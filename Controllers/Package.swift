// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import PackageDescription

// The portable, framework-free WireMVC controllers, proposal-native. Shared by the proposal-based
// runtime example(s) via a path dependency (`.package(path: "../Controllers")`). Depends only on
// WireMVC + Wire — no HTTP framework — so the *same* controller source compiles into each runtime's
// isolated package; `@Controller`'s generated witnesses register onto a `HTTPServerRouteBuilder`.
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
        // `Logger` appears in MeController's injected surface. Named explicitly rather than relied on
        // transitively; this package still names no *logging target*, so consumers keep that choice.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        // The `@RawRoute` streaming route touches the proposal's raw HTTP primitives directly
        // (`HTTPResponseSender`, `HTTPResponse`, `HTTPFields`, `UniqueArray`) — inherent to a raw
        // handler. Still framework-free: these are the proposal's HTTP types, not Hummingbird/Vapor.
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        // The job worker is a `ServiceLifecycle.Service`, collated into the graph's services by
        // `@BackgroundService`. It arrives transitively through WireMVC, but `MemberImportVisibility`
        // means a module that *names* `Service` must depend on it directly.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
    ],
    targets: [
        .target(
            name: "Controllers",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings
        ),
        // Pure-logic unit tests, for the three things in this package that are not a route. Everything
        // else here is a controller whose behaviour *is* a route, tested over the wire in each runtime's
        // suite. The multipart parser is different — security-adjacent, with silent failure modes (a
        // two-byte corruption of every part) and no server needed to exercise it. So is the job worker:
        // its drain, its startup sweep and its claim ordering are properties of a `ServiceGroup` and a
        // store, not of HTTP — observable only by running a group, and asserting the drain through a route
        // suite would mean asserting on the suite's own teardown. And so is the policy set: an
        // authorisation bug does not throw, it answers `200`, and it answers `200` only for the caller
        // nobody drove a request as — so the whole caller × action × resource matrix belongs in a table
        // here rather than in a request each.
        .testTarget(
            name: "ControllersTests",
            dependencies: [
                "Controllers",
                // `JobWorkerTests` runs the worker in a real `ServiceGroup` against an in-memory
                // `JobStore` — the only way to arm the graceful-shutdown handler its drain depends on,
                // and the only place the claim ordering and the startup sweep are observable.
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: proposalSettings
        ),
    ]
)
