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

/// Thrown by a handler (`get`/`edit`) when a todo isn't found. `TodosController`'s
/// `@ErrorResponse(TodoNotFound.self, .notFound)` maps this handler throw to 404 —
/// without it, the baseline terminal re-throws it to the framework's 500.
public struct TodoNotFound: Error {
    public init() {}
}
