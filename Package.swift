// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchVinyl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchVinyl", targets: ["NotchVinyl"]),
    ],
    targets: [
        .target(
            name: "NotchVinylKit",
            path: "Sources/NotchVinylKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NotchVinyl",
            dependencies: ["NotchVinylKit"],
            path: "Sources/NotchVinyl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
