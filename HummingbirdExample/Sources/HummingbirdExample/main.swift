import Controllers
import Hummingbird
import HummingbirdTesting
// Conformance-only import: provides `extension Router: ServerTransport`, which `WireMVC.apply`
// needs but no symbol here names, so the unused_import analyzer can't see it's required.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import WireMVC

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Cross-runtime demo, Hummingbird edition. The graph constructs the in-memory backend and
// injects it into the collated (framework-free) TodosController; we build a Hummingbird router,
// register a native route AND apply the WireMVC controllers onto it — the two coexist — then
// drive every route in-process.

struct ExampleFailed: Error {}

let graph = try await Wire.bootstrap()

let router = Router()
// A native Hummingbird route, registered the framework's own way — coexists with the
// WireMVC-applied /todos/* on the same router.
router.get("health") { _, _ in "OK" }
// The WireMVC controllers, applied onto the router (a ServerTransport via OpenAPIHummingbird).
try WireMVC.apply(graph, to: router)

let app = Application(router: router)

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

print(
    "wire-mvc-examples (Hummingbird) OK — the same WireMVC controllers, collated across modules and served on Hummingbird alongside a native route"
)
