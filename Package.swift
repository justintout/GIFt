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
                // Relax Swift 6 strict concurrency for this small utility app.
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "GiftCoreTests",
            dependencies: ["GiftCore"],
            path: "Tests/GiftCoreTests"
        )
    ]
)
