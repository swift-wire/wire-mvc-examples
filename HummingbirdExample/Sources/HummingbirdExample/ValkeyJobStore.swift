// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Controllers
import Valkey
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's job store — the same real Valkey the todos live in, over the same graph-owned
/// `ValkeyClient` whose connection pool the `ServiceGroup` already runs. So this app now hands that group
/// two services that need each other: the client, and the `JobWorker` that reads through it.
///
/// **That ordering is worth knowing and is not guaranteed.** A `ServiceGroup` starts its services
/// concurrently, so the worker's sweep can run before the client's pool is up. `valkey-swift` connects on
/// demand rather than requiring a started pool, so the read waits rather than failing — but a client that
/// *did* require it would want `ServiceGroupConfiguration` ordering, which is the general answer and more
/// machinery than this example needs.
///
/// Each job is a JSON string under `job:<id>`; ids come from `INCR jobs:seq` and the ids in play are kept
/// in a `jobs` list, the same three-key shape `ValkeyTodoRepository` uses.
@Singleton(as: JobStore.self)
struct ValkeyJobStore: JobStore {
    private let client: ValkeyClient
    private static let index = ValkeyKey("jobs")  // list of ids, insertion order
    private static let sequence = ValkeyKey("jobs:seq")  // INCR counter → job ids

    @Inject init(client: ValkeyClient) {
        self.client = client
    }

    /// **The store issues the id, and here it is genuinely the store doing it** — `INCR` is atomic across
    /// clients, so two instances enqueueing at once cannot collide. That is the property a process-local
    /// counter silently lacks, and the reason ``JobStore/enqueue(text:)`` returns the record rather than
    /// taking one.
    func enqueue(text: String) async throws -> JobRecord {
        let id = try await client.incr(Self.sequence)
        let record = JobRecord(id: String(id), text: text, state: .queued)
        try await store(record)
        _ = try await client.rpush(Self.index, elements: [record.id])
        return record
    }

    func find(id: String) async throws -> JobRecord? {
        guard let stored = try await client.get(Self.key(id)) else { return nil }
        return try JSONDecoder().decode(JobRecord.self, from: Data(stored))
    }

    /// One round trip: the record is written whole, and a key-value store has no revision to reconcile
    /// against — the write CouchDB needs two calls for.
    func update(_ record: JobRecord) async throws {
        try await store(record)
    }

    /// Walks the index rather than scanning the keyspace, because `KEYS` blocks the server and `SCAN`
    /// gives no ordering — the same reason `ValkeyTodoRepository.all()` keeps a list. A deployment with
    /// many jobs would keep a *second* list of the unfinished ones and pop from it, which is what a Valkey
    /// job queue really looks like; this walks all of them because the example's point is the lifecycle.
    func unfinished() async throws -> [JobRecord] {
        var unfinished: [JobRecord] = []
        for token in try await client.lrange(Self.index, start: 0, stop: -1) {
            guard let record = try await find(id: try token.decode(as: String.self)) else { continue }
            if record.state == .queued || record.state == .running { unfinished.append(record) }
        }
        return unfinished
    }

    private func store(_ record: JobRecord) async throws {
        _ = try await client.set(Self.key(record.id), value: try JSONEncoder().encode(record))
    }

    private static func key(_ id: String) -> ValkeyKey { ValkeyKey("job:\(id)") }
}
