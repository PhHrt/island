// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [.macOS(.v26)],
    targets: [
        // Logique pure, sans UI ni API système : testée par `swift test`.
        .target(
            name: "IslandCore",
            path: "Sources/IslandCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Island",
            dependencies: ["IslandCore"],
            path: "Sources/Island",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IslandCoreTests",
            dependencies: ["IslandCore"],
            path: "Tests/IslandCoreTests"
        ),
    ]
)
