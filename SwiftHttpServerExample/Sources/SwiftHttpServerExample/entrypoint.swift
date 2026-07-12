/// The serving entry point — the average app's `@main`: build the app via `buildApplication`, then
/// `serve(on:)` (which freezes the trie into a compact router and serves it). Route verification
/// lives in the test target. In its own file with `@main` (not `main.swift`) so the test target can
/// `@testable import SwiftHttpServerExample` to reach `buildApplication`.
@main
struct SwiftHttpServerExample {
    static func main() async throws {
        let (server, router) = try await buildApplication(ServingArguments())
        try await router.serve(on: server)
    }
}

/// The serving binary's fixed host/port; the test target supplies its own (ephemeral) arguments.
struct ServingArguments: AppArguments {
    let hostname = "127.0.0.1"
    let port = 8080
}
