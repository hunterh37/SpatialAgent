#if os(visionOS)
import ARKit
import Foundation
import simd

/// ARKit hand tracking reduced to at most one offered palm.
///
/// Privacy (spec/05-scene.md): joints never leave the device and are never published. The
/// only thing this type exposes is a `PalmPose`, which is the same abstraction level as a
/// named place.
///
/// Polled, not streamed. `latestAnchors` is already the newest pose ARKit has, so a frame
/// callback reading it is cheaper and stays in step with the render loop, rather than a
/// task queueing joint arrays the renderer will discard.
@MainActor
public final class HandTrackingSession {
    public let session = ARKitSession()
    public let provider = HandTrackingProvider()

    public private(set) var gate = PalmGate()
    public private(set) var isRunning = false

    /// The stable, debounced palm, or nil when no hand is offered.
    public var palm: PalmPose? { gate.isOffered ? gate.pose : nil }

    /// Both hands' palm centres this frame, left then right, nil where untracked.
    ///
    /// Raw and undebounced on purpose: this is what `KnockDetector` differentiates for
    /// speed, and a gate built to reject flicker would also reject the fast swipe that is
    /// the entire gesture. Still an abstraction, not joints — two points leave this type,
    /// the same as before, and nothing downstream can reconstruct a hand from them.
    public private(set) var handPoints: [SIMD3<Float>?] = [nil, nil]

    public init() {}

    public static var isSupported: Bool { HandTrackingProvider.isSupported }

    public func start() async {
        guard Self.isSupported, !isRunning else { return }
        do {
            try await session.run([provider])
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    public func stop() {
        guard isRunning else { return }
        session.stop()
        isRunning = false
        gate.reset()
        handPoints = [nil, nil]
    }

    /// Call once per frame. Returns the stable palm pose, if any.
    @discardableResult
    public func update(deltaTime: Float) -> PalmPose? {
        guard isRunning else { return nil }
        let hands = provider.latestAnchors
        handPoints = [Self.center(of: hands.leftHand), Self.center(of: hands.rightHand)]
        // The right hand wins a tie only because a tie means both palms are up, and
        // switching perch target every frame between two valid hands reads as a glitch.
        let candidate = Self.palmPose(from: hands.rightHand)
            ?? Self.palmPose(from: hands.leftHand)
        return gate.update(deltaTime: deltaTime, candidate: candidate)
    }

    /// Palm centre of a tracked hand, regardless of which way it faces. A knock is a hand
    /// moving through the bird; whether the palm happens to be up is irrelevant to it.
    static func center(of anchor: HandAnchor?) -> SIMD3<Float>? {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let origin = anchor.originFromAnchorTransform
        let wristJoint = skeleton.joint(.wrist)
        let knuckleJoint = skeleton.joint(.middleFingerKnuckle)
        guard wristJoint.isTracked, knuckleJoint.isTracked else { return nil }
        func world(_ joint: HandSkeleton.Joint) -> SIMD3<Float> {
            let m = origin * joint.anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        return (world(wristJoint) + world(knuckleJoint)) * 0.5
    }

    static func palmPose(from anchor: HandAnchor?) -> PalmPose? {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let origin = anchor.originFromAnchorTransform
        func world(_ name: HandSkeleton.JointName) -> SIMD3<Float>? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            let m = origin * joint.anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        guard
            let wrist = world(.wrist),
            let index = world(.indexFingerKnuckle),
            let little = world(.littleFingerKnuckle),
            let middle = world(.middleFingerKnuckle)
        else { return nil }
        return PalmDetector.evaluate(
            wrist: wrist,
            indexKnuckle: index,
            littleKnuckle: little,
            middleKnuckle: middle,
            chirality: anchor.chirality == .right ? .right : .left
        )
    }
}
#endif
