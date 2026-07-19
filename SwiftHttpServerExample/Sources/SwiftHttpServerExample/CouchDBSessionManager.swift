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

/// This runtime's session store — the app `@Singleton(as: SessionManager.self)`, backed by the same real
/// CouchDB the todos use, in its own `sessions` database. A token maps to a document whose `_id` is the
/// token; the session id is minted once (on first sight) and read back thereafter, so the same token
/// resolves to the same id across requests. Self-contained like `CouchDBTodoRepository` (the process-wide
/// async-http-client, env-driven config), binding via the same opaque-lift pattern.
@Singleton(as: SessionManager.self)
final class CouchDBSessionManager: SessionManager {
    private let baseURL: String  // http://host:port/sessions
    private let authorization: String
    private static let maximumBody = 1_000_000

    private var client: AsyncHTTPClient.HTTPClient { .shared }

    @Inject init() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["COUCHDB_HOST"] ?? "localhost"
        let port = environment["COUCHDB_PORT"] ?? "5984"
        let user = environment["COUCHDB_USER"] ?? "admin"
        let password = environment["COUCHDB_PASSWORD"] ?? "password"
        baseURL = "http://\(host):\(port)/sessions"
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
            throw CouchDBSessionError(status: response.status)
        }
    }

    func sessionID(for token: String) async throws -> String {
        if let existing = try await storedID(for: token) { return existing }
        let created = UUID().uuidString
        if try await create(token: token, sessionID: created) { return created }
        // Lost a concurrent create (409 Conflict) — the winner's document is now authoritative.
        guard let winner = try await storedID(for: token) else {
            throw CouchDBSessionError(status: .conflict)
        }
        return winner
    }

    /// The stored session id for `token`, or `nil` when no document exists yet.
    private func storedID(for token: String) async throws -> String? {
        var client = client
        let (response, data) = try await client.get(
            url: URL(string: "\(baseURL)/\(token)")!,
            headerFields: headers(),
            collectUpTo: Self.maximumBody
        )
        guard response.status == .ok else { return nil }
        return try JSONDecoder().decode(SessionDocument.self, from: data).sessionID
    }

    /// PUT a fresh session document; `true` if created, `false` on a 409 Conflict (someone else won).
    private func create(token: String, sessionID: String) async throws -> Bool {
        var client = client
        let (response, _) = try await client.put(
            url: URL(string: "\(baseURL)/\(token)")!,
            headerFields: jsonHeaders(),
            bodyData: try JSONEncoder().encode(SessionBody(sessionID: sessionID)),
            collectUpTo: Self.maximumBody
        )
        switch response.status {
        case .created: return true
        case .conflict: return false
        default: throw CouchDBSessionError(status: response.status)
        }
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

/// A session document as read back — just the minted id (CouchDB's `_id` is the token).
private struct SessionDocument: Decodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

/// The body written on create.
private struct SessionBody: Encodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

private struct CouchDBSessionError: Error {
    let status: HTTPResponse.Status
}
