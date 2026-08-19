// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CortexSentinelBar",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CortexSentinelBar",
            path: "Sources/CortexSentinelBar"
        ),
        .testTarget(
            name: "CortexSentinelBarTests",
            dependencies: ["CortexSentinelBar"],
            path: "Tests/CortexSentinelBarTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
