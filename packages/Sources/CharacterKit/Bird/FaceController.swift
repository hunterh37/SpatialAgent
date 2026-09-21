import Foundation
import simd

/// Drives the face: expression crossfades, blinking, and the beak.
///
/// Three things that all write to the same parameters and would fight if they lived apart.
/// The order is fixed and it matters: the expression sets the pose, the blink multiplies the
/// eye on top of it, and the beak overrides whatever the expression asked for while speech is
/// actually happening — because a beak that moves without speech is the single most uncanny
/// thing this face can do.
public struct FaceController: Sendable {
    /// Crossfade duration between named expressions. Snapping is prohibited.
    public static let crossfadeDuration: Float = 0.25
    /// Spec 06: close over 90ms, open over 110ms — never symmetric.
    public static let blinkCloseDuration: Float = 0.09
    public static let blinkOpenDuration: Float = 0.11
    public static let blinkedEyeScale: Float = 0.08
    /// Spontaneous blinks every 3–6s with jitter.
    public static let blinkIntervalRange: ClosedRange<Float> = 3.0...6.0
    /// The beak closes within 120ms of the last token.
    public static let beakCloseDuration: Float = 0.12

    // MARK: Expression

    public private(set) var expression: Expression = .neutral
    private var from: FaceParameters = Expression.neutral.parameters
    private var to: FaceParameters = Expression.neutral.parameters
    private var crossfade: Float = 1

    // MARK: Blink

    private enum BlinkPhase: Equatable { case open, closing, opening }
    private var blinkPhase: BlinkPhase = .open
    private var blinkElapsed: Float = 0
    private var nextBlink: Float = 4
    private var pendingDoubleBlink = false
    private var random: SystemRandom

    // MARK: Beak

    /// Set from the speech amplitude envelope while `speaking`.
    public var speechAmplitude: Float = 0
    private var beakDrive: Float = 0
    private var sinceToken: Float = .greatestFiniteMagnitude

    public private(set) var parameters: FaceParameters = Expression.neutral.parameters
    /// The pose before the blink and the beak are layered on. Exposed because "nothing
    /// snaps" is a claim about the expression blend — a blink is *meant* to be fast, and
    /// measuring it as part of the blend would either fail the check or raise its ceiling
    /// until the check means nothing.
    public private(set) var expressionParameters: FaceParameters = Expression.neutral.parameters

    public init(seed: UInt64 = 0x5EED) {
        random = SystemRandom(seed: seed)
        nextBlink = random.float(in: Self.blinkIntervalRange)
    }

    // MARK: Input

    /// Crossfades to a new expression. Re-requesting the current one is a no-op rather than a
    /// restart, so a state machine that re-emits does not stutter the face.
    public mutating func set(_ expression: Expression) {
        guard expression != self.expression else { return }
        from = parameters
        to = expression.parameters
        self.expression = expression
        crossfade = 0
        // Surprise reads as a double blink; `alert` is the surprised state on this face.
        if expression == .alert {
            // Surprise blinks twice, and it blinks *now* — a double blink that waits for the
            // next scheduled one is not a reaction to anything.
            pendingDoubleBlink = true
            nextBlink = 0
        }
    }

    /// Called for every speech token the client receives. The beak is driven by real tokens,
    /// never by a guess about how long speech will last.
    public mutating func noteToken(amplitude: Float = 0.6) {
        sinceToken = 0
        speechAmplitude = min(1, max(0, amplitude))
        beakDrive = speechAmplitude
    }

    /// Drops the beak immediately — used when speech is interrupted rather than finished.
    public mutating func silence() {
        speechAmplitude = 0
        beakDrive = 0
        sinceToken = .greatestFiniteMagnitude
    }

    // MARK: Per-frame

    public mutating func update(deltaTime: Float) {
        guard deltaTime > 0 else { return }
        advanceCrossfade(deltaTime)
        advanceBlink(deltaTime)
        advanceBeak(deltaTime)
    }

    private mutating func advanceCrossfade(_ dt: Float) {
        if crossfade < 1 {
            crossfade = min(1, crossfade + dt / Self.crossfadeDuration)
        }
        parameters = FaceParameters.blend(from, to, t: Easing.inOutQuad(crossfade))
        expressionParameters = parameters
    }

    private mutating func advanceBlink(_ dt: Float) {
        // No blinking at all while thinking: it reads as concentration (spec 06 §Face).
        let blinkingAllowed = expression != .thinking

        switch blinkPhase {
        case .open:
            nextBlink -= dt * blinkRate
            if blinkingAllowed, nextBlink <= 0 {
                blinkPhase = .closing
                blinkElapsed = 0
            }
        case .closing:
            blinkElapsed += dt
            if blinkElapsed >= Self.blinkCloseDuration {
                blinkPhase = .opening
                blinkElapsed = 0
            }
        case .opening:
            blinkElapsed += dt
            if blinkElapsed >= Self.blinkOpenDuration {
                blinkPhase = .open
                blinkElapsed = 0
                if pendingDoubleBlink {
                    pendingDoubleBlink = false
                    nextBlink = 0.06
                } else {
                    nextBlink = random.float(in: Self.blinkIntervalRange)
                }
            }
        }
        parameters.eyeOpen *= blinkScale
    }

    /// Blinking slows while listening and speeds up when excited. `listening` is a state,
    /// not an expression; `curious` is the face it wears, so that is where the slowing goes.
    private var blinkRate: Float {
        switch expression {
        case .curious: return 0.6
        case .excited: return 1.8
        default: return 1.0
        }
    }

    private var blinkScale: Float {
        switch blinkPhase {
        case .open:
            return 1
        case .closing:
            let t = Easing.inQuad(blinkElapsed / Self.blinkCloseDuration)
            return 1 + (Self.blinkedEyeScale - 1) * t
        case .opening:
            let t = Easing.outQuad(blinkElapsed / Self.blinkOpenDuration)
            return Self.blinkedEyeScale + (1 - Self.blinkedEyeScale) * t
        }
    }

    private mutating func advanceBeak(_ dt: Float) {
        sinceToken += dt
        if sinceToken > 0 {
            // Linear ramp to shut, sized so the beak is fully closed at exactly 120ms after
            // the last token no matter how wide it was.
            beakDrive = max(0, beakDrive - dt / Self.beakCloseDuration)
        }
        parameters.beakOpen = max(parameters.beakOpen, beakDrive * FaceParameters.maxBeakOpen)
    }

    /// True while the beak is being driven by speech rather than by the expression.
    public var isBeakSpeaking: Bool { beakDrive > 0.001 }
}

/// A small deterministic generator so idle timing and blink jitter are reproducible in tests.
/// `SystemRandomNumberGenerator` would make every timing assertion flaky.
public struct SystemRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    public mutating func float(in range: ClosedRange<Float>) -> Float {
        let unit = Float(next() % 1_000_000) / 1_000_000
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    public mutating func float() -> Float { float(in: 0...1) }
}
