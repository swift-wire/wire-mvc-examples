import ContainerMacrosLib
import ContainerTestSupport
import Controllers
import LocalContainers
import Testing
import Vapor
import VaporTesting
import Wire  // WiringModel (for the /wiring check)

@testable import VaporExample

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The throwaway MongoDB the integration test runs against — provisioned and torn down by the
/// `containerTrait`, not by the app. The official image runs without auth unless a root user is set,
/// so no environment is needed; the `.log` wait strategy holds until Mongo is actually accepting
/// connections, not merely listening.
@Containers
struct TodoContainers {
    @Container(
        image: "mongo:7",
        ports: [27017],
        waitStrategy: .log("Waiting for connections")
    )
    var mongo: RunningContainer
}

@Suite(
    TodoContainers.containerTrait,
    .enabled(if: containerRuntimeAvailable, "A container runtime (Docker) is required")
)
struct TodoVerificationTests {
    let containers = TodoContainers()

    /// Drives every route in-process with VaporTesting — the native Vapor route plus the WireMVC
    /// todos CRUD (backed by the test's MongoDB container) and the cross-runtime `/wiring`
    /// introspection endpoint. The container's host/port are exported as the connection env the
    /// repository reads, then `withApp(configure:)` builds the app the same way `main` does and
    /// shuts it down after — which runs the `@Teardown` that disconnects the Mongo cluster.
    @Test func drivesEveryRouteOverRealMongoDB() async throws {
        setenv("MONGO_HOST", containers.mongo.host, 1)
        setenv("MONGO_PORT", String(try containers.mongo.mappedPort(27017)), 1)

        try await withApp(configure: configure) { app in
            let tester = try app.testing()

            func decode<T: Decodable>(_ type: T.Type, _ response: TestingHTTPResponse) throws -> T {
                try JSONDecoder().decode(T.self, from: Data(buffer: response.body))
            }
            func execute(
                _ method: HTTPMethod,
                _ path: String,
                json: Bool = false,
                extraHeaders: [String: String] = [:],
                body: String? = nil
            ) async throws -> TestingHTTPResponse {
                var headers = HTTPHeaders()
                if json { headers.contentType = .json }
                for (name, value) in extraHeaders { headers.add(name: name, value: value) }
                return try await tester.performTest(
                    request: TestingHTTPRequest(
                        method: method,
                        url: URI(string: path),  // string init parses the query so @Query binds
                        headers: headers,
                        body: body.map { ByteBuffer(string: $0) } ?? ByteBuffer()
                    )
                )
            }

            // Native Vapor route.
            let health = try await execute(.GET, "/health")
            #expect(health.status == .ok)

            // WireMVC: create (@JSONBody, @JSONResponse(status:)).
            let created = try await execute(.POST, "/todos", json: true, body: #"{"title":"Write M5"}"#)
            #expect(created.status == .created)
            let todo = try decode(Todo.self, created)

            // WireMVC: list.
            let listed = try await execute(.GET, "/todos")
            #expect(listed.status == .ok)
            #expect(try decode([Todo].self, listed) == [todo])

            // WireMVC: get by @Path id.
            let got = try await execute(.GET, "/todos/\(todo.id)")
            #expect(got.status == .ok)
            #expect(try decode(Todo.self, got) == todo)

            // GET /export — @RawRoute(.responseSender) with a sender-transforming middleware (M5.4R), here
            // through the ServerTransport adapter: the handler receives a MultiPartSender<S> and streams the
            // todos as a multipart/mixed body, one part per todo, through a MultiPartWriter.
            let exported = try await execute(.GET, "/export")
            let exportText = String(buffer: exported.body)
            #expect(
                exported.status == .ok && exportText.contains("--wireboundary")
                    && exportText.contains("Content-Type: application/json")
                    && exportText.contains("name=\"\(todo.id)\"") && exportText.contains(todo.title)
                    && exportText.contains("completed")  // the whole Todo is JSON-encoded, not just the title
                    && exportText.contains("--wireboundary--")
            )

            // get by @Path id, missing — the handler throws TodoNotFound; @ErrorResponse maps it to 404
            // (M5.4E use-case-2, a handler throw), not the baseline 500.
            let missing = try await execute(.GET, "/todos/does-not-exist")
            #expect(missing.status == .notFound)

            // WireMVC: edit.
            let patched = try await execute(.PATCH, "/todos/\(todo.id)", json: true, body: #"{"completed":true}"#)
            #expect(patched.status == .ok)
            #expect(try decode(Todo.self, patched).completed)

            // WireMVC: @EventStreamResponse SSE — the streaming producer tier, through the
            // WireMVCServerTransport bridge onto Vapor.
            // A second todo makes it a genuine multi-event stream; assert both events are present (order
            // isn't guaranteed) and that there are exactly two, then remove the second.
            let created2 = try await execute(.POST, "/todos", json: true, body: #"{"title":"Walk dog"}"#)
            let todo2 = try decode(Todo.self, created2)
            let stream = try await execute(.GET, "/todos/stream")
            let events = String(buffer: stream.body)
            #expect(stream.status == .ok)
            #expect(events.contains("data: \(todo.id)\n\n") && events.contains("data: \(todo2.id)\n\n"))
            #expect(events.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 2)

            // ---- The OpenAPI half, on the same transport and the same backend ----
            //
            // Everything above reached `/todos` through `@Get`/`@Post`. These reach `/api/todos` through
            // an OpenAPI document, and read the todos the annotation-driven routes just wrote — one
            // `TodoRepository` binding (here MongoDB) serves both, because after M6d an operation *is* a
            // WireMVC route. `configure.swift` is unchanged: `WireMVCServerTransport.apply` already
            // registers every collated contributor, so a second adapter needs nothing added.
            //
            // The `/api` prefix comes from the document's `servers:` block, not from the app.
            let viaSpec = try await execute(.GET, "/api/todos")
            #expect(viaSpec.status == .ok)
            #expect(try decode([Todo].self, viaSpec).count == 2, "the operation reads what the @Post routes wrote")

            // Created through the document, read back through the annotation-driven route: interchangeable
            // over one store, which is the claim worth pinning. Net-zero, so the counts below still hold.
            let createdViaSpec = try await execute(
                .POST,
                "/api/todos",
                json: true,
                body: #"{"title":"via the document"}"#
            )
            #expect(createdViaSpec.status == .created)
            let specTodo = try decode(Todo.self, createdViaSpec)
            let readBack = try await execute(.GET, "/todos/\(specTodo.id)")
            #expect(try decode(Todo.self, readBack).title == "via the document")

            // @ErrorResponse at operation scope, carrying the body the document declares for its 404 —
            // the annotation-driven `/todos/does-not-exist` above answers 404 too. One error model.
            let missingViaSpec = try await execute(.GET, "/api/todos/does-not-exist")
            #expect(missingViaSpec.status == .notFound)
            #expect(String(buffer: missingViaSpec.body).contains("no such todo"))

            let deletedViaSpec = try await execute(.DELETE, "/api/todos/\(specTodo.id)")
            #expect(deletedViaSpec.status == .noContent)
            _ = try await execute(.DELETE, "/todos/\(todo2.id)", extraHeaders: ["x-api-key": "secret"])

            // WireMVC: @Query (completed, after the PATCH) and @Header (x-limit caps the list).
            let qTrue = try await execute(.GET, "/todos?completed=true")
            #expect(try decode([Todo].self, qTrue).count == 1)
            let qFalse = try await execute(.GET, "/todos?completed=false")
            #expect(try decode([Todo].self, qFalse).isEmpty)
            let limited = try await execute(.GET, "/todos", extraHeaders: ["x-limit": "0"])
            #expect(try decode([Todo].self, limited).isEmpty)

            // DELETE is guarded by the route-scope @Middleware(RequireAPIKey). Without the key the gate
            // handles the request — 401, handler skipped (Model B); with it, the handler runs.
            let rejected = try await execute(.DELETE, "/todos/\(todo.id)")
            #expect(rejected.status == .unauthorized)

            // WireMVC: delete (@ResponseStatus).
            let deleted = try await execute(.DELETE, "/todos/\(todo.id)", extraHeaders: ["x-api-key": "secret"])
            #expect(deleted.status == .noContent)

            let empty = try await execute(.GET, "/todos")
            #expect(try decode([Todo].self, empty).isEmpty)

            // WireMVC.mountIntrospection — the wiring model, served cross-runtime (here on Vapor).
            let wiring = try await execute(.GET, "/wiring")
            #expect(wiring.status == .ok)
            let model = try decode(WiringModel.self, wiring)
            // Both controllers are in the one graph — the operations are not a parallel world.
            #expect(model.bindings.contains { $0.type.contains("TodosOperations") })
            #expect(model.bindings.contains { $0.type.contains("TodosController") })

            // @Scoped(seed: HTTPRequest.self) @Controller("/me") — a request-scoped controller alongside
            // the @Singleton TodosController, here through the ServerTransport adapter. The request-scoped
            // Session throws Unauthenticated at scope construction when the request carries no session cookie, and
            // @ErrorResponse(Unauthenticated.self, .unauthorized) maps it to 401 (throw-at-scope-entry, no
            // gate); with a session the controller is built fresh per request from the request-scoped
            // Session, so two requests see two identities.
            let noSession = try await execute(.GET, "/me")
            #expect(noSession.status == .unauthorized)

            let alice = try await execute(.GET, "/me", extraHeaders: ["Cookie": "session=alice"])
            #expect(alice.status == .ok)
            let aliceMe = try decode(Me.self, alice)
            #expect(aliceMe.user == "user:alice")

            let bob = try await execute(.GET, "/me", extraHeaders: ["Cookie": "session=bob"])
            #expect(bob.status == .ok)
            let bobMe = try decode(Me.self, bob)
            #expect(bobMe.user == "user:bob")

            // The Session is fresh per request (distinct users). The @Singleton SessionManager it borrows is
            // shared: it caches a UUID per token, so re-requesting with the same session returns the SAME id
            // (a fresh-per-request manager would mint a new UUID each time), while a different token differs.
            // This is the request-scope capture-dep, here through the adapter.
            let aliceAgain = try await execute(.GET, "/me", extraHeaders: ["Cookie": "session=alice"])
            #expect(try decode(Me.self, aliceAgain).id == aliceMe.id)
            #expect(aliceMe.id != bobMe.id)

            // The `html-form` example, through the adapter: `@FormBody` in, streamed `@HTMLResponse` out.
            // Both halves are declared outside WireMVC, and neither the binding nor the streaming response
            // is native to this runtime — they arrive over `WireMVCServerTransport` like every other route.
            let blankForm = try await execute(.GET, "/contact")
            #expect(blankForm.status == .ok)
            #expect(blankForm.headers.first(name: "Content-Type") == "text/html; charset=utf-8")
            #expect(String(buffer: blankForm.body).contains(#"<form method="post" action="/contact""#))

            let submitted = try await execute(
                .POST,
                "/contact",
                extraHeaders: ["Content-Type": "application/x-www-form-urlencoded"],
                body: "name=Ada+Lovelace&email=ada%40example.com&message=Please+send+documentation."
            )
            #expect(submitted.status == .ok)
            #expect(String(buffer: submitted.body).contains("Thanks, Ada Lovelace — we will reply to ada@example.com."))

            // A *user-declared response mode* through the adapter: `@YAMLResponse` in `YAMLConfig`, with
            // `@YAMLBody` on the way in. `HTMLForm` above covers the streaming terminal; this is the
            // buffered one, and neither annotation is WireMVC's.
            let config = try await execute(.GET, "/config")
            #expect(config.status == .ok)
            #expect(config.headers.first(name: "Content-Type") == "application/yaml")
            #expect(String(buffer: config.body).contains("serviceName: todos"))

            let edited = try await execute(
                .PUT,
                "/config",
                extraHeaders: ["Content-Type": "application/yaml"],
                body: "serviceName: todos\nreplicas: 7\nfeatures: [metrics]\n"
            )
            #expect(edited.status == .ok)
            #expect(String(buffer: edited.body).contains("replicas: 7"))

            // A **streamed** request body through the adapter: `@MultipartSummary` on WireMVC's streaming
            // request tier. The adapter's bridge reader pulls one chunk per read off the transport's body,
            // so the parser is fed as the upload arrives rather than from a body already drained for it.
            let upload = try await execute(
                .POST,
                "/upload",
                extraHeaders: ["Content-Type": "multipart/form-data; boundary=B"],
                body: "--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nWrite M5\r\n"
                    + "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n"
                    + "Content-Type: text/plain\r\n\r\nalpha\r\n--B--\r\n"
            )
            #expect(upload.status == .ok)
            let receipt = try decode(UploadReceipt.self, upload)
            #expect(receipt.fields["title"] == "Write M5")
            #expect(receipt.files.map(\.byteCount) == [5], "the file's bytes were counted, never held")

            // The **lent** stream, through the adapter — the handler rejects on the first field and never
            // reads the file. What that saves is not asserted here: a status code cannot show bytes that
            // were never received. The bridge's side of it is pinned by `wire-mvc`'s own adapter suite.
            let abandoned = try await execute(
                .POST,
                "/upload/stream",
                extraHeaders: ["Content-Type": "multipart/form-data; boundary=B"],
                body: "--B\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\nwrong\r\n"
                    + "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"big.bin\"\r\n"
                    + "Content-Type: application/octet-stream\r\n\r\n"
                    + String(repeating: "x", count: 4096) + "\r\n--B--\r\n"
            )
            #expect(abandoned.status == .unauthorized, "decided on the first field, before the file")

            let accepted = try await execute(
                .POST,
                "/upload/stream",
                extraHeaders: ["Content-Type": "multipart/form-data; boundary=B"],
                body: "--B\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\nletmein\r\n"
                    + "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n"
                    + "Content-Type: application/octet-stream\r\n\r\nalpha\r\n--B--\r\n"
            )
            #expect(accepted.status == .ok)
            #expect(try decode(StreamedUploadReceipt.self, accepted).read == ["a.bin": 5])
        }
    }
}
