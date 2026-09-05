// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Controllers
import MongoKitten
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's session store — the app `@Singleton(as: SessionManager.self)`, reaching the same MongoDB
/// the todos use through the graph-owned `MongoDatabase`, in its own `sessions` collection. A token maps to
/// a document whose `_id` is the token; the session id is minted once (on first sight) and read back
/// thereafter, so the same token resolves to the same id across requests.
@Singleton(as: SessionManager.self)
struct MongoDBSessionManager: SessionManager {
    private let database: MongoDatabase

    private var sessions: MongoCollection { database["sessions"] }

    @Inject init(database: MongoDatabase) {
        self.database = database
    }

    func sessionID(for token: String) async throws -> String {
        if let existing = try await sessions.findOne(["_id": token], as: StoredSession.self) {
            return existing.sessionID
        }
        let created = StoredSession(id: token, sessionID: UUID().uuidString)
        do {
            _ = try await sessions.insertEncoded(created)
            return created.sessionID
        } catch {
            // Lost a concurrent insert (duplicate `_id`) — the winner's document is authoritative.
            guard let winner = try await sessions.findOne(["_id": token], as: StoredSession.self) else {
                throw error
            }
            return winner.sessionID
        }
    }
}

/// The stored session document — the minted id keyed by the token in MongoDB's `_id`.
private struct StoredSession: Codable {
    let id: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case sessionID
    }
}
