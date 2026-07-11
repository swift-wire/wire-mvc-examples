/// The serving entry point — build the server and serve `Well, hello!` on a fixed port. Route
/// verification lives in the test target. In its own file with `@main` (not `main.swift`) so the
/// test target can `@testable import SwiftHttpServerExample` to reach the assembly helpers.
@main
@available(anyAppleOS 26.0, *)
struct SwiftHttpServerExample {
    static func main() async throws {
        let server = try makeHelloWorldServer(port: 8080)
        try await serveHelloWorld(on: server)
    }
}
