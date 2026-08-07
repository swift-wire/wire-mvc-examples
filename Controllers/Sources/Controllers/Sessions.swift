import Foundation
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
// `TodosController` in one graph. **Authentication is throw-at-scope-construction (M5.4E):** the `Session`
// binding *throws* `Unauthenticated` at scope entry when the `x-session` header is absent, and `MeController`
// declares `@ErrorResponse(Unauthenticated.self, .unauthorized)` — the generated terminal enters the scope
// inside its `catch`, so the throw maps to 401. No gate, no double-read, no sentinel: a request-scoped
// binding that fails to build maps like a handler throw (gates are reserved for authorization).

/// Thrown by `Session`'s self-production when the request carries no `x-session` header — mapped to 401 by
/// `MeController`'s `@ErrorResponse`. A plain framework-free error type (no WireMVC import), matched by type.
public struct Unauthenticated: Error {}

/// The cookie the session token rides in. A cookie rather than a bespoke header because that is what a
/// browser sends back on its own — which is the whole point of a session, and what `Set-Cookie` on the
/// response is for.
public let sessionCookieName = "session"

/// Pull one cookie's value out of a `Cookie:` request field. Request cookies are a single field with
/// `; `-separated pairs (RFC 6265 §5.4) — unlike `Set-Cookie`, which is one field *per* cookie and must
/// never be folded, which is why the response side appends rather than sets.
public func cookieValue(_ name: String, in request: HTTPRequest) -> String? {
    guard let header = request.headerFields[.cookie] else { return nil }
    for pair in header.split(separator: ";") {
        let trimmed = pair.drop { $0 == " " }
        guard let equals = trimmed.firstIndex(of: "=") else { continue }
        if trimmed[trimmed.startIndex..<equals] == name {
            return String(trimmed[trimmed.index(after: equals)...])
        }
    }
    return nil
}

/// The `Set-Cookie` value for a minted session, and for clearing one. `HttpOnly` so script cannot read it;
/// `Path=/` so it is sent to every route; `SameSite=Lax` as the sane default a login flow wants.
public func sessionCookie(_ token: String) -> String {
    "\(sessionCookieName)=\(token); Path=/; HttpOnly; SameSite=Lax"
}

public func clearedSessionCookie() -> String {
    "\(sessionCookieName)=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
}

/// A request-scoped identity — `@Scoped(seed: HTTPRequest.self)` makes it a per-request binding built from
/// the request that opened the scope, so each request gets a fresh `Session`. Generic over the opaque
/// `SessionManager` (an app `@Singleton(as:)`) because `some P` can't be a stored property — the same lift
/// `MeController` uses for its repository. **The binding is the auth check:** an absent `x-session` header
/// throws `Unauthenticated` here, at scope construction, so `Session` only ever exists for an authenticated
/// request.
@Scoped(seed: HTTPRequest.self)
public struct Session<Manager: SessionManager>: Sendable {
    public let user: String
    private let token: String
    private let manager: Manager
    /// Injects the request seed (fresh per request) *and* the app-`@Singleton` `SessionManager` (shared) —
    /// so this scope entry borrows the singleton, ready to resolve the token to its stored session id.
    /// Throws `Unauthenticated` (mapped to 401 by the controller's `@ErrorResponse`) when the request
    /// carries no session cookie — so a browser that has never logged in gets a 401 rather than a scope
    /// that half-exists.
    @Inject public init(request: HTTPRequest, manager: Manager) throws {
        guard let token = cookieValue(sessionCookieName, in: request), !token.isEmpty else {
            throw Unauthenticated()
        }
        self.token = token
        self.user = "user:\(token)"
        self.manager = manager
    }

    /// Resolve the stable session id from the store. The async DB read happens here, during request
    /// handling — not in `init` (mirroring how the handler calls `repository.all()`) — so scope
    /// construction stays synchronous (it only throws the auth check, no `await`).
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
/// `@Singleton(as:)`), lifted as generic parameters. **`@ErrorResponse(Unauthenticated.self, .unauthorized)`**
/// maps the `Session` binding's scope-entry throw to 401: an unauthenticated request fails to construct the
/// scope, and the generated terminal — which enters the scope inside its `catch` — turns that into a 401.
@Scoped(seed: HTTPRequest.self)
@Controller("/me")
@ErrorResponse(Unauthenticated.self, .unauthorized)
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

// MARK: - The cookie lifecycle

public struct Credentials: Codable, Sendable {
    public let user: String
    public init(user: String) { self.user = user }
}

public struct LoggedIn: Codable, Sendable, Equatable {
    public let user: String
    public init(user: String) { self.user = user }
}

/// Minting and clearing the session cookie — the half a bespoke header could never do.
///
/// Both routes return a **labelled response tuple**, so the `Set-Cookie` is a value the handler produces
/// rather than something it reaches out and mutates. `logout` returns `(status:headers:)` with no body and
/// therefore carries no response annotation at all: its return type already says there is no body and that
/// the status is computed.
///
/// App-`@Singleton`, not request-scoped: logging *in* is the one route that must work without a session, so
/// it cannot depend on the request-scoped `Session` that throws when the cookie is absent.
@Singleton
@Controller("/session")
// App-scoped but consumes `SessionManager`, which a keyed suite binds per request — so under a mocked
// suite it is rebuilt per request to see the double. The guided diagnostic names this exact fix.
@TestScopable
public struct SessionController<Manager: SessionManager>: Sendable {
    @Inject var manager: Manager

    /// Mint a token, persist it (the store records it on first sight), and hand it back as a cookie the
    /// browser will send on every subsequent request.
    @Post("/login")
    @JSONResponse
    public func login(
        @JSONBody credentials: Credentials
    ) async throws -> (headers: HTTPFields, body: LoggedIn) {
        let token = UUID().uuidString
        _ = try await manager.sessionID(for: token)
        var headers = HTTPFields()
        headers[values: .setCookie].append(sessionCookie(token))
        return (headers, LoggedIn(user: credentials.user))
    }

    /// Clear it. `Max-Age=0` is how a server deletes a cookie — there is no other mechanism.
    @Post("/logout")
    public func logout() -> (status: HTTPResponse.Status, headers: HTTPFields) {
        var headers = HTTPFields()
        headers[values: .setCookie].append(clearedSessionCookie())
        return (.noContent, headers)
    }
}
