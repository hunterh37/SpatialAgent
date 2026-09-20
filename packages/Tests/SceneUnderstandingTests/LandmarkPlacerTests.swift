import SpatialMemory
import XCTest
import simd
@testable import SceneUnderstanding

/// The checklist path writes the same records the spoken teaching path does.
@MainActor
final class LandmarkPlacerTests: XCTestCase {
    /// The placer holds the scene weakly — the app owns it — so the test has to be its owner.
    private var scene: FixtureSceneProvider?

    private func makePlacer(gaze: Bool) -> (LandmarkPlacer, MapStore) {
        let defaults = UserDefaults(suiteName: "landmark.placer.\(UUID().uuidString)")!
        let store = MapStore(defaults: defaults)
        let scene = FixtureSceneProvider.apartment()
        self.scene = scene
        // Looking slightly down: a level ray never meets a horizontal plane, so a flat
        // forward vector would test the fallback path in both cases.
        scene.userForward = simd_normalize(SIMD3(0, -0.6, -1))
        let capture = gaze ? GazeCapture(caster: SyntheticSceneMesh.room()) : nil
        let anchors = AnchorBinding(store: store, provider: scene)
        return (
            LandmarkPlacer(store: store, scene: scene, gaze: capture, anchors: anchors),
            store
        )
    }

    private func preset(_ id: String) -> LandmarkPreset {
        LandmarkPreset.preset(id: id)!
    }

    func testPlacingWritesAnAnchoredPlaceAndAnEpisode() async {
        let (placer, store) = makePlacer(gaze: true)
        let outcome = await placer.place(preset("workspace"))

        guard case let .placed(name, anchored) = outcome else {
            return XCTFail("expected an anchored placement, got \(outcome)")
        }
        XCTAssertEqual(name, "my desk")
        XCTAssertTrue(anchored)

        let place = try! XCTUnwrap(store.map.place(named: "my desk"))
        XCTAssertEqual(place.kind, .workspace)
        XCTAssertTrue(place.isNavigable)
        XCTAssertEqual(store.map.episodes.filter { $0.kind == .taught }.count, 1)
    }

    /// The simulator has no raycast, and the flow still has to be demoable there.
    func testPlacingWithoutGazeFallsBackToASyntheticOffset() async {
        let (placer, store) = makePlacer(gaze: false)
        let outcome = await placer.place(preset("petting-spot"))

        XCTAssertEqual(outcome, .placedSynthetically(name: "the petting spot"))
        XCTAssertNotNil(store.map.place(named: "the petting spot"))
    }

    func testTheHomePerchMovesRatherThanMultiplying() async {
        let (placer, store) = makePlacer(gaze: true)
        await placer.place(preset("perch"))
        let first = try! XCTUnwrap(store.map.homePerch)

        // A second landmark taking the perch role is the user moving it.
        await placer.place(preset("workspace"))
        XCTAssertTrue(store.setHomePerch(id: store.map.place(named: "my desk")!.id))

        XCTAssertEqual(store.map.places.filter { $0.kind == .perch }.count, 1)
        XCTAssertEqual(store.map.homePerch?.name, "my desk")
        XCTAssertEqual(store.map.place(id: first.id)?.kind, .generic)
    }

    func testRePlacingCorrectsInPlace() async {
        let (placer, store) = makePlacer(gaze: true)
        await placer.place(preset("toy-basket"))
        await placer.place(preset("toy-basket"))
        XCTAssertEqual(store.map.places.filter { $0.nameKey == "the toy basket" }.count, 1)
    }

    /// Deleting the plant has to take its keep-away region with it.
    func testTheFragileLandmarkWritesAndRemovesItsRule() async {
        let (placer, store) = makePlacer(gaze: true)
        await placer.place(preset("plant"))
        XCTAssertEqual(store.map.rules.filter { $0.kind == .fragile }.count, 1)

        XCTAssertTrue(placer.remove(preset("plant")))
        XCTAssertNil(store.map.place(named: "the plant"))
        XCTAssertTrue(store.map.rules.isEmpty)
    }

    func testNextIsTheFirstUnplacedPreset() async {
        let (placer, _) = makePlacer(gaze: true)
        XCTAssertEqual(placer.next()?.id, "perch")
        await placer.place(preset("perch"))
        XCTAssertEqual(placer.next()?.id, "food-bowl")
    }

    func testResetRoomForgetsEverything() async {
        let (placer, store) = makePlacer(gaze: true)
        await placer.place(preset("perch"))
        await placer.resetRoom()
        XCTAssertTrue(store.map.isEmpty)
    }

    // MARK: - Dragging a marker

    func testMarkersAreOnlyThePlacedPresets() async {
        let (placer, _) = makePlacer(gaze: true)
        XCTAssertTrue(placer.markers.isEmpty)
        await placer.place(preset("perch"))
        XCTAssertEqual(placer.markers.map(\.id), ["perch"])
        XCTAssertTrue(placer.markers[0].isHomePerch)
    }

    /// A dragged landmark keeps its identity: the record is moved, not replaced.
    func testMoveKeepsThePlaceIdAndMovesItsRule() async {
        let (placer, store) = makePlacer(gaze: true)
        await placer.place(preset("plant"))
        let before = store.map.place(named: "the plant")!

        let target = SIMD3<Float>(2, 0, -1)
        await placer.move(preset("plant"), to: target)

        let after = store.map.place(named: "the plant")!
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.position, target)
        XCTAssertEqual(store.map.rules.first?.position, target)
    }

    func testMovingAnUnplacedLandmarkFails() async {
        let (placer, _) = makePlacer(gaze: true)
        let outcome = await placer.move(preset("toy-basket"), to: .zero)
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }
}
