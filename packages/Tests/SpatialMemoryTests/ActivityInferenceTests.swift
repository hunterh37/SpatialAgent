import XCTest
import simd
@testable import SpatialMemory

/// Spec 07 §Learned behavior.
final class ActivityInferenceTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func mapWithDesk() -> (SemanticMap, Place) {
        var map = SemanticMap()
        let desk = Place(name: "the desk", position: SIMD3(1, 0, 0), radius: 0.8)
        map.upsert(desk)
        map.upsert(Activity(name: "brainstorming", placeId: desk.id))
        return (map, desk)
    }

    // MARK: Band formation

    func testBandsFormFromRepeatedVisitsAtTheSameHour() {
        var (map, desk) = mapWithDesk()
        for day in 1...4 {
            ActivityInference.noteVisit(to: desk, at: date(day: day, hour: 9, minute: 10), in: &map)
        }
        ActivityInference.learn(in: &map, calendar: calendar)

        let activity = try! XCTUnwrap(map.activity(named: "brainstorming"))
        XCTAssertEqual(activity.bands.count, 1)
        let band = activity.bands[0]
        XCTAssertEqual(band.observations, 4)
        XCTAssertTrue(band.contains(minute: 9 * 60 + 10))
        // Padded either side, so arriving early is the same activity.
        XCTAssertTrue(band.contains(minute: 8 * 60 + 45))
        XCTAssertFalse(band.contains(minute: 14 * 60))
    }

    func testASingleVisitIsNotAHabit() {
        var (map, desk) = mapWithDesk()
        ActivityInference.noteVisit(to: desk, at: date(day: 1, hour: 9), in: &map)
        ActivityInference.learn(in: &map, calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(map.activity(named: "brainstorming")).bands.isEmpty)
    }

    func testTwoDistinctTimesOfDayFormTwoBands() {
        var (map, desk) = mapWithDesk()
        for day in 1...3 {
            ActivityInference.noteVisit(to: desk, at: date(day: day, hour: 9), in: &map)
            ActivityInference.noteVisit(to: desk, at: date(day: day, hour: 20), in: &map)
        }
        ActivityInference.learn(in: &map, calendar: calendar)

        let bands = try! XCTUnwrap(map.activity(named: "brainstorming")).bands
        XCTAssertEqual(bands.count, 2)
        XCTAssertTrue(bands.contains { $0.contains(minute: 9 * 60) })
        XCTAssertTrue(bands.contains { $0.contains(minute: 20 * 60) })
    }

    func testVisitsToSomewhereElseDoNotFormABand() {
        var (map, desk) = mapWithDesk()
        let couch = Place(name: "the couch", position: SIMD3(-2, 0, 0), radius: 0.8)
        map.upsert(couch)
        for day in 1...4 {
            ActivityInference.noteVisit(to: couch, at: date(day: day, hour: 21), in: &map)
        }
        ActivityInference.learn(in: &map, calendar: calendar)
        XCTAssertTrue(try XCTUnwrap(map.activity(named: "brainstorming")).bands.isEmpty)
        _ = desk
    }

    /// Deleting the history has to un-learn the habit it produced, or "forget this" is a lie.
    func testLearningIsDerivedFromEpisodesRatherThanAccumulated() {
        var (map, desk) = mapWithDesk()
        for day in 1...4 {
            ActivityInference.noteVisit(to: desk, at: date(day: day, hour: 9), in: &map)
        }
        ActivityInference.learn(in: &map, calendar: calendar)
        XCTAssertFalse(try XCTUnwrap(map.activity(named: "brainstorming")).bands.isEmpty)

        map.delete(id: desk.id)
        XCTAssertTrue(map.episodes.isEmpty)
    }

    func testLearningTwiceChangesNothing() {
        var (map, desk) = mapWithDesk()
        for day in 1...3 {
            ActivityInference.noteVisit(to: desk, at: date(day: day, hour: 9), in: &map)
        }
        ActivityInference.learn(in: &map, calendar: calendar)
        let once = map.activities
        ActivityInference.learn(in: &map, calendar: calendar)
        XCTAssertEqual(map.activities, once)
    }

    // MARK: Follow vs settle

    private func learned() -> SemanticMap {
        var (map, desk) = mapWithDesk()
        for day in 1...4 {
            ActivityInference.noteVisit(to: desk, at: date(day: day, hour: 9), in: &map)
        }
        ActivityInference.learn(in: &map, calendar: calendar)
        return map
    }

    func testInsideTheActivitysPlaceDuringItsBandTheBirdSettles() {
        let map = learned()
        let response = ActivityInference.response(
            forUserAt: SIMD3(1, 0, 0),
            in: map,
            now: date(day: 9, hour: 9, minute: 5),
            calendar: calendar
        )
        XCTAssertEqual(response, .settle(activity: "brainstorming"))
    }

    func testOutsideTheBandTheBirdFollows() {
        let map = learned()
        let response = ActivityInference.response(
            forUserAt: SIMD3(1, 0, 0),
            in: map,
            now: date(day: 9, hour: 15),
            calendar: calendar
        )
        XCTAssertEqual(response, .follow)
    }

    func testOutsideThePlaceTheBirdFollows() {
        let map = learned()
        let response = ActivityInference.response(
            forUserAt: SIMD3(-3, 0, 0),
            in: map,
            now: date(day: 9, hour: 9),
            calendar: calendar
        )
        XCTAssertEqual(response, .follow)
    }

    func testAnUnmappedRoomAlwaysFollows() {
        let response = ActivityInference.response(
            forUserAt: .zero,
            in: SemanticMap(),
            now: date(day: 9, hour: 9),
            calendar: calendar
        )
        XCTAssertEqual(response, .follow)
    }

    func testAPlaceWithNoActivityFollows() {
        var map = SemanticMap()
        map.upsert(Place(name: "the hall", position: .zero, radius: 1))
        let response = ActivityInference.response(
            forUserAt: .zero, in: map, now: date(day: 9, hour: 9), calendar: calendar
        )
        XCTAssertEqual(response, .follow)
    }
}
