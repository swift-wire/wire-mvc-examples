import ContainerMacrosLib
import ContainerTestSupport
import Controllers
import Foundation
import LocalContainers
import NIOHTTPServer
import Testing

@testable import SwiftHttpServerExample

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The throwaway CouchDB the integration test runs against — provisioned and torn down by the
/// `containerTrait`, not by the app. CouchDB 3 won't start without an admin, so `COUCHDB_USER`/
/// `COUCHDB_PASSWORD` configure the image; the `.log` wait strategy holds until CouchDB is actually
/// up, not merely listening.
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

@Suite(
    "SwiftHttpServerExample",
    TodoContainers.containerTrait,
    .enabled(if: containerRuntimeAvailable, "A container runtime (Docker) is required")
)
struct TodosRoutingTests {
    let containers = TodoContainers()

    struct TestArguments: AppArguments {
        let hostname = "127.0.0.1"
        let port = 0  // ephemeral
    }

    /// Builds the app (Wire bootstraps the CouchDB repository into the collated TodosController,
    /// registered onto the trie router), serves it on an ephemeral loopback port, and drives the full
    /// todos CRUD lifecycle plus `/wiring` with real HTTP requests — then cancels serving. The
    /// controllers are served on the proposal server; the repository reaches CouchDB (the test's
    /// container) through the proposal client — the proposal end to end.
    @Test
    func servesTodosCRUDOverCouchDB() async throws {
        setenv("COUCHDB_HOST", containers.couchdb.host, 1)
        setenv("COUCHDB_PORT", String(try containers.couchdb.mappedPort(5984)), 1)
        setenv("COUCHDB_USER", "admin", 1)
        setenv("COUCHDB_PASSWORD", "password", 1)

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

            // GET /todos/stream (@RawRoute) — the raw handler streams the todos as SSE. Reaching this
            // route (rather than get(id: "stream")) confirms the trie prefers the literal over `{id}`.
            let (streamStatus, streamData) = try await send("GET", "/todos/stream", port: port)
            #expect(streamStatus == 200)
            #expect(String(decoding: streamData, as: UTF8.self) == "data: \(created.id)\n\n")

            // GET /todos?completed=… (@Query) — the todo is completed after the PATCH.
            let (qTrue, qTrueData) = try await send("GET", "/todos?completed=true", port: port)
            let qTrueList = try JSONDecoder().decode([Todo].self, from: qTrueData)
            #expect(qTrue == 200 && qTrueList.count == 1)
            let (_, qFalseData) = try await send("GET", "/todos?completed=false", port: port)
            #expect(try JSONDecoder().decode([Todo].self, from: qFalseData).isEmpty)

            // GET /todos with x-limit: 0 (@Header) — caps the list to nothing.
            let (_, limitedData) = try await send("GET", "/todos", port: port, headers: ["x-limit": "0"])
            #expect(try JSONDecoder().decode([Todo].self, from: limitedData).isEmpty)

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
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
}
