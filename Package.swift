// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agentable",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "agentable", targets: ["agentable"]),
        .executable(name: "AgentableApp", targets: ["AgentableApp"]),
        .library(name: "AgentableCore", targets: ["AgentableCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "AgentableCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "agentable",
            dependencies: [
                "AgentableCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "AgentableApp",
            dependencies: ["AgentableCore"],
            // Translations ship in the app bundle (Contents/Resources/*.lproj), where SwiftUI looks.
            exclude: ["Resources/AppIcon.icns", "Localization"],
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(
            name: "AgentableCoreTests",
            dependencies: ["AgentableCore"]
        ),
    ]
)
