// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MatterGlow",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "MatterGlow", path: "Sources/MatterGlow"),
    ]
)
