import Foundation
import SceneUnderstanding
import simd

/// The bird's half of a teaching act (spec 07 §Acknowledgement).
///
/// Teaching that produces only a toast is a failed teaching act (PRD §7). The order is fixed
/// and each step is here rather than spread across the session: look at the target
/// immediately, hop to it when it is reachable, wear the matching expression, and say the
/// name back. The name-back is the correction channel for a mis-transcription and is not
/// optional, which is why it is part of the plan rather than left to the model's prose.
public struct TeachingResponse: Equatable, Sendable {
    /// Everything the act asks the body to do.
    public struct Plan: Equatable, Sendable {
        public var expression: Expression
        /// Always set: the look is the part that needs nothing to have been written yet.
        public var lookAt: SIMD3<Float>?
        /// Set when the target is reachable. An unreachable target is looked at, not walked to.
        public var hopTo: SIMD3<Float>?
        /// Said back to the user, verbatim.
        public var spokenLine: String
    }

    /// The budget every act has to meet, from spec 07 §Teaching.
    public static let motionBudget: TimeInterval = 0.4

    /// The expression each act wears.
    ///
    /// `scolded` for forbidding exists because forbidding a region must feel like it landed
    /// on a creature (spec 06 §Expressions); `happy` for a correction accepted is what makes
    /// correcting feel like being understood rather than like being an error.
    public static func expression(for act: TeachingAct) -> Expression {
        switch act {
        case .namePlace, .nameObject, .nameActivity: return .curious
        case .forbidRegion: return .scolded
        // Being given a home is the one act that is about the bird, not about the room.
        case .correctName, .setHomePerch: return .happy
        }
    }

    public static func spokenLine(for act: TeachingAct, name: String) -> String {
        switch act {
        case .namePlace, .nameObject, .nameActivity: return "Okay — \(name)."
        case .forbidRegion: return name.isEmpty ? "Okay. Not there." : "Okay. Not \(name)."
        case .correctName: return "Got it — \(name) now."
        case .setHomePerch: return name.isEmpty ? "Okay — I'll wait here." : "Okay — I'll wait at \(name)."
        }
    }

    /// Builds the plan. `reachable` comes from the navmesh, so a forbidden or unreachable
    /// target produces a look and no hop rather than a hop that fails.
    public static func plan(
        for act: TeachingAct,
        name: String,
        target: SIMD3<Float>?,
        reachable: Bool
    ) -> Plan {
        Plan(
            expression: expression(for: act),
            lookAt: target,
            // Forbidding is the one act the bird does not walk toward: hopping onto the thing
            // it was just told to stay away from is the wrong reading of "don't go here".
            hopTo: (reachable && act != .forbidRegion) ? target : nil,
            spokenLine: spokenLine(for: act, name: name)
        )
    }
}

#if canImport(RealityKit)
import QuartzCore

public extension CharacterEntity {
    /// Acknowledges a teaching act on the body.
    ///
    /// Returns the plan so the caller can speak the line; the motion starts on this call,
    /// inside the 400ms budget, without waiting for the record, the model, or the network.
    @discardableResult
    func acknowledge(
        _ act: TeachingAct,
        name: String,
        target: SIMD3<Float>?,
        path: [SIMD3<Float>]? = nil
    ) -> TeachingResponse.Plan {
        let plan = TeachingResponse.plan(
            for: act,
            name: name,
            target: target,
            reachable: !(path ?? []).isEmpty
        )
        if let look = plan.lookAt { apply(.look(at: look)) }
        face.set(plan.expression)
        if plan.hopTo != nil, let path, !path.isEmpty {
            apply(.walk(path: path))
        }
        return plan
    }
}
#endif
