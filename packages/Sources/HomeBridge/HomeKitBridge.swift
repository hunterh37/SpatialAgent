import AgentProtocol
import Foundation

#if canImport(HomeKit) && !os(visionOS)
import HomeKit

/// Real HomeKit execution.
///
/// **This does not build on visionOS.** The HomeKit framework is not part of the visionOS
/// SDK, so the plan in docs/architecture.md §5 — "execution can run either on-device via
/// HomeKit or on the Mac, on-device is simpler because HomeKit authorization already lives
/// with the user's session" — does not survive contact with the platform. The fallback is
/// `RemoteHomeProvider`: execution moves to the Mac companion, which *can* link HomeKit, and
/// the headset holds only the confirmation gate. See docs/middle-layer-todo.md §1.
///
/// This file is kept compiled-out rather than deleted because the macOS companion target
/// uses exactly this code path.
@MainActor
public final class HomeKitBridge: NSObject, HomeProviding {
    public private(set) var devices: [Device] = []
    public var onDeviceChanged: ((Device) -> Void)?

    private let manager = HMHomeManager()

    public func refresh() async throws {
        guard let home = manager.primaryHome else { throw HomeError.notAuthorized }
        devices = home.accessories.flatMap { accessory in
            accessory.services.compactMap { service -> Device? in
                guard let kind = Self.kind(for: service.serviceType) else { return nil }
                return Device(
                    id: service.uniqueIdentifier.uuidString,
                    name: service.name,
                    room: accessory.room?.name,
                    kind: kind,
                    capabilities: service.characteristics.map(\.characteristicType)
                )
            }
        }
    }

    /// Real execution against HomeKit characteristics.
    ///
    /// The tool surface is the abstract one from spec/04-home.md; the mapping from a tool to
    /// a characteristic type lives here and nowhere else, so adding Matter or a hub later is
    /// a second `HomeProviding` rather than a change to the agent loop.
    public func execute(tool: String, args: JSONObject?) async throws -> JSONObject {
        switch tool {
        case "list_devices":
            try await refresh()
            return ["devices": .array(devices.map { .string($0.id) })]

        case "get_device_state":
            let id = args?["device_id"]?.stringValue ?? ""
            guard let service = service(id: id) else { throw HomeError.unknownDevice(id) }
            return try await readState(of: service)

        case "set_light":
            let id = args?["device_id"]?.stringValue ?? ""
            guard let service = service(id: id) else { throw HomeError.unknownDevice(id) }
            if let on = args?["on"]?.boolValue {
                try await write(on, to: service, type: HMCharacteristicTypePowerState)
            }
            if let brightness = args?["brightness"]?.doubleValue {
                try await write(
                    Int(brightness.rounded()),
                    to: service,
                    type: HMCharacteristicTypeBrightness
                )
            }
            return try await readState(of: service)

        case "set_lock":
            let id = args?["device_id"]?.stringValue ?? ""
            guard let service = service(id: id) else { throw HomeError.unknownDevice(id) }
            guard let locked = args?["locked"]?.boolValue else {
                throw HomeError.unsupportedCapability(device: id, capability: "lock")
            }
            // Unsafe by the table in spec/04-home.md: by the time it reaches here the user
            // has already confirmed on the headset. The Mac executes; it does not decide.
            try await write(
                locked ? 1 : 0,
                to: service,
                type: HMCharacteristicTypeTargetLockMechanismState
            )
            return try await readState(of: service)

        default:
            throw HomeError.unknownTool(tool)
        }
    }

    private func service(id: String) -> HMService? {
        guard let home = manager.primaryHome else { return nil }
        for accessory in home.accessories {
            for service in accessory.services where service.uniqueIdentifier.uuidString == id {
                return service
            }
        }
        return nil
    }

    private func write(_ value: Any, to service: HMService, type: String) async throws {
        guard let characteristic = service.characteristics.first(
            where: { $0.characteristicType == type }
        ) else {
            throw HomeError.unsupportedCapability(device: service.name, capability: type)
        }
        try await characteristic.writeValue(value)
    }

    private func readState(of service: HMService) async throws -> JSONObject {
        var state = JSONObject()
        for characteristic in service.characteristics {
            try? await characteristic.readValue()
            switch characteristic.characteristicType {
            case HMCharacteristicTypePowerState:
                state["on"] = .bool(characteristic.value as? Bool ?? false)
            case HMCharacteristicTypeBrightness:
                state["brightness"] = .number(Double(characteristic.value as? Int ?? 0))
            case HMCharacteristicTypeCurrentLockMechanismState,
                 HMCharacteristicTypeTargetLockMechanismState:
                state["locked"] = .bool((characteristic.value as? Int ?? 0) == 1)
            default:
                continue
            }
        }
        return state
    }

    private static func kind(for serviceType: String) -> DeviceKind? {
        switch serviceType {
        case HMServiceTypeLightbulb: return .light
        case HMServiceTypeLockMechanism: return .lock
        case HMServiceTypeThermostat: return .thermostat
        case HMServiceTypeWindowCovering, HMServiceTypeGarageDoorOpener: return .cover
        default: return nil
        }
    }
}
#endif

/// Execution delegated to the Mac companion over the existing socket.
///
/// This is the visionOS path, forced by HomeKit's absence from the visionOS SDK. It changes
/// the trust story and that change is deliberate and bounded: the *decision* to act still
/// requires a confirmation the headset renders and the user taps, and the headset refuses to
/// forward an `unsafe` call that has not been confirmed. The Mac executes; it does not decide.
@MainActor
public final class RemoteHomeProvider: HomeProviding {
    public private(set) var devices: [Device] = []
    public var onDeviceChanged: ((Device) -> Void)?

    public init() {}

    /// Set by the connection layer when the Mac pushes its device snapshot.
    public func ingest(_ devices: [Device]) {
        let changed = devices.filter { new in
            guard let old = self.devices.first(where: { $0.id == new.id }) else { return true }
            return old != new
        }
        self.devices = devices
        changed.forEach { onDeviceChanged?($0) }
    }

    public func refresh() async throws {}

    public func execute(tool: String, args: JSONObject?) async throws -> JSONObject {
        // The headset does not execute. It returns the call to the caller, which forwards a
        // `toolResult` only after the Mac reports back.
        throw HomeError.unavailableOnPlatform(
            "HomeKit is unavailable on visionOS; execution belongs to the Mac companion."
        )
    }
}

/// In-memory home, mirroring `services/agentd/mocks/mock_home.py` so the same tool surface
/// and the same fixtures exercise both halves of the project.
@MainActor
public final class MockHomeProvider: HomeProviding {
    public private(set) var devices: [Device]
    public var onDeviceChanged: ((Device) -> Void)?

    public init(devices: [Device] = MockHomeProvider.apartment()) {
        self.devices = devices
    }

    public nonisolated static func apartment() -> [Device] {
        [
            Device(id: "light.kitchen", name: "Kitchen Ceiling", room: "Kitchen", kind: .light,
                   state: ["on": .bool(true), "brightness": .number(80)],
                   capabilities: ["on", "brightness"]),
            Device(id: "light.desk", name: "Desk Lamp", room: "Study", kind: .light,
                   state: ["on": .bool(false)], capabilities: ["on"]),
            Device(id: "lock.front", name: "Front Door", room: "Entry", kind: .lock,
                   state: ["locked": .bool(true)], capabilities: ["locked"]),
        ]
    }

    public func refresh() async throws {}

    public func execute(tool: String, args: JSONObject?) async throws -> JSONObject {
        switch tool {
        case "list_devices":
            return ["devices": .array(devices.map { .string($0.id) })]

        case "get_device_state":
            let device = try require(args?["device_id"]?.stringValue)
            return device.state ?? JSONObject()

        case "set_light":
            var device = try require(args?["device_id"]?.stringValue)
            guard device.kind == .light else {
                throw HomeError.unsupportedCapability(device: device.name, capability: "light")
            }
            var state = device.state ?? JSONObject()
            if let on = args?["on"]?.boolValue { state["on"] = .bool(on) }
            if let brightness = args?["brightness"]?.doubleValue {
                state["brightness"] = .number(brightness)
            }
            device.state = state
            replace(device)
            return state

        case "set_lock":
            var device = try require(args?["device_id"]?.stringValue)
            guard device.kind == .lock else {
                throw HomeError.unsupportedCapability(device: device.name, capability: "lock")
            }
            var state = device.state ?? JSONObject()
            state["locked"] = .bool(args?["locked"]?.boolValue ?? true)
            device.state = state
            replace(device)
            return state

        default:
            throw HomeError.unknownTool(tool)
        }
    }

    private func require(_ id: String?) throws -> Device {
        guard let id, let device = devices.first(where: { $0.id == id }) else {
            throw HomeError.unknownDevice(id ?? "")
        }
        return device
    }

    private func replace(_ device: Device) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        onDeviceChanged?(device)
    }
}
