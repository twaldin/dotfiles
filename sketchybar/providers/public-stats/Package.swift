// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PublicStats",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sketchybar-public-stats", targets: ["PublicStats"])
    ],
    targets: [
        .executableTarget(
            name: "PublicStats",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("Network"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
