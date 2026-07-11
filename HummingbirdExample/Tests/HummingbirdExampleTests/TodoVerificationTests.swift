import Controllers
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
import Wire  // WiringModel (for the /wiring check)

@testable import HummingbirdExample

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Test-only `AppArguments`: an ephemeral port, since the in-memory `.router` test client never
/// binds a socket.
struct TestArguments: AppArguments {
    var hostname = "127.0.0.1"
    var port = 0
}

@Suite("HummingbirdExample routes")
struct TodoVerificationTests {
    /// Drives every route in-process with HummingbirdTesting — the native Hummingbird route plus
    /// the WireMVC todos CRUD (backed by the in-memory SQLite repository) and the cross-runtime
    /// `/wiring` introspection endpoint. `buildApplication` assembles the app the same way `main`
    /// does; `.router` runs the request through the router without binding a socket.
    @Test func drivesEveryRouteOverSQLite() async throws {
        let app = try await buildApplication(TestArguments())
        try await app.test(.router) { client in
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

            // WireMVC: delete (@ResponseStatus).
            let deleted = try await client.execute(uri: "/todos/\(todo.id)", method: .delete)
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
