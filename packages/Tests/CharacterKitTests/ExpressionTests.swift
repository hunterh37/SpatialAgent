import XCTest
@testable import CharacterKit

/// Spec 06 §Face and §Expressions.
final class ExpressionTests: XCTestCase {
    private let frame: Float = 1.0 / 90.0

    // MARK: Distinctness

    func testEveryExpressionProducesADistinctParameterVector() {
        var seen: [[Float]] = []
        for expression in Expression.allCases {
            let vector = expression.parameters.vector
            XCTAssertFalse(seen.contains(vector), "\(expression) duplicates another expression")
            seen.append(vector)
        }
        XCTAssertEqual(seen.count, 9)
    }

    /// Distinct-but-identical-at-1.5m is the failure this guards: two expressions differing
    /// by a hair are two expressions the user cannot tell apart.
    func testEveryExpressionPairIsVisiblyApart() {
        for a in Expression.allCases {
            for b in Expression.allCases where a != b {
                let distance = FaceParameters.distance(a.parameters, b.parameters)
                XCTAssertGreaterThan(distance, 0.05, "\(a) vs \(b)")
            }
        }
    }

    func testScoldedShrinksTheBodyBySixPercent() {
        XCTAssertEqual(Expression.scolded.parameters.bodyRaise, -0.06, accuracy: 1e-6)
    }

    func testBeakNeverExceedsTwentyTwoDegrees() {
        for expression in Expression.allCases {
            XCTAssertLessThanOrEqual(expression.parameters.beakOpen, FaceParameters.maxBeakOpen)
            XCTAssertGreaterThanOrEqual(expression.parameters.beakOpen, 0)
        }
    }

    func testConfusedTiltsOppositeCurious() {
        XCTAssertGreaterThan(Expression.curious.parameters.headTilt, 0)
        XCTAssertLessThan(Expression.confused.parameters.headTilt, 0)
        XCTAssertGreaterThan(
            abs(Expression.confused.parameters.headTilt),
            abs(Expression.curious.parameters.headTilt)
        )
    }

    func testPupilsDilateForHappyAndContractForAlert() {
        XCTAssertEqual(Expression.happy.parameters.pupilDilation, 1.15, accuracy: 1e-6)
        XCTAssertEqual(Expression.curious.parameters.pupilDilation, 1.15, accuracy: 1e-6)
        XCTAssertEqual(Expression.alert.parameters.pupilDilation, 0.85, accuracy: 1e-6)
    }

    func testCrestFlattensForUncertainAndScolded() {
        XCTAssertLessThan(Expression.scolded.parameters.crestLean, 0)
        XCTAssertLessThan(Expression.sad.parameters.crestLean, 0)
        XCTAssertLessThan(Expression.thinking.parameters.crestLean, 0)
        XCTAssertGreaterThan(Expression.curious.parameters.crestLean, 0)
    }

    // MARK: Crossfade

    /// The one hard rule: nothing on this face is allowed to snap.
    func testCrossfadeNeverSnaps() {
        // The fastest legal per-frame move is the widest parameter swing over the crossfade
        // duration, plus headroom for the ease's peak slope.
        let widest = Expression.allCases.flatMap { a in
            Expression.allCases.map { FaceParameters.distance(a.parameters, $0.parameters) }
        }.max() ?? 1
        let limit = widest / FaceController.crossfadeDuration * frame * 2.2

        for target in Expression.allCases {
            var face = FaceController()
            face.set(.scolded)
            for _ in 0..<40 { face.update(deltaTime: frame) }
            face.set(target)
            var previous = face.expressionParameters
            for _ in 0..<60 {
                face.update(deltaTime: frame)
                let moved = FaceParameters.distance(previous, face.expressionParameters)
                XCTAssertLessThanOrEqual(moved, limit, "snapped on the way to \(target)")
                previous = face.expressionParameters
            }
        }
    }

    func testCrossfadeReachesTheTarget() {
        var face = FaceController()
        face.set(.excited)
        for _ in 0..<60 { face.update(deltaTime: frame) }
        // Blink is the only thing still multiplying the eye, so compare everything else.
        let expected = Expression.excited.parameters
        XCTAssertEqual(face.parameters.crestSpread, expected.crestSpread, accuracy: 0.01)
        XCTAssertEqual(face.parameters.pupilDilation, expected.pupilDilation, accuracy: 0.01)
        XCTAssertEqual(face.expression, .excited)
    }

    func testSettingTheSameExpressionDoesNotRestartTheFade() {
        var face = FaceController()
        face.set(.happy)
        for _ in 0..<30 { face.update(deltaTime: frame) }
        let midway = face.parameters
        face.set(.happy)
        face.update(deltaTime: frame)
        XCTAssertLessThan(FaceParameters.distance(midway, face.parameters), 0.05)
    }

    func testEveryExpressionIsReachableFromEveryOther() {
        for a in Expression.allCases {
            for b in Expression.allCases where a != b {
                var face = FaceController()
                face.set(a)
                for _ in 0..<40 { face.update(deltaTime: frame) }
                face.set(b)
                for _ in 0..<40 { face.update(deltaTime: frame) }
                XCTAssertEqual(face.expression, b)
                XCTAssertEqual(
                    face.parameters.crestLean,
                    b.parameters.crestLean,
                    accuracy: 0.02,
                    "\(a) -> \(b)"
                )
            }
        }
    }

    /// The blink is the one fast thing on the face, and it still takes more than one frame.
    func testBlinkTakesLongerThanAFrame() {
        XCTAssertGreaterThan(FaceController.blinkCloseDuration, frame * 2)
        XCTAssertGreaterThan(FaceController.blinkOpenDuration, frame * 2)
    }

    // MARK: Beak

    func testBeakClosesWithin120msOfTheLastToken() {
        var face = FaceController()
        face.noteToken(amplitude: 1.0)
        face.update(deltaTime: frame)
        XCTAssertGreaterThan(face.parameters.beakOpen, 0.1)

        var elapsed: Float = 0
        while elapsed < FaceController.beakCloseDuration {
            face.update(deltaTime: frame)
            elapsed += frame
        }
        XCTAssertEqual(face.parameters.beakOpen, 0, accuracy: 1e-5)
        XCTAssertFalse(face.isBeakSpeaking)
    }

    func testBeakDoesNotMoveWithoutSpeech() {
        var face = FaceController()
        for _ in 0..<200 {
            face.update(deltaTime: frame)
            XCTAssertEqual(face.parameters.beakOpen, 0, accuracy: 1e-6)
        }
    }

    func testBeakTracksSpeechAmplitude() {
        var face = FaceController()
        face.noteToken(amplitude: 0.3)
        face.update(deltaTime: frame)
        let quiet = face.parameters.beakOpen
        face.noteToken(amplitude: 1.0)
        face.update(deltaTime: frame)
        XCTAssertGreaterThan(face.parameters.beakOpen, quiet)
    }

    func testInterruptedSpeechDropsTheBeakImmediately() {
        var face = FaceController()
        face.noteToken(amplitude: 1.0)
        face.update(deltaTime: frame)
        face.silence()
        face.update(deltaTime: frame)
        XCTAssertEqual(face.parameters.beakOpen, 0, accuracy: 1e-6)
    }

    // MARK: Blink

    func testBlinkTimingIsAsymmetric() {
        XCTAssertNotEqual(FaceController.blinkCloseDuration, FaceController.blinkOpenDuration)
        XCTAssertLessThan(FaceController.blinkCloseDuration, FaceController.blinkOpenDuration)
    }

    func testBlinksHappenAndFullyReopen() {
        var face = FaceController()
        var minimumEye: Float = 1
        var elapsed: Float = 0
        while elapsed < 12 {
            face.update(deltaTime: frame)
            minimumEye = min(minimumEye, face.parameters.eyeOpen)
            elapsed += frame
        }
        XCTAssertLessThan(minimumEye, 0.2, "never blinked")
        // And it is open again by the end of the window.
        XCTAssertGreaterThan(face.parameters.eyeOpen, 0.5)
    }

    func testNoBlinkingWhileThinking() {
        var face = FaceController()
        face.set(.thinking)
        for _ in 0..<60 { face.update(deltaTime: frame) }
        var minimumEye: Float = 1
        var elapsed: Float = 0
        while elapsed < 20 {
            face.update(deltaTime: frame)
            minimumEye = min(minimumEye, face.parameters.eyeOpen)
            elapsed += frame
        }
        XCTAssertGreaterThan(minimumEye, 0.5, "blinked while thinking")
    }

    func testBlinkIntervalStaysInTheSpecRange() {
        var face = FaceController(seed: 12345)
        var gaps: [Float] = []
        var sinceBlink: Float = 0
        var wasOpen = true
        var elapsed: Float = 0
        while elapsed < 60 {
            face.update(deltaTime: frame)
            elapsed += frame
            sinceBlink += frame
            let open = face.parameters.eyeOpen > 0.5
            if wasOpen, !open {
                gaps.append(sinceBlink)
                sinceBlink = 0
            }
            wasOpen = open
        }
        XCTAssertGreaterThan(gaps.count, 5)
        for gap in gaps.dropFirst() {
            XCTAssertGreaterThan(gap, FaceController.blinkIntervalRange.lowerBound - 0.5)
            XCTAssertLessThan(gap, FaceController.blinkIntervalRange.upperBound + 1.0)
        }
    }

    func testBlinkJitterIsNotAMetronome() {
        var face = FaceController(seed: 99)
        var gaps: Set<Int> = []
        var sinceBlink: Float = 0
        var wasOpen = true
        var elapsed: Float = 0
        while elapsed < 90 {
            face.update(deltaTime: frame)
            elapsed += frame
            sinceBlink += frame
            let open = face.parameters.eyeOpen > 0.5
            if wasOpen, !open {
                gaps.insert(Int(sinceBlink * 10))
                sinceBlink = 0
            }
            wasOpen = open
        }
        XCTAssertGreaterThan(gaps.count, 3, "blink interval is fixed")
    }

    func testAlertDoubleBlinks() {
        var face = FaceController()
        face.set(.alert)
        var blinks = 0
        var wasOpen = true
        var elapsed: Float = 0
        while elapsed < 2.0 {
            face.update(deltaTime: frame)
            elapsed += frame
            let open = face.parameters.eyeOpen > 0.5
            if wasOpen, !open { blinks += 1 }
            wasOpen = open
        }
        XCTAssertGreaterThanOrEqual(blinks, 2, "surprise did not double blink")
    }
}
