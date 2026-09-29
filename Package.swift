// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Signloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Signloader",
            path: "Sources/Signloader",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
