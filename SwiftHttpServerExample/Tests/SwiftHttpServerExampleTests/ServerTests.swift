import ContainerMacrosLib
import ContainerTestSupport
import Controllers
import Foundation
// `MemberImportVisibility`: this file names `HTTPField.Name` members, so it must import their defining
// module itself rather than relying on one reaching it transitively.
import HTTPTypes
import LocalContainers
import Synchronization  // the LogRequests observe-middleware counter
import Testing
import WireMVCTesting

/// The throwaway CouchDB the integration suite runs against — provisioned and torn down by the
/// `containerTrait`, not by the app. CouchDB 3 won't start without an admin, so `COUCHDB_USER`/
/// `COUCHDB_PASSWORD` configure the image; the `.log` wait strategy holds until CouchDB is actually up.
@Containers
struct TodoContainers {
    @Container(
        image: "couchdb:3",
        ports: [5984],
        environment: ["COUCHDB_USER": "admin", "COUCHDB_PASSWORD": "password"],
        waitStrategy: .log("Apache CouchDB has started")
    )
    var couchdb: RunningContainer
}

/// The real-backend integration suite: serves the app's **production graph** (the real `CouchDB*` bindings)
/// through the keyless `@Suite(.wiremvc(.swiftHttpServer))` harness — a `NIOHTTPServer` the harness owns and
/// binds to an ephemeral loopback port, so nothing has to `@Replaces` the app's `ServerConfig` down to 0 —
/// driving the full todos
/// CRUD lifecycle plus `/wiring` and the request-scoped `/me` over real HTTP against the container-backed
/// CouchDB — the same seam the mocked suite uses, but end to end. Serialized: the tests mutate one shared
/// CouchDB, so they must not interleave.
@Suite(
    "SwiftHttpServerExample real backend",
    TodoContainers.containerTrait,
    .wiremvc(
        .swiftHttpServer,
        environment: {
            // Evaluated at suite entry — after `containerTrait` has started CouchDB and set
            // `ContainerTestContext.current` — and applied before the harness bootstraps the graph, so the
            // environment-reading `provideCouchDBClient` sees the container's assigned endpoint.
            let couchdb = TodoContainers().couchdb
            return [
                "COUCHDB_HOST": couchdb.host,
                "COUCHDB_PORT": String(try couchdb.mappedPort(5984)),
                "COUCHDB_USER": "admin",
                "COUCHDB_PASSWORD": "password",
            ]
        }
    ),
    .enabled(if: containerRuntimeAvailable, "A container runtime (Docker) is required"),
    .serialized
)
struct TodosRoutingTests {
    @Test
    func servesTodosCRUDOverCouchDB() async throws {
        // Keyless suite: `withClient` yields a client carrying no doubles — the E2E walk drives the real
        // CouchDB-backed graph. Untyped on purpose: the explicit 201/200/404 assertions are the point here,
        // and a typed method would fold them into its return-or-throw.
        try await withClient { client in

            // POST /todos (@JSONBody, @JSONResponse(status: .created))
            let create = try await client.post("/todos", json: ["title": "Buy milk"])
            #expect(create.status == 201)
            let created = try create.json(Todo.self)
            #expect(created.title == "Buy milk" && created.completed == false)
            // 201 carries a `Location` naming what was created — computed by the handler and returned in its
            // response tuple, while `@JSONResponse(status: .created)` still supplies the status.
            #expect(create.head?.headerFields[.location] == "/todos/\(created.id)")
            // And the route it names is real: the canonical answer is only useful if it resolves.
            let followed = try await client.get("/todos/\(created.id)")
            #expect(followed.status == 200)
            #expect(try followed.json(Todo.self).id == created.id)

            // The two verbs, on one controller. `x-content-type-options` is `.set`, so the middleware is
            // authoritative everywhere. `Cache-Control` is `.setIfAbsent`: `list` answers with its own and
            // keeps it, while a route that says nothing gets the middleware's default.
            let listed = try await client.get("/todos")
            #expect(listed.head?.headerFields[.init("x-content-type-options")!] == "nosniff")
            #expect(listed.head?.headerFields[.cacheControl] == "no-cache", "the route's own answer wins")

            let defaulted = try await client.get("/todos/\(created.id)")
            #expect(defaulted.head?.headerFields[.init("x-content-type-options")!] == "nosniff")
            #expect(defaulted.head?.headerFields[.cacheControl] == "no-store", "the middleware's default")

            // GET /todos (@JSONResponse list)
            let list = try await client.get("/todos")
            #expect(list.status == 200)
            let todos = try list.json([Todo].self)
            #expect(todos.count == 1 && todos.first?.id == created.id)

            // GET /todos/{id} (@Path)
            let fetched = try await client.get("/todos/\(created.id)")
            #expect(fetched.status == 200)
            #expect(try fetched.json(Todo.self) == created)

            // GET /export — @MultiPartResponse on the streaming producer tier: the handler returns parts and
            // MultiPartProducer frames them as a multipart/mixed body, one part per todo.
            let export = try await client.get("/export")
            #expect(export.status == 200)
            let exportText = export.bodyText
            #expect(
                exportText.contains("--wireboundary") && exportText.contains("Content-Type: application/json")
                    && exportText.contains("name=\"\(created.id)\"") && exportText.contains(created.title)
                    && exportText.contains("completed") && exportText.contains("--wireboundary--")
            )
            // The boundary-bearing content type comes from the producer, not from hand-built HTTPFields —
            // which is the part of the raw handler the tier took over.
            #expect(export.head?.headerFields[.contentType] == "multipart/mixed; boundary=wireboundary")

            // GET /export/raw — the same body through the *other* tier: a @RawRoute(.responseSender) handler
            // receiving a sender a middleware transformed. Asserted byte-identical to the producer's output,
            // which is the claim the two-route split rests on — they differ in how the response is produced,
            // not in what it is.
            let exportRaw = try await client.get("/export/raw")
            #expect(exportRaw.status == 200)
            let rawText = exportRaw.bodyText
            #expect(
                rawText.contains("--wireboundary") && rawText.contains("Content-Type: application/json")
                    && rawText.contains("name=\"\(created.id)\"") && rawText.contains(created.title)
                    && rawText.contains("--wireboundary--")
            )

            // GET /todos/{missing} — the handler throws TodoNotFound; @ErrorResponse maps it to 404.
            let missing = try await client.get("/todos/does-not-exist")
            #expect(missing.status == 404)

            // PATCH /todos/{id} (@Path + @JSONBody)
            let patched = try await client.patch("/todos/\(created.id)", json: ["completed": true])
            #expect(patched.status == 200)
            #expect(try patched.json(Todo.self).completed == true)

            // GET /todos/stream (@EventStreamResponse) — one SSE event per todo, framed by ServerSentEventProducer
            // on the streaming tier. Add a second so the stream is more than one
            // write, assert both events are present and there are exactly two, then remove the second.
            let created2 = try await client.post("/todos", json: ["title": "Walk dog"]).json(Todo.self)
            let stream = try await client.get("/todos/stream")
            #expect(stream.status == 200)
            let events = stream.bodyText
            #expect(events.contains("data: \(created.id)\n\n") && events.contains("data: \(created2.id)\n\n"))
            #expect(events.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 2)

            // ---- Abandoning an upload mid-body, over a real connection ----
            //
            // The mocked suite already pins the 401. What only a live transport shows is what happens to the
            // connection: the handler rejects on the first field and never reads the file, so the response
            // is written before the request `.end` arrives. `HTTPKeepAliveHandler` sees that and amends the
            // head with `Connection: close` rather than draining an unbounded upload — which is why an early
            // exit is a well-formed HTTP interaction and not a hung socket.
            let boundary = "----WireMVCLive"
            var abandoned = "--\(boundary)\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\nwrong\r\n"
            abandoned += "--\(boundary)\r\nContent-Disposition: form-data; name=\"blob\"; filename=\"big.bin\"\r\n"
            abandoned += "Content-Type: application/octet-stream\r\n\r\n"
            abandoned += String(repeating: "x", count: 512 * 1024)
            abandoned += "\r\n--\(boundary)--\r\n"

            let abandonedUpload = try await client.send(
                "POST",
                "/upload/stream",
                body: Data(abandoned.utf8),
                headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
            )
            #expect(abandonedUpload.status == 401, "rejected on the first field, before the file was read")
            #expect(
                abandonedUpload.head?.headerFields[.connection]?.lowercased() == "close",
                "the server closes rather than draining a body the handler abandoned"
            )

            // ---- The OpenAPI half, on the same router and the same backend ----
            //
            // Everything above reached `/todos` through `@Get`/`@Post`. These reach `/api/todos` through an
            // OpenAPI document, and read the todos the annotation-driven routes just wrote — one
            // `TodoRepository` binding (here CouchDB) serves both, because after M6d an operation *is* a
            // WireMVC route. Here they register *natively*, onto the trie builder, where the other two
            // runtimes reach the same routes through the `WireMVCServerTransport` bridge.
            //
            // The `/api` prefix comes from the document's `servers:` block, not from the app.
            let viaSpec = try await client.get("/api/todos")
            #expect(viaSpec.status == 200)
            #expect(try viaSpec.json([Todo].self).count == 2, "the operation reads what the @Post routes wrote")

            // Created through the document, read back through the annotation-driven route: interchangeable
            // over one store. Net-zero, so the counts below still hold.
            let createdViaSpec = try await client.post("/api/todos", json: ["title": "via the document"])
            #expect(createdViaSpec.status == 201)
            let specTodo = try createdViaSpec.json(Todo.self)
            #expect(try await client.get("/todos/\(specTodo.id)").json(Todo.self).title == "via the document")

            // Assertions the *document* makes and the generator drops, now enforced. Three shapes, three
            // answers, none of them written by a handler: a body a generated check refused, a body the
            // *deserializer* refused (which never reached the forwarder, and used to be a bare 400 with
            // no body), and a parameter violation — 400 rather than 422, because the request line is
            // wrong and not the payload, which is the split `WireMVCBindingError` already draws.
            let emptyTitle = try await client.post("/api/todos", json: ["title": ""])
            #expect(emptyTitle.status == 422)
            #expect(emptyTitle.bodyText.contains("invalid: body.title"))
            let missingTitle = try await client.post("/api/todos", json: [String: String]())
            #expect(missingTitle.status == 422)
            #expect(missingTitle.bodyText.contains("body.title"))
            let badID = try await client.get("/api/todos/NOT_LOWERCASE")
            #expect(badID.status == 400)
            #expect(badID.bodyText.contains("path.id"))

            // @ErrorResponse at operation scope, carrying the body the document declares for its 404.
            let missingViaSpec = try await client.get("/api/todos/does-not-exist")
            #expect(missingViaSpec.status == 404)
            #expect(missingViaSpec.bodyText.contains("no such todo"))

            #expect(try await client.delete("/api/todos/\(specTodo.id)").status == 204)
            _ = try await client.delete("/todos/\(created2.id)", headers: ["x-api-key": "secret"])

            // GET /todos?completed=… (@Query) — the todo is completed after the PATCH.
            let qTrue = try await client.get("/todos?completed=true")
            let qTrueList = try qTrue.json([Todo].self)
            #expect(qTrue.status == 200 && qTrueList.count == 1)
            let qFalse = try await client.get("/todos?completed=false")
            #expect(try qFalse.json([Todo].self).isEmpty)

            // GET /todos with x-limit: 0 (@Header) — caps the list to nothing.
            let limited = try await client.get("/todos", headers: ["x-limit": "0"])
            #expect(try limited.json([Todo].self).isEmpty)

            // DELETE is guarded by the route-scope @Middleware(RequireAPIKey). Without the key it's 401 and the
            // handler never runs, but the controller-scope @Middleware(LogRequests) still advances its counter.
            let observedBefore = requestObservations.load(ordering: .relaxed)
            let rejected = try await client.delete("/todos/\(created.id)")
            #expect(rejected.status == 401)
            #expect(requestObservations.load(ordering: .relaxed) > observedBefore)

            // DELETE /todos/{id} (@ResponseStatus(.noContent)) — with the key the handler runs.
            let deleted = try await client.delete("/todos/\(created.id)", headers: ["x-api-key": "secret"])
            #expect(deleted.status == 204)

            // GET /todos — now empty
            let empty = try await client.get("/todos")
            #expect(try empty.json([Todo].self).isEmpty)

            // GET /wiring — cross-runtime introspection, served over the same router
            #expect(try await client.get("/wiring").status == 200)

            // CORS as a global @Middleware on the composition root: it wraps every route, so a listed
            // origin gets its fields on an ordinary response. Only this runtime has a global tier —
            // Hummingbird and Vapor mount onto their own Application, with no generated @main to fold into.
            let cors = try await client.get("/todos", headers: ["Origin": "https://allowed.example"])
            #expect(cors.head?.headerFields[.accessControlAllowOrigin] == "https://allowed.example")
            #expect(cors.head?.headerFields[.accessControlAllowCredentials] == "true")
            #expect(cors.head?.headerFields[values: .vary].contains("Origin") == true)

            // The preflight is answered by the middleware rather than routed — /todos has no OPTIONS route.
            let preflight = try await client.send(
                "OPTIONS",
                "/todos",
                headers: ["Origin": "https://allowed.example", "Access-Control-Request-Method": "POST"]
            )
            #expect(preflight.status == 204)
            #expect(preflight.head?.headerFields[.accessControlMaxAge] == "600")
            #expect(preflight.head?.headerFields[.accessControlAllowOrigin] == "https://allowed.example")

            // An unlisted origin is answered without the field rather than echoed.
            let disallowed = try await client.get("/todos", headers: ["Origin": "https://evil.example"])
            #expect(disallowed.head?.headerFields[.accessControlAllowOrigin] == nil)

            // A route the trie doesn't have → 404
            #expect(try await client.get("/nope").status == 404)

            // @Scoped(seed: HTTPRequest.self) @Controller("/me") — the request-scoped controller. With no
            // session cookie the Session binding throws Unauthenticated at scope entry → 401.
            #expect(try await client.get("/me").status == 401)

            // The real cookie round trip: log in, read the token back out of `Set-Cookie`, and replay it.
            // This is what a browser does on its own, and what a bespoke header could never demonstrate.
            let aliceLogin = try await client.post("/session/login", json: Credentials(user: "alice"))
            #expect(aliceLogin.status == 200)
            let aliceCookie = try #require(sessionCookieToken(from: aliceLogin))

            let aliceResponse = try await client.get("/me", headers: ["Cookie": "session=\(aliceCookie)"])
            let alice = try aliceResponse.json(Me.self)
            #expect(aliceResponse.status == 200)

            let bobLogin = try await client.post("/session/login", json: Credentials(user: "bob"))
            let bobCookie = try #require(sessionCookieToken(from: bobLogin))
            let bob = try await client.get("/me", headers: ["Cookie": "session=\(bobCookie)"]).json(Me.self)

            let aliceAgain = try await client.get("/me", headers: ["Cookie": "session=\(aliceCookie)"])
                .json(Me.self)

            // Asserted against the cookie that was *sent*, not just across responses. `user` is the token
            // the `Session` binding read off the request, so `user == "user:<sent>"` says the cookie
            // survived the trip — and names which request it failed on. Comparing the two responses to each
            // other only says they disagree, which is what left the last two failures ambiguous between
            // "the client rewrote the header" and "the store lost the token".
            #expect(alice.user == "user:\(aliceCookie)", "request 1 received a cookie it was not sent")
            #expect(bob.user == "user:\(bobCookie)", "request 2 received a cookie it was not sent")
            #expect(aliceAgain.user == "user:\(aliceCookie)", "request 3 received a cookie it was not sent")

            // Then the session itself: the store minted an id at login and hands the same one back for the
            // same token. This can only be trusted once the assertions above hold — if the cookie did not
            // survive, an id mismatch says nothing about the store.
            #expect(alice.id == aliceAgain.id)
            #expect(alice.id != bob.id)

            // Logout clears it: a bodiless response tuple, `Max-Age=0`, and no response annotation at all.
            let loggedOut = try await client.post("/session/logout", json: Credentials(user: "alice"))
            #expect(loggedOut.status == 204)
            #expect(loggedOut.head?.headerFields[values: .setCookie].contains { $0.contains("Max-Age=0") } == true)

            // **Work that outlives the request**, over a real socket and a real store. The mocked suite
            // covers these routes in-process against an `@Replaces` in-memory `JobStore`; what this adds is
            // the graph's collated services running under the `.swiftHttpServer` mode — that mode's
            // `defaultServices` is `.run` — with the job records in the same CouchDB as the todos.
            let enqueued = try await client.post("/jobs", json: JobSubmission(text: "the cat sat on the mat"))
            #expect(enqueued.status == 202)
            let queued = try enqueued.json(JobRecord.self)
            #expect(queued.state == .queued)

            // The record is in CouchDB before the response was written — the property `submit` awaits its
            // write for, and the one that makes the `202` survive this process. Silent about which state
            // comes back: the worker may already have run it, and asserting `queued` would be asserting a
            // race.
            #expect(try await client.get("/jobs/\(queued.id)").status == 200)

            var finished = queued
            for _ in 0..<5_000 {
                finished = try await client.get("/jobs/\(queued.id)").json(JobRecord.self)
                if finished.state == .completed || finished.state == .failed { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(finished.state == .completed)
            #expect(finished.summary == "the:2")

            // `/documents` over a real socket. The mocked suite covers the policy tiers in detail against
            // the in-process dispatch; what only this one adds is that the gate's response survives the
            // transport — it is written from a middleware rather than from a route terminal, which is a
            // different path through `WireMVCOutcome.send` and the one nothing else here drives live.
            let user = ["x-user": "erin"]
            let gated = try await client.get("/documents/notes", headers: user)
            #expect(gated.status == 403)
            #expect(try gated.json(AccessDenial.self).policy == "SuspendedSubjectRule")

            // And the handler tier's refusal, which is bodiless — the two are told apart the same way here
            // as everywhere else.
            let refused = try await client.get("/documents/sequencing", headers: ["x-user": "bob"])
            #expect(refused.status == 403)
            #expect(refused.bodyText.isEmpty)
        }
    }
}

/// Pull the session token out of a login response's `Set-Cookie`. Read with `[values:]`, never the
/// single-value subscript — that one joins with ", " and does not special-case `Set-Cookie`, so a response
/// carrying two cookies would come back as one unparseable string.
private func sessionCookieToken(from response: TestResponse) -> String? {
    for field in response.head?.headerFields[values: .setCookie] ?? [] {
        guard field.hasPrefix("session=") else { continue }
        let value = field.dropFirst("session=".count)
        return String(value.prefix { $0 != ";" })
    }
    return nil
}
