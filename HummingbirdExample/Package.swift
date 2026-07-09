// swift-tools-version: 6.3
import PackageDescription

// Runtime 1: Hummingbird — its own package, so its dependency tree (swift-nio, etc.) is isolated
// from Vapor's and from the http-api-proposal's 6.4 requirement. The shared controllers arrive
// via a path dependency on ../Controllers, so this compiles the *same* controller source as
// every other runtime; only the transport + backend differ.
let package = Package(
    name: "HummingbirdExample",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Controllers"),
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "HummingbirdExample",
            dependencies: [
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        )
    ]
)
