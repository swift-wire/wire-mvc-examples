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
        }
    }
}
