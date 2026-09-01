// swift-tools-version: 6.4
import PackageDescription

// The `html-form` example: render a form, POST it back, re-render with validation errors.
//
// A **sibling** of `Controllers` rather than part of it, for the same reason `OpenAPISpec` is: this package
// depends on an HTML library, and `Controllers` is deliberately lean — WireMVC + Wire and nothing else — so
// a runtime can take the annotation-driven controllers without inheriting a view layer. It takes `@FormBody`
// *from* `Controllers`, which is the point: the binding is framework-free and reusable, the views are not.
//
// It runs no code generator. Each runtime executable re-parses these sources because of the
// dependency on the `Wire` product, which is what puts this controller in the app's graph.
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
    name: "HTMLForm",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HTMLForm", targets: ["HTMLForm"])
    ],
    dependencies: [
        .package(path: "../Controllers"),
        .package(
            url: "https://github.com/tachyonics/wire-mvc.git",
            branch: "main",
            traits: ["Elementary"]
        ),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        // Redundant on its face — wire-mvc already depends on the fork at this exact revision, and this
        // package needs no other pin. It is here because SwiftPM will not resolve a *revision*-pinned
        // dependency that is only reachable transitively in a graph this size: without it, a runtime
        // depending on `../HTMLForm` fails with "exhausted attempts to resolve the dependencies graph,
        // ... 'elementary'". Declaring it in the one package that actually uses Elementary keeps that
        // workaround out of all five runtimes. It goes away with the pin, once the fork is upstreamed.
        .package(
            url: "https://github.com/tachyonics/elementary.git",
            revision: "07eb69492ddf7052616af47518e7f883bd8f2691"
        ),
    ],
    targets: [
        .target(
            name: "HTMLForm",
            dependencies: [
                "Controllers",
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCElementary", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Elementary", package: "elementary"),
            ],
            swiftSettings: proposalSettings
        )
    ]
)
