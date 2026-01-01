// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ModernSwiftLogger",
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
        .library(name: "ModernSwiftLogger", targets: ["ModernSwiftLogger"]),
        .executable(name: "modernswiftlogger-cli", targets: ["ModernSwiftLoggerCLI"]),
    ],
    targets: [
        .target(name: "ModernSwiftLogger"),
        .executableTarget(name: "ModernSwiftLoggerCLI", dependencies: ["ModernSwiftLogger"]),
        .testTarget(name: "ModernSwiftLoggerTests", dependencies: ["ModernSwiftLogger"]),
    ]
)
