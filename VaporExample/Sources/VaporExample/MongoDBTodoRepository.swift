import Configuration
import Controllers
import MongoKitten
import Wire
import WireConfiguration

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The MongoDB connection, owned by the graph and shared by every backend that talks to it — the todo
/// repository and the session store both inject the `MongoDatabase`, so the cluster is connected once (its
/// endpoint read from the environment) and disconnected once. The producer-form `@Teardown` releases the
/// cluster at shutdown; wire-mvc-examples validates that teardown runs against swift-wire. Each consumer
/// works within its own collection (`todos`, `sessions`).
@Provides
@Teardown({ (database: MongoDatabase) in await (database.pool as? MongoCluster)?.disconnect() })
func provideMongoDatabase(
    @ConfigProperty(forKey: "mongo.host", default: "localhost") host: String,
    @ConfigProperty(forKey: "mongo.port", default: 27017) port: Int
) async throws -> MongoDatabase {
    // Connection settings come from the graph's shared `ConfigReader`, injected like any other dependency
    // rather than constructed here. swift-configuration maps each key to an env var (`mongo.host` →
    // `MONGO_HOST`), so the deployment contract is unchanged; what changes is that the reader is visible in
    // the graph and substitutable in a test.
    return try await MongoDatabase.connect(to: "mongodb://\(host):\(port)/todos")
}

/// This runtime's todo backend — a real MongoDB, a document store (distinct from Hummingbird's Valkey and
/// the proposal runtime's CouchDB). It talks to the store through the graph-owned `MongoDatabase` (shared
/// with the session store), working within its `todos` collection. `@Singleton(as: TodoRepository.self)`
/// binds it as the controller's repository.
@Singleton(as: TodoRepository.self)
struct MongoDBTodoRepository: TodoRepository {
    private let database: MongoDatabase

    private var todos: MongoCollection { database["todos"] }

    @Inject init(database: MongoDatabase) {
        self.database = database
    }

    func all() async throws -> [Todo] {
        try await todos.find().sort(["_id": 1]).decode(StoredTodo.self).drain().map(\.todo)
    }

    func find(id: String) async throws -> Todo? {
        try await todos.findOne(["_id": id], as: StoredTodo.self)?.todo
    }

    func create(_ input: CreateTodo) async throws -> Todo {
        let stored = StoredTodo(id: UUID().uuidString, title: input.title, completed: false)
        _ = try await todos.insertEncoded(stored)
        return stored.todo
    }

    func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard var todo = try await find(id: id) else { return nil }
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        _ = try await todos.upsertEncoded(StoredTodo(todo), where: ["_id": id])
        return todo
    }

    func delete(id: String) async throws {
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
