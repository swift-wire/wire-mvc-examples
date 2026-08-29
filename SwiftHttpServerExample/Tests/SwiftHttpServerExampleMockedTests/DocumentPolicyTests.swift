import Controllers
// `MemberImportVisibility`: this file names `HTTPField.Name` members, so it imports the module that
// declares them rather than relying on one reaching it transitively.
import HTTPTypes
import Testing
import WireMVCTesting

@testable import SwiftHttpServerExample

/// `/documents` over the wire — and specifically **which rule answered**.
///
/// The policy set itself is exhaustively covered by `PolicyEngineTests` in the `Controllers` package,
/// where the whole matrix is a table and a denial can be read back by name. What only a driven route can
/// show is that the decision reaches the response — and, because every refusal here names the rule that
/// produced it, that the *intended* rule refused rather than that something did.
///
/// **That is the observation channel, and it is the one worth having.** An earlier shape of this file
/// used a coarser one: a screening middleware answered with a body while a handler's `@ErrorResponse`
/// answered a bodiless status, so a test could tell which *layer* refused by whether bytes came back.
/// That told you nothing about which rule, and it stopped meaning anything the moment both halves of the
/// decision moved into one binding. Reading `policy` is strictly better: `SuspendedSubjectRule` cannot be
/// confused with `ClearanceRule` however the app is layered, and the assertions below survive a reader
/// deciding to put a gate back — see ``DocumentsController``.
///
/// A `/api/documents/{id}` served from the OpenAPI document goes through the *same* bindings, and is
/// asserted in the runtime suites rather than here: the mocked variant mounts the annotation-driven
/// routes only.
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
    /// The failure is confusing on first contact because it is *partial*: a request refused before the
    /// terminal never looks the doubles up, so those tests pass. Only the routes that reach a handler
    /// fail — which reads as "the policy tier is broken" rather than "the request was not correlated".
    ///
    /// The generated typed client is handed back; these tests want statuses and bodies rather than decoded
    /// values, so they reach the `TestClient` underneath it.
    private func withDocuments<R>(_ body: (TestClient) async throws -> R) async throws -> R {
        try await withClient(supplying: DocumentsControllerDoubles()) { documents in
            try await body(documents.client)
        }
    }

    // MARK: - Authentication is not a policy question

    /// No `x-user`: the request-scoped ``Caller`` fails to construct, and
    /// `@ErrorResponse(Unauthenticated.self, .unauthorized)` maps that to `401`.
    ///
    /// No rule is consulted at all: the scope fails to build, so nothing that decides about policy ever
    /// runs. Keeping the two in different mechanisms is what stops any policy layer from having to
    /// distinguish "no identity" from "identity refused" — it never sees the first case.
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

    // MARK: - The resource-independent rules

    /// **Refused before the store is read, with a body naming the rule.** A suspended account is a
    /// resource-independent denial, so the binding answers it from the request alone — the `guard` that
    /// screens sits ahead of the `find`, which is what makes "before the store is read" structural rather
    /// than incidental.
    @Test func aSuspendedAccountIsRefusedWithoutReadingTheStore() async throws {
        try await withDocuments { client in
            let response = try await client.get("/documents/notes", headers: headers("erin"))
            #expect(response.status == 403)
            let denial = try response.json(AccessDenial.self)
            #expect(denial.policy == "SuspendedSubjectRule")
        }
    }

    /// The second resource-independent rule: an external `DELETE` is refused without the store being
    /// read. It is also the rule that most tempts an application into a screening middleware, which would
    /// refuse it without the request scope existing either — see ``DocumentsController``.
    ///
    /// The same caller deleting the same document from inside succeeds — see
    /// ``anOwnerDeletesTheirOwnDocumentFromTheInternalNetwork()`` — so this is the zone attribute and not
    /// something about `alice` or about `DELETE`.
    @Test func anExternalMutationIsRefusedWithoutReadingTheStore() async throws {
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

    /// A refusal is still a response a browser fetched, so the global CORS middleware's
    /// `Access-Control-Allow-Origin` has to survive it — without which a cross-origin caller could not
    /// read the `403` it was given.
    ///
    /// This failed for a while and nothing caught it. The terminal resolved `headerFields` against the
    /// response-header drain on the success path and built a bare status in its `catch`, so every
    /// contributed field vanished from every `@ErrorResponse` refusal. It was invisible here because the
    /// screening middleware this suite used to exercise answered with `respondingWith`, which drains — so
    /// the one refusal the test drove was the one that worked. Fixed upstream in wire-mvc; the assertion
    /// now means what it always claimed to.
    ///
    /// The same claim `corsFieldsSurviveAFileAnsweredHere` makes for the global tier, on the error path,
    /// which is where it is easiest to lose.
    @Test func corsFieldsSurviveARefusal() async throws {
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

    // MARK: - The resource-reading rules

    /// **The case no layer in front of the store could decide.** `bob`'s clearance does not reach
    /// `sequencing`'s classification, and nothing about that is visible until the document is loaded —
    /// from the request alone this is the same request as the one below it, which succeeds.
    ///
    /// Named, which is how this test knows *which* rule refused: `ClearanceRule` is resource-reading, so
    /// a refusal naming it could not have been decided before the document was loaded.
    @Test func aClearanceRefusalNeedsTheDocumentLoaded() async throws {
        try await withDocuments { client in
            let refused = try await client.get("/documents/sequencing", headers: headers("bob"))
            #expect(refused.status == 403)
            #expect(try refused.json(AccessDenial.self).policy == "ClearanceRule")

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
            #expect(try response.json(AccessDenial.self).policy == "ClearanceRule", "not the grant's absence")
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
            // status alone does not establish. Now structurally so rather than by handler discipline: the
            // binding refuses while producing the argument, so `documents.update` is never reached.
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
    /// Except that `erin` is suspended, and a resource-independent rule refuses the *request* rather than
    /// filtering it — which is the interaction worth pinning, and the reason ``DocumentLister`` screens
    /// before it filters. A version that only filtered would answer `200 []` and quietly call "you may see
    /// nothing" the same thing as "you are refused".
    @Test func aSuspendedCallersCollectionIsRefusedRatherThanEmptied() async throws {
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
    /// This is the case no screening layer could reach even in principle: the resource attributes come
    /// from the request body, which nothing in front of the route decodes.
    @Test func aCreateIsAuthorisedAgainstTheAttributesItWouldHave() async throws {
        try await withDocuments { client in
            let refused = try await client.post(
                "/documents",
                json: CreateDocument(title: "over his head", text: "…", classification: 3),
                headers: headers("bob")
            )
            #expect(refused.status == 403)
            // The proposed attributes were in hand: `ClearanceRule` reads a resource, and the only
            // resource here is the one the request asked to create.
            #expect(try refused.json(AccessDenial.self).policy == "ClearanceRule")

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
