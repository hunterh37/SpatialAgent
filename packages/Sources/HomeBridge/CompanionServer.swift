import AgentProtocol
import Foundation
import Network

/// The loopback bridge the Mac companion serves and `agentd` calls.
///
/// HomeKit is not in the visionOS SDK and `HMHomeManager` needs a real user session, so home
/// execution lives in a small Mac app rather than in `agentd` itself (docs/architecture.md §5,
/// docs/middle-layer-todo.md §1). The seam between them is this: three HTTP endpoints on
/// 127.0.0.1, carrying the same abstract `Device` and the same tool names the rest of the
/// project uses.
///
/// Loopback only, and deliberately so. A home-control endpoint that answers on the LAN is a
/// home-control endpoint someone else on the LAN can use, and nothing here needs to leave the
/// machine: `agentd` runs on the same Mac.
@MainActor
public final class CompanionServer {
    /// Default port. Not 8787: that is `agentd`, and two listeners fighting over one port is
    /// a failure that looks like a bug in the model.
    public static let defaultPort: UInt16 = 8790

    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public var onStateChange: ((State) -> Void)?
    /// Every executed call, newest last. Shown in the companion's window so a user can see
    /// what the bird actually did to their home.
    public private(set) var log: [Entry] = []
    public var onLog: ((Entry) -> Void)?

    public struct Entry: Sendable, Hashable, Identifiable {
        public let id = UUID()
        public let at: Date
        public let tool: String
        public let deviceId: String?
        public let ok: Bool
        public let detail: String
    }

    private let home: any HomeProviding
    private var listener: NWListener?
    private let port: UInt16

    public init(home: any HomeProviding, port: UInt16 = CompanionServer.defaultPort) {
        self.home = home
        self.port = port
    }

    // MARK: Lifecycle

    public func start() {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.set(.listening(port: self.port))
                    case let .failed(error): self.set(.failed(error.localizedDescription))
                    case .cancelled: self.set(.stopped)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        set(.stopped)
    }

    private func set(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        onStateChange?(state)
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = await self.respond(to: request)
                connection.send(
                    content: response,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
    }

    /// Minimal HTTP/1.1. A full server would be a dependency; this speaks exactly the three
    /// requests `agentd` makes and refuses everything else.
    func respond(to request: String) async -> Data {
        let head = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = head.split(separator: " ")
        guard parts.count >= 2 else { return Self.http(status: "400 Bad Request", json: "{}") }
        let method = String(parts[0])
        let path = String(parts[1])
        let body = request.range(of: "\r\n\r\n").map { String(request[$0.upperBound...]) } ?? ""

        switch (method, path) {
        case ("GET", "/health"):
            return Self.http(status: "200 OK", json: #"{"ok":true}"#)

        case ("GET", "/devices"):
            try? await home.refresh()
            let payload = (try? JSONEncoder().encode(home.devices)) ?? Data("[]".utf8)
            return Self.http(
                status: "200 OK",
                json: String(data: payload, encoding: .utf8) ?? "[]"
            )

        case ("POST", "/execute"):
            return await execute(body: body)

        default:
            return Self.http(status: "404 Not Found", json: #"{"error":"no such endpoint"}"#)
        }
    }

    private func execute(body: String) async -> Data {
        struct Call: Decodable {
            var tool: String
            var args: JSONObject?
        }
        guard let data = body.data(using: .utf8),
              let call = try? JSONDecoder().decode(Call.self, from: data)
        else {
            return Self.http(status: "400 Bad Request", json: #"{"error":"bad call"}"#)
        }

        do {
            let payload = try await home.execute(tool: call.tool, args: call.args)
            note(call.tool, args: call.args, ok: true, detail: "ok")
            let encoded = (try? JSONEncoder().encode(["ok": true])) ?? Data()
            _ = encoded
            let result = Result(ok: true, payload: payload, error: nil)
            return Self.http(status: "200 OK", json: result.json)
        } catch {
            let message = (error as? HomeError)?.errorDescription ?? error.localizedDescription
            note(call.tool, args: call.args, ok: false, detail: message)
            return Self.http(
                status: "200 OK",
                json: Result(ok: false, payload: nil, error: message).json
            )
        }
    }

    private struct Result {
        var ok: Bool
        var payload: JSONObject?
        var error: String?

        var json: String {
            var object: JSONObject = ["ok": .bool(ok)]
            if let payload { object["payload"] = .object(payload) }
            if let error { object["error"] = .string(error) }
            let data = (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    private func note(_ tool: String, args: JSONObject?, ok: Bool, detail: String) {
        let entry = Entry(
            at: Date(),
            tool: tool,
            deviceId: args?["device_id"]?.stringValue,
            ok: ok,
            detail: detail
        )
        log.append(entry)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        onLog?(entry)
    }

    static func http(status: String, json: String) -> Data {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
