import Foundation
import simd

/// Which room the bird is in, and therefore which map is loaded.
///
/// Spec 07 §Persistence: map records persist keyed by room, with anchors re-resolved on
/// launch. `MapStore` has always taken a `roomId`; this is the piece that decides what to
/// pass it, so that a second room is a second map rather than a pile of names from two
/// places in one list.
///
/// Identification is by anchor, not by geometry. Two rooms of the same size are the same
/// floor plan and different rooms, and the only thing on the device that already knows the
/// difference is world tracking: a room is "the set of anchors that relocalize together".
@MainActor
public final class RoomRegistry: ObservableObject {
    /// One known room.
    public struct Room: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// User-facing, and optional: most people never name a room, and the map works
        /// without it.
        public var name: String?
        /// Anchors last seen in this room. Overlap is what identifies it on the next launch.
        public var anchorIds: Set<UUID>
        public var lastSeen: Date

        public init(
            id: String = UUID().uuidString,
            name: String? = nil,
            anchorIds: Set<UUID> = [],
            lastSeen: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.anchorIds = anchorIds
            self.lastSeen = lastSeen
        }
    }

    /// How much of a room's anchor set has to relocalize before it is *that* room.
    ///
    /// Low, deliberately: furniture moves, planes come and go, and a stale anchor should not
    /// cost the user every name they taught. The cost of a false match is one wrong map,
    /// which the inspector makes visible and a wipe fixes; the cost of a false miss is a
    /// bird that hatches blank in a room it has known for weeks.
    public static let matchFraction = 0.25
    public static let minimumMatches = 2

    @Published public private(set) var rooms: [Room] = []
    @Published public private(set) var currentRoomId: String

    private let defaults: UserDefaults
    private let storageKey = "io.medvr.SpatialAgent.rooms"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currentRoomId = "default"
        load()
        if rooms.isEmpty {
            let first = Room(id: "default")
            rooms = [first]
        }
        currentRoomId = rooms.max(by: { $0.lastSeen < $1.lastSeen })?.id ?? "default"
    }

    /// The store for the current room. Callers hold one at a time; switching rooms means
    /// asking again rather than mutating the one they have.
    public func store() -> MapStore {
        MapStore(defaults: defaults, roomId: currentRoomId)
    }

    // MARK: Identification

    /// Tells the registry which anchors have relocalized this session.
    ///
    /// Returns the room id now in force. When nothing matches, a new room is created rather
    /// than the current one being extended: merging an unknown space into a known map is how
    /// a kitchen ends up containing a bedroom's names.
    @discardableResult
    public func observe(relocalizedAnchors anchors: Set<UUID>) -> String {
        guard !anchors.isEmpty else { return currentRoomId }

        if let match = bestMatch(for: anchors) {
            currentRoomId = match.id
            update(match.id) { room in
                room.anchorIds.formUnion(anchors)
                room.lastSeen = Date()
            }
            persist()
            return currentRoomId
        }

        // An empty "default" room has never been anywhere; adopt it rather than leaving a
        // stranded empty map behind.
        if let empty = rooms.first(where: { $0.anchorIds.isEmpty }) {
            currentRoomId = empty.id
            update(empty.id) { room in
                room.anchorIds = anchors
                room.lastSeen = Date()
            }
            persist()
            return currentRoomId
        }

        let room = Room(anchorIds: anchors)
        rooms.append(room)
        currentRoomId = room.id
        persist()
        return currentRoomId
    }

    /// The room whose anchors overlap enough with what has relocalized.
    public func bestMatch(for anchors: Set<UUID>) -> Room? {
        var best: (Room, Int)?
        for room in rooms where !room.anchorIds.isEmpty {
            let overlap = room.anchorIds.intersection(anchors).count
            let needed = max(
                Self.minimumMatches,
                Int((Double(room.anchorIds.count) * Self.matchFraction).rounded(.up))
            )
            guard overlap >= needed else { continue }
            if best == nil || overlap > best!.1 { best = (room, overlap) }
        }
        return best?.0
    }

    public func name(_ name: String, roomId: String? = nil) {
        update(roomId ?? currentRoomId) { $0.name = name }
        persist()
    }

    /// Forgetting a room forgets its map too: a room record with no map is a name for
    /// nothing, and a map with no room is unreachable.
    public func forget(roomId: String) {
        MapStore(defaults: defaults, roomId: roomId).forgetEverything()
        rooms.removeAll { $0.id == roomId }
        if currentRoomId == roomId {
            // A forgotten room does not come back under its own id: reusing it would point
            // the next session's store at a key the user just erased.
            if let survivor = rooms.first {
                currentRoomId = survivor.id
            } else {
                let fresh = Room()
                rooms = [fresh]
                currentRoomId = fresh.id
            }
        }
        persist()
    }

    public var currentRoom: Room? { rooms.first { $0.id == currentRoomId } }

    // MARK: Storage

    private func update(_ id: String, _ body: (inout Room) -> Void) {
        guard let index = rooms.firstIndex(where: { $0.id == id }) else { return }
        body(&rooms[index])
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rooms) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Room].self, from: data)
        else { return }
        rooms = decoded
    }
}
