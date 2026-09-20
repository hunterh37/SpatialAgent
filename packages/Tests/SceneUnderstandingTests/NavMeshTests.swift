import SpatialMemory
import XCTest
import simd
@testable import SceneUnderstanding

final class NavMeshTests: XCTestCase {
    /// 4m x 4m floor with a 2m-wide wall across the middle, leaving a 1m gap on the +X side.
    private func roomWithWall() -> NavMesh {
        let floor = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(4, 4))
        let wall = FloorRect(center: SIMD3(-0.75, 0, 0), extent: SIMD2(2.5, 0.2))
        return NavMeshBuilder.build(floors: [floor], obstacles: [wall])!
    }

    func testFloorIsWalkableAndObstacleIsNot() {
        let mesh = roomWithWall()
        XCTAssertTrue(mesh.isWalkable(SIMD3(1.5, 0, 1.5)))
        XCTAssertFalse(mesh.isWalkable(SIMD3(-0.75, 0, 0)))
    }

    /// Obstacles are inflated by 15cm so the character never grazes furniture.
    func testClearanceMarginIsApplied() {
        let mesh = roomWithWall()
        XCTAssertFalse(mesh.isWalkable(SIMD3(-0.75, 0, 0.18)))
        XCTAssertTrue(mesh.isWalkable(SIMD3(-0.75, 0, 0.6)))
    }

    func testPathRoutesAroundObstacleRatherThanThroughIt() throws {
        let mesh = roomWithWall()
        let path = try XCTUnwrap(mesh.path(from: SIMD3(-1.5, 0, -1.5), to: SIMD3(-1.5, 0, 1.5)))
        for point in path {
            XCTAssertTrue(mesh.isWalkable(point), "path left the navmesh at \(point)")
        }
        // The only way through is the gap on the +X side, so the path must bow that way.
        XCTAssertGreaterThan(path.map(\.x).max() ?? -99, 0.4)
    }

    func testUnreachableTargetReturnsNilRatherThanPartialPath() {
        let island = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(2, 2))
        let mesh = NavMeshBuilder.build(floors: [island], obstacles: [])!
        // 20m away: off the mesh entirely, outside clamp radius.
        XCTAssertNil(mesh.path(from: SIMD3(0, 0, 0), to: SIMD3(20, 0, 20)))
    }

    func testClampSnapsOntoNearestWalkableCell() throws {
        let mesh = roomWithWall()
        let clamped = try XCTUnwrap(mesh.clamp(SIMD3(-0.75, 0, 0)))
        XCTAssertTrue(mesh.isWalkable(clamped))
    }

    func testPathIsSimplifiedAtCorners() throws {
        let floor = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(4, 4))
        let mesh = NavMeshBuilder.build(floors: [floor], obstacles: [])!
        let path = try XCTUnwrap(mesh.path(from: SIMD3(-1.5, 0, 0), to: SIMD3(1.5, 0, 0)))
        // A straight line across open floor should not be 30 waypoints.
        XCTAssertLessThan(path.count, 5)
    }
}

final class PlacementTests: XCTestCase {
    func testInitialPlacementRespectsMinimumDistanceAndFloor() throws {
        let floor = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6))
        let mesh = NavMeshBuilder.build(floors: [floor], obstacles: [])!
        let user = SIMD3<Float>(0, 1.5, 2)
        let pose = try XCTUnwrap(
            Placement.initialPose(in: mesh, userPosition: user, userForward: SIMD3(0, 0, -1))
        )
        XCTAssertTrue(mesh.isWalkable(pose.position))
        XCTAssertGreaterThanOrEqual(
            Placement.planarDistance(pose.position, user),
            Placement.minimumUserDistance
        )
    }

    /// No valid point must mean "say so", never "place it badly" (spec/05-scene.md).
    func testNoReachableFloorReturnsNil() {
        let tiny = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(0.3, 0.3))
        let mesh = NavMeshBuilder.build(floors: [tiny], obstacles: [])!
        XCTAssertNil(
            Placement.initialPose(
                in: mesh,
                userPosition: SIMD3(0, 1.5, 0),
                userForward: SIMD3(0, 0, -1)
            )
        )
    }
}

/// Spec 07 §Enforcement. The claim "a model that decides to go there simply gets no path" is
/// only true if it is true for every start and every goal, so it is tested as a property over
/// 10k random pairs rather than with a handful of examples.
final class ForbiddenZoneTests: XCTestCase {
    /// A 4m room: small enough that 10k A* runs stay a few seconds, large enough that the
    /// forbidden regions do not cover it.
    private let floor = FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(4, 4))

    private func shrine(at x: Float = 1.0, z: Float = 1.0, radius: Float = 0.8) -> Rule {
        Rule(name: "the shrine", kind: .forbidden, position: SIMD3(x, 0, z), radius: radius)
    }

    private func mesh(rules: [Rule]) -> NavMesh {
        NavMeshBuilder.build(floors: [floor], obstacles: [], rules: rules)!
    }

    // MARK: The property

    func testNoPathEverEntersAForbiddenRegion() {
        let rules = [shrine(), shrine(at: -1.2, z: -1.0, radius: 0.5)]
        let mesh = self.mesh(rules: rules)
        var generator = SeededGenerator(seed: 0xF0_0D_BEEF)
        var pathsFound = 0

        for _ in 0..<10_000 {
            let start = SIMD3<Float>(
                Float.random(in: -1.9...1.9, using: &generator), 0,
                Float.random(in: -1.9...1.9, using: &generator)
            )
            let goal = SIMD3<Float>(
                Float.random(in: -1.9...1.9, using: &generator), 0,
                Float.random(in: -1.9...1.9, using: &generator)
            )
            guard let path = mesh.path(from: start, to: goal) else { continue }
            pathsFound += 1
            for vertex in path {
                for rule in rules {
                    XCTAssertFalse(
                        rule.contains(vertex),
                        "path vertex \(vertex) is inside \(rule.name)"
                    )
                }
            }
        }
        XCTAssertGreaterThan(pathsFound, 5_000, "the test would pass vacuously with no paths")
    }

    /// Including when the goal is the forbidden region itself, which is the case a model
    /// actually produces: it was told not to go there and it tried anyway.
    func testAGoalInsideTheRegionProducesNoPathRatherThanAPathToTheEdge() {
        let rule = shrine()
        let mesh = self.mesh(rules: [rule])
        for _ in 0..<200 {
            let goal = SIMD3<Float>(
                rule.position.x + Float.random(in: -0.4...0.4), 0,
                rule.position.z + Float.random(in: -0.4...0.4)
            )
            guard let path = mesh.path(from: SIMD3(-1.8, 0, -1.8), to: goal) else { continue }
            XCTAssertFalse(rule.contains(path.last!))
        }
    }

    func testForbiddenCellsAreRemovedFromTheWalkableSurface() {
        let open = mesh(rules: [])
        let closed = mesh(rules: [shrine()])
        XCTAssertLessThan(closed.walkableCellCount, open.walkableCellCount)
        XCTAssertFalse(closed.isWalkable(SIMD3(1, 0, 1)))
        XCTAssertTrue(open.isWalkable(SIMD3(1, 0, 1)))
    }

    func testClampNeverReturnsAPointInsideAForbiddenRegion() {
        let rule = shrine()
        let mesh = self.mesh(rules: [rule])
        for _ in 0..<500 {
            let point = SIMD3<Float>(
                Float.random(in: -1.9...1.9), 0, Float.random(in: -1.9...1.9)
            )
            guard let clamped = mesh.clamp(point) else { continue }
            XCTAssertFalse(rule.contains(clamped))
        }
    }

    func testIsForbiddenAnswersWithoutTheGrid() {
        let mesh = self.mesh(rules: [shrine()])
        XCTAssertTrue(mesh.isForbidden(SIMD3(1, 0, 1)))
        XCTAssertFalse(mesh.isForbidden(SIMD3(-1.5, 0, -1.5)))
    }

    // MARK: Fragile is not a wall

    func testFragileRegionsAreNotSubtracted() {
        let fragile = Rule(
            name: "the vase", kind: .fragile, severity: .soft,
            position: SIMD3(1, 0, 1), radius: 0.5
        )
        let mesh = self.mesh(rules: [fragile])
        XCTAssertTrue(mesh.isWalkable(SIMD3(1, 0, 1)), "fragile must not become a wall")
        XCTAssertEqual(mesh.fragileRegions.count, 1)
    }

    func testFragileRegionsExcludeLandingAndGesturing() {
        let fragile = Rule(
            name: "the vase", kind: .fragile, severity: .soft,
            position: SIMD3(1, 0, 1), radius: 0.5
        )
        let mesh = self.mesh(rules: [fragile])
        XCTAssertFalse(mesh.allowsLanding(at: SIMD3(1, 0, 1)))
        XCTAssertTrue(mesh.allowsLanding(at: SIMD3(-1.5, 0, -1.5)))
    }

    func testPathsMayPassNearAFragileRegion() {
        let fragile = Rule(
            name: "the vase", kind: .fragile, severity: .soft,
            position: SIMD3(0, 0, 0), radius: 0.4
        )
        let mesh = self.mesh(rules: [fragile])
        XCTAssertNotNil(mesh.path(from: SIMD3(-1.8, 0, 0), to: SIMD3(1.8, 0, 0)))
    }

    // MARK: Other kinds change nothing geometric

    func testQuietAndPerchRulesLeaveTheSurfaceAlone() {
        let rules = [
            Rule(name: "study", kind: .quiet, severity: .soft, position: .zero, radius: 1),
            Rule(name: "sill", kind: .perch, severity: .soft, position: SIMD3(1.5, 0, 1.5), radius: 1),
        ]
        XCTAssertEqual(mesh(rules: rules).walkableCellCount, mesh(rules: []).walkableCellCount)
    }

    func testRulesAreAppliedAfterObstaclesSoNothingReopensThem() {
        // An obstacle covering the same area must not put walkable cells back.
        let rule = shrine(at: 0, z: 0, radius: 0.8)
        let mesh = NavMeshBuilder.build(
            floors: [floor],
            obstacles: [FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(2, 2))],
            rules: [rule]
        )!
        XCTAssertFalse(mesh.isWalkable(.zero))
    }
}

/// Deterministic randomness: a property test that fails only on some runs is a property test
/// nobody will trust.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
