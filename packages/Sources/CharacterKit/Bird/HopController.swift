import Foundation
import simd

/// Ballistic hop locomotion along a navmesh path.
///
/// Spec 06 §Locomotion: one hop is 0.34s, 4cm peak, 9cm forward. Foot contact happens at the
/// start and the end of the arc and nowhere in between, which is the whole trick — the root
/// only translates while airborne, so foot-sliding is not a bug that has to be tuned out, it
/// is structurally impossible. Every horizontal movement in this type is gated on `airborne`.
///
/// Pure Swift by design: the controller computes poses and the rig consumes them. That is what
/// lets the foot-sliding property be a unit test rather than a thing checked by eye.
public struct HopController: Sendable {
    // MARK: Spec constants

    public static let hopDuration: Float = 0.34
    public static let hopPeak: Float = 0.04
    public static let hopDistance: Float = 0.09
    /// Anticipation squashes the opposite way for 80ms before takeoff.
    public static let anticipationDuration: Float = 0.08
    /// A beat on the ground between hops; hop cadence is where speed comes from.
    public static let groundedDuration: Float = 0.06

    /// Above this much remaining path, a hop becomes a glide. Below it, a glide looks twitchy.
    public static let glideThreshold: Float = 1.5
    public static let glideDuration: Float = 0.62
    public static let glidePeak: Float = 0.07
    /// A shallow arc 2–3 hops long.
    public static let glideDistance: Float = 0.24

    /// Where a hop is in its cycle. Only `.airborne` moves the bird.
    public enum Phase: Equatable, Sendable {
        case idle
        case grounded
        case anticipating
        case airborne
        case gliding
    }

    /// Emitted for the animator to react to; the controller never touches the rig itself.
    public enum Event: Equatable, Sendable {
        case takeoffAnticipated
        case landed
        case pathCompleted
        case pathRejected
    }

    // MARK: State

    public private(set) var phase: Phase = .idle
    public private(set) var position: SIMD3<Float> = .zero
    public private(set) var yaw: Float = 0

    /// Height above the standing pose, applied to `Bob`. Zero whenever a foot is down —
    /// `Bob` carries the feet, so any non-zero value here while grounded is a foot through
    /// the floor.
    public private(set) var bobHeight: Float = 0
    /// The pre-takeoff crouch, applied to `Body` alone. It cannot go on `Bob`: the feet stay
    /// planted through the crouch, and only the body drops.
    public private(set) var bodyDip: Float = 0
    /// 0 at rest, 1 fully out. Wings give a small out-and-back on takeoff.
    public private(set) var wingExtension: Float = 0
    /// The tail counter-rotates against the head and the arc.
    public private(set) var tailPitch: Float = 0

    private var path: [SIMD3<Float>] = []
    private var pathIndex = 0
    private var phaseElapsed: Float = 0
    private var hopStart: SIMD3<Float> = .zero
    private var hopEnd: SIMD3<Float> = .zero
    private var hopArcPeak: Float = HopController.hopPeak
    private var hopArcDuration: Float = HopController.hopDuration

    public init() {}

    // MARK: Contact

    /// True whenever at least one foot is on the floor. The feet may only move when this is
    /// false; that invariant is the test.
    public var isGrounded: Bool {
        switch phase {
        case .airborne, .gliding: return false
        case .idle, .grounded, .anticipating: return true
        }
    }

    public var isMoving: Bool { phase != .idle }

    /// Path still to cover, in metres.
    public var remainingDistance: Float {
        guard pathIndex < path.count else { return 0 }
        var total = horizontalDistance(from: position, to: path[pathIndex])
        var index = pathIndex
        while index + 1 < path.count {
            total += horizontalDistance(from: path[index], to: path[index + 1])
            index += 1
        }
        return total
    }

    // MARK: Path

    /// Takes a navmesh path. An empty or already-reached path is rejected rather than
    /// half-followed: spec 06 says an unreachable `walkTo` fails to idle, it never partially
    /// hops toward a wall.
    @discardableResult
    public mutating func follow(path: [SIMD3<Float>]) -> Event? {
        let usable = path.filter { horizontalDistance(from: position, to: $0) > 0.005 }
        guard !usable.isEmpty else {
            stop()
            return .pathRejected
        }
        self.path = usable
        pathIndex = 0
        phase = .grounded
        phaseElapsed = 0
        return nil
    }

    public mutating func stop() {
        path = []
        pathIndex = 0
        phase = .idle
        phaseElapsed = 0
        bobHeight = 0
        bodyDip = 0
        wingExtension = 0
        tailPitch = 0
    }

    public mutating func place(at position: SIMD3<Float>, yaw: Float = 0) {
        stop()
        self.position = position
        self.yaw = yaw
    }

    // MARK: Per-frame

    /// Advances locomotion. Returns the events this frame produced, in order.
    public mutating func update(deltaTime: Float) -> [Event] {
        guard deltaTime > 0, phase != .idle else { return [] }
        var events: [Event] = []
        var remaining = deltaTime

        // Sub-stepped by phase boundary so a long frame cannot skip a landing — a missed
        // landing is a missed squash and a foot that moved while grounded.
        while remaining > 0, phase != .idle {
            let duration = currentPhaseDuration()
            let step = min(remaining, max(0, duration - phaseElapsed))
            phaseElapsed += step
            remaining -= step
            applyPhasePose()
            if phaseElapsed >= duration - 1e-6 {
                events.append(contentsOf: advancePhase())
            } else {
                break
            }
        }
        return events
    }

    private func currentPhaseDuration() -> Float {
        switch phase {
        case .idle: return .greatestFiniteMagnitude
        case .grounded: return Self.groundedDuration
        case .anticipating: return Self.anticipationDuration
        case .airborne, .gliding: return hopArcDuration
        }
    }

    private mutating func applyPhasePose() {
        switch phase {
        case .idle, .grounded:
            bobHeight = 0
            bodyDip = 0
            wingExtension = max(0, wingExtension - 0.08)
            tailPitch *= 0.85
        case .anticipating:
            // Crouch: the bird dips before it goes, and the dip is vertical only.
            bodyDip = -0.012 * Easing.outQuad(phaseElapsed / Self.anticipationDuration)
            bobHeight = 0
            wingExtension = 0
            tailPitch = 0.10 * Easing.outQuad(phaseElapsed / Self.anticipationDuration)
        case .airborne, .gliding:
            bodyDip = 0
            let t = Easing.clamp(phaseElapsed / hopArcDuration)
            // A parabola, not a sine: the arc has to look thrown, and it has to be exactly
            // zero at both ends so the landing frame is a contact frame.
            bobHeight = hopArcPeak * 4 * t * (1 - t)
            position = mix(hopStart, hopEnd, t: t)
            // Out-and-back: a full beat on a hop, three fast ones on a glide.
            let beats: Float = phase == .gliding ? 3 : 1
            wingExtension = max(0, sin(t * .pi * beats))
            // Counter-rotation against the arc: tail down as the body rises.
            tailPitch = -0.28 * sin(t * .pi)
        }
    }

    private mutating func advancePhase() -> [Event] {
        phaseElapsed = 0
        switch phase {
        case .idle:
            return []
        case .grounded:
            guard pathIndex < path.count else {
                stop()
                return [.pathCompleted]
            }
            phase = .anticipating
            // Turn happens on the ground, between hops. Turning mid-air would drag the feet.
            yaw = headingToWaypoint()
            return [.takeoffAnticipated]
        case .anticipating:
            beginHop()
            return []
        case .airborne, .gliding:
            position = hopEnd
            bobHeight = 0
            bodyDip = 0
            wingExtension = 0
            tailPitch = 0
            advanceWaypointIfReached()
            if pathIndex >= path.count {
                phase = .idle
                path = []
                return [.landed, .pathCompleted]
            }
            phase = .grounded
            return [.landed]
        }
    }

    private mutating func beginHop() {
        let target = path[pathIndex]
        let delta = SIMD3(target.x - position.x, 0, target.z - position.z)
        let distance = simd_length(delta)
        let direction = distance > 1e-5 ? delta / distance : SIMD3<Float>(0, 0, 1)

        // Glide only above the threshold, and never further than the path actually goes.
        let glide = remainingDistance > Self.glideThreshold
        let stride = min(distance, glide ? Self.glideDistance : Self.hopDistance)
        phase = glide ? .gliding : .airborne
        hopArcPeak = glide ? Self.glidePeak : Self.hopPeak
        hopArcDuration = glide ? Self.glideDuration : Self.hopDuration

        hopStart = position
        var end = position + direction * stride
        // Y comes from the path, which comes from the navmesh floor height: the feet land on
        // a detected floor, never on an interpolated guess.
        end.y = target.y
        hopEnd = end
    }

    private mutating func advanceWaypointIfReached() {
        while pathIndex < path.count,
              horizontalDistance(from: position, to: path[pathIndex]) < 0.02 {
            pathIndex += 1
        }
    }

    private func headingToWaypoint() -> Float {
        guard pathIndex < path.count else { return yaw }
        let target = path[pathIndex]
        let delta = SIMD3(target.x - position.x, 0, target.z - position.z)
        guard simd_length(delta) > 1e-5 else { return yaw }
        return atan2(delta.x, delta.z)
    }

    // MARK: Foot contact

    /// World position of one foot, given the rig's proportions.
    ///
    /// Feet hang off `Bob` and inherit root position, yaw and the vertical arc — and nothing
    /// else. No squash, no per-foot step offset while grounded, which is exactly why the
    /// horizontal component cannot change on a grounded frame.
    public func footPosition(
        left: Bool,
        proportions: BirdProportions = BirdProportions()
    ) -> SIMD3<Float> {
        let scale = proportions.normalizationScale
        let offsetX = (left ? -1 : 1) * proportions.footSeparation / 2 * scale
        let offsetZ = proportions.footLength * 0.18 * scale
        let rotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let local = rotation.act(SIMD3(offsetX, 0, offsetZ))
        return SIMD3(
            position.x + local.x,
            position.y + bobHeight + proportions.footHeight / 2 * scale,
            position.z + local.z
        )
    }

    // MARK: Helpers

    private func horizontalDistance(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
        simd_length(SIMD3(b.x - a.x, 0, b.z - a.z))
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
