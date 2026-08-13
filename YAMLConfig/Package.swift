// swift-tools-version: 6.4
import PackageDescription

// Both ends of the extension point, in one package and around one codec: `@YAMLBody` binds a YAML request
// body, `@YAMLResponse` encodes a YAML response, and WireMVC names neither.
//
// A **sibling** of `Controllers` for the same reason `HTMLForm` and `OpenAPISpec` are: it depends on a
// third-party codec (Yams), and `Controllers` is deliberately WireMVC + Wire and nothing else. Taking the
// shared controllers must not mean taking a YAML parser.
//
// `WireMVCMacrosPlugin` is the dependency that makes the response half possible at all. A macro declaration
// has to name the plugin implementing it, and `#externalMacro` resolves only against a target this package
// depends on — so `@YAMLResponse` is declarable here only because wire-mvc exports its plugin as a product.
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
    name: "YAMLConfig",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "YAMLConfig", targets: ["YAMLConfig"])
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "YAMLConfig",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCMacrosPlugin", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: proposalSettings
        )
    ]
)
