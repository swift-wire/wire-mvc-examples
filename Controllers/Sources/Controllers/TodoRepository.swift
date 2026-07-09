/// The persistence boundary the controller depends on. Declared here (framework-free), *not*
/// satisfied here — each runtime executable binds its own `@Singleton(as: TodoRepository.self)`
/// backend. `async` so a real database backend fits the same protocol as the in-memory one.
///
/// This is the axis the six `hummingbird-examples/todos-*` vary on (DynamoDB / Fluent / Postgres
/// / …); for WireMVC it collapses to one injected binding.
public protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func find(id: String) async throws -> Todo?
    func create(_ input: CreateTodo) async throws -> Todo
    func update(id: String, with input: EditTodo) async throws -> Todo?
    func delete(id: String) async throws
}

/// Thrown when a todo isn't found. (Maps to 500 under M5's baseline error handling; typed
/// error→response mapping — e.g. 404 — is deferred.)
public struct TodoNotFound: Error {
    public init() {}
}
