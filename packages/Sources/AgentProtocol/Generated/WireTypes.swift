// Mirrors packages/AgentProtocol/schema/protocol.schema.json.
//
// The schema is the source of truth (docs/architecture.md §3a). Until `make protocol`
// exists, this file is the hand-maintained Swift half and `AgentProtocolTests` asserts
// field-name parity against the schema so drift fails in CI rather than on a headset.
//
// Pure Swift only. No RealityKit, no ARKit, no SwiftUI, no third-party dependencies.

import Foundation

public enum Wire {
    public static let protocolVersion = 1
}

// MARK: - Geometry

public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct NamedPlace: Codable, Hashable, Sendable {
    public var name: String
    public var position: Vec3
    public var radius: Double

    public init(name: String, position: Vec3, radius: Double) {
        self.name = name
        self.position = position
        self.radius = max(0.1, radius)
    }
}

public struct SceneSnapshot: Codable, Hashable, Sendable {
    public var places: [NamedPlace]
    public var floorArea: Double?
    public var userPosition: Vec3?

    public init(places: [NamedPlace], floorArea: Double? = nil, userPosition: Vec3? = nil) {
        self.places = places
        self.floorArea = floorArea
        self.userPosition = userPosition
    }
}

// MARK: - Home

public enum DeviceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case light, lock, thermostat, cover, sensor, scene, media, other
}

public struct Device: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var room: String?
    public var kind: DeviceKind
    public var state: JSONObject?
    public var capabilities: [String]?

    public init(
        id: String,
        name: String,
        room: String? = nil,
        kind: DeviceKind,
        state: JSONObject? = nil,
        capabilities: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.room = room
        self.kind = kind
        self.state = state
        self.capabilities = capabilities
    }
}

public enum Safety: String, Codable, Hashable, Sendable {
    case safe
    case unsafe
}

// MARK: - Character directives

public enum DirectiveKind: String, Codable, Hashable, Sendable {
    case walkTo, lookAt, point, emote, gesture, idle
}

public enum DirectiveTarget: String, Codable, Hashable, Sendable {
    case user, place, device
}

public enum Emotion: String, Codable, Hashable, Sendable {
    case neutral, confused, happy, concerned, thinking
}

/// Symbolic intent only. Never animation names, never raw coordinates (spec/01-character.md).
public struct CharacterDirective: Codable, Hashable, Sendable {
    public var kind: DirectiveKind
    public var place: String?
    public var target: DirectiveTarget?
    public var deviceId: String?
    public var emotion: Emotion?

    public init(
        kind: DirectiveKind,
        place: String? = nil,
        target: DirectiveTarget? = nil,
        deviceId: String? = nil,
        emotion: Emotion? = nil
    ) {
        self.kind = kind
        self.place = place
        self.target = target
        self.deviceId = deviceId
        self.emotion = emotion
    }
}

// MARK: - Client -> Server

public enum ClientMessage: Codable, Hashable, Sendable {
    case hello(protocolVersion: Int, client: String)
    case userUtterance(id: String, text: String)
    case sceneUpdate(scene: SceneSnapshot)
    case deviceStates(devices: [Device])
    case toolResult(callId: String, ok: Bool, payload: JSONObject?, error: String?)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, client, id, text, scene, devices, callId, ok, payload, error
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(version, client):
            try c.encode("hello", forKey: .type)
            try c.encode(version, forKey: .protocolVersion)
            try c.encode(client, forKey: .client)
        case let .userUtterance(id, text):
            try c.encode("userUtterance", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case let .sceneUpdate(scene):
            try c.encode("sceneUpdate", forKey: .type)
            try c.encode(scene, forKey: .scene)
        case let .deviceStates(devices):
            try c.encode("deviceStates", forKey: .type)
            try c.encode(devices, forKey: .devices)
        case let .toolResult(callId, ok, payload, error):
            try c.encode("toolResult", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(ok, forKey: .ok)
            try c.encodeIfPresent(payload, forKey: .payload)
            try c.encodeIfPresent(error, forKey: .error)
        case .ping:
            try c.encode("ping", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                client: try c.decode(String.self, forKey: .client)
            )
        case "userUtterance":
            self = .userUtterance(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text)
            )
        case "sceneUpdate":
            self = .sceneUpdate(scene: try c.decode(SceneSnapshot.self, forKey: .scene))
        case "deviceStates":
            self = .deviceStates(devices: try c.decode([Device].self, forKey: .devices))
        case "toolResult":
            self = .toolResult(
                callId: try c.decode(String.self, forKey: .callId),
                ok: try c.decode(Bool.self, forKey: .ok),
                payload: try c.decodeIfPresent(JSONObject.self, forKey: .payload),
                error: try c.decodeIfPresent(String.self, forKey: .error)
            )
        case "ping":
            self = .ping
        case let other:
            throw WireError.unknownMessageType(other)
        }
    }
}

// MARK: - Server -> Client

public enum ServerEvent: Codable, Hashable, Sendable {
    case ready(sessionId: String, protocolVersion: Int, model: String)
    case token(utteranceId: String, text: String)
    case utteranceEnd(utteranceId: String)
    case characterDirective(CharacterDirective)
    case toolCall(callId: String, name: String, args: JSONObject?, safety: Safety)
    case error(code: String, message: String)
    case pong

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, protocolVersion, model, utteranceId, text
        case directive, callId, name, args, safety, code, message
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ready(sessionId, version, model):
            try c.encode("ready", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(version, forKey: .protocolVersion)
            try c.encode(model, forKey: .model)
        case let .token(utteranceId, text):
            try c.encode("token", forKey: .type)
            try c.encode(utteranceId, forKey: .utteranceId)
            try c.encode(text, forKey: .text)
        case let .utteranceEnd(utteranceId):
            try c.encode("utteranceEnd", forKey: .type)
            try c.encode(utteranceId, forKey: .utteranceId)
        case let .characterDirective(directive):
            try c.encode("characterDirective", forKey: .type)
            try c.encode(directive, forKey: .directive)
        case let .toolCall(callId, name, args, safety):
            try c.encode("toolCall", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(args, forKey: .args)
            try c.encode(safety, forKey: .safety)
        case let .error(code, message):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        case .pong:
            try c.encode("pong", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "ready":
            self = .ready(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                model: try c.decode(String.self, forKey: .model)
            )
        case "token":
            self = .token(
                utteranceId: try c.decode(String.self, forKey: .utteranceId),
                text: try c.decode(String.self, forKey: .text)
            )
        case "utteranceEnd":
            self = .utteranceEnd(utteranceId: try c.decode(String.self, forKey: .utteranceId))
        case "characterDirective":
            self = .characterDirective(try c.decode(CharacterDirective.self, forKey: .directive))
        case "toolCall":
            self = .toolCall(
                callId: try c.decode(String.self, forKey: .callId),
                name: try c.decode(String.self, forKey: .name),
                args: try c.decodeIfPresent(JSONObject.self, forKey: .args),
                safety: try c.decode(Safety.self, forKey: .safety)
            )
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message)
            )
        case "pong":
            self = .pong
        case let other:
            throw WireError.unknownMessageType(other)
        }
    }
}

public enum WireError: Error, Equatable, Sendable {
    /// Unknown types are ignored by the reader, not fatal (spec/03-protocol.md).
    case unknownMessageType(String)
    case protocolVersionMismatch(local: Int, remote: Int)
}
