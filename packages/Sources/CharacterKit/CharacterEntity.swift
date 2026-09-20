#if canImport(RealityKit)
import AgentProtocol
import Foundation
import QuartzCore
import RealityKit
import SceneUnderstanding
import simd

/// The character in the room: the bird rig plus the controllers that drive it.
///
/// Everything here is procedural. There is no USDZ, no skeleton, no `AnimationResource` and no
/// clip names — spec 06 replaced all of it with transform updates, and this type is where the
/// `CharacterStateMachine` meets them. The previous capsule-and-clip path is gone rather than
/// kept as a fallback: a fallback body that cannot express any of the nine expressions is a
/// fallback that silently disables half the product.
///
/// One update per frame, one place, so the 0.4ms budget is measurable.
@MainActor
public final class CharacterEntity {
    public let root = Entity()

    public private(set) var rig: BirdRig
    public private(set) var machine = CharacterStateMachine()
    public private(set) var position: SIMD3<Float> = .zero

    /// Locomotion, motion core, face, attention and idle. Each is a value type with its own
    /// tests; this class owns the wiring and nothing else.
    public private(set) var hop = HopController()
    public private(set) var animator = BirdAnimator()
    public private(set) var face = FaceController()
    public private(set) var attention = AttentionController()
    public private(set) var idle = IdlePool()

    /// 22cm at the crown (spec 06 §Proportions). Kept as a static for call sites that anchor
    /// UI above the head.
    public static let targetHeight: Float = BirdProportions().crownHeight

    /// Wall-clock cost of the last `update`, in seconds. The 0.4ms budget is checked against
    /// this on-device rather than inferred from a profile.
    public private(set) var lastUpdateCost: TimeInterval = 0
    public static let frameBudget: TimeInterval = 0.0004

    private var lookTarget: SIMD3<Float>?
    private var userSilence: Float = 0
    private var stateEntered: TimeInterval = 0

    public init(palette: BirdPalette = .teal) {
        rig = BirdRig(palette: palette)
        root.name = "SpatialAgent.Character"
        root.addChild(rig.root)
        apply(state: machine.state)
    }

    /// Swaps the colour variant. Chosen at hatch and changeable (spec 06 §Variants).
    public func wear(_ palette: BirdPalette) {
        let pose = (position, hop.yaw)
        rig.root.removeFromParent()
        rig = BirdRig(palette: palette)
        root.addChild(rig.root)
        hop.place(at: pose.0, yaw: pose.1)
        position = pose.0
    }

    // MARK: - Placement

    public func place(at pose: Placement.Pose) {
        position = pose.position
        hop.place(at: pose.position, yaw: pose.yaw)
        root.position = pose.position
        root.orientation = simd_quatf(angle: pose.yaw, axis: SIMD3(0, 1, 0))
        attention.reset()
        machine.handle(.settled)
        apply(state: machine.state)
    }

    // MARK: - Directives

    public func apply(_ resolved: ResolvedDirective) {
        switch resolved {
        case let .walk(path):
            machine.handle(.pathAccepted)
            if hop.follow(path: path) == .pathRejected {
                // An unreachable walk fails to idle and speaks from where it stands; it never
                // partially hops toward a wall (spec 06 §Locomotion).
                machine.handle(.interrupted)
            } else {
                // Hops turn between arcs, on the ground, so there is no turn state to wait out.
                machine.handle(.turnComplete)
            }
        case let .look(at: target):
            lookTarget = target
        case let .point(at: target):
            lookTarget = target
            machine.handle(.gestureStarted)
        case .emote, .gesture:
            machine.handle(.gestureStarted)
        case .idle:
            hop.stop()
            machine.handle(.settled)
        case .unresolved:
            // Resolution failure never moves the character. It speaks from where it stands.
            hop.stop()
            machine.handle(.interrupted)
        }
        apply(state: machine.state)
    }

    public func signal(_ event: CharacterEvent) {
        let before = machine.state
        let after = machine.handle(event)
        if event == .addressed || event == .utteranceEnded { userSilence = 0 }
        if event == .firstToken { face.noteToken() }
        if event == .speechEnded || event == .interrupted { face.silence() }
        if before != after { apply(state: after) }
    }

    /// Speech amplitude envelope while `speaking`. The beak follows real tokens, never a guess.
    public func speechToken(amplitude: Float) {
        face.noteToken(amplitude: amplitude)
    }

    // MARK: - State mapping (spec 06 §Mapping to agent state)

    private func apply(state: CharacterState) {
        stateEntered = CACurrentMediaTime()
        switch state {
        case .idle:
            face.set(.neutral)
            animator.breathRate = 1.0
            animator.breathDepth = 1.0
        case .listening:
            // Turns to the user, head tilt, crest forward, blinking slows.
            face.set(.curious)
            idle.interrupt()
            animator.breathRate = 1.0
        case .thinking:
            // Look up and away, crest half-flat, slow drift, no blink.
            face.set(.thinking)
            idle.interrupt()
            lookTarget = nil
            animator.breathRate = 0.8
        case .speaking:
            face.set(.happy)
            idle.interrupt()
            animator.breathRate = 1.1
        case .walking, .turning:
            idle.interrupt()
            animator.breathRate = 1.4
        case .arriving:
            // A settle: one small shuffle, wing fold, blink.
            face.set(.neutral)
            animator.breathRate = 1.2
        case .gesturing:
            face.set(.alert)
            idle.interrupt()
        }
    }

    /// Time since the current state was entered. `thinking` has a 400ms budget from
    /// end-of-utterance and the procedural entry has to land inside it.
    public var timeInState: TimeInterval { CACurrentMediaTime() - stateEntered }

    /// The body change the spec's 400ms budget is measured against: a pose distinct from
    /// neutral, reached without waiting on the model.
    public var hasVisibleBodyChange: Bool {
        FaceParameters.distance(face.expressionParameters, Expression.neutral.parameters) > 0.02
    }

    // MARK: - Per-frame update

    /// Called from a `SceneEvents.Update` subscription. Keeps all motion in one place so the
    /// frame cost is measurable.
    public func update(deltaTime: Float, userPosition: SIMD3<Float>) {
        let started = CACurrentMediaTime()
        defer { lastUpdateCost = CACurrentMediaTime() - started }

        userSilence += deltaTime
        animator.update(deltaTime: deltaTime)
        face.update(deltaTime: deltaTime)
        advanceLocomotion(deltaTime: deltaTime)
        advanceAttention(deltaTime: deltaTime, userPosition: userPosition)
        advanceIdle(deltaTime: deltaTime)
        writeToRig()
    }

    private func advanceLocomotion(deltaTime: Float) {
        guard hop.isMoving else { return }
        for event in hop.update(deltaTime: deltaTime) {
            switch event {
            case .takeoffAnticipated: animator.anticipate()
            case .landed: animator.land()
            case .pathCompleted: signal(.arrived); signal(.settled)
            case .pathRejected: signal(.interrupted)
            }
        }
        position = hop.position
    }

    private func advanceAttention(deltaTime: Float, userPosition: SIMD3<Float>) {
        // Thinking looks up and away; everything else looks at the directive target, or at
        // the user when there is none.
        if machine.state == .thinking {
            attention.target = position + SIMD3(0.4, 0.9, 0.5)
        } else {
            attention.target = lookTarget ?? userPosition
        }
        attention.update(deltaTime: deltaTime, origin: headOrigin(), bodyYaw: hop.yaw)

        // The double-take: the body turns to follow only when the head has run out of reach
        // and only when locomotion is not already using the body.
        if let requested = attention.bodyTurnRequest, !hop.isMoving {
            hop.place(at: position, yaw: requested)
            attention.bodyTurnServed()
        }
    }

    private func advanceIdle(deltaTime: Float) {
        guard machine.state == .idle, !hop.isMoving else { return }
        idle.userSilence = userSilence
        guard let behavior = idle.update(deltaTime: deltaTime) else { return }
        switch behavior {
        case .smallHop:
            // A hop in place: the arc runs, the path is one step forward of nothing.
            animator.anticipate()
        case .settle:
            animator.breathDepth = 0.7
        case .headTilt:
            face.set(.curious)
        case .lookAround, .preenWing, .shuffleTurn, .stretchWings, .scratch:
            face.set(.neutral)
        }
    }

    /// Writes this frame's values onto the rig. Every entity touched per frame is touched
    /// here and nowhere else.
    private func writeToRig() {
        root.position = SIMD3(position.x, position.y, position.z)
        root.orientation = simd_quatf(angle: hop.yaw, axis: SIMD3(0, 1, 0))

        let parameters = face.parameters
        let scale = rig.proportions.normalizationScale

        if let bob = rig.entity(.bob) {
            bob.position.y = hop.bobHeight
        }
        if let body = rig.entity(.body) {
            body.scale = rig.proportions.bodyScale * animator.bodyScale
            body.position.y = rig.proportions.bodyCenterY
                + (hop.bodyDip + parameters.bodyRaise * rig.proportions.bodyDiameter) / scale
        }
        if let head = rig.entity(.head) {
            head.orientation = simd_quatf(angle: attention.headYaw, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: -attention.headPitch, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: parameters.headTilt, axis: SIMD3(0, 0, 1))
                * simd_quatf(angle: parameters.headPitch, axis: SIMD3(1, 0, 0))
        }
        for (joint, side) in [(BirdRig.Joint.eyeL, Float(-1)), (.eyeR, 1)] {
            guard let eye = rig.entity(joint) else { continue }
            eye.scale = SIMD3(1, max(0.05, parameters.eyeOpen), 1)
            if let pupil = eye.children.first {
                let reach = rig.proportions.eyeRadius * 0.45
                pupil.position.x = attention.pupilOffset.x * reach
                pupil.position.y = attention.pupilOffset.y * reach
                pupil.scale = SIMD3(repeating: parameters.pupilDilation)
            }
            if let brow = rig.entity(joint == .eyeL ? .browL : .browR) {
                let inner = parameters.browInner + side * parameters.browAsymmetry * 0.5
                brow.position.y = rig.proportions.browRise + inner * 0.006
                brow.orientation = simd_quatf(
                    angle: side * (parameters.browOuter - inner) * 0.6,
                    axis: SIMD3(0, 0, 1)
                )
            }
        }
        if let beak = rig.entity(.beak) {
            beak.orientation = simd_quatf(angle: .pi / 2 + parameters.beakOpen, axis: SIMD3(1, 0, 0))
        }
        if let crest = rig.entity(.crest) {
            crest.orientation = simd_quatf(angle: -parameters.crestLean * 0.5, axis: SIMD3(1, 0, 0))
            crest.scale = SIMD3(1 + parameters.crestSpread * 0.4, 1, 1)
        }
        for (joint, side) in [(BirdRig.Joint.wingL, Float(-1)), (.wingR, 1)] {
            guard let wing = rig.entity(joint) else { continue }
            wing.orientation = simd_quatf(
                angle: side * hop.wingExtension * 0.9,
                axis: SIMD3(0, 0, 1)
            )
        }
        if let tail = rig.entity(.tail) {
            tail.orientation = simd_quatf(angle: 0.32 + hop.tailPitch, axis: SIMD3(1, 0, 0))
        }
    }

    private func headOrigin() -> SIMD3<Float> {
        SIMD3(
            position.x,
            position.y + rig.proportions.headCenterY * rig.proportions.normalizationScale,
            position.z
        )
    }
}
#endif
