import XCTest
import simd
@testable import CharacterKit

/// Spec 06 §Locomotion. The first test is the one that matters: foot-sliding is the single
/// most visible failure mode in the spec, and it is asserted here frame by frame rather than
/// left to on-device inspection.
final class HopControllerTests: XCTestCase {
    private let frame: Float = 1.0 / 90.0

    private func straightPath(length: Float, steps: Int = 6) -> [SIMD3<Float>] {
        (1...steps).map { SIMD3(0, 0, length * Float($0) / Float(steps)) }
    }

    /// Runs a full path and hands every frame to the caller.
    private func run(
        _ controller: inout HopController,
        path: [SIMD3<Float>],
        maxSeconds: Float = 40,
        frame: Float? = nil,
        body: (inout HopController, [HopController.Event]) -> Void
    ) {
        let dt = frame ?? self.frame
        controller.follow(path: path)
        var elapsed: Float = 0
        while controller.isMoving, elapsed < maxSeconds {
            let events = controller.update(deltaTime: dt)
            elapsed += dt
            body(&controller, events)
        }
        XCTAssertLessThan(elapsed, maxSeconds, "path never completed")
    }

    // MARK: The property

    func testFeetNeverMoveHorizontallyWhileGrounded() {
        var controller = HopController()
        var previous: [Bool: SIMD3<Float>] = [
            true: controller.footPosition(left: true),
            false: controller.footPosition(left: false),
        ]
        var wasGrounded = controller.isGrounded
        var groundedFrames = 0

        run(&controller, path: straightPath(length: 1.2)) { controller, _ in
            for left in [true, false] {
                let now = controller.footPosition(left: left)
                if wasGrounded, controller.isGrounded {
                    let slide = simd_length(
                        SIMD3(now.x - previous[left]!.x, 0, now.z - previous[left]!.z)
                    )
                    XCTAssertEqual(slide, 0, accuracy: 1e-6, "foot slid while grounded")
                }
                previous[left] = now
            }
            if controller.isGrounded { groundedFrames += 1 }
            wasGrounded = controller.isGrounded
        }

        // A path that never touches down would pass the assertion vacuously.
        XCTAssertGreaterThan(groundedFrames, 20)
    }

    /// Same property at a dropped frame rate, where a naive integrator skips the landing.
    func testFeetNeverSlideAt30fps() {
        var controller = HopController()
        var previous = controller.footPosition(left: true)
        var wasGrounded = controller.isGrounded
        run(&controller, path: straightPath(length: 1.0), frame: 1.0 / 30.0) { controller, _ in
            let now = controller.footPosition(left: true)
            if wasGrounded, controller.isGrounded {
                let slide = simd_length(SIMD3(now.x - previous.x, 0, now.z - previous.z))
                XCTAssertEqual(slide, 0, accuracy: 1e-6)
            }
            previous = now
            wasGrounded = controller.isGrounded
        }
    }

    func testFeetAreOnTheFloorWheneverGrounded() {
        var controller = HopController()
        let proportions = BirdProportions()
        let expected = proportions.footHeight / 2 * proportions.normalizationScale
        run(&controller, path: straightPath(length: 0.8)) { controller, _ in
            guard controller.isGrounded else { return }
            XCTAssertEqual(controller.footPosition(left: true).y, expected, accuracy: 1e-6)
        }
    }

    // MARK: Arc

    func testHopArcMatchesTheSpec() {
        var controller = HopController()
        controller.follow(path: [SIMD3(0, 0, 0.5)])
        var peak: Float = 0
        var airborneTime: Float = 0
        var landed = false
        while !landed {
            let events = controller.update(deltaTime: 1.0 / 240.0)
            if controller.phase == .airborne {
                airborneTime += 1.0 / 240.0
                peak = max(peak, controller.bobHeight)
            }
            landed = events.contains(.landed)
        }
        XCTAssertEqual(peak, HopController.hopPeak, accuracy: 0.002)
        XCTAssertEqual(airborneTime, HopController.hopDuration, accuracy: 0.01)
    }

    func testOneHopCoversNineCentimetres() {
        var controller = HopController()
        controller.follow(path: [SIMD3(0, 0, 0.5)])
        var landed = false
        while !landed { landed = controller.update(deltaTime: frame).contains(.landed) }
        XCTAssertEqual(controller.position.z, HopController.hopDistance, accuracy: 0.002)
    }

    func testBobHeightIsZeroOnEveryGroundedFrame() {
        var controller = HopController()
        run(&controller, path: straightPath(length: 0.6)) { controller, _ in
            if controller.isGrounded { XCTAssertEqual(controller.bobHeight, 0, accuracy: 1e-6) }
        }
    }

    func testAnticipationPrecedesEveryTakeoff() {
        var controller = HopController()
        var sawAnticipation = false
        var takeoffs = 0
        var landings = 0
        run(&controller, path: straightPath(length: 0.5)) { controller, events in
            if events.contains(.takeoffAnticipated) {
                sawAnticipation = true
                takeoffs += 1
            }
            if events.contains(.landed) {
                landings += 1
                XCTAssertTrue(sawAnticipation, "landed without anticipating")
            }
        }
        XCTAssertGreaterThan(takeoffs, 1)
        XCTAssertEqual(takeoffs, landings)
    }

    func testAnticipationDipsWithoutMovingHorizontally() {
        var controller = HopController()
        controller.follow(path: [SIMD3(0, 0, 0.5)])
        var sawDip = false
        while controller.phase != .airborne {
            _ = controller.update(deltaTime: frame)
            if controller.phase == .anticipating {
                // The crouch drops the body, never the feet.
                XCTAssertEqual(controller.bobHeight, 0, accuracy: 1e-6)
                XCTAssertEqual(controller.position.x, 0, accuracy: 1e-6)
                XCTAssertEqual(controller.position.z, 0, accuracy: 1e-6)
                if controller.bodyDip < -0.001 { sawDip = true }
            }
        }
        XCTAssertTrue(sawDip)
    }

    // MARK: Wings and tail

    func testWingsGoOutAndBackOnEveryHop() {
        var controller = HopController()
        var peak: Float = 0
        run(&controller, path: straightPath(length: 0.4)) { controller, events in
            peak = max(peak, controller.wingExtension)
            if events.contains(.landed) {
                XCTAssertEqual(controller.wingExtension, 0, accuracy: 1e-5, "wings stayed out")
                XCTAssertGreaterThan(peak, 0.8)
                peak = 0
            }
        }
    }

    func testTailCounterRotatesAgainstTheArc() {
        var controller = HopController()
        controller.follow(path: [SIMD3(0, 0, 0.5)])
        var checked = false
        while !checked {
            _ = controller.update(deltaTime: frame)
            if controller.phase == .airborne, controller.bobHeight > 0.02 {
                // Body up, tail down.
                XCTAssertLessThan(controller.tailPitch, 0)
                checked = true
            }
        }
    }

    // MARK: Glide

    func testLongPathsGlide() {
        var controller = HopController()
        var glided = false
        run(&controller, path: straightPath(length: 4.0, steps: 8), maxSeconds: 80) { c, _ in
            if c.phase == .gliding { glided = true }
        }
        XCTAssertTrue(glided)
    }

    func testShortPathsNeverGlide() {
        var controller = HopController()
        run(&controller, path: straightPath(length: 0.5)) { controller, _ in
            XCTAssertNotEqual(controller.phase, .gliding)
        }
    }

    func testGlideStopsBeforeTheLastMetreAndAHalf() {
        var controller = HopController()
        run(&controller, path: straightPath(length: 4.0, steps: 8), maxSeconds: 80) { c, _ in
            if c.phase == .gliding {
                XCTAssertGreaterThan(c.remainingDistance, HopController.glideThreshold - 0.3)
            }
        }
    }

    // MARK: Path handling

    func testPathCompletesAtTheDestination() {
        var controller = HopController()
        let path = straightPath(length: 0.9)
        var completed = false
        run(&controller, path: path) { _, events in
            if events.contains(.pathCompleted) { completed = true }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(controller.position.z, path.last!.z, accuracy: 0.03)
        XCTAssertFalse(controller.isMoving)
    }

    /// An unreachable walk fails to idle; it never partially hops toward a wall.
    func testEmptyPathIsRejectedRatherThanFollowed() {
        var controller = HopController()
        XCTAssertEqual(controller.follow(path: []), .pathRejected)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.position, .zero)
    }

    func testPathToWhereTheBirdAlreadyStandsIsRejected() {
        var controller = HopController()
        controller.place(at: SIMD3(1, 0, 1))
        XCTAssertEqual(controller.follow(path: [SIMD3(1, 0, 1)]), .pathRejected)
        XCTAssertFalse(controller.isMoving)
    }

    func testTurningHappensOnTheGroundNotInTheAir() {
        var controller = HopController()
        var yawWhileAirborne: Float?
        run(&controller, path: [SIMD3(0.6, 0, 0.0), SIMD3(0.6, 0, 0.6)]) { controller, _ in
            guard !controller.isGrounded else {
                yawWhileAirborne = nil
                return
            }
            if let recorded = yawWhileAirborne {
                XCTAssertEqual(controller.yaw, recorded, accuracy: 1e-6)
            }
            yawWhileAirborne = controller.yaw
        }
    }

    func testStopClearsEverything() {
        var controller = HopController()
        controller.follow(path: straightPath(length: 1.0))
        _ = controller.update(deltaTime: 0.3)
        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.bobHeight, 0)
        XCTAssertEqual(controller.wingExtension, 0)
        XCTAssertFalse(controller.isMoving)
    }

    func testLandingYComesFromThePathNotTheArc() {
        var controller = HopController()
        controller.follow(path: [SIMD3(0, 0.12, 0.4)])
        var landed = false
        while !landed { landed = controller.update(deltaTime: frame).contains(.landed) }
        XCTAssertEqual(controller.position.y, 0.12, accuracy: 1e-5)
    }
}
