// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "heed",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure state machine: no Accessibility, no AppKit. Unit-testable in isolation.
        .target(
            name: "HeedCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Heed",
            dependencies: ["HeedCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Renders the iconset. Shares `HeedCore.glyphPath` with the menu bar, so the app icon and
        // the status item can never drift apart.
        .executableTarget(
            name: "heed-icon",
            dependencies: ["HeedCore"],
            path: "Sources/IconTool",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HeedCoreTests",
            dependencies: ["HeedCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
