import ArgumentParser
import Hummingbird

// The serving entry point — the average Hummingbird app's `@main`: parse host/port, build the app
// via `buildApplication`, and run it as a service (graceful shutdown included). Route verification
// lives in the test target (HummingbirdTesting), not here. In its own file with `@main` (not
// `main.swift`) so the test target can `@testable import HummingbirdExample` to reach
// `buildApplication`.
@main
struct App: AsyncParsableCommand, AppArguments {
    @Option(name: .shortAndLong) var hostname: String = "127.0.0.1"
    @Option(name: .shortAndLong) var port: Int = 8080

    func run() async throws {
        let app = try await buildApplication(self)
        try await app.runService()
    }
}
