import HTTPTypes
public import Wire
public import WireMVC

/// The app-`@Singleton` session store — one per app, shared across every request. Each runtime binds its
/// own `@Singleton(as: SessionManager.self)` backend against its database (the same opaque-lift pattern as
/// `TodoRepository`), so the token→session-id mapping lives in that runtime's real store. The request-scoped
/// `Session` *borrows* it (the M5.4 capture-dep) and resolves the token to a **stable** id: the same token
/// yields the same id across requests because the store persists it. Declared here (framework-free) but not
/// satisfied here — each executable supplies the DB-backed implementation.
public protocol SessionManager: Sendable {
    /// The session id for `token`, minted and persisted on first sight, stable thereafter.
    func sessionID(for token: String) async throws -> String
}

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

/// A request-scoped identity — `@Scoped(seed: HTTPRequest.self)` makes it a per-request binding built from
/// the request that opened the scope, so each request gets a fresh `Session`. Generic over the opaque
/// `SessionManager` (an app `@Singleton(as:)`) because `some P` can't be a stored property — the same lift
/// `MeController` uses for its repository. The `RequireSession` gate guarantees a non-empty `x-session`
/// header reached the terminal, so this init trusts it.
@Scoped(seed: HTTPRequest.self)
public struct Session<Manager: SessionManager>: Sendable {
    public let user: String
    private let token: String
    private let manager: Manager
    /// Injects the request seed (fresh per request) *and* the app-`@Singleton` `SessionManager` (shared) —
    /// so this scope entry borrows the singleton, ready to resolve the token to its stored session id.
    @Inject public init(request: HTTPRequest, manager: Manager) {
        let token = request.headerFields[HTTPField.Name("x-session")!] ?? ""
        self.token = token
        self.user = "user:\(token)"
        self.manager = manager
    }

    /// Resolve the stable session id from the store. The async DB read happens here, during request
    /// handling — not in `init` (mirroring how the handler calls `repository.all()`) — so scope
    /// construction stays synchronous.
    public func id() async throws -> String {
        try await manager.sessionID(for: token)
    }
}

public struct Me: Codable, Sendable, Equatable {
    public let user: String
    public let id: String
}

/// A **request-scoped** controller — constructed fresh per request from the `HTTPRequest` seed, injecting
/// the request-scoped `Session`. Coexists with the app-`@Singleton` `TodosController`. Generic over **both**
/// opaque app singletons it reaches: the `TodoRepository` backend and the `SessionManager` store (each an
/// `@Singleton(as:)`), lifted as generic parameters. The controller-scope `RequireSession` gate
/// short-circuits an unauthenticated request with 401 before the terminal constructs the scope, so
/// `Session` only ever backs an authenticated request.
@Scoped(seed: HTTPRequest.self)
@Controller("/me")
@Middleware(SessionMiddleware.requireSession)
public struct MeController<Repository: TodoRepository, Manager: SessionManager>: Sendable {
    @Inject var session: Session<Manager>  // request-scoped, generic over the opaque store
    // The app's opaque-lifted backend (`@Singleton(as: TodoRepository.self)`, `some TodoRepository`),
    // injected as a lifted generic parameter — the same portable shape `TodosController` uses. A
    // request-scoped controller *borrowing* the shared app backend is the idiomatic M5.4 case.
    @Inject var repository: Repository

    @Get
    @JSONResponse
    public func me() async throws -> Me {
        // Prove the opaque backend resolves into (and is callable from) a request-scoped controller.
        _ = try await repository.all()
        return Me(user: session.user, id: try await session.id())
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
