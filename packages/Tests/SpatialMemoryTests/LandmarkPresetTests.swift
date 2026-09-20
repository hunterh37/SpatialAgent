import XCTest
import simd
@testable import SpatialMemory

/// The demo-room presets and the single-home-perch invariant they rely on.
final class LandmarkPresetTests: XCTestCase {
    func testDemoRoomCoversTheScriptedLandmarks() {
        let ids = LandmarkPreset.demoRoom.map(\.id)
        XCTAssertEqual(
            ids,
            ["perch", "workspace", "couch", "front-door", "kitchen", "plant", "snack-shelf"]
        )
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(LandmarkPreset.demoRoom.map(\.name)).count, ids.count)
    }

    /// Exactly one preset claims the perch role, and it is first: everything the bird does
    /// unprompted resolves against it.
    func testExactlyOnePresetIsTheHomePerch() {
        let perches = LandmarkPreset.demoRoom.filter(\.isHomePerch)
        XCTAssertEqual(perches.count, 1)
        XCTAssertEqual(LandmarkPreset.demoRoom.first?.id, "perch")
    }

    func testThePlantCarriesAFragileRule() {
        let plant = try! XCTUnwrap(LandmarkPreset.preset(id: "plant"))
        XCTAssertEqual(plant.rule, .fragile)
        XCTAssertFalse(Rule.Kind.fragile.isAlwaysHard)
    }

    // MARK: Home perch

    private func mapWithTwoPlaces() -> (SemanticMap, Place, Place) {
        var map = SemanticMap()
        let shelf = Place(name: "the shelf", position: SIMD3(1, 0, 0), kind: .perch)
        let ledge = Place(name: "the ledge", position: SIMD3(-1, 0, 0))
        map.upsert(shelf)
        map.upsert(ledge)
        return (map, shelf, ledge)
    }

    func testHomePerchIsThePlaceWithPerchKind() {
        let (map, shelf, _) = mapWithTwoPlaces()
        XCTAssertEqual(map.homePerch?.id, shelf.id)
    }

    /// Placing a new perch moves the role rather than creating a second one, and the old
    /// place survives — only its role moved.
    func testSettingANewHomePerchDemotesTheOldOne() {
        var (map, shelf, ledge) = mapWithTwoPlaces()
        XCTAssertTrue(map.setHomePerch(id: ledge.id))

        XCTAssertEqual(map.homePerch?.id, ledge.id)
        XCTAssertEqual(map.places.filter { $0.kind == .perch }.count, 1)
        XCTAssertEqual(map.place(id: shelf.id)?.kind, .generic)
        XCTAssertEqual(map.places.count, 2)
    }

    func testSettingAnUnknownHomePerchFails() {
        var (map, shelf, _) = mapWithTwoPlaces()
        XCTAssertFalse(map.setHomePerch(id: UUID()))
        XCTAssertEqual(map.homePerch?.id, shelf.id)
    }
}
