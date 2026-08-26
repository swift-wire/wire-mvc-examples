public import HTTPAPIs
public import HTTPTypes
public import Wire
public import WireMVC

extension ControllerMiddleware {
    /// The key ``DocumentsController`` names in `@Middleware(ControllerMiddleware.screenAccess)`.
    ///
    /// **Controller scope, not route scope**, and the item that asked for this said route scope. The
    /// reason it changed is the point of the whole file: once the policy is a set of bindings, the
    /// annotation stops carrying policy. A route-scope placement would say "this route is the one that
    /// needs screening", which is a second, hand-maintained encoding of a decision the set already makes —
    /// and a wrong one the moment a rule changes. So the gate goes on once, screens every route the same
    /// way, and derives the *action* attribute from the request method, which is where an action attribute
    /// comes from.
    ///
    /// A rule that genuinely applied to one route and not its siblings **is** expressible now, and was not
    /// when this was written. The box carries a ``RouteContext`` — the matched template and its path
    /// parameters — so one gate folded once can read which route it is on and key policy on it. The
    /// wire-mvc change that added it was forced by this file: per-route policy previously needed a distinct
    /// `FactoryKey` and a distinct middleware type per route, which is a cost no rule is worth.
    ///
    /// It is still not used here, and the reason is the one above rather than the one that has gone. The
    /// set already decides which requests need screening; a placement — or a `switch` on
    /// `peekedRoute?.template` — would be a second, hand-maintained encoding of that decision, wrong the
    /// moment a rule changes. What changed is that this is now a choice rather than a constraint, which is
    /// worth saying plainly: the design did not depend on the limitation it was written under.
    public static let screenAccess = FactoryKey()
}

/// The gate: refuse what can be refused from the request alone, and get out of the way otherwise.
///
/// Three things it deliberately does not do, each because it cannot:
///
/// - **It never permits.** ``PolicyEngine/screen(subject:action:environment:)`` returns a denial or
///   nothing, because the rules that read the resource have abstained. A gate that treated a permit as
///   final would wave through precisely the requests the abstaining rules exist to stop.
/// - **It never answers `401`.** A request presenting no known principal is forwarded untouched, and the
///   request-scoped ``Caller`` binding fails to construct a moment later, which the controller's
///   `@ErrorResponse` maps. Authentication is not the gate's question, and splitting it out is what keeps
///   this `intercept` free of a "is this even a user" branch.
/// - **It never loads anything.** The resource is the handler's to fetch; see ``DocumentsController``.
///
/// What it *is* worth having: an external `DELETE` from a suspended account is refused here, before the
/// scope is entered and before the store is touched. That is a pre-authorisation filter doing its job, and
/// it is the half of the decision that a per-request scope would be too late for.
@Factory(ControllerMiddleware.screenAccess)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the box roles in order (canonical)
public struct ScreenAccess<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var engine: PolicyEngine
    /// The second resolution of the subject, and the one that cannot be shared with the request scope —
    /// see ``Caller`` for why, and for what would have to change upstream to close it.
    @Inject var directory: PrincipalDirectory

    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let request = input.peekedRequest
        // `isPending` first, for the reason `ServeStaticFiles` states: an outer middleware may already
        // have answered and the box has no sender left. First decision wins, and this is not it.
        guard input.isPending,
            let action = Self.action(of: request.method),
            let principal = directory.principal(presentedBy: request),
            let denial = engine.screen(
                subject: principal,
                action: action,
                environment: RequestEnvironment.of(request)
            )
        else {
            return try await next(input)
        }
        // `respondingWith`, not raw `responding`, so the response-header registry is drained onto this
        // answer: a refusal is still a response a browser fetched, and dropping CORS's
        // `Access-Control-Allow-Origin` from it would leave the caller unable to read the `403` it was
        // given. `StaticFileServing.swift` argues the same choice at length for the global tier.
        return try await next(try await input.respondingWith(try .json(denial, status: .forbidden)))
    }

    /// The **action** attribute, from the request method. `nil` for a method this controller registers no
    /// route for, which is declined rather than refused: the router owns that answer (`405`, or `404` on
    /// the runtimes that spell it that way), and a gate inventing a `403` for it would be describing a
    /// route that does not exist.
    private static func action(of method: HTTPRequest.Method) -> AccessAction? {
        switch method {
        case .get, .head: .read
        case .post: .create
        case .patch, .put: .update
        case .delete: .delete
        default: nil
        }
    }
}
