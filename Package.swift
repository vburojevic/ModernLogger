// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ModernLogger",
    platforms: [
        // Choose modern baselines that work across all Apple platforms.
        // If your projects need older deployment targets, lower these as needed.
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ModernLogger", targets: ["ModernLogger"]),
        .executable(name: "modernlogger-cli", targets: ["ModernLoggerCLI"]),
    ],
    targets: [
        .target(name: "ModernLogger"),
        .executableTarget(name: "ModernLoggerCLI", dependencies: ["ModernLogger"]),
        .testTarget(name: "ModernLoggerTests", dependencies: ["ModernLogger"]),
    ]
)
