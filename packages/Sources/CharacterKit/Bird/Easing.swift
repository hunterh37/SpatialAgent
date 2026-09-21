import Foundation

/// The easing curves the bird's timed motion is built from.
///
/// Springs cover anything that chases a moving target; these cover anything with a fixed
/// duration — squash, blink, hop arc, crossfade. Both exist because using a spring for a
/// 60ms landing squash means the squash has no defined end, and using a curve for head
/// tracking means the head snaps whenever the target moves.
public enum Easing: Sendable {
    /// Clamps to 0...1 first, so callers can pass raw elapsed/duration without guarding.
    public static func clamp(_ t: Float) -> Float { min(1, max(0, t)) }

    public static func linear(_ t: Float) -> Float { clamp(t) }

    public static func inQuad(_ t: Float) -> Float {
        let t = clamp(t)
        return t * t
    }

    public static func outQuad(_ t: Float) -> Float {
        let t = clamp(t)
        return 1 - (1 - t) * (1 - t)
    }

    public static func inOutQuad(_ t: Float) -> Float {
        let t = clamp(t)
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    public static func outCubic(_ t: Float) -> Float {
        let t = clamp(t)
        return 1 - pow(1 - t, 3)
    }

    public static func inOutCubic(_ t: Float) -> Float {
        let t = clamp(t)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Overshoots and comes back. The anticipation before a hop uses it.
    public static func outBack(_ t: Float, overshoot: Float = 1.70158) -> Float {
        let t = clamp(t)
        let c3 = overshoot + 1
        return 1 + c3 * pow(t - 1, 3) + overshoot * pow(t - 1, 2)
    }

    /// Rises to 1 at the midpoint and returns to 0. Every squash pulse is this shape.
    public static func pulse(_ t: Float) -> Float {
        let t = clamp(t)
        return sin(t * .pi)
    }
}
