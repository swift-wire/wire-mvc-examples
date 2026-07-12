import Wire
import WireMVC

/// The portable todos controller — identical across every runtime executable. It depends only
/// on the `TodoRepository` protocol and WireMVC's declarative annotations; nothing
/// framework-specific. The repository is a **lifted generic parameter** (Wire's opaque-injection
/// shape — `some TodoRepository` on a stored property can't be assigned), resolved to whatever
/// backend the executable binds via `@Singleton(as: TodoRepository.self)`.
///
/// `@Singleton @Controller` makes it a graph binding whose routes are collated onto a
/// `ServerTransport` by `WireMVC.apply`.
@Singleton
@Controller("/todos")
public struct TodosController<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    @Get
    @JSONResponse
    public func list() async throws -> [Todo] {
        try await repository.all()
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
    public func delete(@Path id: String) async throws {
        try await repository.delete(id: id)
    }
}
