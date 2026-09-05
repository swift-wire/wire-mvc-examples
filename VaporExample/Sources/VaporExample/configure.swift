// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import Configuration
import Logging
import OpenAPIVapor  // VaporTransport (a ServerTransport)
import ServiceLifecycle
import Synchronization
import Vapor
import Wire
import WireMVC
import WireMVCServerTransport

// The app assembly, shared by the serving `@main` and the test target — the Vapor-idiomatic
// `configure(_:)`. `Wire.bootstrap()` constructs the MongoDB backend (connecting to the database)
// and injects it into the collated, framework-free TodosController; we register a native Vapor route
// AND bridge the proposal-native WireMVC
// controllers onto Vapor's transport via the WireMVCServerTransport adapter (they coexist), then
// mount the cross-runtime introspection endpoint. Two things then hang off the app's lifecycle: the
// graph's `@Teardown` (which disconnects the container) and the graph's collated `ServiceLifecycle`
// services, which this runtime has to run for itself — see `WireGraphServices`.
func configure(_ app: Application) async throws {
    // This function is the pre-step: the same two things happen before construction that `prepare()` does
    // in the proposal runtime's `@WireMVCBootstrap` app — bootstrap logging, then build the one
    // `ConfigReader` the graph shares and hand it in as a graph input.
    let graph = try await Wire.bootstrap(inputs: bootstrapConfiguration())

    // A native Vapor route — coexists with the WireMVC-applied /todos/* on the same app.
    app.get("health") { _ in "OK" }

    // The WireMVC controllers, bridged onto Vapor's transport via the ServerTransport adapter, plus
    // the introspection endpoint. `apply` returns the graph's collated app-scoped `ServiceLifecycle`
    // services — here the shared controllers' `JobWorker`, contributed with `@BackgroundService`.
    let transport = VaporTransport(routesBuilder: app)
    let services = try WireMVCServerTransport.apply(graph, to: transport)
    try WireMVCServerTransport.mountIntrospection(for: graph, on: transport)

    // On shutdown, tear down the graph — which disconnects the MongoDB backend.
    app.lifecycle.use(WireGraphTeardown(teardown: { await graph.teardown() }))
    // Registered *after* the teardown handler on purpose: Vapor runs shutdown handlers in reverse, so
    // this one stops the services first and the graph is torn down under a group that has already
    // drained. The other order would disconnect a backend out from under a service still using it.
    app.lifecycle.use(WireGraphServices(services: services))
}

/// Runs the graph's collated app-scoped `ServiceLifecycle` services alongside the Vapor application.
///
/// **This is the one runtime where the app has to supply the group itself.** The other two are handed
/// one: the proposal runtime's generated `@main` passes `apply`'s services to `WireMVC.serve`, and
/// Hummingbird takes them straight into `Application(services:)`, which owns a `ServiceGroup` already.
/// Vapor 4 has no ServiceLifecycle integration at all — nothing in it names `Service` — so the collation
/// arrives with nowhere to go, and the return value of `apply` is silently droppable. It *was* dropped
/// here until the shared controllers grew a service worth running, which is the failure mode this type
/// exists to close: the graph collates correctly, the routes work, and the background work simply never
/// happens.
///
/// Both halves hang off `LifecycleHandler`, and the **synchronous** `didBoot` is deliberate.
/// `app.testing()` boots through the non-async `boot()`, which calls only the sync variants, while the
/// async variants default to calling their sync counterparts — so implementing the sync one covers the
/// serving path and the test path with one implementation. Implementing `didBootAsync` instead would
/// start the services under `swift run` and not under `swift test`.
///
/// Shutdown is the async half because it has something to await: graceful shutdown is *triggered*
/// synchronously but finishes when every service's `run()` returns, and waiting for that is the entire
/// point of a group. `JobWorker` drains its queue in that window.
final class WireGraphServices: LifecycleHandler {
    private let services: [any Service]
    /// The running group and the task driving it, or `nil` before boot and after shutdown. A `Mutex`
    /// rather than an actor because both accesses are synchronous and `didBoot` cannot `await`.
    private let running = Mutex<(group: ServiceGroup, task: Task<Void, any Error>)?>(nil)

    init(services: [any Service]) {
        self.services = services
    }

    func didBoot(_ application: Application) throws {
        guard !services.isEmpty else { return }
        // No `gracefulShutdownSignals`: Vapor installs its own signal handling and drives shutdown
        // through `asyncShutdown`, so a second set of handlers here would race it.
        let group = ServiceGroup(services: services, logger: application.logger)
        // Requests can begin before a service's `run()` has been entered. That is tolerable for the
        // work this collation carries — the job queue buffers, so an early submission is delayed rather
        // than lost — and would not be for a backend a route reaches synchronously; such a binding wants
        // to be usable before its run loop starts, as `ValkeyClient` is on the Hummingbird runtime.
        let task = Task { try await group.run() }
        running.withLock { $0 = (group, task) }
    }

    func shutdownAsync(_ application: Application) async {
        guard
            let running = running.withLock({ state in
                defer { state = nil }
                return state
            })
        else { return }
        await running.group.triggerGracefulShutdown()
        do {
            try await running.task.value
        } catch {
            // Shutdown is best-effort by the time it runs, so this is reported rather than rethrown —
            // the same treatment `WireGraphTeardown` gives a teardown error.
            application.logger.report(error: error)
        }
    }
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
