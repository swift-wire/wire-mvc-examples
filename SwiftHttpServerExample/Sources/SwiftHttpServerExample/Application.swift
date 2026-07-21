import Logging
import NIOHTTPServer
import Wire
import WireMVC
import WireMVCRouter  // the package-provided native router (TrieRouteBuilder / FrozenTrieRouter)

/// The runtime configuration the app is built from. The serving `@main` supplies a fixed host/port;
/// the test target supplies its own (an ephemeral port), so both build the app the same way.
protocol AppArguments {
    var hostname: String { get }
    var port: Int { get }
}

/// The trie route builder specialised to this runtime's server type.
typealias ServerRouteBuilder = TrieRouteBuilder<
    NIOHTTPServer.RequestContext, NIOHTTPServer.Reader, NIOHTTPServer.ResponseSender
>

/// Assembles the app, shared by the serving `@main` and the test target. `Wire.bootstrap()`
/// constructs the in-memory backend and injects it into the collated (framework-free) TodosController;
/// `WireMVC.apply` registers the controllers' routes onto a `TrieRouteBuilder`, and `mountIntrospection`
/// adds the cross-runtime `/wiring` endpoint. Returns the server and the *unfrozen* builder: both the
/// `@main` and the test `finalize()` it into the immutable `FrozenTrieRouter` and serve that (the test
/// reads the bound port first) — the build → freeze → serve lifecycle the package router provides.
func buildApplication(
    _ arguments: some AppArguments
) async throws -> (server: NIOHTTPServer, router: ServerRouteBuilder) {
    let graph = try await Wire.bootstrap()

    let server = NIOHTTPServer(
        logger: Logger(label: "SwiftHttpServerExample"),
        configuration: try .init(
            bindTarget: .hostAndPort(host: arguments.hostname, port: arguments.port),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
    )

    var builder = ServerRouteBuilder(for: server)
    try WireMVC.apply(graph, to: &builder)
    try WireMVC.mountIntrospection(for: graph, into: &builder)

    return (server, builder)
}
