// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PublicStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sketchybar-public-stats", targets: ["PublicStats"])
    ],
    targets: [
        .executableTarget(
            name: "PublicStats",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
