import Controllers
import Smockable
import Testing
import WireMVCTesting

// The mocked routing suite — routing/controller logic in isolation, no CouchDB and no transport.
// `@Suite(.wiremvc(key, .inProcess))` builds the app's real router over an in-memory server and calls the
// finalized handler directly: no socket, no port, and the app's `createServer()` is never involved. The keyed
// harness is parked for `MockedRoutingBinds.mocks`; each test supplies its per-request smockable doubles with
// `withClient(supplying: <Controller>Doubles(…))`, which hands back that controller's typed client bound to
// the doubles it just supplied. The doubles are per controller, so each test names only the slots its own
// controller reaches: `MeController` takes both, `TodosController` and `ExportController` take the repository
// alone. `/me` is the app's only seed-scoped (`@Scoped(seed:)`) controller and exercises both mocked slots —
// its handler calls `repository.all()` (the todo op) and `session.id()` → `manager.sessionID(for:)` (the
// session op). Verifying those interactions proves the request routed through the controller against the
// mocks, with no backend.

@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct MockedRoutingTests {
    /// `GET /me` with a session cookie: the request-scoped `MeController` is built fresh, injecting the
    /// mocked `TodoRepository` directly and the mocked `SessionManager` through its `Session`. The response
    /// carries the session op's mocked id, and both mocks record exactly the calls the controller made.
    @Test func meRouteThreadsBothMocks() async throws {
        var todoExpectations = MockMockableTodoRepository.Expectations()
        when(todoExpectations.all(), return: [Todo]())  // MeController.me() calls repository.all()
        let todoMock = MockMockableTodoRepository(expectations: todoExpectations)

        var sessionExpectations = MockMockableSessionManager.Expectations()
        when(sessionExpectations.sessionID(for: .any), return: "mock-session-42")
        let sessionMock = MockMockableSessionManager(expectations: sessionExpectations)

        try await withClient(
            supplying: MeControllerDoubles(sessionManager: sessionMock, todoRepository: todoMock)
        ) { meController in
            // The session cookie is read by the request-scoped `Session` binding off the `HTTPRequest`, not
            // declared as a `@Header` on the handler — so it is not a typed parameter, but the method still
            // takes extra headers, which keeps the derived path and decoded response. Sent as a real `Cookie`
            // field, the same way the browser would.
            let me = try await meController.me(headers: ["Cookie": "session=alice"])
            #expect(me.user == "user:alice")
            #expect(me.id == "mock-session-42")  // the session op's mocked answer, not a real store's UUID
        }

        // The exact instances recorded the exact calls the controller made — routing exercised, no backend.
        verify(todoMock, times: 1).all()  // the todo op
        verify(sessionMock, times: 1).sessionID(for: "alice")  // the session op, keyed on the cookie token
    }

    /// `GET /me` without an `x-session` header: the `Session` binding throws `Unauthenticated` at scope entry,
    /// which `@ErrorResponse(Unauthenticated.self, .unauthorized)` maps to 401 — before the session op runs.
    /// The mocks are still supplied (the keyed suite's uniform rule), but `sessionID` is never reached.
    @Test func meWithoutSessionShortCircuitsBeforeSessionOp() async throws {
        let todoMock = MockMockableTodoRepository(expectations: MockMockableTodoRepository.Expectations())
        let sessionMock = MockMockableSessionManager(expectations: MockMockableSessionManager.Expectations())

        try await withClient(
            supplying: MeControllerDoubles(sessionManager: sessionMock, todoRepository: todoMock)
        ) { meController in
            // No `x-session`: the typed method surfaces the 401 as a throw carrying the status.
            let error = try await #require(throws: WireMVCRouteError.self) { try await meController.me() }
            #expect(error.status == .unauthorized)
        }

        verify(sessionMock, .never).sessionID(for: .any)  // scope-entry throw short-circuits the session op
    }

    /// `GET /todos` — the **app-scoped** (`@Singleton`) generic `TodosController<Repository>`, `@TestScopable`,
    /// so the keyed suite rebuilds it per request against the mock (seedless reconstruction, the generic axis
    /// concretized to the mock). Its controller-scope `@Middleware(ControllerMiddleware.audit)` (`AuditGate`) is
    /// a **generic mock-consuming factory** — it `@Inject`s the same `Repository`, sourced per request from the
    /// doubles via the variant factory's `create(doubles:)`. The supplied mock answers `all()`, served through
    /// the rebuilt controller, and its exact instance records the one call.
    @Test func todosRouteThreadsMockThroughAppScopedControllerAndFactory() async throws {
        var todoExpectations = MockMockableTodoRepository.Expectations()
        when(todoExpectations.all(), return: [Todo(id: "42", title: "mock todo", completed: false)])
        let todoMock = MockMockableTodoRepository(expectations: todoExpectations)

        // Per-controller doubles: `TodosController` never reaches the session slot, so its struct has no field
        // for it and this test supplies only the repository — no throwaway session mock.
        try await withClient(supplying: TodosControllerDoubles(todoRepository: todoMock)) { todos in
            let listed = try await todos.list(completed: nil, limit: nil)
            #expect(listed.map(\.id) == ["42"])  // the mock's answer, via the per-request app-scoped controller
        }
        verify(todoMock, times: 1).all()
    }

    /// `GET /export` — the app-scoped generic `ExportController<Repository>`, `@TestScopable`, whose route is a
    /// `@RawRoute` streaming a `multipart/mixed` body. Under the keyed suite it's rebuilt per request with the
    /// mock; the raw handler calls `repository.all()` and streams each todo. Proves the **raw-route** variant
    /// witness enters seedless scope with the mock (the reconstructed subject, not a held `_wireSubject`).
    @Test func exportRawRouteThreadsMockThroughAppScopedController() async throws {
        var todoExpectations = MockMockableTodoRepository.Expectations()
        when(todoExpectations.all(), return: [Todo(id: "7", title: "streamed", completed: true)])
        let todoMock = MockMockableTodoRepository(expectations: todoExpectations)

        try await withClient(supplying: ExportControllerDoubles(todoRepository: todoMock)) { export in
            // The raw-route shim: the request line is derived, the payload stays untyped, and a non-2xx is not
            // treated as a failure — a raw route may answer one by design.
            try await export.todos { response, _ in
                #expect(response.status == .ok)
            }
        }
        verify(todoMock, times: 1).all()  // the raw handler reached the mock through the rebuilt controller
    }
}
