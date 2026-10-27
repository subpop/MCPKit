// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MCPKit",
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces and make them visible to other packages.
        .library(
            name: "MCPKit",
            targets: ["MCPKit"]
        ),
        .executable(
            name: "MCPEchoServer",
            targets: ["MCPEchoServer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/subpop/JSONRPCKit.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MCPKit",
            dependencies: [
                .product(name: "JSONRPCKit", package: "JSONRPCKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .executableTarget(
            name: "MCPEchoServer",
            dependencies: [
                "MCPKit",
                .product(name: "JSONRPCKit", package: "JSONRPCKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .testTarget(
            name: "MCPKitTests",
            dependencies: [
                "MCPKit",
                .product(name: "JSONRPCKit", package: "JSONRPCKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
    ]
)
