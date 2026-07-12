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
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/tachyonics/swift-local-containers.git", from: "0.10.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
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
                .product(name: "Valkey", package: "valkey-swift"),
                // The graph's Valkey client is a `ServiceLifecycle.Service`; the generated
                // `_WireGraph: WireMVCComposable` conformance references `any Service`.
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        ),
        // The integration test provisions a throwaway Valkey via swift-local-containers'
        // test-support macros (`@Containers`/`@Container` + `containerTrait`), then drives the routes
        // with HummingbirdTesting's `.live` mode — the container is a test concern, not the app's, and
        // `.live` runs the app's ServiceGroup (so the graph's Valkey service actually connects).
        .testTarget(
            name: "HummingbirdExampleTests",
            dependencies: [
                "HummingbirdExample",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "ContainerMacrosLib", package: "swift-local-containers"),
                .product(name: "ContainerTestSupport", package: "swift-local-containers"),
                .product(name: "DockerRuntime", package: "swift-local-containers"),
                .product(name: "LocalContainers", package: "swift-local-containers"),
            ]
        ),
    ]
)
