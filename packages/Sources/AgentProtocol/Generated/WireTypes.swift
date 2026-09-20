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

/// Who fulfils an approved tool call. `.server` means this client only approves and must
/// never report having acted itself (docs/middle-layer-todo.md §1).
public enum Executor: String, Codable, Hashable, Sendable {
    case client
    case server
}

public enum AmbientKind: String, Codable, Hashable, Sendable {
    case doorbell, finished, sensor, stateChange
}

/// Server-asserted and coarse. The client owns the rendering, not the urgency.
public enum AmbientInterrupt: String, Codable, Hashable, Sendable {
    case now        // interrupt the conversation; go to the source
    case passing    // wait for the next idle
    case silent     // update state, say nothing
}

/// What the server can actually do, so the client never discovers it by failure.
public struct Capabilities: Codable, Hashable, Sendable {
    public var ambientEvents: Bool
    public var toolExecution: Executor
    public var requestPlace: Bool
    public var speechInput: Bool
    /// Upper bound on silence; send `ping` inside it.
    public var idleTimeoutSeconds: Double

    public init(
        ambientEvents: Bool = false,
        toolExecution: Executor = .client,
        requestPlace: Bool = false,
        speechInput: Bool = false,
        idleTimeoutSeconds: Double = 30
    ) {
        self.ambientEvents = ambientEvents
        self.toolExecution = toolExecution
        self.requestPlace = requestPlace
        self.speechInput = speechInput
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }
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
    /// `sessionId` resumes the session named by a previous `ready`; nil starts a new one.
    case hello(protocolVersion: Int, client: String, sessionId: String?)
    /// `isFinal: false` is a partial speech transcript: the character may react, the model waits.
    case userUtterance(id: String, text: String, isFinal: Bool)
    case sceneUpdate(scene: SceneSnapshot)
    case deviceStates(devices: [Device])
    case toolResult(callId: String, ok: Bool, payload: JSONObject?, error: String?)
    /// Answers a server-executed call. Approval only — this client did not act.
    case confirmationResult(callId: String, approved: Bool)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, client, sessionId, id, text, isFinal, scene, devices
        case callId, ok, payload, error, approved
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(version, client, sessionId):
            try c.encode("hello", forKey: .type)
            try c.encode(version, forKey: .protocolVersion)
            try c.encode(client, forKey: .client)
            try c.encodeIfPresent(sessionId, forKey: .sessionId)
        case let .userUtterance(id, text, isFinal):
            try c.encode("userUtterance", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(isFinal, forKey: .isFinal)
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
        case let .confirmationResult(callId, approved):
            try c.encode("confirmationResult", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(approved, forKey: .approved)
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
                client: try c.decode(String.self, forKey: .client),
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId)
            )
        case "userUtterance":
            self = .userUtterance(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                isFinal: try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
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
        case "confirmationResult":
            self = .confirmationResult(
                callId: try c.decode(String.self, forKey: .callId),
                approved: try c.decode(Bool.self, forKey: .approved)
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
    case ready(sessionId: String, protocolVersion: Int, model: String, capabilities: Capabilities, resumed: Bool)
    case token(utteranceId: String, text: String)
    case utteranceEnd(utteranceId: String)
    case characterDirective(CharacterDirective)
    case toolCall(callId: String, name: String, args: JSONObject?, safety: Safety, executedBy: Executor)
    /// The home speaking first (PRD §4).
    case ambientEvent(source: String, kind: AmbientKind, interrupt: AmbientInterrupt, text: String)
    /// The agent needs a place it does not have; ask the user in character.
    case requestPlace(name: String, prompt: String)
    case error(code: String, message: String)
    case pong

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, protocolVersion, model, capabilities, resumed, utteranceId, text
        case directive, callId, name, args, safety, executedBy, code, message
        case source, kind, interrupt, prompt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ready(sessionId, version, model, capabilities, resumed):
            try c.encode("ready", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(version, forKey: .protocolVersion)
            try c.encode(model, forKey: .model)
            try c.encode(capabilities, forKey: .capabilities)
            try c.encode(resumed, forKey: .resumed)
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
        case let .toolCall(callId, name, args, safety, executedBy):
            try c.encode("toolCall", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(args, forKey: .args)
            try c.encode(safety, forKey: .safety)
            try c.encode(executedBy, forKey: .executedBy)
        case let .ambientEvent(source, kind, interrupt, text):
            try c.encode("ambientEvent", forKey: .type)
            try c.encode(source, forKey: .source)
            try c.encode(kind, forKey: .kind)
            try c.encode(interrupt, forKey: .interrupt)
            try c.encode(text, forKey: .text)
        case let .requestPlace(name, prompt):
            try c.encode("requestPlace", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(prompt, forKey: .prompt)
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
                model: try c.decode(String.self, forKey: .model),
                capabilities: try c.decodeIfPresent(Capabilities.self, forKey: .capabilities)
                    ?? Capabilities(),
                resumed: try c.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
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
                safety: try c.decode(Safety.self, forKey: .safety),
                executedBy: try c.decodeIfPresent(Executor.self, forKey: .executedBy) ?? .client
            )
        case "ambientEvent":
            self = .ambientEvent(
                source: try c.decode(String.self, forKey: .source),
                kind: try c.decode(AmbientKind.self, forKey: .kind),
                interrupt: try c.decode(AmbientInterrupt.self, forKey: .interrupt),
                text: try c.decode(String.self, forKey: .text)
            )
        case "requestPlace":
            self = .requestPlace(
                name: try c.decode(String.self, forKey: .name),
                prompt: try c.decode(String.self, forKey: .prompt)
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
