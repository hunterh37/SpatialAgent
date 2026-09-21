import SpatialMemory
import XCTest
import simd
@testable import CharacterKit

/// When an idle bird walks home (spec 07 §Learned behavior).
final class IdleReturnTests: XCTestCase {
    private let away = SIMD3<Float>(2, 0, 0)
    private let perch = SIMD3<Float>(0, 0, 0)

    func testReturnsOnceItHasBeenIdleLongEnough() {
        XCTAssertTrue(
            IdleReturn.shouldReturn(
                isIdle: true,
                idleFor: IdleReturn.settleDelay,
                characterPosition: away,
                perch: perch
            )
        )
    }

    func testDoesNotReturnBeforeTheSettleDelay() {
        XCTAssertFalse(
            IdleReturn.shouldReturn(
                isIdle: true,
                idleFor: IdleReturn.settleDelay - 0.1,
                characterPosition: away,
                perch: perch
            )
        )
    }

    func testDoesNotReturnWhileBusy() {
        XCTAssertFalse(
            IdleReturn.shouldReturn(
                isIdle: false,
                idleFor: 600,
                characterPosition: away,
                perch: perch
            )
        )
    }

    /// Already home. Without this the bird re-paths every frame after it arrives.
    func testDoesNotReturnWhenAlreadyOnThePerch() {
        XCTAssertFalse(
            IdleReturn.shouldReturn(
                isIdle: true,
                idleFor: 600,
                characterPosition: SIMD3(0, 1.2, IdleReturn.arrivalRadius - 0.05),
                perch: perch
            )
        )
    }

    func testDoesNothingWithNoTaughtPerch() {
        XCTAssertFalse(
            IdleReturn.shouldReturn(
                isIdle: true,
                idleFor: 600,
                characterPosition: away,
                perch: nil
            )
        )
    }

    /// Height is ignored: a shelf perch is the same spot as the floor under it.
    func testDistanceIsPlanar() {
        XCTAssertEqual(
            IdleReturn.planarDistance(SIMD3(0, 3, 0), SIMD3(0, 0, 0)),
            0,
            accuracy: 1e-5
        )
    }

    func testTheMapOverloadTargetsTheTaughtHomePerch() {
        var map = SemanticMap(roomId: "idle")
        map.upsert(Place(name: "the desk", position: SIMD3(0, 0, 0), kind: .surface))
        // No perch taught yet: idling must not send the bird to whatever place exists.
        XCTAssertFalse(
            IdleReturn.shouldReturn(
                isIdle: true,
                idleFor: IdleReturn.settleDelay,
                characterPosition: SIMD3(0, 0, 4),
                map: map
            )
        )

        map.upsert(Place(name: "the red perch", position: SIMD3(0, 1, 0), kind: .perch))
        XCTAssertTrue(
            IdleReturn.shouldReturn(
                isIdle: true,
                idleFor: IdleReturn.settleDelay,
                characterPosition: SIMD3(0, 1, 4),
                map: map
            )
        )
    }
}
