// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

public import HTTPTypes
public import Wire
public import WireMVC

/// The enqueue-and-poll pair — and the only controller in this repository whose successful answer is a
/// promise rather than a result.
///
/// It injects `some JobProcessor`, the same opaque-lift shape `TodosController` uses for its repository,
/// and that is the claim worth making: **hosting work that outlives the request costs the route nothing.**
/// Nothing here is background-specific. The binding on the other side of that generic parameter happens
/// to be a running `ServiceLifecycle` service, and this controller cannot tell.
///
/// No `@TestScopable`: what a keyed suite would substitute per request is the processor, and the
/// processor is the thing under test. What varies between graphs is the ``JobStore`` behind it, which is
/// an app binding like any backend.
@Singleton
@Controller("/jobs")
@ErrorResponse(EmptySubmission.self, .badRequest)
@ErrorResponse(QueueClosed.self, .serviceUnavailable)
@ErrorResponse(JobNotFound.self, .notFound)
public struct JobsController<Processor: JobProcessor>: Sendable {
    @Inject var jobs: Processor

    /// Accept work and say so. **`202`, not `201`**: a `201` promises a resource exists at `Location`,
    /// and nothing has been created here except a record of the intention — RFC 9110 §15.3.3 is explicit
    /// that `202` is for a request accepted for processing that may or may not complete. `Location` still
    /// names where the answer will appear, which is what makes the pair usable without a callback.
    ///
    /// The body is the record the store wrote: `queued`, with no summary. It cannot say anything else,
    /// and that is the proof the suites lean on — a `completed` body would mean the work had happened
    /// inside the request after all.
    ///
    /// `async` because the record is durable before this returns. An enqueue that did not await its write
    /// would answer faster and promise less; see ``JobProcessor/submit(_:)``.
    @Post
    @JSONResponse(status: .accepted)
    public func submit(@JSONBody submission: JobSubmission) async throws -> (headers: HTTPFields, body: JobRecord) {
        let record = try await jobs.submit(submission)
        // Written out rather than derived, for the reason `TodosController.create` states: the
        // `@Controller("/jobs")` prefix is compile-time text the handler cannot read back.
        return ([.location: "/jobs/\(record.id)"], record)
    }

    /// Where the answer turns up. Polled rather than pushed — a webhook or an event stream is the same
    /// record delivered differently, and this repository already serves `text/event-stream` elsewhere.
    ///
    /// A **failed** job answers `200` carrying a record whose `state` is `failed`, not a `5xx`: the
    /// question "how did job 3 go?" was answered successfully. Conflating the two would leave a caller
    /// unable to tell a job that failed from a poll that did.
    @Get("/{id}")
    @JSONResponse
    public func status(@Path id: String) async throws -> JobRecord {
        try await jobs.record(id: id)
    }
}
