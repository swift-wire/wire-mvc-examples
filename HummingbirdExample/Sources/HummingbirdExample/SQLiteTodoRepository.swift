import Controllers
import GRDB
import Wire

/// The Hummingbird runtime's backend — an embedded SQLite database via GRDB. In-memory, so the
/// example needs no external infra, but it's a *real* backend: an actual schema, SQL, and
/// prepared statements behind the same `TodoRepository` protocol another runtime satisfies with
/// a different store. `@Singleton(as: TodoRepository.self)` binds it as the controller's repository.
@Singleton(as: TodoRepository.self)
public final class SQLiteTodoRepository: TodoRepository {
    private let queue: DatabaseQueue

    @Inject public init() throws {
        queue = try DatabaseQueue()  // in-memory SQLite
        try queue.write { database in
            try database.create(table: "todo") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("title", .text).notNull()
                table.column("completed", .boolean).notNull()
            }
        }
    }

    public func all() async throws -> [Todo] {
        try await queue.read { database in
            try Row.fetchAll(database, sql: "SELECT id, title, completed FROM todo ORDER BY id").map(Self.todo)
        }
    }

    public func find(id: String) async throws -> Todo? {
        guard let rowID = Int64(id) else { return nil }
        return try await queue.read { database in
            try Row.fetchOne(database, sql: "SELECT id, title, completed FROM todo WHERE id = ?", arguments: [rowID])
                .map(Self.todo)
        }
    }

    public func create(_ input: CreateTodo) async throws -> Todo {
        try await queue.write { database in
            try database.execute(
                sql: "INSERT INTO todo (title, completed) VALUES (?, ?)",
                arguments: [input.title, false]
            )
            return Todo(id: "\(database.lastInsertedRowID)", title: input.title, completed: false)
        }
    }

    public func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard let rowID = Int64(id) else { return nil }
        return try await queue.write { database in
            let existing = try Row.fetchOne(
                database,
                sql: "SELECT id, title, completed FROM todo WHERE id = ?",
                arguments: [rowID]
            )
            guard var todo = existing.map(Self.todo) else { return nil }
            if let title = input.title { todo.title = title }
            if let completed = input.completed { todo.completed = completed }
            try database.execute(
                sql: "UPDATE todo SET title = ?, completed = ? WHERE id = ?",
                arguments: [todo.title, todo.completed, rowID]
            )
            return todo
        }
    }

    public func delete(id: String) async throws {
        guard let rowID = Int64(id) else { return }
        try await queue.write { database in
            try database.execute(sql: "DELETE FROM todo WHERE id = ?", arguments: [rowID])
        }
    }

    private static func todo(_ row: Row) -> Todo {
        let id: Int64 = row["id"]
        return Todo(id: "\(id)", title: row["title"], completed: row["completed"])
    }
}
