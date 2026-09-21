import Foundation
import simd

/// Every measurement in spec/06-avatar.md, in one struct, in metres.
///
/// The ratios are the cuteness (spec 06 §Proportions), and tuning them is the bulk of the
/// avatar work. Keeping them here — rather than as literals inside rig construction — is what
/// makes them adjustable and assertable without reading geometry code.
///
/// The spec fixes both the part sizes *and* a 22cm crown height, and those two do not agree:
/// an 11cm body sitting on 1.8cm feet with a 8cm head overlapping it stands 17.9cm, and the
/// only ways to reach 22cm are a modelled neck (the spec forbids one) or a floating head.
/// So the rig is built at the spec's part sizes and then uniformly scaled by
/// ``normalizationScale`` so the crown lands at exactly ``crownHeight``. Uniform scale leaves
/// every ratio — the part the spec calls non-negotiable — untouched.
public struct BirdProportions: Equatable, Sendable {
    // MARK: Body

    /// 11cm sphere. The largest single element.
    public var bodyDiameter: Float = 0.11
    /// Roundness is non-negotiable; this is the only non-uniform scale on the body.
    public var bodyScale: SIMD3<Float> = SIMD3(1.0, 0.92, 0.95)

    // MARK: Head

    /// 8cm sphere, ~0.72 of body diameter.
    public var headDiameter: Float = 0.08
    /// How far the head sphere sinks into the body. The neck is implied, not modelled.
    public var headOverlap: Float = 0.02
    /// The head sits forward of body centre by ~1cm.
    public var headForward: Float = 0.01

    // MARK: Face

    /// 2.6cm spheres, ~0.33 of head diameter, which is enormous and correct.
    public var eyeDiameter: Float = 0.026
    /// Gap between the eyes, in eye diameters.
    public var eyeSeparation: Float = 0.6
    /// Eyes sit forward and high on the head.
    public var eyeRise: Float = 0.008
    public var pupilDiameter: Float = 0.011
    /// Short and blunt. A long beak reads as a crow and kills it.
    public var beakLength: Float = 0.022
    public var beakBaseDiameter: Float = 0.018
    public var beakDrop: Float = 0.004
    /// Barely visible at neutral, which is why they carry the plumage material.
    public var browLength: Float = 0.016
    public var browThickness: Float = 0.004
    public var browRise: Float = 0.019
    /// Three small cones. Optional per colour variant.
    public var crestConeHeight: Float = 0.022
    public var crestConeDiameter: Float = 0.014
    public var crestSpread: Float = 0.012

    // MARK: Limbs

    /// Two flattened ellipsoids, 6cm, resting slightly out from the body, never folded flat.
    public var wingLength: Float = 0.06
    public var wingFlatten: Float = 0.3
    public var wingRest: Float = 0.004
    /// Visible, planted, slightly oversized.
    public var footLength: Float = 0.03
    public var footWidth: Float = 0.022
    public var footHeight: Float = 0.018
    public var footSeparation: Float = 0.044
    /// Small. A counterweight for the head, visually and in the animation.
    public var tailLength: Float = 0.05
    public var tailWidth: Float = 0.028
    public var tailThickness: Float = 0.008

    // MARK: Overall

    /// Height at the crown, standing. Reads as a small creature on a desk.
    public var crownHeight: Float = 0.22

    public init() {}

    // MARK: Derived layout, all pre-normalization

    public var bodyRadius: Float { bodyDiameter / 2 }
    public var headRadius: Float { headDiameter / 2 }
    public var eyeRadius: Float { eyeDiameter / 2 }

    /// Vertical half-extent of the body after its non-uniform scale.
    public var bodyHalfHeight: Float { bodyRadius * bodyScale.y }

    /// The body rests on the feet: no gap, no intersection.
    public var bodyCenterY: Float { footHeight + bodyHalfHeight }
    public var bodyTopY: Float { bodyCenterY + bodyHalfHeight }
    public var headCenterY: Float { bodyTopY - headOverlap + headRadius }
    public var eyeCenterY: Float { headCenterY + eyeRise }

    /// Eye centre offset from the midline, from the spec's separation-in-eye-diameters rule.
    public var eyeCenterX: Float { (eyeSeparation * eyeDiameter) / 2 + eyeRadius }
    /// Eyes sit forward on the head sphere, not on its equator.
    public var eyeCenterZ: Float { headForward + headRadius * 0.72 }

    /// Crown before normalization — the top of the head sphere, not the crest.
    public var naturalCrownHeight: Float { headCenterY + headRadius }

    /// Uniform scale applied at the root so the crown lands at ``crownHeight``.
    public var normalizationScale: Float {
        guard naturalCrownHeight > .ulpOfOne else { return 1 }
        return crownHeight / naturalCrownHeight
    }

    // MARK: Ratios the spec calls out by name

    public var headToBodyRatio: Float { headDiameter / bodyDiameter }
    public var eyeToHeadRatio: Float { eyeDiameter / headDiameter }

    /// The spec's own bounds on the two ratios that decide whether it is cute.
    public var satisfiesSpecRatios: Bool {
        (0.70...0.75).contains(headToBodyRatio) && (0.30...0.36).contains(eyeToHeadRatio)
    }
}
