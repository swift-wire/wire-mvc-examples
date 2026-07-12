import Controllers
import Foundation
import NIOHTTPServer
import Testing

@testable import SwiftHttpServerExample

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("SwiftHttpServerExample")
struct TodosRoutingTests {
    struct TestArguments: AppArguments {
        let hostname = "127.0.0.1"
        let port = 0  // ephemeral
    }

    /// Builds the app (Wire bootstraps the in-memory repository into the collated TodosController,
    /// registered onto the trie router), serves it on an ephemeral loopback port, and drives the full
    /// todos CRUD lifecycle plus `/wiring` with real HTTP requests — then cancels serving. All
    /// in-process; no container or external infra.
    @Test
    func servesTodosCRUD() async throws {
        let (server, router) = try await buildApplication(TestArguments())
        let handler = router.freeze()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve(handler: handler) }
            let port = try #require(try await server.listeningAddresses.first?.port)

            // POST /todos (@JSONBody, @JSONResponse(status: .created))
            let (createStatus, createData) = try await send(
                "POST",
                "/todos",
                port: port,
                contentType: "application/json",
                body: Data(#"{"title":"Buy milk"}"#.utf8)
            )
            #expect(createStatus == 201)
            let created = try JSONDecoder().decode(Todo.self, from: createData)
            #expect(created.title == "Buy milk" && created.completed == false)

            // GET /todos (@JSONResponse list)
            let (listStatus, listData) = try await send("GET", "/todos", port: port)
            #expect(listStatus == 200)
            let list = try JSONDecoder().decode([Todo].self, from: listData)
            #expect(list.count == 1 && list.first?.id == created.id)

            // GET /todos/{id} (@Path)
            let (getStatus, getData) = try await send("GET", "/todos/\(created.id)", port: port)
            #expect(getStatus == 200)
            #expect(try JSONDecoder().decode(Todo.self, from: getData) == created)

            // PATCH /todos/{id} (@Path + @JSONBody)
            let (patchStatus, patchData) = try await send(
                "PATCH",
                "/todos/\(created.id)",
                port: port,
                contentType: "application/json",
                body: Data(#"{"completed":true}"#.utf8)
            )
            #expect(patchStatus == 200)
            #expect(try JSONDecoder().decode(Todo.self, from: patchData).completed == true)

            // DELETE /todos/{id} (@ResponseStatus(.noContent))
            let (deleteStatus, _) = try await send("DELETE", "/todos/\(created.id)", port: port)
            #expect(deleteStatus == 204)

            // GET /todos — now empty
            let (_, emptyData) = try await send("GET", "/todos", port: port)
            #expect(try JSONDecoder().decode([Todo].self, from: emptyData).isEmpty)

            // GET /wiring — cross-runtime introspection, served over the same router
            let (wiringStatus, _) = try await send("GET", "/wiring", port: port)
            #expect(wiringStatus == 200)

            // A route the trie doesn't have → 404
            let (missStatus, _) = try await send("GET", "/nope", port: port)
            #expect(missStatus == 404)

            group.cancelAll()
        }
    }
}

/// One real HTTP request against the loopback server; returns the status code and body bytes.
func send(
    _ method: String,
    _ path: String,
    port: Int,
    contentType: String? = nil,
    body: Data? = nil
) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
}
