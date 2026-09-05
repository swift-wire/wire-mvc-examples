// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

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

    /// Explicit because a memberwise init is internal: these are decoded from a request body here, but
    /// `OpenAPISpec` constructs them when it maps the document's schemas onto this domain.
    public init(title: String) {
        self.title = title
    }
}

/// The request body for editing a todo; each field is optional (partial update).
public struct EditTodo: Codable, Sendable {
    public let title: String?
    public let completed: Bool?

    public init(title: String?, completed: Bool?) {
        self.title = title
        self.completed = completed
    }
}
