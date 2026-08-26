public import HTTPTypes
public import Wire

// The combining algorithm, the refusal it produces, and where subject attributes come from. Split from
// `AccessPolicy.swift`, which declares the attributes and the rules themselves: the rules are what an
// application edits, and this is the machinery they are edited against.

/// What a refusal says, on the wire and in a log line. The policy is named because a `403` that does not
/// say which rule produced it is unactionable for the caller and unauditable for the operator — and,
/// concretely here, it is what lets a test assert that the *intended* rule refused rather than that
/// something did.
public struct AccessDenial: Codable, Sendable, Equatable {
    public let policy: String
    public let reason: String

    public init(policy: String, reason: String) {
        self.policy = policy
        self.reason = reason
    }
}

/// Thrown by ``PolicyEngine/authorize(_:)`` — mapped to `403` by ``DocumentsController``'s
/// `@ErrorResponse`. Carries the denial so a handler can log it, even though the mapped response cannot:
/// `@ErrorResponse(E.self, .status)` produces a bodiless status, so the handler tier's `403` has no body
/// where the gate tier's does. That asymmetry is not decoration — it is how the suites tell which tier
/// refused.
public struct AccessDenied: Error {
    public let denial: AccessDenial

    public init(denial: AccessDenial) {
        self.denial = denial
    }
}

/// The combining algorithm, and the only thing in the app that knows there is more than one rule.
///
/// **Deny-overrides, then permit-required** — XACML's `deny-unless-permit` with an explicit deny pass in
/// front of it, which is the combination worth copying: any deny refuses, and in the absence of a deny a
/// request still needs somebody to have said yes. The second half is what makes an unanticipated request
/// fail closed. `bob` attempting to edit `alice`'s document is refused by no rule at all; what refuses him
/// is that no rule permits.
@Singleton
public struct PolicyEngine: Sendable {
    @Inject(AccessPolicies.all) var policies: [any AccessPolicy]

    /// The gate tier's question: **is there a reason to refuse this before doing any work?**
    ///
    /// Returns a denial or nothing, and *cannot* return a permit. That is the whole contract, and it is
    /// the one thing here that would be a security bug if it were relaxed. A resource-reading rule
    /// abstains when there is no resource, so a query without one is missing an unknown number of the
    /// rules that would have denied it; a gate that took `ReadGrant`'s permit as final would therefore
    /// wave through exactly the requests ``ClearanceRule`` exists to stop. Undecided is the only honest
    /// answer this tier can give, so it is the only one the signature can express.
    public func screen(
        subject: Principal,
        action: AccessAction,
        environment: RequestEnvironment
    ) -> AccessDenial? {
        let query = AccessQuery(subject: subject, action: action, environment: environment, resource: nil)
        return firstDenial(in: query)
    }

    /// The handler tier's question, with every attribute in hand. Throws ``AccessDenied`` rather than
    /// returning, so a handler authorises in one line and the controller's `@ErrorResponse` turns a
    /// refusal into a status without the handler naming one.
    public func authorize(_ query: AccessQuery) throws {
        if let denial = firstDenial(in: query) { throw AccessDenied(denial: denial) }
        guard policies.contains(where: { $0.evaluate(query) == .permit }) else {
            throw AccessDenied(
                denial: AccessDenial(
                    policy: "PolicyEngine",
                    reason: "no policy permits \(query.action.rawValue) for \(query.subject.user)"
                )
            )
        }
    }

    /// The same decision as ``authorize(_:)``, as a `Bool` — for the collection route, which filters
    /// rather than refuses. A request for a list of things the caller may not see is not an error; the
    /// answer is the shorter list. Sharing the decision function with the item route is what keeps the two
    /// from disagreeing, which is the classic way an authorisation model springs a leak.
    public func permits(_ query: AccessQuery) -> Bool {
        (try? authorize(query)) != nil
    }

    /// The deny pass, shared by both entry points. First rather than all: the combining algorithm makes
    /// every deny equivalent to the outcome, so the remaining ones would only lengthen the reason.
    private func firstDenial(in query: AccessQuery) -> AccessDenial? {
        for policy in policies {
            if case .deny(let reason) = policy.evaluate(query) {
                return AccessDenial(policy: policy.name, reason: reason)
            }
        }
        return nil
    }
}

// MARK: - Resolving the subject

/// Where subject attributes come from — an ordinary app `@Singleton`, injected by the gate and by the
/// request-scoped ``Caller`` alike.
///
/// The fixture is a table because the interesting axis of this example is the policy set, not the identity
/// provider. `x-user` stands in for a validated token's `sub` claim: the parity note's deferred `auth-jwt`
/// item is the one that replaces the header with a signature check, and it changes this type and nothing
/// else in the file — which is the argument for the attributes being a binding rather than something a
/// middleware parses out of a header inline.
@Singleton
public struct PrincipalDirectory: Sendable {
    /// The header naming the caller. Named once, for the same reason
    /// ``RequestEnvironment/zoneHeader`` is: two layers read it.
    public static let userHeader = "x-user"

    private static let principals: [String: Principal] = [
        "alice": Principal(user: "alice", roles: [.author], department: "research", clearance: 3),
        "bob": Principal(user: "bob", roles: [.author], department: "research", clearance: 1),
        "carol": Principal(user: "carol", roles: [.admin], department: "research", clearance: 2),
        "dave": Principal(user: "dave", roles: [.auditor], department: "operations", clearance: 5),
        "erin": Principal(
            user: "erin",
            roles: [.author],
            department: "research",
            clearance: 3,
            suspended: true
        ),
    ]

    /// The principal for `user`, or `nil` for a name the directory does not hold — which is
    /// *authentication* failing, and answered `401` by the layer that asked. Distinct from a principal
    /// that exists and is suspended, which is authorisation failing and answered `403`.
    public func principal(for user: String) -> Principal? {
        Self.principals[user]
    }

    /// The principal a request presents, or `nil` when it presents none the directory knows.
    public func principal(presentedBy request: HTTPRequest) -> Principal? {
        guard let user = request.headerFields[HTTPField.Name(Self.userHeader)!] else { return nil }
        return principal(for: user)
    }
}

/// The request-scoped caller: subject and environment attributes, resolved once at scope entry.
///
/// `@Scoped(seed: HTTPRequest.self)` and **throwing**, the shape ``Session`` established: an unknown or
/// absent `x-user` fails to construct the scope, and ``DocumentsController``'s
/// `@ErrorResponse(Unauthenticated.self, .unauthorized)` turns that into a `401`. Authentication is a
/// binding that fails to build; authorisation is a policy decision. Keeping them in different mechanisms
/// is what stops a gate from having to distinguish "no identity" from "identity refused" — the gate never
/// sees the first case.
///
/// **``ScreenAccess`` resolves the same principal a second time, and cannot avoid it today.** Two separate
/// reasons, both established by compiling the alternative rather than by reading the codegen:
///
/// - **A `@Factory` template's `@Inject` deps are resolved once, into an app `@Singleton`.** Injecting
///   `Caller` into ``ScreenAccess`` is `error: no binding produces 'Caller'`. That is correct and
///   permanent: `@Factory` is a lifetime of its own — the template is constructed per `create` call and is
///   not a binding, while the factory holding its `@Inject` members is — so the members resolve where the
///   *factory* is constructed, which is app scope. A template has no scoped form and is not supposed to.
///
///   Writing this file is what established that, by compiling the alternative rather than reading the
///   codegen, and it turned up a swift-wire diagnostic bug on the way: the guided note offered *scope
///   `_WireFactory_ControllerMiddleware_screenAccess` to `@Scoped(seed:)` too*, which named a synthesised
///   type with no declaration to annotate — and annotating the template instead was an `invalid
///   redeclaration of 'init(…)'`, since both macros synthesise one. Fixed upstream: a scope macro beside
///   `@Factory` is now refused outright as two lifetime macros on one declaration, and the note says what
///   is actually true.
/// - **And the ordering would defeat it anyway.** The fold is entered before `_wireEnterScope`, which
///   happens inside the fold's own terminal — so at the moment `create` is called there is no request
///   scope to construct anything in. Nor is there a channel from a middleware to the handler to carry a
///   resolution forward: the terminal destructures the box and discards the context.
///
/// Here that costs a second dictionary read; against a real identity provider it would cost a second round
/// trip — **which an application closes by caching the lookup, so the cost is not what wants fixing
/// upstream.** What a framework change would buy is narrower and better: the two tiers agreeing *by
/// construction* rather than by both happening to call the same method. They cannot diverge here, since
/// both go through ``PrincipalDirectory/principal(presentedBy:)``, which is the mitigation an app has.
///
/// And "let middleware be scoped" is probably the wrong answer to it: moving the fold inside the scope
/// costs the pre-authorisation property this gate exists for (a refusal currently skips scope construction
/// entirely) and drops every contributed header field from the `401`. The likelier answer is to leave the
/// gate where it is and move *authorisation* into the argument — a `RequestBound` with graph access, whose
/// seam already sits after scope entry. wire-mvc's
/// [`ScopeAwareMiddlewareAndBindings.md`](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/ScopeAwareMiddlewareAndBindings.md)
/// carries the three candidate designs, what each costs, and the sequence.
@Scoped(seed: HTTPRequest.self)
public struct Caller: Sendable {
    public let principal: Principal
    public let environment: RequestEnvironment

    @Inject public init(request: HTTPRequest, directory: PrincipalDirectory) throws {
        guard let principal = directory.principal(presentedBy: request) else { throw Unauthenticated() }
        self.principal = principal
        self.environment = RequestEnvironment.of(request)
    }

    /// The query this caller would put about `resource`. A helper rather than four call sites building
    /// the same value, so a handler's authorisation line names only what varies: the action and the thing.
    public func query(_ action: AccessAction, on resource: ResourceAttributes) -> AccessQuery {
        AccessQuery(subject: principal, action: action, environment: environment, resource: resource)
    }
}
