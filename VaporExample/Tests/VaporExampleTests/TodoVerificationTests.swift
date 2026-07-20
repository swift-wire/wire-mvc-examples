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
                    && exportText.contains("name=\"\(todo.id)\"") && exportText.contains(todo.title)
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

            // WireMVC: @RawRoute SSE — streamed through the WireMVCServerTransport bridge onto Vapor.
            // A second todo makes it a genuine multi-event stream; assert both events are present (order
            // isn't guaranteed) and that there are exactly two, then remove the second.
            let created2 = try await execute(.POST, "/todos", json: true, body: #"{"title":"Walk dog"}"#)
            let todo2 = try decode(Todo.self, created2)
            let stream = try await execute(.GET, "/todos/stream")
            let events = String(buffer: stream.body)
            #expect(stream.status == .ok)
            #expect(events.contains("data: \(todo.id)\n\n") && events.contains("data: \(todo2.id)\n\n"))
            #expect(events.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == 2)
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
            #expect(model.bindings.contains { $0.type.contains("TodosController") })

            // @Scoped(seed: HTTPRequest.self) @Controller("/me") — a request-scoped controller alongside
            // the @Singleton TodosController, here through the ServerTransport adapter. The request-scoped
            // Session throws Unauthenticated at scope construction when there is no x-session, and
            // @ErrorResponse(Unauthenticated.self, .unauthorized) maps it to 401 (throw-at-scope-entry, no
            // gate); with a session the controller is built fresh per request from the request-scoped
            // Session, so two requests see two identities.
            let noSession = try await execute(.GET, "/me")
            #expect(noSession.status == .unauthorized)

            let alice = try await execute(.GET, "/me", extraHeaders: ["x-session": "alice"])
            #expect(alice.status == .ok)
            let aliceMe = try decode(Me.self, alice)
            #expect(aliceMe.user == "user:alice")

            let bob = try await execute(.GET, "/me", extraHeaders: ["x-session": "bob"])
            #expect(bob.status == .ok)
            let bobMe = try decode(Me.self, bob)
            #expect(bobMe.user == "user:bob")

            // The Session is fresh per request (distinct users). The @Singleton SessionManager it borrows is
            // shared: it caches a UUID per token, so re-requesting with the same session returns the SAME id
            // (a fresh-per-request manager would mint a new UUID each time), while a different token differs.
            // This is the request-scope capture-dep, here through the adapter.
            let aliceAgain = try await execute(.GET, "/me", extraHeaders: ["x-session": "alice"])
            #expect(try decode(Me.self, aliceAgain).id == aliceMe.id)
            #expect(aliceMe.id != bobMe.id)
        }
    }
}
