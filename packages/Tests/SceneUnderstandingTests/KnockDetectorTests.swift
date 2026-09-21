import XCTest
import simd
@testable import SceneUnderstanding

/// A swat is a hand crossing the bird fast. Everything else — a reach, a slow pass, a hand
/// put down on the table — has to cost nothing, because a perch wrongly ruled out is a
/// memory the user did not teach.
final class KnockDetectorTests: XCTestCase {
    private let bird = SIMD3<Float>(0, 1, -1)
    private let frame: Float = 1.0 / 90

    /// A hand crossing the bird at 2 m/s.
    private func swipe(through point: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let travel = SIMD3<Float>(2 * frame, 0, 0)
        return (point - travel * 0.5, point + travel * 0.5)
    }

    func testAFastHandThroughTheBirdIsAStrike() throws {
        let (from, to) = swipe(through: bird)
        let strike = try XCTUnwrap(
            KnockDetector.evaluate(from: from, to: to, deltaTime: frame, target: bird)
        )
        XCTAssertGreaterThan(strike.speed, KnockDetector.minimumSpeed)
        XCTAssertEqual(simd_length(strike.direction), 1, accuracy: 1e-4)
        XCTAssertEqual(strike.direction.y, 0, "a knock throws him sideways, never up")
        XCTAssertGreaterThan(strike.force, 0)
        XCTAssertLessThanOrEqual(strike.force, 1)
    }

    /// The same path at reaching speed. This is the test that protects the demo: the user
    /// points at the perch, and the bird does not decide he was attacked.
    func testASlowHandThroughTheBirdIsAReach() {
        let travel = SIMD3<Float>(0.3 * frame, 0, 0)
        XCTAssertNil(
            KnockDetector.evaluate(
                from: bird - travel * 0.5, to: bird + travel * 0.5, deltaTime: frame, target: bird
            )
        )
    }

    func testAFastHandThatMissesIsNothing() {
        let (from, to) = swipe(through: bird + SIMD3(0, 0.6, 0))
        XCTAssertNil(KnockDetector.evaluate(from: from, to: to, deltaTime: frame, target: bird))
    }

    /// At 3 m/s the hand is 3cm past the bird by the next frame, so sampling positions alone
    /// would miss the fastest swipes. The segment's closest approach is what is tested.
    func testAHandThatPassesClearThroughBetweenFramesStillCounts() throws {
        let from = bird + SIMD3(-0.4, 0, 0)
        let to = bird + SIMD3(0.4, 0, 0)
        let strike = try XCTUnwrap(
            KnockDetector.evaluate(from: from, to: to, deltaTime: 0.25, target: bird)
        )
        XCTAssertEqual(strike.direction.x, 1, accuracy: 1e-4)
    }

    /// Putting a mug down next to the perch travels fast and passes close, and is not a swat.
    func testAVerticalDropIsNotASwat() {
        let from = bird + SIMD3(0, 0.3, 0)
        let to = bird + SIMD3(0, -0.1, 0)
        XCTAssertNil(KnockDetector.evaluate(from: from, to: to, deltaTime: 0.15, target: bird))
    }

    // MARK: Stateful use

    func testOneSwipeRegistersOnceAcrossManyFrames() {
        var detector = KnockDetector()
        var strikes = 0
        var x: Float = -0.3
        // A 3-frame swipe: the hand is within the strike radius on more than one of them.
        for _ in 0 ..< 3 {
            let hand = SIMD3(bird.x + x, bird.y, bird.z)
            if detector.update(deltaTime: frame, hands: [nil, hand], target: bird) != nil {
                strikes += 1
            }
            x += 0.3
        }
        XCTAssertEqual(strikes, 1, "one swipe must cost one perch, not three")
        XCTAssertTrue(detector.isCoolingDown)
    }

    func testTheFirstFrameOfTrackingCannotStrike() {
        var detector = KnockDetector()
        XCTAssertNil(detector.update(deltaTime: frame, hands: [nil, bird], target: bird))
    }

    func testEitherHandCanSwat() {
        for slot in 0 ..< 2 {
            var detector = KnockDetector()
            var hands: [SIMD3<Float>?] = [nil, nil]
            hands[slot] = bird + SIMD3(-0.3, 0, 0)
            _ = detector.update(deltaTime: frame, hands: hands, target: bird)
            hands[slot] = bird + SIMD3(0.3, 0, 0)
            XCTAssertNotNil(detector.update(deltaTime: frame, hands: hands, target: bird))
        }
    }

    func testResetClearsTheCooldown() {
        var detector = KnockDetector()
        _ = detector.update(deltaTime: frame, hands: [nil, bird + SIMD3(-0.3, 0, 0)], target: bird)
        _ = detector.update(deltaTime: frame, hands: [nil, bird + SIMD3(0.3, 0, 0)], target: bird)
        XCTAssertTrue(detector.isCoolingDown)
        detector.reset()
        XCTAssertFalse(detector.isCoolingDown)
    }
}
