import XCTest
@testable import AgentProtocol

final class WireTests: XCTestCase {
    /// The schema is the source of truth. Until `make protocol` generates this file, the
    /// contract is held by asserting the encoded field names against the schema's own
    /// spelling. A rename on either side fails here rather than on a headset.
    func testHelloEncodesSchemaFieldNames() throws {
        let json = try WireCodec.encode(
            .hello(protocolVersion: Wire.protocolVersion, client: "visionOS", sessionId: nil)
        )
        XCTAssertTrue(json.contains("\"type\":\"hello\""))
        XCTAssertTrue(json.contains("\"protocolVersion\":1"))
        XCTAssertTrue(json.contains("\"client\":\"visionOS\""))
        XCTAssertFalse(json.contains("sessionId"))
    }

    func testHelloCarriesSessionIdWhenResuming() throws {
        let json = try WireCodec.encode(
            .hello(protocolVersion: Wire.protocolVersion, client: "visionOS", sessionId: "s1")
        )
        XCTAssertTrue(json.contains("\"sessionId\":\"s1\""))
    }

    func testConfirmationResultCarriesApprovalOnly() throws {
        let json = try WireCodec.encode(.confirmationResult(callId: "c1", approved: true))
        XCTAssertTrue(json.contains("\"type\":\"confirmationResult\""))
        XCTAssertTrue(json.contains("\"approved\":true"))
        // It must not look like a claim to have executed anything.
        XCTAssertFalse(json.contains("payload"))
        XCTAssertFalse(json.contains("\"ok\""))
    }

    func testPartialTranscriptMarksItselfNotFinal() throws {
        let json = try WireCodec.encode(.userUtterance(id: "u1", text: "turn off the", isFinal: false))
        XCTAssertTrue(json.contains("\"isFinal\":false"))
    }

    func testToolResultOmitsNilPayload() throws {
        let json = try WireCodec.encode(
            .toolResult(callId: "c1", ok: false, payload: nil, error: "user_cancelled")
        )
        XCTAssertFalse(json.contains("payload"))
        XCTAssertTrue(json.contains("\"error\":\"user_cancelled\""))
    }

    func testServerEventsDecode() throws {
        let ready = try WireCodec.decodeEvent(
            #"{"type":"ready","sessionId":"s1","protocolVersion":1,"model":"llama3.2"}"#
        )
        XCTAssertEqual(
            ready,
            .ready(
                sessionId: "s1",
                protocolVersion: 1,
                model: "llama3.2",
                capabilities: Capabilities(),
                resumed: false
            )
        )

        let token = try WireCodec.decodeEvent(#"{"type":"token","utteranceId":"u1","text":"hi"}"#)
        XCTAssertEqual(token, .token(utteranceId: "u1", text: "hi"))
    }

    /// A v0.1 server sends neither field; the client must still connect.
    func testReadyWithoutCapabilitiesFallsBackToConservativeDefaults() throws {
        let event = try WireCodec.decodeEvent(
            #"{"type":"ready","sessionId":"s1","protocolVersion":1,"model":"m"}"#
        )
        guard case let .ready(_, _, _, capabilities, resumed) = event else {
            return XCTFail("expected ready")
        }
        XCTAssertFalse(resumed)
        XCTAssertFalse(capabilities.ambientEvents)
        XCTAssertEqual(capabilities.toolExecution, .client)
    }

    func testReadyDecodesCapabilities() throws {
        let event = try WireCodec.decodeEvent(
            #"{"type":"ready","sessionId":"s1","protocolVersion":1,"model":"m","resumed":true,"capabilities":{"ambientEvents":true,"toolExecution":"server","requestPlace":true,"speechInput":false,"idleTimeoutSeconds":30}}"#
        )
        guard case let .ready(_, _, _, capabilities, resumed) = event else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(resumed)
        XCTAssertEqual(capabilities.toolExecution, .server)
        XCTAssertEqual(capabilities.idleTimeoutSeconds, 30)
    }

    func testAmbientEventDecodes() throws {
        let event = try WireCodec.decodeEvent(
            #"{"type":"ambientEvent","source":"sensor.doorbell","kind":"doorbell","interrupt":"now","text":"Someone is at the door."}"#
        )
        XCTAssertEqual(
            event,
            .ambientEvent(
                source: "sensor.doorbell", kind: .doorbell, interrupt: .now,
                text: "Someone is at the door."
            )
        )
    }

    func testRequestPlaceDecodes() throws {
        let event = try WireCodec.decodeEvent(
            #"{"type":"requestPlace","name":"kitchen","prompt":"Where's the kitchen?"}"#
        )
        XCTAssertEqual(event, .requestPlace(name: "kitchen", prompt: "Where's the kitchen?"))
    }

    /// Absent `executedBy` means the client executes, which is what a v0.1 server meant.
    func testToolCallDefaultsToClientExecution() throws {
        let event = try WireCodec.decodeEvent(
            #"{"type":"toolCall","callId":"c1","name":"set_lock","safety":"unsafe"}"#
        )
        guard case let .toolCall(_, _, _, _, executedBy) = event else {
            return XCTFail("expected toolCall")
        }
        XCTAssertEqual(executedBy, .client)
    }

    func testDirectiveDecodesSymbolicIntentOnly() throws {
        let event = try WireCodec.decodeEvent(
            #"{"type":"characterDirective","directive":{"kind":"walkTo","place":"kitchen"}}"#
        )
        guard case let .characterDirective(directive) = event else {
            return XCTFail("expected directive")
        }
        XCTAssertEqual(directive.kind, .walkTo)
        XCTAssertEqual(directive.place, "kitchen")
    }

    /// Forward compatibility: unknown types are ignored, not fatal (spec/03-protocol.md).
    func testUnknownEventTypeIsIgnoredNotFatal() throws {
        XCTAssertNil(try WireCodec.decodeEvent(#"{"type":"holographicConfetti","n":3}"#))
    }

    func testNewlineFraming() {
        var buffer = "{\"type\":\"pong\"}\n{\"type\":\"pong\"}\n{\"type\":\"po"
        let frames = WireCodec.frames(from: &buffer)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(buffer, "{\"type\":\"po")
    }

    func testDeviceStateRoundTrips() throws {
        let device = Device(
            id: "light.kitchen", name: "Kitchen", room: "Kitchen", kind: .light,
            state: ["on": .bool(true), "brightness": .number(80)], capabilities: ["on"]
        )
        let data = try WireCodec.encoder.encode(device)
        let decoded = try WireCodec.decoder.decode(Device.self, from: data)
        XCTAssertEqual(decoded.state?["brightness"]?.intValue, 80)
        XCTAssertEqual(decoded, device)
    }
}
