import ContainerMacrosLib
import ContainerTestSupport
import Controllers
import Foundation
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

            // GET /todos (@JSONResponse list)
            let list = try await client.get("/todos")
            #expect(list.status == 200)
            let todos = try list.json([Todo].self)
            #expect(todos.count == 1 && todos.first?.id == created.id)

            // GET /todos/{id} (@Path)
            let fetched = try await client.get("/todos/\(created.id)")
            #expect(fetched.status == 200)
            #expect(try fetched.json(Todo.self) == created)

            // GET /export — @RawRoute(.responseSender) with a sender-transforming middleware: streams the todos
            // as a multipart/mixed body, one part per todo.
            let export = try await client.get("/export")
            #expect(export.status == 200)
            let exportText = export.bodyText
            #expect(
                exportText.contains("--wireboundary") && exportText.contains("Content-Type: application/json")
                    && exportText.contains("name=\"\(created.id)\"") && exportText.contains(created.title)
                    && exportText.contains("completed") && exportText.contains("--wireboundary--")
            )

            // GET /todos/{missing} — the handler throws TodoNotFound; @ErrorResponse maps it to 404.
            let missing = try await client.get("/todos/does-not-exist")
            #expect(missing.status == 404)

            // PATCH /todos/{id} (@Path + @JSONBody)
            let patched = try await client.patch("/todos/\(created.id)", json: ["completed": true])
            #expect(patched.status == 200)
            #expect(try patched.json(Todo.self).completed == true)

            // GET /todos/stream (@RawRoute) — one SSE event per todo. Add a second so the stream is more than one
            // write, assert both events are present and there are exactly two, then remove the second.
            let created2 = try await client.post("/todos", json: ["title": "Walk dog"]).json(Todo.self)
            let stream = try await client.get("/todos/stream")
            #expect(stream.status == 200)
            let events = stream.bodyText
            #expect(events.contains("data: \(created.id)\n\n") && events.contains("data: \(created2.id)\n\n"))
            #expect(events.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 2)

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

            // A route the trie doesn't have → 404
            #expect(try await client.get("/nope").status == 404)

            // @Scoped(seed: HTTPRequest.self) @Controller("/me") — the request-scoped controller. Without an
            // x-session header the Session binding throws Unauthenticated at scope entry → 401; with one, the
            // controller is built fresh per request and returns the identity.
            #expect(try await client.get("/me").status == 401)

            let aliceResponse = try await client.get("/me", headers: ["x-session": "alice"])
            let alice = try aliceResponse.json(Me.self)
            #expect(aliceResponse.status == 200 && alice.user == "user:alice")

            let bob = try await client.get("/me", headers: ["x-session": "bob"]).json(Me.self)
            #expect(bob.user == "user:bob")

            // The @Singleton SessionManager caches a stable id per token, so the same session resolves to the
            // same id across requests while a different token differs — the request-scope capture-dep.
            let aliceAgain = try await client.get("/me", headers: ["x-session": "alice"]).json(Me.self)
            #expect(alice.id == aliceAgain.id)
            #expect(alice.id != bob.id)
        }
    }
}
