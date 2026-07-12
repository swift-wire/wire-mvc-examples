import Controllers
import Wire

/// This runtime's backend — an in-memory store behind the `TodoRepository` protocol the shared,
/// framework-free controller depends on. An `actor` gives it safe concurrent access with no external
/// infra (another runtime satisfies the same protocol with SQLite or Postgres).
/// `@Singleton(as: TodoRepository.self)` binds it as the controller's injected repository.
@Singleton(as: TodoRepository.self)
actor InMemoryTodoRepository: TodoRepository {
    private var todos: [String: Todo] = [:]
    private var nextID = 1

    @Inject init() {}

    func all() async throws -> [Todo] {
        todos.values.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    func find(id: String) async throws -> Todo? {
        todos[id]
    }

    func create(_ input: CreateTodo) async throws -> Todo {
        let todo = Todo(id: "\(nextID)", title: input.title, completed: false)
        nextID += 1
        todos[todo.id] = todo
        return todo
    }

    func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard var todo = todos[id] else { return nil }
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        todos[id] = todo
        return todo
    }

    func delete(id: String) async throws {
        todos[id] = nil
    }
}
