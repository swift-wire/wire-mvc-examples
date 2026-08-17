public import Configuration
import Hummingbird
import Logging
import Wire
// Conformance-only import: provides `extension Router: ServerTransport`, which
// `WireMVCServerTransport.apply` needs but no symbol here names, so the unused_import analyzer can't
// see it's required.
// swiftlint:disable:next unused_import
import OpenAPIHummingbird
import WireMVC
import WireMVCServerTransport

/// The runtime configuration the app is built from — the Hummingbird-idiomatic `AppArguments`
/// seam. The serving `@main` command supplies it from parsed CLI options; the test target supplies
/// its own (an ephemeral port), so both build the app the same way.
public protocol AppArguments {
    var hostname: String { get }
    var port: Int { get }
}

/// Assembles the Hummingbird app, shared by the serving `@main` and the test target. `Wire.bootstrap()`
/// constructs the Valkey backend (the `ValkeyClient` and the repository that injects it) and injects it
/// into the collated (framework-free) TodosController; we build a router with a native route AND the
/// proposal-native WireMVC controllers applied onto it via the `WireMVCServerTransport` adapter (which
/// bridges them onto Hummingbird's `Router` as a `ServerTransport`) — the two coexist — plus the
/// cross-runtime `/wiring` introspection endpoint.
///
/// `WireMVCServerTransport.apply` returns the graph's collated app-scoped services (here the
/// `ValkeyClient`, contributed via `@Contributes(to: WireMVCKeys.services)`); handed to
/// `Application(services:)`, Hummingbird's `ServiceGroup` runs the client's connection pool alongside
/// the server and stops it at shutdown — the graph hosting a `ServiceLifecycle` service, WireMVC's
/// `services` collation applied end to end.
public func buildApplication(_ arguments: some AppArguments) async throws -> some ApplicationProtocol {
    // Hand-assembled rather than `@WireMVCBootstrap`, so this function *is* the pre-step: the same two
    // things happen before construction that `prepare()` does in the proposal runtime's app — bootstrap
    // logging, then build the one `ConfigReader` the graph shares and pass it in as a graph input.
    let graph = try await Wire.bootstrap(inputs: bootstrapConfiguration())

    let router = Router()
    // A native Hummingbird route, registered the framework's own way — coexists with the
    // WireMVC-applied /todos/* on the same router.
    router.get("health") { _, _ in "OK" }
    // The WireMVC controllers, bridged onto the router via the ServerTransport adapter (which returns
    // the graph's collated services — the Valkey client's run loop), plus the introspection endpoint.
    let services = try WireMVCServerTransport.apply(graph, to: router)
    try WireMVCServerTransport.mountIntrospection(for: graph, on: router)

    return Application(
        router: router,
        configuration: .init(address: .hostname(arguments.hostname, port: arguments.port)),
        services: services
    )
}

/// The graph's inputs — the `ConfigReader` every provider injects instead of reading the environment for
/// itself. Declared in this package, not in `Controllers`: inputs are the consumer's to supply, and a
/// library cannot decide what its consumers must pass in.
@GraphInputs
public struct AppInputs: Sendable {
    public let config: ConfigReader

    public init(config: ConfigReader) {
        self.config = config
    }
}

/// Bootstrap the logging system, then build the inputs. Ordering matters and only runs correctly here:
/// swift-log captures the unbound default logger at first access, so bootstrapping after the graph is
/// built would leave already-constructed bindings holding a logger that ignores this configuration.
///
/// The level comes from config (`LOG_LEVEL`) — the ordinary reason to want configuration before logging.
/// Hummingbird binds its own per-request logger as a task-local on top of whatever handler is installed
/// here, and `WireMVCTaskLocalLogging` adopts *that*, so a controller's log line carries the framework's
/// own `hb.request.id` rather than a second, disagreeing id.
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
