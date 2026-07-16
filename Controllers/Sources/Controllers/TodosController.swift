import BasicContainers
import HTTPAPIs
import HTTPTypes
public import Wire
public import WireMVC

/// The portable todos controller — identical across every runtime executable. It depends only
/// on the `TodoRepository` protocol and WireMVC's declarative annotations; nothing
/// framework-specific. The repository is a **lifted generic parameter** (Wire's opaque-injection
/// shape — `some TodoRepository` on a stored property can't be assigned), resolved to whatever
/// backend the executable binds via `@Singleton(as: TodoRepository.self)`.
///
/// `@Singleton @Controller` makes it a graph binding whose routes `WireMVC.apply` registers onto a
/// `RoutableHTTPServerBuilder` (the runtime's router).
@Singleton
@Controller("/todos")
@Middleware(LogRequests<WireContext, WireReader, WireSender>.self)  // controller-scope: every route
@Middleware(AuditKeys.factory)  // controller-scope, generic-with-deps, non-canonical parameter order
public struct TodosController<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    /// `@Query completed` filters and the `x-limit` `@Header` caps the count — both optional (via
    /// Swift-native defaults) and both `LosslessStringConvertible`-converted, so a bare `GET /todos`
    /// still returns everything.
    @Get
    @JSONResponse
    public func list(
        @Query completed: Bool? = nil,
        @Header("x-limit") limit: Int? = nil
    ) async throws -> [Todo] {
        var todos = try await repository.all()
        if let completed { todos = todos.filter { $0.completed == completed } }
        if let limit { todos = Array(todos.prefix(limit)) }
        return todos
    }

    @Get("/{id}")
    @JSONResponse
    public func get(@Path id: String) async throws -> Todo {
        guard let todo = try await repository.find(id: id) else { throw TodoNotFound() }
        return todo
    }

    @Post
    @JSONResponse(status: .created)
    public func create(@JSONBody input: CreateTodo) async throws -> Todo {
        try await repository.create(input)
    }

    @Patch("/{id}")
    @JSONResponse
    public func edit(@Path id: String, @JSONBody input: EditTodo) async throws -> Todo {
        guard let todo = try await repository.update(id: id, with: input) else { throw TodoNotFound() }
        return todo
    }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    @Middleware(RequireAPIKeyKeys.factory)  // route-scope gate — generic-with-deps, factory-lifted by key
    public func delete(@Path id: String) async throws {
        try await repository.delete(id: id)
    }

    /// A raw streaming route (`@RawRoute`): the handler is handed the response sender verbatim and
    /// writes it itself — no decode, no encode — streaming the todos as server-sent events. It's
    /// generic over the sender (the router's associated type) and still `@Inject`s the repository
    /// like any controller method. `/todos/stream` is a literal, so the router matches it here rather
    /// than `/todos/{id}`.
    @Get("/stream")
    @RawRoute
    public func stream<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        var fields = HTTPFields()
        fields[.contentType] = "text/event-stream"
        var writer = try await responseSender.send(HTTPResponse(status: .ok, headerFields: fields))
        for todo in try await repository.all() {
            var event = UniqueArray<UInt8>(copying: Array("data: \(todo.id)\n\n".utf8))
            try await writer.write(buffer: &event)
        }
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: nil)
    }
}
