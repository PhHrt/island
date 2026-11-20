// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Island",
            path: "Sources/Island",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
