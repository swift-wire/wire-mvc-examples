import Controllers
// `MemberImportVisibility`: this file names `HTTPField.Name.location`, so it imports the module that
// declares it rather than relying on one reaching it transitively.
import HTTPTypes
import Testing
import WireMVCTesting

@testable import SwiftHttpServerExample

/// The jobs routes, driven through the real router with the graph's services **running**.
///
/// `services: .run` is the whole reason this suite is separate from `MockedRoutingTests`. A
/// `.wiremvc(…)` suite defaults to ``WireMVCTestServices/skip`` — a route-logic suite wants isolation,
/// and starting a graph's services to test a `@Get` would start a database client — so the default is
/// right and this is the exception that proves it: with services skipped, `POST /jobs` still answers
/// `202` and the job stays `queued` forever, because the thing that would run it was never started.
/// That is the same failure a deployment has when it forgets to hand `apply`'s services to a group, and
/// it is why the assertions below poll for a *terminal* state rather than trusting the `202`.
///
/// Docker-free like the rest of this target, but for a different reason than the other suites here: the
/// app's real ``JobStore`` is CouchDB-backed, and `InMemoryJobStore` supersedes it with `@Replaces` rather
/// than `@BindType`. A background service is app-scoped and reads its store outside any request, so there
/// is no request to thread a double through — see that type for the rule.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess, services: .run))
struct JobsTests {

    /// Poll `GET /jobs/{id}` until the job leaves `queued`/`running`. Bounded: a job that never runs is
    /// this suite's most likely failure and should read as one rather than as a hang.
    private func waitForTerminalState(of id: String, using jobs: JobsControllerClient) async throws -> JobRecord {
        for _ in 0..<5_000 {
            let record = try await jobs.status(id: id)
            if record.state == .completed || record.state == .failed { return record }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("job \(id) never left \(try await jobs.status(id: id).state)")
        return try await jobs.status(id: id)
    }

    /// The shape of the whole feature in one test: the response is a promise, and the answer turns up
    /// later at the address the response named.
    ///
    /// The `202` body **cannot** say `completed` — it is the record as it stood inside `submit`'s lock,
    /// before the worker had been handed anything. So the pair of assertions is the proof that the work
    /// happened outside the request rather than inside it, with no timing assumption in either direction.
    @Test func submittedWorkIsAnsweredLaterAtTheAddressTheResponseNamed() async throws {
        try await withClient(for: JobsControllerClient.self) { jobs in
            let accepted = try await jobs.submit(submission: JobSubmission(text: "the cat sat on the mat"))
            #expect(accepted.state == .queued)
            #expect(accepted.summary == nil)

            let finished = try await waitForTerminalState(of: accepted.id, using: jobs)
            #expect(finished.state == .completed)
            #expect(finished.summary == "the:2")
        }
    }

    /// `202`, not `201`, and a `Location` that names where the answer will appear. Asserted with the
    /// untyped client because the typed one returns the decoded body and drops the head — the status and
    /// the header field are exactly what this test is about.
    @Test func acceptedCarriesTheStatusAndTheLocationOfTheAnswer() async throws {
        try await withClient { client in
            let response = try await client.post("/jobs", json: JobSubmission(text: "hello hello world"))
            #expect(response.status == 202)
            let record = try response.json(JobRecord.self)
            #expect(response.head?.headerFields[.location] == "/jobs/\(record.id)")
            #expect(record.text == "hello hello world", "the record carries what the sweep would need")
        }
    }

    /// **The record is in the store before the response is written**, seen from the outside: the very next
    /// request finds it, whatever state it has reached by then. This is what `submit` awaiting its write
    /// buys, and it is the difference between a `202` that is a promise and one that is a hope — an
    /// enqueue that only put the job on the in-process handoff would answer `404` here for a job it had
    /// just accepted.
    ///
    /// Deliberately silent about *which* state comes back. Asserting `queued` would be asserting that the
    /// worker had not got to it yet, which is a race; asserting the record exists at all is the property.
    @Test func theRecordIsReadableImmediatelyAfterTheResponse() async throws {
        try await withClient { client in
            let accepted = try await client.post("/jobs", json: JobSubmission(text: "durable before the 202"))
            let id = try accepted.json(JobRecord.self).id
            let immediately = try await client.get("/jobs/\(id)")
            #expect(immediately.status == 200)
            #expect(try immediately.json(JobRecord.self).text == "durable before the 202")
        }
    }

    /// A job that fails after acceptance is a **record**, not a status: the poll answers `200` carrying
    /// `failed`. There is no other way for it to answer — the caller's response was written and the
    /// connection closed while the job was still queued, so `@ErrorResponse` cannot reach this failure
    /// however it is declared. It is the one asymmetry that makes a queue a different contract rather
    /// than a slower one.
    @Test func aFailureAfterAcceptanceIsARecordRatherThanAStatus() async throws {
        try await withClient { client in
            // Clears the boundary check (non-empty) and still has no words in it — the failure can only
            // be found by doing the work. See `summarise(_:)`.
            let accepted = try await client.post("/jobs", json: JobSubmission(text: "— , —"))
            #expect(accepted.status == 202)
            let id = try accepted.json(JobRecord.self).id

            try await withClient(for: JobsControllerClient.self) { jobs in
                let finished = try await waitForTerminalState(of: id, using: jobs)
                #expect(finished.state == .failed)
                #expect(finished.failure == "no words")
            }

            // And the poll that found that out was itself a success.
            let poll = try await client.get("/jobs/\(id)")
            #expect(poll.status == 200)
        }
    }

    /// The boundary refusal, which happens before an id is issued — so there is nothing to poll for
    /// afterwards, and the caller learns synchronously. The cheap half of validation belongs here.
    @Test func anEmptySubmissionIsRefusedBeforeAnIdIsIssued() async throws {
        try await withClient { client in
            let refused = try await client.post("/jobs", json: JobSubmission(text: ""))
            #expect(refused.status == 400)
        }
    }

    /// An unknown id maps to `404` through `@ErrorResponse` — and it is the **route's** 404, not the
    /// app's `@NotFound` fallback, which would have carried a `NoRoute` body. `/jobs/{id}` matched; the
    /// job did not exist. The distinction is the one `StaticFileServingTests` draws for the three 404s
    /// the app can produce, and this is a fourth.
    @Test func anUnknownIdIsTheRoutesOwn404NotTheFallbacks() async throws {
        try await withClient { client in
            let response = try await client.get("/jobs/does-not-exist")
            #expect(response.status == 404)
            #expect(throws: (any Error).self) { try response.json(NoRoute.self) }
        }
    }
}
