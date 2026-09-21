import AgentProtocol
import Foundation
import Observation
import SceneUnderstanding
import SpatialMemory

/// Runs the demo script.
///
/// Two jobs, both of which exist because a stage demo cannot depend on a laptop being
/// reachable. First, it populates the room: every `LandmarkPreset` is written through
/// `LandmarkPlacer`, so the map the bird navigates is real user data, world-anchored where
/// anchoring is available and synthetically offset where it is not. Second, it plays a
/// chip's `script` when no server is attached, pushing the same `CharacterDirective`s the
/// model would have emitted through the same resolver.
///
/// When a server *is* attached it does nothing but forward the utterance. The scripted path
/// is the understudy, never the understudy standing in front of the lead.
@MainActor
@Observable
public final class DemoDirector {
    public enum RoomState: Equatable, Sendable {
        case empty
        case seeding
        /// `synthetic` when nothing could be raycast, which is the simulator's normal case.
        case ready(placed: Int, synthetic: Bool)

        public var isReady: Bool { if case .ready = self { return true }; return false }
    }

    public private(set) var room: RoomState = .empty
    /// The prompt currently being replayed, so a chip can show it is mid-beat.
    public private(set) var playing: DemoPrompt?
    /// Last thing that stopped a beat from being legible, spoken in the window rather than
    /// swallowed: a demo failing silently is worse than a demo failing out loud.
    public private(set) var problem: String?

    private unowned let session: AgentSession
    private var task: Task<Void, Never>?

    public init(session: AgentSession) {
        self.session = session
    }

    public var isPlaying: Bool { playing != nil }

    // MARK: Room

    /// Places every preset that is not placed yet. Idempotent, so it is safe to hit before
    /// each run-through, and cheap enough to hit automatically when the space opens.
    public func seedRoom(_ presets: [LandmarkPreset] = LandmarkPreset.demoRoom) async {
        guard let placer = session.landmarks else {
            room = .empty
            problem = "No room yet — open the immersive space first."
            return
        }
        room = .seeding
        var placed = 0
        var synthetic = false
        for preset in presets where !placer.isPlaced(preset) {
            switch await placer.place(preset) {
            case .placed:
                placed += 1
            case .placedSynthetically:
                placed += 1
                synthetic = true
            case let .failed(reason):
                problem = reason
            }
        }
        let total = presets.filter { placer.isPlaced($0) }.count
        room = total == 0 ? .empty : .ready(placed: total, synthetic: synthetic)
        if total > 0 { problem = nil }
        _ = placed
    }

    /// Wipes the map and the anchors behind it. The checklist's reset, reachable from the
    /// demo bar so a second run-through starts from nothing.
    public func resetRoom() async {
        stop()
        await session.landmarks?.resetRoom()
        room = .empty
        problem = nil
    }

    // MARK: Playback

    /// What a chip tap does. Connected: the utterance goes to the model, unchanged. Offline:
    /// the scripted beat plays.
    public func tap(_ prompt: DemoPrompt) {
        guard session.isOffline, !prompt.script.isEmpty else {
            session.send(utterance: prompt.utterance)
            return
        }
        play(prompt)
    }

    /// Plays one beat locally, cancelling whatever was mid-flight.
    public func play(_ prompt: DemoPrompt) {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run([prompt])
        }
    }

    /// The beats of DEMO.md §2, back to back, with the room seeded first.
    public func runOfShow() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            if !self.room.isReady { await self.seedRoom() }
            await self.run(DemoScenarios.runOfShow, gap: 1.6)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        playing = nil
    }

    private func run(_ prompts: [DemoPrompt], gap: TimeInterval = 0) async {
        for prompt in prompts {
            if Task.isCancelled { break }
            playing = prompt
            session.appendUserLocally(prompt.utterance)
            for action in prompt.script {
                if Task.isCancelled { break }
                await perform(action)
            }
            if gap > 0 { await sleep(gap) }
        }
        playing = nil
    }

    private func perform(_ action: DemoAction) async {
        switch action {
        case let .say(line):
            session.speakLocally(line)
            // Long lines get their own read time, so the next directive does not step on
            // the speech bubble.
            await sleep(min(3.0, 0.9 + Double(line.count) / 28.0))

        case let .directive(directive):
            session.applyLocally(directive)
            if directive.kind == .walkTo { await sleep(0.3) }

        case let .pause(seconds):
            await sleep(seconds)

        case let .teach(presetId):
            guard let preset = LandmarkPreset.preset(id: presetId) else { return }
            guard let placer = session.landmarks else {
                problem = "No room yet — open the immersive space first."
                return
            }
            if !placer.isPlaced(preset) { _ = await placer.place(preset) }

        case let .device(id, on):
            await session.executeLocally(
                tool: "set_light",
                args: ["device_id": .string(id), "on": .bool(on)]
            )

        case let .satisfy(need):
            await satisfy(need)

        case .inventory:
            session.speakLocally(session.places.inventory)
            await sleep(3.0)

        case .perch:
            // No `satisfy` here: a need resolves to the one place that answers it, and a
            // perch is a choice between three that all do. The line and the flight both
            // come from `AgentSession.goPerch`, which is also what a server directive
            // would drive, so the scripted and live paths stay one path.
            let choice = session.goPerch()
            await sleep(min(3.4, 1.1 + Double(choice.line.count) / 28.0))
            if choice.canAct { await sleep(1.2) }

        case .forgetKnockOffs:
            session.places.forgetKnockOffs()

        case .decide:
            guard let need = HabitMemory.strongestNeed(in: session.places.map) else {
                session.speakLocally(
                    "I don't know this room yet. Show me where I eat and I'll take it from there."
                )
                await sleep(2.4)
                return
            }
            await satisfy(need)
        }
    }

    /// The one beat that is a lookup rather than a line. `MapStore.visit` resolves the need
    /// against the map *and* counts the visit, so the sentence gets more confident each time
    /// the same chip is tapped — the count is the learning, and it is on the record in the
    /// inspector rather than in a variable here.
    private func satisfy(_ need: Need) async {
        let decision = session.places.visit(need)
        session.speakLocally(decision.line)
        await sleep(min(3.0, 0.9 + Double(decision.line.count) / 28.0))
        guard let place = decision.place else {
            // Nothing placed for this need: the bird asks instead of flying somewhere
            // arbitrary, which is what makes the successful case mean anything.
            session.applyLocally(CharacterDirective(kind: .lookAt, target: .user))
            session.applyLocally(CharacterDirective(kind: .emote, emotion: .concerned))
            return
        }
        session.applyLocally(
            CharacterDirective(kind: .walkTo, place: place.name, target: .place)
        )
        await sleep(2.4)
        session.applyLocally(CharacterDirective(kind: .emote, emotion: .happy))
        if need == .lonely { session.applyLocally(CharacterDirective(kind: .gesture)) }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
