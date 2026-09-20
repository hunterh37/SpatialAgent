import XCTest
@testable import SpatialMemory

/// Spec 07 §Persistence: maps are keyed by room, with anchors re-resolved on launch.
@MainActor
final class RoomRegistryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "rooms-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func anchors(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    func testAFirstRoomAdoptsTheDefaultMapRatherThanStrandingIt() {
        let defaults = self.defaults()
        let registry = RoomRegistry(defaults: defaults)
        let store = registry.store()
        store.add(Place(name: "the desk", position: .zero))

        let ids = anchors(4)
        let roomId = registry.observe(relocalizedAnchors: Set(ids))
        XCTAssertEqual(roomId, "default")
        XCTAssertEqual(registry.store().map.places.count, 1, "the taught place was stranded")
    }

    func testTheSameRoomIsRecognisedOnTheNextLaunch() {
        let defaults = self.defaults()
        let ids = anchors(8)

        let first = RoomRegistry(defaults: defaults)
        let roomId = first.observe(relocalizedAnchors: Set(ids))
        first.store().add(Place(name: "the desk", position: .zero))

        // Relaunch: only some anchors come back, which is the normal case.
        let second = RoomRegistry(defaults: defaults)
        XCTAssertEqual(second.observe(relocalizedAnchors: Set(ids.prefix(3))), roomId)
        XCTAssertNotNil(second.store().resolve("the desk"))
    }

    func testADifferentRoomGetsItsOwnMap() {
        let defaults = self.defaults()
        let registry = RoomRegistry(defaults: defaults)

        registry.observe(relocalizedAnchors: Set(anchors(6)))
        registry.store().add(Place(name: "the desk", position: .zero))

        let second = registry.observe(relocalizedAnchors: Set(anchors(6)))
        XCTAssertNotEqual(second, registry.rooms[0].id)
        XCTAssertTrue(registry.store().map.isEmpty, "a new room must not inherit names")

        // And the first room's map is still there.
        registry.observe(relocalizedAnchors: registry.rooms[0].anchorIds)
        XCTAssertNotNil(registry.store().resolve("the desk"))
    }

    func testOneSharedAnchorIsNotAMatch() {
        let defaults = self.defaults()
        let registry = RoomRegistry(defaults: defaults)
        let known = anchors(8)
        let roomId = registry.observe(relocalizedAnchors: Set(known))

        let strangerWithOneOverlap = Set([known[0]] + anchors(5))
        XCTAssertNotEqual(registry.observe(relocalizedAnchors: strangerWithOneOverlap), roomId)
    }

    func testSeeingNothingKeepsTheCurrentRoom() {
        let registry = RoomRegistry(defaults: defaults())
        let before = registry.currentRoomId
        XCTAssertEqual(registry.observe(relocalizedAnchors: []), before)
    }

    func testRoomsPersistAcrossLaunches() {
        let defaults = self.defaults()
        let ids = anchors(5)
        RoomRegistry(defaults: defaults).observe(relocalizedAnchors: Set(ids))

        let reloaded = RoomRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.rooms.count, 1)
        XCTAssertEqual(reloaded.rooms[0].anchorIds.count, 5)
    }

    func testForgettingARoomForgetsItsMap() {
        let defaults = self.defaults()
        let registry = RoomRegistry(defaults: defaults)
        let roomId = registry.observe(relocalizedAnchors: Set(anchors(5)))
        registry.store().add(Place(name: "the desk", position: .zero))

        registry.forget(roomId: roomId)
        XCTAssertFalse(registry.rooms.contains { $0.id == roomId })
        XCTAssertTrue(MapStore(defaults: defaults, roomId: roomId).map.isEmpty)
    }

    func testARoomCanBeNamedButDoesNotHaveToBe() {
        let registry = RoomRegistry(defaults: defaults())
        XCTAssertNil(registry.currentRoom?.name)
        registry.name("the study")
        XCTAssertEqual(registry.currentRoom?.name, "the study")
    }
}
