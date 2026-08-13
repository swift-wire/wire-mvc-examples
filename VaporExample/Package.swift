// swift-tools-version: 6.4
import PackageDescription

// Runtime 2: Vapor — proposal-native. Serves the shared (framework-free) controllers via the opt-in
// WireMVCServerTransport adapter: WireMVC's proposal-native routes are bridged onto Vapor's
// `ServerTransport` (`VaporTransport` via swift-openapi-vapor). Its own package, so Vapor's dependency
// tree stays isolated; the shared controllers arrive via a path dependency on ../Controllers, so this
// compiles the *same* controller source as every other runtime — only the transport + backend differ.
//
// swift-tools-version 6.4 + deployment macOS 26 because proposal-native WireMVC requires them. The
// `ServerTransport` trait is enabled on the wire-mvc dependency to pull in the WireMVCServerTransport
// adapter (and OpenAPIRuntime).
//
// Structured like a real Vapor app: the `VaporExample` executable target holds the app assembly
// (`configure`) plus a thin serving `@main`, and `VaporExampleTests` drives the routes with
// VaporTesting — Vapor's testing tools (and swift-testing/XCTest) only link into test targets, so
// route verification lives there, not in `main`. This is how `vapor new` scaffolds a project.
let package = Package(
    name: "VaporExample",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../Controllers"),
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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.106.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.0.0"),
        .package(url: "https://github.com/tachyonics/swift-local-containers.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VaporExample",
            dependencies: [
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "HTMLForm", package: "HTMLForm"),
                .product(name: "YAMLConfig", package: "YAMLConfig"),
                .product(name: "OpenAPISpec", package: "OpenAPISpec"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCServerTransport", package: "wire-mvc"),
                .product(name: "WireOpenAPI", package: "wire-open-api"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "MongoKitten", package: "MongoKitten"),
                .product(name: "Configuration", package: "swift-configuration"),
                // This runtime binds no services, but the generated `_WireGraph: WireMVCComposable`
                // conformance references `any Service`.
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            // The decomposed three-plugin form, not the bundled `WireMVCBuildPlugin`: that one runs
            // WireGen and WireMVC's route codegen together, which is right for an app with one adapter
            // and silently leaves the second adapter's witnesses ungenerated once there are two.
            plugins: [
                .plugin(name: "WireBuildPlugin", package: "swift-wire"),
                .plugin(name: "WireMVCRouteGenPlugin", package: "wire-mvc"),
                .plugin(name: "WireOpenAPIGenPlugin", package: "wire-open-api"),
            ]
        ),
        // The integration test provisions a throwaway MongoDB via swift-local-containers'
        // test-support macros (`@Containers`/`@Container` + `containerTrait`), then drives the
        // routes with VaporTesting — the container is a test concern, not the app's.
        .testTarget(
            name: "VaporExampleTests",
            dependencies: [
                "VaporExample",
                .product(name: "VaporTesting", package: "vapor"),
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
