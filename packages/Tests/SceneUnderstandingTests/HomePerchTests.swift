import SpatialMemory
import XCTest
import simd
@testable import SceneUnderstanding

/// `set_home_perch`, client half. The server only says the kind is `perch`; which record
/// carries it is decided here — and it is always one of the three coloured presets, because
/// the learned-choice line reads the perch's name out loud and the room has no colour for a
/// name this path made up.
@MainActor
final class HomePerchTests: XCTestCase {
    private let down = SIMD3<Float>(0, -1, 0)

    private func setup(suite: String) -> (TeachingResolver, MapStore, GazeCapture, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MapStore(defaults: defaults)
        let gaze = GazeCapture(caster: SyntheticSceneMesh.room())
        return (TeachingResolver(store: store, gaze: gaze), store, gaze, defaults)
    }

    private func lookAtDesk(_ gaze: GazeCapture) {
        gaze.beginUtterance(origin: SIMD3(1.2, 1.5, -1.0), direction: down)
    }

    private func lookAtFloor(_ gaze: GazeCapture) {
        gaze.beginUtterance(origin: SIMD3(-1.5, 1.5, 1.5), direction: down)
    }

    func testPerchFromGazeAdoptsTheNextColouredPresetRatherThanInventingAName() async throws {
        let (teaching, store, gaze, _) = setup(suite: "perch-\(UUID().uuidString)")
        lookAtDesk(gaze)
        let outcome = await teaching.apply(.setHomePerch, name: "")

        guard case let .taught(act, name, id) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(act, .setHomePerch)
        XCTAssertEqual(name, "the red perch")
        let perch = try XCTUnwrap(store.map.homePerch)
        XCTAssertEqual(perch.id, id)
        XCTAssertEqual(perch.kind, .perch)
        XCTAssertEqual(perch.elevation, LandmarkPreset.perchHeight)
        XCTAssertTrue(store.map.episodes.contains { $0.placeId == id || $0.summary.contains("set_home_perch") })
    }

    /// The regression: two perches taught in an empty room are the red one and the blue one.
    /// "your perch" was a fourth, unnamed perch that then won the choice and was narrated.
    func testTwoPerchesTaughtInAnEmptyRoomAreRedThenBlue() async {
        let (teaching, store, gaze, _) = setup(suite: "perch-\(UUID().uuidString)")
        lookAtDesk(gaze)
        await teaching.apply(.setHomePerch, name: "")
        lookAtFloor(gaze)
        await teaching.apply(.setHomePerch, name: "")

        XCTAssertEqual(store.map.perches.map(\.name), ["the red perch", "the blue perch"])
        XCTAssertNil(store.resolve("your perch"))
    }

    /// Looking at a perch that is already there is a reference to it, not a fourth record.
    func testLookingAtAnExistingPerchBindsToItInsteadOfAddingOne() async {
        let (teaching, store, gaze, _) = setup(suite: "perch-\(UUID().uuidString)")
        lookAtDesk(gaze)
        await teaching.apply(.setHomePerch, name: "")
        lookAtDesk(gaze)
        let outcome = await teaching.apply(.setHomePerch, name: "")

        guard case let .corrected(_, name, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(name, "the red perch")
        XCTAssertEqual(store.map.places.count, 1)
    }

    func testPerchWithNoGazeStaysOpenForAFollowUp() async {
        let (teaching, _, _, _) = setup(suite: "perch-\(UUID().uuidString)")
        let outcome = await teaching.apply(.setHomePerch, name: "")
        XCTAssertEqual(outcome, .needsGaze)
        XCTAssertTrue(TeachingAct.setHomePerch.needsGaze(place: nil))
        XCTAssertFalse(TeachingAct.setHomePerch.needsGaze(place: "the shelf"))
    }

    func testPerchPromotesAnExistingNamedPlaceWithoutMovingIt() async throws {
        let (teaching, store, gaze, _) = setup(suite: "perch-\(UUID().uuidString)")
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the shelf")
        let shelf = try XCTUnwrap(store.resolve("the shelf"))

        // No gaze at all: promoting a record that already has a position must not need one.
        let outcome = await teaching.apply(.setHomePerch, name: "", place: "the shelf")

        guard case let .corrected(act, name, id) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(act, .setHomePerch)
        XCTAssertEqual(name, "the shelf")
        XCTAssertEqual(id, shelf.id)
        XCTAssertEqual(store.resolve("the shelf")?.kind, .perch)
        XCTAssertEqual(store.resolve("the shelf")?.position, shelf.position)
        XCTAssertEqual(store.map.places.count, 1, "promotion is not a second record")
    }

    func testPerchSurvivesAMapStoreReload() async throws {
        let suite = "perch-\(UUID().uuidString)"
        let (teaching, store, gaze, defaults) = setup(suite: suite)
        lookAtDesk(gaze)
        await teaching.apply(.setHomePerch, name: "")
        let id = try XCTUnwrap(store.map.homePerch?.id)

        let reloaded = MapStore(defaults: defaults)
        XCTAssertEqual(reloaded.map.homePerch?.id, id)
        XCTAssertEqual(reloaded.map.homePerch?.name, "the red perch")
    }
}
