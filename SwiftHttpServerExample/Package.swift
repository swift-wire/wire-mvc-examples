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
        // `NIOHTTPServer` switches on WireMVCTesting's `NIOHTTPServer: WireMVCTestServer` conformance and
        // the `.swiftHttpServer` suite mode. Off by default in wire-mvc, so a consumer that doesn't serve on
        // NIO resolves no server package at all — this runtime does, so it opts in.
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main", traits: ["NIOHTTPServer"]),
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
        // smockable — generates a protocol mock from an `@Smock` protocol. The mocked routing suite mocks
        // the `TodoRepository`/`SessionManager` protocols (via the external-protocol mirror workaround) and
        // threads the generated mocks through the keyed WireMVCTesting harness.
        .package(url: "https://github.com/tachyonics/smockable", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftHttpServerExample",
            dependencies: [
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "WireMVC", package: "wire-mvc"),
                // The package-provided native router (TrieRouteBuilder / FrozenTrieRouter) — replaces
                // this runtime's former in-tree TrieRouter copy.
                .product(name: "WireMVCRouter", package: "wire-mvc"),
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
        // Real-backend integration suite. Re-composes the app's production graph (the plugin re-parses the
        // app via its `_WireExports.swift` marker) — the real `CouchDB*` bindings, served through the keyless
        // `@Suite(.wiremvc(.swiftHttpServer))` harness on a harness-owned server bound to an ephemeral port.
        // A container trait provisions a throwaway CouchDB; a small env trait threads its host/port into the
        // graph's `provideCouchDBClient` before the harness bootstraps. Depending on `WireMVCTesting` makes the
        // plugin emit the `.wiremvc(_:)` suite-trait factory (not a `@main`, which can't live in a test bundle).
        .testTarget(
            name: "SwiftHttpServerExampleTests",
            dependencies: [
                "SwiftHttpServerExample",
                // Direct deps so the plugin re-parses WireMVC's adapter directives when re-composing the
                // app's graph, and so the generated `.wiremvc(_:)` factory's references resolve.
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "WireMVCTesting", package: "wire-mvc"),
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ContainerMacrosLib", package: "swift-local-containers"),
                .product(name: "ContainerTestSupport", package: "swift-local-containers"),
                .product(name: "DockerRuntime", package: "swift-local-containers"),
                .product(name: "LocalContainers", package: "swift-local-containers"),
            ],
            swiftSettings: extraSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        // Mocked routing suite — socket-free (`.inProcess`), so it depends on no concrete server at all.
        // It tests route/controller logic, not transport. smockable mocks for `TodoRepository` + `SessionManager` threaded into the
        // request-scoped `MeController<Repository, Manager>` (generic over both mocked slots — the
        // opaque-injection lift) via a keyed `@BindType` harness (`@Suite(.wiremvc(key, .inProcess))` + `withBindValues` +
        // `verify`). The keyed suite serves the key's variant app graph, which drops the app's
        // `@Singleton(as:)` CouchDB bindings, so the real backend's `init` never runs — the suite is
        // Docker-free without touching the production graph.
        .testTarget(
            name: "SwiftHttpServerExampleMockedTests",
            dependencies: [
                "SwiftHttpServerExample",
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "WireMVCTesting", package: "wire-mvc"),
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Smockable", package: "smockable"),
            ],
            swiftSettings: extraSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
    ]
)
