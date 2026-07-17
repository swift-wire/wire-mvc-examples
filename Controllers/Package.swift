// swift-tools-version: 6.4
import PackageDescription

// The portable, framework-free WireMVC controllers, proposal-native. Shared by the proposal-based
// runtime example(s) via a path dependency (`.package(path: "../Controllers")`). Depends only on
// WireMVC + Wire — no HTTP framework — so the *same* controller source compiles into each runtime's
// isolated package; `@Controller`'s generated witnesses register onto a `RoutableHTTPServerBuilder`.
//
// tools-version 6.4, deployment macOS 26, and the experimental/upcoming-feature flags match
// proposal-native WireMVC — the generated witnesses interface with the proposal's `~Copyable` /
// `consuming sending` streaming types, and macOS 26 makes `anyAppleOS 26.0` unconditional so Wire's
// ungated generated graph compiles.
let proposalSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Controllers",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Controllers", targets: ["Controllers"])
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        // The `@RawRoute` streaming route touches the proposal's raw HTTP primitives directly
        // (`HTTPResponseSender`, `HTTPResponse`, `HTTPFields`, `UniqueArray`) — inherent to a raw
        // handler. Still framework-free: these are the proposal's HTTP types, not Hummingbird/Vapor.
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "Controllers",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
            ],
            swiftSettings: proposalSettings
        )
    ]
)
