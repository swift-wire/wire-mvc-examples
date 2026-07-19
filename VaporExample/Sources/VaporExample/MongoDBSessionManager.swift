import Configuration
import Controllers
import MongoKitten
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's session store — the app `@Singleton(as: SessionManager.self)`, backed by the same real
/// MongoDB the todos use, in its own `sessions` collection. A token maps to a document whose `_id` is the
/// token; the id is minted once (on first sight) and read back thereafter, so the same token resolves to
/// the same id across requests. Self-contained like `MongoDBTodoRepository` (its own connection released by
/// `@Teardown`), binding via the same opaque-lift pattern — a second opaquely-bound singleton whose
/// teardown wire-mvc-examples also validates.
@Singleton(as: SessionManager.self)
public final class MongoDBSessionManager: SessionManager {
    private let database: MongoDatabase

    private var sessions: MongoCollection { database["sessions"] }

    @Inject public init() async throws {
        let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
        let host = config.string(forKey: "mongo.host", default: "localhost")
        let port = config.int(forKey: "mongo.port", default: 27017)
        database = try await MongoDatabase.connect(to: "mongodb://\(host):\(port)/todos")
    }

    @Teardown public func shutdown() async {
        await (database.pool as? MongoCluster)?.disconnect()
    }

    public func sessionID(for token: String) async throws -> String {
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
