package import Controllers
package import SwiftHttpServerExample
package import Wire

// The mocked routing suite's test-graph variant. One `TestingKey`, two `@BindType` slots binding the app's
// `TodoRepository` / `SessionManager` to the smockable mocks (declared in `MockableProtocols.swift`), plus the
// ephemeral-port `@Replaces` so this suite's server binds a free loopback port. The keyed suite serves the
// key's *variant* app graph, which drops the app's `@Singleton(as:)` CouchDB bindings — so the real backend's
// `init` never runs and the suite is Docker-free without touching the production graph.

/// The test-graph variant. The request-scoped `MeController` reaches `TodoRepository` directly and
/// `SessionManager` through its request-scoped `Session`, and the app-scoped `TodosController`/`ExportController`
/// (both `@TestScopable`) are rebuilt per request — so all three thread the supplied mock per request.
enum MockedRoutingBinds {
    @BindType(TodoRepository.self, TodoRepositoryMock.self)
    @BindType(SessionManager.self, SessionManagerMock.self)
    static let mocks = TestingKey()
}
