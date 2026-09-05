// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import Controllers

/// The combining algorithm and the rules, with no server involved.
///
/// Here rather than in a runtime suite for the reason the multipart parser is: this is pure logic with
/// silent failure modes. An authorisation bug does not throw — it answers `200`, and it answers `200` only
/// for the caller nobody drove a request as. Over the wire each case costs a request and can only assert a
/// status; here the whole matrix is a table, and the two cases that matter most —
/// ``PolicyEngine/screen(subject:action:environment:)`` refusing to permit, and a grant losing to a deny —
/// are stated directly rather than inferred from a status code.
///
/// The runtime suites still drive the routes: what they prove is that the decision reaches the response,
/// on all three hosts. What they cannot prove cheaply is that it is the right decision for every caller.
struct PolicyEngineTests {
    private let engine = PolicyEngine(
        policies: [
            SuspendedSubjectRule(),
            NetworkZoneRule(),
            ClearanceRule(),
            DepartmentRule(),
            OwnerGrant(),
            ReadGrant(),
            AdministratorGrant(),
        ]
    )
    private let directory = PrincipalDirectory()
    private let store = DocumentStore()

    private func principal(_ user: String) throws -> Principal {
        try #require(directory.principal(for: user))
    }

    private func document(_ id: String) throws -> Document {
        try #require(store.find(id: id))
    }

    private func query(
        _ user: String,
        _ action: AccessAction,
        _ documentID: String,
        from zone: RequestEnvironment.Zone = .internalNetwork
    ) throws -> AccessQuery {
        AccessQuery(
            subject: try principal(user),
            action: action,
            environment: RequestEnvironment(zone: zone),
            resource: try document(documentID).attributes
        )
    }

    /// Reading back the denial rather than only that one happened, because "which rule refused" is the
    /// whole content of a policy set: a test that accepts any denial passes when the wrong rule fires.
    private func denial(of query: AccessQuery) -> AccessDenial? {
        do {
            try engine.authorize(query)
            return nil
        } catch let error as AccessDenied {
            return error.denial
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    // MARK: - The combining algorithm

    /// **A grant is not an override.** `carol` is an administrator, and ``AdministratorGrant`` permits
    /// every action she attempts; `sequencing` is classified above her clearance, and ``ClearanceRule``
    /// denies. Deny-overrides means she is refused.
    ///
    /// This is the property that separates the model from role-based access control, where an admin role
    /// is normally exactly the bypass this is not.
    @Test func anAdministratorIsStillBoundedByClassification() throws {
        #expect(denial(of: try query("carol", .read, "sequencing"))?.policy == "ClearanceRule")
        // The same administrator, on a document within her clearance, is permitted — so the refusal above
        // is the classification and not something about being an administrator.
        #expect(denial(of: try query("carol", .update, "notes")) == nil)
    }

    /// **Permit-required: an unanticipated request fails closed.** No rule denies `bob` editing `alice`'s
    /// document — he is in her department, his clearance reaches it, the network is internal, he is not
    /// suspended. What refuses him is that nothing permits: ``OwnerGrant`` abstains because he is not the
    /// owner, ``ReadGrant`` because this is not a read, ``AdministratorGrant`` because he is not one.
    ///
    /// The denial names the engine rather than a policy, which is the honest attribution: no rule made
    /// this decision, the absence of one did.
    @Test func aRequestNoRulePermitsIsRefusedByTheAlgorithmItself() throws {
        let refusal = try #require(denial(of: try query("bob", .update, "notes")))
        #expect(refusal.policy == "PolicyEngine")
        #expect(refusal.reason.contains("no policy permits"))
    }

    /// An owner gets every action on their own document, which is the permit most requests run on.
    @Test func anOwnerIsPermittedEveryActionOnTheirOwnDocument() throws {
        for action in [AccessAction.read, .update, .delete] {
            #expect(denial(of: try query("alice", action, "notes")) == nil, "alice \(action) notes")
        }
    }

    /// The auditor exemption is exactly one rule wide. `dave` reads across the department boundary that
    /// refuses `alice`, and is still subject to everything else — asserted by the pair rather than by the
    /// grant alone, since an exemption that quietly widened would pass the first assertion on its own.
    ///
    /// `alice` and not `bob`, and the difference is worth knowing: `bob` is refused `runbook` too, but by
    /// ``ClearanceRule``, which is ordered ahead. Deny-overrides makes the outcome the same whichever rule
    /// fires, so `withOrder:` cannot change *whether* a request is refused — only which refusal is
    /// reported. A test naming a policy is therefore also a test of the order, and picking a subject whose
    /// only obstacle is the boundary is what keeps it a test of the boundary.
    @Test func anAuditorCrossesTheDepartmentBoundaryAndNothingElse() throws {
        #expect(denial(of: try query("dave", .read, "notes")) == nil)
        #expect(denial(of: try query("alice", .read, "runbook"))?.policy == "DepartmentRule")
        // Reading is granted; editing another department's document is not, because no rule permits it.
        #expect(denial(of: try query("dave", .update, "notes"))?.policy == "PolicyEngine")
    }

    // MARK: - The two tiers

    /// **The gate cannot answer the question the handler answers, and this is the case that proves it.**
    ///
    /// `bob` reading `sequencing` is refused by ``ClearanceRule`` — but only once the document is in hand.
    /// Screened from the request alone the same request is *undecided*: every resource-reading rule
    /// abstains, and the only rule with anything to say is ``ReadGrant``, which permits.
    ///
    /// So a gate that treated a permit as final would wave this through. That is why
    /// ``PolicyEngine/screen(subject:action:environment:)`` returns `AccessDenial?` rather than a decision
    /// — the type is what makes the mistake unwriteable rather than merely discouraged.
    @Test func screeningIsUndecidedWhereTheFullDecisionIsARefusal() throws {
        let subject = try principal("bob")
        let internalZone = RequestEnvironment(zone: .internalNetwork)
        #expect(engine.screen(subject: subject, action: .read, environment: internalZone) == nil)
        #expect(denial(of: try query("bob", .read, "sequencing"))?.policy == "ClearanceRule")
    }

    /// What the gate *can* decide: both resource-independent denials, which is why the tier is worth
    /// having. Neither of these needs the store touched or the request scope entered.
    @Test func theGateDecidesWhatTheRequestAloneDecides() throws {
        let suspended = try principal("erin")
        let refusal = try #require(
            engine.screen(subject: suspended, action: .read, environment: RequestEnvironment(zone: .internalNetwork))
        )
        #expect(refusal.policy == "SuspendedSubjectRule")

        let external = RequestEnvironment(zone: .external)
        let owner = try principal("alice")
        #expect(engine.screen(subject: owner, action: .delete, environment: external)?.policy == "NetworkZoneRule")
        // The same caller, the same zone, a read: the rule is about mutation, not about the network.
        #expect(engine.screen(subject: owner, action: .read, environment: external) == nil)
        // And the same delete from inside is not the gate's to refuse — the handler tier gets its turn.
        #expect(
            engine.screen(
                subject: owner,
                action: .delete,
                environment: RequestEnvironment(zone: .internalNetwork)
            ) == nil
        )
    }

    /// The network rule survives the resource being known: a rule that decided at the gate must decide the
    /// same way at the handler, or the tiers would disagree about the requests that reach both.
    @Test func aGateDecidableRuleDecidesTheSameWayWithTheResourceInHand() throws {
        #expect(denial(of: try query("alice", .delete, "notes", from: .external))?.policy == "NetworkZoneRule")
    }

    // MARK: - Filtering

    /// The collection tier, as a table. `permits` is `authorize` with the throw swallowed, so this is not
    /// re-asserting the rules — it is asserting that the *set of documents each caller can see* is what
    /// the rules add up to, which is the property a reader of the policy file wants checked and the one
    /// that is tedious to derive by hand.
    @Test(
        arguments: [
            // alice owns two research documents and cannot reach operations.
            ("alice", ["notes", "sequencing"]),
            // bob's clearance stops at `notes`; `runbook` is another department's.
            ("bob", ["notes"]),
            // carol administers research, but clearance 2 does not reach `sequencing`.
            ("carol", ["notes"]),
            // the auditor sees everything: clearance 5, and the department boundary does not apply.
            ("dave", ["notes", "sequencing", "runbook"]),
            // suspended — every rule goes against the account, including the read grant.
            ("erin", []),
        ] as [(String, [String])]
    )
    func eachCallerSeesExactlyWhatTheRulesAddUpTo(user: String, visible: [String]) throws {
        let subject = try principal(user)
        let seen = store.all()
            .filter {
                engine.permits(
                    AccessQuery(
                        subject: subject,
                        action: .read,
                        environment: RequestEnvironment(zone: .internalNetwork),
                        resource: $0.attributes
                    )
                )
            }
            .map(\.id)
        #expect(seen == visible)
    }

    // MARK: - Resolving the subject

    /// A name the directory does not hold is *authentication* failing, and is distinct from a principal
    /// that exists and is suspended. The two answers are produced by different layers — the request-scoped
    /// ``Caller`` and the gate — and this is where the distinction starts.
    @Test func anUnknownNameIsNotAPrincipalAndASuspendedOneIs() {
        #expect(directory.principal(for: "mallory") == nil)
        #expect(directory.principal(for: "erin")?.suspended == true)
    }
}
