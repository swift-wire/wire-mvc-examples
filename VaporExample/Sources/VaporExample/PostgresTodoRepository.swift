import Configuration
import Controllers
import Logging
import PostgresNIO
import Wire

/// The Vapor runtime's backend — a real PostgreSQL database. Like any real app, it reads its
/// connection from the environment (via swift-configuration) and owns a `PostgresClient` pool
/// through Wire's DI: `@Inject init` connects and creates the schema; `@Teardown` closes the pool
/// at shutdown. It does *not* provision the database — that's an operational concern (a real
/// Postgres for `swift run`, a throwaway container the test starts via swift-local-containers).
/// Here it's just another `@Singleton(as:)`, and the `@Teardown` on that opaquely-bound singleton
/// is exactly what wire-mvc-examples validates against swift-wire.
@Singleton(as: TodoRepository.self)
public final class PostgresTodoRepository: TodoRepository {
    private static let logger = Logger(label: "PostgresTodoRepository")

    private let client: PostgresClient
    private let runTask: Task<Void, Never>

    @Inject public init() async throws {
        // Connection config from the environment, 12-factor style. swift-configuration maps each
        // key to an env var (`database.host` → `DATABASE_HOST`, `database.port` → `DATABASE_PORT`,
        // …). The test exports the container's host/port that way; a real deployment sets them
        // however it manages configuration.
        let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
        client = PostgresClient(
            configuration: .init(
                host: config.string(forKey: "database.host", default: "localhost"),
                port: config.int(forKey: "database.port", default: 5432),
                username: config.string(forKey: "database.username", default: "postgres"),
                password: config.string(forKey: "database.password", isSecret: true, default: "postgres"),
                database: config.string(forKey: "database.name", default: "todos"),
                tls: .disable
            )
        )
        let client = client
        runTask = Task { await client.run() }

        let rows = try await client.query(
            """
            CREATE TABLE IF NOT EXISTS todo (
                id SERIAL PRIMARY KEY,
                title TEXT NOT NULL,
                completed BOOLEAN NOT NULL
            )
            """,
            logger: Self.logger
        )
        for try await _ in rows {}
    }

    @Teardown public func shutdown() async {
        runTask.cancel()
        await runTask.value
    }

    public func all() async throws -> [Todo] {
        let rows = try await client.query("SELECT id, title, completed FROM todo ORDER BY id", logger: Self.logger)
        var todos: [Todo] = []
        for try await (id, title, completed) in rows.decode((Int, String, Bool).self) {
            todos.append(Todo(id: "\(id)", title: title, completed: completed))
        }
        return todos
    }

    public func find(id: String) async throws -> Todo? {
        guard let rowID = Int(id) else { return nil }
        let rows = try await client.query(
            "SELECT id, title, completed FROM todo WHERE id = \(rowID)",
            logger: Self.logger
        )
        for try await (id, title, completed) in rows.decode((Int, String, Bool).self) {
            return Todo(id: "\(id)", title: title, completed: completed)
        }
        return nil
    }

    public func create(_ input: CreateTodo) async throws -> Todo {
        let rows = try await client.query(
            "INSERT INTO todo (title, completed) VALUES (\(input.title), \(false)) RETURNING id",
            logger: Self.logger
        )
        for try await id in rows.decode(Int.self) {
            return Todo(id: "\(id)", title: input.title, completed: false)
        }
        throw TodoNotFound()
    }

    public func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard let rowID = Int(id), var todo = try await find(id: id) else { return nil }
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        try await execute(
            "UPDATE todo SET title = \(todo.title), completed = \(todo.completed) WHERE id = \(rowID)"
        )
        return todo
    }

    public func delete(id: String) async throws {
        guard let rowID = Int(id) else { return }
        try await execute("DELETE FROM todo WHERE id = \(rowID)")
    }

    /// Run a statement that returns no rows, driving it to completion.
    private func execute(_ query: PostgresQuery) async throws {
        let rows = try await client.query(query, logger: Self.logger)
        for try await _ in rows {}
    }
}
