// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VibeKeyLite",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VibeKeyLite", targets: ["VibeKeyLite"]),
        .executable(name: "vibekeyctl", targets: ["vibekeyctl"]),
        .library(name: "VibeKeyLiteCore", targets: ["VibeKeyLiteCore"])
    ],
    targets: [
        .target(name: "VibeKeyLiteCore"),
        .executableTarget(
            name: "VibeKeyLite",
            dependencies: ["VibeKeyLiteCore"]
        ),
        .executableTarget(
            name: "vibekeyctl",
            dependencies: ["VibeKeyLiteCore"]
        ),
        .testTarget(
            name: "VibeKeyLiteCoreTests",
            dependencies: ["VibeKeyLiteCore"]
        ),
        .testTarget(
            name: "VibeKeyLiteAppTests",
            dependencies: ["VibeKeyLite"]
        )
    ]
)
