import Foundation

/// Append-only history (spec 07 §Model).
///
/// Episodes are the only record the user did not author, which is exactly why deletion has to
/// reach them: erasing a place while episodes still name it leaves the name recoverable, and
/// spec 07 says deletion is immediate and complete.
public struct Episode: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case taught
        case visited
        case acted
        case asked
        case declined
    }

    public var id: UUID
    public var timestamp: Date
    public var placeId: UUID?
    public var objectId: UUID?
    public var kind: Kind
    public var summary: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        placeId: UUID? = nil,
        objectId: UUID? = nil,
        kind: Kind,
        summary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.placeId = placeId
        self.objectId = objectId
        self.kind = kind
        self.summary = summary
    }

    /// True when this episode mentions the record in any way. Used by deletion.
    public func references(_ recordId: UUID) -> Bool {
        placeId == recordId || objectId == recordId
    }
}
