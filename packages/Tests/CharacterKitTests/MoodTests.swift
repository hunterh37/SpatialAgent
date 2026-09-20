import XCTest
@testable import CharacterKit

/// Spec 07 §Learned behavior, affinity.
final class MoodTests: XCTestCase {
    // MARK: Monotonic response to each input

    func testEveryPositiveInputRaisesAffinityAndEveryNegativeOneLowersIt() {
        for input in Mood.Input.allCases {
            var mood = Mood()
            let before = mood.affinity
            mood.note(input)
            if input.step > 0 {
                XCTAssertGreaterThan(mood.affinity, before, "\(input)")
            } else {
                XCTAssertLessThan(mood.affinity, before, "\(input)")
            }
        }
    }

    func testTeachingIsWorthMoreThanASuccessfulAction() {
        var taught = Mood()
        taught.note(.taught)
        var acted = Mood()
        acted.note(.actionSucceeded)
        XCTAssertGreaterThan(taught.affinity, acted.affinity)
    }

    func testTimeInSessionCountsButOnlyALittle() {
        var mood = Mood()
        mood.advance(seconds: 600)
        XCTAssertGreaterThan(mood.affinity, 0)

        var taught = Mood()
        taught.note(.taught)
        XCTAssertGreaterThan(taught.affinity, mood.affinity, "an hour must not beat a teaching act")
    }

    func testTimeSaturates() {
        var mood = Mood()
        mood.advance(seconds: 60 * 60 * 8)
        XCTAssertLessThanOrEqual(mood.affinity, Mood.timeCap + 1e-5)
    }

    func testAffinityIsBounded() {
        var mood = Mood()
        for _ in 0..<500 {
            mood.beginSession()
            mood.note(.taught)
        }
        XCTAssertLessThanOrEqual(mood.affinity, 1)

        for _ in 0..<500 { mood.note(.questionIgnored) }
        XCTAssertGreaterThanOrEqual(mood.affinity, -1)
    }

    // MARK: No grind path

    func testRepeatingTheSameInputSaturatesWithinASession() {
        var mood = Mood()
        for _ in 0..<50 { mood.note(.taught) }
        XCTAssertLessThanOrEqual(mood.affinity, Mood.Input.taught.sessionCap + 1e-5)
    }

    func testANewSessionLetsItGrowAgainButNotInstantly() {
        var mood = Mood()
        for _ in 0..<50 { mood.note(.taught) }
        let afterOne = mood.affinity
        mood.beginSession()
        for _ in 0..<50 { mood.note(.taught) }
        XCTAssertGreaterThan(mood.affinity, afterOne)
        XCTAssertLessThanOrEqual(mood.affinity, afterOne + Mood.Input.taught.sessionCap + 1e-5)
    }

    func testIgnoringQuestionsKeepsCostingNoMatterHowOften() {
        var mood = Mood()
        mood.note(.questionIgnored)
        let once = mood.affinity
        for _ in 0..<5 { mood.note(.questionIgnored) }
        XCTAssertLessThan(mood.affinity, once, "negative inputs must not saturate")
    }

    // MARK: Never a number

    /// The public surface exposes warmth and three biases. It does not expose the value, and
    /// the value is not reconstructible from a description.
    func testNoPublicApiExposesARawAffinityValue() {
        var mood = Mood()
        mood.note(.taught)

        // Warmth is a coarse enum with no numeric payload.
        XCTAssertFalse(Mood.Warmth.allCases.map(\.rawValue).contains { $0.contains(where: \.isNumber) })
        // And nothing in the type prints one.
        XCTAssertFalse("\(mood.warmth)".contains(where: \.isNumber))
        XCTAssertFalse("\(mood.baselineExpression)".contains(where: \.isNumber))
    }

    func testWarmthIsCoarseRatherThanContinuous() {
        var mood = Mood()
        let start = mood.warmth
        mood.note(.actionSucceeded)
        XCTAssertEqual(mood.warmth, start, "a single small input must not change the readout")
    }

    func testWarmthRisesThroughItsBandsInOrder() {
        var mood = Mood()
        XCTAssertEqual(mood.warmth, .neutral)
        for _ in 0..<10 {
            mood.beginSession()
            mood.note(.taught)
            mood.note(.taught)
            mood.note(.taught)
            mood.note(.taught)
        }
        XCTAssertGreaterThan(mood.warmth, .neutral)

        var wary = Mood()
        for _ in 0..<10 { wary.note(.questionIgnored) }
        XCTAssertEqual(wary.warmth, .wary)
    }

    // MARK: The biases it drives

    func testAttachmentClosesTheDistanceAndWarinessOpensIt() {
        var attached = Mood()
        for _ in 0..<10 {
            attached.beginSession()
            attached.note(.taught)
            attached.note(.taught)
            attached.note(.taught)
        }
        var wary = Mood()
        for _ in 0..<10 { wary.note(.questionIgnored) }

        XCTAssertLessThan(attached.preferredDistance, Mood().preferredDistance)
        XCTAssertGreaterThan(wary.preferredDistance, Mood().preferredDistance)
        // Never close enough to crowd, never far enough to lose.
        for mood in [attached, wary, Mood()] {
            XCTAssertGreaterThanOrEqual(mood.preferredDistance, 1.0)
            XCTAssertLessThanOrEqual(mood.preferredDistance, 2.2)
        }
    }

    func testTheIdleBiasFeedsTheIdlePoolInTheStatedDirection() {
        var attached = Mood()
        for _ in 0..<10 {
            attached.beginSession()
            attached.note(.taught)
            attached.note(.taught)
            attached.note(.taught)
        }
        var pool = IdlePool()
        pool.mood = attached.idleBias
        let energetic = pool.weight(for: .smallHop)

        var flat = IdlePool()
        flat.mood = Mood().idleBias
        XCTAssertGreaterThan(energetic, flat.weight(for: .smallHop))
    }

    func testTheBaselineFaceFollowsWarmth() {
        var wary = Mood()
        for _ in 0..<10 { wary.note(.questionIgnored) }
        XCTAssertEqual(wary.baselineExpression, .alert)
        XCTAssertEqual(Mood().baselineExpression, .neutral)
    }

    func testBreathDepthStaysAlive() {
        var wary = Mood()
        for _ in 0..<20 { wary.note(.questionIgnored) }
        XCTAssertGreaterThanOrEqual(wary.breathDepth, 0.7, "breathing must never stop")
        XCTAssertLessThanOrEqual(wary.breathDepth, 1.0)
    }
}
