import AgentProtocol
import AgentTransport
import CharacterKit
import HomeBridge
import SceneUnderstanding
import XCTest
import simd
@testable import AgentKit

/// In-process channel. It does NOT bypass the codec: every message is encoded and decoded
/// with `WireCodec`, mirroring rule 1 of the mock layer (docs/architecture.md §6) — a mock
/// that skips the wire stops catching wire bugs, which are the ones that only show up
/// on-device.
final class LoopbackChannel: AgentChannel, @unchecked Sendable {
    let events: AsyncStream<ServerEvent>
    private let continuation: AsyncStream<ServerEvent>.Continuation
    private let lock = NSLock()
    private var _sent: [ClientMessage] = []

    var sent: [ClientMessage] { lock.withLock { _sent } }

    init() {
        var cont: AsyncStream<ServerEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func connect(to endpoint: AgentEndpoint) async {}
    func disconnect() async { continuation.finish() }

    func send(_ message: ClientMessage) async {
        let line = try! WireCodec.encode(message)
        let decoded = try! WireCodec.decodeClientMessage(line)!
        lock.withLock { _sent.append(decoded) }
    }

    /// Server half: also round-trips through the codec.
    func emit(_ event: ServerEvent) {
        let line = try! WireCodec.encode(event)
        continuation.yield(try! WireCodec.decodeEvent(line)!)
    }
}

@MainActor
final class AgentSessionTests: XCTestCase {
    private func makeSession(
        home: any HomeProviding
    ) -> (AgentSession, LoopbackChannel) {
        let channel = LoopbackChannel()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let session = AgentSession(
            channel: channel,
            home: home,
            places: NamedPlaceStore(defaults: defaults)
        )
        session.connect(to: AgentEndpoint(name: "test", host: "127.0.0.1", port: 8787))
        return (session, channel)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    func testReadyPublishesDeviceAndSceneSnapshots() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "llama3.2", capabilities: Capabilities(), resumed: false))
        await settle()

        XCTAssertTrue(session.connection.isConnected)
        XCTAssertTrue(channel.sent.contains { if case .deviceStates = $0 { return true }; return false })
        XCTAssertTrue(channel.sent.contains { if case .sceneUpdate = $0 { return true }; return false })
    }

    func testProtocolVersionMismatchFailsWithAStatedReason() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 99, model: "x", capabilities: Capabilities(), resumed: false))
        await settle()

        guard case let .failed(reason) = session.connection else {
            return XCTFail("expected failure, got \(session.connection)")
        }
        XCTAssertTrue(reason.contains("99"))
    }

    func testTokensStreamIntoTheReply() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()
        session.send(utterance: "turn off the kitchen light")
        await settle()

        let id = channel.sent.compactMap { message -> String? in
            if case let .userUtterance(id, _, _) = message { return id }
            return nil
        }.last!

        channel.emit(.token(utteranceId: id, text: "On "))
        channel.emit(.token(utteranceId: id, text: "it."))
        await settle()
        XCTAssertEqual(session.currentReply, "On it.")

        channel.emit(.utteranceEnd(utteranceId: id))
        await settle()
        XCTAssertFalse(session.isStreaming)
        XCTAssertEqual(session.transcript.last?.text, "On it.")
    }

    /// PRD §6: the character reacts before it knows the answer.
    func testCharacterEntersThinkingOnSendNotOnFirstToken() async {
        let (session, _) = makeSession(home: MockHomeProvider())
        session.send(utterance: "hello")
        XCTAssertEqual(session.characterState, .thinking)
    }

    func testSafeToolExecutesWithoutConfirmation() async throws {
        let home = MockHomeProvider()
        let (session, channel) = makeSession(home: home)
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t1", name: "set_light",
                args: ["device_id": .string("light.desk"), "on": .bool(true)],
                safety: .safe, executedBy: .client
            )
        )
        await settle()

        XCTAssertTrue(session.confirmations.pending.isEmpty)
        XCTAssertEqual(home.devices.first { $0.id == "light.desk" }?.state?["on"]?.boolValue, true)
        XCTAssertTrue(channel.sent.contains { message in
            if case let .toolResult(callId, ok, _, _) = message { return callId == "t1" && ok }
            return false
        })
    }

    /// The binary success criterion (PRD §6): no unsafe action executes without confirmation.
    func testUnsafeToolBlocksUntilConfirmed() async throws {
        let home = MockHomeProvider()
        let (session, channel) = makeSession(home: home)
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t2", name: "set_lock",
                args: ["device_id": .string("lock.front"), "locked": .bool(false)],
                safety: .unsafe, executedBy: .client
            )
        )
        await settle()

        XCTAssertEqual(session.confirmations.pending.first?.summary, "Unlock the Front Door")
        // Nothing has executed and nothing has been reported back yet.
        XCTAssertEqual(
            home.devices.first { $0.id == "lock.front" }?.state?["locked"]?.boolValue, true
        )
        XCTAssertFalse(channel.sent.contains { message in
            if case let .toolResult(callId, _, _, _) = message { return callId == "t2" }
            return false
        })

        session.confirmations.confirm("t2")
        await settle()
        XCTAssertEqual(
            home.devices.first { $0.id == "lock.front" }?.state?["locked"]?.boolValue, false
        )
    }

    /// A server that lies about safety must not get a free unlock.
    func testServerAssertedSafeOnALockStillRequiresConfirmation() async {
        let home = MockHomeProvider()
        let (session, channel) = makeSession(home: home)
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t3", name: "set_lock",
                args: ["device_id": .string("lock.front"), "locked": .bool(false)],
                safety: .safe, executedBy: .client
            )
        )
        await settle()

        XCTAssertEqual(session.confirmations.pending.count, 1)
        XCTAssertEqual(
            home.devices.first { $0.id == "lock.front" }?.state?["locked"]?.boolValue, true
        )
    }

    func testCancelledConfirmationReportsFailureAndLeavesDeviceAlone() async {
        let home = MockHomeProvider()
        let (session, channel) = makeSession(home: home)
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t4", name: "set_lock",
                args: ["device_id": .string("lock.front"), "locked": .bool(false)],
                safety: .unsafe, executedBy: .client
            )
        )
        await settle()
        session.confirmations.cancel("t4")
        await settle()

        XCTAssertTrue(channel.sent.contains { message in
            if case let .toolResult(callId, ok, _, error) = message {
                return callId == "t4" && !ok && error == "user_cancelled"
            }
            return false
        })
        XCTAssertEqual(
            home.devices.first { $0.id == "lock.front" }?.state?["locked"]?.boolValue, true
        )
    }

    // MARK: Server-side execution (docs/middle-layer-todo.md §1)

    /// HomeKit is absent from the visionOS SDK, so the Mac executes. The headset's whole
    /// job is asking a human, and it must never claim to have acted.
    func testServerExecutedToolSendsApprovalNotAToolResult() async {
        let home = MockHomeProvider()
        let (session, channel) = makeSession(home: home)
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t9", name: "set_lock",
                args: ["device_id": .string("lock.front"), "locked": .bool(false)],
                safety: .unsafe, executedBy: .server
            )
        )
        await settle()
        XCTAssertEqual(session.confirmations.pending.count, 1)

        session.confirmations.confirm("t9")
        await settle()

        XCTAssertTrue(channel.sent.contains { message in
            if case let .confirmationResult(callId, approved) = message {
                return callId == "t9" && approved
            }
            return false
        })
        XCTAssertFalse(channel.sent.contains { message in
            if case let .toolResult(callId, _, _, _) = message { return callId == "t9" }
            return false
        })
        // The client did not touch the device; the server owns execution.
        XCTAssertEqual(
            home.devices.first { $0.id == "lock.front" }?.state?["locked"]?.boolValue, true
        )
    }

    func testDeclinedServerExecutedToolSendsRefusal() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t10", name: "set_lock",
                args: ["device_id": .string("lock.front"), "locked": .bool(false)],
                safety: .unsafe, executedBy: .server
            )
        )
        await settle()
        session.confirmations.cancel("t10")
        await settle()

        XCTAssertTrue(channel.sent.contains { message in
            if case let .confirmationResult(callId, approved) = message {
                return callId == "t10" && !approved
            }
            return false
        })
    }

    // MARK: Ambient and place requests

    func testAmbientEventWithNowInterruptSpeaksImmediately() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(ambientEvents: true), resumed: false))
        await settle()

        channel.emit(
            .ambientEvent(
                source: "sensor.doorbell", kind: .doorbell, interrupt: .now,
                text: "Someone is at the door."
            )
        )
        await settle()

        XCTAssertEqual(session.lastAmbient?.kind, .doorbell)
        XCTAssertEqual(session.transcript.last?.text, "Someone is at the door.")
    }

    /// `silent` updates state and says nothing: a light changing is not worth a sentence.
    func testSilentAmbientEventDoesNotSpeak() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(ambientEvents: true), resumed: false))
        await settle()

        channel.emit(
            .ambientEvent(
                source: "light.kitchen", kind: .stateChange, interrupt: .silent, text: "on"
            )
        )
        await settle()

        XCTAssertEqual(session.lastAmbient?.interrupt, .silent)
        XCTAssertTrue(session.transcript.isEmpty)
    }

    func testRequestPlaceIsAskedInCharacter() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(requestPlace: true), resumed: false))
        await settle()

        channel.emit(.requestPlace(name: "kitchen", prompt: "Where's the kitchen?"))
        await settle()

        XCTAssertEqual(session.placeRequest?.name, "kitchen")
        XCTAssertEqual(session.transcript.last?.text, "Where's the kitchen?")
    }

    func testCapabilitiesAreReadFromReady() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(
            .ready(
                sessionId: "s1", protocolVersion: 1, model: "m",
                capabilities: Capabilities(ambientEvents: true, toolExecution: .server),
                resumed: false
            )
        )
        await settle()

        XCTAssertEqual(session.capabilities.toolExecution, .server)
        XCTAssertTrue(session.capabilities.ambientEvents)
    }

    func testUnknownPlaceDirectiveSpeaksInsteadOfMoving() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        let scene = FixtureSceneProvider.apartment()
        session.attach(scene: scene)
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(.characterDirective(CharacterDirective(kind: .walkTo, place: "conservatory")))
        await settle()

        XCTAssertEqual(session.lastResolved, .unresolved(reason: .unknownPlace("conservatory")))
        XCTAssertTrue(session.transcript.last?.text.contains("conservatory") ?? false)
    }

    func testDisconnectIsSpokenPlainlyNotShownAsACode() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.error(code: "disconnected", message: "I can't reach the Mac right now."))
        await settle()
        XCTAssertFalse(session.transcript.last?.text.contains("disconnected") ?? true)
    }

    /// The view observes the session, not the gate inside it. Without this mirror the
    /// confirmation ornament never renders and an unsafe call sits invisible until it
    /// times out — which is exactly how it failed in the simulator.
    func testPendingConfirmationsAreRepublishedOnTheSession() async {
        let (session, channel) = makeSession(home: MockHomeProvider())
        channel.emit(.ready(sessionId: "s1", protocolVersion: 1, model: "m", capabilities: Capabilities(), resumed: false))
        await settle()

        channel.emit(
            .toolCall(
                callId: "t11", name: "set_lock",
                args: ["device_id": .string("lock.front"), "locked": .bool(false)],
                safety: .unsafe, executedBy: .server
            )
        )
        await settle()
        XCTAssertEqual(session.pendingConfirmations.map(\.id), ["t11"])

        session.confirmations.confirm("t11")
        await settle()
        XCTAssertTrue(session.pendingConfirmations.isEmpty)
    }
}
