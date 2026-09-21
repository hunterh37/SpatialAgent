import XCTest
import simd
@testable import SceneUnderstanding

final class PalmDetectorTests: XCTestCase {
    /// A right hand held flat, palm up, fingers pointing -Z.
    private func rightPalmUp(
        origin: SIMD3<Float> = SIMD3(0.2, 1.0, -0.4)
    ) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let wrist = origin
        let middle = origin + SIMD3(0, 0, -0.09)
        // Thumb side of a supinated right hand is +X, so the index knuckle is at +X.
        let index = origin + SIMD3(0.04, 0, -0.085)
        let little = origin + SIMD3(-0.04, 0, -0.085)
        return (wrist, index, little, middle)
    }

    func testPalmUpIsDetected() {
        let (wrist, index, little, middle) = rightPalmUp()
        let pose = PalmDetector.evaluate(
            wrist: wrist, indexKnuckle: index, littleKnuckle: little,
            middleKnuckle: middle, chirality: .right
        )
        let unwrapped = try? XCTUnwrap(pose)
        XCTAssertNotNil(unwrapped)
        guard let pose = unwrapped else { return }
        XCTAssertGreaterThan(pose.normal.y, 0.9)
        // Landing sits above the skin, never in it.
        XCTAssertGreaterThan(pose.landing.y, pose.center.y)
        XCTAssertEqual(simd_length(pose.normal), 1, accuracy: 1e-4)
    }

    func testPalmDownIsRejected() {
        // Mirroring index and little flips the winding, which is a palm facing the floor.
        let (wrist, index, little, middle) = rightPalmUp()
        XCTAssertNil(
            PalmDetector.evaluate(
                wrist: wrist, indexKnuckle: little, littleKnuckle: index,
                middleKnuckle: middle, chirality: .right
            )
        )
    }

    func testLeftAndRightBothReadUp() {
        let (wrist, index, little, middle) = rightPalmUp()
        let right = PalmDetector.evaluate(
            wrist: wrist, indexKnuckle: index, littleKnuckle: little,
            middleKnuckle: middle, chirality: .right
        )
        // Same physical gesture on the other hand mirrors the knuckle order.
        let left = PalmDetector.evaluate(
            wrist: wrist, indexKnuckle: little, littleKnuckle: index,
            middleKnuckle: middle, chirality: .left
        )
        XCTAssertNotNil(right)
        XCTAssertNotNil(left)
        XCTAssertGreaterThan(left?.normal.y ?? 0, 0.9)
    }

    func testVerticalPalmIsRejected() {
        let wrist = SIMD3<Float>(0, 1, 0)
        let middle = wrist + SIMD3(0, 0.09, 0)
        let index = wrist + SIMD3(0, 0.085, -0.04)
        let little = wrist + SIMD3(0, 0.085, 0.04)
        XCTAssertNil(
            PalmDetector.evaluate(
                wrist: wrist, indexKnuckle: index, littleKnuckle: little,
                middleKnuckle: middle, chirality: .right
            )
        )
    }

    func testTinySpanIsRejectedAsTrackingNoise() {
        let wrist = SIMD3<Float>(0, 1, 0)
        let middle = wrist + SIMD3(0, 0, -0.01)
        let index = wrist + SIMD3(-0.005, 0, -0.01)
        let little = wrist + SIMD3(0.005, 0, -0.01)
        XCTAssertNil(
            PalmDetector.evaluate(
                wrist: wrist, indexKnuckle: index, littleKnuckle: little,
                middleKnuckle: middle, chirality: .right
            )
        )
    }

    func testGateRequiresDwellBeforeOffering() {
        let (wrist, index, little, middle) = rightPalmUp()
        let pose = PalmDetector.evaluate(
            wrist: wrist, indexKnuckle: index, littleKnuckle: little,
            middleKnuckle: middle, chirality: .right
        )!
        var gate = PalmGate()
        XCTAssertNil(gate.update(deltaTime: 0.1, candidate: pose))
        XCTAssertNil(gate.update(deltaTime: 0.1, candidate: pose))
        XCTAssertNotNil(gate.update(deltaTime: 0.2, candidate: pose))
        XCTAssertTrue(gate.isOffered)
        // A single dropped frame must not drop the bird off the hand.
        XCTAssertNotNil(gate.update(deltaTime: 0.05, candidate: nil))
        XCTAssertNil(gate.update(deltaTime: 0.3, candidate: nil))
        XCTAssertFalse(gate.isOffered)
    }
}
