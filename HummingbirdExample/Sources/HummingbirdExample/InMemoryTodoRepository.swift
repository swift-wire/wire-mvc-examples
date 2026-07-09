import Controllers
import Synchronization
import Wire

/// The Hummingbird runtime's backend — an in-memory store. `@Singleton(as: TodoRepository.self)`
/// binds it as the `some TodoRepository` the shared `TodosController` injects; another runtime
/// binds a different backend without the controller changing.
@Singleton(as: TodoRepository.self)
public final class InMemoryTodoRepository: TodoRepository {
    private struct State {
        var todos: [String: Todo] = [:]
        var nextID = 1
    }

    private let state = Mutex(State())

    @Inject public init() {}

    public func all() async throws -> [Todo] {
        state.withLock { store in Array(store.todos.values).sorted { $0.id < $1.id } }
    }

    public func find(id: String) async throws -> Todo? {
        state.withLock { $0.todos[id] }
    }

    public func create(_ input: CreateTodo) async throws -> Todo {
        state.withLock { store in
            let id = "\(store.nextID)"
            store.nextID += 1
            let todo = Todo(id: id, title: input.title, completed: false)
            store.todos[id] = todo
            return todo
        }
    }

    public func update(id: String, with input: EditTodo) async throws -> Todo? {
        state.withLock { store in
            guard var todo = store.todos[id] else { return nil }
            if let title = input.title { todo.title = title }
            if let completed = input.completed { todo.completed = completed }
            store.todos[id] = todo
            return todo
        }
    }

    public func delete(id: String) async throws {
        state.withLock { _ = $0.todos.removeValue(forKey: id) }
    }
}
