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
    /// How far a knocked bird is thrown, metres per unit of strike force.
    public static let knockDistance: Float = 0.55
    /// Tumble spin over the fall, radians per unit of force.
    public static let knockSpin: Float = 3.2
    /// The fall is faster than a flight and does not arc upward.
    public static let fallDuration: Float = 0.62

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
        /// Knocked off a perch: falling, not flying. No control, and a tumble.
        case falling
    }

    /// What the flight is heading for. A hand moves and is followed; a perch does not and
    /// must not be — a static target chasing tracking noise reads as the bird sliding along
    /// the crossbar.
    public enum Target: Equatable, Sendable {
        case hand
        /// A perch object, with the map record's id so a knock can be written to it.
        case perch(id: UUID?)

        public var isHand: Bool { self == .hand }
    }

    public enum Event: Equatable, Sendable {
        case tookOff
        case landedOnHand
        /// Landed on a perch object.
        case landedOnPerch(id: UUID?)
        case leftHand
        case landedOnFloor
        case offerRejected
        /// Swatted off a perch. Carries the record that just lost the bird's trust.
        case knockedOff(id: UUID?)
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
    /// What the current flight is for. Read on landing and on a knock.
    public private(set) var target: Target = .hand
    /// Tumble roll while falling, radians. Added to `bank` by the rig.
    public private(set) var tumble: Float = 0
    private var tumbleRate: Float = 0

    public init() {}

    /// True while this controller, not the navmesh, owns the character's transform.
    public var isEngaged: Bool { phase != .grounded }
    /// Standing on an offered hand.
    public var isPerched: Bool { phase == .perched && target.isHand }
    /// Standing on a perch object, which is the state a knock can interrupt.
    public var isPerchedOnObject: Bool {
        if case .perch = target { return phase == .perched }
        return false
    }
    /// The map record the bird is standing on, if any.
    public var perchedPlaceId: UUID? {
        guard case let .perch(id) = target, phase == .perched else { return nil }
        return id
    }

    // MARK: Entry points

    public func canAccept(_ palm: PalmPose, from current: SIMD3<Float>) -> Bool {
        simd_distance(palm.landing, current) <= Self.maximumReach
    }

    /// Begin flying to `palm`. Returns the event, if any.
    ///
    /// A hand outranks a pole. An offer is therefore accepted from the ground *or* out of
    /// any perch-object flight or stand: furniture is what the bird does when nobody is
    /// asking, and an invitation that the bird ignores because he happens to be on a
    /// crossbar reads as the hand perch being broken. The one uninterruptible phase is
    /// `.falling` — a bird being swatted through the air is not choosing anything.
    public mutating func offer(
        _ palm: PalmPose,
        currentPosition: SIMD3<Float>,
        currentYaw: Float
    ) -> Event? {
        let preempting = !target.isHand && phase != .falling
        guard phase == .grounded || preempting else { return nil }
        guard canAccept(palm, from: currentPosition) else { return .offerRejected }
        // Preempting starts the flight from where the bird actually is — possibly 1m up on
        // a crossbar — so he flies across rather than snapping to the floor first, and it
        // keeps the perch's floor return, so letting go afterwards ends on the floor and
        // not back on the pole he was just taken off.
        let start = preempting ? position : currentPosition
        let startYaw = preempting ? yaw : currentYaw
        let home = preempting ? (floorAnchor ?? (start, startYaw)) : (currentPosition, currentYaw)
        target = .hand
        floorAnchor = home
        position = start
        yaw = startYaw
        begin(from: start, fromYaw: startYaw, to: palm.landing, toYaw: palm.yaw)
        phase = .launching
        elapsed = 0
        return .tookOff
    }

    /// The palm moved: retarget without restarting the flight. Ignored while the flight is
    /// bound for a perch, which does not move.
    public mutating func retarget(_ palm: PalmPose) {
        guard target.isHand else { return }
        switch phase {
        case .launching, .flying:
            to = palm.landing
            toYaw = palm.yaw
        case .perched:
            to = palm.landing
            toYaw = palm.yaw
        case .grounded, .returning, .falling:
            break
        }
    }

    /// The offer was withdrawn. Fly back to the floor pose it left.
    ///
    /// Only a hand can be withdrawn. A perch is furniture: it is still there when the user
    /// puts their hands down, and the frame loop calls this every frame that no palm is
    /// offered, so without this guard the bird would fall off the perch instantly.
    public mutating func release() {
        guard target.isHand else { return }
        switch phase {
        case .grounded, .returning, .falling:
            return
        case .launching, .flying, .perched:
            let home = floorAnchor ?? (position, yaw)
            begin(from: position, fromYaw: yaw, to: home.position, toYaw: home.yaw)
            phase = .returning
            elapsed = 0
        }
    }

    /// Fly to a fixed point and stand on it: a perch on a pole, 1m off the floor.
    ///
    /// Separate from `offer` because a perch is not an invitation — reach does not apply
    /// (the bird crosses the room for it), the target does not move, and leaving it is a
    /// knock rather than a withdrawal. The flight itself is the same arc, so the motion the
    /// audience already recognises from the hand perch is exactly what they see here.
    @discardableResult
    public mutating func flyTo(
        perch landing: SIMD3<Float>,
        yaw landingYaw: Float,
        placeId: UUID?,
        currentPosition: SIMD3<Float>,
        currentYaw: Float,
        floorReturn: SIMD3<Float>? = nil
    ) -> Event? {
        guard phase == .grounded else { return nil }
        target = .perch(id: placeId)
        // Where he goes back to when knocked off: the floor under the perch, not where he
        // took off from. Being swatted lands you where you fell.
        floorAnchor = (floorReturn ?? SIMD3(landing.x, currentPosition.y, landing.z), landingYaw)
        position = currentPosition
        yaw = currentYaw
        begin(from: currentPosition, fromYaw: currentYaw, to: landing, toYaw: landingYaw)
        phase = .launching
        elapsed = 0
        return .tookOff
    }

    /// Swatted. Returns the event carrying the perch that just lost the bird, or nil when
    /// he was not on a perch to begin with — a hand passing through empty air is nothing.
    @discardableResult
    public mutating func knockOff(
        force: Float = 0.6,
        direction: SIMD3<Float> = SIMD3(0, 0, 1)
    ) -> Event? {
        guard case let .perch(id) = target, phase == .perched || phase == .flying else {
            return nil
        }
        let strength = min(max(force, 0.2), 1)
        let planar = SIMD3(direction.x, 0, direction.z)
        let heading = simd_length(planar) < 1e-4
            ? SIMD3<Float>(0, 0, 1)
            : simd_normalize(planar)
        let home = floorAnchor ?? (SIMD3(position.x, 0, position.z), yaw)
        // Thrown along the swipe, then down to the floor height he came from. The landing
        // point is not clamped to the navmesh here; the entity re-places onto it on arrival.
        let landing = SIMD3(
            home.position.x + heading.x * Self.knockDistance * strength,
            home.position.y,
            home.position.z + heading.z * Self.knockDistance * strength
        )
        begin(from: position, fromYaw: yaw, to: landing, toYaw: yaw)
        duration = Self.fallDuration
        // No lift: a knocked bird falls. The arc term is reused as a small upward pop at
        // the moment of impact with the hand, which is what sells the hit.
        arc = 0.06 * strength
        tumbleRate = Self.knockSpin * strength / Self.fallDuration
        tumble = 0
        phase = .falling
        elapsed = 0
        return .knockedOff(id: id)
    }

    /// Hard reset used when the character is re-placed by the scene.
    public mutating func cancel(at position: SIMD3<Float>, yaw: Float) {
        self = PerchController()
        target = .hand
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

        case .falling:
            let t = min(1, duration <= 0 ? 1 : elapsed / duration)
            // Linear, not eased: gravity does not ease out. The only easing is the small
            // pop at the start, which is the hand's momentum, not the bird's choice.
            position = simd_mix(from, to, SIMD3(repeating: t))
            position.y += arc * 4 * t * (1 - t)
            tumble += tumbleRate * deltaTime
            // Wings flail late, after the bird has worked out what happened.
            wingExtension = t < 0.35 ? 0.15 : min(1, (t - 0.35) * 3)
            tailPitch = 0.3 * (1 - t)
            bank = 0
            bodyDip = 0
            if t >= 1 {
                phase = .grounded
                target = .hand
                floorAnchor = nil
                tumble = 0
                tumbleRate = 0
                wingExtension = 0
                tailPitch = 0
                events.append(.landedOnFloor)
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
                    switch target {
                    case .hand: events.append(.landedOnHand)
                    case let .perch(id): events.append(.landedOnPerch(id: id))
                    }
                } else {
                    phase = .grounded
                    target = .hand
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
            // A perch object never moves, so `to` is already `position` and this converges
            // to a no-op; the same code therefore serves both without a branch.
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
