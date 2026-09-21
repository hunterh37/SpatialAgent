import XCTest
import simd
@testable import SpatialMemory

/// Spec 07 §Curiosity. The budget is a product requirement (PRD §9), so every clause gets its
/// own test rather than one combined one: a budget that is only tested in aggregate is a
/// budget where one clause can rot unnoticed.
final class CuriosityPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let user = SIMD3<Float>.zero

    private func candidate(_ id: String = "c1", at x: Float = 1) -> CuriosityPlanner.Candidate {
        .init(id: id, kind: .unnamedRegion, position: SIMD3(x, 0, 0), subject: "that spot")
    }

    private func ready() -> CuriosityPlanner {
        var planner = CuriosityPlanner()
        planner.beginSession()
        // A question is never asked within 30s of an utterance; start the clock well before.
        planner.noteUtterance(at: now.addingTimeInterval(-600))
        return planner
    }

    private func ask(_ planner: CuriosityPlanner, at date: Date? = nil) -> CuriosityPlanner.Candidate? {
        planner.next(
            from: [candidate()],
            now: date ?? now,
            userPosition: user,
            map: SemanticMap()
        )
    }

    // MARK: Each clause, alone

    func testAQuestionIsAskedWhenNothingForbidsIt() {
        XCTAssertNotNil(ask(ready()))
    }

    func testAtMostOneQuestionPerTenMinutes() {
        var planner = ready()
        planner.noteAsked(candidate("earlier"), at: now)

        XCTAssertEqual(
            planner.budgetAllows(
                now: now.addingTimeInterval(CuriosityPlanner.minimumGap - 1),
                userPosition: user,
                map: SemanticMap()
            ),
            .tooSoon
        )
        XCTAssertNil(
            planner.budgetAllows(
                now: now.addingTimeInterval(CuriosityPlanner.minimumGap + 1),
                userPosition: user,
                map: SemanticMap()
            )
        )
    }

    func testAtMostFourPerSession() {
        var planner = ready()
        var clock = now
        for index in 0..<CuriosityPlanner.perSessionLimit {
            planner.noteAsked(candidate("c\(index)"), at: clock)
            clock = clock.addingTimeInterval(CuriosityPlanner.minimumGap + 1)
        }
        XCTAssertEqual(
            planner.budgetAllows(now: clock, userPosition: user, map: SemanticMap()),
            .sessionLimitReached
        )
    }

    func testNeverWithin30SecondsOfAUserUtterance() {
        var planner = ready()
        planner.noteUtterance(at: now)
        XCTAssertEqual(
            planner.budgetAllows(
                now: now.addingTimeInterval(CuriosityPlanner.utteranceQuiet - 1),
                userPosition: user,
                map: SemanticMap()
            ),
            .tooSoonAfterAnUtterance
        )
        XCTAssertNil(
            planner.budgetAllows(
                now: now.addingTimeInterval(CuriosityPlanner.utteranceQuiet + 1),
                userPosition: user,
                map: SemanticMap()
            )
        )
    }

    func testNeverWhileTheUserIsInsideAQuietRule() {
        var map = SemanticMap()
        map.upsert(
            Rule(name: "the study", kind: .quiet, severity: .soft, position: .zero, radius: 2)
        )
        XCTAssertEqual(
            ready().budgetAllows(now: now, userPosition: user, map: map),
            .insideAQuietRule
        )
        // Outside it, the same planner is free to ask.
        XCTAssertNil(ready().budgetAllows(now: now, userPosition: SIMD3(9, 0, 9), map: map))
    }

    func testNeverTwiceAboutTheSameCandidate() {
        var planner = ready()
        let subject = candidate()
        planner.noteAsked(subject, at: now.addingTimeInterval(-CuriosityPlanner.minimumGap - 1))
        XCTAssertFalse(planner.isEligible(subject, now: now))
        XCTAssertNil(ask(planner))
    }

    func testDecliningSuppressesThatCandidateForSevenDays() {
        var planner = ready()
        let subject = candidate()
        planner.noteDeclined(subject, at: now)

        XCTAssertFalse(
            planner.isEligible(subject, now: now.addingTimeInterval(CuriosityPlanner.suppression - 60))
        )
        XCTAssertTrue(
            planner.isEligible(subject, now: now.addingTimeInterval(CuriosityPlanner.suppression + 60))
        )
    }

    func testIgnoringSuppressesTheCandidateToo() {
        var planner = ready()
        let subject = candidate()
        planner.noteIgnored(subject, at: now)
        XCTAssertFalse(planner.isEligible(subject, now: now.addingTimeInterval(60)))
    }

    func testTwoIgnoresStopQuestionsForTheRestOfTheSession() {
        var planner = ready()
        planner.noteIgnored(candidate("a"), at: now)
        XCTAssertFalse(planner.isStoppedForSession)
        planner.noteIgnored(candidate("b"), at: now)
        XCTAssertTrue(planner.isStoppedForSession)
        XCTAssertEqual(
            planner.budgetAllows(
                now: now.addingTimeInterval(CuriosityPlanner.minimumGap * 10),
                userPosition: user,
                map: SemanticMap()
            ),
            .stoppedAfterIgnores
        )
    }

    func testANewSessionClearsTheStopButNotTheSuppression() {
        var planner = ready()
        let subject = candidate()
        planner.noteIgnored(subject, at: now)
        planner.noteIgnored(candidate("b"), at: now)
        planner.beginSession()

        XCTAssertFalse(planner.isStoppedForSession, "the stop is per session")
        XCTAssertFalse(
            planner.isEligible(subject, now: now.addingTimeInterval(60)),
            "suppression outlives the session"
        )
    }

    func testTheNeverTwiceRuleSurvivesARelaunch() throws {
        var planner = ready()
        let subject = candidate()
        planner.noteAsked(subject, at: now)

        let decoded = try JSONDecoder().decode(
            CuriosityPlanner.self,
            from: try JSONEncoder().encode(planner)
        )
        XCTAssertFalse(decoded.isEligible(subject, now: now.addingTimeInterval(86_400 * 30)))
    }

    // MARK: Asking from next to the thing

    func testAQuestionFromAcrossTheRoomIsNotAQuestion() {
        let planner = ready()
        let subject = candidate(at: 4)
        XCTAssertFalse(planner.isCloseEnoughToAsk(subject, birdPosition: .zero))
        XCTAssertTrue(planner.isCloseEnoughToAsk(subject, birdPosition: SIMD3(3.5, 0, 0)))
    }

    // MARK: Ranking and generation

    func testTheNearestThingToTheUsersAttentionIsAskedAboutFirst() {
        let planner = ready()
        let near = CuriosityPlanner.Candidate(
            id: "near", kind: .unnamedRegion, position: SIMD3(1, 0, 0), subject: "near"
        )
        let far = CuriosityPlanner.Candidate(
            id: "far", kind: .unnamedRegion, position: SIMD3(6, 0, 0), subject: "far"
        )
        let chosen = planner.next(
            from: [far, near],
            now: now,
            userPosition: .zero,
            attention: SIMD3(1.2, 0, 0),
            map: SemanticMap()
        )
        XCTAssertEqual(chosen?.id, "near")
    }

    func testDevicesWithNoSpatialBindingBecomeCandidates() {
        var map = SemanticMap()
        map.upsert(MapObject(name: "the lamp", position: .zero, deviceId: "light.lamp"))
        let candidates = CuriosityPlanner.candidates(
            in: map,
            deviceIds: ["light.lamp": "Lamp", "switch.coffee": "Coffee machine"]
        )
        let devices = candidates.filter { $0.kind == .unboundDevice }
        XCTAssertEqual(devices.map(\.subject), ["Coffee machine"])
    }

    func testPlacesWithNoActivityBecomeCandidates() {
        var map = SemanticMap()
        let desk = Place(name: "the desk", position: SIMD3(1, 0, 0), radius: 0.5)
        let couch = Place(name: "the couch", position: SIMD3(-1, 0, 0), radius: 0.5)
        map.upsert(desk)
        map.upsert(couch)
        map.upsert(Activity(name: "brainstorming", placeId: map.place(named: "the desk")?.id))

        let subjects = CuriosityPlanner.candidates(in: map)
            .filter { $0.kind == .placeWithoutActivity }
            .map(\.subject)
        XCTAssertEqual(subjects, ["the couch"])
    }

    func testARegionInsideATaughtPlaceIsNotUnnamed() {
        var map = SemanticMap()
        map.upsert(Place(name: "the study", position: .zero, radius: 2))
        let candidates = CuriosityPlanner.candidates(
            in: map, unnamedRegions: [SIMD3(0.5, 0, 0), SIMD3(8, 0, 0)]
        )
        XCTAssertEqual(candidates.filter { $0.kind == .unnamedRegion }.count, 1)
    }
}
