package import Configuration
package import HTTPAPIs
import HTTPTypes
import Logging
package import NIOHTTPServer
package import Wire
import WireConfiguration
package import WireMVC
package import WireMVCMiddleware
import WireMVCRouter

// The WireMVC-native composition root. `@Singleton` makes it a graph binding (its `@Inject` resolves);
// `@WireMVCBootstrap` makes the plugin generate the program entry point (`@main`) for a program consumer,
// or the companion `.wiremvc()` suite-trait factory for a test consumer. There is no `main.swift` and no
// hand-written `@main` — `swift run SwiftHttpServerExample` bootstraps the graph, constructs this type,
// registers the collated controllers onto the package `TrieRouteBuilder`, and serves on 127.0.0.1.
//
// `package` (with `package import Wire`) so a same-package test target can re-parse and re-compose these
// bindings — the real-backend suite serves this exact graph, the mocked suite supersedes the CouchDB
// backends with in-memory fakes and threads per-request smockable doubles through the keyed harness.

@Singleton
@WireMVCBootstrap
@Middleware(CORSMiddlewareKeys.factory)  // global: every route and the fallback alike
// The second global middleware, and the one that *answers*. Order is declaration order — CORS is folded
// outside this one — and that is what the file middleware's `respondingWith` depends on: CORS has already
// contributed `Access-Control-Allow-Origin` to the registry by the time a file response is written, and
// draining is what carries it onto a response the router never saw. Reversed, a cross-origin fetch of a
// static file would come back without the field. See `StaticFileServing.swift`.
@Middleware(GlobalMiddleware.serveStaticFiles)
package struct AppBootstrap {
    /// The CORS middleware's dependency, resolved from the graph like any other. `.oneOf` with credentials
    /// is the combination worth showing: allowed *because* it names one origin per response, where `.all`
    /// with credentials traps at construction.
    @Provides package static let cors = CORSConfiguration(
        allowOrigin: .oneOf(["https://allowed.example"]),
        allowMethods: [.get, .post, .delete],
        allowHeaders: [.contentType, .init("x-session")!],
        allowCredentials: true,
        maxAge: .seconds(600)
    )

    @Inject let config: ServerConfig

    /// The **pre-step**: runs before `Wire.bootstrap`, and its return value is the graph's `inputs:`.
    ///
    /// Two things have to happen before any binding exists, and this is the only place they can:
    ///
    /// 1. **`LoggingSystem.bootstrap`.** It traps on a second call and, more importantly, the unbound
    ///    default logger is captured at first access — so bootstrapping after the graph is built would
    ///    leave every binding constructed so far holding a logger that ignores this configuration. The
    ///    level itself comes from config (`LOG_LEVEL`), which is the ordinary reason to want config first.
    /// 2. **Building the `ConfigReader`** the whole graph shares, and handing it in as an input.
    ///
    /// Being pre-graph it can inject nothing — that is the trade for running first, and why it reads the
    /// environment directly here and nowhere else.
    package static func prepare() throws -> AppInputs {
        let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
        let level = Logger.Level(rawValue: config.string(forKey: "log.level", default: "info")) ?? .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }
        return AppInputs(config: config)
    }
    // Returns the *concrete* server, not `some HTTPServer`: the proposal's `Reader`/`ResponseSender`
    // are `~Copyable`, which a bare `some HTTPServer` opaque return can't express. The generated
    // `@main` (and `.wiremvc()` suite trait) binds to whatever concrete type this returns.
    package func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "SwiftHttpServerExample"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: config.host, port: config.port),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
    }

    // The package-provided `TrieRouteBuilder` is a `FinalizableHTTPServerRouteBuilder`: `WireMVC.apply`
    // registers routes onto it, and the generated entry point `finalize()`s it into the immutable
    // `FrozenTrieRouter` the server serves (build → freeze → serve).
    package func createRouteBuilder<Server: HTTPServer>(
        for server: borrowing Server
    ) -> some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)
    }

    // Mount the graph's wiring model (`introspect()` as JSON) at `/wiring` — unguarded (no `@Middleware`),
    // so the generated entry point registers it via `WireMVC.mountIntrospection` before `finalize()`.
    // Returning `nil` would skip it.
    package func mountIntrospectionAt() -> String? { "/wiring" }

    /// The app's own fallback for requests no route matched — the other half of the static-file seam.
    ///
    /// Without this the plugin synthesises a plain bodiless `404`, which is what most apps get and is
    /// indistinguishable from a route's own mapped `404`. Authoring one gives the three reachable
    /// `404`s distinct bodies, which is what lets `StaticFileServingTests` assert *which* layer answered
    /// rather than only that something did.
    ///
    /// `@RawRoute` is required, not chosen: there is no matched template, so there is nothing to decode
    /// against and nothing to encode a return value into — a non-raw `@NotFound` is diagnosed. `@Path` is
    /// unavailable here for the same reason. The generated registration wraps the sender in a
    /// `ResponseHeaderApplyingSender`, so the head written below still picks up every global
    /// middleware's contributed field; a fallback is the one response nobody declares and therefore the
    /// easiest place to lose them.
    ///
    /// Registered via `registerNotFound` *before* `finalize()`, so it is a real route inside the router —
    /// which is precisely why the static middleware, sitting outside the router, gets to answer over it.
    ///
    /// **`consuming sending Sender`**, which is worth spelling here because for a while it could not be.
    /// The generated registration passes `ResponseHeaderApplyingSender(wrapping: responseSender, …)`, and
    /// that wrapper holds the `ResponseHeaderRegistry`; the registry travels inside the request context,
    /// which the proposal's `HTTPServerRequestHandler.handle` takes as plain `consuming` while `reader`
    /// and `responseSender` are `consuming sending`. So the registry was task-isolated, merging it into an
    /// otherwise-disconnected sender closed the region, and this parameter had to be plain `consuming` —
    /// a `@NotFound` being the worst case of it, since `registerNotFound` folds no middleware and its
    /// sender is therefore always the untransformed, wrapped one.
    ///
    /// wire-mvc made the registry a `~Copyable` value carried in `WireDisconnected`, so the wrapper's two
    /// inputs are both disconnected and the composite survives as `sending`. This declaration is a
    /// regression guard on that: the exact shape that used to fail, in a real app, and it stops compiling
    /// if the registry ever stops being linear.
    @NotFound
    @RawRoute
    package func noRoute<Sender: HTTPResponseSender & ~Copyable>(
        request: HTTPRequest,
        responseSender: consuming sending Sender
    ) async throws where Sender.Writer: ~Copyable {
        try await WireMVCOutcome.json(
            NoRoute(unmatched: request.path ?? "", method: request.method.rawValue),
            status: .notFound
        ).send(on: responseSender)
    }
}

/// The server bind config the composition root injects. `package` so a test target re-composing the app can
/// supersede the production port with an OS-ephemeral `0` — see `serverConfig()`.
package struct ServerConfig: Sendable {
    package let host: String
    package let port: Int
    package init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// The graph's inputs — the values built *before* construction and handed in by ``AppBootstrap/prepare()``.
///
/// The reader stays an input even though no provider below calls it any more: `@ConfigProperty` does not
/// remove the reader, it moves the *call*. Each annotated parameter becomes a synthesised producer that
/// resolves a `ConfigReader` from the graph like any other dependency, so something still has to bind one.
/// Making it an input rather than a `@Provides` keeps it built before the graph, alongside the logging
/// bootstrap that has to run first.
///
/// Declared in the app package rather than in `Controllers`, because inputs are the *consumer's* to
/// supply — a library cannot decide what its consumers must pass in.
@GraphInputs
package struct AppInputs: Sendable {
    package let config: ConfigReader

    package init(config: ConfigReader) {
        self.config = config
    }
}

/// The production binding for `ServerConfig`, read from configuration rather than hardcoded: the bind
/// address is a deployment fact.
///
/// `server.host` → `SERVER_HOST`, `server.port` → `SERVER_PORT`, with the old fixed values as defaults so
/// `swift run` still serves on `127.0.0.1:8080` with nothing exported. Only the app's own `createServer()`
/// reads it: a suite serves on the server its `WireMVCTestMode` carries.
@Provides package func serverConfig(
    @ConfigProperty(forKey: "server.host", default: "127.0.0.1") host: String,
    @ConfigProperty(forKey: "server.port", default: 8080) port: Int
) -> ServerConfig {
    ServerConfig(host: host, port: port)
}
