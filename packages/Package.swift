// swift-tools-version: 6.0
import PackageDescription

// Layering rule (docs/architecture.md §1): `apps/` contains no logic.
// AgentProtocol is pure Swift — no RealityKit, no ARKit, no SwiftUI, no deps.
// That constraint is what keeps the Swift client and the Python server from drifting.
//
// Swift 5 language mode throughout: the strict-concurrency migration is its own change and
// mixing it into the initial visionOS layer would obscure both.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SpatialAgentKit",
    platforms: [.visionOS(.v2), .macOS(.v15)],
    products: [
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .library(name: "AgentTransport", targets: ["AgentTransport"]),
        .library(name: "SceneUnderstanding", targets: ["SceneUnderstanding"]),
        .library(name: "SpatialMemory", targets: ["SpatialMemory"]),
        .library(name: "CharacterKit", targets: ["CharacterKit"]),
        .library(name: "HomeBridge", targets: ["HomeBridge"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "VoiceInput", targets: ["VoiceInput"]),
    ],
    targets: [
        .target(name: "AgentProtocol", swiftSettings: swift5),
        .target(name: "AgentTransport", dependencies: ["AgentProtocol"], swiftSettings: swift5),
        .target(
            name: "SceneUnderstanding",
            dependencies: ["AgentProtocol"],
            swiftSettings: swift5
        ),
        // The map is user data with a persistence and privacy story; the scene module is
        // derived sensor data. Separate targets keep that boundary from blurring.
        .target(name: "SpatialMemory", dependencies: ["AgentProtocol"], swiftSettings: swift5),
        .target(
            name: "CharacterKit",
            dependencies: ["AgentProtocol", "SceneUnderstanding", "SpatialMemory"],
            swiftSettings: swift5
        ),
        .target(name: "HomeBridge", dependencies: ["AgentProtocol"], swiftSettings: swift5),
        .target(name: "DesignSystem", swiftSettings: swift5),
        .target(name: "VoiceInput", swiftSettings: swift5),
        .target(
            name: "AgentKit",
            dependencies: [
                "AgentProtocol", "AgentTransport", "SceneUnderstanding", "SpatialMemory",
                "CharacterKit", "HomeBridge",
            ],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "AgentProtocolTests",
            dependencies: ["AgentProtocol"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "SceneUnderstandingTests",
            dependencies: ["SceneUnderstanding"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "SpatialMemoryTests",
            dependencies: ["SpatialMemory"],
            swiftSettings: swift5
        ),
        .testTarget(name: "CharacterKitTests", dependencies: ["CharacterKit"], swiftSettings: swift5),
        .testTarget(name: "HomeBridgeTests", dependencies: ["HomeBridge"], swiftSettings: swift5),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"], swiftSettings: swift5),
        // Live end-to-end against a running agentd + local model. Skips itself unless
        // AGENTD_LIVE_URL is set, so `swift test` stays offline-clean.
        .testTarget(
            name: "LiveIntegrationTests",
            dependencies: [
                "AgentKit", "AgentTransport", "CharacterKit", "SceneUnderstanding",
                "SpatialMemory",
            ],
            swiftSettings: swift5
        ),
    ]
)
