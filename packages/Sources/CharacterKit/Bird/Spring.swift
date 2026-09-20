import Foundation

/// A damped spring toward a target, used for everything on the bird that follows something.
///
/// Spec 06 asks for damped motion "never linear" on the head, and the same primitive drives
/// pupils, crest, wings and squash recovery. One type, tuned per use, is what keeps the motion
/// feeling like one creature.
///
/// Integration is semi-implicit Euler with internal substepping. A frame at 30fps is three
/// times the step of one at 90fps, and a stiff spring integrated in one 33ms step diverges —
/// the substep cap is what makes the 30fps path behave like the 90fps path instead of
/// exploding or ringing.
public struct Spring: Equatable, Sendable {
    /// Undamped angular frequency. Higher is snappier.
    public var stiffness: Float
    /// 1.0 is critically damped: fastest approach with no overshoot. Below 1 rings, which is
    /// what a bounce is.
    public var damping: Float

    public private(set) var value: Float
    public private(set) var velocity: Float
    public var target: Float

    /// Largest step the integrator will take. 4ms is well inside stability for every tuning
    /// used on the bird, and a 90fps frame is a single step.
    public static let maxSubstep: Float = 1.0 / 240.0

    public init(stiffness: Float = 90, damping: Float = 1.0, value: Float = 0, target: Float = 0) {
        self.stiffness = stiffness
        self.damping = damping
        self.value = value
        self.velocity = 0
        self.target = target
    }

    /// Advances the spring. Safe to call with any frame duration.
    @discardableResult
    public mutating func step(_ deltaTime: Float) -> Float {
        guard deltaTime > 0 else { return value }
        // Clamped so a stalled frame cannot teleport the rig.
        let total = min(deltaTime, 0.25)
        let steps = max(1, Int((total / Self.maxSubstep).rounded(.up)))
        let dt = total / Float(steps)
        let k = stiffness * stiffness
        let c = 2 * damping * stiffness
        for _ in 0..<steps {
            let acceleration = k * (target - value) - c * velocity
            velocity += acceleration * dt
            value += velocity * dt
        }
        return value
    }

    /// Jumps to a value with no motion. Used on placement, never during animation.
    public mutating func reset(to value: Float) {
        self.value = value
        self.target = value
        velocity = 0
    }

    /// Distance still to travel, which is what "settled" means for every caller.
    public var isSettled: Bool { abs(target - value) < 0.001 && abs(velocity) < 0.01 }
}

/// The same spring on an angle, wrapped so it takes the short way around.
public struct AngularSpring: Equatable, Sendable {
    private var spring: Spring

    public init(stiffness: Float = 90, damping: Float = 1.0, value: Float = 0) {
        spring = Spring(stiffness: stiffness, damping: damping, value: value, target: value)
    }

    public var value: Float { spring.value }
    public var velocity: Float { spring.velocity }
    public var isSettled: Bool { spring.isSettled }
    public var stiffness: Float {
        get { spring.stiffness }
        set { spring.stiffness = newValue }
    }

    public var target: Float {
        get { spring.target }
        set {
            // Re-express both around the current value so a wrap from +179° to -179° is a 2°
            // move, not a 358° sweep across the face.
            let delta = AngularSpring.shortest(from: spring.value, to: newValue)
            spring.target = spring.value + delta
        }
    }

    @discardableResult
    public mutating func step(_ deltaTime: Float) -> Float { spring.step(deltaTime) }

    public mutating func reset(to value: Float) { spring.reset(to: value) }

    public static func shortest(from: Float, to: Float) -> Float {
        var delta = to - from
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
