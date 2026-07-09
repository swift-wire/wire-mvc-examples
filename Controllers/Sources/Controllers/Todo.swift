/// A todo item. Plain `Codable` — the controllers and repository are framework-free.
public struct Todo: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var completed: Bool

    public init(id: String, title: String, completed: Bool) {
        self.id = id
        self.title = title
        self.completed = completed
    }
}

/// The request body for creating a todo.
public struct CreateTodo: Codable, Sendable {
    public let title: String
}

/// The request body for editing a todo; each field is optional (partial update).
public struct EditTodo: Codable, Sendable {
    public let title: String?
    public let completed: Bool?
}
