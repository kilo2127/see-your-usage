// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MindYourUsage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MindYourUsage", targets: ["MindYourUsage"]),
        .library(name: "MindYourUsageCore", targets: ["MindYourUsageCore"])
    ],
    targets: [
        .target(name: "MindYourUsageCore"),
        .executableTarget(
            name: "MindYourUsage",
            dependencies: ["MindYourUsageCore"]
        ),
        .testTarget(
            name: "MindYourUsageCoreTests",
            dependencies: ["MindYourUsageCore"]
        )
    ]
)
