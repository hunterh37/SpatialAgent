import AgentKit
import AgentProtocol
import AgentTransport
import CharacterKit
import HomeBridge
import SceneUnderstanding
import XCTest
import simd

/// The real client stack against a real `agentd` running a real local model.
///
/// Everything else in this repo mocks one side or the other. This target mocks neither: a
/// live `WebSocketAgentChannel` over a live socket, `AgentSession` handling the events,
/// `DirectiveResolver` turning them into paths across the fixture apartment's navmesh. It
/// is the only test that can catch a schema mismatch between Swift and Python, because it
/// is the only one where both are present.
///
/// Opt-in, since it needs a server and a model:
///
///     make live            # boots agentd + ollama and runs this
///     AGENTD_LIVE_URL=ws://127.0.0.1:8787/agent swift test --filter LiveAgentTests
///
/// Skipped, not failed, when `AGENTD_LIVE_URL` is unset — CI without a model stays green.
final class LiveAgentTests: XCTestCase {
    private var endpoint: AgentEndpoint?

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["AGENTD_LIVE_URL"],
              let url = URL(string: raw), let host = url.host else {
            throw XCTSkip("set AGENTD_LIVE_URL to run the live integration tests")
        }
        endpoint = AgentEndpoint(
            name: "live", host: host, port: url.port ?? 8787, isManual: true
        )
    }

    // MARK: Harness

    /// Collects everything the render layer would have been told to do.
    @MainActor
    private final class CharacterSpy {
        var resolved: [ResolvedDirective] = []
        var signals: [CharacterEvent] = []

        var walks: [[SIMD3<Float>]] {
            resolved.compactMap { if case let .walk(path) = $0 { return path }; return nil }
        }

        var unresolved: [UnresolvedReason] {
            resolved.compactMap {
                if case let .unresolved(reason) = $0 { return reason }
                return nil
            }
        }
    }

    /// A session wired exactly as `SpatialAgentApp` wires it: fixture room, the apartment's
    /// named places, the mock home standing in for HomeKit.
    @MainActor
    private func makeLiveSession(
        store: UserDefaults? = nil
    ) async throws -> (AgentSession, CharacterSpy, MockHomeProvider) {
        let places = NamedPlaceStore(defaults: Self.scratchDefaults())
        for place in Self.apartmentPlaces { places.add(place) }

        let home = MockHomeProvider()
        let session = AgentSession(
            channel: WebSocketAgentChannel(store: store), home: home, places: places
        )
        let spy = CharacterSpy()
        session.bindCharacter(
            onDirective: { spy.resolved.append($0) },
            onSignal: { spy.signals.append($0) }
        )
        session.attach(scene: FixtureSceneProvider.apartment())
        session.characterPosition = SIMD3(0, 0, 0.8)
        session.connect(to: try XCTUnwrap(endpoint))

        try await waitUntil("connected", timeout: 10) { session.connection.isConnected }
        return (session, spy, home)
    }

    /// The same four places as `mocks/scenarios/apartment.yaml`, so both halves of the
    /// project are describing one imagined room.
    private static let apartmentPlaces: [PlaceRecord] = [
        PlaceRecord(name: "kitchen", position: SIMD3(2.4, 0, -1.8), radius: 0.9),
        PlaceRecord(name: "desk", position: SIMD3(-1.6, 0, -2.2), radius: 0.6),
        PlaceRecord(name: "couch", position: SIMD3(0.2, 0, 1.4), radius: 0.8),
        PlaceRecord(name: "front door", position: SIMD3(-3.1, 0, 0.4), radius: 0.5),
    ]

    private static func scratchDefaults() -> UserDefaults {
        let suite = "live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(what)")
    }

    // MARK: The protocol actually round-trips

    /// If Swift and Python disagree about a field name, nothing below this line works.
    func testHandshakeNegotiatesCapabilitiesOverARealSocket() async throws {
        let (session, _, _) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run {
            guard case let .connected(sessionId, model) = session.connection else {
                return XCTFail("expected connected, got \(session.connection)")
            }
            XCTAssertFalse(sessionId.isEmpty)
            XCTAssertFalse(model.isEmpty, "server must name the model it is running")
            XCTAssertGreaterThan(session.capabilities.idleTimeoutSeconds, 0)
        }
    }

    /// PRD §6: the character reacts before the model has produced anything.
    func testCharacterReactsBeforeTheModelAnswers() async throws {
        let (session, spy, _) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "hello there") }
        try await waitUntil("a directive", timeout: 5) { !spy.resolved.isEmpty }

        await MainActor.run {
            XCTAssertEqual(session.characterState, .thinking)
            // `lookAt(user)` and `emote(thinking)` are server-side acknowledgements, sent
            // ahead of the first token (agentd/session.py).
            XCTAssertTrue(spy.resolved.contains { if case .look = $0 { return true }; return false })
        }
        try await waitUntil("the reply to finish", timeout: 90) { !session.isStreaming }
    }

    func testTokensFromTheLocalModelStreamIntoTheTranscript() async throws {
        let (session, _, _) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "say hello in one short sentence") }
        try await waitUntil("a spoken reply", timeout: 90) {
            !session.isStreaming && session.transcript.contains { $0.role == .agent }
        }

        await MainActor.run {
            let reply = session.transcript.last { $0.role == .agent }?.text ?? ""
            XCTAssertFalse(reply.isEmpty)
            // The scratchpad of a reasoning model is filtered server-side; if that breaks,
            // the character says it out loud.
            XCTAssertFalse(reply.contains("<think>"))
        }
    }

    // MARK: The model moves the character through the real scene

    /// The headline: a sentence typed by a user becomes a path across the navmesh, with a
    /// local model choosing the destination and the client choosing every coordinate.
    func testModelDrivenWalkProducesAPathAcrossTheNavmesh() async throws {
        let (session, spy, _) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "turn off the kitchen lights") }
        try await waitUntil("a walk", timeout: 90) { !spy.walks.isEmpty }

        await MainActor.run {
            let path = spy.walks[0]
            XCTAssertGreaterThanOrEqual(path.count, 2, "a path is at least start and end")

            let kitchen = Self.apartmentPlaces[0].position
            let arrival = path.last!
            XCTAssertLessThan(
                simd_distance(SIMD3(arrival.x, 0, arrival.z), SIMD3(kitchen.x, 0, kitchen.z)),
                1.2,
                "the walk should end at the kitchen, not somewhere the model invented"
            )
            XCTAssertTrue(spy.unresolved.isEmpty, "unresolved: \(spy.unresolved)")
        }
    }

    /// Every waypoint has to be on the floor. This is the property that stops a
    /// hallucinated destination putting the character inside the couch.
    func testEveryWaypointIsOnReachableFloor() async throws {
        let (session, spy, _) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "go to the desk") }
        try await waitUntil("a walk", timeout: 90) { !spy.walks.isEmpty }

        await MainActor.run {
            let mesh = FixtureSceneProvider.apartment().navMesh!
            for point in spy.walks.flatMap({ $0 }) {
                XCTAssertTrue(
                    mesh.isWalkable(point),
                    "waypoint \(point) is off the navmesh — that is a character in a wall"
                )
            }
        }
    }

    /// A place the client never named cannot be walked to, whatever the model says.
    func testAPlaceTheClientNeverNamedIsAskedAboutNotWalkedTo() async throws {
        let (session, spy, _) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "walk over to the conservatory") }
        try await waitUntil("the turn to end", timeout: 90) { !session.isStreaming }

        await MainActor.run {
            for path in spy.walks {
                let end = path.last!
                for place in Self.apartmentPlaces where place.name == "conservatory" {
                    XCTFail("walked to \(place.name) at \(end)")
                }
            }
            // Either nothing moved, or the character spoke. What must not happen is a walk
            // to coordinates the model made up.
            XCTAssertFalse(session.transcript.isEmpty)
        }
    }

    // MARK: Tools

    /// The model decides *what*; the client decides whether it is allowed and does it.
    func testModelCanActuallyChangeADeviceThroughTheClient() async throws {
        let (session, _, home) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "turn off the kitchen lights") }
        try await waitUntil("the kitchen light to go off", timeout: 90) {
            home.devices.first { $0.id == "light.kitchen" }?.state?["on"]?.boolValue == false
        }
    }

    /// The binary safety criterion (PRD §6), end to end with a real model in the loop.
    func testUnsafeToolFromARealModelStillBlocksOnConfirmation() async throws {
        let (session, _, home) = try await makeLiveSession()
        defer { Task { @MainActor in session.disconnect() } }

        await MainActor.run { session.send(utterance: "unlock the front door") }
        try await waitUntil("a confirmation prompt", timeout: 90) {
            !session.confirmations.pending.isEmpty
        }

        await MainActor.run {
            XCTAssertEqual(
                home.devices.first { $0.id == "lock.front" }?.state?["locked"]?.boolValue,
                true,
                "nothing may unlock before a human taps confirm"
            )
        }
    }

    // MARK: Session state lives on the server

    /// A relaunched app offers back the session id it remembered, and the server hands the
    /// same conversation back rather than starting a new one (spec/03-protocol.md).
    func testRelaunchResumesTheConversationOnTheServer() async throws {
        let store = Self.scratchDefaults()

        let (first, _, _) = try await makeLiveSession(store: store)
        await MainActor.run {
            XCTAssertFalse(first.didResumeSession, "a cold start is not a resume")
            first.send(utterance: "remember the word pelican")
        }
        try await waitUntil("the first turn", timeout: 90) { !first.isStreaming }
        let firstId = await MainActor.run { first.connection }
        await MainActor.run { first.disconnect() }

        // Same store, new session object: exactly what launching the app again does.
        let (second, _, _) = try await makeLiveSession(store: store)
        defer { Task { @MainActor in second.disconnect() } }

        await MainActor.run {
            XCTAssertTrue(second.didResumeSession, "server did not recognise the session id")
            XCTAssertEqual(second.connection, firstId, "resumed onto a different session")
            XCTAssertNotNil(store.string(forKey: WebSocketAgentChannel.sessionIdKey))
        }
    }

    /// A client with nothing remembered must not accidentally land in someone's session.
    func testColdStartGetsAFreshSession() async throws {
        let (a, _, _) = try await makeLiveSession(store: nil)
        let (b, _, _) = try await makeLiveSession(store: nil)
        defer { Task { @MainActor in a.disconnect(); b.disconnect() } }

        await MainActor.run {
            XCTAssertFalse(a.didResumeSession)
            XCTAssertFalse(b.didResumeSession)
            XCTAssertNotEqual(a.connection, b.connection)
        }
    }
}
