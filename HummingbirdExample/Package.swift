// swift-tools-version: 6.4
import PackageDescription

// Runtime 1: Hummingbird — proposal-native. Serves the shared (framework-free) controllers via the
// opt-in WireMVCServerTransport adapter: WireMVC's proposal-native routes are bridged onto Hummingbird's
// `ServerTransport` (its `Router`, via swift-openapi-hummingbird). Its own package, so its dependency
// tree stays isolated; the shared controllers arrive via a path dependency on ../Controllers, so this
// compiles the *same* controller source as the proposal runtime — only the transport + backend differ.
//
// swift-tools-version 6.4 + deployment macOS 26 because proposal-native WireMVC requires them. The
// `ServerTransport` trait is enabled on the wire-mvc dependency to pull in the WireMVCServerTransport
// adapter (and OpenAPIRuntime).
//
// Structured like a real Hummingbird app (as `hummingbird-examples/todos-*` and the Hummingbird
// template are): `buildApplication` in the target assembles the app, a thin `@main`
// AsyncParsableCommand serves it, and `HummingbirdExampleTests` drives the routes with
// HummingbirdTesting. Verification lives in the test target, not in `main`.
let package = Package(
    name: "HummingbirdExample",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../Controllers"),
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main", traits: ["ServerTransport"]),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "HummingbirdExample",
            dependencies: [
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCServerTransport", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        ),
        .testTarget(
            name: "HummingbirdExampleTests",
            dependencies: [
                "HummingbirdExample",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "Wire", package: "swift-wire"),
            ]
        ),
    ]
)
