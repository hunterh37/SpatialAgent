import Foundation
import simd

/// The ordered set of landmarks a room is set up with before a demo.
///
/// Teaching by speech is the product; this is the pre-flight for it. A preset exists because
/// the demo needs the *same* room every time — a perch, a workspace, a fragile plant — and
/// re-deriving those names from whatever was said on stage is how a demo loses its story.
/// The names here are the names the recall prompts in `DemoScenarios` ask about, so the two
/// lists are one contract.
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
        fallbackOffset: SIMD2<Float>
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.kind = kind
        self.rule = rule
        self.prompt = prompt
        self.radius = max(0.1, radius)
        self.fallbackOffset = fallbackOffset
    }

    /// True when this preset claims the one home perch.
    public var isHomePerch: Bool { kind == .perch }

    /// The seven-landmark room. Ordered: the perch first, because everything the bird does
    /// when nobody is talking to it resolves against that one record.
    public static let demoRoom: [LandmarkPreset] = [
        LandmarkPreset(
            id: "perch",
            label: "Home perch",
            name: "your perch",
            kind: .perch,
            prompt: "Look at the shelf or ledge the bird should live on.",
            radius: 0.35,
            fallbackOffset: SIMD2(-1.0, -1.4)
        ),
        LandmarkPreset(
            id: "workspace",
            label: "Workspace",
            name: "my desk",
            kind: .workspace,
            prompt: "Look at your desk.",
            radius: 0.8,
            fallbackOffset: SIMD2(1.2, -0.6)
        ),
        LandmarkPreset(
            id: "couch",
            label: "Couch",
            name: "the couch",
            kind: .surface,
            prompt: "Look at the couch.",
            radius: 0.9,
            fallbackOffset: SIMD2(-1.6, -1.2)
        ),
        LandmarkPreset(
            id: "front-door",
            label: "Front door",
            name: "the front door",
            kind: .floor,
            prompt: "Look at the floor in front of the door.",
            radius: 1.0,
            fallbackOffset: SIMD2(0, 1.8)
        ),
        LandmarkPreset(
            id: "kitchen",
            label: "Kitchen",
            name: "the kitchen",
            kind: .floor,
            prompt: "Look at the middle of the kitchen floor.",
            radius: 1.2,
            fallbackOffset: SIMD2(1.8, 1.0)
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
            fallbackOffset: SIMD2(-0.4, -1.9)
        ),
        LandmarkPreset(
            id: "snack-shelf",
            label: "Snack shelf",
            name: "the snack shelf",
            kind: .surface,
            prompt: "Look at the snack shelf.",
            radius: 0.5,
            fallbackOffset: SIMD2(2.0, -1.2)
        ),
    ]

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
