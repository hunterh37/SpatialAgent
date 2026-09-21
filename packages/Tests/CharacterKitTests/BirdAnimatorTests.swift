import XCTest
import simd
@testable import CharacterKit

/// Spec 06 §Idle and §Locomotion. The frame-rate pair matters: the headset runs 90fps and
/// drops to 30 under load, and a spring that is stable at one and divergent at the other is
/// a bird that explodes exactly when the room gets busy.
final class BirdAnimatorTests: XCTestCase {
    private let fast: Float = 1.0 / 90.0
    private let slow: Float = 1.0 / 30.0

    // MARK: Spring stability

    private func converged(at dt: Float, stiffness: Float, damping: Float) -> Spring {
        var spring = Spring(stiffness: stiffness, damping: damping)
        spring.target = 1
        for _ in 0..<Int(4.0 / dt) { spring.step(dt) }
        return spring
    }

    func testSpringConvergesAt90fps() {
        let spring = converged(at: fast, stiffness: 90, damping: 1.0)
        XCTAssertEqual(spring.value, 1, accuracy: 0.001)
        XCTAssertTrue(spring.isSettled)
    }

    func testSpringConvergesAt30fps() {
        let spring = converged(at: slow, stiffness: 90, damping: 1.0)
        XCTAssertEqual(spring.value, 1, accuracy: 0.001)
        XCTAssertTrue(spring.isSettled)
    }

    /// The two frame rates must land in the same place, not merely both land somewhere.
    func testFrameRateDoesNotChangeTheResult() {
        let a = converged(at: fast, stiffness: 120, damping: 0.9)
        let b = converged(at: slow, stiffness: 120, damping: 0.9)
        XCTAssertEqual(a.value, b.value, accuracy: 0.002)
    }

    func testCriticallyDampedSpringNeverOvershoots() {
        for dt in [fast, slow] {
            var spring = Spring(stiffness: 120, damping: 1.0)
            spring.target = 1
            var peak: Float = 0
            for _ in 0..<Int(3.0 / dt) {
                spring.step(dt)
                peak = max(peak, spring.value)
            }
            XCTAssertLessThanOrEqual(peak, 1.001, "overshoot at dt=\(dt)")
        }
    }

    /// Underdamped springs are allowed to ring, but the ringing has to decay, and it has to
    /// decay the same way at both frame rates.
    func testUnderdampedOscillationDecaysAtBothFrameRates() {
        for dt in [fast, slow] {
            var spring = Spring(stiffness: 140, damping: 0.4)
            spring.target = 1
            var latePeak: Float = 0
            var elapsed: Float = 0
            while elapsed < 4 {
                spring.step(dt)
                elapsed += dt
                if elapsed > 2 { latePeak = max(latePeak, abs(spring.value - 1)) }
            }
            XCTAssertLessThan(latePeak, 0.02, "still ringing at dt=\(dt)")
        }
    }

    func testStalledFrameDoesNotTeleportTheSpring() {
        var spring = Spring(stiffness: 200, damping: 1.0)
        spring.target = 1
        spring.step(5.0)
        XCTAssertLessThanOrEqual(spring.value, 1.001)
        XCTAssertFalse(spring.value.isNaN)
    }

    func testResetClearsVelocity() {
        var spring = Spring(stiffness: 90, damping: 1.0)
        spring.target = 1
        spring.step(0.1)
        spring.reset(to: 0.5)
        XCTAssertEqual(spring.value, 0.5)
        XCTAssertEqual(spring.velocity, 0)
        XCTAssertTrue(spring.isSettled)
    }

    func testAngularSpringTakesTheShortWayAround() {
        var spring = AngularSpring(stiffness: 120, damping: 1.0, value: 3.0)
        spring.target = -3.0
        // 3.0 to -3.0 the short way is +0.28 rad, not -6.0.
        XCTAssertEqual(spring.target, 3.0 + (2 * .pi - 6.0), accuracy: 1e-4)
        for _ in 0..<270 { spring.step(fast) }
        XCTAssertEqual(AngularSpring.shortest(from: spring.value, to: -3.0), 0, accuracy: 0.01)
    }

    // MARK: Easing

    func testEasingCurvesAreBounded() {
        for t in stride(from: Float(-0.5), through: 1.5, by: 0.05) {
            for value in [
                Easing.linear(t), Easing.inQuad(t), Easing.outQuad(t),
                Easing.inOutQuad(t), Easing.outCubic(t), Easing.inOutCubic(t),
            ] {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testEasingCurvesStartAtZeroAndEndAtOne() {
        for curve in [Easing.inQuad, Easing.outQuad, Easing.inOutQuad, Easing.outCubic,
                      Easing.inOutCubic] {
            XCTAssertEqual(curve(0), 0, accuracy: 1e-5)
            XCTAssertEqual(curve(1), 1, accuracy: 1e-5)
        }
    }

    func testOutBackOvershootsThenSettles() {
        XCTAssertGreaterThan(Easing.outBack(0.6), 1.0)
        XCTAssertEqual(Easing.outBack(1), 1, accuracy: 1e-5)
    }

    func testPulseReturnsToZero() {
        XCTAssertEqual(Easing.pulse(0), 0, accuracy: 1e-5)
        XCTAssertEqual(Easing.pulse(1), 0, accuracy: 1e-5)
        XCTAssertEqual(Easing.pulse(0.5), 1, accuracy: 1e-5)
    }

    // MARK: Breathing

    func testBreathingStaysWithinTwoPercentOfBodyScale() {
        var animator = BirdAnimator()
        var peak: Float = 0
        for _ in 0..<(90 * 20) {
            animator.update(deltaTime: fast)
            peak = max(peak, abs(animator.breathScale.y - 1))
        }
        XCTAssertLessThanOrEqual(peak, BirdAnimator.breathAmplitude + 1e-4)
        // And it actually breathes rather than sitting at 1.
        XCTAssertGreaterThan(peak, BirdAnimator.breathAmplitude * 0.9)
    }

    func testBreathingRunsAtAQuarterHertz() {
        var animator = BirdAnimator()
        // One full cycle is 4s; after exactly one cycle the phase is back where it started.
        for _ in 0..<(90 * 4) { animator.update(deltaTime: fast) }
        // Phase is kept in 0..<1, so "back to the start" is a distance measured modulo 1.
        let distance = min(animator.breathPhase, 1 - animator.breathPhase)
        XCTAssertEqual(distance, 0, accuracy: 0.01)
    }

    func testBreathingNeverFullyStops() {
        var animator = BirdAnimator()
        animator.breathDepth = 0
        animator.breathRate = 0
        for _ in 0..<90 { animator.update(deltaTime: fast) }
        // Rate is floored, so the phase still advances even when something asks it not to.
        XCTAssertGreaterThan(animator.breathPhase, 0)
    }

    // MARK: Squash

    func testLandingSquashIsWideAndShort() {
        var animator = BirdAnimator()
        animator.land()
        XCTAssertEqual(animator.squash.scale.x, 1.08, accuracy: 0.001)
        XCTAssertEqual(animator.squash.scale.y, 0.92, accuracy: 0.001)
    }

    func testAnticipationStretchesTheOtherWay() {
        var animator = BirdAnimator()
        animator.anticipate()
        XCTAssertLessThan(animator.squash.scale.x, 1)
        XCTAssertGreaterThan(animator.squash.scale.y, 1)
    }

    func testSquashEasesBackToRestAndStops() {
        var animator = BirdAnimator()
        animator.land()
        var elapsed: Float = 0
        while elapsed < 0.19 {
            animator.update(deltaTime: fast)
            elapsed += fast
        }
        XCTAssertFalse(animator.squash.isActive)
        XCTAssertEqual(animator.bodyScale.y, animator.breathScale.y, accuracy: 1e-5)
    }

    func testSquashIsHeldBeforeItReleases() {
        var animator = BirdAnimator()
        animator.land()
        animator.update(deltaTime: 0.05)
        XCTAssertEqual(animator.squash.scale.x, 1.08, accuracy: 0.001)
        animator.update(deltaTime: 0.08)
        XCTAssertLessThan(animator.squash.scale.x, 1.08)
        XCTAssertGreaterThan(animator.squash.scale.x, 1.0)
    }

    func testSquashNeverSnapsBackInOneFrame() {
        var animator = BirdAnimator()
        animator.land()
        animator.update(deltaTime: 0.06)
        var previous = animator.squash.scale.x
        while animator.squash.isActive {
            animator.update(deltaTime: fast)
            let now = animator.squash.scale.x
            XCTAssertLessThan(abs(now - previous), 0.03)
            previous = now
        }
    }

    func testBodyScaleCombinesBreathAndSquash() {
        var animator = BirdAnimator()
        animator.update(deltaTime: 1.0)
        animator.land()
        XCTAssertEqual(
            animator.bodyScale.x,
            animator.breathScale.x * animator.squash.scale.x,
            accuracy: 1e-5
        )
    }
}
