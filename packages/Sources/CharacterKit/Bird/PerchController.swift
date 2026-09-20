import Foundation
import SceneUnderstanding
import simd

/// Flight to an offered palm, and staying on it (spec 06 §Locomotion, hand perch).
///
/// `HopController` is deliberately ground-only: every horizontal move is gated on a foot
/// being off the floor, which is what makes foot-sliding structurally impossible. A hand is
/// not the floor and can be two metres away and moving, so this is a second controller
/// rather than a flight mode bolted onto the first — the hop invariant survives intact and
/// the handover between them is one explicit switch instead of a flag inside every branch.
///
/// Pure Swift: it computes a pose per frame and the rig consumes it.
public struct PerchController: Sendable {
    // MARK: Constants

    /// Cruise speed of the flight arc, m/s.
    public static let flightSpeed: Float = 1.3
    public static let minimumFlightDuration: Float = 0.45
    public static let maximumFlightDuration: Float = 1.6
    /// Height of the arc above the straight line, as a fraction of the distance, capped.
    public static let arcRatio: Float = 0.22
    public static let maximumArc: Float = 0.35
    /// Wing beats per second while airborne.
    public static let flapRate: Float = 7.0
    /// Time constant for tracking a moving hand once perched. Small enough to look attached,
    /// large enough that tracking noise does not buzz.
    public static let perchFollow: Float = 0.06
    /// Beyond this the palm is out of reach and the offer is ignored.
    public static let maximumReach: Float = 3.0

    public enum Phase: Equatable, Sendable {
        case grounded
        /// Crouch before takeoff.
        case launching
        /// In the air, heading for the palm.
        case flying
        /// Standing on the hand, following it.
        case perched
        /// Flying back down to the floor pose it left.
        case returning
    }

    public enum Event: Equatable, Sendable {
        case tookOff
        case landedOnHand
        case leftHand
        case landedOnFloor
        case offerRejected
    }

    public static let launchDuration: Float = 0.14

    // MARK: State

    public private(set) var phase: Phase = .grounded
    public private(set) var position: SIMD3<Float> = .zero
    public private(set) var yaw: Float = 0
    public private(set) var wingExtension: Float = 0
    public private(set) var bodyDip: Float = 0
    public private(set) var tailPitch: Float = 0
    /// Roll into the turn, radians. Read by the rig for a bank.
    public private(set) var bank: Float = 0

    private var from: SIMD3<Float> = .zero
    private var to: SIMD3<Float> = .zero
    private var fromYaw: Float = 0
    private var toYaw: Float = 0
    private var arc: Float = 0
    private var duration: Float = 0
    private var elapsed: Float = 0
    /// Where it stood before the offer, so leaving the hand is a return and not a new search.
    private var floorAnchor: (position: SIMD3<Float>, yaw: Float)?

    public init() {}

    /// True while the hand, not the navmesh, owns the character's transform.
    public var isEngaged: Bool { phase != .grounded }
    public var isPerched: Bool { phase == .perched }

    // MARK: Entry points

    public func canAccept(_ palm: PalmPose, from current: SIMD3<Float>) -> Bool {
        simd_distance(palm.landing, current) <= Self.maximumReach
    }

    /// Begin flying to `palm` from the current ground pose. Returns the event, if any.
    public mutating func offer(
        _ palm: PalmPose,
        currentPosition: SIMD3<Float>,
        currentYaw: Float
    ) -> Event? {
        guard phase == .grounded else { return nil }
        guard canAccept(palm, from: currentPosition) else { return .offerRejected }
        floorAnchor = (currentPosition, currentYaw)
        position = currentPosition
        yaw = currentYaw
        begin(from: currentPosition, fromYaw: currentYaw, to: palm.landing, toYaw: palm.yaw)
        phase = .launching
        elapsed = 0
        return .tookOff
    }

    /// The palm moved: retarget without restarting the flight.
    public mutating func retarget(_ palm: PalmPose) {
        switch phase {
        case .launching, .flying:
            to = palm.landing
            toYaw = palm.yaw
        case .perched:
            to = palm.landing
            toYaw = palm.yaw
        case .grounded, .returning:
            break
        }
    }

    /// The offer was withdrawn. Fly back to the floor pose it left.
    public mutating func release() {
        switch phase {
        case .grounded, .returning:
            return
        case .launching, .flying, .perched:
            let home = floorAnchor ?? (position, yaw)
            begin(from: position, fromYaw: yaw, to: home.position, toYaw: home.yaw)
            phase = .returning
            elapsed = 0
        }
    }

    /// Hard reset used when the character is re-placed by the scene.
    public mutating func cancel(at position: SIMD3<Float>, yaw: Float) {
        self = PerchController()
        self.position = position
        self.yaw = yaw
    }

    // MARK: Per-frame

    public mutating func update(deltaTime: Float) -> [Event] {
        var events: [Event] = []
        elapsed += deltaTime

        switch phase {
        case .grounded:
            wingExtension = 0
            bodyDip = 0
            bank = 0

        case .launching:
            // A crouch, wings half out, before the body ever leaves the hand's line.
            let t = min(1, elapsed / Self.launchDuration)
            bodyDip = -0.012 * sin(t * .pi)
            wingExtension = 0.5 * t
            if t >= 1 {
                phase = .flying
                elapsed = 0
            }

        case .flying, .returning:
            let t = min(1, duration <= 0 ? 1 : elapsed / duration)
            let eased = Self.easeInOut(t)
            position = simd_mix(from, to, SIMD3(repeating: eased))
            position.y += arc * 4 * eased * (1 - eased)
            yaw = fromYaw + Self.shortestAngle(from: fromYaw, to: toYaw) * eased
            // Wings beat, and the beat fades out on approach so it settles rather than
            // stopping mid-flap.
            let flap = 0.5 + 0.5 * sin(elapsed * Self.flapRate * 2 * .pi)
            wingExtension = (0.45 + 0.55 * flap) * (1 - eased * eased)
            tailPitch = -0.18 * (1 - eased)
            bank = Self.shortestAngle(from: fromYaw, to: toYaw) * 0.25 * sin(eased * .pi)
            bodyDip = 0
            if t >= 1 {
                if phase == .flying {
                    phase = .perched
                    events.append(.landedOnHand)
                } else {
                    phase = .grounded
                    floorAnchor = nil
                    events.append(.landedOnFloor)
                }
                wingExtension = 0
                bank = 0
                tailPitch = 0
                elapsed = 0
            }

        case .perched:
            // Critically-damped follow, so the bird rides a moving hand without buzzing on
            // tracking noise. Exponential rather than a spring: a spring overshoots, and
            // overshoot here means the bird visibly leaves the palm.
            let alpha = 1 - exp(-deltaTime / max(Self.perchFollow, 1e-4))
            position += (to - position) * alpha
            yaw += Self.shortestAngle(from: yaw, to: toYaw) * alpha
            // A small grip adjustment keeps it alive rather than frozen to the transform.
            wingExtension = max(0, wingExtension - deltaTime * 2)
            bodyDip = 0
            bank = 0
        }
        return events
    }

    // MARK: Helpers

    private mutating func begin(
        from start: SIMD3<Float>,
        fromYaw startYaw: Float,
        to end: SIMD3<Float>,
        toYaw endYaw: Float
    ) {
        from = start
        to = end
        self.fromYaw = startYaw
        self.toYaw = endYaw
        let distance = simd_distance(start, end)
        duration = min(
            Self.maximumFlightDuration,
            max(Self.minimumFlightDuration, distance / Self.flightSpeed)
        )
        arc = min(Self.maximumArc, distance * Self.arcRatio)
    }

    static func easeInOut(_ t: Float) -> Float {
        let c = min(max(t, 0), 1)
        return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
    }

    /// Signed shortest rotation, so a flight never takes the long way round.
    static func shortestAngle(from: Float, to: Float) -> Float {
        var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
