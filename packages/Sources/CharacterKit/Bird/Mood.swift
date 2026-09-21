import Foundation

/// How attached the bird is, and what that changes.
///
/// Spec 07 §Learned behavior: affinity accumulates from teaching, successful actions and time
/// in-session; ignored questions and cancelled actions lower it slightly. It biases idle
/// weights, proximity and the expression baseline.
///
/// It is never shown as a number and there is no way to grind it. Both of those are
/// structural here rather than a UI convention: the stored value is not public, the only
/// readouts are a coarse `Warmth` and the three biases, and every positive input saturates
/// within a session so repeating it stops paying. A visible number turns a creature into a
/// progress bar, and a grindable one turns attention into a chore.
public struct Mood: Sendable {
    /// -1 to 1. Deliberately not public: see the type comment.
    internal private(set) var affinity: Float = 0
    /// Per-session credit already taken, per input kind, so repetition saturates.
    private var credited: [Input: Float] = [:]
    private var sessionSeconds: Float = 0

    public init() {}

    /// Everything that moves the needle. A closed set, because "what makes it like you" is a
    /// design decision rather than something any call site should be able to invent.
    public enum Input: String, Sendable, Hashable, CaseIterable {
        case taught
        case actionSucceeded
        case questionAnswered
        case questionIgnored
        case actionCancelled
        /// Swatted off a perch. Costs more than an ignored question and less than nothing
        /// else does, because it is the only input that is a hand landing on the bird.
        case knockedOff

        /// Signed step per occurrence.
        var step: Float {
            switch self {
            case .taught: return 0.08
            case .actionSucceeded: return 0.03
            case .questionAnswered: return 0.05
            case .questionIgnored: return -0.04
            case .actionCancelled: return -0.02
            case .knockedOff: return -0.06
            }
        }

        /// Most this input can contribute in one session. The anti-grind clause: teaching
        /// the same wall five names in a row is worth about as much as teaching it one.
        var sessionCap: Float {
            switch self {
            case .taught: return 0.25
            case .actionSucceeded: return 0.12
            case .questionAnswered: return 0.15
            // Negative inputs are not capped: ignoring every question should keep costing.
            case .questionIgnored, .actionCancelled, .knockedOff:
                return .greatestFiniteMagnitude
            }
        }
    }

    /// Time in session contributes, slowly, up to a small ceiling.
    public static let timeRate: Float = 0.01 / 60
    /// Below one teaching act, on purpose: presence counts for something, and sitting in the
    /// room must never be the main way the bird comes to like you.
    public static let timeCap: Float = 0.06

    // MARK: Inputs

    public mutating func note(_ input: Input) {
        let taken = credited[input, default: 0]
        var step = input.step
        if step > 0 {
            let remaining = max(0, input.sessionCap - taken)
            step = min(step, remaining)
        }
        credited[input] = taken + abs(step)
        affinity = min(1, max(-1, affinity + step))
    }

    /// Advances the in-session clock. Time is the weakest input by design: presence should
    /// count for something, and it should not be the main thing that counts.
    public mutating func advance(seconds: Float) {
        guard seconds > 0 else { return }
        let earned = min(Self.timeCap - min(Self.timeCap, sessionSeconds * Self.timeRate),
                         seconds * Self.timeRate)
        sessionSeconds += seconds
        guard earned > 0 else { return }
        affinity = min(1, max(-1, affinity + earned))
    }

    /// A new session clears the per-session saturation but keeps the affinity itself.
    public mutating func beginSession() {
        credited = [:]
        sessionSeconds = 0
    }

    // MARK: Readouts — coarse, never numeric

    /// The only thing anything outside this type is allowed to know about how it feels.
    public enum Warmth: String, Sendable, CaseIterable, Comparable {
        case wary
        case neutral
        case friendly
        case attached

        private var rank: Int {
            switch self {
            case .wary: return 0
            case .neutral: return 1
            case .friendly: return 2
            case .attached: return 3
            }
        }

        public static func < (lhs: Warmth, rhs: Warmth) -> Bool { lhs.rank < rhs.rank }
    }

    public var warmth: Warmth {
        switch affinity {
        case ..<(-0.15): return .wary
        case ..<0.2: return .neutral
        case ..<0.6: return .friendly
        default: return .attached
        }
    }

    // MARK: Biases

    /// Fed to `IdlePool.mood`: -1 to 1, energetic behaviors rise with attachment.
    public var idleBias: Float { affinity }

    /// How close the bird prefers to stand, in metres. Attachment closes the gap; wariness
    /// opens it. Bounded so it can never crowd the user or leave the room.
    public var preferredDistance: Float {
        let base: Float = 1.6
        return min(2.2, max(1.0, base - affinity * 0.6))
    }

    /// The face it wears when nothing else is happening.
    public var baselineExpression: Expression {
        switch warmth {
        case .wary: return .alert
        case .neutral: return .neutral
        case .friendly, .attached: return .happy
        }
    }

    /// Breathing depth multiplier: a wary bird holds itself still and shallow.
    public var breathDepth: Float { min(1.0, max(0.7, 0.9 + affinity * 0.1)) }
}
