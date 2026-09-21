import SwiftUI

/// One taught record in the map inspector.
///
/// Spec 07 §Inspection: name, kind, when it was taught, how often it has been used, and a
/// per-row delete. A map that cannot be audited or erased is not something to put a door
/// lock behind, so every field here exists to make one record answerable and removable.
public struct MapRow: View {
    public let name: String
    public let kind: String
    public let taughtAt: Date
    public let useCount: Int
    /// False when the anchor has never relocalized: shown as "somewhere in this room".
    public let isLocated: Bool
    public let isSelected: Bool
    public let onSelect: () -> Void
    public let onDelete: () -> Void

    public init(
        name: String,
        kind: String,
        taughtAt: Date,
        useCount: Int,
        isLocated: Bool = true,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {}
    ) {
        self.name = name
        self.kind = kind
        self.taughtAt = taughtAt
        self.useCount = useCount
        self.isLocated = isLocated
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .accessibilityIdentifier("map.row.name")
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("map.row.delete")
            .accessibilityLabel("Forget \(name)")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .accessibilityIdentifier("map.row")
    }

    private var subtitle: String {
        var parts = [kind]
        if !isLocated { parts.append("somewhere in this room") }
        parts.append("taught \(Self.relative.localizedString(for: taughtAt, relativeTo: Date()))")
        if useCount > 0 { parts.append("used \(useCount)×") }
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
