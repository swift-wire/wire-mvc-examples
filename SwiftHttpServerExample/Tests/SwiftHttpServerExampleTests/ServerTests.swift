import ContainerMacrosLib
import ContainerTestSupport
import Controllers
import Foundation
import LocalContainers
import NIOHTTPServer
import Synchronization  // the LogRequests observe-middleware counter
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

            // GET /todos/{missing} — the handler throws TodoNotFound; @ErrorResponse maps it to 404
            // (M5.4E use-case-2, a handler throw), not the baseline 500.
            let (missingStatus, _) = try await send("GET", "/todos/does-not-exist", port: port)
            #expect(missingStatus == 404)

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

            // GET /todos/stream (@RawRoute) — the raw handler streams one SSE event per todo. Create a
            // second todo first so the stream is genuinely more than one write; assert both events are
            // present (order isn't guaranteed across backends) and that there are exactly two, then
            // remove the second to restore single-todo state. Reaching this route (rather than
            // get(id: "stream")) also confirms the trie prefers the literal over `{id}`.
            let (_, created2Data) = try await send(
                "POST",
                "/todos",
                port: port,
                contentType: "application/json",
                body: Data(#"{"title":"Walk dog"}"#.utf8)
            )
            let created2 = try JSONDecoder().decode(Todo.self, from: created2Data)
            let (streamStatus, streamData) = try await send("GET", "/todos/stream", port: port)
            let events = String(decoding: streamData, as: UTF8.self)
            #expect(streamStatus == 200)
            #expect(events.contains("data: \(created.id)\n\n") && events.contains("data: \(created2.id)\n\n"))
            #expect(events.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 2)
            _ = try await send("DELETE", "/todos/\(created2.id)", port: port, headers: ["x-api-key": "secret"])

            // GET /todos?completed=… (@Query) — the todo is completed after the PATCH.
            let (qTrue, qTrueData) = try await send("GET", "/todos?completed=true", port: port)
            let qTrueList = try JSONDecoder().decode([Todo].self, from: qTrueData)
            #expect(qTrue == 200 && qTrueList.count == 1)
            let (_, qFalseData) = try await send("GET", "/todos?completed=false", port: port)
            #expect(try JSONDecoder().decode([Todo].self, from: qFalseData).isEmpty)

            // GET /todos with x-limit: 0 (@Header) — caps the list to nothing.
            let (_, limitedData) = try await send("GET", "/todos", port: port, headers: ["x-limit": "0"])
            #expect(try JSONDecoder().decode([Todo].self, from: limitedData).isEmpty)

            // DELETE is guarded by the route-scope @Middleware(RequireAPIKey). Without the key the gate
            // handles the request itself — 401, the handler never runs (Model B short-circuit). The
            // controller-scope @Middleware(LogRequests) still runs for this rejected request, so its
            // counter advances — "every middleware runs" even past a gate.
            let observedBefore = requestObservations.load(ordering: .relaxed)
            let (rejected, _) = try await send("DELETE", "/todos/\(created.id)", port: port)
            #expect(rejected == 401)
            #expect(requestObservations.load(ordering: .relaxed) > observedBefore)

            // DELETE /todos/{id} (@ResponseStatus(.noContent)) — with the key the handler runs.
            let (deleteStatus, _) = try await send(
                "DELETE",
                "/todos/\(created.id)",
                port: port,
                headers: ["x-api-key": "secret"]
            )
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

            // @Scoped(seed: HTTPRequest.self) @Controller("/me") — a request-scoped controller alongside
            // the @Singleton TodosController. The request-scoped Session throws Unauthenticated at scope
            // construction when there is no x-session, and @ErrorResponse(Unauthenticated.self, .unauthorized)
            // maps it to 401 (throw-at-scope-entry, no gate); with a session the controller is built fresh
            // per request, injecting the request-scoped Session, so two requests see two identities.
            let (noSession, _) = try await send("GET", "/me", port: port)
            #expect(noSession == 401)

            let (aliceStatus, aliceData) = try await send("GET", "/me", port: port, headers: ["x-session": "alice"])
            let alice = try JSONDecoder().decode(Me.self, from: aliceData)
            #expect(aliceStatus == 200 && alice.user == "user:alice")

            let (bobStatus, bobData) = try await send("GET", "/me", port: port, headers: ["x-session": "bob"])
            let bob = try JSONDecoder().decode(Me.self, from: bobData)
            #expect(bobStatus == 200 && bob.user == "user:bob")

            // The Session is fresh per request (distinct users). The @Singleton SessionManager it borrows is
            // shared: it caches a UUID per token, so re-requesting with the same session returns the SAME id
            // (a fresh-per-request manager would mint a new UUID each time), while a different token differs.
            // This is the request-scope capture-dep — the scoped Session borrowing an app singleton.
            let (_, aliceAgainData) = try await send("GET", "/me", port: port, headers: ["x-session": "alice"])
            let aliceAgain = try JSONDecoder().decode(Me.self, from: aliceAgainData)
            #expect(alice.id == aliceAgain.id)
            #expect(alice.id != bob.id)

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
