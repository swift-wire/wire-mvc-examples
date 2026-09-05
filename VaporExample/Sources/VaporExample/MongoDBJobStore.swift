// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import Controllers
import MongoKitten
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's job store — the same real MongoDB the todos and sessions live in, working within its own
/// `jobs` collection over the graph-owned `MongoDatabase`. The third `@Singleton(as:)` backend binding
/// here, and the one this runtime had to build a `ServiceGroup` for: see `WireGraphServices` in
/// `configure.swift`.
///
/// A document store maps a ``JobRecord`` almost exactly — the whole record is one document keyed by `_id`,
/// so `update` is a single upsert and the sweep is a real server-side query rather than a client-side
/// filter. That last point is the one substantive difference between the three backends: Mongo can ask
/// "which jobs are unfinished", CouchDB needs a view (and this repository scans instead), and Valkey has
/// to walk an index.
@Singleton(as: JobStore.self)
struct MongoDBJobStore: JobStore {
    private let database: MongoDatabase

    private var jobs: MongoCollection { database["jobs"] }

    @Inject init(database: MongoDatabase) {
        self.database = database
    }

    /// A UUID rather than a counter. Mongo's own `ObjectId` would do as well and is what a Mongo-native
    /// design would reach for; a UUID keeps the id a plain `String` across all three backends, so the
    /// shared `JobRecord` needs no per-store id type.
    func enqueue(text: String) async throws -> JobRecord {
        let stored = StoredJob(JobRecord(id: UUID().uuidString, text: text, state: .queued))
        _ = try await jobs.insertEncoded(stored)
        return stored.record
    }

    func find(id: String) async throws -> JobRecord? {
        try await jobs.findOne(["_id": id], as: StoredJob.self)?.record
    }

    func update(_ record: JobRecord) async throws {
        _ = try await jobs.upsertEncoded(StoredJob(record), where: ["_id": record.id])
    }

    /// Queried, not filtered: the states are asked for by name, so the worker's recovery cost is a lookup
    /// rather than a full scan. `_id` order makes the recovered jobs come back in the order they were
    /// accepted, which is not required — the worker will run them in any order — but makes a failure
    /// easier to read.
    func unfinished() async throws -> [JobRecord] {
        try await jobs
            .find(["state": ["$in": [JobState.queued.rawValue, JobState.running.rawValue]]])
            .sort(["_id": 1])
            .decode(StoredJob.self)
            .drain()
            .map(\.record)
    }
}

/// The stored document — `JobRecord` with its `id` mapped to MongoDB's `_id`, the same treatment
/// `MongoDBTodoRepository` gives a todo.
private struct StoredJob: Codable {
    let id: String
    let text: String
    let state: JobState
    let summary: String?
    let failure: String?

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case text
        case state
        case summary
        case failure
    }

    init(_ record: JobRecord) {
        self.id = record.id
        self.text = record.text
        self.state = record.state
        self.summary = record.summary
        self.failure = record.failure
    }

    var record: JobRecord {
        JobRecord(id: id, text: text, state: state, summary: summary, failure: failure)
    }
}
