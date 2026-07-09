import Controllers
import HTTPTypes
import Hummingbird
import HummingbirdTesting

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct ExampleFailed: Error {}

/// Drives every route in-process — the native Hummingbird route plus the WireMVC todos CRUD —
/// and asserts the responses. Kept out of `main` so the assembly stays readable as checks accrue.
func verifyTodos(_ app: some ApplicationProtocol) async throws {
    try await app.test(.router) { client in
        var failed = false
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
            if !condition { failed = true }
        }
        func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
            try JSONDecoder().decode(T.self, from: Data(response.body.readableBytesView))
        }
        let json: HTTPFields = [.contentType: "application/json"]

        // Native Hummingbird route.
        let health = try await client.execute(uri: "/health", method: .get)
        check(health.status == .ok, "GET /health  → 200 (native Hummingbird route)")

        // WireMVC: create.
        let created = try await client.execute(
            uri: "/todos",
            method: .post,
            headers: json,
            body: ByteBuffer(string: #"{"title":"Write M5"}"#)
        )
        check(created.status == .created, "POST /todos  → 201 (@JSONBody, @JSONResponse(status:))")
        let todo = try decode(Todo.self, created)

        // WireMVC: list.
        let listed = try await client.execute(uri: "/todos", method: .get)
        let todos = try decode([Todo].self, listed)
        check(listed.status == .ok && todos == [todo], "GET /todos  → 200, the created todo")

        // WireMVC: get by @Path id.
        let got = try await client.execute(uri: "/todos/\(todo.id)", method: .get)
        check(try got.status == .ok && decode(Todo.self, got) == todo, "GET /todos/\(todo.id)  → 200, @Path decoded")

        // WireMVC: edit.
        let patched = try await client.execute(
            uri: "/todos/\(todo.id)",
            method: .patch,
            headers: json,
            body: ByteBuffer(string: #"{"completed":true}"#)
        )
        check(
            try patched.status == .ok && decode(Todo.self, patched).completed,
            "PATCH /todos/\(todo.id)  → 200, completed"
        )

        // WireMVC: delete (@ResponseStatus).
        let deleted = try await client.execute(uri: "/todos/\(todo.id)", method: .delete)
        check(deleted.status == .noContent, "DELETE /todos/\(todo.id)  → 204 (@ResponseStatus)")

        let empty = try await client.execute(uri: "/todos", method: .get)
        check(try decode([Todo].self, empty).isEmpty, "GET /todos  → empty after delete")

        if failed { throw ExampleFailed() }
    }
}
