import Logging
public import ServiceLifecycle
import Synchronization
public import Wire
public import WireMVC

// Work that outlives the request: a durable job store bound per runtime, and a worker that drains it,
// collated into the graph's `ServiceLifecycle` services by `@BackgroundService`. Every other route in this
// repository answers from work it does *inside* the request; this is the one that hands work off and
// answers before it has happened.

// MARK: - The wire types

/// What a client posts to `POST /jobs`. Deliberately one field: the interesting axis here is *when* the
/// work runs, not what it is.
public struct JobSubmission: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Where a job has got to. `running` is not decoration: it is what tells a *later* process that a previous
/// one died mid-job, which is the difference between a sweep that can distinguish "never started" from
/// "started and lost" and one that cannot.
public enum JobState: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
}

/// The whole of a job, in the store and on the wire — the `202`'s body and what `GET /jobs/{id}` returns.
///
/// It carries `text` because the **sweep** needs it: a job recovered from the store after a restart has to
/// be runnable from its record alone, and a record that only described the job's progress would leave the
/// recovering process holding an id it could do nothing with.
public struct JobRecord: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let state: JobState
    public let summary: String?
    public let failure: String?

    public init(id: String, text: String, state: JobState, summary: String? = nil, failure: String? = nil) {
        self.id = id
        self.text = text
        self.state = state
        self.summary = summary
        self.failure = failure
    }

    /// The three transitions, as values. A worker computes the next record rather than mutating one, so
    /// what is written to the store is a whole record and a store needs only `update`.
    func running() -> JobRecord {
        JobRecord(id: id, text: text, state: .running)
    }

    func completed(summary: String) -> JobRecord {
        JobRecord(id: id, text: text, state: .completed, summary: summary)
    }

    func failed(_ description: String) -> JobRecord {
        JobRecord(id: id, text: text, state: .failed, failure: description)
    }
}

/// `GET /jobs/{id}` for an id the store has never held — mapped to 404 by ``JobsController``.
public struct JobNotFound: Error {}

/// `POST /jobs` after the worker stopped accepting, which happens only during graceful shutdown — mapped
/// to 503. Worth a distinct error: the window is real (a load balancer keeps sending during a drain) and
/// a 503 is what tells the caller to retry elsewhere, where a 500 would not.
public struct QueueClosed: Error {}

/// `POST /jobs` with nothing in it. Refused at the boundary, before an id exists — see ``summarise(_:)``
/// for where the line between this check and the worker's falls, and why it falls there.
public struct EmptySubmission: Error {}

// MARK: - The two halves

/// The durable half: where a job's record lives between the response and the work.
///
/// Declared here, framework-free, and **not satisfied here** — each runtime binds
/// `@Singleton(as: JobStore.self)` against its own database, the same cross-module shape
/// ``TodoRepository`` and ``SessionManager`` use. So the persistence axis collapses to one binding for a
/// third time, and the job records land in the runtime's real store rather than in the process.
///
/// The store issues ids, exactly as `TodoRepository.create` does: an id minted in the process would be
/// meaningless to the next one.
public protocol JobStore: Sendable {
    /// Record a new job as `queued` and hand back the record — including the id the store issued.
    func enqueue(text: String) async throws -> JobRecord

    /// The job with `id`, or `nil` if the store has never held one.
    func find(id: String) async throws -> JobRecord?

    /// Overwrite a job's record with `record`, keyed by its id.
    func update(_ record: JobRecord) async throws

    /// Everything a previous process accepted and did not finish — `queued` (never started) and `running`
    /// (started and lost). What the sweep in ``JobWorker/run()`` recovers.
    func unfinished() async throws -> [JobRecord]
}

/// The volatile half: what a route talks to. Opaque, so a controller depends on the *capability* rather
/// than on the worker that happens to implement it — and so the handoff between them stays private.
public protocol JobProcessor: Sendable {
    /// Accept a submission and return its record, which is `queued` by construction. Returns only once
    /// the record is **durable**: that is what makes the `202` a promise rather than a hope.
    func submit(_ submission: JobSubmission) async throws -> JobRecord

    /// The current record for `id`. Throws ``JobNotFound`` for an id the store has never held.
    func record(id: String) async throws -> JobRecord
}

// MARK: - The worker

/// The graph-hosted worker — and, being an ordinary binding, the thing the route talks to as well.
///
/// Three annotations, doing three separate jobs: `@Singleton(as: JobProcessor.self)` binds it under an
/// opaque identity, so `JobsController` depends on `some JobProcessor` and never learns that the thing
/// answering its `submit` is also a running service; `@BackgroundService` is sugar for
/// `@Contributes(to: WireMVCKeys.services)`, so the *same instance* is handed to the app's `ServiceGroup`;
/// and `Service` is stated rather than added, since the marker adds no conformance.
///
/// **The two roles the earlier cut conflated are now a binding and a collaborator.** The durable half is
/// ``JobStore``, resolved from the graph like any backend. What is left here is the half that genuinely
/// cannot be shared: an in-process `AsyncStream` handing accepted work to the loop in `run()`. Owning it
/// rather than injecting it is the point of putting the processor and the worker in one type — `run()`
/// drains its own stream, and nothing else can reach the continuation.
///
/// **Why keep an in-process handoff at all**, when the store is already durable and could be polled? Most
/// real queues are this hybrid: the stream is what makes an enqueue visible to the worker in microseconds,
/// and the store is what makes it survive. What the hybrid costs is a gap between the two — a record
/// written and not handed over — and the sweep in `run()` is what closes it.
@Singleton(as: JobProcessor.self)
@BackgroundService
public final class JobWorker<Store: JobStore>: JobProcessor, Service {
    private let store: Store
    private let handoff = AsyncStream<JobRecord>.makeStream()
    /// Whether `submit` still accepts. Guarded together with finishing the stream, so the two cannot
    /// disagree.
    private let accepting = Mutex(true)
    private let logger = Logger(label: "jobs")

    @Inject public init(store: Store) {
        self.store = store
    }

    // MARK: The processor half

    /// **Durable before it returns.** The store write is awaited, then the record is handed to the loop —
    /// which is the ordering the `202` depends on: a caller told its work was accepted can survive this
    /// process dying, because the record is already in the database when the response is written.
    ///
    /// The reverse ordering would be faster and would be a lie. So would refusing to await it: an id
    /// minted here and written later leaves `GET /jobs/{id}` answering `404` for a job this route just
    /// accepted.
    ///
    /// **Shutdown can still race the yield**, and the answer is durability rather than a lock. Between the
    /// `accepting` check and the yield, a graceful shutdown can finish the stream; the record is then
    /// written, `queued`, and this process will never run it. That is not a lost job — it is exactly what
    /// `unfinished()` returns and what the sweep in ``run()`` picks up next boot. RFC 9110 §15.3.3 is
    /// unusually helpful here: a `202` promises the request was *accepted for processing*, not that
    /// processing will happen in any particular process.
    public func submit(_ submission: JobSubmission) async throws -> JobRecord {
        guard !submission.text.isEmpty else { throw EmptySubmission() }
        // Checked *before* the write, never after: throwing `QueueClosed` on a record already in the
        // store would answer 503 for a job the sweep will nonetheless run.
        try accepting.withLock { guard $0 else { throw QueueClosed() } }
        let record = try await store.enqueue(text: submission.text)
        handoff.continuation.yield(record)
        return record
    }

    public func record(id: String) async throws -> JobRecord {
        guard let record = try await store.find(id: id) else { throw JobNotFound() }
        return record
    }

    // MARK: The service half

    /// Recover, then drain until shutdown, then drain what is left and return.
    ///
    /// **The sweep runs before the loop**, and it is what makes the store more than a log. Anything a
    /// previous process left `queued` (accepted, never handed over) or `running` (started, then lost) is
    /// pushed back through the same handoff, so recovery and normal operation share one code path. It
    /// makes the contract **at-least-once**: a job whose process died after `summarise` but before the
    /// write is run again. That is the right default — the alternative is at-most-once, which drops work
    /// — and it is why a real job's payload should be idempotent.
    ///
    /// **The drain is why this is a `Service` and not a `Task`.** `withGracefulShutdownHandler` is only
    /// armed inside a `ServiceGroup`, and the group does not consider shutdown finished until `run()`
    /// returns. So `onGracefulShutdown` refuses new submissions and *finishes* the handoff, the `for
    /// await` delivers everything already buffered, and the loop ends when the buffer is empty. The
    /// one-line alternative — `handoff.stream.cancelOnGracefulShutdown()` — means the opposite: it
    /// cancels mid-iteration, abandoning the job in hand and everything behind it. Right for a service
    /// whose loop is *waiting*, wrong for one whose loop is *working*.
    ///
    /// A detached `Task` has neither half: nothing tells it shutdown began, and nothing waits for it.
    public func run() async throws {
        for orphan in try await store.unfinished() {
            logger.info("recovering an unfinished job", metadata: ["job": .string(orphan.id)])
            handoff.continuation.yield(orphan)
        }
        await withGracefulShutdownHandler {
            for await job in handoff.stream {
                await process(job)
            }
        } onGracefulShutdown: {
            self.stopAccepting()
        }
    }

    /// Claim the job, do the work, record the outcome.
    ///
    /// **Claiming re-reads first, and that is not defensive coding — it closes a hole the hybrid creates.**
    /// A route is reachable before its service's `run()` has begun, on all three runtimes: nothing orders
    /// serving after the `ServiceGroup` starts. So a job submitted in that window is written `queued`,
    /// handed to the loop by ``submit(_:)``, *and* found by the sweep a moment later — delivered twice.
    /// At-least-once permits that, but running the same job twice on an ordinary path is not what the
    /// contract is for. Re-reading fixes it because the loop is serial: the second delivery cannot be
    /// claimed until the first has written its outcome, and a terminal record is one this worker has
    /// already finished. It is also what a conditional claim *is* in a real queue, so the shape is the
    /// one that survives contact with a database.
    ///
    /// A record left `running` is deliberately *not* skipped. That is the sweep's other case — started by
    /// a previous process and lost — and re-running it is the at-least-once contract working, not the
    /// duplicate above.
    ///
    /// Claiming is then a write of its own rather than a saving of one, because `running` is what a later
    /// sweep reads to tell "never started" from "started and lost". A store write that fails abandons the
    /// job *in the store's current state*, so the next sweep sees it and retries — which is why no failure
    /// below rethrows: throwing out of `run()` would take the whole `ServiceGroup` down over one job, and
    /// the recovery path already exists.
    private func process(_ job: JobRecord) async {
        do {
            guard let current = try await store.find(id: job.id) else { return }
            guard current.state == .queued || current.state == .running else { return }
        } catch {
            logger.error("could not read a job before claiming it", metadata: ["job": .string(job.id)])
            return
        }

        do {
            try await store.update(job.running())
        } catch {
            logger.error("could not claim a job", metadata: ["job": .string(job.id)])
            return
        }

        let outcome: JobRecord
        do {
            outcome = job.completed(summary: try summarise(job.text))
        } catch {
            // **The failure has nowhere to go but the record.** By now the caller has had its `202` and
            // the connection is gone, so there is no status to map this to and `@ErrorResponse` cannot
            // reach it — the asymmetry that makes a job queue a different contract rather than a slower
            // one. `GET /jobs/{id}` is where a caller finds out; this line is where an operator does.
            logger.warning("job failed", metadata: ["job": .string(job.id)])
            outcome = job.failed(String(describing: error))
        }

        do {
            try await store.update(outcome)
        } catch {
            logger.error("could not record a job's outcome", metadata: ["job": .string(job.id)])
        }
    }

    /// Stop accepting and finish the handoff, so the loop ends **once the buffer is empty** rather than
    /// immediately. One lock over both, so a submission cannot pass the `accepting` check on the strength
    /// of a flag this call is in the middle of clearing.
    private func stopAccepting() {
        accepting.withLock { accepting in
            accepting = false
            handoff.continuation.finish()
        }
    }
}

// MARK: - The work itself

/// Thrown by ``summarise(_:)`` for text that survived the boundary check and still has no words in it.
public struct NothingToSummarise: Error, CustomStringConvertible {
    public var description: String { "no words" }
}

/// The job: the most frequent word in `text`, and how often it occurs (`"the:3"`). Ties break
/// alphabetically, so the answer is a function of the input and a test can state it.
///
/// **Where the two checks fall is the point, not the arithmetic.** `submit` refuses empty text, because
/// that is answerable at the boundary in constant time and before an id exists. It does *not* refuse text
/// with no words in it — `"— , —"` — because finding that out means tokenising, which is the job. Any
/// queue's boundary validation is the shallow half by construction; the deep half is discovered when the
/// work runs, by which time the response is long gone.
///
/// Pure, and the one thing in this file a unit test can drive without a graph, a store or a server — the
/// same division `MultipartParser` gets.
func summarise(_ text: String) throws -> String {
    var counts: [String: Int] = [:]
    for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
        counts[word.lowercased(), default: 0] += 1
    }
    guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else {
        throw NothingToSummarise()
    }
    return "\(best.key):\(best.value)"
}
