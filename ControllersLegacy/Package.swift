// swift-tools-version: 6.3
import PackageDescription

// The legacy, ServerTransport-era WireMVC controllers, still used by the Hummingbird and Vapor
// runtime examples (which target the old `WireMVC.apply(to: some ServerTransport)` surface) until
// they migrate to proposal-native WireMVC. The proposal example uses the new `Controllers` package.
// Package renamed to `ControllersLegacy`; the product stays `Controllers` so the consuming examples
// need only a path/package change, not an import change.
let package = Package(
    name: "ControllersLegacy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Controllers", targets: ["Controllers"])
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Controllers",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
            ]
        )
    ]
)
