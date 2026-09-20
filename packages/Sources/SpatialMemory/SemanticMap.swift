import AgentProtocol
import Foundation
import simd

/// Everything the bird has been taught about one room (spec 07 §Model).
///
/// A value type: the map is user data, and making it a value makes "what exactly did that
/// teaching act change" answerable by comparing two of them. `MapStore` owns persistence and
/// observation; this owns the semantics.
public struct SemanticMap: Codable, Hashable, Sendable {
    /// Rooms are keyed by relocalized room identifier. Multi-room maps land in phase E; the
    /// key exists now so that persistence does not have to be rewritten when they do.
    public var roomId: String

    public internal(set) var places: [Place] = []
    public internal(set) var objects: [MapObject] = []
    public internal(set) var rules: [Rule] = []
    public internal(set) var activities: [Activity] = []
    /// Append-only.
    public internal(set) var episodes: [Episode] = []

    public init(roomId: String = "default") {
        self.roomId = roomId
    }

    // MARK: - Collision semantics

    /// What an upsert did. The caller needs to know, because a correction is spoken back
    /// differently from a new name ("that's the kitchen now" vs "okay, the kitchen").
    public enum Outcome: Equatable, Sendable {
        case created(UUID)
        case corrected(UUID)
    }

    /// Teaching a name that already exists updates the existing record and the bird says so
    /// (spec 07 §Model). It never creates a second record with the same name, and it never
    /// silently discards the old one — the id survives, which is what keeps episodes and
    /// activities pointing at the right thing through a correction.
    @discardableResult
    public mutating func upsert(_ place: Place) -> Outcome {
        if let index = places.firstIndex(where: { $0.nameKey == place.nameKey }) {
            let id = places[index].id
            var updated = place
            updated.id = id
            updated.useCount = places[index].useCount
            updated.taughtAt = places[index].taughtAt
            places[index] = updated
            return .corrected(id)
        }
        places.append(place)
        return .created(place.id)
    }

    @discardableResult
    public mutating func upsert(_ object: MapObject) -> Outcome {
        if let index = objects.firstIndex(where: { $0.nameKey == object.nameKey }) {
            let id = objects[index].id
            var updated = object
            updated.id = id
            updated.useCount = objects[index].useCount
            updated.taughtAt = objects[index].taughtAt
            objects[index] = updated
            return .corrected(id)
        }
        objects.append(object)
        return .created(object.id)
    }

    @discardableResult
    public mutating func upsert(_ rule: Rule) -> Outcome {
        if let index = rules.firstIndex(where: { $0.nameKey == rule.nameKey && $0.kind == rule.kind }) {
            let id = rules[index].id
            var updated = rule
            updated.id = id
            updated.taughtAt = rules[index].taughtAt
            rules[index] = updated
            return .corrected(id)
        }
        rules.append(rule)
        return .created(rule.id)
    }

    @discardableResult
    public mutating func upsert(_ activity: Activity) -> Outcome {
        if let index = activities.firstIndex(where: { $0.nameKey == activity.nameKey }) {
            let id = activities[index].id
            var updated = activity
            updated.id = id
            // Observed bands are evidence, not authorship: a re-teach never erases them.
            updated.bands = activities[index].bands.isEmpty
                ? activity.bands
                : activities[index].bands
            updated.taughtAt = activities[index].taughtAt
            activities[index] = updated
            return .corrected(id)
        }
        activities.append(activity)
        return .created(activity.id)
    }

    /// Episodes are append-only and never merge.
    public mutating func record(_ episode: Episode) {
        episodes.append(episode)
    }

    // MARK: - Renaming

    /// Re-targets an existing record to a new name. Returns false when the new name is taken
    /// by a different record, because silently merging two taught records is the one thing
    /// spec 07 prohibits outright.
    @discardableResult
    public mutating func rename(placeId: UUID, to name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let index = places.firstIndex(where: { $0.id == placeId }) else { return false }
        if let clash = places.firstIndex(where: { $0.nameKey == key }), clash != index {
            return false
        }
        places[index].name = name
        return true
    }

    @discardableResult
    public mutating func rename(objectId: UUID, to name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let index = objects.firstIndex(where: { $0.id == objectId }) else { return false }
        if let clash = objects.firstIndex(where: { $0.nameKey == key }), clash != index {
            return false
        }
        objects[index].name = name
        return true
    }

    // MARK: - Lookup

    /// Case-insensitive exact match only. Fuzzy matching here would reintroduce guessing at
    /// exactly the layer the spec forbids it: an unknown name must become a question.
    public func place(named name: String) -> Place? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return places.first { $0.nameKey == key }
    }

    public func object(named name: String) -> MapObject? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return objects.first { $0.nameKey == key }
    }

    public func activity(named name: String) -> Activity? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return activities.first { $0.nameKey == key }
    }

    public func place(id: UUID) -> Place? { places.first { $0.id == id } }

    /// The place containing a point, smallest first — a desk inside a study resolves to the
    /// desk, which is what the user meant.
    public func containingPlace(of point: SIMD3<Float>) -> Place? {
        places.filter { $0.contains(point) }.min { $0.radius < $1.radius }
    }

    /// Every place whose radius covers the point. Teaching inside one of these is what
    /// triggers the disambiguation question in C4.
    public func placesContaining(_ point: SIMD3<Float>) -> [Place] {
        places.filter { $0.contains(point) }
    }

    public func rules(containing point: SIMD3<Float>, kind: Rule.Kind? = nil) -> [Rule] {
        rules.filter { $0.contains(point) && (kind == nil || $0.kind == kind) }
    }

    /// The hard `forbidden` regions the navmesh subtracts (B3).
    public var forbiddenRegions: [Rule] {
        rules.filter { $0.kind == .forbidden && $0.severity == .hard }
    }

    /// Marks a record used. Drives the inspector's use count and, later, curiosity ranking.
    public mutating func noteUse(placeId: UUID) {
        guard let index = places.firstIndex(where: { $0.id == placeId }) else { return }
        places[index].useCount += 1
    }

    public mutating func noteUse(objectId: UUID) {
        guard let index = objects.firstIndex(where: { $0.id == objectId }) else { return }
        objects[index].useCount += 1
    }

    // MARK: - Deletion

    /// Deletion is immediate and complete, including from episodes (spec 07 §Inspection).
    ///
    /// Episodes referencing the record go too rather than being orphaned: an episode that
    /// still reads "taught: kitchen" is the name surviving its own deletion.
    @discardableResult
    public mutating func delete(id: UUID) -> Bool {
        let before = totalRecordCount
        places.removeAll { $0.id == id }
        objects.removeAll { $0.id == id }
        rules.removeAll { $0.id == id }
        activities.removeAll { $0.id == id }
        episodes.removeAll { $0.references(id) || $0.id == id }
        // Anything that pointed at the deleted record loses the pointer, not itself.
        for index in objects.indices where objects[index].placeId == id {
            objects[index].placeId = nil
        }
        for index in activities.indices where activities[index].placeId == id {
            activities[index].placeId = nil
        }
        return totalRecordCount < before
    }

    /// "Forget everything": one action, no residue (spec 07 §Inspection).
    public mutating func wipe() {
        places = []
        objects = []
        rules = []
        activities = []
        episodes = []
    }

    public var totalRecordCount: Int {
        places.count + objects.count + rules.count + activities.count + episodes.count
    }

    public var isEmpty: Bool { totalRecordCount == 0 }

    // MARK: - Wire

    /// Places as the existing `SceneSnapshot` carries them. B4 replaces this with the fully
    /// abstracted, coordinate-free view.
    public func snapshot(userPosition: SIMD3<Float>?, floorArea: Double?) -> SceneSnapshot {
        SceneSnapshot(
            places: places.map(\.wire),
            floorArea: floorArea,
            userPosition: userPosition.map {
                Vec3(x: Double($0.x), y: Double($0.y), z: Double($0.z))
            }
        )
    }
}
