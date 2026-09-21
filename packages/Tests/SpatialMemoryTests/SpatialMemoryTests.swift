import XCTest
import simd
@testable import SpatialMemory

/// Spec 07 §Model and §Inspection.
final class SemanticMapTests: XCTestCase {
    private func place(_ name: String, at x: Float = 0, radius: Float = 0.5) -> Place {
        Place(name: name, position: SIMD3(x, 0, 0), radius: radius)
    }

    // MARK: Identity and collisions

    func testANameCollisionIsACorrectionNotASecondRecord() {
        var map = SemanticMap()
        guard case let .created(id) = map.upsert(place("Kitchen", at: 1)) else {
            return XCTFail("first teach should create")
        }
        let outcome = map.upsert(place("kitchen", at: 3))
        XCTAssertEqual(outcome, .corrected(id), "a second teach of the same name is a correction")
        XCTAssertEqual(map.places.count, 1)
        XCTAssertEqual(map.places[0].position.x, 3, "the correction should have moved it")
    }

    func testCorrectionKeepsTheIdentitySoReferencesSurvive() {
        var map = SemanticMap()
        guard case let .created(placeId) = map.upsert(place("desk")) else { return XCTFail() }
        map.upsert(Activity(name: "writing", placeId: placeId))
        map.upsert(place("Desk", at: 2))
        XCTAssertEqual(map.activities[0].placeId, placeId)
        XCTAssertNotNil(map.place(id: placeId))
    }

    func testNameKeyIgnoresCaseAndSurroundingWhitespace() {
        var map = SemanticMap()
        map.upsert(place("  Kitchen  "))
        XCTAssertNotNil(map.place(named: "kitchen"))
        XCTAssertNotNil(map.place(named: "KITCHEN"))
        XCTAssertEqual(map.places.count, 1)
    }

    func testLookupIsExactNotFuzzy() {
        var map = SemanticMap()
        map.upsert(place("kitchen"))
        XCTAssertNil(map.place(named: "kitchn"))
        XCTAssertNil(map.place(named: "the kitchen"))
    }

    func testCorrectionPreservesUseCountAndTaughtAt() {
        var map = SemanticMap()
        guard case let .created(id) = map.upsert(place("couch")) else { return XCTFail() }
        map.noteUse(placeId: id)
        map.noteUse(placeId: id)
        let taughtAt = map.places[0].taughtAt
        map.upsert(place("couch", at: 4))
        XCTAssertEqual(map.places[0].useCount, 2)
        XCTAssertEqual(map.places[0].taughtAt, taughtAt)
    }

    func testObjectsAndPlacesDoNotShareANamespace() {
        var map = SemanticMap()
        map.upsert(place("kitchen"))
        map.upsert(MapObject(name: "kitchen", position: SIMD3(1, 0, 1)))
        XCTAssertEqual(map.places.count, 1)
        XCTAssertEqual(map.objects.count, 1)
    }

    func testRenamingToATakenNameIsRefusedRatherThanMerged() {
        var map = SemanticMap()
        guard case let .created(deskId) = map.upsert(place("desk")) else { return XCTFail() }
        map.upsert(place("kitchen", at: 2))
        XCTAssertFalse(map.rename(placeId: deskId, to: "Kitchen"))
        XCTAssertEqual(map.place(named: "desk")?.id, deskId)
        XCTAssertEqual(map.places.count, 2)
    }

    func testRenamingToAFreeNameSucceeds() {
        var map = SemanticMap()
        guard case let .created(id) = map.upsert(place("desk")) else { return XCTFail() }
        XCTAssertTrue(map.rename(placeId: id, to: "workbench"))
        XCTAssertNotNil(map.place(named: "workbench"))
        XCTAssertNil(map.place(named: "desk"))
    }

    // MARK: Containment

    func testSmallestContainingPlaceWins() {
        var map = SemanticMap()
        map.upsert(Place(name: "study", position: .zero, radius: 3))
        map.upsert(Place(name: "desk", position: SIMD3(0.2, 0, 0), radius: 0.6))
        XCTAssertEqual(map.containingPlace(of: SIMD3(0.1, 0, 0))?.name, "desk")
        XCTAssertEqual(map.containingPlace(of: SIMD3(2, 0, 0))?.name, "study")
        XCTAssertNil(map.containingPlace(of: SIMD3(9, 0, 0)))
    }

    func testPlacesContainingReturnsEveryOverlap() {
        var map = SemanticMap()
        map.upsert(Place(name: "study", position: .zero, radius: 3))
        map.upsert(Place(name: "desk", position: .zero, radius: 0.6))
        XCTAssertEqual(map.placesContaining(.zero).count, 2)
    }

    // MARK: Rules

    func testForbiddenIsAlwaysHardEvenWhenAskedForSoft() {
        let rule = Rule(name: "the shrine", kind: .forbidden, severity: .soft, position: .zero)
        XCTAssertEqual(rule.severity, .hard)
    }

    func testSoftKindsKeepTheirSeverity() {
        let rule = Rule(name: "the vase", kind: .fragile, severity: .soft, position: .zero)
        XCTAssertEqual(rule.severity, .soft)
    }

    func testForbiddenRegionsAreWhatTheNavmeshWillSubtract() {
        var map = SemanticMap()
        map.upsert(Rule(name: "shrine", kind: .forbidden, position: .zero, radius: 1))
        map.upsert(Rule(name: "vase", kind: .fragile, severity: .soft, position: SIMD3(3, 0, 0)))
        map.upsert(Rule(name: "study", kind: .quiet, severity: .soft, position: SIMD3(6, 0, 0)))
        XCTAssertEqual(map.forbiddenRegions.count, 1)
        XCTAssertEqual(map.forbiddenRegions[0].name, "shrine")
    }

    func testEveryRuleKindHasPlainLanguageForTheUser() {
        for kind in Rule.Kind.allCases {
            let rule = Rule(name: "x", kind: kind, position: .zero)
            XCTAssertFalse(rule.plainLanguage.isEmpty)
        }
    }

    func testRulesOfTheSameNameButDifferentKindCoexist() {
        var map = SemanticMap()
        map.upsert(Rule(name: "the shelf", kind: .forbidden, position: .zero))
        map.upsert(Rule(name: "the shelf", kind: .quiet, severity: .soft, position: .zero))
        XCTAssertEqual(map.rules.count, 2)
    }

    // MARK: Activities

    func testActivityBandsSurviveAReTeach() {
        var map = SemanticMap()
        map.upsert(Activity(name: "brainstorm", bands: [.init(startMinute: 540, endMinute: 660)]))
        map.upsert(Activity(name: "Brainstorm", placeId: UUID()))
        XCTAssertEqual(map.activities.count, 1)
        XCTAssertEqual(map.activities[0].bands.count, 1, "observed evidence was erased")
    }

    func testBandsWrapMidnight() {
        let band = Activity.Band(startMinute: 1380, endMinute: 120)
        XCTAssertTrue(band.contains(minute: 1400))
        XCTAssertTrue(band.contains(minute: 30))
        XCTAssertFalse(band.contains(minute: 600))
    }

    func testActivityIsActiveInsideItsBand() {
        let activity = Activity(name: "brainstorm", bands: [.init(startMinute: 540, endMinute: 660)])
        XCTAssertTrue(activity.isActive(atMinute: 600))
        XCTAssertFalse(activity.isActive(atMinute: 61))
    }

    // MARK: Anchors

    func testARecordThatNeverRelocalizedIsNotNavigable() {
        let taught = Place(name: "desk", position: .zero, anchorId: UUID(), hasRelocalized: false)
        XCTAssertFalse(taught.isNavigable)
        let relocalized = Place(name: "desk", position: .zero, anchorId: UUID(), hasRelocalized: true)
        XCTAssertTrue(relocalized.isNavigable)
    }

    func testAnUnanchoredRecordIsTrusted() {
        XCTAssertTrue(Place(name: "fixture", position: .zero).isNavigable)
    }

    // MARK: Deletion

    func testDeletionIsCompleteIncludingEpisodes() {
        var map = SemanticMap()
        guard case let .created(id) = map.upsert(place("kitchen")) else { return XCTFail() }
        map.record(Episode(placeId: id, kind: .taught, summary: "taught kitchen"))
        map.record(Episode(placeId: id, kind: .visited, summary: "went to kitchen"))
        map.record(Episode(kind: .acted, summary: "turned something off"))

        XCTAssertTrue(map.delete(id: id))
        XCTAssertTrue(map.places.isEmpty)
        XCTAssertEqual(map.episodes.count, 1, "episodes naming the record must go too")
        XCTAssertFalse(map.episodes.contains { $0.references(id) })
    }

    func testDeletionClearsPointersWithoutDeletingThePointers() {
        var map = SemanticMap()
        guard case let .created(placeId) = map.upsert(place("study")) else { return XCTFail() }
        map.upsert(MapObject(name: "lamp", position: .zero, placeId: placeId))
        map.upsert(Activity(name: "reading", placeId: placeId))

        map.delete(id: placeId)
        XCTAssertEqual(map.objects.count, 1)
        XCTAssertNil(map.objects[0].placeId)
        XCTAssertEqual(map.activities.count, 1)
        XCTAssertNil(map.activities[0].placeId)
    }

    func testDeletingSomethingAbsentReportsFalse() {
        var map = SemanticMap()
        XCTAssertFalse(map.delete(id: UUID()))
    }

    func testWipeLeavesNoResidue() {
        var map = SemanticMap()
        map.upsert(place("kitchen"))
        map.upsert(MapObject(name: "kettle", position: .zero))
        map.upsert(Rule(name: "shrine", kind: .forbidden, position: .zero))
        map.upsert(Activity(name: "tea"))
        map.record(Episode(kind: .taught, summary: "taught kettle"))

        map.wipe()
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(map.totalRecordCount, 0)
        XCTAssertTrue(map.episodes.isEmpty)
    }

    // MARK: Disambiguation (spec 07 §Disambiguation)

    func testTeachingInsideAnExistingPlaceNeverSilentlyOverwrites() {
        var map = SemanticMap()
        map.upsert(Place(name: "the study", position: .zero, radius: 1.5))
        let inside = SIMD3<Float>(0.4, 0, 0.2)

        // Naming something else inside it is a question, not a write.
        let clash = map.needsDisambiguation(naming: "the desk", at: inside)
        XCTAssertEqual(clash?.name, "the study")
        XCTAssertEqual(map.places.count, 1)
        XCTAssertNotNil(map.place(named: "the study"))

        // Answer one: rename the existing place. One record, the new name, same identity.
        var renamed = map
        let studyId = try! XCTUnwrap(renamed.place(named: "the study")).id
        XCTAssertTrue(renamed.rename(placeId: studyId, to: "the desk"))
        XCTAssertEqual(renamed.places.count, 1)
        XCTAssertEqual(renamed.place(named: "the desk")?.id, studyId)

        // Answer two: nest an object inside it. Both records survive.
        var nested = map
        nested.upsert(MapObject(name: "the desk", position: inside, placeId: studyId))
        XCTAssertNotNil(nested.place(named: "the study"))
        XCTAssertNotNil(nested.object(named: "the desk"))
        XCTAssertEqual(nested.nestedObjects(in: nested.places[0]).count, 1)
    }

    func testReTeachingTheSameNameDoesNotAsk() {
        var map = SemanticMap()
        map.upsert(Place(name: "the study", position: .zero, radius: 1.5))
        XCTAssertNil(map.needsDisambiguation(naming: "The Study", at: SIMD3(0.2, 0, 0)))
    }

    func testNamingOutsideEveryPlaceDoesNotAsk() {
        var map = SemanticMap()
        map.upsert(Place(name: "the study", position: .zero, radius: 0.5))
        XCTAssertNil(map.needsDisambiguation(naming: "the kitchen", at: SIMD3(4, 0, 4)))
    }

    // MARK: Persistence round trip

    func testRoundTripsThroughJSON() throws {
        var map = SemanticMap(roomId: "living-room")
        map.upsert(Place(name: "kitchen", position: SIMD3(1, 0, 2), radius: 0.9, kind: .workspace))
        map.upsert(MapObject(name: "kettle", position: SIMD3(1, 1, 2), deviceId: "device-1"))
        map.upsert(Rule(name: "shrine", kind: .forbidden, position: SIMD3(4, 0, 4), radius: 1))
        map.upsert(Activity(name: "tea", bands: [.init(startMinute: 400, endMinute: 500)]))
        map.record(Episode(kind: .taught, summary: "taught the kettle"))

        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(SemanticMap.self, from: data)
        XCTAssertEqual(decoded, map)
        XCTAssertEqual(decoded.roomId, "living-room")
        XCTAssertEqual(decoded.objects[0].deviceId, "device-1")
    }
}

/// `MapStore` owns persistence, migration and the wipe.
@MainActor
final class MapStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "map-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testRecordsSurviveARelaunch() {
        let defaults = self.defaults()
        let first = MapStore(defaults: defaults)
        first.add(Place(name: "kitchen", position: SIMD3(2, 0, -1), radius: 0.8))
        first.record(Episode(kind: .taught, summary: "taught the kitchen"))

        let second = MapStore(defaults: defaults)
        XCTAssertEqual(second.map.places.count, 1)
        XCTAssertEqual(second.resolve("Kitchen")?.radius, 0.8)
        XCTAssertEqual(second.map.episodes.count, 1)
    }

    func testRoomsArePersistedSeparately() {
        let defaults = self.defaults()
        MapStore(defaults: defaults, roomId: "study").add(Place(name: "desk", position: .zero))
        let kitchen = MapStore(defaults: defaults, roomId: "kitchen")
        XCTAssertTrue(kitchen.map.isEmpty)
    }

    func testLegacyNamedPlacesAreMigratedRatherThanDropped() throws {
        let defaults = self.defaults()
        // Exactly what `NamedPlaceStore` wrote.
        struct LegacyPlace: Codable {
            var name: String
            var position: SIMD3<Float>
            var radius: Float
            var anchorId: UUID?
        }
        let legacy = [
            LegacyPlace(name: "kitchen", position: SIMD3(2, 0, -1), radius: 0.9, anchorId: nil),
            LegacyPlace(name: "desk", position: SIMD3(-1, 0, -2), radius: 0.6, anchorId: nil),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "io.medvr.SpatialAgent.places")

        let store = MapStore(defaults: defaults)
        XCTAssertEqual(store.map.places.count, 2)
        XCTAssertEqual(store.resolve("desk")?.radius, 0.6)
        // And the migration happens once.
        XCTAssertNil(defaults.data(forKey: "io.medvr.SpatialAgent.places"))
    }

    func testForgetEverythingLeavesNothingOnDisk() {
        let defaults = self.defaults()
        let store = MapStore(defaults: defaults)
        store.add(Place(name: "kitchen", position: .zero))
        store.add(Rule(name: "shrine", kind: .forbidden, position: .zero))
        store.record(Episode(kind: .taught, summary: "taught the kitchen"))

        store.forgetEverything()
        XCTAssertTrue(store.map.isEmpty)

        let reloaded = MapStore(defaults: defaults)
        XCTAssertTrue(reloaded.map.isEmpty, "a wipe that a relaunch can undo is not a wipe")
    }

    func testDeleteIsPersistedImmediately() {
        let defaults = self.defaults()
        let store = MapStore(defaults: defaults)
        store.add(Place(name: "kitchen", position: .zero))
        let id = store.map.places[0].id
        store.delete(id: id)
        XCTAssertTrue(MapStore(defaults: defaults).map.isEmpty)
    }

    func testTeachingTheSameNameTwiceIsReportedAsACorrection() {
        let store = MapStore(defaults: defaults())
        _ = store.add(Place(name: "kitchen", position: .zero))
        let outcome = store.add(Place(name: "Kitchen", position: SIMD3(1, 0, 1)))
        if case .created = outcome { XCTFail("second teach should be a correction") }
    }

    func testSnapshotCarriesTaughtPlaces() {
        let store = MapStore(defaults: defaults())
        store.add(Place(name: "kitchen", position: SIMD3(2, 0, -1), radius: 0.9))
        let snapshot = store.snapshot(userPosition: SIMD3(0, 0, 0), floorArea: 18)
        XCTAssertEqual(snapshot.places.count, 1)
        XCTAssertEqual(snapshot.places[0].name, "kitchen")
    }

    /// Rooms already on disk carry the perch `set_home_perch` used to mint. Loading demotes
    /// it: the record and its anchor stay, the role goes, and the learned choice stops
    /// narrating a name the room has no colour for.
    func testLoadDemotesAPerchTheRoomHasNoColourFor() {
        let defaults = defaults()
        let store = MapStore(defaults: defaults)
        store.add(Place(name: "the red perch", position: SIMD3(-1, 0, -1), kind: .perch, elevation: 1))
        store.add(Place(name: "your perch", position: SIMD3(0, 0, -1), kind: .perch, elevation: 1))

        let reloaded = MapStore(defaults: defaults)

        XCTAssertEqual(reloaded.map.perches.map(\.name), ["the red perch"])
        let stray = reloaded.map.place(named: "your perch")
        XCTAssertEqual(stray?.kind, .generic, "kept, with its anchor")
        XCTAssertEqual(stray?.position, SIMD3(0, 0, -1))
        XCTAssertNil(PerchMemory.candidates(in: reloaded.map).first { $0.name == "your perch" })

        // One way: the demotion is written back, so a third load sees it already done.
        XCTAssertEqual(MapStore(defaults: defaults).map.place(named: "your perch")?.kind, .generic)
    }
}
