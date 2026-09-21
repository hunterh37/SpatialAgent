import XCTest
import simd
@testable import SpatialMemory

/// Needs resolve against the map, not against a name in the utterance. These tests are the
/// demo's claim in miniature: delete the bowl and "go eat" stops working.
final class HabitMemoryTests: XCTestCase {
    private func room() -> SemanticMap {
        var map = SemanticMap()
        map.upsert(Place(name: "the food bowl", position: SIMD3(1, 0, 0), kind: .food))
        map.upsert(Place(name: "the water dish", position: SIMD3(2, 0, 0), kind: .water))
        map.upsert(Place(name: "the petting spot", position: SIMD3(0, 0, 1), kind: .comfort))
        map.upsert(Place(name: "the toy basket", position: SIMD3(-1, 0, 0), kind: .toy))
        map.upsert(Place(name: "the red perch", position: SIMD3(0, 1, -1), kind: .perch))
        return map
    }

    func testEachNeedResolvesToItsOwnPlace() {
        let map = room()
        XCTAssertEqual(HabitMemory.place(for: .hungry, in: map)?.name, "the food bowl")
        XCTAssertEqual(HabitMemory.place(for: .thirsty, in: map)?.name, "the water dish")
        XCTAssertEqual(HabitMemory.place(for: .lonely, in: map)?.name, "the petting spot")
        XCTAssertEqual(HabitMemory.place(for: .bored, in: map)?.name, "the toy basket")
        XCTAssertEqual(HabitMemory.place(for: .sleepy, in: map)?.name, "the red perch")
    }

    /// The whole point: an empty map answers with a question, not with a flight to whatever
    /// place happens to be first.
    func testAnUntaughtNeedCannotAct() {
        let decision = HabitMemory.decide(.hungry, in: SemanticMap())
        XCTAssertFalse(decision.canAct)
        XCTAssertNil(decision.place)
        XCTAssertTrue(decision.line.contains("show me"), decision.line)
    }

    /// Two bowls, one used: the used one is the habit.
    func testTheMostUsedPlaceWins() {
        var map = room()
        var second = Place(name: "the travel bowl", position: SIMD3(3, 0, 0), kind: .food)
        second.useCount = 4
        map.upsert(second)
        XCTAssertEqual(HabitMemory.place(for: .hungry, in: map)?.name, "the travel bowl")
    }

    /// A place whose anchor has not relocalized is "somewhere in this room" and is not a
    /// destination, so a need skips it rather than flying to a stale coordinate.
    func testUnrelocalizedPlacesAreNotDestinations() {
        var map = SemanticMap()
        map.upsert(
            Place(
                name: "the food bowl",
                position: SIMD3(1, 0, 0),
                kind: .food,
                anchorId: UUID(),
                hasRelocalized: false
            )
        )
        XCTAssertNil(HabitMemory.place(for: .hungry, in: map))
    }

    func testTheFirstAnswerableNeedIsTheOneItPicks() {
        var map = SemanticMap()
        XCTAssertNil(HabitMemory.strongestNeed(in: map))
        map.upsert(Place(name: "the toy basket", position: .zero, kind: .toy))
        XCTAssertEqual(HabitMemory.strongestNeed(in: map), .bored)
        map.upsert(Place(name: "the food bowl", position: SIMD3(1, 0, 0), kind: .food))
        XCTAssertEqual(HabitMemory.strongestNeed(in: map), .hungry)
    }

    /// The recall line is built from the map, so an empty room says so and a taught room
    /// names what it was taught.
    func testInventoryIsBuiltFromTheMap() {
        XCTAssertTrue(HabitMemory.inventory(of: SemanticMap()).contains("new to me"))
        var map = room()
        map.upsert(Rule(name: "the plant", kind: .fragile, position: .zero, radius: 0.4))
        let line = HabitMemory.inventory(of: map)
        XCTAssertTrue(line.contains("the food bowl"), line)
        XCTAssertTrue(line.contains("the petting spot"), line)
        XCTAssertTrue(line.contains("the plant"), line)
    }

    /// Visiting counts, and the count is what turns a placement into a habit.
    @MainActor
    func testVisitingCountsTheUse() {
        let store = MapStore(
            defaults: UserDefaults(suiteName: "habit-memory-tests")!,
            roomId: UUID().uuidString
        )
        store.add(Place(name: "the food bowl", position: SIMD3(1, 0, 0), kind: .food))

        let first = store.visit(.hungry)
        XCTAssertEqual(first.place?.name, "the food bowl")
        XCTAssertFalse(first.isLearned)

        let second = store.visit(.hungry)
        XCTAssertTrue(second.isLearned)
        XCTAssertEqual(store.place(for: .hungry)?.useCount, 2)
        XCTAssertEqual(store.map.episodes.filter { $0.kind == .visited }.count, 2)
    }
}
