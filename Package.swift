// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Grabit",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Grabit", path: "Sources/Grabit")
    ],
    swiftLanguageModes: [.v5]
)
