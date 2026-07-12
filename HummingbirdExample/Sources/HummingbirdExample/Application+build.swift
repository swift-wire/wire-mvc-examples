import Hummingbird
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
    let graph = try await Wire.bootstrap()

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
