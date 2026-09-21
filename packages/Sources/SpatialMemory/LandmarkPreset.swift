import Foundation
import simd

// The ordered set of landmarks a room is set up with before a demo. Teaching by speech is
// the product; this is the pre-flight for it. The demo needs the same room every time, and
// every preset here carries the `PlaceKind` a need resolves against, so the recall prompts
// in `DemoScenarios` and this list are one contract.

/// What gets drawn where a landmark is. The marker is built from primitives at runtime, so
/// this is a shape recipe rather than an asset name: a bowl is a cylinder and a rim, a perch
/// is a pole and a crossbar (spec 06 — no assets anywhere in the app).
/// A prop's paint, as plain components so this stays free of UIKit and testable off-device.
///
/// Perches carry one because the room has three of them and they are behaviourally
/// interchangeable: the bird's choice between them is learned, not configured. Three
/// identical brown poles make that learning invisible — "he's on the pole" is not an
/// observation anyone can check. Three coloured ones turn it into "he's on the red one
/// again", which is the demo's whole claim about habit memory, visible from across a room.
public struct PropTint: Hashable, Sendable, Codable {
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(_ red: Float, _ green: Float, _ blue: Float) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// A darker version, for the parts that read as shadow: the base, the end caps.
    public func shaded(_ factor: Float = 0.68) -> PropTint {
        PropTint(red * factor, green * factor, blue * factor)
    }

    /// Saturated and far apart in hue, so they are still telling apart under passthrough
    /// tinting and at three metres. Ordered the way the perches are listed.
    public static let perchPalette: [PropTint] = [
        PropTint(0.85, 0.27, 0.28),   // red
        PropTint(0.25, 0.55, 0.88),   // blue
        PropTint(0.95, 0.72, 0.22),   // amber
        PropTint(0.35, 0.72, 0.45),   // green
        PropTint(0.68, 0.42, 0.85),   // violet
    ]

    /// Natural wood, for every prop that is not a perch.
    public static let wood = PropTint(0.62, 0.44, 0.27)

    /// A stable colour for a landmark that was taught rather than preset, so a perch the
    /// user named by speaking gets a colour too — and the same colour every launch, because
    /// a perch that changes colour between sessions cannot be referred to by its colour.
    public static func stable(for id: String) -> PropTint {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return perchPalette[Int(hash % UInt64(perchPalette.count))]
    }
}

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
    /// Metres above the floor that the bird stands at here. Non-zero makes the landmark a
    /// flight target rather than a walk target.
    public var height: Float
    /// Where the synthetic fallback puts it, as (right, forward) metres from the user.
    ///
    /// The simulator has no plane detection and no gaze raycast, so without this the whole
    /// flow is untappable exactly where it is most often demoed from.
    public var fallbackOffset: SIMD2<Float>
    /// The prop's paint. Perches are coloured so the three of them can be told apart by
    /// eye; everything else keeps its own material palette and ignores this.
    public var tint: PropTint

    public init(
        id: String,
        label: String,
        name: String,
        kind: PlaceKind = .generic,
        rule: Rule.Kind? = nil,
        prompt: String,
        radius: Float = 0.5,
        prop: PropStyle = .marker,
        height: Float = 0,
        fallbackOffset: SIMD2<Float>,
        tint: PropTint? = nil
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.kind = kind
        self.rule = rule
        self.prompt = prompt
        self.radius = max(0.1, radius)
        self.prop = prop
        self.height = max(0, height)
        self.fallbackOffset = fallbackOffset
        // A perch with no colour named for it still gets one, derived from its id: an
        // uncoloured perch among coloured ones reads as a bug, not as a default.
        self.tint = tint ?? (kind == .perch ? .stable(for: id) : .wood)
    }

    /// Matched the way `MapRecord.nameKey` is, so a preset and the record it wrote compare
    /// equal without either side knowing about the other's type.
    public var nameKey: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when this preset is one of the room's perches. There are three, they differ only
    /// in colour, and which one the bird uses is learned rather than configured — the colour
    /// exists so that learning can be watched, not to rank them.
    public var isPerch: Bool { kind == .perch }

    /// Kept for the teaching path, where `set_home_perch` still promotes exactly one record.
    @available(*, deprecated, renamed: "isPerch")
    public var isHomePerch: Bool { isPerch }

    /// The need this landmark answers, if any. `nil` for scenery and for the plant.
    public var need: Need? { kind.need }

    /// The demo room, which is a bird's room rather than a furniture catalogue: everything
    /// in it either answers a need (perch, bowl, dish, cushion, basket) or constrains the
    /// route (the plant). Ordered so the checklist teaches the story in order — where it
    /// sleeps, then eats, drinks, gets petted, plays, and finally what to stay off.
    /// Where the crossbar sits. Head height for a seated user and inside arm's reach, which
    /// is the whole requirement: the perch has to be somewhere a hand can actually swat.
    public static let perchHeight: Float = 1.0

    public static let demoRoom: [LandmarkPreset] = [
        LandmarkPreset(
            id: "perch-left",
            label: "Red perch",
            name: "the red perch",
            kind: .perch,
            prompt: "Look at where the red perch should stand.",
            radius: 0.3,
            prop: .perch,
            height: Self.perchHeight,
            fallbackOffset: SIMD2(-1.3, -1.6),
            // Named for the colour rather than the wall it is against, because the colour is
            // the part that survives the furniture being moved — and the part the user can
            // say out loud when the bird picks a favourite.
            tint: PropTint.perchPalette[0]
        ),
        LandmarkPreset(
            id: "perch-middle",
            label: "Blue perch",
            name: "the blue perch",
            kind: .perch,
            prompt: "Look at where the blue perch should stand.",
            radius: 0.3,
            prop: .perch,
            height: Self.perchHeight,
            fallbackOffset: SIMD2(-0.5, -1.9),
            tint: PropTint.perchPalette[1]
        ),
        LandmarkPreset(
            id: "perch-right",
            label: "Amber perch",
            name: "the amber perch",
            kind: .perch,
            prompt: "Look at where the amber perch should stand.",
            radius: 0.3,
            prop: .perch,
            height: Self.perchHeight,
            fallbackOffset: SIMD2(0.4, -2.0),
            tint: PropTint.perchPalette[2]
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

    /// The three perches, in the order the checklist places them.
    public static let perches: [LandmarkPreset] = demoRoom.filter(\.isPerch)

    /// The only names a perch record may carry. Three coloured perches is the product's
    /// contract, not a default: the learned-choice line reads the name out loud, and a
    /// fourth record called something like "your perch" turns "the red perch. Still the
    /// good one." into a sentence nobody can check against the room.
    public static let perchNameKeys: Set<String> = Set(perches.map(\.nameKey))

    /// True when `name` is one of the three coloured perches, matched the way records are.
    public static func isPerchName(_ name: String) -> Bool {
        perchNameKeys.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func preset(id: String) -> LandmarkPreset? {
        demoRoom.first { $0.id == id }
    }
}

public extension SemanticMap {
    /// The perch the bird currently calls home.
    ///
    /// This used to be "the one place with `PlaceKind.perch`", because there was one. There
    /// are now three, and picking between them is `PerchMemory`: fewest knock-offs wins. So
    /// idle return, the sleepy need and the teaching path all still ask one question and get
    /// one answer — the answer just changes when the user swats him off a perch.
    var homePerch: Place? { PerchMemory.best(in: self) }

    /// Every place the bird may stand on as a perch.
    ///
    /// The name filter is the guard: `PlaceKind.perch` alone once let any record call itself
    /// a perch, and one stray record was enough to win the learned choice and be narrated by
    /// a name the room has no colour for. The three coloured presets are the closed set.
    var perches: [Place] {
        places.filter { $0.kind == .perch && LandmarkPreset.isPerchName($0.name) }
    }

    /// Makes one place the home perch and demotes any other. Returns false when the id is
    /// not a place, so a caller cannot believe it moved a perch it never found.
    @discardableResult
    mutating func setHomePerch(id: UUID) -> Bool {
        guard places.contains(where: { $0.id == id }) else { return false }
        for index in places.indices {
            if places[index].id == id {
                places[index].kind = .perch
            } else if places[index].kind == .perch, !LandmarkPreset.isPerchName(places[index].name) {
                // Only a perch the room has no colour for is demoted: the three coloured
                // presets are equals and coexist, and it is that stray fourth record the
                // choice must never see. Demoted rather than deleted — the user taught the
                // name, and only the perch *role* moved.
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
