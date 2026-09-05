// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import Controllers
import Synchronization
import Wire

/// The mocked suite's ``JobStore`` — and the one binding in this target that is `@Replaces` rather than
/// `@BindType`.
///
/// **The distinction is structural, not stylistic.** `@BindType` sources its instance from a `doubles`
/// value threaded into a *scope at entry*, so it reaches a binding that is built (or rebuilt, via
/// `@TestScopable`) per request. `JobWorker` is neither: it is app-scoped by necessity, since the
/// `ServiceGroup` runs the same instance for the process's lifetime, and it reads its store outside any
/// request — the sweep in `run()` happens before a request has ever arrived. There is no request to hang
/// a double off. So a background service's collaborators are `@Replaces` territory: a real binding in the
/// test target that supersedes the app's, rather than a mock threaded per test.
///
/// The practical consequence is that this suite cannot `verify` interactions with the store the way
/// `MockedRoutingTests` does with the repository. It asserts on behaviour through the routes instead,
/// which is the right level for a worker anyway — what matters is that the job ran, not which calls it
/// made getting there.
///
/// `static` state because `@Replaces` supersedes the *binding*, and Wire constructs the replacement once
/// per graph; the suite's tests share one store exactly as they would share one database.
@Singleton(as: JobStore.self)
@Replaces
struct InMemoryJobStore: JobStore {
    private static let state = Mutex<(records: [String: JobRecord], next: Int)>(([:], 1))

    func enqueue(text: String) async throws -> JobRecord {
        Self.state.withLock { state in
            let record = JobRecord(id: String(state.next), text: text, state: .queued)
            state.next += 1
            state.records[record.id] = record
            return record
        }
    }

    func find(id: String) async throws -> JobRecord? {
        Self.state.withLock { $0.records[id] }
    }

    func update(_ record: JobRecord) async throws {
        Self.state.withLock { $0.records[record.id] = record }
    }

    func unfinished() async throws -> [JobRecord] {
        Self.state.withLock { state in
            state.records.values.filter { $0.state == .queued || $0.state == .running }
        }
    }
}
