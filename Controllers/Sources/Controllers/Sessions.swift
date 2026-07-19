import HTTPTypes
public import Wire
public import WireMVC

// The M5.4 request-scoped-controller case, portable across every runtime. A `@Scoped(seed:) @Controller`
// is constructed fresh per request from the request seed (the bridge proxy's `_wireEnterScope` thunk),
// injecting a request-scoped `Session` built from that same request — alongside the app-`@Singleton`
// `TodosController` in one graph. A controller-scope gate writes 401 for an unauthenticated request
// *before* the terminal enters the scope (Model B short-circuit), which is the auth-failure division of
// labour: gates own pre-handler policy (401/403), the request scope owns the authenticated identity.

/// Key for the controller-scope session gate.
public enum SessionMiddleware {
    public static let requireSession = FactoryKey()
}

/// A request-scoped identity — `@Scoped(seed: HTTPRequest.self)` makes it a per-request binding built
/// from the request that opened the scope, so each request gets a fresh `Session`. The `RequireSession`
/// gate guarantees a non-empty `x-session` header reached the terminal, so this init trusts it.
@Scoped(seed: HTTPRequest.self)
public struct Session: Sendable {
    public let user: String
    @Inject public init(request: HTTPRequest) {
        let token = request.headerFields[HTTPField.Name("x-session")!] ?? ""
        self.user = "user:\(token)"
    }
}

public struct Me: Codable, Sendable, Equatable {
    public let user: String
}

/// A **request-scoped** controller — constructed fresh per request from the `HTTPRequest` seed,
/// injecting the request-scoped `Session`. Coexists with the app-`@Singleton` `TodosController`. The
/// controller-scope `RequireSession` gate short-circuits an unauthenticated request with 401 before the
/// terminal constructs the scope, so `Session`'s init only ever runs for an authenticated request.
@Scoped(seed: HTTPRequest.self)
@Controller("/me")
@Middleware(SessionMiddleware.requireSession)
public struct MeController: Sendable {
    @Inject var session: Session

    @Get
    @JSONResponse
    public func me() async throws -> Me {
        Me(user: session.user)
    }
}

/// The controller-scope session gate — generic, dep-free, Model B: with no `x-session` header it writes
/// 401 itself (consuming the sender), the box becomes `.responded`, and `MeController`'s terminal (and
/// its scope entry) is skipped. It still calls `next` — every middleware runs. Mirrors `RequireAPIKey`.
@Factory(SessionMiddleware.requireSession)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the box roles in order (canonical)
public struct RequireSession<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let session = input.peekedRequest.headerFields[HTTPField.Name("x-session")!] ?? ""
        guard input.isPending, session.isEmpty else {
            return try await next(input)
        }
        return try await next(
            input.responding { sender in
                var writer = sender
                try await writer.sendAndFinish(HTTPResponse(status: .unauthorized))
            }
        )
    }
}
