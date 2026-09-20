import Foundation
import simd

/// "the coffee machine" — a point, optionally bound to a home device and to a containing
/// place (spec 07 §Model).
public struct MapObject: MapRecord {
    public var id: UUID
    public var name: String
    public var anchor: AnchorRef
    /// HomeKit device identifier, when the user bound one. This binding is why "turn *that*
    /// off" can resolve on the client without a coordinate ever reaching the server.
    public var deviceId: String?
    public var placeId: UUID?
    public var taughtAt: Date
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        position: SIMD3<Float>,
        deviceId: String? = nil,
        placeId: UUID? = nil,
        anchorId: UUID? = nil,
        hasRelocalized: Bool = false,
        taughtAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        anchor = AnchorRef(anchorId: anchorId, position: position, hasRelocalized: hasRelocalized)
        self.deviceId = deviceId
        self.placeId = placeId
        self.taughtAt = taughtAt
        self.useCount = useCount
    }

    public var position: SIMD3<Float> {
        get { anchor.position }
        set { anchor.position = newValue }
    }

    public var isNavigable: Bool { anchor.isNavigable }
}
