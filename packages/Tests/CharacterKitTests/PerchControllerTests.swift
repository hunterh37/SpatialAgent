import XCTest
import SceneUnderstanding
import simd
@testable import CharacterKit

final class PerchControllerTests: XCTestCase {
    private func palm(at p: SIMD3<Float>, yaw: Float = 0) -> PalmPose {
        PalmPose(center: p, normal: SIMD3(0, 1, 0), landing: p, yaw: yaw, chirality: .right)
    }

    private func run(_ c: inout PerchController, seconds: Float, step: Float = 1.0 / 90) -> [PerchController.Event] {
        var events: [PerchController.Event] = []
        var t: Float = 0
        while t < seconds {
            events += c.update(deltaTime: step)
            t += step
        }
        return events
    }

    func testFlightReachesThePalmAndPerches() {
        var c = PerchController()
        let target = SIMD3<Float>(0.3, 1.1, -0.5)
        XCTAssertEqual(c.offer(palm(at: target), currentPosition: .zero, currentYaw: 0), .tookOff)
        let events = run(&c, seconds: 3)
        XCTAssertTrue(events.contains(.landedOnHand))
        XCTAssertEqual(c.phase, .perched)
        XCTAssertEqual(simd_distance(c.position, target), 0, accuracy: 1e-3)
    }

    func testFlightArcsAboveTheStraightLine() {
        var c = PerchController()
        let target = SIMD3<Float>(1.5, 1.1, 0)
        _ = c.offer(palm(at: target), currentPosition: SIMD3(0, 1.1, 0), currentYaw: 0)
        var peak: Float = 0
        var t: Float = 0
        while t < 1.5 {
            _ = c.update(deltaTime: 1.0 / 90)
            peak = max(peak, c.position.y)
            t += 1.0 / 90
        }
        XCTAssertGreaterThan(peak, 1.1 + 0.05)
    }

    func testPerchFollowsAMovingHand() {
        var c = PerchController()
        _ = c.offer(palm(at: SIMD3(0, 1, 0)), currentPosition: .zero, currentYaw: 0)
        _ = run(&c, seconds: 3)
        XCTAssertEqual(c.phase, .perched)
        let moved = SIMD3<Float>(0.4, 1.2, 0.1)
        c.retarget(palm(at: moved))
        _ = run(&c, seconds: 0.6)
        XCTAssertEqual(simd_distance(c.position, moved), 0, accuracy: 0.01)
    }

    func testReleaseReturnsToTheFloorPoseItLeft() {
        var c = PerchController()
        let home = SIMD3<Float>(1, 0, 1)
        _ = c.offer(palm(at: SIMD3(0.5, 1.1, 0.5)), currentPosition: home, currentYaw: 0.7)
        _ = run(&c, seconds: 3)
        c.release()
        let events = run(&c, seconds: 3)
        XCTAssertTrue(events.contains(.landedOnFloor))
        XCTAssertEqual(c.phase, .grounded)
        XCTAssertFalse(c.isEngaged)
        XCTAssertEqual(simd_distance(c.position, home), 0, accuracy: 1e-3)
    }

    func testOutOfReachPalmIsRejectedAndNeverEngages() {
        var c = PerchController()
        let far = SIMD3<Float>(0, 1, -10)
        XCTAssertEqual(c.offer(palm(at: far), currentPosition: .zero, currentYaw: 0), .offerRejected)
        XCTAssertEqual(c.phase, .grounded)
        XCTAssertFalse(c.isEngaged)
    }

    func testRetargetDoesNotRestartTheFlight() {
        var c = PerchController()
        _ = c.offer(palm(at: SIMD3(0, 1, -1)), currentPosition: .zero, currentYaw: 0)
        _ = run(&c, seconds: 0.5)
        let progressed = c.position
        c.retarget(palm(at: SIMD3(0.02, 1, -1)))
        _ = c.update(deltaTime: 1.0 / 90)
        // A restart would snap back toward the origin; a retarget moves on from here.
        XCTAssertLessThan(simd_distance(c.position, progressed), 0.05)
    }

    func testYawTakesTheShortWayRound() {
        XCTAssertEqual(PerchController.shortestAngle(from: 3.0, to: -3.0), 0.283, accuracy: 0.01)
        XCTAssertEqual(PerchController.shortestAngle(from: -3.0, to: 3.0), -0.283, accuracy: 0.01)
    }
}
