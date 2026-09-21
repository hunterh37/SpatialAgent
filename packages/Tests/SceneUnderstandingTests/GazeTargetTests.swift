import XCTest
import simd
@testable import SceneUnderstanding

/// Spec 07 §Capture.
@MainActor
final class GazeTargetTests: XCTestCase {
    private let down = SIMD3<Float>(0, -1, 0)
    private func eye(_ x: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, 1.5, z) }

    private func room() -> SyntheticSceneMesh { .room() }

    // MARK: Radius derivation per surface class

    func testLookingAtADeskCapturesTheDesksExtentNotAPoint() {
        let hit = try! XCTUnwrap(room().raycast(origin: eye(1.2, -1.0), direction: down))
        XCTAssertEqual(hit.surface, .surface)
        let target = GazeTarget(hit: hit)
        // 1.4m desk: radius covers it rather than inscribing a 10cm dot on it.
        XCTAssertEqual(target.radius, 0.7, accuracy: 1e-5)
    }

    func testAFloorHitAdoptsOneMetre() {
        let hit = try! XCTUnwrap(room().raycast(origin: eye(-1.5, 1.5), direction: down))
        XCTAssertEqual(hit.surface, .floor)
        XCTAssertEqual(GazeTarget(hit: hit).radius, GazeTarget.floorRadius, accuracy: 1e-5)
    }

    func testAnObjectClusterAdoptsItsBoundsPlusTenCentimetres() {
        let hit = try! XCTUnwrap(room().raycast(origin: eye(1.5, -1.0), direction: down))
        XCTAssertEqual(hit.surface, .objectCluster)
        // 0.3m across: 0.15 + 0.10.
        XCTAssertEqual(GazeTarget(hit: hit).radius, 0.25, accuracy: 1e-5)
    }

    func testSurfaceRadiusIsClampedAtBothEnds() {
        let tiny = GazeHit(point: .zero, extent: SIMD2(0.2, 0.2), surface: .surface)
        XCTAssertEqual(GazeTarget.radius(for: tiny), 0.3, accuracy: 1e-5)

        let huge = GazeHit(point: .zero, extent: SIMD2(9, 9), surface: .surface)
        XCTAssertEqual(GazeTarget.radius(for: huge), 2.0, accuracy: 1e-5)
    }

    func testEverySurfaceClassProducesAUsableRadius() {
        for surface in GazeSurfaceClass.allCases {
            let hit = GazeHit(point: .zero, extent: SIMD2(0.8, 0.5), surface: surface)
            XCTAssertGreaterThanOrEqual(GazeTarget.radius(for: hit), 0.1)
            XCTAssertLessThanOrEqual(GazeTarget.radius(for: hit), 2.0)
        }
    }

    func testTheNearestThingAlongTheRayWins() {
        // The coffee machine stands on the desk; looking at it must not capture the desk.
        let hit = try! XCTUnwrap(room().raycast(origin: eye(1.5, -1.0), direction: down))
        XCTAssertEqual(hit.surface, .objectCluster)
        XCTAssertEqual(hit.point.y, 0.92 + 0.36, accuracy: 1e-5)
    }

    func testARayThatHitsNothingReturnsNil() {
        XCTAssertNil(room().raycast(origin: eye(9, 9), direction: down))
        XCTAssertNil(room().raycast(origin: eye(0, 0), direction: SIMD3(0, 1, 0)))
    }

    // MARK: Hold from utterance start

    func testTheHeldTargetIsTheUtteranceStartTargetNotTheEndOne() {
        let capture = GazeCapture(caster: room())
        // "this is my desk" — the user starts looking at the desk...
        let started = capture.beginUtterance(origin: eye(1.2, -1.0), direction: down)
        XCTAssertEqual(started?.surface, .surface)

        // ...and by the end of the sentence they are looking at the floor across the room.
        let atEnd = capture.target()
        XCTAssertEqual(atEnd?.surface, .surface, "the act captured where the user looked away to")
        XCTAssertEqual(atEnd?.point, started?.point)
    }

    func testTheTargetIsHeldForTheWholeActNotReCast() {
        let mesh = room()
        let capture = GazeCapture(caster: mesh)
        capture.beginUtterance(origin: eye(1.2, -1.0), direction: down)
        // The room changes mid-sentence; the held target does not.
        mesh.targets = []
        XCTAssertNotNil(capture.target())
        XCTAssertEqual(capture.target()?.surface, .surface)
    }

    func testEndingTheActReleasesTheHold() {
        let capture = GazeCapture(caster: room())
        capture.beginUtterance(origin: eye(1.2, -1.0), direction: down)
        capture.endAct()
        XCTAssertNil(capture.target())
    }

    // MARK: No valid hit

    func testNoValidHitAsksRatherThanGuessing() {
        let capture = GazeCapture(caster: room())
        let target = capture.beginUtterance(origin: eye(9, 9), direction: down)
        XCTAssertNil(target, "a miss must not invent a target")
        XCTAssertTrue(capture.isAwaitingFollowUp)
    }

    func testTheActStaysOpenForOneFollowUpTurn() {
        let capture = GazeCapture(caster: room())
        capture.beginUtterance(origin: eye(9, 9), direction: down)
        let resolved = capture.resolveFollowUp(origin: eye(1.2, -1.0), direction: down)
        XCTAssertEqual(resolved?.surface, .surface)
        XCTAssertFalse(capture.isAwaitingFollowUp)
    }

    func testAFollowUpWithNothingPendingDoesNotReCapture() {
        let capture = GazeCapture(caster: room())
        capture.beginUtterance(origin: eye(1.2, -1.0), direction: down)
        let same = capture.resolveFollowUp(origin: eye(-1.5, 1.5), direction: down)
        XCTAssertEqual(same?.surface, .surface, "a held target must not be silently replaced")
    }

    func testNoCasterAtAllIsAMissNotACrash() {
        let capture = GazeCapture(caster: nil)
        XCTAssertNil(capture.beginUtterance(origin: eye(0, 0), direction: down))
        XCTAssertTrue(capture.isAwaitingFollowUp)
    }
}
