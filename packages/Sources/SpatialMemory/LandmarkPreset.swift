import Foundation
import simd

// The ordered set of landmarks a room is set up with before a demo. Teaching by speech is
// the product; this is the pre-flight for it. The demo needs the same room every time, and
// every preset here carries the `PlaceKind` a need resolves against, so the recall prompts
// in `DemoScenarios` and this list are one contract.

/// What gets drawn where a landmark is. The marker is built from primitives at runtime, so
/// this is a shape recipe rather than an asset name: a bowl is a cylinder and a rim, a perch
/// is a pole and a crossbar (spec 06 — no assets anywhere in the app).
public enum PropStyle: String, Codable, CaseIterable, Sendable {
    case perch
    case foodBowl
    case waterDish
    case cushion
    case toyBasket
    case desk
    case plant
    case marker
}

public struct LandmarkPreset: Identifiable, Hashable, Sendable {
    public var id: String
    /// Checklist row title.
    public var label: String
    /// The name written into the map. Lowercased matching makes this the recall key.
    public var name: String
    public var kind: PlaceKind
    /// Some landmarks are a place *and* a constraint: the plant is a place the bird can name
    /// and a region it must keep out of.
    public var rule: Rule.Kind?
    /// What the user is told to look at before tapping.
    public var prompt: String
    public var radius: Float
    /// The low-poly prop drawn at the landmark.
    public var prop: PropStyle
    /// Where the synthetic fallback puts it, as (right, forward) metres from the user.
    ///
    /// The simulator has no plane detection and no gaze raycast, so without this the whole
    /// flow is untappable exactly where it is most often demoed from.
    public var fallbackOffset: SIMD2<Float>

    public init(
        id: String,
        label: String,
        name: String,
        kind: PlaceKind = .generic,
        rule: Rule.Kind? = nil,
        prompt: String,
        radius: Float = 0.5,
        prop: PropStyle = .marker,
        fallbackOffset: SIMD2<Float>
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.kind = kind
        self.rule = rule
        self.prompt = prompt
        self.radius = max(0.1, radius)
        self.prop = prop
        self.fallbackOffset = fallbackOffset
    }

    /// True when this preset claims the one home perch.
    public var isHomePerch: Bool { kind == .perch }

    /// The need this landmark answers, if any. `nil` for scenery and for the plant.
    public var need: Need? { kind.need }

    /// The demo room, which is a bird's room rather than a furniture catalogue: everything
    /// in it either answers a need (perch, bowl, dish, cushion, basket) or constrains the
    /// route (the plant). Ordered so the checklist teaches the story in order — where it
    /// sleeps, then eats, drinks, gets petted, plays, and finally what to stay off.
    public static let demoRoom: [LandmarkPreset] = [
        LandmarkPreset(
            id: "perch",
            label: "Perch",
            name: "your perch",
            kind: .perch,
            prompt: "Look at the shelf or ledge the bird should live on.",
            radius: 0.35,
            prop: .perch,
            fallbackOffset: SIMD2(-1.0, -1.4)
        ),
        LandmarkPreset(
            id: "food-bowl",
            label: "Food bowl",
            name: "the food bowl",
            kind: .food,
            prompt: "Look at the spot where you feed him.",
            radius: 0.35,
            prop: .foodBowl,
            fallbackOffset: SIMD2(1.2, -1.5)
        ),
        LandmarkPreset(
            id: "water-dish",
            label: "Water dish",
            name: "the water dish",
            kind: .water,
            prompt: "Look at the spot where his water sits.",
            radius: 0.3,
            prop: .waterDish,
            fallbackOffset: SIMD2(1.7, -1.1)
        ),
        LandmarkPreset(
            id: "petting-spot",
            label: "Petting spot",
            name: "the petting spot",
            kind: .comfort,
            prompt: "Look at where you sit when you pet him.",
            radius: 0.6,
            prop: .cushion,
            fallbackOffset: SIMD2(-1.7, -0.7)
        ),
        LandmarkPreset(
            id: "toy-basket",
            label: "Toy basket",
            name: "the toy basket",
            kind: .toy,
            prompt: "Look at where his toys are kept.",
            radius: 0.4,
            prop: .toyBasket,
            fallbackOffset: SIMD2(-0.2, -2.2)
        ),
        LandmarkPreset(
            id: "workspace",
            label: "Your desk",
            name: "my desk",
            kind: .workspace,
            prompt: "Look at your desk.",
            radius: 0.8,
            prop: .desk,
            fallbackOffset: SIMD2(1.0, -0.4)
        ),
        LandmarkPreset(
            id: "plant",
            label: "Plant (keep away)",
            name: "the plant",
            kind: .generic,
            // Fragile, not forbidden: the bird may path past a plant, never land on it.
            rule: .fragile,
            prompt: "Look at the plant.",
            radius: 0.4,
            prop: .plant,
            fallbackOffset: SIMD2(0.3, -1.8)
        ),
    ]

    /// The preset that answers a need, which is how a scripted beat targets "wherever he
    /// eats" without naming the bowl.
    public static func preset(for need: Need) -> LandmarkPreset? {
        demoRoom.first { $0.kind == need.kind }
    }

    public static func preset(id: String) -> LandmarkPreset? {
        demoRoom.first { $0.id == id }
    }
}

public extension SemanticMap {
    /// The one place the bird calls home. `PlaceKind.perch` is behavior, so more than one of
    /// them is an ambiguous idle target rather than a richer map.
    var homePerch: Place? { places.first { $0.kind == .perch } }

    /// Makes one place the home perch and demotes any other. Returns false when the id is
    /// not a place, so a caller cannot believe it moved a perch it never found.
    @discardableResult
    mutating func setHomePerch(id: UUID) -> Bool {
        guard places.contains(where: { $0.id == id }) else { return false }
        for index in places.indices {
            if places[index].id == id {
                places[index].kind = .perch
            } else if places[index].kind == .perch {
                // Demoted rather than deleted: the user taught that name and only the
                // perch *role* moved.
                places[index].kind = .generic
            }
        }
        return true
    }
}

public extension MapStore {
    @discardableResult
    func setHomePerch(id: UUID) -> Bool {
        mutate { $0.setHomePerch(id: id) }
    }

    var homePerch: Place? { map.homePerch }
}
