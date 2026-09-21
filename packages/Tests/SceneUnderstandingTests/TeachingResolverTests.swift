import SpatialMemory
import XCTest
import simd
@testable import SceneUnderstanding

/// Spec 07 §Teaching, client half: the act and the name come from the server, everything
/// spatial happens here.
@MainActor
final class TeachingResolverTests: XCTestCase {
    private let down = SIMD3<Float>(0, -1, 0)

    private func setup() -> (TeachingResolver, MapStore, GazeCapture, SyntheticSceneMesh) {
        let suite = "teach-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MapStore(defaults: defaults)
        let mesh = SyntheticSceneMesh.room()
        let gaze = GazeCapture(caster: mesh)
        return (TeachingResolver(store: store, gaze: gaze), store, gaze, mesh)
    }

    private func lookAtDesk(_ gaze: GazeCapture) {
        gaze.beginUtterance(origin: SIMD3(1.2, 1.5, -1.0), direction: down)
    }

    private func lookAtFloor(_ gaze: GazeCapture) {
        gaze.beginUtterance(origin: SIMD3(-1.5, 1.5, 1.5), direction: down)
    }

    // MARK: The five acts

    func testNamingAPlaceWritesARecordWithTheGeometrysRadius() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        let outcome = await teaching.apply(.namePlace, name: "my workspace")

        guard case let .taught(act, name, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(act, .namePlace)
        XCTAssertEqual(name, "my workspace")
        let place = try! XCTUnwrap(store.resolve("my workspace"))
        XCTAssertEqual(place.radius, 0.7, accuracy: 1e-5, "radius must come from the desk")
        XCTAssertEqual(place.kind, .surface)
    }

    func testNamingAnObjectBindsTheDeviceAndTheContainingPlace() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        lookAtDesk(gaze)
        let outcome = await teaching.apply(
            .nameObject, name: "the coffee machine", deviceId: "switch.coffee"
        )

        guard case .taught = outcome else { return XCTFail("\(outcome)") }
        let object = try! XCTUnwrap(store.map.object(named: "the coffee machine"))
        XCTAssertEqual(object.deviceId, "switch.coffee")
        XCTAssertEqual(object.placeId, store.resolve("the study")?.id)
    }

    func testForbiddingWritesAHardRule() async {
        let (teaching, store, gaze, _) = setup()
        lookAtFloor(gaze)
        let outcome = await teaching.apply(.forbidRegion, name: "the shrine", hard: true)

        guard case .taught = outcome else { return XCTFail("\(outcome)") }
        let rule = try! XCTUnwrap(store.map.rules.first)
        XCTAssertEqual(rule.kind, .forbidden)
        XCTAssertEqual(rule.severity, .hard)
        XCTAssertEqual(store.map.forbiddenRegions.count, 1)
    }

    func testASoftForbidIsFragileRatherThanForbidden() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.forbidRegion, name: "the vase", hard: false)
        XCTAssertEqual(store.map.rules.first?.kind, .fragile)
        XCTAssertTrue(store.map.forbiddenRegions.isEmpty)
    }

    func testForbiddingWithNoNameStillProducesARule() async {
        let (teaching, store, gaze, _) = setup()
        lookAtFloor(gaze)
        let outcome = await teaching.apply(.forbidRegion, name: "")
        guard case .taught = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(store.map.rules.count, 1)
    }

    func testNamingAnActivityBindsItToTheContainingPlace() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        lookAtDesk(gaze)
        await teaching.apply(.nameActivity, name: "brainstorming")

        let activity = try! XCTUnwrap(store.map.activity(named: "brainstorming"))
        XCTAssertEqual(activity.placeId, store.resolve("the study")?.id)
    }

    func testAnActivityWithNoPlaceCreatesOneSoItCanBeActedOn() async {
        let (teaching, store, gaze, _) = setup()
        lookAtFloor(gaze)
        await teaching.apply(.nameActivity, name: "brainstorming")
        XCTAssertNotNil(store.map.activity(named: "brainstorming")?.placeId)
        XCTAssertNotNil(store.resolve("brainstorming"))
    }

    func testCorrectingRetargetsTheMostRecentReferent() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the kitchen")
        let outcome = await teaching.apply(.correctName, name: "the study")

        guard case let .corrected(_, name, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(name, "the study")
        XCTAssertNotNil(store.resolve("the study"))
        XCTAssertNil(store.resolve("the kitchen"))
        XCTAssertEqual(store.map.places.count, 1, "a correction is not a second record")
    }

    func testCorrectingWithNothingRecentFailsRatherThanGuessing() async {
        let (teaching, _, _, _) = setup()
        guard case .failed = await teaching.apply(.correctName, name: "the kitchen") else {
            return XCTFail("a correction with no referent must fail")
        }
    }

    func testCorrectingAnObjectWorksToo() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.nameObject, name: "the kettle")
        await teaching.apply(.correctName, name: "the coffee machine")
        XCTAssertNotNil(store.map.object(named: "the coffee machine"))
        XCTAssertNil(store.map.object(named: "the kettle"))
    }

    // MARK: Gaze

    func testAnActWithNoGazeTargetAsksRatherThanWriting() async {
        let (teaching, store, _, _) = setup()
        let outcome = await teaching.apply(.namePlace, name: "my workspace")
        XCTAssertEqual(outcome, .needsGaze)
        XCTAssertTrue(store.map.isEmpty)
    }

    func testTheHeldTargetIsReleasedOnceTheActCompletes() async {
        let (teaching, _, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        XCTAssertNil(gaze.target(), "a held target must not leak into the next act")
    }

    // MARK: Episodes

    func testEveryActLeavesAnEpisode() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        XCTAssertEqual(store.map.episodes.count, 1)
        XCTAssertEqual(store.map.episodes.first?.kind, .taught)
    }

    // MARK: Disambiguation (C4)

    func testNamingInsideAnExistingPlaceAsksInsteadOfOverwriting() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        lookAtDesk(gaze)
        let outcome = await teaching.apply(.namePlace, name: "the desk")

        guard case let .needsDisambiguation(existing, name, _) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(existing.name, "the study")
        XCTAssertEqual(name, "the desk")
        XCTAssertEqual(store.map.places.count, 1, "nothing may be written before the answer")
    }

    func testRenamingIsOneOfExactlyTwoAnswers() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        let existing = try! XCTUnwrap(store.resolve("the study"))
        let outcome = teaching.rename(existing: existing, to: "the desk")

        guard case .corrected = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotNil(store.resolve("the desk"))
        XCTAssertNil(store.resolve("the study"))
        XCTAssertEqual(store.map.places.count, 1)
    }

    func testNestingIsTheOtherAnswerAndProducesAnObject() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        lookAtDesk(gaze)
        let outcome = await teaching.nest(name: "the desk", act: .namePlace)

        guard case .taught = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotNil(store.map.object(named: "the desk"))
        XCTAssertNotNil(store.resolve("the study"), "the existing place must survive")
    }

    func testReTeachingTheSameNameIsACorrectionNotAQuestion() async {
        let (teaching, store, gaze, _) = setup()
        lookAtDesk(gaze)
        await teaching.apply(.namePlace, name: "the study")
        lookAtDesk(gaze)
        let outcome = await teaching.apply(.namePlace, name: "the study")

        guard case .corrected = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(store.map.places.count, 1)
    }
}
