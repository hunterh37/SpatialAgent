import XCTest
import simd
@testable import SpatialMemory

/// The aversion: three identical perches, and the only thing that separates them is what
/// the user's hand has done to the bird on each one.
final class PerchMemoryTests: XCTestCase {
    private func room() -> (SemanticMap, Place, Place, Place) {
        var map = SemanticMap()
        let red = Place(name: "the red perch", position: SIMD3(-1, 0, -1), kind: .perch,
                        taughtAt: Date(timeIntervalSince1970: 1), elevation: 1)
        let blue = Place(name: "the blue perch", position: SIMD3(0, 0, -1.5), kind: .perch,
                         taughtAt: Date(timeIntervalSince1970: 2), elevation: 1)
        let amber = Place(name: "the amber perch", position: SIMD3(1, 0, -1), kind: .perch,
                          taughtAt: Date(timeIntervalSince1970: 3), elevation: 1)
        map.upsert(red)
        map.upsert(blue)
        map.upsert(amber)
        return (map, red, blue, amber)
    }

    func testAnUntouchedRoomPicksTheFirstPerchAndKeepsPickingIt() {
        var (map, red, _, _) = room()
        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)
        // Determinism matters more than variety here: a demo where the same state answers
        // differently on the second tap proves nothing about memory.
        map.noteUse(placeId: red.id)
        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)
    }

    /// The whole feature in one test: one knock moves the choice, and no amount of prior
    /// success on the knocked perch brings it back.
    func testOneKnockOffMovesTheChoiceEvenToAPerchHeHasNeverUsed() {
        var (map, red, blue, _) = room()
        for _ in 0 ..< 5 { map.noteUse(placeId: red.id) }
        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)

        map.noteKnockOff(placeId: red.id)

        XCTAssertEqual(PerchMemory.best(in: map)?.id, blue.id)
        XCTAssertEqual(map.place(id: red.id)?.knockOffs, 1)
    }

    func testKnockingHimOffEachPerchInTurnWalksThroughAllThree() {
        var (map, red, blue, amber) = room()
        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)
        map.noteKnockOff(placeId: red.id)
        XCTAssertEqual(PerchMemory.best(in: map)?.id, blue.id)
        map.noteKnockOff(placeId: blue.id)
        XCTAssertEqual(PerchMemory.best(in: map)?.id, amber.id)
        // Every perch swatted: he still has to pick one, and it is the least-swatted.
        map.noteKnockOff(placeId: amber.id)
        map.noteKnockOff(placeId: amber.id)
        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)
    }

    func testTheSpokenLineNamesThePerchHeIsAvoiding() {
        var (map, red, _, _) = room()
        map.noteKnockOff(placeId: red.id)
        let choice = PerchMemory.choose(in: map)

        XCTAssertTrue(choice.isLearned)
        XCTAssertTrue(choice.line.contains("the red perch"), choice.line)
        XCTAssertTrue(choice.line.contains("the blue perch"), choice.line)
        XCTAssertEqual(choice.avoided.map(\.id), [red.id])
    }

    func testWithNoPerchesHeAsksToBeShownRatherThanFlyingSomewhere() {
        let choice = PerchMemory.choose(in: SemanticMap())
        XCTAssertNil(choice.place)
        XCTAssertFalse(choice.canAct)
        XCTAssertTrue(choice.line.contains("show me"), choice.line)
    }

    /// A perch whose anchor never came back is not a destination, however clean its record.
    func testAPerchThatHasNotRelocalizedIsNotAChoice() {
        var map = SemanticMap()
        map.upsert(
            Place(name: "the red perch", position: .zero, kind: .perch,
                  anchorId: UUID(), hasRelocalized: false, elevation: 1)
        )
        XCTAssertNil(PerchMemory.best(in: map))
    }

    func testForgettingKnockOffsRestoresTheOriginalChoice() {
        var (map, red, _, _) = room()
        map.noteKnockOff(placeId: red.id)
        map.forgetKnockOffs()

        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)
        XCTAssertTrue(PerchMemory.avoided(in: map).isEmpty)
        XCTAssertNil(PerchMemory.summary(of: map))
    }

    func testKnockingOffAnUnknownRecordChangesNothing() {
        var (map, _, _, _) = room()
        XCTAssertNil(map.noteKnockOff(placeId: UUID()))
    }

    /// Sleep resolves through the same choice, so "time to settle down" and "go perch" can
    /// never send him to different poles.
    func testTheSleepyNeedResolvesThroughTheSameChoice() {
        var (map, red, blue, _) = room()
        map.noteKnockOff(placeId: red.id)

        XCTAssertEqual(HabitMemory.place(for: .sleepy, in: map)?.id, blue.id)
        XCTAssertEqual(HabitMemory.decide(.sleepy, in: map).line, PerchMemory.choose(in: map).line)
        XCTAssertTrue(HabitMemory.inventory(of: map).contains("the red perch"))
    }

    /// The count survives a round trip, and a map written before knock-offs existed still
    /// decodes — the field is optional in storage for exactly that reason.
    func testKnockOffsSurviveEncodingAndOldMapsStillDecode() throws {
        var (map, red, _, _) = room()
        map.noteKnockOff(placeId: red.id)
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(SemanticMap.self, from: data)
        XCTAssertEqual(decoded.place(id: red.id)?.knockOffs, 1)
        XCTAssertEqual(decoded.place(id: red.id)?.elevation, 1)

        let legacy = """
        {"id":"x","name":"the shelf","kind":"perch","radius":0.3,"useCount":0,
         "taughtAt":0,"anchor":{"position":[0,0,0],"hasRelocalized":true}}
        """.replacingOccurrences(of: "\"id\":\"x\"", with: "\"id\":\"\(UUID().uuidString)\"")
        let old = try JSONDecoder().decode(Place.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.knockOffs, 0)
        XCTAssertEqual(old.elevation, 0)
        XCTAssertFalse(old.isElevated)
    }

    // MARK: The closed set of perches

    /// The regression: `set_home_perch` used to mint a record called "your perch", which then
    /// won the choice and got read out as "your perch. Still the good one." A perch the room
    /// has no colour for is not a perch the bird can talk about, so it is not a candidate.
    func testAStrayPerchRecordIsNotACandidate() {
        var (map, red, _, _) = room()
        let stray = Place(name: "your perch", position: SIMD3(0, 0, 3), kind: .perch,
                          taughtAt: Date(timeIntervalSince1970: 0), elevation: 1)
        map.upsert(stray)

        XCTAssertFalse(PerchMemory.candidates(in: map).contains { $0.id == stray.id })
        XCTAssertEqual(PerchMemory.candidates(in: map).count, 3)
        XCTAssertEqual(map.perches.count, 3)
        // Even though it was taught first, which is how it used to win the tie-break.
        XCTAssertEqual(PerchMemory.best(in: map)?.id, red.id)
        XCTAssertFalse(PerchMemory.choose(in: map).line.contains("your perch"))
    }

    func testEveryCandidateIsAColouredPreset() {
        let (map, _, _, _) = room()
        for place in PerchMemory.candidates(in: map) {
            XCTAssertTrue(LandmarkPreset.isPerchName(place.name), place.name)
        }
    }
}
