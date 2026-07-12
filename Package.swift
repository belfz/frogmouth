// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "frogmouth",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FrogmouthCore", targets: ["FrogmouthCore"]),
        .executable(name: "frogmouth", targets: ["FrogmouthApp"]),
    ],
    targets: [
        .target(name: "FrogmouthCore"),
        .executableTarget(
            name: "FrogmouthApp",
            dependencies: ["FrogmouthCore"]
        ),
        .testTarget(
            name: "FrogmouthCoreTests",
            dependencies: ["FrogmouthCore"]
        ),
    ]
)

