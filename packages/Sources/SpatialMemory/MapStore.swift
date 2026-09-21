import AgentProtocol
import Foundation
import simd

/// Persistence and observation for the semantic map.
///
/// Split from `SemanticMap` because the map is a value with semantics and this is an object
/// with a storage story. It also replaces `NamedPlaceStore`: places are now one layer of the
/// map rather than a table of their own, and the old store's data is migrated on first load
/// rather than dropped — a user who taught four place names does not get to lose them to a
/// refactor.
@MainActor
public final class MapStore: ObservableObject {
    @Published public private(set) var map: SemanticMap

    private let defaults: UserDefaults
    private let roomId: String

    /// Keyed by room, so a second room is a second key rather than a migration.
    private var storageKey: String { "io.medvr.SpatialAgent.map.\(roomId)" }
    /// The key `NamedPlaceStore` used.
    private static let legacyPlacesKey = "io.medvr.SpatialAgent.places"

    public init(defaults: UserDefaults = .standard, roomId: String = "default") {
        self.defaults = defaults
        self.roomId = roomId
        map = SemanticMap(roomId: roomId)
        load()
    }

    // MARK: - Writes

    /// Every mutation goes through here so that nothing can change the map without it being
    /// written to disk.
    @discardableResult
    public func mutate<T>(_ body: (inout SemanticMap) -> T) -> T {
        let result = body(&map)
        persist()
        return result
    }

    @discardableResult
    public func add(_ place: Place) -> SemanticMap.Outcome {
        mutate { $0.upsert(place) }
    }

    @discardableResult
    public func add(_ object: MapObject) -> SemanticMap.Outcome {
        mutate { $0.upsert(object) }
    }

    @discardableResult
    public func add(_ rule: Rule) -> SemanticMap.Outcome {
        mutate { $0.upsert(rule) }
    }

    @discardableResult
    public func add(_ activity: Activity) -> SemanticMap.Outcome {
        mutate { $0.upsert(activity) }
    }

    public func record(_ episode: Episode) {
        mutate { $0.record(episode) }
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        mutate { $0.delete(id: id) }
    }

    /// "Forget everything." The stored blob goes too — a wipe that leaves the old JSON on
    /// disk is a wipe that a decoder bug can undo.
    public func forgetEverything() {
        map.wipe()
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: Self.legacyPlacesKey)
        persist()
    }

    // MARK: - Reads

    public func resolve(_ name: String) -> Place? { map.place(named: name) }

    public func snapshot(userPosition: SIMD3<Float>?, floorArea: Double?) -> SceneSnapshot {
        map.snapshot(userPosition: userPosition, floorArea: floorArea)
    }

    public var places: [Place] { map.places }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(SemanticMap.self, from: data) {
            map = decoded
            demoteUncolouredPerches()
            return
        }
        migrateLegacyPlaces()
    }

    /// One-way cleanup for rooms already on disk: a perch whose name is not one of the three
    /// coloured presets stops being a perch.
    ///
    /// `set_home_perch` used to mint its own record called "your perch", and that record then
    /// won the learned choice and got read out — "your perch. Still the good one." Three
    /// named perches is the product's contract; a fourth unnamed one makes the line
    /// unreadable. The record and its anchor are kept, because the user did teach a spot;
    /// only the role goes.
    private func demoteUncolouredPerches() {
        var demoted = false
        for index in map.places.indices
            where map.places[index].kind == .perch
            && !LandmarkPreset.isPerchName(map.places[index].name) {
            map.places[index].kind = .generic
            demoted = true
        }
        if demoted { persist() }
    }

    /// One-way migration out of `NamedPlaceStore`'s array of places.
    private func migrateLegacyPlaces() {
        guard let data = defaults.data(forKey: Self.legacyPlacesKey),
              let legacy = try? JSONDecoder().decode([LegacyPlace].self, from: data),
              !legacy.isEmpty
        else { return }
        for old in legacy {
            map.upsert(
                Place(
                    name: old.name,
                    position: old.position,
                    radius: old.radius,
                    anchorId: old.anchorId
                )
            )
        }
        persist()
        defaults.removeObject(forKey: Self.legacyPlacesKey)
    }

    /// The shape `PlaceRecord` was stored in.
    private struct LegacyPlace: Codable {
        var name: String
        var position: SIMD3<Float>
        var radius: Float
        var anchorId: UUID?
    }
}
