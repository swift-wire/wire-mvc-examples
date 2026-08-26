import Logging
import ServiceLifecycle
import Synchronization
import Testing

@testable import Controllers

/// An in-memory ``JobStore``, standing in for a runtime's database. Records what was written and in what
/// order, because two of the tests below are about ordering rather than about outcome.
final class RecordingJobStore: JobStore, Sendable {
    struct State {
        var records: [String: JobRecord] = [:]
        var next = 1
        /// Every `update`, in order — the claim writes and the outcome writes both land here.
        var writes: [JobRecord] = []
    }

    let state = Mutex(State())

    /// Seed a record as a previous process would have left it, without going through `enqueue`.
    func seed(_ record: JobRecord) {
        state.withLock { $0.records[record.id] = record }
    }

    func enqueue(text: String) async throws -> JobRecord {
        state.withLock { state in
            let record = JobRecord(id: String(state.next), text: text, state: .queued)
            state.next += 1
            state.records[record.id] = record
            return record
        }
    }

    func find(id: String) async throws -> JobRecord? {
        state.withLock { $0.records[id] }
    }

    func update(_ record: JobRecord) async throws {
        state.withLock { state in
            state.records[record.id] = record
            state.writes.append(record)
        }
    }

    func unfinished() async throws -> [JobRecord] {
        state.withLock { state in
            state.records.values
                .filter { $0.state == .queued || $0.state == .running }
                .sorted { $0.id < $1.id }
        }
    }
}

/// The worker's own behaviour, driven directly — no graph, no server, no database.
///
/// It is here rather than in a runtime's suite because every property below belongs to the
/// `ServiceGroup` or to the store, not to HTTP. `withGracefulShutdownHandler` is armed *only* inside a
/// group, so outside one the drain is unobservable and the loop looks identical to a plain `for await`; a
/// route suite could show that a job completes, and only a group can show *which* jobs complete when the
/// process is going away.
@Suite("Job worker")
struct JobWorkerTests {
    private func waitForTerminalState(of id: String, in store: RecordingJobStore) async throws -> JobRecord {
        for _ in 0..<5_000 {
            if let record = try await store.find(id: id), record.state == .completed || record.state == .failed {
                return record
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("job \(id) never reached a terminal state")
        return try #require(await store.find(id: id))
    }

    /// **The record is durable before `submit` returns.** Asserted without running the worker at all,
    /// which is the only way to see it: with a worker draining, every ordering looks the same from
    /// outside. No group here, so nothing consumes the handoff — and the store still has the job.
    @Test func submitWritesTheRecordBeforeItReturns() async throws {
        let store = RecordingJobStore()
        let worker = JobWorker(store: store)

        let accepted = try await worker.submit(JobSubmission(text: "the cat sat on the mat"))
        #expect(accepted.state == .queued)
        #expect(accepted.summary == nil)
        #expect(try await store.find(id: accepted.id) == accepted, "the 202's body is what the store holds")
    }

    /// The boundary check is `submit`'s, and it runs before the store is touched — so a rejected
    /// submission leaves nothing behind, not even an abandoned `queued` row.
    @Test func emptyTextIsRefusedBeforeTheStoreIsTouched() async throws {
        let store = RecordingJobStore()
        let worker = JobWorker(store: store)

        await #expect(throws: EmptySubmission.self) { try await worker.submit(JobSubmission(text: "")) }
        #expect(store.state.withLock { $0.records.isEmpty })
        await #expect(throws: JobNotFound.self) { try await worker.record(id: "1") }
    }

    /// The load-bearing test: **everything accepted before shutdown runs, and nothing is accepted after.**
    ///
    /// Two steps are not obvious. The **probe job first**, awaited to completion, because
    /// `ServiceGroup.triggerGracefulShutdown()` on a group still in `.initial` transitions it straight to
    /// `.finished` and the pending `run()` then throws `alreadyFinished` — a test that triggers before the
    /// group is genuinely running measures nothing and fails confusingly. And the batch is submitted
    /// **before** the trigger and needs no synchronisation after it, because `submit` yields into the
    /// stream's unbounded buffer, so by the time shutdown is triggered all fifty are buffered.
    @Test func gracefulShutdownDrainsWhatWasAlreadyAccepted() async throws {
        let store = RecordingJobStore()
        let worker = JobWorker(store: store)
        let group = ServiceGroup(services: [worker], logger: Logger(label: "test"))

        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }

            let probe = try await worker.submit(JobSubmission(text: "probe"))
            #expect(try await waitForTerminalState(of: probe.id, in: store).state == .completed)

            // `batch` twice so the summary is a fact about the job's own text rather than about the
            // tie-break: a bare `"batch \($0)"` would summarise to the *number*, which sorts first.
            var batch: [JobRecord] = []
            for index in 1...50 {
                batch.append(try await worker.submit(JobSubmission(text: "batch \(index) batch")))
            }
            #expect(batch.allSatisfy { $0.state == .queued })

            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()

            // `run()` has returned, so the drain is over — no polling, no tolerance.
            for accepted in batch {
                let record = try #require(await store.find(id: accepted.id))
                #expect(record.state == .completed, "job \(accepted.id) was accepted and then dropped")
                #expect(record.summary == "batch:2")
            }
        }

        // And the other half of the contract: the door is shut, with the status that says "retry".
        await #expect(throws: QueueClosed.self) { try await worker.submit(JobSubmission(text: "too late")) }
    }

    /// **The sweep**, which is what makes the store more than a log of what this process did. A job left
    /// `queued` by a previous process was accepted and never handed over; one left `running` was started
    /// and lost. Both are recovered through the same handoff before the loop takes anything new, and the
    /// `running` case is what makes the contract at-least-once.
    @Test func unfinishedWorkFromAPreviousProcessIsRecovered() async throws {
        let store = RecordingJobStore()
        store.seed(JobRecord(id: "100", text: "never handed over", state: .queued))
        store.seed(JobRecord(id: "101", text: "started and lost", state: .running))
        store.seed(JobRecord(id: "102", text: "already done done", state: .completed, summary: "done:2"))

        let worker = JobWorker(store: store)
        let group = ServiceGroup(services: [worker], logger: Logger(label: "test"))

        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }

            // "never handed over" — three words, one each, so the tie breaks alphabetically.
            #expect(try await waitForTerminalState(of: "100", in: store).summary == "handed:1")
            #expect(try await waitForTerminalState(of: "101", in: store).summary == "and:1")

            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }

        // A finished job is not swept — `unfinished()` is the filter, and re-running completed work is
        // the failure mode a sweep that took everything would have.
        #expect(store.state.withLock { $0.writes.allSatisfy { $0.id != "102" } })
    }

    /// A job is **claimed before it is worked**, which is what a later sweep reads to tell "never started"
    /// from "started and lost". Asserted on the write log rather than by polling, because the `running`
    /// state is by nature something a poll only catches by luck.
    @Test func aJobIsClaimedRunningBeforeItsOutcomeIsWritten() async throws {
        let store = RecordingJobStore()
        let worker = JobWorker(store: store)
        let group = ServiceGroup(services: [worker], logger: Logger(label: "test"))

        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            let accepted = try await worker.submit(JobSubmission(text: "one two two"))
            _ = try await waitForTerminalState(of: accepted.id, in: store)
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }

        let writes = store.state.withLock { $0.writes }
        #expect(writes.map(\.state) == [.running, .completed])
        #expect(writes.last?.summary == "two:2")
    }

    /// **A job submitted before the sweep runs is delivered twice and must still run once.**
    ///
    /// Deterministic rather than lucky: the submission happens strictly before `group.run()`, so the
    /// record is durably `queued` and sitting in the handoff's buffer by the time the sweep reads
    /// `unfinished()` and finds it a second time. That is not a contrived ordering — it is the ordinary
    /// startup window on every runtime, since nothing sequences serving after the `ServiceGroup` starts.
    ///
    /// The write log is the assertion, because from the outside a job run twice looks exactly like a job
    /// run once: same terminal state, same summary. Only the claim shows it.
    @Test func aJobSubmittedBeforeTheSweepIsNotRunTwice() async throws {
        let store = RecordingJobStore()
        let worker = JobWorker(store: store)

        let accepted = try await worker.submit(JobSubmission(text: "one two two"))
        #expect(accepted.state == .queued)

        let group = ServiceGroup(services: [worker], logger: Logger(label: "test"))
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }
            _ = try await waitForTerminalState(of: accepted.id, in: store)
            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }

        let writes = store.state.withLock { $0.writes }
        #expect(writes.map(\.state) == [.running, .completed], "delivered twice, and run twice")
    }

    /// A job that fails does not stop the worker, and the next one still runs — obvious to state and easy
    /// to lose, since the natural spelling of the loop body propagates out of `run()` and terminates the
    /// service, taking the whole group down with it.
    @Test func aFailedJobIsRecordedAndTheWorkerCarriesOn() async throws {
        let store = RecordingJobStore()
        let worker = JobWorker(store: store)
        let group = ServiceGroup(services: [worker], logger: Logger(label: "test"))

        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { try await group.run() }

            // Clears the boundary check and still has no words in it — see `summarise(_:)`.
            let doomed = try await worker.submit(JobSubmission(text: "— , —"))
            let failed = try await waitForTerminalState(of: doomed.id, in: store)
            #expect(failed.state == .failed)
            #expect(failed.failure == "no words")
            #expect(failed.summary == nil)

            let next = try await worker.submit(JobSubmission(text: "still here"))
            #expect(try await waitForTerminalState(of: next.id, in: store).state == .completed)

            await group.triggerGracefulShutdown()
            try await tasks.waitForAll()
        }
    }

    /// The pure half. Ties break alphabetically so the answer is a function of the input rather than of
    /// dictionary ordering — without that, this suite would pass locally and flake elsewhere.
    @Test func theSummaryIsTheMostFrequentWordWithTiesBrokenAlphabetically() throws {
        #expect(try summarise("the cat sat on the mat, the end") == "the:3")
        #expect(try summarise("beta alpha") == "alpha:1")
        #expect(try summarise("Word word WORD") == "word:3")
        // Digits are word characters; punctuation and whitespace separate.
        #expect(try summarise("a1 a1 b") == "a1:2")
        #expect(throws: NothingToSummarise.self) { try summarise("— , —") }
    }
}
