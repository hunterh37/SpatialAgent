import AgentKit
import AgentTransport
import DesignSystem
import HomeBridge
import SwiftUI
import simd
import VoiceInput

/// Larry's control surface: connection, the transcript, and the text field that stands in for
/// speech until v0.2. The character itself lives in the immersive space; the window is the
/// playful shell around him (candy cards, an XP bar, a bobbing badge).
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var session: AgentSession
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    @StateObject private var voice = SpeechCapture()
    @State private var draft = ""
    @State private var manualHost = ""
    @State private var showingMap = false
    @State private var showingLandmarks = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LarryCard(tint: Larry.sky) { transcript }
            demoChips
            composer
        }
        .padding(22)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 760)
        .background(
            LinearGradient(
                colors: [Larry.grape.opacity(0.22), Larry.sky.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        .sheet(isPresented: $showingLandmarks) {
            LandmarkSetupView().environmentObject(session)
        }
        .sheet(isPresented: $showingMap) {
            MapInspectorView(highlighted: highlightBinding)
                .environmentObject(session)
        }
    }

    /// The inspector writes the highlight into the app model so the immersive view can draw
    /// it; the sheet and the room are two windows onto one selection.
    private var highlightBinding: Binding<SIMD3<Float>?> {
        Binding(
            get: { model.highlightedRecord },
            set: { model.highlightedRecord = $0 }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LarryAvatar(isExcited: session.isStreaming || voice.isListening)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Larry.name).font(.largeTitle.weight(.heavy))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Text(Larry.tagline).font(.caption).foregroundStyle(Larry.mint)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                Text(connectionLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("connection.label")
                LarryXPBar(level: level, progress: levelProgress).frame(width: 190)
            }
            Spacer()
            Button {
                showingLandmarks = true
            } label: {
                Label("Landmarks", systemImage: "mappin.and.ellipse")
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(.bordered)
            .tint(Larry.sky)
            .accessibilityIdentifier("landmarks.open")
            Button {
                showingMap = true
            } label: {
                Label("What I know", systemImage: "backpack.fill")
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(.bordered)
            .tint(Larry.mint)
            .accessibilityIdentifier("map.open")
            Toggle("In the room", isOn: spaceBinding)
                .toggleStyle(.button)
                .lineLimit(1).fixedSize()
                .tint(Larry.bubblegum)
                .accessibilityIdentifier("space.toggle")
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
                            if entry.role == .user {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(Larry.sky)
                                    .frame(width: 22)
                            } else {
                                LarryAvatar(size: 22)
                            }
                            Text(entry.text)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(
                                    (entry.role == .user ? Larry.sky : Larry.bubblegum).opacity(0.18),
                                    in: .rect(cornerRadius: 18)
                                )
                        }
                        .id(entry.id)
                        .accessibilityIdentifier(
                            entry.role == .user ? "transcript.user" : "transcript.agent"
                        )
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
            TextField("Tell Larry to do something", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.12), in: .capsule)
                .focused($fieldFocused)
                .onSubmit(send)
                .accessibilityIdentifier("composer.field")
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .tint(Larry.bubblegum)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("composer.send")
        }
        .padding(10)
        .background(Larry.grape.opacity(0.14), in: .capsule)
    }

    /// Canned utterances, sent verbatim through the same path the text field uses. The
    /// strings live in `DemoScenarios` so the demo script is data rather than view code.
    private var demoChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(DemoScenarios.all) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(group.title, systemImage: group.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Larry.mint)
                        HStack(spacing: 6) {
                            ForEach(group.prompts) { prompt in
                                Button(prompt.label) { session.send(utterance: prompt.utterance) }
                                    .buttonStyle(.bordered)
                                    .tint(Larry.grape)
                                    .font(.caption)
                                    .accessibilityIdentifier("demo.chip")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: 76)
    }

    /// Cosmetic only: Larry "levels up" every five exchanges so the window has a reason to
    /// celebrate. Nothing in the agent path reads these numbers.
    private var level: Int { session.transcript.count / 5 + 1 }
    private var levelProgress: Double { Double(session.transcript.count % 5) / 5.0 }

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
        .tint(voice.isListening ? Larry.bubblegum : Larry.mint)
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
        if let pending = session.pendingConfirmations.first {
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
