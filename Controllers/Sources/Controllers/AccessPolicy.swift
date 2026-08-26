public import HTTPTypes
public import Wire

// Attribute-based access control, as bindings. The `auth-abac` shape: a decision is a function of four
// attribute sets — **subject**, **action**, **resource**, **environment** — and each rule about them is
// its own `@Singleton`, contributed to one `CollectedKey` and combined by an engine that knows none of
// them individually.
//
// What that buys over the API-key gate in `TodosMiddleware.swift` is not strictness, it is *where the
// policy lives*. The gate encodes its rule in the annotation's placement: `@Middleware(requireAPIKey)` on
// `delete` and nowhere else means "deleting needs a key", and the only way to read the app's policy is to
// grep for the annotation. Here the placement says nothing — one gate sits on the whole controller — and
// the policy is the *set*, which can be listed, ordered, tested one rule at a time, and extended by adding
// a binding rather than by editing a route.
//
// **The decision does not fit in one tier, and that is structural rather than a choice made here.** A
// route-scope middleware is handed the request and nothing else: `RequestResponseMiddlewareBox` carries
// the request, the context, the reader and the sender, and the generated terminal discards the context
// before calling the handler. So a middleware cannot be told which route it is on and cannot see the
// matched path parameters; it cannot inject a request-scoped binding either, because a `@Factory`
// template resolves its deps once into an app `@Singleton` and the fold runs before the scope is entered
// (see ``Caller``, which records what the compiler says about each half). Above all it cannot see the
// **resource**, which has not been loaded yet.
//
// So the same policy set is consulted twice, by two callers with different attributes in hand:
//
// 1. ``PolicyEngine/screen(subject:action:environment:)`` from ``ScreenAccess``, the gate, with no
//    resource. It answers **deny or undecided, never permit** — see that method for why treating a permit
//    as final there would be a security bug rather than an optimisation.
// 2. ``PolicyEngine/authorize(_:)`` from the handler, once the document is in hand, with every attribute.
//    Plus ``PolicyEngine/permits(_:)`` for the collection route, which filters rather than refuses.
//
// The rules themselves are written once and do not know which caller is asking: a rule that needs the
// resource returns ``PolicyDecision/notApplicable`` when there isn't one, and that single convention is
// what makes one set serve both tiers.
//
// This file is the part an application edits — the attributes and the rules. The machinery they are
// edited against (the combining algorithm, the refusal it produces, and where subject attributes come
// from) is in `PolicyEngine.swift`; the gate itself is in `AccessGate.swift`.

// MARK: - The attributes

/// A subject attribute: what the caller is allowed to be, as opposed to what they are allowed to do.
///
/// Roles are *attributes here*, not permissions — no rule reads `.admin` and grants "delete"; rules read
/// it and grant or refuse in combination with the other three attribute sets. That is the whole
/// difference between this and role-based access control, and ``AdministratorGrant`` plus
/// ``ClearanceRule`` is where it becomes visible: an administrator is granted, and still refused.
public enum Role: String, Sendable, Hashable {
    /// Writes their own documents. The baseline.
    case author
    /// Grants any action, and is nobody's exemption from a rule that denies — see ``AdministratorGrant``.
    case admin
    /// Exempt from the department boundary, and only from that one: an auditor reads across the
    /// organisation but is still bounded by classification.
    case auditor
}

/// The **subject** attributes — who is asking, resolved from the request by ``PrincipalDirectory``.
///
/// `suspended` is deliberately an attribute of the principal rather than an absence from the directory. A
/// suspended account still authenticates; what changes is that every policy decision goes against it. Told
/// apart from an unknown user, this is the difference between `403` and `401`, and the two answers are
/// produced by different layers here — the gate and the scope — which is what makes them testable apart.
public struct Principal: Sendable, Equatable {
    public let user: String
    public let roles: Set<Role>
    public let department: String
    public let clearance: Int
    public let suspended: Bool

    public init(user: String, roles: Set<Role>, department: String, clearance: Int, suspended: Bool = false) {
        self.user = user
        self.roles = roles
        self.department = department
        self.clearance = clearance
        self.suspended = suspended
    }
}

/// The **action** attribute. One value per thing that can be attempted, mapped from the request method by
/// ``ScreenAccess`` and named directly by each handler.
///
/// There is no `list`. A collection route asks the same `read` question once per document and keeps the
/// ones that pass (``DocumentsController/list()``), so "may I see this" has exactly one spelling and the
/// list route cannot drift away from the item route's answer.
public enum AccessAction: String, Sendable, Equatable {
    case read
    case create
    case update
    case delete

    /// Whether the action changes state. Read by ``NetworkZoneRule``, which is the one rule that cares
    /// about the shape of the action rather than its identity.
    public var isMutating: Bool { self != .read }
}

/// The **resource** attributes — the half a gate cannot have, because reading them means loading the
/// thing, which is the handler's job.
///
/// A struct separate from ``Document`` so a *proposed* resource can be described before one exists:
/// `POST /documents` authorises against the attributes the new document would have, which is the only way
/// to refuse a create that would produce a document its own author could not read. See
/// ``DocumentsController/create(input:)``.
public struct ResourceAttributes: Sendable, Equatable {
    public let owner: String
    public let department: String
    public let classification: Int

    public init(owner: String, department: String, classification: Int) {
        self.owner = owner
        self.department = department
        self.classification = classification
    }
}

/// The **environment** attributes — facts about the request that are about neither the caller nor the
/// thing being reached.
///
/// One attribute, the network zone, taken from an `x-network` request header. That header stands in for
/// what a deployment actually has: a value a trusted reverse proxy stamps and strips, which is how network
/// zone reaches an application in every real system that uses it. Treating a client-settable header as
/// trusted would be the bug; the header is here because the *policy tier* is what this example is about,
/// and an environment attribute with no way to vary it in a test is an untested rule.
public struct RequestEnvironment: Sendable, Equatable {
    public enum Zone: String, Sendable, Equatable {
        case internalNetwork = "internal"
        case external
    }

    public let zone: Zone

    public init(zone: Zone) {
        self.zone = zone
    }

    /// The header the zone is read from, named once so the gate and the request-scoped ``Caller`` cannot
    /// disagree about it.
    public static let zoneHeader = "x-network"

    /// Resolve the zone from a request. Anything that is not the literal `internal` — including an absent
    /// header — is `external`, because the default for a network-zone attribute has to be the untrusted
    /// one: a misconfigured proxy then costs a refusal rather than a grant.
    public static func of(_ request: HTTPRequest) -> RequestEnvironment {
        let value = request.headerFields[HTTPField.Name(zoneHeader)!]
        return RequestEnvironment(zone: value == Zone.internalNetwork.rawValue ? .internalNetwork : .external)
    }
}

/// One question put to the policy set.
///
/// `resource` is optional, and that optionality is the tier boundary made into a type: the gate builds a
/// query without one and the handler builds a query with one, and a rule decides which of the two it can
/// answer by pattern-matching on it.
public struct AccessQuery: Sendable {
    public let subject: Principal
    public let action: AccessAction
    public let environment: RequestEnvironment
    public let resource: ResourceAttributes?

    public init(
        subject: Principal,
        action: AccessAction,
        environment: RequestEnvironment,
        resource: ResourceAttributes? = nil
    ) {
        self.subject = subject
        self.action = action
        self.environment = environment
        self.resource = resource
    }
}

// MARK: - The policies

/// What one rule says about one query.
///
/// Three cases, not two. ``notApplicable`` is what makes a policy *set* composable: a rule that has
/// nothing to say about this query says so, rather than having to invent a permit (which would make it an
/// authority over questions it does not understand) or a deny (which would make every rule a veto over
/// every route). It is also the single mechanism by which one set serves both tiers — a resource-reading
/// rule is `notApplicable` at the gate by construction.
public enum PolicyDecision: Sendable, Equatable {
    case permit
    case deny(String)
    case notApplicable
}

/// A rule about the four attribute sets. Each conformer is an ordinary `@Singleton` contributed to
/// ``AccessPolicies/all``; nothing else in the app names one by type.
public protocol AccessPolicy: Sendable {
    /// How this policy identifies itself in a denial. Defaulted to the type's own name, which is what
    /// makes a `403` body say *which* rule refused without anyone maintaining a table of strings.
    var name: String { get }

    /// Pure and synchronous, and both are load-bearing. Pure, so ``PolicyEngine/permits(_:)`` can run the
    /// whole set once per document while filtering a collection without that becoming N round trips;
    /// synchronous, so a rule cannot quietly acquire a dependency on a network call that the filter would
    /// then pay for per row. A rule that genuinely needs remote state belongs behind an attribute
    /// resolved once per request — which is what ``PrincipalDirectory`` is.
    func evaluate(_ query: AccessQuery) -> PolicyDecision
}

extension AccessPolicy {
    public var name: String { String(describing: Self.self) }
}

/// The key every rule contributes to and the engine consumes. Adding a rule to the app is adding a
/// `@Contributes` annotation — there is no registry to edit and no place that lists them.
public enum AccessPolicies {
    public static let all = CollectedKey<any AccessPolicy>()
}

/// Denies everything for a suspended principal. **Resource-independent**, so the gate refuses the request
/// before the handler runs and before the store is touched — one of exactly two rules that can.
///
/// First by `withOrder:` for reporting rather than for correctness: the combining algorithm is
/// deny-overrides, so order cannot change the outcome, but it does decide which denial is *named* when
/// more than one applies, and "suspended" is the useful thing to be told.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 10)
public struct SuspendedSubjectRule: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        query.subject.suspended ? .deny("the account \(query.subject.user) is suspended") : .notApplicable
    }
}

/// Denies mutating actions from outside the internal network. The second **resource-independent** rule,
/// and the reason the gate tier is worth having at all: a `DELETE` arriving from the public internet is
/// refused without a lookup, which is what a pre-authorisation filter is for.
///
/// Reads two attribute sets and neither is the subject's — the case that is awkward to express in a model
/// where authorisation hangs off an identity, and ordinary here.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 20)
public struct NetworkZoneRule: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        guard query.action.isMutating, query.environment.zone == .external else { return .notApplicable }
        return .deny("\(query.action.rawValue) is not permitted from the external network")
    }
}

/// Denies a subject whose clearance does not reach the resource's classification. **Resource-reading**, so
/// it abstains at the gate and decides in the handler.
///
/// This is the rule that proves a grant is not an override: `AdministratorGrant` permits, this denies, and
/// deny-overrides means the administrator is refused. Pinned by
/// `anAdministratorIsStillBoundedByClassification`.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 30)
public struct ClearanceRule: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        guard let resource = query.resource else { return .notApplicable }
        guard query.subject.clearance < resource.classification else { return .notApplicable }
        return .deny(
            "clearance \(query.subject.clearance) does not reach classification \(resource.classification)"
        )
    }
}

/// Denies reaching across a department boundary, exempting an auditor. **Resource-reading.**
///
/// The exemption is a *role read as an attribute*: nothing here grants an auditor anything, it only stops
/// this one rule from denying — the auditor still needs a permit from elsewhere in the set, and is still
/// subject to ``ClearanceRule``. An administrator is deliberately **not** exempt: a department is a
/// boundary in this app, and an administrator is an authority within one.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 40)
public struct DepartmentRule: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        guard let resource = query.resource else { return .notApplicable }
        guard resource.department != query.subject.department, !query.subject.roles.contains(.auditor) else {
            return .notApplicable
        }
        return .deny("\(resource.department) is not \(query.subject.user)'s department")
    }
}

/// Permits any action on a resource the subject owns. **Resource-reading**, and the only permit most
/// requests ever get.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 50)
public struct OwnerGrant: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        guard let resource = query.resource, resource.owner == query.subject.user else { return .notApplicable }
        return .permit
    }
}

/// Permits reading, to anyone. Resource-independent, and therefore evaluated at the gate too — where it is
/// **discarded**, because the gate never accepts a permit. See ``PolicyEngine/screen(subject:action:environment:)``.
///
/// What stops this from making every document world-readable is that a permit does not beat a deny:
/// ``ClearanceRule`` and ``DepartmentRule`` still refuse, and `list` filters on the same answer.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 60)
public struct ReadGrant: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        query.action == .read ? .permit : .notApplicable
    }
}

/// Permits any action to an administrator. Resource-independent — and, again, a *grant*: it survives only
/// as far as the first rule that denies.
@Singleton
@Contributes(to: AccessPolicies.all, withOrder: 70)
public struct AdministratorGrant: AccessPolicy {
    public func evaluate(_ query: AccessQuery) -> PolicyDecision {
        query.subject.roles.contains(.admin) ? .permit : .notApplicable
    }
}
