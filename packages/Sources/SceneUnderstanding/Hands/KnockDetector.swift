import Foundation
import simd

/// A hand swatting the bird off a perch.
///
/// The counterpart to `PalmDetector`: an open palm held still is an invitation, and a hand
/// moving fast through the bird is the opposite. Both are decided from geometry alone, so
/// the thresholds that separate "reached past him" from "knocked him off" are unit tests
/// rather than something tuned by waving at a headset.
///
/// Two hands are tracked independently because a swipe is one-handed and the other hand is
/// usually resting: averaging them would hide the gesture entirely.
public struct KnockDetector: Sendable {
    /// Hand speed, m/s, below which a pass is a reach and not a swat. A deliberate swipe
    /// runs 1.5–3 m/s; reaching for a cup is well under 0.6.
    public static let minimumSpeed: Float = 0.9
    /// How close the hand has to come to the bird's body, metres. Generous: the bird is
    /// 22cm tall and the tracked point is the palm, not the fingertips that actually hit.
    public static let strikeRadius: Float = 0.22
    /// The swat must be going *across* the bird, not toward or away from the user's eye:
    /// a hand approaching along its own line of travel is a reach. cos(~65°).
    public static let minimumLateralFraction: Float = 0.42
    /// After a knock, ignore everything for this long, so one swipe is one knock and not
    /// six across six frames.
    public static let refractoryPeriod: Float = 1.2

    /// One tracked hand between two frames.
    public struct Sample: Equatable, Sendable {
        public var position: SIMD3<Float>
        public init(position: SIMD3<Float>) { self.position = position }
    }

    public struct Strike: Equatable, Sendable {
        /// How hard, 0–1, from speed. Drives how far the bird tumbles.
        public var force: Float
        /// Unit, horizontal: which way the bird gets knocked.
        public var direction: SIMD3<Float>
        public var speed: Float
    }

    private var previous: [SIMD3<Float>?] = [nil, nil]
    private var cooldown: Float = 0

    public init() {}

    /// True while a fresh knock cannot be registered.
    public var isCoolingDown: Bool { cooldown > 0 }

    public mutating func reset() { self = KnockDetector() }

    /// Feed this frame's hand positions (nil per slot when that hand is untracked) and the
    /// point the bird is standing at. Returns a strike at most once per swipe.
    public mutating func update(
        deltaTime: Float,
        hands: [SIMD3<Float>?],
        target: SIMD3<Float>
    ) -> Strike? {
        cooldown = max(0, cooldown - deltaTime)
        var strike: Strike?
        for index in 0 ..< 2 {
            let current = index < hands.count ? hands[index] : nil
            defer { previous[index] = current }
            guard deltaTime > 1e-4, let current, let last = previous[index] else { continue }
            guard cooldown == 0, strike == nil else { continue }
            if let hit = Self.evaluate(from: last, to: current, deltaTime: deltaTime, target: target) {
                strike = hit
            }
        }
        if strike != nil { cooldown = Self.refractoryPeriod }
        return strike
    }

    /// The geometry, with no state: did a hand travelling `from`→`to` in `deltaTime` swat
    /// something standing at `target`?
    public static func evaluate(
        from last: SIMD3<Float>,
        to current: SIMD3<Float>,
        deltaTime: Float,
        target: SIMD3<Float>
    ) -> Strike? {
        let travel = current - last
        let speed = simd_length(travel) / max(deltaTime, 1e-4)
        guard speed >= minimumSpeed else { return nil }
        guard simd_length(travel) > 1e-5 else { return nil }
        let heading = simd_normalize(travel)

        // Closest approach of the segment to the bird, so a fast hand that passed *through*
        // him between two frames still counts. Sampling positions alone would miss it at
        // 3 m/s, which is exactly the speed that should register.
        let toTarget = target - last
        let t = min(max(simd_dot(toTarget, travel) / simd_length_squared(travel), 0), 1)
        let closest = last + travel * t
        guard simd_distance(closest, target) <= strikeRadius else { return nil }

        // Sideways, not downward: the swipe has to travel across the room. A hand dropping
        // vertically onto the perch is someone putting a mug down, and that must not cost a
        // perch. The horizontal fraction of a unit heading is exactly that test.
        let planarHeading = SIMD3(heading.x, 0, heading.z)
        guard simd_length(planarHeading) >= minimumLateralFraction else { return nil }

        let direction = simd_normalize(planarHeading)
        let force = min(1, (speed - minimumSpeed) / 2.0 + 0.35)
        return Strike(force: force, direction: direction, speed: speed)
    }
}
