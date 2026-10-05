// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "gift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "gift", targets: ["gift"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "GiftCore",
            path: "Sources/GiftCore"
        ),
        .executableTarget(
            name: "gift",
            dependencies: [
                "GiftCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/gift",
            swiftSettings: [
                // The AppKit surface this app drives (CGEvent taps, ScreenCaptureKit delegates,
                // NSWindow subclasses) is not annotated for strict concurrency.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "GiftCoreTests",
            dependencies: ["GiftCore"],
            path: "Tests/GiftCoreTests"
        )
    ]
)
