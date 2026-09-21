import AgentKit
import DesignSystem
import SpatialMemory
import SwiftUI
import simd

/// Everything the bird knows about this room, and the one button that erases it.
///
/// Spec 07 §Inspection: every record listed with name, kind, taught-at and use count, a
/// spatial highlight on selection, a per-row delete, and a single "forget everything" that
/// re-hatches in place. This view is the audit surface for the whole product — the map is
/// what the user spent effort building, and it is also what a door lock ends up behind.
struct MapInspectorView: View {
    @EnvironmentObject private var session: AgentSession
    @State private var selection: UUID?
    @State private var confirmingWipe = false
    @Environment(\.dismiss) private var dismiss

    /// Set on selection; the immersive view highlights this record in the room.
    @Binding var highlighted: SIMD3<Float>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if session.places.map.isEmpty {
                empty
            } else {
                list
            }
        }
        .padding(24)
        .confirmationDialog(
            "Forget everything about this room?",
            isPresented: $confirmingWipe,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) {
                session.places.forgetEverything()
                highlighted = nil
                selection = nil
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Every place, thing, rule and activity you taught goes. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("What I know").font(.title)
            Spacer()
            Button("Forget everything", role: .destructive) { confirmingWipe = true }
                .accessibilityIdentifier("map.forgetEverything")
                .disabled(session.places.map.isEmpty)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("map.close")
        }
    }

    private var empty: some View {
        Text("Nothing yet. Look at something and tell me what it is.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("map.empty")
            .padding(.top, 24)
    }

    private var list: some View {
        List {
            section("Places", rows: session.places.map.places.map(row(for:)))
            section("Things", rows: session.places.map.objects.map(row(for:)))
            section("Rules", rows: session.places.map.rules.map(row(for:)))
            section("Activities", rows: session.places.map.activities.map(row(for:)))
        }
        .accessibilityIdentifier("map.list")
    }

    @ViewBuilder
    private func section(_ title: String, rows: [MapRow]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in row }
            }
        }
    }

    // MARK: Rows

    private func row(for place: Place) -> MapRow {
        MapRow(
            name: place.name,
            kind: place.kind.rawValue,
            taughtAt: place.taughtAt,
            useCount: place.useCount,
            isLocated: place.isNavigable,
            isSelected: selection == place.id,
            onSelect: { select(place.id, at: place.isNavigable ? place.position : nil) },
            onDelete: { delete(place.id) }
        )
    }

    private func row(for object: MapObject) -> MapRow {
        MapRow(
            name: object.name,
            kind: object.deviceId == nil ? "thing" : "thing · linked to a device",
            taughtAt: object.taughtAt,
            useCount: object.useCount,
            isLocated: object.isNavigable,
            isSelected: selection == object.id,
            onSelect: { select(object.id, at: object.isNavigable ? object.position : nil) },
            onDelete: { delete(object.id) }
        )
    }

    private func row(for rule: Rule) -> MapRow {
        MapRow(
            name: rule.name,
            kind: rule.plainLanguage,
            taughtAt: rule.taughtAt,
            useCount: rule.useCount,
            isSelected: selection == rule.id,
            onSelect: { select(rule.id, at: rule.position) },
            onDelete: { delete(rule.id) }
        )
    }

    private func row(for activity: Activity) -> MapRow {
        MapRow(
            name: activity.name,
            kind: "activity",
            taughtAt: activity.taughtAt,
            useCount: activity.useCount,
            isSelected: selection == activity.id,
            onSelect: {
                let place = activity.placeId.flatMap { session.places.map.place(id: $0) }
                select(activity.id, at: place?.position)
            },
            onDelete: { delete(activity.id) }
        )
    }

    // MARK: Actions

    private func select(_ id: UUID, at position: SIMD3<Float>?) {
        selection = id
        highlighted = position
    }

    /// Deletion is immediate and complete. There is no undo and no tombstone, because a
    /// record the user erased that comes back is worse than one that was never deletable.
    private func delete(_ id: UUID) {
        session.places.delete(id: id)
        if selection == id {
            selection = nil
            highlighted = nil
        }
    }
}
