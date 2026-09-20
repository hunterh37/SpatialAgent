import XCTest
import simd
@testable import CharacterKit

/// Spec 06 §Attention.
final class AttentionTests: XCTestCase {
    private let frame: Float = 1.0 / 90.0
    private let origin = SIMD3<Float>(0, 0, 0)

    private func settled(target: SIMD3<Float>, bodyYaw: Float = 0) -> AttentionController {
        var attention = AttentionController()
        attention.target = target
        for _ in 0..<180 { attention.update(deltaTime: frame, origin: origin, bodyYaw: bodyYaw) }
        return attention
    }

    // MARK: Limits

    func testHeadYawNeverExceedsTheLimit() {
        for angle in stride(from: -Float.pi, through: Float.pi, by: 0.1) {
            var attention = AttentionController()
            attention.target = SIMD3(sin(angle) * 2, 0, cos(angle) * 2)
            for _ in 0..<200 {
                attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
                XCTAssertLessThanOrEqual(abs(attention.headYaw), AttentionController.maxHeadYaw)
            }
        }
    }

    func testHeadPitchNeverExceedsTheLimit() {
        for height in stride(from: Float(-3), through: 3, by: 0.25) {
            var attention = AttentionController()
            attention.target = SIMD3(0, height, 0.3)
            for _ in 0..<200 {
                attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
                XCTAssertLessThanOrEqual(abs(attention.headPitch), AttentionController.maxHeadPitch)
            }
        }
    }

    func testHeadReachesATargetInsideTheLimits() {
        let attention = settled(target: SIMD3(1, 0, 1))
        XCTAssertEqual(attention.headYaw, .pi / 4, accuracy: 0.01)
        XCTAssertFalse(attention.isAtYawLimit)
    }

    func testHeadPinsAtTheLimitRatherThanCentringWhenTheTargetIsBehind() {
        let attention = settled(target: SIMD3(0, 0, -2))
        XCTAssertTrue(attention.isAtYawLimit)
        XCTAssertEqual(abs(attention.headYaw), AttentionController.maxHeadYaw, accuracy: 1e-4)
    }

    func testYawIsRelativeToTheBody() {
        let attention = settled(target: SIMD3(2, 0, 0), bodyYaw: .pi / 2)
        // The target is straight ahead once the body has turned.
        XCTAssertEqual(attention.headYaw, 0, accuracy: 0.01)
    }

    // MARK: Ordering

    /// Eyes lead the head. Measured as the time each takes to cover half the move.
    func testEyesReachHalfwayBeforeTheHead() {
        var attention = AttentionController()
        attention.target = SIMD3(1, 0, 1)
        let goal = Float.pi / 4
        var eyeHalfway: Float?
        var headHalfway: Float?
        var elapsed: Float = 0
        while elapsed < 1.0 {
            attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
            elapsed += frame
            // The pupil residual collapses as the head catches up; the eye is "there" as soon
            // as head + residual covers the move.
            let eyeAngle = attention.headYaw
                + attention.pupilOffset.x * AttentionController.maxHeadYaw * 0.35
            if eyeHalfway == nil, eyeAngle >= goal / 2 { eyeHalfway = elapsed }
            if headHalfway == nil, attention.headYaw >= goal / 2 { headHalfway = elapsed }
        }
        XCTAssertNotNil(eyeHalfway)
        XCTAssertNotNil(headHalfway)
        XCTAssertLessThan(eyeHalfway!, headHalfway!)
    }

    /// The head trails by the spec's 80–140ms.
    func testHeadLagIsInTheSpecWindow() {
        var attention = AttentionController()
        attention.target = SIMD3(1, 0, 1)
        let goal = Float.pi / 4
        var elapsed: Float = 0
        var lag: Float?
        while elapsed < 1.0, lag == nil {
            attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
            elapsed += frame
            if attention.headYaw >= goal / 2 { lag = elapsed }
        }
        XCTAssertNotNil(lag)
        XCTAssertGreaterThanOrEqual(lag!, 0.08)
        XCTAssertLessThanOrEqual(lag!, 0.14)
    }

    func testPupilsCarryTheResidualAndThenCentre() {
        var attention = AttentionController()
        attention.target = SIMD3(1, 0, 1)
        var peak: Float = 0
        for _ in 0..<20 {
            attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
            peak = max(peak, abs(attention.pupilOffset.x))
        }
        XCTAssertGreaterThan(peak, 0.1, "pupils never led")
        for _ in 0..<200 { attention.update(deltaTime: frame, origin: origin, bodyYaw: 0) }
        XCTAssertEqual(attention.pupilOffset.x, 0, accuracy: 0.02)
    }

    func testPupilOffsetStaysOnTheSclera() {
        for angle in stride(from: -Float.pi, through: Float.pi, by: 0.2) {
            var attention = AttentionController()
            attention.target = SIMD3(sin(angle) * 2, 1.5, cos(angle) * 2)
            for _ in 0..<120 {
                attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
                XCTAssertLessThanOrEqual(abs(attention.pupilOffset.x), 1.0)
                XCTAssertLessThanOrEqual(abs(attention.pupilOffset.y), 1.0)
            }
        }
    }

    // MARK: The double-take

    func testBodyTurnIsRequestedOnlyAfterTheDelay() {
        var attention = AttentionController()
        attention.target = SIMD3(0, 0, -2)
        var elapsed: Float = 0
        var requestedAt: Float?
        while elapsed < 1.0 {
            attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
            elapsed += frame
            if attention.bodyTurnRequest != nil, requestedAt == nil { requestedAt = elapsed }
        }
        XCTAssertNotNil(requestedAt)
        XCTAssertGreaterThanOrEqual(requestedAt!, AttentionController.bodyTurnDelay - frame)
        XCTAssertLessThan(requestedAt!, AttentionController.bodyTurnDelay + 0.05)
    }

    func testNoBodyTurnForATargetTheHeadCanReach() {
        var attention = AttentionController()
        attention.target = SIMD3(1, 0, 1)
        for _ in 0..<200 {
            attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
            XCTAssertNil(attention.bodyTurnRequest)
        }
    }

    func testBodyTurnRequestPointsAtTheTarget() {
        var attention = AttentionController()
        attention.target = SIMD3(0, 0, -2)
        for _ in 0..<60 { attention.update(deltaTime: frame, origin: origin, bodyYaw: 0) }
        let request = try? XCTUnwrap(attention.bodyTurnRequest)
        XCTAssertEqual(abs(AngularSpring.shortest(from: request ?? 0, to: .pi)), 0, accuracy: 0.01)
    }

    func testTurningTheBodyEndsTheDoubleTake() {
        var attention = AttentionController()
        attention.target = SIMD3(0, 0, -2)
        for _ in 0..<60 { attention.update(deltaTime: frame, origin: origin, bodyYaw: 0) }
        XCTAssertNotNil(attention.bodyTurnRequest)
        attention.bodyTurnServed()
        // Body now faces the target; nothing more is asked for.
        for _ in 0..<60 { attention.update(deltaTime: frame, origin: origin, bodyYaw: .pi) }
        XCTAssertNil(attention.bodyTurnRequest)
        XCTAssertEqual(attention.headYaw, 0, accuracy: 0.05)
    }

    func testABriefGlanceBehindDoesNotTurnTheBody() {
        var attention = AttentionController()
        attention.target = SIMD3(0, 0, -2)
        for _ in 0..<10 { attention.update(deltaTime: frame, origin: origin, bodyYaw: 0) }
        attention.target = SIMD3(0, 0, 2)
        for _ in 0..<60 {
            attention.update(deltaTime: frame, origin: origin, bodyYaw: 0)
            XCTAssertNil(attention.bodyTurnRequest)
        }
    }

    // MARK: Independence from locomotion

    /// The bird has to be able to watch the user while hopping away.
    func testHeadKeepsTrackingWhileAHopPathIsActive() {
        var hop = HopController()
        var attention = AttentionController()
        let user = SIMD3<Float>(0, 1.4, -1.0)
        attention.target = user
        hop.follow(path: [SIMD3(0, 0, 1.2)])

        var sawAirborneTracking = false
        var elapsed: Float = 0
        while hop.isMoving, elapsed < 30 {
            _ = hop.update(deltaTime: frame)
            attention.update(deltaTime: frame, origin: hop.position, bodyYaw: hop.yaw)
            elapsed += frame
            // Head is always pointed as far toward the user as the limit allows, in the air
            // and on the ground alike.
            XCTAssertLessThanOrEqual(abs(attention.headYaw), AttentionController.maxHeadYaw)
            if !hop.isGrounded, attention.isAtYawLimit { sawAirborneTracking = true }
        }
        XCTAssertTrue(sawAirborneTracking, "attention stopped mid-hop")
    }

    func testAttentionNeverWritesToLocomotion() {
        var hop = HopController()
        var attention = AttentionController()
        attention.target = SIMD3(0, 0, -5)
        hop.place(at: SIMD3(0, 0, 0))
        for _ in 0..<200 {
            attention.update(deltaTime: frame, origin: hop.position, bodyYaw: hop.yaw)
        }
        // A body-turn request is an ask, not a move.
        XCTAssertNotNil(attention.bodyTurnRequest)
        XCTAssertEqual(hop.yaw, 0)
        XCTAssertEqual(hop.position, .zero)
    }

    // MARK: Reset

    func testResetClearsEverything() {
        var attention = settled(target: SIMD3(0, 0, -2))
        attention.reset()
        XCTAssertEqual(attention.headYaw, 0)
        XCTAssertEqual(attention.pupilOffset, .zero)
        XCTAssertNil(attention.bodyTurnRequest)
    }

    func testNoTargetParksTheHeadForward() {
        var attention = settled(target: SIMD3(1, 0, 1))
        attention.target = nil
        for _ in 0..<200 { attention.update(deltaTime: frame, origin: origin, bodyYaw: 0) }
        XCTAssertEqual(attention.headYaw, 0, accuracy: 0.01)
        XCTAssertEqual(attention.headPitch, 0, accuracy: 0.01)
    }
}
