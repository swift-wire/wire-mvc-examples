// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

package import Controllers
// `MemberImportVisibility`: this file reads `HTTPResponse.Status` members, so it must import their
// defining module itself rather than relying on one reaching it transitively.
import HTTPTypes
package import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's todo backend — a real CouchDB, a document store (distinct from Hummingbird's Valkey and
/// Vapor's MongoDB). It reaches the store over the graph-owned `ConfiguredHTTPClient` (injected under the
/// CouchDB key via `@Bind`, shared with the session store) rooted at its own `todos` database.
/// `@Singleton(as: TodoRepository.self)` binds it as the controller's repository.
@Singleton(as: TodoRepository.self)
package struct CouchDBTodoRepository: TodoRepository {
    private let client: ConfiguredHTTPClient  // rooted at the todos database
    private static let maximumBody = 1_000_000

    @Inject package init(@Bind(CouchDB.client) client: ConfiguredHTTPClient) async throws {
        self.client = client.rooted(at: "todos")
        // Create the database (idempotent: 201 Created, or 412 Precondition Failed if it exists).
        let (response, _) = try await self.client.put(bodyData: Data(), collectUpTo: Self.maximumBody)
        guard response.status == .created || response.status == .preconditionFailed else {
            throw CouchDBError(status: response.status)
        }
    }

    package func all() async throws -> [Todo] {
        let (response, data) = try await client.get("_all_docs?include_docs=true", collectUpTo: Self.maximumBody)
        guard response.status == .ok else { throw CouchDBError(status: response.status) }
        return try JSONDecoder().decode(AllDocuments.self, from: data).rows.map(\.doc.todo)
    }

    package func find(id: String) async throws -> Todo? {
        try await fetch(id: id)?.todo
    }

    package func create(_ input: CreateTodo) async throws -> Todo {
        let todo = Todo(id: UUID().uuidString, title: input.title, completed: false)
        try await putDocument(id: todo.id, body: DocumentBody(rev: nil, title: todo.title, completed: todo.completed))
        return todo
    }

    package func update(id: String, with input: EditTodo) async throws -> Todo? {
        guard let document = try await fetch(id: id) else { return nil }
        var todo = document.todo
        if let title = input.title { todo.title = title }
        if let completed = input.completed { todo.completed = completed }
        try await putDocument(
            id: id,
            body: DocumentBody(rev: document.rev, title: todo.title, completed: todo.completed)
        )
        return todo
    }

    package func delete(id: String) async throws {
        guard let document = try await fetch(id: id) else { return }
        _ = try await client.delete("\(id)?rev=\(document.rev)", collectUpTo: Self.maximumBody)
    }

    // MARK: - Helpers

    /// Fetch the raw document (with its `_rev`, needed to update or delete).
    private func fetch(id: String) async throws -> StoredDocument? {
        let (response, data) = try await client.get(id, collectUpTo: Self.maximumBody)
        guard response.status == .ok else { return nil }
        return try JSONDecoder().decode(StoredDocument.self, from: data)
    }

    /// PUT a document (create when `body.rev` is nil, update otherwise).
    private func putDocument(id: String, body: DocumentBody) async throws {
        let (response, _) = try await client.put(
            id,
            bodyData: try JSONEncoder().encode(body),
            collectUpTo: Self.maximumBody,
            json: true
        )
        guard response.status == .created else { throw CouchDBError(status: response.status) }
    }
}

/// A CouchDB document as read back — the todo fields plus CouchDB's `_id`/`_rev`.
private struct StoredDocument: Decodable {
    let id: String
    let rev: String
    let title: String
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case rev = "_rev"
        case title
        case completed
    }

    var todo: Todo { Todo(id: id, title: title, completed: completed) }
}

/// The body written on create/update. `_rev` is present only for updates (CouchDB rejects it on
/// create), so it's omitted when nil.
private struct DocumentBody: Encodable {
    let rev: String?
    let title: String
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case rev = "_rev"
        case title
        case completed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rev, forKey: .rev)
        try container.encode(title, forKey: .title)
        try container.encode(completed, forKey: .completed)
    }
}

/// The `_all_docs?include_docs=true` response shape.
private struct AllDocuments: Decodable {
    let rows: [Row]

    struct Row: Decodable {
        let doc: StoredDocument
    }
}
