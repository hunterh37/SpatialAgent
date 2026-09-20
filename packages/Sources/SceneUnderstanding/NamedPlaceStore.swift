import AgentProtocol
import Foundation
import simd

/// A named place is an anchor plus a radius (spec/05-scene.md).
///
/// `walkTo("kitchen")` resolves through this table. An unknown name is a clarifying
/// question, never a guess — `resolve` returning nil is how that is enforced on the client
/// regardless of what the model emits.
public struct PlaceRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name.lowercased() }
    public var name: String
    public var position: SIMD3<Float>
    public var radius: Float
    /// `WorldTrackingProvider` anchor UUID, so the place survives a session.
    public var anchorId: UUID?

    public init(name: String, position: SIMD3<Float>, radius: Float = 0.5, anchorId: UUID? = nil) {
        self.name = name
        self.position = position
        self.radius = max(0.1, radius)
        self.anchorId = anchorId
    }

    public var wire: NamedPlace {
        NamedPlace(
            name: name,
            position: Vec3(x: Double(position.x), y: Double(position.y), z: Double(position.z)),
            radius: Double(radius)
        )
    }
}

@MainActor
public final class NamedPlaceStore: ObservableObject {
    @Published public private(set) var places: [PlaceRecord] = []

    private let defaultsKey = "io.medvr.SpatialAgent.places"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func add(_ record: PlaceRecord) {
        places.removeAll { $0.id == record.id }
        places.append(record)
        persist()
    }

    public func remove(named name: String) {
        places.removeAll { $0.id == name.lowercased() }
        persist()
    }

    /// Case-insensitive exact match only. Fuzzy matching here would reintroduce guessing
    /// at exactly the layer the spec forbids it.
    public func resolve(_ name: String) -> PlaceRecord? {
        places.first { $0.id == name.lowercased() }
    }

    public func snapshot(userPosition: SIMD3<Float>?, floorArea: Double?) -> SceneSnapshot {
        SceneSnapshot(
            places: places.map(\.wire),
            floorArea: floorArea,
            userPosition: userPosition.map {
                Vec3(x: Double($0.x), y: Double($0.y), z: Double($0.z))
            }
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([PlaceRecord].self, from: data)
        else { return }
        places = decoded
    }
}
