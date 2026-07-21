// swift-tools-version: 6.4
import PackageDescription

// Runtime 3: the swift-http-api-proposal server, via swift-server's concrete `NIOHTTPServer`. Serves
// the shared (framework-free) WireMVC controllers proposal-native: `@Controller`'s generated
// witnesses register onto a `TrieRouteBuilder` (a concrete `HTTPServerRouteBuilder` living in this
// runtime), which freezes into the server's request handler. Structured like a real app — a
// `buildApplication` assembly + a thin serving `@main`, with route verification in the test target.
//
// tools-version 6.4, deployment macOS 26 (so `anyAppleOS 26.0` is unconditional and Wire's ungated
// generated graph compiles), and the experimental/upcoming-feature flags match the proposal stack.
// The shared Controllers arrive via an in-repo path dependency (../Controllers), as in every runtime.
let extraSettings: [SwiftSetting] = [
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
    name: "SwiftHttpServerExample",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../Controllers"),
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/swift-server/swift-http-server.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            exact: "1.35.0",
            traits: ["UnstableHTTPAPIsSupport"]
        ),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            exact: "1.1.5",
            traits: ["UnstableAsyncStreaming"]
        ),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.2"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/tachyonics/swift-local-containers.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftHttpServerExample",
            dependencies: [
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "AHCHTTPClient", package: "swift-http-api-proposal"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "AsyncStreaming", package: "swift-async-algorithms"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                // This runtime binds no services, but the generated `_WireGraph: WireMVCComposable`
                // conformance references `any Service` (and `MemberImportVisibility` is on, so it must
                // be a direct dependency).
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: extraSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        .testTarget(
            name: "SwiftHttpServerExampleTests",
            dependencies: [
                "SwiftHttpServerExample",
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "ContainerMacrosLib", package: "swift-local-containers"),
                .product(name: "ContainerTestSupport", package: "swift-local-containers"),
                .product(name: "DockerRuntime", package: "swift-local-containers"),
                .product(name: "LocalContainers", package: "swift-local-containers"),
            ],
            swiftSettings: extraSettings
        ),
    ]
)
