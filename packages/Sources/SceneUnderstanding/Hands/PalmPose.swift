import Foundation
import simd

/// An open, upward-facing palm offered as a landing pad (spec/05-scene.md §Hands).
///
/// Pure geometry, so the "is this palm up?" rule is a unit test rather than something
/// checked by holding a headset. `HandTrackingSession` supplies the joint positions and
/// this decides; nothing here imports ARKit.
public struct PalmPose: Sendable, Hashable {
    public enum Chirality: Sendable, Hashable {
        case left
        case right
    }

    /// Centre of the palm, in world space.
    public var center: SIMD3<Float>
    /// Unit normal pointing out of the palmar surface. Up when the hand is offered.
    public var normal: SIMD3<Float>
    /// Where a perched character should stand: just above the skin, never inside it.
    public var landing: SIMD3<Float>
    /// Yaw, radians, so a character standing here faces back along the fingers.
    public var yaw: Float
    public var chirality: Chirality

    public init(
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        landing: SIMD3<Float>,
        yaw: Float,
        chirality: Chirality
    ) {
        self.center = center
        self.normal = normal
        self.landing = landing
        self.yaw = yaw
        self.chirality = chirality
    }
}

/// Decides whether a hand is offering a palm, from four joint positions.
public enum PalmDetector {
    /// How closely the palm normal must align with world up. cos(~37°).
    public static let upThreshold: Float = 0.8
    /// Clearance above the skin for the landing point, metres.
    public static let landingClearance: Float = 0.02
    /// A hand smaller than this is a tracking artefact, not a palm.
    public static let minimumSpan: Float = 0.04

    /// Palm normal from the wrist/index/little triangle.
    ///
    /// The cross product flips with handedness, so chirality picks the winding rather than
    /// the caller guessing: a left hand held palm-up and a right hand held palm-up must
    /// both return an upward normal.
    public static func normal(
        wrist: SIMD3<Float>,
        indexKnuckle: SIMD3<Float>,
        littleKnuckle: SIMD3<Float>,
        chirality: PalmPose.Chirality
    ) -> SIMD3<Float>? {
        let index = indexKnuckle - wrist
        let little = littleKnuckle - wrist
        // Right hand, palm up, fingers -Z: the index knuckle sits at +X and the little
        // knuckle at -X, so index x little is the outward (upward) palmar normal. The
        // left hand mirrors that knuckle order, hence the swapped winding.
        let raw = chirality == .right
            ? simd_cross(index, little)
            : simd_cross(little, index)
        guard simd_length(raw) > 1e-6 else { return nil }
        return simd_normalize(raw)
    }

    /// Returns a pose only when the hand reads as an open palm facing the sky.
    public static func evaluate(
        wrist: SIMD3<Float>,
        indexKnuckle: SIMD3<Float>,
        littleKnuckle: SIMD3<Float>,
        middleKnuckle: SIMD3<Float>,
        chirality: PalmPose.Chirality,
        up: SIMD3<Float> = SIMD3(0, 1, 0)
    ) -> PalmPose? {
        let span = simd_distance(indexKnuckle, littleKnuckle)
        guard span >= minimumSpan else { return nil }
        guard
            let n = normal(
                wrist: wrist,
                indexKnuckle: indexKnuckle,
                littleKnuckle: littleKnuckle,
                chirality: chirality
            )
        else { return nil }
        guard simd_dot(n, simd_normalize(up)) >= upThreshold else { return nil }

        // Midway between the wrist and the knuckles is the flat of the palm; the knuckle
        // line alone sits too far forward and the character ends up on the fingers.
        let center = (wrist + middleKnuckle) * 0.5
        let forward = middleKnuckle - wrist
        let planar = SIMD3(forward.x, 0, forward.z)
        let yaw = simd_length(planar) < 1e-4 ? 0 : atan2(-planar.x, -planar.z)
        return PalmPose(
            center: center,
            normal: n,
            landing: center + n * landingClearance,
            yaw: yaw,
            chirality: chirality
        )
    }
}

/// Debounces palm detection so a character does not launch at a hand that flickered.
///
/// Hysteresis is asymmetric on purpose: slow to commit, quick to release. A false takeoff
/// looks broken; a slightly early return to the floor just looks like the bird chose to go.
public struct PalmGate: Sendable {
    public static let engageDwell: Float = 0.35
    public static let releaseDwell: Float = 0.25

    public private(set) var pose: PalmPose?
    public private(set) var isOffered = false

    private var heldFor: Float = 0
    private var lostFor: Float = 0

    public init() {}

    /// Feed the frame's candidate (nil when no hand qualifies). Returns the stable pose.
    @discardableResult
    public mutating func update(deltaTime: Float, candidate: PalmPose?) -> PalmPose? {
        if let candidate {
            pose = candidate
            lostFor = 0
            heldFor += deltaTime
            if heldFor >= Self.engageDwell { isOffered = true }
        } else {
            heldFor = 0
            lostFor += deltaTime
            if lostFor >= Self.releaseDwell {
                isOffered = false
                pose = nil
            }
        }
        return isOffered ? pose : nil
    }

    public mutating func reset() {
        self = PalmGate()
    }
}
