import AgentProtocol
import Foundation
import simd

/// Identity for every user-authored record: a stable UUID plus a lowercased name key
/// (spec 07 §Model).
///
/// The name key is what makes a collision a correction rather than a second record. It is
/// computed, never stored, so a rename cannot leave a stale key behind.
public protocol MapRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID { get }
    var name: String { get set }
    /// When the user taught it. Shown in the inspector.
    var taughtAt: Date { get }
    /// How often it has been used to resolve something. Also shown in the inspector.
    var useCount: Int { get set }
}

public extension MapRecord {
    /// Lowercased, whitespace-trimmed name. Two records with the same key are the same record.
    var nameKey: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Where a spatial record actually is.
///
/// The anchor is authoritative and the cached transform is what makes the map usable before
/// relocalization completes (spec 07 §Model). Both are held because either alone is wrong:
/// an anchor with no cache is unusable at launch, and a cache with no anchor drifts.
public struct AnchorRef: Codable, Hashable, Sendable {
    /// `WorldTrackingProvider` anchor UUID.
    public var anchorId: UUID?
    /// Last known position in the room's coordinate space.
    public var position: SIMD3<Float>
    /// Set once the anchor has relocalized in this session. A record that never relocalizes
    /// is "somewhere in this room" and is not navigable.
    public var hasRelocalized: Bool

    public init(anchorId: UUID? = nil, position: SIMD3<Float>, hasRelocalized: Bool = false) {
        self.anchorId = anchorId
        self.position = position
        self.hasRelocalized = hasRelocalized
    }

    /// A record with no anchor at all was authored without world tracking — a fixture, a
    /// test, or a migrated legacy place — and is trusted, because there is nothing to drift.
    public var isNavigable: Bool { anchorId == nil || hasRelocalized }
}

/// What kind of place this is. Kinds are a closed set because each one is behavior, not
/// prose: `perch` raises idle-settle weight, `workspace` attracts activities.
public enum PlaceKind: String, Codable, CaseIterable, Sendable {
    case generic
    case workspace
    case surface
    case floor
    case perch
    /// Where the bird is fed. The need `.hungry` resolves against this kind, never a name.
    case food
    /// Where it drinks.
    case water
    /// Where the user pets it: the one place a `.lonely` need can be satisfied.
    case comfort
    /// Where its toys live.
    case toy

    /// The kinds that answer a need rather than a name. Exactly one place each, which is
    /// what makes "go eat" resolvable with no landmark named in the utterance.
    public var need: Need? {
        switch self {
        case .food: return .hungry
        case .water: return .thirsty
        case .comfort: return .lonely
        case .toy: return .bored
        case .perch: return .sleepy
        default: return nil
        }
    }
}

/// What the bird is trying to satisfy. A need is the demo's whole point: the utterance says
/// "I'm hungry" and the destination comes out of the map, so deleting the bowl changes the
/// answer instead of changing the script.
public enum Need: String, Codable, CaseIterable, Sendable {
    case hungry
    case thirsty
    case lonely
    case bored
    case sleepy

    public var kind: PlaceKind {
        switch self {
        case .hungry: return .food
        case .thirsty: return .water
        case .lonely: return .comfort
        case .bored: return .toy
        case .sleepy: return .perch
        }
    }

    /// Said out loud before the flight, so the audience hears the lookup.
    public var verb: String {
        switch self {
        case .hungry: return "eat"
        case .thirsty: return "drink"
        case .lonely: return "get pets"
        case .bored: return "find a toy"
        case .sleepy: return "settle"
        }
    }
}

/// "my workspace" — a named region (spec 07 §Model).
public struct Place: MapRecord {
    public var id: UUID
    public var name: String
    public var kind: PlaceKind
    public var anchor: AnchorRef
    /// Metres. Derived from surface extent at capture, never a constant (spec 07 §Capture).
    public var radius: Float
    public var taughtAt: Date
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        position: SIMD3<Float>,
        radius: Float = 0.5,
        kind: PlaceKind = .generic,
        anchorId: UUID? = nil,
        hasRelocalized: Bool = false,
        taughtAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.radius = max(0.1, radius)
        anchor = AnchorRef(
            anchorId: anchorId,
            position: position,
            hasRelocalized: hasRelocalized
        )
        self.taughtAt = taughtAt
        self.useCount = useCount
    }

    public var position: SIMD3<Float> {
        get { anchor.position }
        set { anchor.position = newValue }
    }

    /// Not navigable means the bird will say "somewhere in this room" rather than walk to a
    /// stale coordinate.
    public var isNavigable: Bool { anchor.isNavigable }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        simd_length(SIMD3(point.x - position.x, 0, point.z - position.z)) <= radius
    }

    /// The abstracted form sent to the server: a name, a kind, and whether the bird can
    /// currently get there. No coordinates (spec 07 §Enforcement).
    public var wire: MapPlace {
        MapPlace(name: name, kind: kind.rawValue, navigable: isNavigable)
    }

}
