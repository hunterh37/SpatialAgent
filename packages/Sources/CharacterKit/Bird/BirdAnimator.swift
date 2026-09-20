import Foundation
import simd

/// A squash-and-stretch pulse: set instantly, hold, ease back.
///
/// Spec 06 gives the landing shape exactly — (1.08, 0.88) held 60ms, eased back over 140ms —
/// and calls it "the difference between alive and mechanical". It is a fixed-duration curve
/// rather than a spring because a squash has to *end*, on time, every time.
public struct Squash: Equatable, Sendable {
    /// Horizontal scale at full squash. >1 is a squash, <1 a stretch.
    public private(set) var amount: Float = 0
    private var hold: Float = 0
    private var release: Float = 0
    private var elapsed: Float = 0
    private var active = false

    public init() {}

    /// Landing: wide and short. Anticipation before takeoff is the same call with a negative
    /// amount, which stretches instead.
    public mutating func trigger(amount: Float, hold: Float = 0.06, release: Float = 0.14) {
        self.amount = amount
        self.hold = max(0, hold)
        self.release = max(0.001, release)
        elapsed = 0
        active = true
    }

    public mutating func step(_ deltaTime: Float) {
        guard active else { return }
        elapsed += deltaTime
        if elapsed >= hold + release {
            active = false
            elapsed = 0
            amount = 0
        }
    }

    public var isActive: Bool { active }

    /// 1.0 at rest. Multiplies the body's authored scale.
    public var scale: SIMD3<Float> {
        guard active else { return SIMD3(repeating: 1) }
        let strength: Float
        if elapsed <= hold {
            strength = 1
        } else {
            strength = 1 - Easing.outCubic((elapsed - hold) / release)
        }
        let s = amount * strength
        // Volume-preserving in the visual sense: wider by s, shorter by s.
        return SIMD3(1 + s, 1 - s, 1 + s)
    }
}

/// The per-frame driver for everything on the bird that is not a named behavior.
///
/// Breathing, squash and the shared springs live here because they run underneath every state:
/// spec 06 says the breathing cycle "must never fully stop while the bird is alive", so it
/// cannot belong to any one controller that a state transition could switch off.
public struct BirdAnimator: Sendable {
    /// 0.25Hz, 2% body scale (spec 06 §Idle).
    public static let breathFrequency: Float = 0.25
    public static let breathAmplitude: Float = 0.02

    /// Spec 06 §Locomotion: the landing shape.
    public static let landingSquash: Float = 0.08
    /// Anticipation squashes the opposite way for 80ms before takeoff.
    public static let anticipationStretch: Float = -0.06

    public private(set) var breathPhase: Float = 0
    public private(set) var squash = Squash()

    /// Vertical bob, driven by locomotion phase and settled by the hop controller.
    public var bob = Spring(stiffness: 70, damping: 0.85)

    /// Scales breathing depth. Mood and state shift it — `sad` breathes shallow, `excited`
    /// breathes fast — but it never reaches zero.
    public var breathDepth: Float = 1.0
    public var breathRate: Float = 1.0

    public init() {}

    public mutating func update(deltaTime: Float) {
        guard deltaTime > 0 else { return }
        breathPhase += deltaTime * Self.breathFrequency * max(0.1, breathRate)
        breathPhase -= breathPhase.rounded(.down)
        squash.step(deltaTime)
        bob.step(deltaTime)
    }

    public mutating func land() {
        squash.trigger(amount: Self.landingSquash, hold: 0.06, release: 0.14)
    }

    public mutating func anticipate() {
        squash.trigger(amount: Self.anticipationStretch, hold: 0.02, release: 0.06)
    }

    /// 1.0 ± the breath amplitude, applied to the body's Y and inversely to its girth.
    public var breathScale: SIMD3<Float> {
        let depth = Self.breathAmplitude * min(1, max(0, breathDepth))
        let s = sin(breathPhase * 2 * .pi) * depth
        return SIMD3(1 - s * 0.5, 1 + s, 1 - s * 0.5)
    }

    /// Everything multiplied together: what the body's scale is this frame, before the rig's
    /// authored proportions.
    public var bodyScale: SIMD3<Float> { breathScale * squash.scale }

    /// Peak deviation breathing can reach. Asserted against the 2% budget.
    public var breathAmplitudeBound: Float { Self.breathAmplitude * min(1, max(0, breathDepth)) }
}

#if canImport(RealityKit)
import RealityKit

extension BirdAnimator {
    /// Writes this frame's values onto the rig. One place, so the frame cost is measurable.
    @MainActor
    public func apply(to rig: BirdRig) {
        if let body = rig.entity(.body) {
            body.scale = rig.proportions.bodyScale * bodyScale
        }
        if let bobJoint = rig.entity(.bob) {
            bobJoint.position.y = bob.value
        }
    }
}
#endif
