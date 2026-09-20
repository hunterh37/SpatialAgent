import Foundation
import simd

/// The bird's colour, as three materials and a small set of presets.
///
/// Three materials is the spec 06 budget, and it is met by sharing rather than by dropping
/// parts: `plumage` carries body, head, wings, tail, brows *and* pupils; `sclera` carries the
/// eyes; `accent` carries beak, feet and crest. Brows in plumage is why they read as barely
/// visible at neutral, which the spec asks for. Pupils in plumage is why ``plumageLuminance``
/// is constrained — a pale plumage would put a pale pupil on a pale sclera and blind the face.
///
/// Variants are for attachment, not customization: presets only, no editor.
public struct BirdPalette: Equatable, Sendable {
    /// Linear RGB, 0–1. Deliberately not a platform colour type so the palette stays testable
    /// and the module stays buildable without RealityKit.
    public struct RGB: Equatable, Sendable {
        public var r: Float
        public var g: Float
        public var b: Float
        public init(_ r: Float, _ g: Float, _ b: Float) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// Rec. 709 luminance, used for the pupil-contrast constraint.
        public var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    public var name: String
    /// Body, head, wings, tail, brows, pupils.
    public var plumage: RGB
    /// Eyes.
    public var sclera: RGB
    /// Beak, feet, crest.
    public var accent: RGB
    /// Crest presence is per variant (spec 06 §Variants).
    public var hasCrest: Bool

    public init(name: String, plumage: RGB, sclera: RGB, accent: RGB, hasCrest: Bool) {
        self.name = name
        self.plumage = plumage
        self.sclera = sclera
        self.accent = accent
        self.hasCrest = hasCrest
    }

    /// Distinct materials this palette produces. The spec budget is ≤3.
    public static let materialCount = 3

    public var plumageLuminance: Float { plumage.luminance }

    /// The pupil is drawn in plumage on a sclera-coloured eye, so the two must separate.
    public var pupilContrast: Float { abs(sclera.luminance - plumage.luminance) }

    /// Every preset must clear this or the face loses its pupils.
    public static let minimumPupilContrast: Float = 0.25

    // MARK: Presets

    public static let teal = BirdPalette(
        name: "teal",
        plumage: RGB(0.10, 0.34, 0.38),
        sclera: RGB(0.96, 0.95, 0.90),
        accent: RGB(0.95, 0.63, 0.18),
        hasCrest: true
    )

    public static let plum = BirdPalette(
        name: "plum",
        plumage: RGB(0.30, 0.15, 0.36),
        sclera: RGB(0.97, 0.94, 0.94),
        accent: RGB(0.98, 0.76, 0.42),
        hasCrest: true
    )

    public static let moss = BirdPalette(
        name: "moss",
        plumage: RGB(0.20, 0.31, 0.15),
        sclera: RGB(0.95, 0.96, 0.91),
        accent: RGB(0.88, 0.55, 0.22),
        hasCrest: false
    )

    public static let slate = BirdPalette(
        name: "slate",
        plumage: RGB(0.18, 0.20, 0.26),
        sclera: RGB(0.93, 0.94, 0.96),
        accent: RGB(0.92, 0.70, 0.30),
        hasCrest: true
    )

    public static let ember = BirdPalette(
        name: "ember",
        plumage: RGB(0.42, 0.16, 0.12),
        sclera: RGB(0.98, 0.93, 0.88),
        accent: RGB(0.99, 0.80, 0.35),
        hasCrest: false
    )

    /// Three to five presets, no editor.
    public static let variants: [BirdPalette] = [.teal, .plum, .moss, .slate, .ember]

    /// Chosen at hatch and changeable.
    public static func variant(named name: String) -> BirdPalette? {
        variants.first { $0.name == name }
    }
}
