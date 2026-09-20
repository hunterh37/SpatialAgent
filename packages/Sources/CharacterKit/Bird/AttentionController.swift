import Foundation
import simd

/// Where the bird is looking.
///
/// Spec 06 §Attention: eyes lead the head, the head leads the body, and reversing that order
/// is the single most common way a character reads as dead. So the three are three springs
/// with deliberately different stiffness, not one transform with a lag applied.
///
/// Attention is deliberately independent of locomotion. The bird must be able to watch the
/// user while hopping away, which means nothing in here reads the hop controller and nothing
/// in the hop controller writes here; they meet only at the rig.
public struct AttentionController: Sendable {
    // MARK: Spec limits

    /// Head yaw is limited to ±75° from body forward.
    public static let maxHeadYaw: Float = 75 * .pi / 180
    /// Pitch ±40°.
    public static let maxHeadPitch: Float = 40 * .pi / 180
    /// Beyond the yaw limit the body turns to follow after a short delay — the double-take.
    public static let bodyTurnDelay: Float = 0.22

    /// Tuned so the head reaches half of a step change in ~110ms, inside the spec's 80–140ms
    /// trailing window.
    public static let headStiffness: Float = 14
    /// The eyes are roughly three times as quick, which is what "eyes lead" means in numbers.
    public static let eyeStiffness: Float = 42
    /// The body is slowest of the three by a wide margin.
    public static let bodyStiffness: Float = 7

    // MARK: State

    private var headYawSpring = AngularSpring(stiffness: AttentionController.headStiffness)
    private var headPitchSpring = AngularSpring(stiffness: AttentionController.headStiffness)
    private var eyeYawSpring = AngularSpring(stiffness: AttentionController.eyeStiffness)
    private var eyePitchSpring = AngularSpring(stiffness: AttentionController.eyeStiffness)
    private var beyondLimitFor: Float = 0

    /// World-space point the bird is attending to. Nil parks the head at body forward.
    public var target: SIMD3<Float>?

    /// Head yaw and pitch relative to body forward, clamped to the spec limits.
    public private(set) var headYaw: Float = 0
    public private(set) var headPitch: Float = 0
    /// Pupil offset on the eye surface, -1...1 in each axis. Eyes reach the target first.
    public private(set) var pupilOffset: SIMD2<Float> = .zero
    /// Set while the target is past the head's reach and the delay has elapsed. The locomotion
    /// layer is what actually turns the body; attention only asks.
    public private(set) var bodyTurnRequest: Float?

    public init() {}

    /// Advances attention.
    ///
    /// - Parameters:
    ///   - origin: the bird's world position, head height included or not — only the direction
    ///     matters.
    ///   - bodyYaw: current body yaw, which head yaw is expressed relative to.
    public mutating func update(deltaTime: Float, origin: SIMD3<Float>, bodyYaw: Float) {
        guard deltaTime > 0 else { return }

        let desired = desiredAngles(origin: origin, bodyYaw: bodyYaw)
        // Past the limit the head still goes as far as it can and waits for the body; it does
        // not give up and centre, which would read as losing interest.
        let clampedYaw = min(Self.maxHeadYaw, max(-Self.maxHeadYaw, desired.yaw))
        let clampedPitch = min(Self.maxHeadPitch, max(-Self.maxHeadPitch, desired.pitch))

        headYawSpring.target = clampedYaw
        headPitchSpring.target = clampedPitch
        eyeYawSpring.target = clampedYaw
        eyePitchSpring.target = clampedPitch

        headYawSpring.step(deltaTime)
        headPitchSpring.step(deltaTime)
        eyeYawSpring.step(deltaTime)
        eyePitchSpring.step(deltaTime)

        // Clamped again after integration: a spring can overshoot, and an overshoot past the
        // limit is a head through a shoulder.
        headYaw = min(Self.maxHeadYaw, max(-Self.maxHeadYaw, headYawSpring.value))
        headPitch = min(Self.maxHeadPitch, max(-Self.maxHeadPitch, headPitchSpring.value))

        // The pupil carries what the head has not caught up with yet. That residual is
        // literally the eyes leading the head.
        let residualYaw = eyeYawSpring.value - headYaw
        let residualPitch = eyePitchSpring.value - headPitch
        pupilOffset = SIMD2(
            min(1, max(-1, residualYaw / (Self.maxHeadYaw * 0.35))),
            min(1, max(-1, residualPitch / (Self.maxHeadPitch * 0.35)))
        )

        updateBodyTurn(desiredYaw: desired.yaw, bodyYaw: bodyYaw, deltaTime: deltaTime)
    }

    private mutating func updateBodyTurn(desiredYaw: Float, bodyYaw: Float, deltaTime: Float) {
        if abs(desiredYaw) > Self.maxHeadYaw {
            beyondLimitFor += deltaTime
            if beyondLimitFor >= Self.bodyTurnDelay {
                bodyTurnRequest = bodyYaw + desiredYaw
            }
        } else {
            beyondLimitFor = 0
            bodyTurnRequest = nil
        }
    }

    /// Clears a served request. The caller turning the body is what ends the double-take.
    public mutating func bodyTurnServed() {
        bodyTurnRequest = nil
        beyondLimitFor = 0
    }

    public mutating func reset() {
        headYawSpring.reset(to: 0)
        headPitchSpring.reset(to: 0)
        eyeYawSpring.reset(to: 0)
        eyePitchSpring.reset(to: 0)
        headYaw = 0
        headPitch = 0
        pupilOffset = .zero
        bodyTurnRequest = nil
        beyondLimitFor = 0
    }

    /// True while the head is pinned at its limit waiting for the body.
    public var isAtYawLimit: Bool { abs(headYaw) >= Self.maxHeadYaw - 1e-4 }

    private func desiredAngles(origin: SIMD3<Float>, bodyYaw: Float) -> (yaw: Float, pitch: Float) {
        guard let target else { return (0, 0) }
        let delta = target - origin
        let horizontal = simd_length(SIMD3(delta.x, 0, delta.z))
        guard horizontal > 1e-4 || abs(delta.y) > 1e-4 else { return (0, 0) }
        let worldYaw = atan2(delta.x, delta.z)
        let yaw = AngularSpring.shortest(from: bodyYaw, to: worldYaw)
        let pitch = atan2(delta.y, max(horizontal, 1e-4))
        return (yaw, pitch)
    }
}
