import Controllers
import Logging
import Valkey
import Wire
import WireMVC  // @BackgroundService

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The `ValkeyClient` this runtime's backend is built on. It's a `ServiceLifecycle.Service` — its
/// connection pool lives in a `run()` loop — so `@BackgroundService` marks it for the graph's services:
/// constructed once, injected into the repository AND handed to the app's `ServiceGroup`, which runs
/// it alongside the server and stops it at shutdown. Same instance on both sides (Wire invokes a
/// `@Provides` function at most once), so the repository and the run loop share one connection pool.
/// `@BackgroundService` on a `@Provides` function aliases `@Contributes(to: WireMVCKeys.services)`;
/// `ValkeyClient` already conforms to `Service`, so no conformance is added.
///
/// Connection config comes from the environment, 12-factor style — the test exports the container's
/// host/port; a real deployment sets them however it manages config. The client doesn't connect here;
/// it connects when the service group runs it.
@Provides
@BackgroundService
func provideValkeyClient() -> ValkeyClient {
    let environment = ProcessInfo.processInfo.environment
    let host = environment["VALKEY_HOST"] ?? "localhost"
    let port = environment["VALKEY_PORT"].flatMap(Int.init) ?? 6379
    return ValkeyClient(.hostname(host, port: port), logger: Logger(label: "valkey"))
}

/// The Hummingbird runtime's backend — a real Valkey, a key-value store (distinct from Vapor's MongoDB
/// document store and the proposal runtime's CouchDB). Each todo is a JSON string under `todo:<id>`;
/// insertion order is kept in a `todos` list, and ids come from `INCR todos:seq` — a monotonic counter.
/// Like any real app it reaches the store over a driver (`valkey-swift`) injected through Wire's DI; the
/// store itself is provisioned operationally (a real Valkey for `swift run`, a throwaway container the
/// test starts). `@Singleton(as: TodoRepository.self)` binds it as the controller's repository.
@Singleton(as: TodoRepository.self)
public final class ValkeyTodoRepository: TodoRepository {
    private let client: ValkeyClient
    private static let index = ValkeyKey("todos")  // list of ids, insertion order
    private static let sequence = ValkeyKey("todos:seq")  // INCR counter → todo ids

    @Inject public init(client: ValkeyClient) {
        self.client = client
    }

    public func all() async throws -> [Todo] {
        var todos: [Todo] = []
        for token in try await client.lrange(Self.index, start: 0, stop: -1) {
            if let todo = try await find(id: try token.decode(as: String.self)) {
                todos.append(todo)
            }
        }
        return todos
    }

    public func find(id: String) async throws -> Todo? {
        guard let stored = try await client.get(Self.key(id)) else { return nil }
        return try JSONDecoder().decode(Todo.self, from: Data(stored))
    }

    public func create(_ input: CreateTodo) async throws -> Todo {
        let id = try await client.incr(Self.sequence)
        let todo = Todo(id: String(id), title: input.title, completed: false)
        try await store(todo)
        _ = try await client.rpush(Self.index, elements: [todo.id])
        return todo
    }

    public func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard var todo = try await find(id: id) else { return nil }
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        try await store(todo)
        return todo
    }

    public func delete(id: String) async throws {
        _ = try await client.del(keys: [Self.key(id)])
        _ = try await client.lrem(Self.index, count: 0, element: id)
    }

    /// Write the todo as JSON under its `todo:<id>` key (create and update are the same SET).
    private func store(_ todo: Todo) async throws {
        _ = try await client.set(Self.key(todo.id), value: try JSONEncoder().encode(todo))
    }

    private static func key(_ id: String) -> ValkeyKey { ValkeyKey("todo:\(id)") }
}
