// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "IslandCore", targets: ["IslandCore"]),
        .library(name: "PortalKit", targets: ["PortalKit"]),
    ],
    targets: [
        // Logique pure, sans UI ni API système : testée par `swift test`.
        .target(
            name: "IslandCore",
            path: "Sources/IslandCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Transport Portal (iPhone -> Mac), partagé par l'app Mac et l'app iPhone.
        .target(
            name: "PortalKit",
            path: "Sources/PortalKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Island",
            dependencies: ["IslandCore", "PortalKit"],
            path: "Sources/Island",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Outil de test : envoie un fichier ou du texte à Island depuis le Mac, comme le ferait l'iPhone.
        .executableTarget(
            name: "portal-send",
            dependencies: ["PortalKit"],
            path: "Sources/PortalSend",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IslandCoreTests",
            dependencies: ["IslandCore"],
            path: "Tests/IslandCoreTests"
        ),
        .testTarget(
            name: "PortalKitTests",
            dependencies: ["PortalKit"],
            path: "Tests/PortalKitTests"
        ),
    ]
)
