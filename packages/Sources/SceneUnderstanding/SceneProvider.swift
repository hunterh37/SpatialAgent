import AgentProtocol
import Foundation
import SpatialMemory
import simd

/// Abstract scene source, so `AgentKit` and previews can run against a fixture room while
/// the headset runs against ARKit. The fixture mirrors `mocks/scenarios/*.yaml` on the
/// Python side, so both halves of the project test against the same imagined apartment.
@MainActor
public protocol SceneProviding: AnyObject {
    var navMesh: NavMesh? { get }
    var userPosition: SIMD3<Float> { get }
    var userForward: SIMD3<Float> { get }
    func start() async
    func stop()
    /// Fires when the navmesh is rebuilt, not per frame — `sceneUpdate` is throttled to
    /// meaningful change (spec/03-protocol.md).
    var onMeshChanged: ((NavMesh) -> Void)? { get set }
}

/// The fixture room has no world tracking, so every anchor it hands out is a plain UUID that
/// is immediately "relocalized". That keeps fixture-backed records navigable without
/// pretending the fixture has an ARKit session.
@MainActor
public final class FixtureSceneProvider: SceneProviding, AnchorProviding {
    public var onAnchorUpdate: ((UUID, SIMD3<Float>?) -> Void)?

    public var navMesh: NavMesh?
    public var userPosition: SIMD3<Float>
    public var userForward: SIMD3<Float>
    public var onMeshChanged: ((NavMesh) -> Void)?

    /// A 5m x 4m room with a couch and a table subtracted. Matches the shape of
    /// `services/agentd/mocks/scenarios/apartment.yaml`.
    public static func apartment() -> FixtureSceneProvider {
        let floor = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(5, 4))
        let couch = FloorRect(center: SIMD3(-1.6, 0, -1.2), extent: SIMD2(1.8, 0.8))
        let table = FloorRect(center: SIMD3(1.2, 0, 0.6), extent: SIMD2(1.2, 0.7))
        return FixtureSceneProvider(floors: [floor], obstacles: [couch, table])
    }

    public init(
        floors: [FloorRect],
        obstacles: [FloorRect],
        userPosition: SIMD3<Float> = SIMD3(0, 1.5, 1.6),
        userForward: SIMD3<Float> = SIMD3(0, 0, -1)
    ) {
        self.userPosition = userPosition
        self.userForward = userForward
        navMesh = NavMeshBuilder.build(floors: floors, obstacles: obstacles)
    }

    public func start() async {
        if let navMesh { onMeshChanged?(navMesh) }
    }

    public func stop() {}

    public func addAnchor(at position: SIMD3<Float>) async -> UUID? {
        let id = UUID()
        onAnchorUpdate?(id, position)
        return id
    }

    public func removeAnchor(id: UUID) async {
        onAnchorUpdate?(id, nil)
    }
}

#if os(visionOS)
import ARKit
import QuartzCore

/// ARKit plane detection + scene reconstruction reduced to a navmesh.
///
/// Privacy (spec/05-scene.md): nothing here is ever sent upstream. `agentd` receives named
/// places, bounds and a floor area — abstractions — never camera frames or raw meshes. The
/// reduction to `FloorRect` happens on-device and is the boundary that guarantees it.
@MainActor
public final class ARKitSceneProvider: SceneProviding, AnchorProviding {
    public private(set) var navMesh: NavMesh?
    public private(set) var userPosition: SIMD3<Float> = .zero
    public private(set) var userForward: SIMD3<Float> = SIMD3(0, 0, -1)
    public var onMeshChanged: ((NavMesh) -> Void)?

    public let session = ARKitSession()
    public let worldTracking = WorldTrackingProvider()
    private let planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])

    private var floors: [UUID: FloorRect] = [:]
    private var obstacles: [UUID: FloorRect] = [:]
    private var rebuildTask: Task<Void, Never>?
    private var knownAnchors: [UUID: WorldAnchor] = [:]

    public init() {}

    public var isSupported: Bool {
        PlaneDetectionProvider.isSupported && WorldTrackingProvider.isSupported
    }

    public func start() async {
        guard isSupported else { return }
        do {
            try await session.run([worldTracking, planeDetection])
        } catch {
            return
        }
        Task { await consumePlanes() }
        Task { await trackUser() }
        Task { await consumeWorldAnchors() }
    }

    public func stop() {
        rebuildTask?.cancel()
        session.stop()
    }

    /// Fires as world anchors relocalize, move, or are lost. `AnchorBinding` subscribes and
    /// writes the result into the map's cached transforms (spec 07 §Model).
    public var onAnchorUpdate: ((UUID, SIMD3<Float>?) -> Void)?

    public func removeAnchor(id: UUID) async {
        guard let anchor = knownAnchors[id] else { return }
        try? await worldTracking.removeAnchor(anchor)
        knownAnchors[id] = nil
    }

    public func addAnchor(at position: SIMD3<Float>) async -> UUID? {
        await anchorPlace(at: position)
    }

    /// Persists a named place against a world anchor so it survives the session.
    /// Returns the anchor id to store alongside the place.
    public func anchorPlace(at position: SIMD3<Float>) async -> UUID? {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        let anchor = WorldAnchor(originFromAnchorTransform: transform)
        do {
            try await worldTracking.addAnchor(anchor)
            knownAnchors[anchor.id] = anchor
            return anchor.id
        } catch {
            return nil
        }
    }

    /// Relocalization is the whole reason a taught place lands in the same physical spot
    /// after a relaunch, so the stream is consumed for the life of the session rather than
    /// polled at launch.
    private func consumeWorldAnchors() async {
        for await update in worldTracking.anchorUpdates {
            let anchor = update.anchor
            switch update.event {
            case .added, .updated:
                knownAnchors[anchor.id] = anchor
                guard anchor.isTracked else {
                    onAnchorUpdate?(anchor.id, nil)
                    continue
                }
                let m = anchor.originFromAnchorTransform
                onAnchorUpdate?(anchor.id, SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
            case .removed:
                knownAnchors[anchor.id] = nil
                onAnchorUpdate?(anchor.id, nil)
            }
        }
    }

    private func trackUser() async {
        // Head pose drives placement and `lookAt(.user)`. Polled, not per-frame published:
        // the character's gaze is smoothed in CharacterKit.
        while !Task.isCancelled {
            if let device = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                let m = device.originFromAnchorTransform
                userPosition = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                userForward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func consumePlanes() async {
        for await update in planeDetection.anchorUpdates {
            let anchor = update.anchor
            let rect = Self.rect(from: anchor)
            let isFloor = anchor.alignment == .horizontal
                && anchor.classification == .floor

            switch update.event {
            case .added, .updated:
                if isFloor {
                    floors[anchor.id] = rect
                } else if anchor.alignment == .horizontal || anchor.classification == .wall {
                    // Tables, seats and walls all become obstacle footprints. Their height
                    // is irrelevant: a 45cm character cannot pass under a coffee table
                    // convincingly, so a flat subtraction is the honest model.
                    obstacles[anchor.id] = rect
                }
            case .removed:
                floors[anchor.id] = nil
                obstacles[anchor.id] = nil
            }
            scheduleRebuild()
        }
    }

    /// Debounced. Rebuilding per anchor update would rebuild dozens of times a second
    /// during initial room scan and blow the 90fps budget (spec/05-scene.md: rebuild on
    /// meaningful change, not per frame).
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            let mesh = NavMeshBuilder.build(
                floors: Array(self.floors.values),
                obstacles: Array(self.obstacles.values)
            )
            guard let mesh else { return }
            self.navMesh = mesh
            self.onMeshChanged?(mesh)
        }
    }

    private static func rect(from anchor: PlaneAnchor) -> FloorRect {
        let m = anchor.originFromAnchorTransform
        let center = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return FloorRect(
            center: center,
            extent: SIMD2(anchor.geometry.extent.width, anchor.geometry.extent.height)
        )
    }
}
#endif
