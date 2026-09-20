import AgentProtocol
import Foundation

/// The confirmation flow (spec/02-interaction.md, spec/04-home.md).
///
/// Three properties are requirements, not settings:
///   1. `unsafe` never executes without an explicit tap. Binary success criterion (PRD §6).
///   2. Default is Cancel; timeout cancels.
///   3. There is no bypass — no phrase, no setting, no "trust this agent" toggle. Note the
///      absence of any `skip`/`alwaysAllow` parameter below; that absence is the mechanism.
public struct PendingConfirmation: Identifiable, Equatable, Sendable {
    public let id: String          // the toolCall id
    public let toolName: String
    public let deviceName: String
    /// The action in plain language, e.g. "Unlock the Front Door".
    public let summary: String
    public let expiresAt: Date

    public init(
        id: String,
        toolName: String,
        deviceName: String,
        summary: String,
        expiresAt: Date
    ) {
        self.id = id
        self.toolName = toolName
        self.deviceName = deviceName
        self.summary = summary
        self.expiresAt = expiresAt
    }
}

public enum ConfirmationOutcome: Equatable, Sendable {
    case confirmed
    case cancelled
    case timedOut
}

@MainActor
public final class ConfirmationGate: ObservableObject {
    /// Modal to the action, not to the app — the user can keep talking while this stands.
    @Published public private(set) var pending: [PendingConfirmation] = []

    public static let timeout: TimeInterval = 30

    private var continuations: [String: CheckedContinuation<ConfirmationOutcome, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Returns only after the user decides or the window closes. The caller must not send a
    /// `toolResult` for an `unsafe` call before this returns `.confirmed`.
    public func request(
        callId: String,
        toolName: String,
        deviceName: String,
        summary: String
    ) async -> ConfirmationOutcome {
        let confirmation = PendingConfirmation(
            id: callId,
            toolName: toolName,
            deviceName: deviceName,
            summary: summary,
            expiresAt: Date().addingTimeInterval(Self.timeout)
        )
        pending.append(confirmation)

        timers[callId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finish(callId, with: .timedOut)
        }

        return await withCheckedContinuation { continuation in
            continuations[callId] = continuation
        }
    }

    public func confirm(_ callId: String) { finish(callId, with: .confirmed) }
    public func cancel(_ callId: String) { finish(callId, with: .cancelled) }

    private func finish(_ callId: String, with outcome: ConfirmationOutcome) {
        timers[callId]?.cancel()
        timers[callId] = nil
        pending.removeAll { $0.id == callId }
        continuations.removeValue(forKey: callId)?.resume(returning: outcome)
    }

    /// Plain-language rendering of the pending action. Never the raw tool name or args —
    /// the user is being asked to authorise a physical event, not to read a function call.
    public static func summarize(tool: String, args: JSONObject?, device: Device?) -> String {
        let name = device?.name ?? args?["device_id"]?.stringValue ?? "that device"
        switch tool {
        case "set_lock":
            let locked = args?["locked"]?.boolValue ?? true
            return "\(locked ? "Lock" : "Unlock") the \(name)"
        case "set_garage":
            let open = args?["open"]?.boolValue ?? false
            return "\(open ? "Open" : "Close") the \(name)"
        case "set_alarm":
            let armed = args?["armed"]?.boolValue ?? false
            return "\(armed ? "Arm" : "Disarm") the \(name)"
        case "open_cover":
            return "Open the \(name)"
        default:
            return "\(tool.replacingOccurrences(of: "_", with: " ").capitalized) — \(name)"
        }
    }
}
