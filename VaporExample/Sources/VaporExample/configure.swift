import OpenAPIVapor  // VaporTransport (a ServerTransport)
import Configuration
import Logging
import Vapor
import Wire
import WireMVC
import WireMVCServerTransport

// The app assembly, shared by the serving `@main` and the test target — the Vapor-idiomatic
// `configure(_:)`. `Wire.bootstrap()` constructs the MongoDB backend (connecting to the database)
// and injects it into the collated, framework-free TodosController; we register a native Vapor route
// AND bridge the proposal-native WireMVC
// controllers onto Vapor's transport via the WireMVCServerTransport adapter (they coexist), then
// mount the cross-runtime introspection endpoint. The container's lifecycle is tied to the app:
// `@Teardown` runs on shutdown via a lifecycle handler.
func configure(_ app: Application) async throws {
    // This function is the pre-step: the same two things happen before construction that `prepare()` does
    // in the proposal runtime's `@WireMVCBootstrap` app — bootstrap logging, then build the one
    // `ConfigReader` the graph shares and hand it in as a graph input.
    let graph = try await Wire.bootstrap(inputs: bootstrapConfiguration())

    // A native Vapor route — coexists with the WireMVC-applied /todos/* on the same app.
    app.get("health") { _ in "OK" }

    // The WireMVC controllers, bridged onto Vapor's transport via the ServerTransport adapter, plus
    // the introspection endpoint.
    let transport = VaporTransport(routesBuilder: app)
    try WireMVCServerTransport.apply(graph, to: transport)
    try WireMVCServerTransport.mountIntrospection(for: graph, on: transport)

    // On shutdown, tear down the graph — which disconnects the MongoDB backend.
    app.lifecycle.use(WireGraphTeardown(teardown: { await graph.teardown() }))
}

/// Runs the Wire graph's `@Teardown` actions when the application shuts down, so the MongoDB
/// connection is closed whether the app exits normally or a test finishes. Teardown errors are
/// logged rather than thrown — shutdown is best-effort by the time it runs.
struct WireGraphTeardown: LifecycleHandler {
    let teardown: @Sendable () async -> [any Error]

    func shutdownAsync(_ application: Application) async {
        for error in await teardown() {
            application.logger.report(error: error)
        }
    }
}

/// The graph's inputs — the `ConfigReader` every provider injects instead of building its own. Declared in
/// this package rather than in `Controllers`: inputs are the consumer's to supply, and a library cannot
/// decide what its consumers must pass in.
@GraphInputs
struct AppInputs: Sendable {
    let config: ConfigReader
}

/// Bootstrap the logging system, then build the inputs. The order is the point: swift-log captures the
/// unbound default logger at first access, so bootstrapping after the graph is built would leave
/// already-constructed bindings holding a logger that ignores this configuration. The level comes from
/// config (`LOG_LEVEL`), which is the ordinary reason to want configuration first.
private func bootstrapConfiguration() -> AppInputs {
    let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
    let level = Logger.Level(rawValue: config.string(forKey: "log.level", default: "info")) ?? .info
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel = level
        return handler
    }
    return AppInputs(config: config)
}
