// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanPowerOwner",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FanPowerCore", targets: ["FanPowerCore"]),
        .executable(name: "fan-power-owner", targets: ["FanPowerDaemon"]),
        .executable(name: "fan-power-client", targets: ["FanPowerClient"]),
        .executable(name: "fan-power-owner-self-tests", targets: ["FanPowerOwnerSelfTests"]),
    ],
    targets: [
        .target(name: "FanPowerCore"),
        .executableTarget(
            name: "FanPowerDaemon",
            dependencies: ["FanPowerCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedLibrary("bsm"),
            ]
        ),
        .executableTarget(
            name: "FanPowerClient",
            dependencies: ["FanPowerCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "FanPowerOwnerSelfTests",
            dependencies: ["FanPowerCore"],
            path: "Tests/FanPowerCoreTests"
        ),
    ]
)
