import HomeBridge
import SwiftUI

/// What the companion is doing, in plain language.
///
/// The user has just been asked to let a piece of software unlock their front door. The
/// least this app can do is show every call it makes, in order, with the failures included.
struct CompanionView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            devices
            Divider()
            activity
        }
        .padding(20)
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SpatialAgent Home").font(.title2)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("companion.status")
            Text(model.homeKind).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        switch model.state {
        case .stopped:
            return "Not listening. The bird cannot reach the home."
        case let .listening(port):
            return "Listening on 127.0.0.1:\(port) — this machine only."
        case let .failed(reason):
            return "Couldn't start: \(reason)"
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
            }
            if model.devices.isEmpty {
                Text("No devices yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.devices, id: \.self) { Text($0).font(.callout) }
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What it has done").font(.headline)
            if model.log.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.log.reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(entry.ok ? .green : .red)
                                Text("\(entry.tool) \(entry.deviceId ?? "")")
                                Spacer()
                                Text(entry.detail).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}
