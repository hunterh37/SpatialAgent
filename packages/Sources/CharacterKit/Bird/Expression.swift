import Foundation

/// The face, as numbers.
///
/// Spec 06 §Face: four parameters — pupils, brows, beak, crest — plus the eye squint and head
/// tilt the named expressions lean on. A texture atlas was rejected because a swapped texture
/// cannot ease, and every one of these has to.
public struct FaceParameters: Equatable, Sendable {
    /// Pupil scale. 1.15 dilated for happy and curious, 0.85 contracted for alert.
    public var pupilDilation: Float = 1.0
    /// Eye Y-scale. 1 open, 0.08 blinked shut, 0.6 squinted for happy.
    public var eyeOpen: Float = 1.0
    /// Inner-brow height. Up is concern.
    public var browInner: Float = 0
    /// Outer-brow height. Down is determination.
    public var browOuter: Float = 0
    /// Left/right difference. Nonzero is a cocked brow, which is most of `curious`.
    public var browAsymmetry: Float = 0
    /// Beak hinge angle in radians, 0–22°.
    public var beakOpen: Float = 0
    /// Crest lean: +1 forward (curious), -1 flat back (uncertain, scolded).
    public var crestLean: Float = 0
    /// Crest spread, 0–1. Surprise spreads it.
    public var crestSpread: Float = 0
    /// Head roll in radians. The tilt that reads as a question.
    public var headTilt: Float = 0
    /// Head pitch in radians. Up and away is thinking, down is sad and scolded.
    public var headPitch: Float = 0
    /// Body height offset as a fraction: +raised for alert, -shrunk for scolded.
    public var bodyRaise: Float = 0

    public init() {}

    /// The maximum beak angle: 22° (spec 06 §Face).
    public static let maxBeakOpen: Float = 22 * .pi / 180

    /// Ordered parameter vector. Distinctness between expressions is asserted against it, and
    /// blending walks it, so there is exactly one place that knows the parameter count.
    public var vector: [Float] {
        [pupilDilation, eyeOpen, browInner, browOuter, browAsymmetry,
         beakOpen, crestLean, crestSpread, headTilt, headPitch, bodyRaise]
    }

    public init(vector: [Float]) {
        precondition(vector.count == 11)
        pupilDilation = vector[0]
        eyeOpen = vector[1]
        browInner = vector[2]
        browOuter = vector[3]
        browAsymmetry = vector[4]
        beakOpen = vector[5]
        crestLean = vector[6]
        crestSpread = vector[7]
        headTilt = vector[8]
        headPitch = vector[9]
        bodyRaise = vector[10]
    }

    /// Straight-line blend. Crossfade timing is the controller's business, not the pose's.
    public static func blend(_ a: FaceParameters, _ b: FaceParameters, t: Float) -> FaceParameters {
        let t = Easing.clamp(t)
        return FaceParameters(vector: zip(a.vector, b.vector).map { $0 + ($1 - $0) * t })
    }

    /// Largest single-parameter difference between two poses.
    public static func distance(_ a: FaceParameters, _ b: FaceParameters) -> Float {
        zip(a.vector, b.vector).map { abs($0 - $1) }.max() ?? 0
    }
}

/// The nine named expressions of spec 06 §Expressions.
///
/// `scolded` is in the list because forbidding a region has to feel like it landed on a
/// creature; it is the emotional receipt for the one destructive thing a user can teach.
public enum Expression: String, CaseIterable, Sendable {
    case neutral
    case curious
    case happy
    case thinking
    case confused
    case alert
    case sad
    case excited
    case scolded

    public var parameters: FaceParameters {
        var p = FaceParameters()
        switch self {
        case .neutral:
            break
        case .curious:
            p.pupilDilation = 1.15
            p.browAsymmetry = 0.5
            p.browInner = 0.15
            p.crestLean = 1.0
            p.headTilt = 12 * .pi / 180
        case .happy:
            p.pupilDilation = 1.15
            p.eyeOpen = 0.6
            p.beakOpen = FaceParameters.maxBeakOpen * 0.25
            p.crestLean = 0.4
            p.browOuter = 0.2
        case .thinking:
            p.pupilDilation = 0.95
            p.crestLean = -0.5
            p.headPitch = 18 * .pi / 180
            p.headTilt = 5 * .pi / 180
            p.browInner = 0.1
        case .confused:
            p.pupilDilation = 1.05
            p.browAsymmetry = -0.7
            p.browInner = 0.35
            p.headTilt = -18 * .pi / 180
        case .alert:
            p.pupilDilation = 0.85
            p.eyeOpen = 1.05
            p.crestLean = 0.9
            p.crestSpread = 0.4
            p.browOuter = -0.25
            p.bodyRaise = 0.04
        case .sad:
            p.pupilDilation = 0.95
            p.eyeOpen = 0.8
            p.browInner = 0.6
            p.browOuter = -0.1
            p.crestLean = -1.0
            p.headPitch = -20 * .pi / 180
        case .excited:
            p.pupilDilation = 1.2
            p.eyeOpen = 0.9
            p.beakOpen = FaceParameters.maxBeakOpen * 0.45
            p.crestLean = 0.6
            p.crestSpread = 1.0
            p.bodyRaise = 0.02
        case .scolded:
            p.pupilDilation = 0.9
            p.eyeOpen = 0.7
            p.browInner = 0.45
            p.crestLean = -1.0
            p.headPitch = -26 * .pi / 180
            p.headTilt = 8 * .pi / 180
            // Body shrunk 6%.
            p.bodyRaise = -0.06
        }
        return p
    }
}
