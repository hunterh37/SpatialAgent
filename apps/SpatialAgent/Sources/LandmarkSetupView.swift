import AgentKit
import DesignSystem
import SceneUnderstanding
import SpatialMemory
import SwiftUI

/// The pre-demo checklist: look at a spot, tap, and it becomes a taught place.
///
/// Rendering only. Every decision — what the presets are, where a synthetic fallback lands,
/// which place holds the perch role — is in `LandmarkPreset` and `LandmarkPlacer`
/// (docs/architecture.md §1: `apps/` contains no logic).
struct LandmarkSetupView: View {
    @EnvironmentObject private var session: AgentSession
    @Environment(\.dismiss) private var dismiss

    @State private var busy: String?
    @State private var note: String?
    @State private var confirmingReset = false
    /// Bumped after every write. `MapStore` is a nested `ObservableObject`, and SwiftUI does
    /// not propagate those through `AgentSession`, so the checklist would otherwise show a
    /// stale placed/unplaced state until something else redrew it.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            List {
                ForEach(LandmarkPreset.demoRoom) { preset in
                    row(for: preset)
                }
            }
            .accessibilityIdentifier("landmarks.list")
            .id(revision)
            if let note {
                Text(note).font(.caption).foregroundStyle(Larry.mint)
            }
        }
        .padding(24)
        .confirmationDialog(
            "Reset the room?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset room", role: .destructive) {
                Task {
                    await session.landmarks?.resetRoom()
                    note = "Room reset."
                    revision += 1
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Every landmark, thing, rule and activity goes. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Place your landmarks").font(.title)
                Text("\(placedCount) of \(LandmarkPreset.demoRoom.count) placed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The spheres are the correction path: nothing else in the app says a
                // placed landmark can still be moved by hand.
                Text("Placed landmarks show as blue spheres — pinch one to drag it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset room", role: .destructive) { confirmingReset = true }
                .accessibilityIdentifier("landmarks.reset")
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Larry.bubblegum)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func row(for preset: LandmarkPreset) -> some View {
        let place = session.landmarks?.placed(preset)
        HStack(spacing: 14) {
            Image(systemName: place == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(place == nil ? Color.secondary : Larry.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label).font(.headline)
                Text(place == nil ? preset.prompt : subtitle(for: place!))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(place == nil ? "Place here" : "Re-place") {
                Task {
                    busy = preset.id
                    note = describe(await session.landmarks?.place(preset))
                    busy = nil
                    revision += 1
                }
            }
            .buttonStyle(.bordered)
            .tint(Larry.sky)
            .disabled(busy != nil || session.landmarks == nil)
            .accessibilityIdentifier("landmarks.place.\(preset.id)")
            if place != nil {
                Button(role: .destructive) {
                    _ = session.landmarks?.remove(preset)
                    note = "Forgot \(preset.name)."
                    revision += 1
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityIdentifier("landmarks.delete.\(preset.id)")
            }
        }
        .padding(.vertical, 4)
    }

    private var placedCount: Int {
        LandmarkPreset.demoRoom.filter { session.landmarks?.isPlaced($0) == true }.count
    }

    /// The perch role is called out on the row, because "exactly one" is only visible if the
    /// one is labelled.
    private func subtitle(for place: Place) -> String {
        let located = place.isNavigable ? "located" : "somewhere in this room"
        return place.kind == .perch ? "\(place.name) · home perch · \(located)"
            : "\(place.name) · \(located)"
    }

    private func describe(_ outcome: LandmarkPlacer.Outcome?) -> String? {
        switch outcome {
        case let .placed(name, anchored):
            return anchored ? "Anchored \(name)." : "Saved \(name)."
        case let .placedSynthetically(name):
            return "No surface to look at — \(name) placed in the fixture room."
        case let .failed(reason):
            return reason
        case nil:
            return "No room yet."
        }
    }
}
