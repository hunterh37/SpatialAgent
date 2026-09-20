import AgentProtocol
import Foundation

/// `Device` is the abstract model (spec/04-home.md). `agentd` never sees a HomeKit type;
/// swapping in Matter or a hub touches this package only.
@MainActor
public protocol HomeProviding: AnyObject {
    var devices: [Device] { get }
    /// Published to `agentd` at connect time, so the model learns the home it is in at
    /// runtime rather than from a hardcoded prompt.
    func refresh() async throws
    func execute(tool: String, args: JSONObject?) async throws -> JSONObject
    /// Ambient home events (doorbell, appliance finished, sensor trip). Rate-limited and
    /// classified by interrupt level by the consumer.
    var onDeviceChanged: ((Device) -> Void)? { get set }
}

public enum HomeError: LocalizedError, Equatable {
    case unknownDevice(String)
    case unknownTool(String)
    case unsupportedCapability(device: String, capability: String)
    case notAuthorized
    case unavailableOnPlatform(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownDevice(id): return "No device with id \(id)."
        case let .unknownTool(name): return "No tool named \(name)."
        case let .unsupportedCapability(device, capability):
            return "\(device) can't do \(capability)."
        case .notAuthorized: return "Home access hasn't been granted."
        case let .unavailableOnPlatform(detail): return detail
        }
    }

    /// Failures are surfaced in character, with the device named (spec/04-home.md).
    public var spokenLine: String {
        switch self {
        case let .unknownDevice(id): return "I couldn't find \(id) in the house."
        case .unknownTool: return "I don't know how to do that yet."
        case let .unsupportedCapability(device, _): return "The \(device) doesn't support that."
        case .notAuthorized: return "I don't have permission to touch the home yet."
        case .unavailableOnPlatform: return "I can't reach the home from here."
        }
    }
}

/// Client-side safety table (spec/04-home.md).
///
/// The server also asserts a safety class on every `toolCall`, and the client enforces this
/// one **independently**: a compromised or hallucinating server cannot unlock a door by
/// claiming `"safety": "safe"`. Where the two disagree, the stricter wins.
public enum ToolSafety {
    private static let known: [String: Safety] = [
        "list_devices": .safe,
        "get_device_state": .safe,
        "set_light": .safe,
        "set_timer": .safe,
        "set_scene": .safe,
        "set_thermostat": .safe,
        "set_media": .safe,
        "set_lock": .unsafe,
        "set_garage": .unsafe,
        "set_alarm": .unsafe,
        "open_cover": .unsafe,
    ]

    /// Unknown tools are unsafe. Fail closed, matching `ToolRegistry.safety_of` on the server.
    public static func local(_ name: String) -> Safety { known[name] ?? .unsafe }

    /// The stricter of the two classifications. Never the server's alone.
    public static func effective(name: String, serverAsserted: Safety) -> Safety {
        (local(name) == .unsafe || serverAsserted == .unsafe) ? .unsafe : .safe
    }
}
