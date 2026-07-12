// swift-tools-version: 6.3
import PackageDescription

// Runtime 1: Hummingbird — its own package, so its dependency tree (swift-nio, etc.) is isolated
// from Vapor's and from the http-api-proposal's 6.4 requirement. The shared controllers arrive
// via a path dependency on ../ControllersLegacy (the ServerTransport-era controllers, until this
// example migrates to proposal-native WireMVC); only the transport + backend differ.
//
// Structured like a real Hummingbird app (as `hummingbird-examples/todos-*` and the Hummingbird
// template are): `buildApplication` in the target assembles the app, a thin `@main`
// AsyncParsableCommand serves it, and `HummingbirdExampleTests` drives the routes with
// HummingbirdTesting. Verification lives in the test target, not in `main`.
let package = Package(
    name: "HummingbirdExample",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../ControllersLegacy"),
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
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
                .product(name: "Controllers", package: "ControllersLegacy"),
                .product(name: "WireMVC", package: "wire-mvc"),
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
                .product(name: "Controllers", package: "ControllersLegacy"),
                .product(name: "Wire", package: "swift-wire"),
            ]
        ),
    ]
)
