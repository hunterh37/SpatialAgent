import Foundation

/// The weighted idle pool: what the bird does when nothing is happening.
///
/// Spec 06 §Idle: never static. A 4–9s timer picks from eight behaviors, with weights that
/// shift with mood and with how long the user has been quiet. The no-immediate-repeat rule is
/// enforced by construction rather than hoped for, because a creature that preens twice in a
/// row reads as a loop rather than a mind.
public struct IdlePool: Sendable {
    /// The eight behaviors of spec 06.
    public enum Behavior: String, CaseIterable, Sendable {
        case lookAround
        case preenWing
        case headTilt
        case shuffleTurn
        case smallHop
        case stretchWings
        case scratch
        case settle

        /// How long the behavior occupies the bird. The timer for the next one starts after.
        public var duration: Float {
            switch self {
            case .lookAround: return 1.6
            case .preenWing: return 2.2
            case .headTilt: return 0.9
            case .shuffleTurn: return 1.2
            case .smallHop: return 0.5
            case .stretchWings: return 1.8
            case .scratch: return 1.9
            case .settle: return 2.6
            }
        }

        /// Energetic behaviors get rarer as mood drops; quiet ones get commoner as the user
        /// stays silent. Every behavior is one or the other or neither, and the classification
        /// is what the weight shifts key off.
        public var isEnergetic: Bool {
            switch self {
            case .smallHop, .stretchWings, .shuffleTurn: return true
            default: return false
            }
        }

        /// Self-directed behaviors: what the bird does when it has stopped expecting the user.
        public var isSelfDirected: Bool {
            switch self {
            case .preenWing, .scratch, .settle: return true
            default: return false
            }
        }
    }

    /// Spec 06: a 4–9s timer.
    public static let intervalRange: ClosedRange<Float> = 4.0...9.0

    /// -1 low, 0 neutral, +1 high. Set from `Mood` in phase D; until then it is neutral.
    public var mood: Float = 0
    /// Seconds since the user last said anything.
    public var userSilence: Float = 0

    public private(set) var current: Behavior?
    public private(set) var last: Behavior?

    private var random: SystemRandom
    private var untilNext: Float
    private var remainingInCurrent: Float = 0

    public init(seed: UInt64 = 0xB19D) {
        random = SystemRandom(seed: seed)
        untilNext = 0
        untilNext = random.float(in: Self.intervalRange)
    }

    // MARK: Weights

    /// Base weights before any shift. `lookAround` is the commonest because a bird that never
    /// looks at anything reads as asleep.
    public static func baseWeight(_ behavior: Behavior) -> Float {
        switch behavior {
        case .lookAround: return 3.0
        case .preenWing: return 1.6
        case .headTilt: return 2.0
        case .shuffleTurn: return 1.2
        case .smallHop: return 1.0
        case .stretchWings: return 0.9
        case .scratch: return 0.8
        case .settle: return 1.0
        }
    }

    /// Weight of one behavior under the current mood and silence.
    ///
    /// Two independent shifts, both monotonic and both bounded below so no behavior ever
    /// becomes unreachable — an idle pool with an unreachable member is a pool with seven
    /// behaviors and a bug.
    public func weight(for behavior: Behavior) -> Float {
        var weight = Self.baseWeight(behavior)
        let mood = min(1, max(-1, self.mood))
        // Silence saturates at a minute; past that, more silence says nothing new.
        let silence = min(1, max(0, userSilence / 60))

        if behavior.isEnergetic {
            weight *= 1 + mood * 0.6
            weight *= 1 - silence * 0.4
        }
        if behavior.isSelfDirected {
            weight *= 1 + silence * 0.8
            weight *= 1 - mood * 0.2
        }
        if behavior == .lookAround {
            // Looking around is looking *for* someone, and it fades as the room stays empty.
            weight *= 1 - silence * 0.35
        }
        return max(0.05, weight)
    }

    // MARK: Selection

    /// Picks the next behavior. Never the one that just ran.
    public mutating func select() -> Behavior {
        let candidates = Behavior.allCases.filter { $0 != last }
        let total = candidates.reduce(Float(0)) { $0 + weight(for: $1) }
        var roll = random.float() * total
        for candidate in candidates {
            roll -= weight(for: candidate)
            if roll <= 0 {
                last = candidate
                return candidate
            }
        }
        let fallback = candidates.last ?? .lookAround
        last = fallback
        return fallback
    }

    // MARK: Per-frame

    /// Advances the idle timer. Returns a behavior on the frame it starts, nil otherwise.
    public mutating func update(deltaTime: Float) -> Behavior? {
        guard deltaTime > 0 else { return nil }
        if remainingInCurrent > 0 {
            remainingInCurrent -= deltaTime
            if remainingInCurrent <= 0 {
                remainingInCurrent = 0
                current = nil
            }
            return nil
        }
        untilNext -= deltaTime
        guard untilNext <= 0 else { return nil }
        let behavior = select()
        current = behavior
        remainingInCurrent = behavior.duration
        untilNext = random.float(in: Self.intervalRange)
        return behavior
    }

    /// Cuts idle short — the user said something, or a directive arrived.
    public mutating func interrupt() {
        current = nil
        remainingInCurrent = 0
        untilNext = random.float(in: Self.intervalRange)
    }

    /// True while a behavior is playing.
    public var isBusy: Bool { remainingInCurrent > 0 }
}
