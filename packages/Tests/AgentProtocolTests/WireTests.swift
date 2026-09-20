import XCTest
@testable import AgentProtocol

final class WireTests: XCTestCase {
    /// The schema is the source of truth. Until `make protocol` generates this file, the
    /// contract is held by asserting the encoded field names against the schema's own
    /// spelling. A rename on either side fails here rather than on a headset.
    func testHelloEncodesSchemaFieldNames() throws {
        let json = try WireCodec.encode(
            .hello(protocolVersion: Wire.protocolVersion, client: "visionOS")
        )
        XCTAssertTrue(json.contains("\"type\":\"hello\""))
        XCTAssertTrue(json.contains("\"protocolVersion\":1"))
        XCTAssertTrue(json.contains("\"client\":\"visionOS\""))
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
        XCTAssertEqual(ready, .ready(sessionId: "s1", protocolVersion: 1, model: "llama3.2"))

        let token = try WireCodec.decodeEvent(#"{"type":"token","utteranceId":"u1","text":"hi"}"#)
        XCTAssertEqual(token, .token(utteranceId: "u1", text: "hi"))
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
