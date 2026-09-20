import AgentProtocol
import AgentTransport
import CharacterKit
import Combine
import Foundation
import HomeBridge
import SceneUnderstanding
import SpatialMemory
import simd

/// The one object the app talks to. Owns nothing spatial and renders nothing — it turns
/// `ServerEvent`s into state the views and the character observe.
///
/// The division of labour is the one in docs/architecture.md §8: what the character *does*
/// is decided in Python; rendering, ARKit anchors, gaze and animation blending are decided
/// here. Anything added to this file that decides behaviour belongs in `agentd` instead.
@MainActor
public final class AgentSession: ObservableObject {
    // MARK: Published state

    @Published public private(set) var connection: ConnectionState = .idle
    /// Streaming reply, rendered in the speech bubble token by token.
    @Published public private(set) var currentReply: String = ""
    @Published public private(set) var isStreaming = false
    @Published public private(set) var transcript: [TranscriptEntry] = []
    @Published public private(set) var characterState: CharacterState = .idle
    @Published public private(set) var lastResolved: ResolvedDirective?
    /// What the server said it can do, read from `ready` rather than discovered by failure.
    @Published public private(set) var capabilities = Capabilities()
    /// True when the server recognised the offered session id and kept the transcript.
    @Published public private(set) var didResumeSession = false
    /// Last ambient event the home pushed unprompted (PRD §4).
    @Published public private(set) var lastAmbient: AmbientNotice?
    /// Set when the agent asks the user to name a place; cleared once it is named.
    @Published public private(set) var placeRequest: PlaceRequest?
    /// Mirrors `confirmations.pending`.
    ///
    /// A view observing `AgentSession` is not observing the gate inside it: nested
    /// `ObservableObject`s do not propagate, so the confirmation ornament silently never
    /// rendered even though the gate was holding a pending unlock. Republishing here is
    /// what makes the prompt appear.
    @Published public private(set) var pendingConfirmations: [PendingConfirmation] = []

    public let confirmations = ConfirmationGate()
    public let places: MapStore
    /// Gaze capture and the teaching acts that resolve against it. Present only once a scene
    /// provider that can raycast is attached; teaching without a room to look at is not an
    /// act the client can complete.
    public private(set) var teaching: TeachingResolver?
    public private(set) var gaze: GazeCapture?
    /// Set when a teaching act landed inside an existing place and the user has to choose
    /// between renaming it and nesting inside it (spec 07 §Disambiguation).
    @Published public private(set) var teachingQuestion: TeachingQuestion?
    /// The last name taught, for the inspector and for tests.
    @Published public private(set) var lastTaught: String?

    // MARK: Collaborators

    private let channel: AgentChannel
    private let home: any HomeProviding
    private let resolver = DirectiveResolver()
    private var scene: (any SceneProviding)?

    /// Set by the render layer each frame; the resolver needs it to path from where the
    /// character actually is.
    public var characterPosition: SIMD3<Float> = .zero

    private var pumpTask: Task<Void, Never>?
    private var pendingUtteranceId: String?
    /// Id shared by the partial transcripts of the utterance currently being spoken.
    private var pendingPartialId: String?
    private var lastSceneSent: Date = .distantPast
    private var directiveSink: ((ResolvedDirective) -> Void)?
    /// Affinity inputs, routed to the body. The session knows what happened; the entity owns
    /// how it feels about it.
    private var characterMood: ((Mood.Input) -> Void)?
    private var signalSink: ((CharacterEvent) -> Void)?
    /// Mirrors the renderer's machine so views can observe state without touching RealityKit.
    private var machine = CharacterStateMachine()
    private var cancellables: Set<AnyCancellable> = []

    /// Defaults are constructed inside the initializer rather than as default arguments:
    /// both collaborators are `@MainActor`, and a default argument is evaluated in a
    /// nonisolated context.
    public init(
        channel: AgentChannel? = nil,
        home: (any HomeProviding)? = nil,
        places: MapStore? = nil
    ) {
        self.channel = channel ?? WebSocketAgentChannel()
        self.home = home ?? RemoteHomeProvider()
        self.places = places ?? MapStore()

        confirmations.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.pendingConfirmations = $0 }
            .store(in: &cancellables)
    }

    // MARK: Wiring

    /// The render layer registers here rather than the session holding a `CharacterEntity`,
    /// which keeps RealityKit out of this type and lets the whole session be unit-tested.
    public func bindCharacter(
        onDirective: @escaping (ResolvedDirective) -> Void,
        onSignal: @escaping (CharacterEvent) -> Void,
        onMood: ((Mood.Input) -> Void)? = nil
    ) {
        directiveSink = onDirective
        signalSink = onSignal
        characterMood = onMood
    }

    /// Attaches gaze capture so teaching acts have somewhere to land.
    public func attachGaze(_ caster: any GazeCasting) {
        let capture = GazeCapture(caster: caster)
        gaze = capture
        teaching = TeachingResolver(store: places, gaze: capture)
    }

    public func attach(scene: any SceneProviding) {
        self.scene = scene
        if let caster = scene as? any GazeCasting { attachGaze(caster) }
        scene.onMeshChanged = { [weak self] mesh in
            self?.sendSceneUpdate(floorArea: mesh.floorArea)
        }
    }

    // MARK: Lifecycle

    public func connect(to endpoint: AgentEndpoint) {
        connection = .connecting
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            await self.channel.connect(to: endpoint)
            for await event in self.channel.events {
                await self.handle(event)
            }
        }
    }

    public func disconnect() {
        pumpTask?.cancel()
        Task { await channel.disconnect() }
        connection = .idle
    }

    // MARK: Input

    public func send(utterance text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A dictated utterance keeps the id its partials used, so the server sees one
        // utterance growing rather than two.
        let id = pendingPartialId ?? UUID().uuidString
        pendingPartialId = nil
        pendingUtteranceId = id
        transcript.append(TranscriptEntry(role: .user, text: trimmed))
        currentReply = ""
        isStreaming = true
        // Held from the start of the sentence, for the whole act (spec 07 §Capture).
        captureGazeAtUtteranceStart()

        // React before the answer exists. The 400ms budget in PRD §6 is met here, not after
        // the model responds: the character enters `thinking` on send.
        signal(.utteranceEnded)
        Task { await channel.send(.userUtterance(id: id, text: trimmed, isFinal: true)) }
    }

    /// Streams a partial speech transcript. The character is already listening; this only
    /// keeps the server's view of the sentence current, so it is never final and never
    /// enters the transcript.
    public func send(partial text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, capabilities.speechInput else { return }
        let id = pendingPartialId ?? { let new = UUID().uuidString; pendingPartialId = new; return new }()
        captureGazeAtUtteranceStart()
        Task { await channel.send(.userUtterance(id: id, text: trimmed, isFinal: false)) }
    }

    /// Called when the user's gaze lands on the character, or the field takes focus.
    public func addressed() { signal(.addressed) }

    public func publishDevices() {
        Task { await channel.send(.deviceStates(devices: home.devices)) }
    }

    /// Throttled to meaningful change, never per frame (spec/03-protocol.md).
    public func sendSceneUpdate(floorArea: Double?) {
        guard Date().timeIntervalSince(lastSceneSent) > 2 else { return }
        lastSceneSent = Date()
        let snapshot = places.snapshot(
            userPosition: scene?.userPosition,
            floorArea: floorArea
        )
        Task { await channel.send(.sceneUpdate(scene: snapshot)) }
    }

    // MARK: Event handling

    private func handle(_ event: ServerEvent) async {
        switch event {
        case let .ready(sessionId, version, model, capabilities, resumed):
            guard version == Wire.protocolVersion else {
                connection = .failed("Protocol v\(version) from server, client speaks v\(Wire.protocolVersion).")
                await channel.disconnect()
                return
            }
            self.capabilities = capabilities
            didResumeSession = resumed
            connection = .connected(sessionId: sessionId, model: model)
            // A resumed session is mid-thought: the character picks up attention rather
            // than starting from cold idle.
            if resumed { signal(.addressed) }
            // Full snapshot on connect; deltas after.
            publishDevices()
            sendSceneUpdate(floorArea: scene?.navMesh?.floorArea)

        case let .token(utteranceId, text):
            guard utteranceId == pendingUtteranceId || pendingUtteranceId == nil else { return }
            if currentReply.isEmpty { signal(.firstToken) }
            currentReply += text

        case let .utteranceEnd(utteranceId):
            guard utteranceId == pendingUtteranceId else { return }
            isStreaming = false
            if !currentReply.isEmpty {
                transcript.append(TranscriptEntry(role: .agent, text: currentReply))
            }
            signal(.speechEnded)
            pendingUtteranceId = nil

        case let .characterDirective(directive):
            apply(directive)

        case let .toolCall(callId, name, args, safety, executedBy):
            await runTool(
                callId: callId,
                name: name,
                args: args,
                serverSafety: safety,
                executedBy: executedBy
            )

        case let .homeDevices(devices):
            // The Mac owns the home; this is the only way the headset learns a device's
            // name, which is what a confirmation prompt has to show.
            (home as? RemoteHomeProvider)?.ingest(devices)

        case let .ambientEvent(source, kind, interrupt, text):
            lastAmbient = AmbientNotice(
                source: source, kind: kind, interrupt: interrupt, text: text
            )
            // The server classified the urgency; the client only decides the rendering.
            switch interrupt {
            case .now:
                speakInCharacter(text)
            case .passing:
                if case .idle = characterState { speakInCharacter(text) }
            case .silent:
                break
            }

        case let .requestPlace(name, prompt):
            placeRequest = PlaceRequest(name: name, prompt: prompt)
            speakInCharacter(prompt)

        case let .error(code, message):
            if code == "disconnected" { connection = .reconnecting(attempt: 1) }
            // Every failure is spoken in character. No dialogs, no codes.
            speakInCharacter(message)

        case .pong:
            break
        }
    }

    /// Taught objects that carry a device binding, as a device-id lookup.
    private func devicePositions() -> [String: SIMD3<Float>] {
        var out: [String: SIMD3<Float>] = [:]
        for object in places.map.objects {
            guard let id = object.deviceId, object.isNavigable else { continue }
            out[id] = object.position
        }
        return out
    }

    private func apply(_ directive: CharacterDirective) {
        let resolved = resolver.resolve(
            directive,
            characterPosition: characterPosition,
            userPosition: scene?.userPosition ?? .zero,
            places: places.places,
            // Device positions come from taught objects: the binding between a thing in the
            // room and a device id is user data on the client, never anything the server
            // sent (spec 07 §Learned behavior).
            devicePositions: devicePositions(),
            navMesh: scene?.navMesh,
            objects: places.map.objects,
            gaze: gaze?.target()?.point
        )
        lastResolved = resolved
        if case let .unresolved(reason) = resolved {
            speakInCharacter(reason.spokenLine)
        }
        directiveSink?(resolved)
    }

    // MARK: Tools

    // MARK: Teaching

    /// Captures the gaze target at the moment an utterance begins (spec 07 §Capture).
    ///
    /// Called from both the final utterance and the first partial of a dictated one: by the
    /// time "this is my workspace" has finished, the user is already looking somewhere else,
    /// so the capture has to happen at the first word the client hears.
    private func captureGazeAtUtteranceStart() {
        guard let gaze, let scene else { return }
        guard gaze.target() == nil else { return }
        gaze.beginUtterance(origin: scene.userPosition, direction: scene.userForward)
    }

    /// Runs one of the five teaching acts against the held gaze target and answers the
    /// server with what happened — never with where it happened.
    private func runTeaching(callId: String, act: TeachingAct, args: JSONObject?) async {
        guard let teaching else {
            await channel.send(
                .toolResult(callId: callId, ok: false, payload: nil, error: "no_room_yet")
            )
            return
        }
        let name = args?["name"]?.stringValue ?? ""
        let deviceId = args?["device_id"]?.stringValue
        let hard = args?["hard"]?.boolValue ?? true

        // Read before the act, because a completed act releases the held target.
        let target = gaze?.target()?.point
        let outcome = await teaching.apply(act, name: name, deviceId: deviceId, hard: hard)
        acknowledgeOnTheBody(act, target: target)
        await report(outcome, callId: callId, act: act)
    }

    /// The bird's half of the act: look now, hop if it can (spec 07 §Acknowledgement).
    ///
    /// Driven from here rather than from the render layer so that the 400ms budget is met by
    /// the directive that has already been resolved, not by a later frame's guess.
    private func acknowledgeOnTheBody(_ act: TeachingAct, target: SIMD3<Float>?) {
        guard let target else { return }
        emit(.look(at: target))
        guard act != .forbidRegion,
              let mesh = scene?.navMesh,
              let path = mesh.path(from: characterPosition, to: target)
        else { return }
        emit(.walk(path: path))
    }

    private func emit(_ resolved: ResolvedDirective) {
        lastResolved = resolved
        directiveSink?(resolved)
    }

    private func report(_ outcome: TeachingOutcome, callId: String, act: TeachingAct) async {
        switch outcome {
        case let .taught(_, name, _):
            characterMood?(.taught)
            // Saying the name back is the confirmation channel for a mis-transcription, so
            // it happens here rather than being left to whatever the model says next.
            speakInCharacter("Okay — \(name).")
            lastTaught = name
            await channel.send(
                .toolResult(callId: callId, ok: true, payload: ["name": .string(name)], error: nil)
            )
        case let .corrected(_, name, _):
            characterMood?(.taught)
            speakInCharacter("Got it — \(name) now.")
            lastTaught = name
            await channel.send(
                .toolResult(
                    callId: callId,
                    ok: true,
                    payload: ["name": .string(name), "corrected": .bool(true)],
                    error: nil
                )
            )
        case .needsGaze:
            speakInCharacter("I didn't catch where — look at it and say that again?")
            await channel.send(
                .toolResult(callId: callId, ok: false, payload: nil, error: "no_gaze_target")
            )
        case let .needsDisambiguation(existing, name, act):
            teachingQuestion = TeachingQuestion(
                existingName: existing.name,
                proposedName: name,
                act: act,
                callId: callId
            )
            speakInCharacter(
                "That's inside \(existing.name). Rename it to \(name), or is \(name) a thing in there?"
            )
        case let .failed(reason):
            await channel.send(
                .toolResult(callId: callId, ok: false, payload: nil, error: reason)
            )
        }
    }

    /// The two answers a disambiguation has, and the only two (spec 07 §Disambiguation).
    public enum TeachingAnswer: Sendable { case rename, nest }

    public func answerTeaching(_ answer: TeachingAnswer) {
        guard let question = teachingQuestion, let teaching else { return }
        teachingQuestion = nil
        Task {
            let outcome: TeachingOutcome
            switch answer {
            case .rename:
                guard let existing = places.map.place(named: question.existingName) else {
                    return
                }
                outcome = teaching.rename(existing: existing, to: question.proposedName)
            case .nest:
                outcome = await teaching.nest(name: question.proposedName, act: question.act)
            }
            await report(outcome, callId: question.callId, act: question.act)
        }
    }

    private func runTool(
        callId: String,
        name: String,
        args: JSONObject?,
        serverSafety: Safety,
        executedBy: Executor
    ) async {
        // Teaching acts are resolved against the gaze target and the map, never against the
        // home, so they never reach the safety gate or an executor.
        if executedBy == .client, let act = TeachingAct(rawValue: name) {
            await runTeaching(callId: callId, act: act, args: args)
            return
        }

        // Client-enforced, independent of what the server asserted. Stricter wins.
        let safety = ToolSafety.effective(name: name, serverAsserted: serverSafety)

        // Server-executed: this client's whole job is asking a human. It never reports
        // having acted, because it did not (docs/middle-layer-todo.md §1).
        if executedBy == .server {
            guard safety == .unsafe else { return }
            let device = home.devices.first { $0.id == args?["device_id"]?.stringValue }
            let summary = ConfirmationGate.summarize(tool: name, args: args, device: device)
            let outcome = await confirmations.request(
                callId: callId,
                toolName: name,
                deviceName: device?.name ?? "device",
                summary: summary
            )
            await channel.send(
                .confirmationResult(callId: callId, approved: outcome == .confirmed)
            )
            if outcome != .confirmed { speakInCharacter("Okay — leaving that alone.") }
            return
        }

        if safety == .unsafe {
            let device = home.devices.first { $0.id == args?["device_id"]?.stringValue }
            let summary = ConfirmationGate.summarize(tool: name, args: args, device: device)
            let outcome = await confirmations.request(
                callId: callId,
                toolName: name,
                deviceName: device?.name ?? "device",
                summary: summary
            )
            guard outcome == .confirmed else {
                await channel.send(
                    .toolResult(
                        callId: callId,
                        ok: false,
                        payload: nil,
                        error: outcome == .timedOut ? "confirmation_timed_out" : "user_cancelled"
                    )
                )
                speakInCharacter("Okay — leaving that alone.")
                return
            }
        }

        do {
            let payload = try await home.execute(tool: name, args: args)
            await channel.send(.toolResult(callId: callId, ok: true, payload: payload, error: nil))
            publishDevices()
        } catch {
            let message = (error as? HomeError)?.spokenLine ?? "That didn't work."
            await channel.send(
                .toolResult(
                    callId: callId,
                    ok: false,
                    payload: nil,
                    error: (error as? HomeError)?.errorDescription ?? "\(error)"
                )
            )
            speakInCharacter(message)
        }
    }

    // MARK: Helpers

    private func speakInCharacter(_ line: String) {
        currentReply = line
        isStreaming = false
        transcript.append(TranscriptEntry(role: .agent, text: line))
        signal(.firstToken)
        signal(.speechEnded)
    }

    private func signal(_ event: CharacterEvent) {
        signalSink?(event)
        characterState = machine.handle(event)
    }
}

/// An ambient push, kept so a view can render it after the character has spoken.
public struct AmbientNotice: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let source: String
    public let kind: AmbientKind
    public let interrupt: AmbientInterrupt
    public let text: String
}

/// The agent asking for a place it does not have. Cleared when `places` gains that name.
/// A disambiguation the user has to answer, with exactly two answers.
public struct TeachingQuestion: Identifiable, Sendable {
    public let id = UUID()
    public let existingName: String
    public let proposedName: String
    public let act: TeachingAct
    let callId: String
}

public struct PlaceRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let prompt: String
}

public struct TranscriptEntry: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case user, agent }
    public let id = UUID()
    public let role: Role
    public let text: String
}
