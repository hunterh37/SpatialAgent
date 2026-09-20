import Foundation
import simd

/// What the gaze ray landed on. The class decides the radius, so it is part of the hit rather
/// than something inferred later from the geometry (spec 07 §Capture).
public enum GazeSurfaceClass: String, Sendable, Hashable, CaseIterable {
    /// The floor plane. "This is the reading corner."
    case floor
    /// A horizontal or vertical surface: a desk, a shelf, a wall.
    case surface
    /// A cluster of mesh that is not a plane: an appliance, a plant, a vase.
    case objectCluster
}

/// A single raycast result against the scene mesh.
public struct GazeHit: Sendable, Hashable {
    public var point: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// Extent of the thing that was hit — the plane's size, or the cluster's bounds.
    public var extent: SIMD2<Float>
    public var surface: GazeSurfaceClass

    public init(
        point: SIMD3<Float>,
        normal: SIMD3<Float> = SIMD3(0, 1, 0),
        extent: SIMD2<Float>,
        surface: GazeSurfaceClass
    ) {
        self.point = point
        self.normal = normal
        self.extent = extent
        self.surface = surface
    }
}

/// Where a teaching act lands, with the radius the geometry implies.
public struct GazeTarget: Sendable, Hashable {
    public var point: SIMD3<Float>
    public var radius: Float
    public var surface: GazeSurfaceClass
    /// When the utterance that captured this began.
    public var capturedAt: Date

    public init(hit: GazeHit, capturedAt: Date = Date()) {
        point = hit.point
        radius = GazeTarget.radius(for: hit)
        surface = hit.surface
        self.capturedAt = capturedAt
    }

    // MARK: Radius rules (spec 07 §Capture)

    /// A surface hit adopts the plane's extent clamped to 0.3–2.0m.
    public static let surfaceRadiusRange: ClosedRange<Float> = 0.3...2.0
    /// A floor hit adopts 1.0m.
    public static let floorRadius: Float = 1.0
    /// An object hit adopts the mesh cluster bounds plus 10cm.
    public static let objectMargin: Float = 0.1

    /// Radius comes from the geometry, not a constant.
    ///
    /// A constant radius is what makes "this is my desk" and "this is the kitchen" the same
    /// size, and then the bird either stands on the desk or thinks half the flat is kitchen.
    public static func radius(for hit: GazeHit) -> Float {
        switch hit.surface {
        case .floor:
            return floorRadius
        case .surface:
            // Half the larger extent: the radius covers the surface, it does not inscribe it.
            let half = max(hit.extent.x, hit.extent.y) / 2
            return min(surfaceRadiusRange.upperBound, max(surfaceRadiusRange.lowerBound, half))
        case .objectCluster:
            return max(hit.extent.x, hit.extent.y) / 2 + objectMargin
        }
    }
}

/// Something that can cast a gaze ray at the room. A protocol so teaching can be tested
/// against a synthetic mesh, and so the ARKit implementation is swappable.
@MainActor
public protocol GazeCasting: AnyObject {
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> GazeHit?
}

/// Holds the gaze target for the duration of an utterance.
///
/// The target is the hit at the moment the utterance *begins*, not when it ends (spec 07
/// §Capture): by the end of "this is my workspace" the user is already looking somewhere
/// else, and naming whatever they glanced at last is how a teaching act silently lands on the
/// wrong thing.
@MainActor
public final class GazeCapture {
    private let caster: GazeCasting?

    public private(set) var held: GazeTarget?
    /// True when an utterance started with no valid hit. The bird asks rather than guessing,
    /// and the act stays open for one follow-up turn.
    public private(set) var isAwaitingFollowUp = false

    public init(caster: GazeCasting?) {
        self.caster = caster
    }

    /// Captures and holds the target. Call at utterance start.
    @discardableResult
    public func beginUtterance(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        at date: Date = Date()
    ) -> GazeTarget? {
        guard let hit = caster?.raycast(origin: origin, direction: direction) else {
            held = nil
            isAwaitingFollowUp = true
            return nil
        }
        held = GazeTarget(hit: hit, capturedAt: date)
        isAwaitingFollowUp = false
        return held
    }

    /// The held target, for the whole act. Deliberately does not re-cast.
    public func target(atUtteranceEnd: Bool = true) -> GazeTarget? { held }

    /// Clears the hold once the act is finished or abandoned.
    public func endAct() {
        held = nil
        isAwaitingFollowUp = false
    }

    /// The one follow-up turn a missed gaze gets: "look at it and say that again."
    public func resolveFollowUp(origin: SIMD3<Float>, direction: SIMD3<Float>) -> GazeTarget? {
        guard isAwaitingFollowUp else { return held }
        return beginUtterance(origin: origin, direction: direction)
    }
}

/// A raycaster over axis-aligned planes and box clusters.
///
/// It is the fixture half of `GazeCasting`: the headset casts against the ARKit scene mesh,
/// and everything below the raycast — the radius rules, the hold-from-utterance-start
/// behavior — is identical either way and gets tested here.
@MainActor
public final class SyntheticSceneMesh: GazeCasting {
    public struct Target: Sendable, Hashable {
        public var center: SIMD3<Float>
        public var extent: SIMD2<Float>
        public var surface: GazeSurfaceClass
        /// Vertical thickness for clusters; planes are flat.
        public var height: Float

        public init(
            center: SIMD3<Float>,
            extent: SIMD2<Float>,
            surface: GazeSurfaceClass,
            height: Float = 0
        ) {
            self.center = center
            self.extent = extent
            self.surface = surface
            self.height = height
        }
    }

    public var targets: [Target]

    public init(targets: [Target]) {
        self.targets = targets
    }

    /// A 4x4 floor with a desk and a coffee machine on it.
    public static func room() -> SyntheticSceneMesh {
        SyntheticSceneMesh(targets: [
            Target(center: SIMD3(0, 0, 0), extent: SIMD2(4, 4), surface: .floor),
            Target(center: SIMD3(1.2, 0.74, -1.0), extent: SIMD2(1.4, 0.7), surface: .surface),
            Target(
                center: SIMD3(1.5, 0.92, -1.0), extent: SIMD2(0.24, 0.3),
                surface: .objectCluster, height: 0.36
            ),
        ])
    }

    /// Nearest hit along the ray. Clusters are tested before planes at equal distance, since
    /// a machine standing on a desk is what the user is looking at, not the desk under it.
    public func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> GazeHit? {
        let ray = simd_length(direction) > 1e-6 ? simd_normalize(direction) : SIMD3(0, -1, 0)
        var best: (GazeHit, Float)?

        for target in targets {
            let planeY = target.center.y + target.height
            guard abs(ray.y) > 1e-6 else { continue }
            let t = (planeY - origin.y) / ray.y
            guard t > 0 else { continue }
            let point = origin + ray * t
            let dx = abs(point.x - target.center.x)
            let dz = abs(point.z - target.center.z)
            guard dx <= target.extent.x / 2, dz <= target.extent.y / 2 else { continue }

            let hit = GazeHit(
                point: point,
                normal: SIMD3(0, 1, 0),
                extent: target.extent,
                surface: target.surface
            )
            if best == nil || t < best!.1 { best = (hit, t) }
        }
        return best?.0
    }
}
