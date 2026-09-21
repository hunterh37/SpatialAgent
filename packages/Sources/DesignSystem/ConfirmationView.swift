import SwiftUI

/// The confirmation ornament (spec/02-interaction.md).
///
/// Plain language, the target device named, Confirm and Cancel. Cancel is the default and
/// takes the prominent position for the keyboard/focus path; Confirm requires a deliberate
/// move. There is no "don't ask again".
public struct ConfirmationView: View {
    private let summary: String
    private let deviceName: String
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    public init(
        summary: String,
        deviceName: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.summary = summary
        self.deviceName = deviceName
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(summary, systemImage: "exclamationmark.shield")
                .font(.system(size: 19, weight: .medium, design: .rounded))
            Text(deviceName)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("confirmation.cancel")
                Button("Confirm", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("confirmation.confirm")
            }
        }
        .padding(22)
        .frame(maxWidth: 380, alignment: .leading)
        .agentGlassBackground(cornerRadius: 26)
    }
}

#Preview {
    ConfirmationView(
        summary: "Unlock the Front Door",
        deviceName: "Front Door · Entry",
        onConfirm: {},
        onCancel: {}
    )
    .padding(60)
}
