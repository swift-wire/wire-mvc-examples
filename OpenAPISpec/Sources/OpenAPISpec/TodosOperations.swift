import Controllers
public import Wire
public import WireMVC
public import WireOpenAPI

/// The generated schema namespace, shortened. `Components.Schemas.Todo` in every signature crowds out
/// what the signature is actually saying. `public` because it appears in these operations' own public
/// signatures — the handlers are what each runtime's generated conformer calls.
public typealias Schemas = Components.Schemas

/// The **same todos domain, authored the other way** — from an OpenAPI document instead of `@Get`/`@Post`.
///
/// This is the point of the package. `TodosController` in `Controllers` and this type serve the same data
/// from the same `TodoRepository` binding, under the same router, middleware and error tiers, in the same
/// app. After M6d an operation *is* a WireMVC route, so an app does not have two of everything — and that
/// claim is only worth making where a user can see both halves running side by side.
///
/// Generic over the repository for the same reason `TodosController` is: `some TodoRepository` cannot be
/// a stored property, so the backend arrives as a lifted generic parameter that each runtime's
/// `@Singleton(as: TodoRepository.self)` resolves. The two controllers therefore share a backend without
/// either knowing which one it is.
@Singleton
// Bare: the document is the one sitting beside this file. Each runtime executable compiles these
// sources, but which document they implement is settled here, not there.
@OpenAPIController
public struct TodosOperations<Repository: TodoRepository>: Sendable {
    @Inject var repository: Repository

    /// The typed shim: parameters bound by WireMVC's own property wrappers, and the response built from
    /// the one success the document declares. Nothing here names `Operations.ListTodos.Input`.
    @Operation
    public func listTodos(@Query completed: Bool?) async throws -> [Schemas.Todo] {
        let todos = try await repository.all()
        return todos.filter { completed == nil || $0.completed == completed }.map(
            Schemas.Todo.init
        )
    }

    /// Nothing in this method checks the title, and nothing needs to. The document says a title is
    /// between 1 and 80 characters, and the generated validator enforces that before the handler is
    /// entered — including for a body the *deserializer* refused outright, such as one missing `title`
    /// altogether, which never reaches here at all. One mapping answers both, because both arrive as the
    /// same error.
    ///
    /// The three-argument form again, and again because the document forces it: the `422` declared for
    /// this operation carries a `Problem`, which a bare status cannot construct.
    @ErrorResponse(
        WireOpenAPIRequestValidationError.self,
        .unprocessableContent,
        { error in Schemas.Problem(message: "invalid: \(error.failures.map(\.path).joined(separator: ", "))") }
    )
    @Operation
    public func createTodo(@JSONBody input: Schemas.CreateTodo) async throws -> Schemas.Todo {
        .init(try await repository.create(CreateTodo(title: input.title)))
    }

    /// Route scope, not controller scope — and the document decided that. Only `getTodo` and `editTodo`
    /// declare a `404`, and a mapped error is answered as one of the operation's *own* responses, so a
    /// controller-wide mapping is rejected by the spec-read validation naming the three operations that
    /// could not honour it. The three-argument form is what the document forces here too: its `404`
    /// carries a `Problem`, which a status alone cannot construct.
    @ErrorResponse(
        TodoNotFound.self,
        .notFound,
        { _ in Schemas.Problem(message: "no such todo") }
    )
    @Operation
    public func getTodo(@Path id: String) async throws -> Schemas.Todo {
        guard let todo = try await repository.find(id: id) else { throw TodoNotFound() }
        return .init(todo)
    }

    @ErrorResponse(
        TodoNotFound.self,
        .notFound,
        { _ in Schemas.Problem(message: "no such todo") }
    )
    @ErrorResponse(
        WireOpenAPIRequestValidationError.self,
        .unprocessableContent,
        { error in Schemas.Problem(message: "invalid: \(error.failures.map(\.path).joined(separator: ", "))") }
    )
    @Operation
    public func editTodo(
        @Path id: String,
        @JSONBody input: Schemas.EditTodo
    ) async throws -> Schemas.Todo {
        let edit = EditTodo(title: input.title, completed: input.completed)
        guard let todo = try await repository.update(id: id, with: edit) else { throw TodoNotFound() }
        return .init(todo)
    }

    /// The document declares only a `204`, and `@ResponseStatus` says so explicitly rather than leaving
    /// it inferred — the same annotation a `@Get` route uses for the same purpose.
    @Operation
    @ResponseStatus(.noContent)
    public func deleteTodo(@Path id: String) async throws {
        try await repository.delete(id: id)
    }
}

/// The generated schema type and the framework-free domain type are distinct — the document owns one, the
/// repository owns the other — so the boundary is crossed explicitly here rather than by making the domain
/// depend on generated code.
extension Components.Schemas.Todo {
    init(_ todo: Todo) {
        self.init(id: todo.id, title: todo.title, completed: todo.completed)
    }
}
