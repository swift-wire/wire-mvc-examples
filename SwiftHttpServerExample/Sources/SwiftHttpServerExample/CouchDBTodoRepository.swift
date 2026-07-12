import AHCHTTPClient
import AsyncHTTPClient
import Controllers
import HTTPAPIs
import HTTPTypes
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's backend — a real CouchDB, reached over HTTP with the *proposal's own* client. The
/// proposal defines an `HTTPClient` protocol with pluggable backends; here we use the async-http-client
/// backend (`AHCHTTPClient`) explicitly rather than `HTTP.get`/`DefaultHTTPClient.shared`, because the
/// platform default is URLSession-backed on macOS and that backend currently hangs collecting keep-alive
/// responses on the nightly toolchain — worth reporting upstream. Pinning the async-http-client backend
/// keeps the same proposal call surface (`get`/`put`/`delete`) and works on both macOS and Linux.
///
/// CouchDB is a document store with a pure HTTP/JSON API (distinct from Hummingbird's embedded SQL and
/// Vapor's MongoDB), so there's no specialised driver — just requests and `Codable`.
/// `@Singleton(as: TodoRepository.self)` binds it; the database is provisioned by the test's container.
@Singleton(as: TodoRepository.self)
final class CouchDBTodoRepository: TodoRepository {
    private let baseURL: String  // http://host:port/todos
    private let authorization: String
    private static let maximumBody = 1_000_000

    /// The process-wide async-http-client, reused across requests. It needs no explicit shutdown.
    private var client: AsyncHTTPClient.HTTPClient { .shared }

    @Inject init() async throws {
        // Connection config from the environment, 12-factor style — the test exports the container's
        // host/port that way; a real deployment sets them however it manages configuration.
        let environment = ProcessInfo.processInfo.environment
        let host = environment["COUCHDB_HOST"] ?? "localhost"
        let port = environment["COUCHDB_PORT"] ?? "5984"
        let user = environment["COUCHDB_USER"] ?? "admin"
        let password = environment["COUCHDB_PASSWORD"] ?? "password"
        baseURL = "http://\(host):\(port)/todos"
        authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()

        // Create the database (idempotent: 201 Created, or 412 Precondition Failed if it exists).
        var client = client
        let (response, _) = try await client.put(
            url: URL(string: baseURL)!,
            headerFields: headers(),
            bodyData: Data(),
            collectUpTo: Self.maximumBody
        )
        guard response.status == .created || response.status == .preconditionFailed else {
            throw CouchDBError(status: response.status)
        }
    }

    func all() async throws -> [Todo] {
        var client = client
        let (response, data) = try await client.get(
            url: URL(string: "\(baseURL)/_all_docs?include_docs=true")!,
            headerFields: headers(),
            collectUpTo: Self.maximumBody
        )
        guard response.status == .ok else { throw CouchDBError(status: response.status) }
        return try JSONDecoder().decode(AllDocuments.self, from: data).rows.map(\.doc.todo)
    }

    func find(id: String) async throws -> Todo? {
        try await fetch(id: id)?.todo
    }

    func create(_ input: CreateTodo) async throws -> Todo {
        let todo = Todo(id: UUID().uuidString, title: input.title, completed: false)
        try await putDocument(id: todo.id, body: DocumentBody(rev: nil, title: todo.title, completed: todo.completed))
        return todo
    }

    func update(id: String, with input: EditTodo) async throws -> Todo? {
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

    func delete(id: String) async throws {
        guard let document = try await fetch(id: id) else { return }
        var client = client
        _ = try await client.delete(
            url: URL(string: "\(baseURL)/\(id)?rev=\(document.rev)")!,
            headerFields: headers(),
            collectUpTo: Self.maximumBody
        )
    }

    // MARK: - Helpers

    /// Fetch the raw document (with its `_rev`, needed to update or delete).
    private func fetch(id: String) async throws -> StoredDocument? {
        var client = client
        let (response, data) = try await client.get(
            url: URL(string: "\(baseURL)/\(id)")!,
            headerFields: headers(),
            collectUpTo: Self.maximumBody
        )
        guard response.status == .ok else { return nil }
        return try JSONDecoder().decode(StoredDocument.self, from: data)
    }

    /// PUT a document (create when `body.rev` is nil, update otherwise).
    private func putDocument(id: String, body: DocumentBody) async throws {
        var client = client
        let (response, _) = try await client.put(
            url: URL(string: "\(baseURL)/\(id)")!,
            headerFields: jsonHeaders(),
            bodyData: try JSONEncoder().encode(body),
            collectUpTo: Self.maximumBody
        )
        guard response.status == .created else { throw CouchDBError(status: response.status) }
    }

    private func headers() -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = authorization
        return fields
    }

    private func jsonHeaders() -> HTTPFields {
        var fields = headers()
        fields[.contentType] = "application/json"
        return fields
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

private struct CouchDBError: Error {
    let status: HTTPResponse.Status
}
