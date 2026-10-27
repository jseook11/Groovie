// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Umak",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Umak", targets: ["Umak"]),
    ],
    targets: [
        .target(
            name: "UmakKit",
            path: "Sources/UmakKit",
            resources: [.copy("Resources/Localization")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Umak",
            dependencies: ["UmakKit"],
            path: "Sources/Umak",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
