// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "frogmouth",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FrogmouthCore", targets: ["FrogmouthCore"]),
        .executable(name: "frogmouth", targets: ["FrogmouthApp"]),
        .executable(name: "frogmouth-benchmark", targets: ["FrogmouthBenchmark"]),
    ],
    targets: [
        .target(name: "FrogmouthCore"),
        .executableTarget(
            name: "FrogmouthApp",
            dependencies: ["FrogmouthCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "FrogmouthBenchmark",
            dependencies: ["FrogmouthCore"]
        ),
        .testTarget(
            name: "FrogmouthCoreTests",
            dependencies: ["FrogmouthCore"]
        ),
    ]
)
