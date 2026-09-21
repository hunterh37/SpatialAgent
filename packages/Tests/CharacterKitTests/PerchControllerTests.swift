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

/// Flying onto a perch object, and being swatted off it. A perch is not a hand: it does not
/// move, it is not withdrawn, and leaving it is something done *to* the bird.
final class PerchObjectTests: XCTestCase {
    private let bar = SIMD3<Float>(1.2, 1.0, -1.4)
    private let floor = SIMD3<Float>(1.2, 0, -1.4)

    private func palm(at p: SIMD3<Float>, yaw: Float = 0) -> PalmPose {
        PalmPose(center: p, normal: SIMD3(0, 1, 0), landing: p, yaw: yaw, chirality: .right)
    }

    private func run(
        _ c: inout PerchController,
        seconds: Float,
        step: Float = 1.0 / 90
    ) -> [PerchController.Event] {
        var events: [PerchController.Event] = []
        var t: Float = 0
        while t < seconds {
            events += c.update(deltaTime: step)
            t += step
        }
        return events
    }

    private func perched(_ id: UUID = UUID()) -> (PerchController, UUID) {
        var c = PerchController()
        c.flyTo(
            perch: bar, yaw: 0, placeId: id,
            currentPosition: .zero, currentYaw: 0, floorReturn: floor
        )
        _ = run(&c, seconds: 3)
        return (c, id)
    }

    func testHeFliesUpOntoThePerchAndStandsOnIt() {
        let id = UUID()
        var c = PerchController()
        XCTAssertEqual(
            c.flyTo(perch: bar, yaw: 0, placeId: id, currentPosition: .zero, currentYaw: 0),
            .tookOff
        )
        let events = run(&c, seconds: 3)

        XCTAssertTrue(events.contains(.landedOnPerch(id: id)))
        XCTAssertFalse(events.contains(.landedOnHand))
        XCTAssertEqual(simd_distance(c.position, bar), 0, accuracy: 1e-3)
        XCTAssertTrue(c.isPerchedOnObject)
        XCTAssertFalse(c.isPerched, "standing on furniture is not standing on a hand")
        XCTAssertEqual(c.perchedPlaceId, id)
    }

    /// Reach does not gate a perch: the bird crosses the room for one. Only a hand has to be
    /// close enough to be an invitation.
    func testAPerchAcrossTheRoomIsStillFlownTo() {
        var c = PerchController()
        let far = SIMD3<Float>(0, 1, -6)
        XCTAssertEqual(
            c.flyTo(perch: far, yaw: 0, placeId: nil, currentPosition: .zero, currentYaw: 0),
            .tookOff
        )
        _ = run(&c, seconds: 6)
        XCTAssertEqual(simd_distance(c.position, far), 0, accuracy: 1e-3)
    }

    /// The frame loop calls `release()` on every frame with no palm offered. A perch is
    /// furniture, so that must not drop him off it.
    func testNoPalmOfferedDoesNotPullHimOffAPerch() {
        var (c, _) = perched()
        for _ in 0 ..< 200 { c.release() }
        _ = run(&c, seconds: 1)
        XCTAssertTrue(c.isPerchedOnObject)
        XCTAssertEqual(simd_distance(c.position, bar), 0, accuracy: 1e-3)
    }

    /// A palm waved under a perched bird does not drag the perch around.
    func testAPalmCannotRetargetAPerchFlight() {
        var (c, _) = perched()
        c.retarget(
            PalmPose(
                center: .zero, normal: SIMD3(0, 1, 0), landing: SIMD3(-2, 1.4, 0),
                yaw: 0, chirality: .left
            )
        )
        _ = run(&c, seconds: 1)
        XCTAssertEqual(simd_distance(c.position, bar), 0, accuracy: 1e-3)
    }

    func testBeingKnockedOffEndsOnTheFloorUnderThePerch() {
        var (c, id) = perched()
        XCTAssertEqual(c.knockOff(force: 1, direction: SIMD3(1, 0, 0)), .knockedOff(id: id))
        XCTAssertEqual(c.phase, .falling)

        let events = run(&c, seconds: 1.5)
        XCTAssertTrue(events.contains(.landedOnFloor))
        XCTAssertEqual(c.phase, .grounded)
        XCTAssertFalse(c.isEngaged, "the ground controller owns him again")
        XCTAssertEqual(c.position.y, floor.y, accuracy: 1e-3)
        XCTAssertGreaterThan(c.position.x, floor.x, "thrown along the swipe")
        XCTAssertNil(c.perchedPlaceId)
        XCTAssertEqual(c.tumble, 0, "the tumble is cleared on landing, not left on the body")
    }

    func testHeTumblesOnTheWayDown() {
        var (c, _) = perched()
        c.knockOff(force: 1, direction: SIMD3(0, 0, 1))
        _ = run(&c, seconds: PerchController.fallDuration * 0.5)
        XCTAssertGreaterThan(c.tumble, 0)
        XCTAssertLessThan(c.position.y, 1.0)
    }

    /// A harder swipe throws him further. Anything else and force would be decoration.
    func testAHarderSwipeThrowsHimFurther() {
        var (soft, _) = perched()
        var (hard, _) = perched()
        soft.knockOff(force: 0.2, direction: SIMD3(1, 0, 0))
        hard.knockOff(force: 1, direction: SIMD3(1, 0, 0))
        _ = run(&soft, seconds: 1.5)
        _ = run(&hard, seconds: 1.5)
        XCTAssertGreaterThan(hard.position.x, soft.position.x)
    }

    func testAHandCannotBeKnockedOff() {
        var c = PerchController()
        let target = SIMD3<Float>(0.3, 1.1, -0.5)
        c.offer(
            PalmPose(center: target, normal: SIMD3(0, 1, 0), landing: target, yaw: 0,
                     chirality: .right),
            currentPosition: .zero,
            currentYaw: 0
        )
        _ = run(&c, seconds: 3)
        XCTAssertTrue(c.isPerched)
        XCTAssertNil(c.knockOff(), "a hand is withdrawn, not swatted")
    }

    func testKnockingAGroundedBirdIsNothing() {
        var c = PerchController()
        XCTAssertNil(c.knockOff())
        XCTAssertEqual(c.phase, .grounded)
    }

    // MARK: A hand outranks a pole

    private func onPole(_ c: inout PerchController) {
        _ = c.flyTo(perch: SIMD3(0, 1, -2), yaw: 0, placeId: UUID(),
                    currentPosition: SIMD3(0, 0, 0), currentYaw: 0,
                    floorReturn: SIMD3(0, 0, -2))
        _ = run(&c, seconds: 3)
    }

    func testAPalmOfferedWhilePerchedOnAPoleWins() {
        var c = PerchController()
        onPole(&c)
        XCTAssertTrue(c.isPerchedOnObject)

        let hand = SIMD3<Float>(0.4, 1.2, -0.6)
        XCTAssertEqual(c.offer(palm(at: hand), currentPosition: c.position, currentYaw: c.yaw), .tookOff)
        // It flies across from the crossbar rather than dropping to the floor first.
        XCTAssertEqual(c.position, SIMD3(0, 1, -2))

        let events = run(&c, seconds: 3)
        XCTAssertTrue(events.contains(.landedOnHand))
        XCTAssertTrue(c.isPerched)
        XCTAssertEqual(simd_distance(c.position, hand), 0, accuracy: 1e-3)
    }

    func testAPalmOfferedOutOfReachLeavesHimOnThePole() {
        var c = PerchController()
        onPole(&c)
        let far = SIMD3<Float>(0, 1, 6)

        XCTAssertEqual(c.offer(palm(at: far), currentPosition: c.position, currentYaw: c.yaw), .offerRejected)

        XCTAssertTrue(c.isPerchedOnObject)
        XCTAssertEqual(c.position, SIMD3(0, 1, -2))
    }

    /// Leaving the hand afterwards is a return to the floor, not to the pole he was taken off.
    func testReleaseAfterAPreemptingOfferReturnsToTheFloor() {
        var c = PerchController()
        onPole(&c)
        _ = c.offer(palm(at: SIMD3(0.4, 1.2, -0.6)), currentPosition: c.position, currentYaw: c.yaw)
        _ = run(&c, seconds: 3)

        c.release()
        let events = run(&c, seconds: 3)

        XCTAssertTrue(events.contains(.landedOnFloor))
        XCTAssertEqual(c.phase, .grounded)
        XCTAssertEqual(simd_distance(c.position, SIMD3(0, 0, -2)), 0, accuracy: 1e-3)
    }

    /// A flight to a pole is preemptible too, not just standing on one.
    func testAPalmOfferedMidFlightToAPoleWins() {
        var c = PerchController()
        _ = c.flyTo(perch: SIMD3(0, 1, -2), yaw: 0, placeId: nil,
                    currentPosition: .zero, currentYaw: 0, floorReturn: SIMD3(0, 0, -2))
        _ = run(&c, seconds: 0.5)
        XCTAssertEqual(c.phase, .flying)

        XCTAssertEqual(c.offer(palm(at: SIMD3(0.3, 1.1, -0.5)), currentPosition: c.position, currentYaw: c.yaw), .tookOff)
        _ = run(&c, seconds: 3)
        XCTAssertTrue(c.isPerched)
    }

    /// A knocked bird is not choosing anything, so the offer does not interrupt the fall.
    func testAPalmDoesNotInterruptAFall() {
        var c = PerchController()
        onPole(&c)
        _ = c.knockOff()
        XCTAssertEqual(c.phase, .falling)

        XCTAssertNil(c.offer(palm(at: SIMD3(0.2, 1, -1.9)), currentPosition: c.position, currentYaw: c.yaw))
        XCTAssertEqual(c.phase, .falling)
    }
}
