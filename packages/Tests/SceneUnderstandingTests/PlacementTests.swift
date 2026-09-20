import SpatialMemory
import XCTest
import simd
@testable import SceneUnderstanding

/// Spec 05 placement rules, and the spec 07 §Learned behavior bias over them.
final class PlacementTests: XCTestCase {
    private let user = SIMD3<Float>(0, 1.5, 2.0)
    private let forward = SIMD3<Float>(0, 0, -1)

    private func mesh(rules: [Rule] = []) -> NavMesh {
        NavMeshBuilder.build(
            floors: [FloorRect(center: .zero, extent: SIMD2(6, 6))],
            obstacles: [],
            rules: rules
        )!
    }

    private func pose(_ map: SemanticMap, rules: [Rule] = [], now: Date = Date()) -> Placement.Pose? {
        Placement.initialPose(
            in: mesh(rules: rules),
            userPosition: user,
            userForward: forward,
            map: map,
            now: now
        )
    }

    // MARK: Hard constraints still hold

    func testPlacementIsInFrontOfTheUserAndPastTheMinimumDistance() {
        let pose = try! XCTUnwrap(pose(SemanticMap()))
        XCTAssertGreaterThanOrEqual(
            Placement.planarDistance(pose.position, user),
            Placement.minimumUserDistance
        )
        XCTAssertLessThan(pose.position.z, user.z, "placed behind the user")
    }

    func testPlacementFacesTheUser() {
        let pose = try! XCTUnwrap(pose(SemanticMap()))
        let expected = Placement.yawFacing(pose.position, user)
        XCTAssertEqual(pose.yaw, expected, accuracy: 1e-5)
    }

    func testNoFloorMeansNoPose() {
        let empty = NavMesh(origin: SIMD2(-1, -1), width: 4, depth: 4)
        XCTAssertNil(
            Placement.initialPose(in: empty, userPosition: user, userForward: forward)
        )
    }

    // MARK: Perch preference

    private func perch(at x: Float, _ z: Float) -> Rule {
        Rule(name: "the sill", kind: .perch, severity: .soft, position: SIMD3(x, 0, z), radius: 0.5)
    }

    func testPlacementPrefersAPerch() {
        var map = SemanticMap()
        let rule = perch(at: 1.2, 0.2)
        map.upsert(rule)
        let placed = try! XCTUnwrap(pose(map, rules: [rule]))
        XCTAssertTrue(rule.contains(placed.position), "ignored the perch at \(placed.position)")
    }

    func testAPerchNeverBeatsAHardConstraint() {
        var map = SemanticMap()
        // A perch behind the user and inside a forbidden region: both illegal.
        let behind = perch(at: 0, 3.4)
        let forbidden = Rule(
            name: "the shrine", kind: .forbidden, position: SIMD3(0, 0, 3.4), radius: 0.8
        )
        map.upsert(behind)
        map.upsert(forbidden)
        let placed = try! XCTUnwrap(pose(map, rules: [behind, forbidden]))
        XCTAssertFalse(forbidden.contains(placed.position), "placed inside a forbidden region")
        XCTAssertLessThan(placed.position.z, user.z)
        XCTAssertGreaterThanOrEqual(
            Placement.planarDistance(placed.position, user),
            Placement.minimumUserDistance
        )
    }

    func testPlacementNeverLandsOnAFragileRegion() {
        let fragile = Rule(
            name: "the table", kind: .fragile, severity: .soft,
            position: SIMD3(0, 0, 0.4), radius: 0.9
        )
        var map = SemanticMap()
        map.upsert(fragile)
        let placed = try! XCTUnwrap(pose(map, rules: [fragile]))
        XCTAssertFalse(fragile.contains(placed.position))
    }

    // MARK: The user's usual place

    private func calendarDate(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    private func mapWithMorningDesk() -> SemanticMap {
        var map = SemanticMap()
        let place = Place(name: "the desk", position: SIMD3(0.8, 0, 0.4), radius: 0.6)
        map.upsert(place)
        map.upsert(
            Activity(
                name: "brainstorming",
                placeId: place.id,
                bands: [.init(startMinute: 8 * 60, endMinute: 11 * 60, observations: 5)]
            )
        )
        return map
    }

    func testPlacementPrefersTheUsualPlaceForThisTimeOfDay() {
        let map = mapWithMorningDesk()
        let placed = try! XCTUnwrap(pose(map, now: calendarDate(hour: 9)))
        let desk = try! XCTUnwrap(map.place(named: "the desk"))
        XCTAssertTrue(desk.contains(placed.position))
    }

    func testTheUsualPlaceOnlyAppliesInsideItsBand() {
        let map = mapWithMorningDesk()
        XCTAssertNotNil(Placement.usualPlace(in: map, now: calendarDate(hour: 9)))
        XCTAssertNil(Placement.usualPlace(in: map, now: calendarDate(hour: 20)))
    }

    func testAnEmptyMapPlacesExactlyAsBefore() {
        let mesh = self.mesh()
        let plain = Placement.initialPose(in: mesh, userPosition: user, userForward: forward)
        let mapped = Placement.initialPose(
            in: mesh, userPosition: user, userForward: forward, map: SemanticMap()
        )
        XCTAssertEqual(plain?.position, mapped?.position)
    }

    func testTheMostObservedActivityWinsATie() {
        var map = SemanticMap()
        let desk = Place(name: "the desk", position: SIMD3(0.8, 0, 0.4), radius: 0.6)
        let couch = Place(name: "the couch", position: SIMD3(-1.4, 0, 0.4), radius: 0.6)
        map.upsert(desk)
        map.upsert(couch)
        map.upsert(
            Activity(name: "reading", placeId: couch.id,
                     bands: [.init(startMinute: 0, endMinute: 1439, observations: 1)])
        )
        map.upsert(
            Activity(name: "brainstorming", placeId: desk.id,
                     bands: [.init(startMinute: 0, endMinute: 1439, observations: 9)])
        )
        XCTAssertEqual(Placement.usualPlace(in: map)?.name, "the desk")
    }
    // MARK: Inherited from the pre-map placement tests

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
