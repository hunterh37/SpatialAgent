import Foundation
import simd

/// A taught constraint over a region (spec 07 §Rules).
///
/// The kind set is closed because each kind is code, not prompt text. A rule expressed as a
/// prompt instruction is a rule that gets violated on a bad sample, and one violation of
/// "don't touch this" costs the user's trust permanently.
public struct Rule: MapRecord {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Subtracted from the navmesh. The bird cannot path into it or be placed in it.
        case forbidden
        /// Suppresses ambient speech and curiosity questions while the user is inside.
        case quiet
        /// A preferred resting spot; raises idle-settle weight nearby.
        case perch
        /// Allowed to path near, never to land on or gesture at. A softer `forbidden`.
        case fragile

        /// Hard kinds are geometric constraints; soft kinds are behavior weights.
        /// `forbidden` is the only one that can ever be hard, and it always is.
        public var isAlwaysHard: Bool { self == .forbidden }
    }

    public enum Severity: String, Codable, CaseIterable, Sendable {
        /// A geometric constraint. "I won't go there at all."
        case hard
        /// A behavior weight. "I'll keep out of the way."
        case soft
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public private(set) var severity: Severity
    public var anchor: AnchorRef
    public var radius: Float
    public var taughtAt: Date
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        severity: Severity = .hard,
        position: SIMD3<Float>,
        radius: Float = 0.5,
        anchorId: UUID? = nil,
        hasRelocalized: Bool = false,
        taughtAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        // A rule taught with "don't" is always hard (spec 07 §Rules). Rather than trusting
        // every call site to remember that, the type refuses to hold a soft `forbidden`.
        self.severity = kind.isAlwaysHard ? .hard : severity
        anchor = AnchorRef(anchorId: anchorId, position: position, hasRelocalized: hasRelocalized)
        self.radius = max(0.1, radius)
        self.taughtAt = taughtAt
        self.useCount = useCount
    }

    public var position: SIMD3<Float> {
        get { anchor.position }
        set { anchor.position = newValue }
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        simd_length(SIMD3(point.x - position.x, 0, point.z - position.z)) <= radius
    }

    /// What the user is told in plain language on capture.
    public var plainLanguage: String {
        switch (kind, severity) {
        case (.forbidden, _): return "I won't go there at all."
        case (.fragile, _): return "I'll keep out of the way."
        case (.quiet, _): return "I'll stay quiet there."
        case (.perch, _): return "I'll settle there."
        }
    }
}
