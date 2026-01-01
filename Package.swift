// swift-tools-version: 6.2
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
    ],
    targets: [
        .target(name: "ModernLogger"),
        .testTarget(name: "ModernLoggerTests", dependencies: ["ModernLogger"]),
    ]
)
