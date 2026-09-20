import AgentKit
import AgentTransport
import DesignSystem
import HomeBridge
import SwiftUI
import VoiceInput

/// The 2D control surface: connection, the transcript, and the text field that stands in for
/// speech until v0.2. The character itself lives in the immersive space.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var session: AgentSession
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    @StateObject private var voice = SpeechCapture()
    @State private var draft = ""
    @State private var manualHost = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 12)
            transcript
            composer
        }
        .padding(24)
        .task { await model.start() }
        .task {
            // Dictation drives the same path as the text field: partials keep the server
            // current, the final transcript is the utterance.
            voice.onPartial = { text in
                draft = text
                session.send(partial: text)
            }
            voice.onFinal = { text in
                draft = text
                send()
            }
        }
        .onChange(of: voice.isListening) { _, listening in
            if listening { session.addressed() }
        }
        .onChange(of: fieldFocused) { _, focused in
            // Focus is the v0.1 stand-in for gaze acquisition: the character shows it is
            // being addressed before the utterance ends (spec/02-interaction.md).
            if focused { session.addressed() }
        }
        .overlay(alignment: .bottom) { confirmationOrnament }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SpatialAgent").font(.title)
                Text(connectionLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("In the room", isOn: spaceBinding).toggleStyle(.button)
        }
        .overlay(alignment: .bottomLeading) {
            if let problem = model.placementProblem ?? voiceProblem {
                Text(problem).font(.caption).foregroundStyle(.orange).offset(y: 22)
            }
        }
        .padding(.bottom, 8)
        .safeAreaInset(edge: .bottom) { discoveryRow }
    }

    private var discoveryRow: some View {
        HStack(spacing: 8) {
            ForEach(model.discovery.endpoints) { endpoint in
                Button(endpoint.name) { session.connect(to: endpoint) }
                    .buttonStyle(.bordered)
            }
            // Manual entry is kept reachable on purpose: mDNS is blocked on conference
            // Wi-Fi and a demo will eventually need this (docs/architecture.md §2b).
            TextField("Mac IP", text: $manualHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit {
                    guard !manualHost.isEmpty else { return }
                    session.connect(to: model.discovery.addManual(host: manualHost))
                }
        }
        .font(.footnote)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.transcript) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.role == .user ? "person" : "sparkle")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(entry.text)
                        }
                        .id(entry.id)
                    }
                    if session.isStreaming {
                        SpeechBubble(text: session.currentReply, isStreaming: true)
                            .id("streaming")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo(session.transcript.last?.id) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            micButton
            TextField("Ask it to do something", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 14)
    }

    /// Push-to-talk. Held state is explicit rather than voice-activated: an always-open mic
    /// in a room with other people is a different product.
    private var micButton: some View {
        Button {
            Task { await voice.toggle() }
        } label: {
            Image(systemName: voice.isListening ? "mic.fill" : "mic")
                .symbolEffect(.variableColor, isActive: voice.isListening)
        }
        .buttonStyle(.bordered)
        .tint(voice.isListening ? .red : nil)
        .help(voiceProblem ?? "Dictate")
    }

    private var voiceProblem: String? {
        switch voice.status {
        case let .denied(reason), let .failed(reason): return reason
        default: return nil
        }
    }

    @ViewBuilder
    private var confirmationOrnament: some View {
        if let pending = session.confirmations.pending.first {
            ConfirmationView(
                summary: pending.summary,
                deviceName: pending.deviceName,
                onConfirm: { session.confirmations.confirm(pending.id) },
                onCancel: { session.confirmations.cancel(pending.id) }
            )
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var spaceBinding: Binding<Bool> {
        Binding(
            get: { model.spacePhase == .open },
            set: { wantsOpen in
                Task {
                    if wantsOpen {
                        model.spacePhase = .opening
                        if case .opened = await openSpace(id: AppModel.immersiveSpaceId) {
                            model.spacePhase = .open
                        } else {
                            model.spacePhase = .closed
                        }
                    } else {
                        await dismissSpace()
                        model.spacePhase = .closed
                    }
                }
            }
        )
    }

    private var connectionLabel: String {
        switch session.connection {
        case .idle: return "Not connected"
        case .connecting: return "Looking for the Mac…"
        case let .connected(_, model): return "Connected · \(model)"
        case let .reconnecting(attempt): return "Reconnecting (\(attempt))…"
        case let .failed(reason): return reason
        }
    }

    private func send() {
        session.send(utterance: draft)
        draft = ""
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
        .environment(AppModel())
        .environmentObject(AgentSession(home: MockHomeProvider()))
}
