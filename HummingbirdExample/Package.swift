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
        // 12-factor configuration, built once before the graph and passed in as a graph input.
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        // `@ConfigProperty` — reads a value at the injection site, so a provider depends on the value
        // rather than on a reader it has to call.
        .package(url: "https://github.com/tachyonics/wire-configuration.git", branch: "main"),
        // The `html-form` example. A sibling package because it depends on Elementary and `Controllers`
        // deliberately does not; its `Elementary` trait request on wire-mvc unions with this runtime's
        // `ServerTransport` one. Here it also demonstrates that a streamed `@HTMLResponse` reaches the
        // client through the `WireMVCServerTransport` bridge, not only on a native proposal server.
        .package(path: "../HTMLForm"),
        // Both ends of the extension point around one codec: `@YAMLBody` in, `@YAMLResponse` out. Here it
        // also shows a *buffered* user mode reaching the client through `WireMVCServerTransport`, where
        // `HTMLForm` covers the streaming one.
        .package(path: "../YAMLConfig"),
        .package(path: "../OpenAPISpec"),
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main", traits: ["ServerTransport"]),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/wire-open-api.git", branch: "main"),
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
                .product(name: "HTMLForm", package: "HTMLForm"),
                .product(name: "YAMLConfig", package: "YAMLConfig"),
                .product(name: "OpenAPISpec", package: "OpenAPISpec"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCServerTransport", package: "wire-mvc"),
                // The *adopting* logging target: Hummingbird already binds a per-request logger carrying
                // `hb.request.id` as a task-local, so WireMVC uses that one rather than minting a rival.
                .product(name: "WireMVCTaskLocalLogging", package: "wire-mvc"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "WireConfiguration", package: "wire-configuration"),
                .product(name: "WireOpenAPI", package: "wire-open-api"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "Valkey", package: "valkey-swift"),
                // The graph's Valkey client is a `ServiceLifecycle.Service`; the generated
                // `_WireGraph: WireMVCComposable` conformance references `any Service`.
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // **Three plugins, not the bundled `WireMVCBuildPlugin`.** That one runs WireGen and WireMVC's
            // route codegen together, which is right for an app with one adapter and wrong the moment
            // there are two: applying it here would leave WireOpenAPI's conformers ungenerated, silently.
            // Decomposed, `WireBuildPlugin` emits the graph exactly once and each adapter contributes only
            // its own domain generator. `OpenAPIGenerator` itself is not here — the `OpenAPISpec` package
            // runs it and exports the generated types publicly.
            plugins: [
                .plugin(name: "WireBuildPlugin", package: "swift-wire"),
                .plugin(name: "WireMVCRouteGenPlugin", package: "wire-mvc"),
                .plugin(name: "WireOpenAPIGenPlugin", package: "wire-open-api"),
            ]
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
                // The ambient-context probe registers a route through `Router: ServerTransport` and wraps
                // it in real Hummingbird middleware. `OpenAPIRuntime` (for `HTTPBody`) is not named here
                // because this package does not depend on it directly — it arrives with
                // swift-openapi-hummingbird, and adding it would mean pinning a version this example has
                // no other reason to constrain.
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "HTMLForm", package: "HTMLForm"),
                .product(name: "YAMLConfig", package: "YAMLConfig"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "ContainerMacrosLib", package: "swift-local-containers"),
                .product(name: "ContainerTestSupport", package: "swift-local-containers"),
                .product(name: "DockerRuntime", package: "swift-local-containers"),
                .product(name: "LocalContainers", package: "swift-local-containers"),
            ]
        ),
    ]
)
