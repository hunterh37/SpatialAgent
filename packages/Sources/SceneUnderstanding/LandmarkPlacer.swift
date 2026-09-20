import Foundation
import SpatialMemory
import simd

/// Writes the demo room's landmark presets into the map the same way a teaching act does.
///
/// It deliberately reuses `AnchorBinding` and the gaze raycast rather than storing bare
/// coordinates: a landmark that is not world-anchored does not survive a relaunch, and
/// "it remembered where my desk is" is the entire claim the demo makes.
///
/// The placement path and the spoken teaching path therefore produce indistinguishable
/// records; this one just gets its name from a preset and its target from a button press.
@MainActor
public final class LandmarkPlacer {
    public enum Outcome: Equatable, Sendable {
        /// Placed against a world anchor from a real gaze hit.
        case placed(name: String, anchored: Bool)
        /// Placed at a synthetic offset because nothing could be raycast — simulator, or a
        /// headset that has not finished scanning. The flow stays demoable either way.
        case placedSynthetically(name: String)
        case failed(String)
    }

    private let store: MapStore
    private let anchors: AnchorBinding?
    private let gaze: GazeCapture?
    private weak var scene: (any SceneProviding)?

    public init(
        store: MapStore,
        scene: (any SceneProviding)?,
        gaze: GazeCapture? = nil,
        anchors: AnchorBinding? = nil
    ) {
        self.store = store
        self.scene = scene
        self.gaze = gaze
        self.anchors = anchors
    }

    // MARK: - Reads

    public func placed(_ preset: LandmarkPreset) -> Place? {
        store.map.place(named: preset.name)
    }

    public func isPlaced(_ preset: LandmarkPreset) -> Bool { placed(preset) != nil }

    /// The next unplaced preset, which is what the checklist highlights.
    public func next(in presets: [LandmarkPreset] = LandmarkPreset.demoRoom) -> LandmarkPreset? {
        presets.first { !isPlaced($0) }
    }

    // MARK: - Writes

    /// Places (or re-places) one landmark where the user is looking.
    @discardableResult
    public func place(_ preset: LandmarkPreset) async -> Outcome {
        let hit = gazeTarget()
        let point = hit?.point ?? syntheticPoint(for: preset)
        guard let point else { return .failed("I don't know where you are yet.") }
        let radius = hit?.radius ?? preset.radius

        let anchorId = await anchors?.anchor(at: point)
        let relocalized = anchors?.hasRelocalized(anchorId) ?? true

        let place = Place(
            name: preset.name,
            position: point,
            radius: radius,
            kind: preset.kind,
            anchorId: anchorId,
            hasRelocalized: relocalized
        )
        let outcome = store.add(place)
        let id: UUID
        switch outcome {
        case let .created(created): id = created
        case let .corrected(corrected): id = corrected
        }

        // Exactly one home perch: placing a new one moves the role off the old place.
        if preset.isHomePerch { store.setHomePerch(id: id) }

        if let kind = preset.rule {
            store.add(
                Rule(
                    name: preset.name,
                    kind: kind,
                    severity: kind.isAlwaysHard ? .hard : .soft,
                    position: point,
                    radius: radius,
                    anchorId: anchorId,
                    hasRelocalized: relocalized
                )
            )
        }

        // The episode is what makes "what have I taught you about this room" answerable
        // after a setup pass that involved no speech at all.
        store.record(
            Episode(placeId: id, kind: .taught, summary: "placed landmark: \(preset.name)")
        )
        gaze?.endAct()

        if hit == nil { return .placedSynthetically(name: preset.name) }
        return .placed(name: preset.name, anchored: anchorId != nil)
    }

    /// Removes a landmark and everything that pointed at it.
    @discardableResult
    public func remove(_ preset: LandmarkPreset) -> Bool {
        var removed = false
        if let place = placed(preset) {
            removed = store.delete(id: place.id)
        }
        // The fragile rule shares the landmark's name but not its id, so it is its own
        // deletion — otherwise "delete the plant" leaves the keep-away region behind.
        for rule in store.map.rules where rule.nameKey == preset.name.lowercased() {
            store.delete(id: rule.id)
            removed = true
        }
        return removed
    }

    /// "Reset room." Everything, including anchors nothing refers to any more.
    public func resetRoom() async {
        store.forgetEverything()
        await anchors?.releaseOrphanedAnchors()
    }

    // MARK: - Targeting

    private func gazeTarget() -> GazeTarget? {
        guard let gaze, let scene else { return nil }
        return gaze.beginUtterance(origin: scene.userPosition, direction: scene.userForward)
    }

    /// Where the fallback puts a landmark: the preset's offset, in the user's frame, dropped
    /// to the floor. Offsets rather than absolute coordinates so the fixture room and a real
    /// room lay out the same way relative to whoever is wearing the headset.
    private func syntheticPoint(for preset: LandmarkPreset) -> SIMD3<Float>? {
        guard let scene else { return nil }
        let forward = planar(scene.userForward)
        let right = SIMD3(-forward.z, 0, forward.x)
        let origin = scene.userPosition
        let point = SIMD3(origin.x, 0, origin.z)
            + right * preset.fallbackOffset.x
            + forward * preset.fallbackOffset.y
        // Clamped onto the mesh when there is one, so a synthetic landmark is still a place
        // the bird can legally stand.
        return scene.navMesh?.clamp(point, maxRadius: 1.0) ?? point
    }

    private func planar(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let flat = SIMD3(v.x, 0, v.z)
        return simd_length(flat) < 1e-4 ? SIMD3(0, 0, -1) : simd_normalize(flat)
    }
}

public extension LandmarkPlacer {
    /// One draggable marker per placed preset: what the immersive view draws.
    struct Marker: Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var position: SIMD3<Float>
        public var isHomePerch: Bool
    }

    var markers: [Marker] {
        LandmarkPreset.demoRoom.compactMap { preset in
            guard let place = placed(preset) else { return nil }
            return Marker(
                id: preset.id,
                name: place.name,
                position: place.position,
                isHomePerch: place.kind == .perch
            )
        }
    }

    /// Drags a landmark to a new point. The record keeps its id — a moved desk is the same
    /// desk — so episodes and rules that point at it stay pointed at it.
    @discardableResult
    func move(_ preset: LandmarkPreset, to point: SIMD3<Float>) async -> Outcome {
        guard let place = placed(preset) else { return .failed("\(preset.name) isn't placed.") }
        let anchorId = await anchors?.anchor(at: point)
        let relocalized = anchors?.hasRelocalized(anchorId) ?? true
        store.mutate {
            $0.move(
                placeId: place.id,
                to: point,
                anchorId: anchorId,
                hasRelocalized: relocalized
            )
        }
        store.record(
            Episode(placeId: place.id, kind: .taught, summary: "moved landmark: \(preset.name)")
        )
        return .placed(name: preset.name, anchored: anchorId != nil)
    }
}
