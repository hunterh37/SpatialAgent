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
