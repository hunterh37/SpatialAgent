import Foundation

/// "where I brainstorm" — a named activity bound to a place, with the time-of-day bands it
/// has actually been observed in (spec 07 §Model).
public struct Activity: MapRecord {
    /// An observed span of the day, in minutes from midnight. Bands are observed, never
    /// authored: the user says where they brainstorm, not when.
    public struct Band: Codable, Hashable, Sendable {
        public var startMinute: Int
        public var endMinute: Int
        public var observations: Int

        public init(startMinute: Int, endMinute: Int, observations: Int = 1) {
            self.startMinute = max(0, min(1439, startMinute))
            self.endMinute = max(0, min(1439, endMinute))
            self.observations = observations
        }

        public func contains(minute: Int) -> Bool {
            // Bands may wrap midnight; an evening activity is not two activities.
            if startMinute <= endMinute {
                return minute >= startMinute && minute <= endMinute
            }
            return minute >= startMinute || minute <= endMinute
        }
    }

    public var id: UUID
    public var name: String
    public var placeId: UUID?
    public var bands: [Band]
    public var taughtAt: Date
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        placeId: UUID? = nil,
        bands: [Band] = [],
        taughtAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.placeId = placeId
        self.bands = bands
        self.taughtAt = taughtAt
        self.useCount = useCount
    }

    public func isActive(atMinute minute: Int) -> Bool {
        bands.contains { $0.contains(minute: minute) }
    }
}
