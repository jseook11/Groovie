// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Groovie",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Groovie", targets: ["Groovie"]),
    ],
    targets: [
        .target(
            name: "GroovieKit",
            path: "Sources/GroovieKit",
            resources: [.copy("Resources/Localization")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Groovie",
            dependencies: ["GroovieKit"],
            path: "Sources/Groovie",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
