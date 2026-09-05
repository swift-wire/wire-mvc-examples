// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

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

/// This runtime's job store — the same real CouchDB the todos and sessions live in, rooted at its own
/// `jobs` database. The third `@Singleton(as:)` backend binding in this app, alongside `TodoRepository`
/// and `SessionManager`, over the one graph-owned `ConfiguredHTTPClient`.
///
/// **What the store being real changes** is not the routes — it is that a job survives the process. A
/// record written by `enqueue` is still `queued` after a restart, which is what
/// ``Controllers/JobWorker/run()``'s sweep reads, and what makes the `202` a promise the deployment can
/// keep rather than one the process can.
@Singleton(as: JobStore.self)
package struct CouchDBJobStore: JobStore {
    private let client: ConfiguredHTTPClient  // rooted at the jobs database
    private static let maximumBody = 1_000_000

    @Inject package init(@Bind(CouchDB.client) client: ConfiguredHTTPClient) async throws {
        self.client = client.rooted(at: "jobs")
        // Create the database (idempotent: 201 Created, or 412 Precondition Failed if it exists) — the
        // same handshake the todo repository does, and for the same reason: a fresh container has none.
        let (response, _) = try await self.client.put(bodyData: Data(), collectUpTo: Self.maximumBody)
        guard response.status == .created || response.status == .preconditionFailed else {
            throw CouchDBError(status: response.status)
        }
    }

    /// The id is a UUID rather than a counter, matching `CouchDBTodoRepository.create`. CouchDB has no
    /// server-side sequence, and a counter held in the process would mean two instances issuing the same
    /// ids — which is precisely the assumption a durable store exists to remove.
    package func enqueue(text: String) async throws -> JobRecord {
        let record = JobRecord(id: UUID().uuidString, text: text, state: .queued)
        try await put(record, rev: nil)
        return record
    }

    package func find(id: String) async throws -> JobRecord? {
        try await fetch(id: id)?.record
    }

    /// **A read before every write**, because CouchDB rejects a `PUT` without the document's current
    /// `_rev`. So a store update here is two round trips where Mongo's and Valkey's are one — the cost of
    /// document-level MVCC, and the reason `update` takes a whole record rather than a mutation to apply:
    /// the worker has already computed what it wants written, and this only has to find the revision to
    /// write it against.
    package func update(_ record: JobRecord) async throws {
        try await put(record, rev: try await fetch(id: record.id)?.rev)
    }

    /// Scanned client-side rather than through a CouchDB view, which is what `_all_docs` is for and what
    /// the todo repository already does. A real deployment with a large `jobs` database wants a view
    /// emitting on `state` — this is an example about lifecycles, not about indexing.
    package func unfinished() async throws -> [JobRecord] {
        let (response, data) = try await client.get("_all_docs?include_docs=true", collectUpTo: Self.maximumBody)
        guard response.status == .ok else { throw CouchDBError(status: response.status) }
        return try JSONDecoder().decode(AllJobDocuments.self, from: data).rows
            .map(\.doc.record)
            .filter { $0.state == .queued || $0.state == .running }
    }

    // MARK: - Helpers

    private func fetch(id: String) async throws -> StoredJob? {
        let (response, data) = try await client.get(id, collectUpTo: Self.maximumBody)
        guard response.status == .ok else { return nil }
        return try JSONDecoder().decode(StoredJob.self, from: data)
    }

    private func put(_ record: JobRecord, rev: String?) async throws {
        let (response, _) = try await client.put(
            record.id,
            bodyData: try JSONEncoder().encode(JobDocumentBody(rev: rev, record: record)),
            collectUpTo: Self.maximumBody,
            json: true
        )
        guard response.status == .created else { throw CouchDBError(status: response.status) }
    }
}

/// A job document as read back — the record's fields plus CouchDB's `_id`/`_rev`.
private struct StoredJob: Decodable {
    let id: String
    let rev: String
    let text: String
    let state: JobState
    let summary: String?
    let failure: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case rev = "_rev"
        case text
        case state
        case summary
        case failure
    }

    var record: JobRecord {
        JobRecord(id: id, text: text, state: state, summary: summary, failure: failure)
    }
}

/// The body written on create and update. `_rev` is present only for an update (CouchDB rejects it on a
/// create), so it is omitted when nil — the same shape `CouchDBTodoRepository` writes.
private struct JobDocumentBody: Encodable {
    let rev: String?
    let record: JobRecord

    enum CodingKeys: String, CodingKey {
        case rev = "_rev"
        case text
        case state
        case summary
        case failure
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rev, forKey: .rev)
        try container.encode(record.text, forKey: .text)
        try container.encode(record.state, forKey: .state)
        try container.encodeIfPresent(record.summary, forKey: .summary)
        try container.encodeIfPresent(record.failure, forKey: .failure)
    }
}

/// The `_all_docs?include_docs=true` response shape, for the sweep.
private struct AllJobDocuments: Decodable {
    let rows: [Row]

    struct Row: Decodable {
        let doc: StoredJob
    }
}
