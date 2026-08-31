// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "heed",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure state machine: no Accessibility, no AppKit. Unit-testable in isolation.
        .target(
            name: "FFMCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Heed",
            dependencies: ["FFMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FFMCoreTests",
            dependencies: ["FFMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
