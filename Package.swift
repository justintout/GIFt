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
    targets: [
        .target(
            name: "GiftCore",
            path: "Sources/GiftCore"
        ),
        .executableTarget(
            name: "gift",
            dependencies: ["GiftCore"],
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
