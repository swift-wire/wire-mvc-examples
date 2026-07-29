package import Controllers
import Smockable
import Testing  // the @Smock-generated verifier references Testing::SourceLocation (module-qualified)

// smockable mocks for the two protocols under test. `@Smock` can't annotate the external `Controllers`
// protocols, so each mirror protocol *inherits* the real one and re-declares its requirements (the documented
// external-protocol workaround): `@Smock protocol MockableTodoRepository: TodoRepository { … }` makes
// `MockMockableTodoRepository` conform to BOTH — so it satisfies the graph's `TodoRepository` slot while
// exposing smockable's `Expectations`/`when`/`verify` surface.
//
// These live in their **own file**, apart from the `@BindType`s that reference the generated mocks
// (`MockedBinds.swift`): a macro's arguments can't see peer types another macro generates in the *same* file,
// so `@BindType(TodoRepository.self, MockMockableTodoRepository.self)` only resolves the mock cross-file.

@Smock(accessLevel: .internal)
protocol MockableTodoRepository: TodoRepository {
    func all() async throws -> [Todo]
    func find(id: String) async throws -> Todo?
    func create(_ input: CreateTodo) async throws -> Todo
    func update(id: String, with input: EditTodo) async throws -> Todo?
    func delete(id: String) async throws
}

@Smock(accessLevel: .internal)
protocol MockableSessionManager: SessionManager {
    func sessionID(for token: String) async throws -> String
}

// Normal typealiases onto the @Smock-generated mocks, so `@BindType` names a *non-macro* declaration.
typealias TodoRepositoryMock = MockMockableTodoRepository
typealias SessionManagerMock = MockMockableSessionManager
