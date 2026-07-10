import OpenAPIVapor  // VaporTransport (a ServerTransport)
import Vapor
import WireMVC

// The app assembly, shared by the serving `@main` and the test target — the Vapor-idiomatic
// `configure(_:)`. `Wire.bootstrap()` constructs the Postgres backend (which starts a real
// PostgreSQL container via swift-local-containers) and injects it into the collated, framework-free
// TodosController; we register a native Vapor route AND apply the WireMVC controllers onto Vapor's
// transport (they coexist), then mount the cross-runtime introspection endpoint. The container's
// lifecycle is tied to the app: `@Teardown` runs on shutdown via a lifecycle handler.
func configure(_ app: Application) async throws {
    let graph = try await Wire.bootstrap()

    // A native Vapor route — coexists with the WireMVC-applied /todos/* on the same app.
    app.get("health") { _ in "OK" }

    // The WireMVC controllers, applied onto Vapor's transport, plus the introspection endpoint.
    let transport = VaporTransport(routesBuilder: app)
    try WireMVC.apply(graph, to: transport)
    try WireMVC.mountIntrospection(for: graph, on: transport)

    // On shutdown, tear down the graph — which stops the Postgres container.
    app.lifecycle.use(WireGraphTeardown(teardown: { await graph.teardown() }))
}

/// Runs the Wire graph's `@Teardown` actions when the application shuts down, so the Postgres
/// container is stopped whether the app exits normally or a test finishes. Teardown errors are
/// logged rather than thrown — shutdown is best-effort by the time it runs.
struct WireGraphTeardown: LifecycleHandler {
    let teardown: @Sendable () async -> [any Error]

    func shutdownAsync(_ application: Application) async {
        for error in await teardown() {
            application.logger.report(error: error)
        }
    }
}
