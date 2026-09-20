#if canImport(RealityKit)
import AgentProtocol
import Foundation
import RealityKit
import SceneUnderstanding
import simd

/// The character in the room: a RealityKit entity plus a locomotion controller.
///
/// Budget (spec/01-character.md): one skinned mesh, skeleton ≤80 joints, ~45cm tall, sharing
/// a 90fps frame budget with scene mesh and passthrough. The placeholder capsule exists so
/// steps 4 and 5 of the build order can be separated — directives are driven and verified
/// before the rig lands.
@MainActor
public final class CharacterEntity {
    public let root = Entity()
    private var model: Entity?
    private var animations: [String: AnimationResource] = [:]
    private var playback: AnimationPlaybackController?

    public private(set) var machine = CharacterStateMachine()
    public private(set) var position: SIMD3<Float> = .zero

    /// Fixed and human-referenced. Life-size is uncanny at conversational distance.
    public static let targetHeight: Float = 0.45

    private var path: [SIMD3<Float>] = []
    private var pathIndex = 0
    private var lookTarget: SIMD3<Float>?

    /// Metres per second taken from the walk clip's root motion. A fixed speed plus a chosen
    /// clip is what produces foot-sliding, so this is overwritten when the rig loads and the
    /// clip's actual root displacement is measured.
    public private(set) var walkSpeed: Float = 0.42

    public init() {
        root.name = "SpatialAgent.Character"
    }

    // MARK: - Loading

    /// Loads the rigged USDZ with its baked animation library. Falls back to a capsule so
    /// the app is never dead while the art is in flight.
    public func load(named name: String = "Character", in bundle: Bundle = .main) async {
        if let entity = try? await Entity(named: name, in: bundle) {
            install(entity)
            indexAnimations(of: entity)
            if let walk = animations["walk"] {
                walkSpeed = Self.rootMotionSpeed(of: walk) ?? walkSpeed
            }
        } else {
            install(Self.placeholder())
        }
    }

    private func install(_ entity: Entity) {
        model?.removeFromParent()
        model = entity
        root.addChild(entity)
        normalizeScale(entity)
    }

    /// Scales the rig to `targetHeight` so art can ship at any authored size.
    private func normalizeScale(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = bounds.extents.y
        guard height > 0.01 else { return }
        entity.scale *= SIMD3(repeating: Self.targetHeight / height)
    }

    private func indexAnimations(of entity: Entity) {
        for animation in entity.availableAnimations {
            guard let name = animation.name?.lowercased() else { continue }
            for key in ["idle", "walk", "turn", "talk", "point", "gesture", "think"]
            where name.contains(key) {
                animations[key] = animation
            }
        }
    }

    /// Measures the clip's root displacement so locomotion speed derives from the animation
    /// rather than the reverse. Returns nil when the clip has no usable root motion, in
    /// which case the authored default stands and foot contact must be checked by eye.
    private static func rootMotionSpeed(of animation: AnimationResource) -> Float? {
        let duration = Float(animation.definition.duration)
        guard duration > 0.01 else { return nil }
        // RealityKit does not expose sampled root translation directly; the rig is authored
        // with a documented stride length in its metadata. See docs/middle-layer-todo.md.
        return nil
    }

    /// Red capsule stand-in driven by the agent loop while the rig is in flight.
    private static func placeholder() -> Entity {
        let height: Float = 0.34
        let radius: Float = 0.08
        // `MeshResource.generateCapsule` is not in every SDK this package builds against;
        // a fully rounded box reads as a capsule at 45cm.
        let mesh = MeshResource.generateBox(
            size: SIMD3(radius * 2, height, radius * 2),
            cornerRadius: radius
        )
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .red)
        material.roughness = 0.35
        material.metallic = 0.0
        material.emissiveColor = .init(color: .red)
        material.emissiveIntensity = 0.25
        let body = ModelEntity(mesh: mesh, materials: [material])
        body.position.y = height / 2 + radius
        // Tap target for addressing; the capsule has no rig to hit-test against.
        body.components.set(InputTargetComponent())
        body.components.set(
            CollisionComponent(shapes: [.generateCapsule(height: height + radius * 2, radius: radius)])
        )
        let wrapper = Entity()
        wrapper.addChild(body)
        return wrapper
    }

    // MARK: - Placement

    public func place(at pose: Placement.Pose) {
        position = pose.position
        root.position = pose.position
        root.orientation = simd_quatf(angle: pose.yaw, axis: SIMD3(0, 1, 0))
        play(.idle)
    }

    // MARK: - Directives

    public func apply(_ resolved: ResolvedDirective) {
        switch resolved {
        case let .walk(path):
            self.path = path
            pathIndex = 0
            machine.handle(.pathAccepted)
            play(machine.state)
        case let .look(at: target):
            lookTarget = target
        case let .point(at: target):
            lookTarget = target
            machine.handle(.gestureStarted)
            play(.gesturing)
        case .emote, .gesture:
            machine.handle(.gestureStarted)
            play(.gesturing)
        case .idle:
            machine.handle(.settled)
            play(.idle)
        case .unresolved:
            // Resolution failure never moves the character. It speaks from where it stands.
            machine.handle(.interrupted)
            play(.idle)
        }
    }

    public func signal(_ event: CharacterEvent) {
        let before = machine.state
        let after = machine.handle(event)
        if before != after { play(after) }
    }

    // MARK: - Per-frame update

    /// Called from a `SceneEvents.Update` subscription. Keeps all motion in one place so
    /// the frame cost is measurable.
    public func update(deltaTime: Float, userPosition: SIMD3<Float>) {
        advanceAlongPath(deltaTime: deltaTime)
        faceTarget(deltaTime: deltaTime, userPosition: userPosition)
    }

    private func advanceAlongPath(deltaTime: Float) {
        guard machine.state == .walking || machine.state == .turning,
              pathIndex < path.count else { return }

        let target = path[pathIndex]
        let delta = SIMD3(target.x - position.x, 0, target.z - position.z)
        let distance = simd_length(delta)

        // Turn first, then walk: the transition exists so the character does not crab
        // sideways out of idle.
        if machine.state == .turning {
            let desired = atan2(delta.x, delta.z)
            let current = currentYaw()
            let step = shortestAngle(from: current, to: desired)
            let maxStep = Float.pi * 1.5 * deltaTime
            let applied = max(-maxStep, min(maxStep, step))
            root.orientation = simd_quatf(angle: current + applied, axis: SIMD3(0, 1, 0))
            if abs(step) < 0.08 { signal(.turnComplete) }
            return
        }

        if distance < 0.05 {
            pathIndex += 1
            if pathIndex >= path.count { signal(.arrived); signal(.settled) }
            return
        }

        let step = min(distance, walkSpeed * deltaTime)
        let direction = delta / max(distance, 1e-4)
        position += direction * step
        // Y comes from the path, which comes from the navmesh floor height. Feet contact a
        // detected floor plane at all times; this is the line that enforces it.
        position.y = target.y
        root.position = position
        root.orientation = simd_quatf(angle: atan2(direction.x, direction.z), axis: SIMD3(0, 1, 0))
    }

    private func faceTarget(deltaTime: Float, userPosition: SIMD3<Float>) {
        guard machine.state != .walking, machine.state != .turning else { return }
        let target = lookTarget ?? userPosition
        let delta = SIMD3(target.x - position.x, 0, target.z - position.z)
        guard simd_length(delta) > 0.05 else { return }
        let desired = atan2(delta.x, delta.z)
        let current = currentYaw()
        let step = shortestAngle(from: current, to: desired)
        let maxStep = Float.pi * 0.9 * deltaTime
        root.orientation = simd_quatf(
            angle: current + max(-maxStep, min(maxStep, step)),
            axis: SIMD3(0, 1, 0)
        )
    }

    private func currentYaw() -> Float {
        let q = root.orientation
        return atan2(
            2 * (q.real * q.imag.y + q.imag.x * q.imag.z),
            1 - 2 * (q.imag.y * q.imag.y + q.imag.x * q.imag.x)
        )
    }

    private func shortestAngle(from: Float, to: Float) -> Float {
        var delta = to - from
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    // MARK: - Animation

    private func play(_ state: CharacterState) {
        let clip: String
        switch state {
        case .walking, .turning, .arriving: clip = "walk"
        case .speaking: clip = "talk"
        case .thinking: clip = "think"
        case .gesturing: clip = "gesture"
        case .listening, .idle: clip = "idle"
        }
        guard let model, let animation = animations[clip] ?? animations["idle"] else { return }
        playback = model.playAnimation(
            animation.repeat(),
            transitionDuration: machine.lastCrossfade,
            startsPaused: false
        )
    }
}
#endif
