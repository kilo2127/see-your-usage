// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "see-your-usage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "see-your-usage", targets: ["SeeYourUsage"]),
        .library(name: "SeeYourUsageCore", targets: ["SeeYourUsageCore"])
    ],
    targets: [
        .target(name: "SeeYourUsageCore"),
        .executableTarget(
            name: "SeeYourUsage",
            dependencies: ["SeeYourUsageCore"]
        ),
        .testTarget(
            name: "SeeYourUsageCoreTests",
            dependencies: ["SeeYourUsageCore", "SeeYourUsage"]
        )
    ]
)
