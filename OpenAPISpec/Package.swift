// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc-examples project authors

import PackageDescription

// The todos API, authored from an OpenAPI document — the other half of the "one routing model, not two"
// claim. It is a sibling of `Controllers` rather than part of it: this package runs swift-openapi-generator
// and so depends on it, and `Controllers` is deliberately lean (WireMVC + Wire and nothing else). Keeping
// them apart means a runtime can take the annotation-driven controllers without inheriting a code
// generator, and it keeps the forked generator below off the package every runtime already depends on.
//
// It ships the document, the types swift-openapi-generator makes from it, and the `@OpenAPIController`
// implementing them — but it does **not** run WireGen. That happens once, in each runtime executable,
// which re-parses these sources because this target depends on the `Wire` product; that is what puts this spec's
// aggregate proxy in the app.
//
// Everything below `InternalImportsByDefault`, which a module holding *public* generated code cannot have:
// swift-openapi-generator emits plain `import` lines, and a public method whose parameter types come from
// an internally-imported module does not compile.
let generatedPublicAPISettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "OpenAPISpec",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenAPISpec", targets: ["OpenAPISpec"])
    ],
    dependencies: [
        // The domain: `TodoRepository` and `Todo` come from the shared controllers package, so both
        // authoring styles serve the same backend rather than each carrying its own model.
        .package(path: "../Controllers"),
        .package(url: "https://github.com/tachyonics/wire-open-api.git", branch: "main"),
        .package(
            url: "https://github.com/tachyonics/wire-mvc.git",
            branch: "main",
            traits: ["ServerTransport"]
        ),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        // **A fork, pinned to a revision.** WireOpenAPI dispatches each operation individually by calling
        // the generated per-operation method on `UniversalServer`, which stock swift-openapi-generator
        // emits `fileprivate`; the fork lets it follow the configured access modifier. Pinned rather than
        // tracked by branch so the generated code cannot change under the examples. Points back at the
        // released package once upstream takes it.
        .package(
            url: "https://github.com/tachyonics/swift-openapi-generator.git",
            revision: "9e655e0adb9b993ef4cb29a6aa0dfc59b9b42b09"
        ),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "OpenAPISpec",
            dependencies: [
                .product(name: "Controllers", package: "Controllers"),
                .product(name: "WireOpenAPI", package: "wire-open-api"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: generatedPublicAPISettings,
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        )
    ]
)
