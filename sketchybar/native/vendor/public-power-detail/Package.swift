// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PublicPowerDetailPrototype",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PublicPowerDetail", targets: ["PublicPowerDetail"]),
    ],
    targets: [
        .systemLibrary(name: "CDarwinNotify"),
        .target(
            name: "PublicPowerDetail",
            dependencies: ["CDarwinNotify"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
