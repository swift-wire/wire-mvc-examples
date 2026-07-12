import Configuration
import Controllers
import Logging
import MongoKitten
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The Vapor runtime's backend — a real MongoDB, a document store (distinct from Hummingbird's
/// embedded SQL and the proposal runtime's in-memory backend). Like any real app it reads its
/// connection from the environment (via swift-configuration) and owns the `MongoDatabase` through
/// Wire's DI: `@Inject init` connects; `@Teardown` disconnects the cluster at shutdown. It does *not*
/// provision the database — that's operational (a real MongoDB for `swift run`, a throwaway container
/// the test starts via swift-local-containers). Here it's just another `@Singleton(as:)`, and the
/// `@Teardown` on that opaquely-bound singleton is exactly what wire-mvc-examples validates against
/// swift-wire.
@Singleton(as: TodoRepository.self)
public final class MongoDBTodoRepository: TodoRepository {
    private let database: MongoDatabase

    private var todos: MongoCollection { database["todos"] }

    @Inject public init() async throws {
        // Connection config from the environment, 12-factor style. swift-configuration maps each key
        // to an env var (`mongo.host` → `MONGO_HOST`, `mongo.port` → `MONGO_PORT`). The test exports
        // the container's host/port that way; a real deployment sets them however it manages config.
        let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
        let host = config.string(forKey: "mongo.host", default: "localhost")
        let port = config.int(forKey: "mongo.port", default: 27017)
        database = try await MongoDatabase.connect(to: "mongodb://\(host):\(port)/todos")
    }

    @Teardown public func shutdown() async {
        await (database.pool as? MongoCluster)?.disconnect()
    }

    public func all() async throws -> [Todo] {
        try await todos.find().sort(["_id": 1]).decode(StoredTodo.self).drain().map(\.todo)
    }

    public func find(id: String) async throws -> Todo? {
        try await todos.findOne(["_id": id], as: StoredTodo.self)?.todo
    }

    public func create(_ input: CreateTodo) async throws -> Todo {
        let stored = StoredTodo(id: UUID().uuidString, title: input.title, completed: false)
        _ = try await todos.insertEncoded(stored)
        return stored.todo
    }

    public func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard var todo = try await find(id: id) else { return nil }
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        _ = try await todos.upsertEncoded(StoredTodo(todo), where: ["_id": id])
        return todo
    }

    public func delete(id: String) async throws {
        _ = try await todos.deleteOne(where: ["_id": id])
    }
}

/// The stored document — `Todo` with its `id` mapped to MongoDB's `_id`.
private struct StoredTodo: Codable {
    let id: String
    var title: String
    var completed: Bool

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case title
        case completed
    }

    init(id: String, title: String, completed: Bool) {
        self.id = id
        self.title = title
        self.completed = completed
    }

    init(_ todo: Todo) {
        self.init(id: todo.id, title: todo.title, completed: todo.completed)
    }

    var todo: Todo { Todo(id: id, title: title, completed: completed) }
}
