import AgentProtocol
import Foundation
import os

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected(sessionId: String, model: String)
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool { if case .connected = self { return true }; return false }
}

/// Transport-level contract, so `AgentKit` can be exercised without a socket
/// (docs/architecture.md §8: if a behavior cannot be exercised by `fake_headset.py`,
/// it is in the wrong place — the Swift mirror of that rule is this protocol).
public protocol AgentChannel: AnyObject, Sendable {
    var events: AsyncStream<ServerEvent> { get }
    func connect(to endpoint: AgentEndpoint) async
    func send(_ message: ClientMessage) async
    func disconnect() async
}

/// One persistent WebSocket, multiplexed by `type`, newline-delimited JSON.
///
/// Reconnect uses exponential backoff. Conversation state lives on the Mac
/// (docs/architecture.md §8), so a reconnect resumes rather than restarts: the client
/// replays `hello`, the scene snapshot and the device snapshot, nothing else.
public actor WebSocketAgentChannel: AgentChannel {
    public nonisolated let events: AsyncStream<ServerEvent>
    private let continuation: AsyncStream<ServerEvent>.Continuation

    private var task: URLSessionWebSocketTask?
    private var endpoint: AgentEndpoint?
    private var attempt = 0
    /// Offered back in the next `hello` so the server resumes rather than restarts.
    private var lastSessionId: String?
    private var shouldReconnect = true
    private var recorder: SessionRecorder?

    private let session: URLSession
    private let log = Logger(subsystem: "io.medvr.SpatialAgent", category: "transport")

    /// Backoff schedule in seconds, clamped at the last value.
    private let backoff: [Double] = [0.25, 0.5, 1, 2, 4, 8]

    public init(recorder: SessionRecorder? = nil) {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        self.recorder = recorder
        var cont: AsyncStream<ServerEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func connect(to endpoint: AgentEndpoint) async {
        self.endpoint = endpoint
        shouldReconnect = true
        await openSocket()
    }

    public func disconnect() async {
        shouldReconnect = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func send(_ message: ClientMessage) async {
        guard let task else { return }
        do {
            let line = try WireCodec.encode(message) + "\n"
            recorder?.record(outbound: line)
            try await task.send(.string(line))
        } catch {
            log.error("send failed: \(String(describing: error), privacy: .public)")
            await scheduleReconnect()
        }
    }

    private func openSocket() async {
        guard let url = endpoint?.webSocketURL else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // `hello` is always the first frame. A version mismatch closes the socket with a
        // stated reason rather than failing obscurely later (spec/03-protocol.md).
        // The last session id is offered back so a sleep/wake resumes the conversation on
        // the server rather than silently restarting it (spec/03-protocol.md).
        await send(
            .hello(
                protocolVersion: Wire.protocolVersion,
                client: clientDescription(),
                sessionId: lastSessionId
            )
        )
        Task { await receiveLoop(task) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        var buffer = ""
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case let .string(s): text = s
                case let .data(d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                buffer += text
                // agentd sends one JSON object per frame; the newline split also covers a
                // server that batches frames into a single message.
                var frames = WireCodec.frames(from: &buffer)
                if frames.isEmpty, !buffer.isEmpty {
                    frames = [buffer]
                    buffer = ""
                }
                for frame in frames { handle(frame) }
            } catch {
                log.error("receive failed: \(String(describing: error), privacy: .public)")
                await scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ frame: String) {
        recorder?.record(inbound: frame)
        do {
            // Unknown types decode to nil and are dropped, not fatal.
            guard let event = try WireCodec.decodeEvent(frame) else {
                log.debug("ignored unknown event")
                return
            }
            if case let .ready(sessionId, _, _, _, _) = event {
                attempt = 0
                lastSessionId = sessionId
            }
            continuation.yield(event)
        } catch {
            log.error("undecodable frame dropped: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleReconnect() async {
        guard shouldReconnect, let endpoint else { return }
        task = nil
        let delay = backoff[min(attempt, backoff.count - 1)]
        attempt += 1
        continuation.yield(
            .error(
                code: "disconnected",
                // Spoken in character, not shown as a dialog (spec/02-interaction.md).
                message: "I can't reach the Mac right now."
            )
        )
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard shouldReconnect else { return }
        self.endpoint = endpoint
        await openSocket()
    }

    private nonisolated func clientDescription() -> String {
        #if os(visionOS)
        return "visionOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "swift"
        #endif
    }
}
