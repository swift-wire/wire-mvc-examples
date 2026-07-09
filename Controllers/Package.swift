// swift-tools-version: 6.3
import PackageDescription

// The portable, framework-free WireMVC controllers, shared by every runtime example via a path
// dependency (`.package(path: "../Controllers")`). Depends only on WireMVC + Wire — no HTTP
// framework — so the *same* controller source compiles into each runtime's isolated package.
let package = Package(
    name: "Controllers",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Controllers", targets: ["Controllers"])
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Controllers",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
            ]
        )
    ]
)
