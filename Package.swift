// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "VideoBox",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "VideoBox",
            targets: ["VideoBox"]
        )
    ],
    targets: [
        .executableTarget(
            name: "VideoBox",
            path: "Sources/VideoBox"
        )
    ]
)
