// swift-tools-version: 6.4
import PackageDescription

// Runtime 3 (foundation step): the swift-http-api-proposal server, via swift-server's concrete
// `NIOHTTPServer`. This first cut is a minimal "Well, hello!" 200 server — literally the
// swift-http-server example, plaintext — to prove the 6.4-gated proposal stack builds and runs
// here before the WireMVC controllers are layered on. Structured like a real app: a `serveHelloWorld`
// assembly + a thin serving `@main`, with route verification in the test target.
//
// tools-version 6.4 and the experimental/upcoming-feature flags match swift-http-server's — the
// proposal's API is compiled with them, so a consumer needs the same to call it.
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
    platforms: [.macOS(.v15), .iOS(.v18), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2)],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-http-server.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.2"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftHttpServerExample",
            dependencies: [
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: extraSettings
        ),
        .testTarget(
            name: "SwiftHttpServerExampleTests",
            dependencies: ["SwiftHttpServerExample"],
            swiftSettings: extraSettings
        ),
    ]
)
