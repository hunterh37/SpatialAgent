import Foundation
import simd

/// The world-tracking side of anchoring, as a protocol so the map can be tested without a
/// headset and without ARKit.
///
/// Spec 07 §Model: the anchor is authoritative and the cached transform is what makes the map
/// usable before relocalization completes. That means two operations — create an anchor when
/// something is taught, and hear about it when the system finds it again.
@MainActor
public protocol AnchorProviding: AnyObject {
    /// Creates a world anchor at a position. Nil when world tracking is unavailable, in which
    /// case the record is stored with a cached position and no anchor.
    func addAnchor(at position: SIMD3<Float>) async -> UUID?

    /// Removes an anchor that no record refers to any more.
    func removeAnchor(id: UUID) async

    /// Called when an anchor relocalizes or moves. A nil position means the system dropped it.
    var onAnchorUpdate: ((UUID, SIMD3<Float>?) -> Void)? { get set }
}

/// Keeps a `SemanticMap`'s cached transforms in step with world tracking.
///
/// This is the type that makes "taught places land in the same physical spot after a
/// relaunch" true. Relocalization updates the cache; a record whose anchor never comes back
/// is left flagged non-navigable rather than used at a stale position, because walking to
/// where the desk was yesterday is worse than saying the desk is somewhere in this room.
@MainActor
public final class AnchorBinding {
    private weak var provider: AnchorProviding?
    private let store: MapStore

    /// Anchors seen this session, with their latest position.
    public private(set) var relocalized: [UUID: SIMD3<Float>] = [:]
    /// Anchors world tracking has told us it lost.
    public private(set) var dropped: Set<UUID> = []

    public init(store: MapStore, provider: AnchorProviding?) {
        self.store = store
        self.provider = provider
        provider?.onAnchorUpdate = { [weak self] id, position in
            self?.anchorUpdated(id: id, position: position)
        }
    }

    /// Anchors a position before a record is written. Returns nil when tracking is
    /// unavailable; the caller still stores the record, just without an anchor.
    public func anchor(at position: SIMD3<Float>) async -> UUID? {
        await provider?.addAnchor(at: position)
    }

    /// Applies a relocalization to every record bound to that anchor.
    public func anchorUpdated(id: UUID, position: SIMD3<Float>?) {
        guard let position else {
            dropped.insert(id)
            relocalized[id] = nil
            store.mutate { Self.markLost(anchorId: id, in: &$0) }
            return
        }
        dropped.remove(id)
        relocalized[id] = position
        store.mutate { Self.relocalize(anchorId: id, to: position, in: &$0) }
    }

    /// True once world tracking has found this anchor in this session.
    public func hasRelocalized(_ anchorId: UUID?) -> Bool {
        guard let anchorId else { return true }
        return relocalized[anchorId] != nil
    }

    /// Releases anchors nothing refers to any more. Called after a deletion or a wipe.
    public func releaseOrphanedAnchors() async {
        let live = Set(store.map.places.compactMap(\.anchor.anchorId))
            .union(store.map.objects.compactMap(\.anchor.anchorId))
            .union(store.map.rules.compactMap(\.anchor.anchorId))
        for id in relocalized.keys where !live.contains(id) {
            await provider?.removeAnchor(id: id)
            relocalized[id] = nil
        }
    }

    // MARK: - Map mutation

    /// Relocalization updates the cache — for every record on that anchor, in one pass, so a
    /// place and an object sharing an anchor cannot end up disagreeing about where it is.
    public static func relocalize(
        anchorId: UUID,
        to position: SIMD3<Float>,
        in map: inout SemanticMap
    ) {
        map.updateAnchors(matching: anchorId) { anchor in
            anchor.position = position
            anchor.hasRelocalized = true
        }
    }

    /// A dropped anchor does not move the record; it only stops it being navigable. The
    /// cached position stays so the inspector can still highlight roughly where it was.
    public static func markLost(anchorId: UUID, in map: inout SemanticMap) {
        map.updateAnchors(matching: anchorId) { anchor in
            anchor.hasRelocalized = false
        }
    }
}

public extension SemanticMap {
    /// Applies a change to every anchored record bound to one anchor.
    mutating func updateAnchors(matching anchorId: UUID, _ body: (inout AnchorRef) -> Void) {
        for index in places.indices where places[index].anchor.anchorId == anchorId {
            body(&places[index].anchor)
        }
        for index in objects.indices where objects[index].anchor.anchorId == anchorId {
            body(&objects[index].anchor)
        }
        for index in rules.indices where rules[index].anchor.anchorId == anchorId {
            body(&rules[index].anchor)
        }
    }

    /// Records that cannot be navigated to because their anchor has never come back. The
    /// inspector shows these as "somewhere in this room".
    var nonNavigablePlaces: [Place] { places.filter { !$0.isNavigable } }
}
