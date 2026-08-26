import Controllers
// `MemberImportVisibility`: this file names `HTTPField.Name` members, so it imports the module that
// declares them rather than relying on one reaching it transitively.
import HTTPTypes
import Testing
import WireMVCTesting

@testable import SwiftHttpServerExample

/// `/documents` over the wire — and specifically **which tier answered**.
///
/// The policy set itself is exhaustively covered by `PolicyEngineTests` in the `Controllers` package,
/// where the whole matrix is a table and a denial can be read back by name. What only a driven route can
/// show is that the decision reaches the response, and that the two tiers are actually two: a request the
/// gate refuses never enters the request scope, and a request the handler refuses already has the document
/// in hand.
///
/// The suites can tell them apart without any test-only instrumentation, because the tiers answer
/// differently by construction. ``ScreenAccess`` writes its own response and can therefore carry an
/// ``AccessDenial`` body naming the rule; the handler throws, and `@ErrorResponse(E.self, .status)`
/// produces a **bodiless** status. So a `403` with a body came from before the router's terminal, and a
/// `403` without one came from inside it. That asymmetry is the observation channel here, the way
/// `NoRoute` is in `StaticFileServingTests`.
///
/// `.inProcess`, so the front layer, the real `FrozenTrieRouter` and the real middleware fold are the
/// production ones — and Docker-free, because nothing under `/documents` is bound per runtime.
@Suite(.wiremvc(MockedRoutingBinds.mocks, .inProcess))
struct DocumentPolicyTests {
    /// The two request attributes every call below sets: who is asking, and from where. Written as a
    /// helper because *every* mutating request needs the zone — which is itself the point of
    /// ``NetworkZoneRule``, and easy to forget into a passing test that asserts the wrong refusal.
    private func headers(
        _ user: String,
        zone: RequestEnvironment.Zone = .internalNetwork
    ) -> [String: String] {
        [PrincipalDirectory.userHeader: user, RequestEnvironment.zoneHeader: zone.rawValue]
    }

    /// Every request below goes through here, and the reason is a rule about the keyed harness worth
    /// knowing before it costs an afternoon.
    ///
    /// `DocumentsController` is `@Scoped(seed:)`, so under a keyed suite its generated scope entry takes
    /// the per-request doubles — and the route answers the harness's own explicit `500` when a request
    /// arrives with no correlation. That holds **even though this controller substitutes nothing**:
    /// `DocumentsControllerDoubles` is an empty struct, because nothing under `/documents` is bound per
    /// runtime. So the plain `withClient` is not the right client here; supplying nothing, explicitly, is.
    ///
    /// The failure is confusing on first contact because it is *partial*: a request the gate refuses never
    /// reaches the terminal, so the doubles are never looked up and those tests pass. Only the routes that
    /// reach a handler fail — which reads as "the policy tier is broken" rather than "the request was not
    /// correlated".
    ///
    /// The generated typed client is handed back; these tests want statuses and bodies rather than decoded
    /// values, so they reach the `TestClient` underneath it.
    private func withDocuments<R>(_ body: (TestClient) async throws -> R) async throws -> R {
        try await withClient(supplying: DocumentsControllerDoubles()) { documents in
            try await body(documents.client)
        }
    }

    // MARK: - Authentication is not the gate's question

    /// No `x-user`: the request-scoped ``Caller`` fails to construct, and
    /// `@ErrorResponse(Unauthenticated.self, .unauthorized)` maps that to `401`.
    ///
    /// The gate saw this request and forwarded it — it has no principal to screen and does not invent one,
    /// so `401` is produced by the scope rather than by a middleware branch. A gate that answered here
    /// would have to distinguish "no identity" from "identity refused", and would then own an
    /// authentication decision it has no business making.
    @Test func aRequestWithNoPrincipalIsUnauthenticatedRatherThanForbidden() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents/notes")
            #expect(response.status == 401)
        }
    }

    /// A name the directory does not hold is the same answer: authentication failed, and it failed the
    /// same way whether the header was absent or wrong. Distinguishing the two would be telling an
    /// attacker which names exist.
    @Test func anUnknownPrincipalIsAlsoUnauthenticated() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents/notes", headers: headers("mallory"))
            #expect(response.status == 401)
        }
    }

    // MARK: - The gate tier

    /// **Refused before the scope is entered, with a body naming the rule.** A suspended account is a
    /// resource-independent denial, so ``ScreenAccess`` answers it from the request alone.
    @Test func aSuspendedAccountIsRefusedByTheGate() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents/notes", headers: headers("erin"))
            #expect(response.status == 403)
            let denial = try response.json(AccessDenial.self)
            #expect(denial.policy == "SuspendedSubjectRule")
        }
    }

    /// The second gate-decidable rule, and the one that shows the tier earning its place: an external
    /// `DELETE` is refused without the store being read and without the request scope existing.
    ///
    /// The same caller deleting the same document from inside succeeds — see
    /// ``anOwnerDeletesTheirOwnDocumentFromTheInternalNetwork()`` — so this is the zone attribute and not
    /// something about `alice` or about `DELETE`.
    @Test func anExternalMutationIsRefusedByTheGate() async throws {
        try await withDocuments { client in
            let response = try await client.delete(
                "/documents/notes",
                headers: headers("alice", zone: .external)
            )
            #expect(response.status == 403)
            #expect(try response.json(AccessDenial.self).policy == "NetworkZoneRule")
        }
    }

    /// Reading from the external zone is *not* refused: ``NetworkZoneRule`` is about mutation. Worth its
    /// own test because a rule that over-denied would still leave every other test in this file passing.
    @Test func anExternalReadIsNotTheNetworkRulesBusiness() async throws {
        try await withDocuments { client in
            let response = try await client.get(
                "/documents/notes",
                headers: headers("alice", zone: .external)
            )
            #expect(response.status == 200)
        }
    }

    /// A refusal is still a response a browser fetched. ``ScreenAccess`` answers with `respondingWith`
    /// rather than raw `responding`, so the response-header registry is drained onto it and the global
    /// CORS middleware's `Access-Control-Allow-Origin` survives — without which a cross-origin caller
    /// could not read the `403` it was given.
    ///
    /// The same claim `corsFieldsSurviveAFileAnsweredHere` makes for the global tier, at the controller
    /// tier and on the error path, which is where it is easiest to lose.
    @Test func corsFieldsSurviveAGateRefusal() async throws {
        try await withDocuments { client in
            let response = try await client.get(
                "/documents/notes",
                headers: headers("erin").merging(["Origin": "https://allowed.example"]) { a, _ in a }
            )
            #expect(response.status == 403)
            #expect(
                response.head?.headerFields[.init("access-control-allow-origin")!] == "https://allowed.example"
            )
        }
    }

    // MARK: - The handler tier

    /// **The case the gate could not decide.** `bob`'s clearance does not reach `sequencing`'s
    /// classification, and nothing about that is visible until the document is loaded — screened from the
    /// request alone this is the same request as the one below it, which succeeds.
    ///
    /// Bodiless, which is how this test knows the gate did not answer it.
    @Test func aClearanceRefusalComesFromTheHandlerAndNotTheGate() async throws {
        try await withDocuments { client in
            let refused = try await client.get("/documents/sequencing", headers: headers("bob"))
            #expect(refused.status == 403)
            #expect(refused.bodyText.isEmpty, "a body would mean the gate answered")

            // Same caller, same method, same zone — only the resource differs.
            let permitted = try await client.get("/documents/notes", headers: headers("bob"))
            #expect(permitted.status == 200)
        }
    }

    /// **A grant is not an override**, over the wire: `carol` is an administrator and is still refused by
    /// classification. The wire counterpart of `anAdministratorIsStillBoundedByClassification`.
    @Test func anAdministratorIsRefusedByClassification() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents/sequencing", headers: headers("carol"))
            #expect(response.status == 403)
            #expect(response.bodyText.isEmpty)
        }
    }

    /// **Permit-required, over the wire.** No rule denies `bob` editing `alice`'s document; what refuses
    /// him is that no rule permits. A model that only ever denied would have answered `200` here.
    @Test func anEditNoRulePermitsIsRefused() async throws {
        try await withDocuments { client in
            let response = try await client.patch(
                "/documents/notes",
                json: EditDocument(title: nil, text: "bob was here"),
                headers: headers("bob")
            )
            #expect(response.status == 403)
            // And the document is unchanged — the refusal happened before the store was written, which a
            // status alone does not establish.
            let reread = try await client.get("/documents/notes", headers: headers("bob"))
            #expect(try reread.json(Document.self).text == "who is doing what")
        }
    }

    /// `403` and `404` are different answers and the id is what separates them: a document that is not
    /// there is not a document the caller may not have. Both reachable on one route, which is what makes
    /// the pair worth asserting together.
    @Test func anAbsentDocumentIsNotFoundRatherThanForbidden() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents/nothing", headers: headers("alice"))
            #expect(response.status == 404)
        }
    }

    // MARK: - The filter tier

    /// A collection is filtered, not refused. `bob` may read `notes` and neither of the other two
    /// fixtures — one above his clearance, one outside his department — and asks for the list without
    /// being told so.
    ///
    /// Asserted by membership rather than by equality: this suite's own creates land in the same
    /// app-scoped store, and tests run in parallel. The exact set per caller is pinned in
    /// `PolicyEngineTests`, against a store nothing else can reach.
    @Test func theCollectionIsFilteredToWhatTheCallerMayRead() async throws {
        try await withDocuments { client in
            let visible = try await client.get("/documents", headers: headers("bob"))
            #expect(visible.status == 200)
            let ids = Set(try visible.json([Document].self).map(\.id))
            #expect(ids.contains("notes"))
            #expect(!ids.contains("sequencing"), "above bob's clearance")
            #expect(!ids.contains("runbook"), "another department")
        }
    }

    /// The auditor's list crosses the department boundary the previous test's does not — the same route,
    /// the same store, a different subject attribute.
    @Test func anAuditorsCollectionCrossesTheDepartmentBoundary() async throws {
        try await withDocuments { client in
            let listed = try await client.get("/documents", headers: headers("dave"))
            let ids = Set(try listed.json([Document].self).map(\.id))
            #expect(ids.isSuperset(of: ["notes", "sequencing", "runbook"]))
        }
    }

    /// A caller who may read nothing gets an empty list and a `200`, not a `403`: asking for a collection
    /// is not an attempt at anything that can be refused.
    ///
    /// Except that `erin` is suspended, so the gate refuses her before the filter ever runs — which is the
    /// interaction worth pinning. The two tiers answer the same route differently depending on which rule
    /// applies, and the gate wins because it is first.
    @Test func aSuspendedCallersCollectionIsRefusedByTheGateRatherThanEmptied() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents", headers: headers("erin"))
            #expect(response.status == 403)
            #expect(try response.json(AccessDenial.self).policy == "SuspendedSubjectRule")
        }
    }

    // MARK: - Creating, and authorising what does not exist yet

    /// A create is authorised against the attributes the document *would* have. `bob` may not create a
    /// document classified above his own clearance, because he could not then read it.
    ///
    /// This is the case a gate could not reach even in principle: the resource attributes come from the
    /// request body, which the middleware tier does not decode.
    @Test func aCreateIsAuthorisedAgainstTheAttributesItWouldHave() async throws {
        try await withDocuments { client in
            let refused = try await client.post(
                "/documents",
                json: CreateDocument(title: "over his head", text: "…", classification: 3),
                headers: headers("bob")
            )
            #expect(refused.status == 403)
            #expect(refused.bodyText.isEmpty, "the handler refused, with the proposed attributes in hand")

            let created = try await client.post(
                "/documents",
                json: CreateDocument(title: "within his clearance", text: "…", classification: 1),
                headers: headers("bob")
            )
            #expect(created.status == 201)
            let document = try created.json(Document.self)
            #expect(created.head?.headerFields[.location] == "/documents/\(document.id)")
            // Owner and department are the caller's — the request never got to name them.
            #expect(document.owner == "bob")
            #expect(document.department == "research")
        }
    }

    /// The whole lifecycle for a caller who owns what they made: create, edit, delete, gone. Uses a
    /// document this test created rather than a fixture, so it can mutate freely alongside the suite's
    /// other tests.
    @Test func anOwnerDeletesTheirOwnDocumentFromTheInternalNetwork() async throws {
        try await withDocuments { client in
            let created = try await client.post(
                "/documents",
                json: CreateDocument(title: "scratch", text: "first", classification: 1),
                headers: headers("alice")
            )
            let id = try created.json(Document.self).id

            let edited = try await client.patch(
                "/documents/\(id)",
                json: EditDocument(title: nil, text: "second"),
                headers: headers("alice")
            )
            #expect(edited.status == 200)
            #expect(try edited.json(Document.self).text == "second")

            let deleted = try await client.delete("/documents/\(id)", headers: headers("alice"))
            #expect(deleted.status == 204)
            let gone = try await client.get("/documents/\(id)", headers: headers("alice"))
            #expect(gone.status == 404)
        }
    }

    /// An administrator editing someone else's document — the grant doing what a grant is for, on a
    /// document within her clearance. The counterweight to `anAdministratorIsRefusedByClassification`:
    /// without it, that test would pass just as well against a rule set where `.admin` meant nothing.
    @Test func anAdministratorEditsWithinTheirClearance() async throws {
        try await withDocuments { client in
            let created = try await client.post(
                "/documents",
                json: CreateDocument(title: "alice's", text: "hers", classification: 1),
                headers: headers("alice")
            )
            let id = try created.json(Document.self).id

            let edited = try await client.patch(
                "/documents/\(id)",
                json: EditDocument(title: nil, text: "carol edited this"),
                headers: headers("carol")
            )
            #expect(edited.status == 200)
            #expect(try edited.json(Document.self).text == "carol edited this")
        }
    }
}
