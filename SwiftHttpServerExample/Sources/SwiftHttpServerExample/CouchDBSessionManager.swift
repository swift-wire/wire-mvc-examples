package import Controllers
package import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's session store — the app `@Singleton(as: SessionManager.self)`, reaching the same CouchDB
/// the todos use over the graph-owned `ConfiguredHTTPClient` (injected under the CouchDB key via `@Bind`)
/// rooted at its own `sessions` database. A token maps to a document whose `_id` is the token; the session
/// id is minted once (on first sight) and read back thereafter, so the same token resolves to the same id
/// across requests.
@Singleton(as: SessionManager.self)
package struct CouchDBSessionManager: SessionManager {
    private let client: ConfiguredHTTPClient  // rooted at the sessions database
    private static let maximumBody = 1_000_000

    @Inject package init(@Bind(CouchDB.client) client: ConfiguredHTTPClient) async throws {
        self.client = client.rooted(at: "sessions")
        // Create the database (idempotent: 201 Created, or 412 Precondition Failed if it exists).
        let (response, _) = try await self.client.put(bodyData: Data(), collectUpTo: Self.maximumBody)
        guard response.status == .created || response.status == .preconditionFailed else {
            throw CouchDBError(status: response.status)
        }
    }

    package func sessionID(for token: String) async throws -> String {
        if let existing = try await storedID(for: token) { return existing }
        let created = UUID().uuidString
        if try await create(token: token, sessionID: created) { return created }
        // Lost a concurrent create (409 Conflict) — the winner's document is now authoritative.
        guard let winner = try await storedID(for: token) else {
            throw CouchDBError(status: .conflict)
        }
        return winner
    }

    /// The stored session id for `token`, or `nil` when no document exists yet.
    private func storedID(for token: String) async throws -> String? {
        let (response, data) = try await client.get(token, collectUpTo: Self.maximumBody)
        guard response.status == .ok else { return nil }
        return try JSONDecoder().decode(SessionDocument.self, from: data).sessionID
    }

    /// PUT a fresh session document; `true` if created, `false` on a 409 Conflict (someone else won).
    private func create(token: String, sessionID: String) async throws -> Bool {
        let (response, _) = try await client.put(
            token,
            bodyData: try JSONEncoder().encode(SessionBody(sessionID: sessionID)),
            collectUpTo: Self.maximumBody,
            json: true
        )
        switch response.status {
        case .created: return true
        case .conflict: return false
        default: throw CouchDBError(status: response.status)
        }
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
