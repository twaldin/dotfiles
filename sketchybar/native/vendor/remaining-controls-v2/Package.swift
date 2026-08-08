// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemainingControlsV2Prototype",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RemainingControlsCore", targets: ["RemainingControlsCore"]),
        .library(name: "RemainingControlsMacBoundaries", targets: ["RemainingControlsMacBoundaries"]),
        .executable(name: "RemainingControlsSelfTests", targets: ["RemainingControlsSelfTests"]),
    ],
    targets: [
        .target(name: "RemainingControlsCore"),
        .target(
            name: "RemainingControlsMacBoundaries",
            dependencies: ["RemainingControlsCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "RemainingControlsSelfTests",
            dependencies: ["RemainingControlsCore", "RemainingControlsMacBoundaries"],
            path: "Tests/RemainingControlsCoreTests"
        ),
    ]
)
