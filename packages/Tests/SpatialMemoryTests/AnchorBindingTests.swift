import XCTest
import simd
@testable import SpatialMemory

/// Spec 07 §Model, anchoring. Everything here runs against a mock provider, because the
/// property under test — that a taught place lands in the same physical spot after a
/// relaunch — is about what the map does with relocalization events, not about ARKit.
@MainActor
final class AnchorBindingTests: XCTestCase {
    /// Stands in for `WorldTrackingProvider`.
    private final class MockAnchorProvider: AnchorProviding {
        var onAnchorUpdate: ((UUID, SIMD3<Float>?) -> Void)?
        var added: [UUID: SIMD3<Float>] = [:]
        var removed: [UUID] = []
        /// When false, world tracking is unavailable and nothing can be anchored.
        var isAvailable = true

        func addAnchor(at position: SIMD3<Float>) async -> UUID? {
            guard isAvailable else { return nil }
            let id = UUID()
            added[id] = position
            return id
        }

        func removeAnchor(id: UUID) async {
            removed.append(id)
        }

        /// The system finding the anchor again, at wherever it actually is.
        func relocalize(_ id: UUID, at position: SIMD3<Float>) {
            onAnchorUpdate?(id, position)
        }

        func lose(_ id: UUID) {
            onAnchorUpdate?(id, nil)
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "anchor-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeBinding() -> (AnchorBinding, MapStore, MockAnchorProvider) {
        let store = MapStore(defaults: defaults())
        let provider = MockAnchorProvider()
        return (AnchorBinding(store: store, provider: provider), store, provider)
    }

    // MARK: Relocalization updates the cache

    func testRelocalizationUpdatesTheCachedTransform() async {
        let (binding, store, provider) = makeBinding()
        let anchorId = await binding.anchor(at: SIMD3(1, 0, 1))
        store.add(Place(name: "desk", position: SIMD3(1, 0, 1), anchorId: anchorId))

        // The room was re-scanned and the desk is actually 12cm further along.
        provider.relocalize(try! XCTUnwrap(anchorId), at: SIMD3(1.12, 0, 1))

        let desk = try! XCTUnwrap(store.resolve("desk"))
        XCTAssertEqual(desk.position.x, 1.12, accuracy: 1e-5)
        XCTAssertTrue(desk.isNavigable)
    }

    func testRelocalizationUpdatesEveryRecordOnTheSameAnchor() async {
        let (binding, store, provider) = makeBinding()
        let anchorId = await binding.anchor(at: .zero)
        store.add(Place(name: "desk", position: .zero, anchorId: anchorId))
        store.add(MapObject(name: "lamp", position: .zero, anchorId: anchorId))
        store.add(Rule(name: "papers", kind: .fragile, severity: .soft, position: .zero,
                       anchorId: anchorId))

        provider.relocalize(try! XCTUnwrap(anchorId), at: SIMD3(0, 0, 2))

        XCTAssertEqual(store.map.places[0].position.z, 2, accuracy: 1e-5)
        XCTAssertEqual(store.map.objects[0].position.z, 2, accuracy: 1e-5)
        XCTAssertEqual(store.map.rules[0].position.z, 2, accuracy: 1e-5)
    }

    func testRelocalizationIsPersisted() async {
        let defaults = self.defaults()
        let store = MapStore(defaults: defaults)
        let provider = MockAnchorProvider()
        let binding = AnchorBinding(store: store, provider: provider)
        let anchorId = await binding.anchor(at: .zero)
        store.add(Place(name: "desk", position: .zero, anchorId: anchorId))
        provider.relocalize(try! XCTUnwrap(anchorId), at: SIMD3(3, 0, 0))

        // Quit and relaunch in the same room.
        let reloaded = MapStore(defaults: defaults)
        XCTAssertEqual(reloaded.resolve("desk")?.position.x, 3)
    }

    // MARK: Never relocalized is not navigable

    func testARecordWhoseAnchorNeverRelocalizesIsNotNavigable() async {
        // The provider is held for the length of the test: `AnchorBinding` holds it weakly,
        // exactly as the app does, where the scene provider outlives the binding.
        let (binding, store, provider) = makeBinding()
        _ = provider
        let anchorId = await binding.anchor(at: SIMD3(1, 0, 1))
        store.add(Place(name: "desk", position: SIMD3(1, 0, 1), anchorId: anchorId))

        let desk = try! XCTUnwrap(store.resolve("desk"))
        XCTAssertFalse(desk.isNavigable)
        XCTAssertEqual(store.map.nonNavigablePlaces.count, 1)
        XCTAssertFalse(binding.hasRelocalized(anchorId))
    }

    func testALostAnchorStopsBeingNavigableWithoutMovingTheRecord() async {
        let (binding, store, provider) = makeBinding()
        let anchorId = await binding.anchor(at: SIMD3(1, 0, 1))
        store.add(Place(name: "desk", position: SIMD3(1, 0, 1), anchorId: anchorId))
        provider.relocalize(try! XCTUnwrap(anchorId), at: SIMD3(1, 0, 1))
        XCTAssertTrue(try XCTUnwrap(store.resolve("desk")).isNavigable)

        provider.lose(try! XCTUnwrap(anchorId))
        let desk = try! XCTUnwrap(store.resolve("desk"))
        XCTAssertFalse(desk.isNavigable, "a lost anchor must not stay navigable")
        // The cached position survives so the inspector can still show roughly where it was.
        XCTAssertEqual(desk.position, SIMD3(1, 0, 1))
    }

    func testARecordWithNoAnchorAtAllStaysNavigable() {
        let (binding, store, provider) = makeBinding()
        _ = (binding, provider)
        store.add(Place(name: "fixture", position: .zero))
        XCTAssertTrue(try! XCTUnwrap(store.resolve("fixture")).isNavigable)
        XCTAssertTrue(store.map.nonNavigablePlaces.isEmpty)
    }

    func testWorldTrackingUnavailableStillStoresTheRecord() async {
        let (binding, store, provider) = makeBinding()
        provider.isAvailable = false
        let anchorId = await binding.anchor(at: SIMD3(2, 0, 0))
        XCTAssertNil(anchorId)
        store.add(Place(name: "desk", position: SIMD3(2, 0, 0), anchorId: anchorId))
        XCTAssertNotNil(store.resolve("desk"))
        XCTAssertTrue(try! XCTUnwrap(store.resolve("desk")).isNavigable)
    }

    // MARK: Orphans

    func testDeletingARecordReleasesItsAnchor() async {
        let (binding, store, provider) = makeBinding()
        let created = await binding.anchor(at: .zero)
        let anchorId = try! XCTUnwrap(created)
        store.add(Place(name: "desk", position: .zero, anchorId: anchorId))
        provider.relocalize(anchorId, at: .zero)

        store.delete(id: store.map.places[0].id)
        await binding.releaseOrphanedAnchors()
        XCTAssertEqual(provider.removed, [anchorId])
    }

    func testAnAnchorStillInUseIsNotReleased() async {
        let (binding, store, provider) = makeBinding()
        let created = await binding.anchor(at: .zero)
        let anchorId = try! XCTUnwrap(created)
        store.add(Place(name: "desk", position: .zero, anchorId: anchorId))
        store.add(MapObject(name: "lamp", position: .zero, anchorId: anchorId))
        provider.relocalize(anchorId, at: .zero)

        store.delete(id: store.map.places[0].id)
        await binding.releaseOrphanedAnchors()
        XCTAssertTrue(provider.removed.isEmpty, "the lamp is still on that anchor")
    }

    func testUnknownAnchorUpdatesAreHarmless() {
        let (binding, store, provider) = makeBinding()
        _ = binding
        store.add(Place(name: "desk", position: .zero))
        provider.relocalize(UUID(), at: SIMD3(9, 9, 9))
        XCTAssertEqual(store.resolve("desk")?.position, .zero)
    }
}
