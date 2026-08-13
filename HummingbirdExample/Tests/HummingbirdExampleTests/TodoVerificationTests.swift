import ContainerMacrosLib
import ContainerTestSupport
import Controllers
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import LocalContainers
import Testing
import Wire  // WiringModel (for the /wiring check)

@testable import HummingbirdExample

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

/// The throwaway Valkey the integration test runs against — provisioned and torn down by the
/// `containerTrait`, not by the app. The official image runs without auth, so no environment is needed;
/// the `.log` wait strategy holds until Valkey is actually accepting connections, not merely listening.
@Containers
struct TodoContainers {
    @Container(
        image: "valkey/valkey:8",
        ports: [6379],
        waitStrategy: .log("Ready to accept connections")
    )
    var valkey: RunningContainer
}

/// Test-only `AppArguments`: an ephemeral port picked by the OS for the `.live` server.
struct TestArguments: AppArguments {
    var hostname = "127.0.0.1"
    var port = 0
}

@Suite(
    "HummingbirdExample routes",
    TodoContainers.containerTrait,
    .enabled(if: containerRuntimeAvailable, "A container runtime (Docker) is required")
)
struct TodoVerificationTests {
    let containers = TodoContainers()

    /// Drives every route with HummingbirdTesting — the native Hummingbird route plus the WireMVC todos
    /// CRUD (backed by the test's Valkey container) and the cross-runtime `/wiring` introspection
    /// endpoint. The container's host/port are exported as the connection env the Valkey client reads,
    /// then `buildApplication` assembles the app the same way `main` does. `.live` (not `.router`) runs
    /// the app's `ServiceGroup`, so the graph's Valkey service connects before requests flow — and the
    /// service is stopped when the test finishes and the app shuts down.
    @Test func drivesEveryRouteOverValkey() async throws {
        setenv("VALKEY_HOST", containers.valkey.host, 1)
        setenv("VALKEY_PORT", String(try containers.valkey.mappedPort(6379)), 1)

        let app = try await buildApplication(TestArguments())
        try await app.test(.live) { client in
            func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
                try JSONDecoder().decode(T.self, from: Data(response.body.readableBytesView))
            }
            let json: HTTPFields = [.contentType: "application/json"]

            // Native Hummingbird route.
            let health = try await client.execute(uri: "/health", method: .get)
            #expect(health.status == .ok)

            // WireMVC: create (@JSONBody, @JSONResponse(status:)).
            let created = try await client.execute(
                uri: "/todos",
                method: .post,
                headers: json,
                body: ByteBuffer(string: #"{"title":"Write M5"}"#)
            )
            #expect(created.status == .created)
            let todo = try decode(Todo.self, created)

            // WireMVC: list.
            let listed = try await client.execute(uri: "/todos", method: .get)
            #expect(listed.status == .ok)
            #expect(try decode([Todo].self, listed) == [todo])

            // WireMVC: get by @Path id.
            let got = try await client.execute(uri: "/todos/\(todo.id)", method: .get)
            #expect(got.status == .ok)
            #expect(try decode(Todo.self, got) == todo)

            // GET /export — @RawRoute(.responseSender) with a sender-transforming middleware (M5.4R), here
            // through the ServerTransport adapter: the handler receives a MultiPartSender<S> and streams the
            // todos as a multipart/mixed body, one part per todo, through a MultiPartWriter.
            let exported = try await client.execute(uri: "/export", method: .get)
            let exportText = String(decoding: exported.body.readableBytesView, as: UTF8.self)
            #expect(
                exported.status == .ok && exportText.contains("--wireboundary")
                    && exportText.contains("Content-Type: application/json")
                    && exportText.contains("name=\"\(todo.id)\"") && exportText.contains(todo.title)
                    && exportText.contains("completed")  // the whole Todo is JSON-encoded, not just the title
                    && exportText.contains("--wireboundary--")
            )

            // get by @Path id, missing — the handler throws TodoNotFound; @ErrorResponse maps it to 404
            // (M5.4E use-case-2, a handler throw), not the baseline 500.
            let missing = try await client.execute(uri: "/todos/does-not-exist", method: .get)
            #expect(missing.status == .notFound)

            // WireMVC: edit.
            let patched = try await client.execute(
                uri: "/todos/\(todo.id)",
                method: .patch,
                headers: json,
                body: ByteBuffer(string: #"{"completed":true}"#)
            )
            #expect(patched.status == .ok)
            #expect(try decode(Todo.self, patched).completed)

            // WireMVC: @RawRoute SSE — streamed through the WireMVCServerTransport bridge onto Hummingbird.
            // A second todo makes it a genuine multi-event stream; assert both events are present (order
            // isn't guaranteed) and that there are exactly two, then remove the second.
            let created2 = try await client.execute(
                uri: "/todos",
                method: .post,
                headers: json,
                body: ByteBuffer(string: #"{"title":"Walk dog"}"#)
            )
            let todo2 = try decode(Todo.self, created2)
            let stream = try await client.execute(uri: "/todos/stream", method: .get)
            let events = String(decoding: stream.body.readableBytesView, as: UTF8.self)
            #expect(stream.status == .ok)
            #expect(events.contains("data: \(todo.id)\n\n") && events.contains("data: \(todo2.id)\n\n"))
            #expect(events.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 2)

            // ---- The OpenAPI half, on the same router and the same backend ----
            //
            // Everything above reached `/todos` through `@Get`/`@Post`. These reach `/api/todos` through
            // an OpenAPI document, and read the todos the annotation-driven routes just wrote — one
            // `TodoRepository` binding serves both, because after M6d an operation *is* a WireMVC route.
            // Nothing in `buildApplication` mentions OpenAPI: `WireMVCServerTransport.apply` already
            // registers every collated contributor, which is the whole point of one collation surface.
            //
            // The prefix comes from the document's `servers:` block, not from the app.
            let viaSpec = try await client.execute(uri: "/api/todos", method: .get)
            #expect(viaSpec.status == .ok)
            let listedViaSpec = try decode([Todo].self, viaSpec)
            #expect(listedViaSpec.count == 2, "the operation reads what the @Post routes wrote")

            // Created through the document, read back through the annotation-driven route: the two
            // styles are interchangeable over one store, which is the claim worth pinning.
            let createdViaSpec = try await client.execute(
                uri: "/api/todos",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"title":"via the document"}"#)
            )
            #expect(createdViaSpec.status == .created)
            let specTodo = try decode(Todo.self, createdViaSpec)
            let readBackViaAnnotation = try await client.execute(uri: "/todos/\(specTodo.id)", method: .get)
            #expect(try decode(Todo.self, readBackViaAnnotation).title == "via the document")

            // @ErrorResponse at operation scope, with the body the document declares for its 404. The
            // annotation-driven `/todos/does-not-exist` above answers 404 too — one error model, two
            // authoring styles.
            let missingViaSpec = try await client.execute(uri: "/api/todos/does-not-exist", method: .get)
            #expect(missingViaSpec.status == .notFound)
            #expect(String(buffer: missingViaSpec.body).contains("no such todo"))

            // Cleanup, through the document's own delete (204, from @ResponseStatus).
            let deletedViaSpec = try await client.execute(
                uri: "/api/todos/\(specTodo.id)",
                method: .delete
            )
            #expect(deletedViaSpec.status == .noContent)

            _ = try await client.execute(
                uri: "/todos/\(todo2.id)",
                method: .delete,
                headers: [HTTPField.Name("x-api-key")!: "secret"]
            )

            // WireMVC: @Query (completed, after the PATCH) and @Header (x-limit caps the list).
            let qTrue = try await client.execute(uri: "/todos?completed=true", method: .get)
            #expect(try decode([Todo].self, qTrue).count == 1)
            let qFalse = try await client.execute(uri: "/todos?completed=false", method: .get)
            #expect(try decode([Todo].self, qFalse).isEmpty)
            let limited = try await client.execute(
                uri: "/todos",
                method: .get,
                headers: [HTTPField.Name("x-limit")!: "0"]
            )
            #expect(try decode([Todo].self, limited).isEmpty)

            // DELETE is guarded by the route-scope @Middleware(RequireAPIKey). Without the key the gate
            // handles the request — 401, handler skipped (Model B); with it, the handler runs.
            let rejected = try await client.execute(uri: "/todos/\(todo.id)", method: .delete)
            #expect(rejected.status == .unauthorized)

            // WireMVC: delete (@ResponseStatus).
            let deleted = try await client.execute(
                uri: "/todos/\(todo.id)",
                method: .delete,
                headers: [HTTPField.Name("x-api-key")!: "secret"]
            )
            #expect(deleted.status == .noContent)

            let empty = try await client.execute(uri: "/todos", method: .get)
            #expect(try decode([Todo].self, empty).isEmpty)

            // WireMVC.mountIntrospection — the wiring model, served cross-runtime (here on Hummingbird).
            let wiring = try await client.execute(uri: "/wiring", method: .get)
            #expect(wiring.status == .ok)
            let model = try decode(WiringModel.self, wiring)
            #expect(model.bindings.contains { $0.type.contains("TodosController") })
            // Both controllers are in the one graph — the OpenAPI operations are not a parallel world.
            #expect(model.bindings.contains { $0.type.contains("TodosOperations") })

            // @Scoped(seed: HTTPRequest.self) @Controller("/me") — a request-scoped controller alongside
            // the @Singleton TodosController, here through the ServerTransport adapter. The request-scoped
            // Session throws Unauthenticated at scope construction when the request carries no session cookie, and
            // @ErrorResponse(Unauthenticated.self, .unauthorized) maps it to 401 (throw-at-scope-entry, no
            // gate); with a session the controller is built fresh per request from the request-scoped
            // Session, so two requests see two identities.
            let noSession = try await client.execute(uri: "/me", method: .get)
            #expect(noSession.status == .unauthorized)

            let alice = try await client.execute(
                uri: "/me",
                method: .get,
                headers: [.cookie: "session=alice"]
            )
            #expect(alice.status == .ok)
            let aliceMe = try decode(Me.self, alice)
            #expect(aliceMe.user == "user:alice")

            let bob = try await client.execute(uri: "/me", method: .get, headers: [.cookie: "session=bob"])
            #expect(bob.status == .ok)
            let bobMe = try decode(Me.self, bob)
            #expect(bobMe.user == "user:bob")

            // The Session is fresh per request (distinct users). The @Singleton SessionManager it borrows is
            // shared: it caches a UUID per token, so re-requesting with the same session returns the SAME id
            // (a fresh-per-request manager would mint a new UUID each time), while a different token differs.
            // This is the request-scope capture-dep, here through the adapter.
            let aliceAgain = try await client.execute(
                uri: "/me",
                method: .get,
                headers: [.cookie: "session=alice"]
            )
            #expect(try decode(Me.self, aliceAgain).id == aliceMe.id)
            #expect(aliceMe.id != bobMe.id)

            // The `html-form` example, through the adapter: `@FormBody` in, streamed `@HTMLResponse` out.
            // Both halves are declared outside WireMVC, and neither the binding nor the streaming response
            // is native to this runtime — they arrive over `WireMVCServerTransport` like every other route.
            let blankForm = try await client.execute(uri: "/contact", method: .get)
            #expect(blankForm.status == .ok)
            #expect(blankForm.headers[.contentType] == "text/html; charset=utf-8")
            #expect(String(buffer: blankForm.body).contains(#"<form method="post" action="/contact""#))

            let submitted = try await client.execute(
                uri: "/contact",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "name=Ada+Lovelace&email=ada%40example.com&message=Please+send+documentation.")
            )
            #expect(submitted.status == .ok)
            #expect(String(buffer: submitted.body).contains("Thanks, Ada Lovelace — we will reply to ada@example.com."))

            // A *user-declared response mode* through the adapter: `@YAMLResponse` in `YAMLConfig`, with
            // `@YAMLBody` on the way in. `HTMLForm` above covers the streaming terminal; this is the
            // buffered one, and neither annotation is WireMVC's.
            let config = try await client.execute(uri: "/config", method: .get)
            #expect(config.status == .ok)
            #expect(config.headers[.contentType] == "application/yaml")
            #expect(String(buffer: config.body).contains("serviceName: todos"))

            let edited = try await client.execute(
                uri: "/config",
                method: .put,
                headers: [.contentType: "application/yaml"],
                body: ByteBuffer(string: "serviceName: todos\nreplicas: 7\nfeatures: [metrics]\n")
            )
            #expect(edited.status == .ok)
            #expect(String(buffer: edited.body).contains("replicas: 7"))

            // A **streamed** request body through the adapter: `@MultipartBody` on WireMVC's streaming
            // request tier, parsing an upload chunk by chunk. Note the adapter's `BridgeReader` wraps bytes
            // it has already collected, so this streams the API and not the transport — the binding behaves
            // identically, and the memory benefit is real only on the proposal-native runtime.
            let upload = try await client.execute(
                uri: "/upload",
                method: .post,
                headers: [.contentType: "multipart/form-data; boundary=B"],
                body: ByteBuffer(
                    string: "--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nWrite M5\r\n"
                        + "--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n"
                        + "Content-Type: text/plain\r\n\r\nalpha\r\n--B--\r\n"
                )
            )
            #expect(upload.status == .ok)
            let receipt = try decode(UploadReceipt.self, upload)
            #expect(receipt.fields["title"] == "Write M5")
            #expect(receipt.files.map(\.byteCount) == [5], "the file's bytes were counted, never held")
        }
    }
}
