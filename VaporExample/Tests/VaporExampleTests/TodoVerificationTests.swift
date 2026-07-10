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

/// The throwaway Postgres the integration test runs against — provisioned and torn down by the
/// `containerTrait`, not by the app. `POSTGRES_PASSWORD`/`POSTGRES_DB` configure the image (it
/// won't initialise without a password), and the `.log` wait strategy holds until Postgres is
/// actually accepting connections, not merely listening.
@Containers
struct TodoContainers {
    @Container(
        image: "postgres:16-alpine",
        ports: [5432],
        environment: ["POSTGRES_PASSWORD": "postgres", "POSTGRES_DB": "todos"],
        waitStrategy: .log("database system is ready to accept connections")
    )
    var postgres: RunningContainer
}

@Suite(
    TodoContainers.containerTrait,
    .enabled(if: containerRuntimeAvailable, "A container runtime (Docker) is required")
)
struct TodoVerificationTests {
    let containers = TodoContainers()

    /// Drives every route in-process with VaporTesting — the native Vapor route plus the WireMVC
    /// todos CRUD (backed by the test's Postgres container) and the cross-runtime `/wiring`
    /// introspection endpoint. The container's host/port are exported as the connection env the
    /// repository reads, then `withApp(configure:)` builds the app the same way `main` does and
    /// shuts it down after — which runs the `@Teardown` that closes the connection pool.
    @Test func drivesEveryRouteOverRealPostgres() async throws {
        setenv("DATABASE_HOST", containers.postgres.host, 1)
        setenv("DATABASE_PORT", String(try containers.postgres.mappedPort(5432)), 1)

        try await withApp(configure: configure) { app in
            let tester = try app.testing()

            func decode<T: Decodable>(_ type: T.Type, _ response: TestingHTTPResponse) throws -> T {
                try JSONDecoder().decode(T.self, from: Data(buffer: response.body))
            }
            func execute(
                _ method: HTTPMethod,
                _ path: String,
                json: Bool = false,
                body: String? = nil
            ) async throws -> TestingHTTPResponse {
                var headers = HTTPHeaders()
                if json { headers.contentType = .json }
                return try await tester.performTest(
                    request: TestingHTTPRequest(
                        method: method,
                        url: URI(path: path),
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

            // WireMVC: edit.
            let patched = try await execute(.PATCH, "/todos/\(todo.id)", json: true, body: #"{"completed":true}"#)
            #expect(patched.status == .ok)
            #expect(try decode(Todo.self, patched).completed)

            // WireMVC: delete (@ResponseStatus).
            let deleted = try await execute(.DELETE, "/todos/\(todo.id)")
            #expect(deleted.status == .noContent)

            let empty = try await execute(.GET, "/todos")
            #expect(try decode([Todo].self, empty).isEmpty)

            // WireMVC.mountIntrospection — the wiring model, served cross-runtime (here on Vapor).
            let wiring = try await execute(.GET, "/wiring")
            #expect(wiring.status == .ok)
            let model = try decode(WiringModel.self, wiring)
            #expect(model.bindings.contains { $0.type.contains("TodosController") })
        }
    }
}
