import Vapor

// A thin serving entry point — the average Vapor app's `main`: detect the environment, build the
// app via `configure`, and serve. Route verification lives in the test target (VaporTesting), not
// here. Named `entrypoint.swift` with `@main` (not `main.swift`) so the test target can
// `@testable import VaporExample` to reach `configure`.
@main
enum Entrypoint {
    static func main() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)

        let app = try await Application.make(environment)
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
