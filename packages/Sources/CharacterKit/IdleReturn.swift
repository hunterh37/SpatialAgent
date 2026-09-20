import Foundation
import SpatialMemory
import simd

/// When an idle bird goes home.
///
/// Presence is what makes the character feel resident rather than summoned, and the taught
/// home perch is the only spot the user chose for it. This is a pure policy so the timing —
/// the one thing that reads as "twitchy" or "dead" — is testable without a headset and
/// without RealityKit.
public enum IdleReturn {
    /// How long the bird stays where the conversation left it before drifting home. Long
    /// enough that it is not walking off mid-answer, short enough to be seen in a demo.
    public static let settleDelay: TimeInterval = 6
    /// Already home. Without this the bird re-paths every tick once it arrives.
    public static let arrivalRadius: Float = 0.35

    /// True when the character should path back to the perch now.
    public static func shouldReturn(
        isIdle: Bool,
        idleFor: TimeInterval,
        characterPosition: SIMD3<Float>,
        perch: SIMD3<Float>?
    ) -> Bool {
        guard isIdle, let perch, idleFor >= settleDelay else { return false }
        return planarDistance(characterPosition, perch) > arrivalRadius
    }

    /// The same policy against a map. The perch is never passed in by the app layer: the one
    /// the user taught is `SemanticMap.homePerch`, and a perch the bird cannot currently reach
    /// is no target at all (a stale anchor would send it to a coordinate that moved).
    public static func shouldReturn(
        isIdle: Bool,
        idleFor: TimeInterval,
        characterPosition: SIMD3<Float>,
        map: SemanticMap
    ) -> Bool {
        guard let perch = map.homePerch, perch.isNavigable else { return false }
        return shouldReturn(
            isIdle: isIdle,
            idleFor: idleFor,
            characterPosition: characterPosition,
            perch: perch.position
        )
    }

    public static func planarDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }
}
