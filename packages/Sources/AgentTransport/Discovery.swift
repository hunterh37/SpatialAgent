import Foundation
import Network
import os

/// Bonjour discovery of `agentd` on the LAN (docs/architecture.md §2b).
///
/// Vision Pro cannot reach `localhost`; the Mac is a separate host. Hardcoding an IP is the
/// documented way to lose an evening, so the default path is mDNS with a manual override
/// retained for conference Wi-Fi where mDNS is blocked.
///
/// Info.plist requirements, or browsing silently returns nothing:
///   NSLocalNetworkUsageDescription, NSBonjourServices = ["_spatialagent._tcp"],
///   NSAppTransportSecurity.NSAllowsLocalNetworking = true
public struct AgentEndpoint: Hashable, Sendable, Identifiable {
    public var id: String { "\(host):\(port)" }
    public var name: String
    public var host: String
    public var port: Int
    public var isManual: Bool

    public init(name: String, host: String, port: Int, isManual: Bool = false) {
        self.name = name
        self.host = host
        self.port = port
        self.isManual = isManual
    }

    /// `agentd` serves the socket at `/agent` (services/agentd/agentd/server.py).
    public var webSocketURL: URL? {
        URL(string: "ws://\(host):\(port)/agent")
    }

    public var healthURL: URL? {
        URL(string: "http://\(host):\(port)/health")
    }
}

public enum DiscoveryConstants {
    public static let serviceType = "_spatialagent._tcp"
    public static let defaultPort = 8787
}

@MainActor
public final class AgentDiscovery: ObservableObject {
    @Published public private(set) var endpoints: [AgentEndpoint] = []
    @Published public private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private let log = Logger(subsystem: "io.medvr.SpatialAgent", category: "discovery")

    public init() {}

    public func start() {
        // The simulator runs on the Mac, so `agentd` on localhost is reachable there and is
        // the fastest path to a live loop before a headset is on the network.
        #if targetEnvironment(simulator)
        _ = addManual(host: "127.0.0.1")
        #endif
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: DiscoveryConstants.serviceType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true
                case .failed, .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    public func stop() {
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    /// Manual fallback for networks where mDNS is blocked. Keep this reachable in the UI;
    /// a demo network will eventually need it.
    public func addManual(host: String, port: Int = DiscoveryConstants.defaultPort) -> AgentEndpoint {
        let endpoint = AgentEndpoint(name: "Manual", host: host, port: port, isManual: true)
        if !endpoints.contains(endpoint) { endpoints.insert(endpoint, at: 0) }
        return endpoint
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        // `.local` + the compiled-in default port is a guess: agentd may run on any port and
        // the hostname is not always resolvable on the headset. Resolve each result to a real
        // host and port instead, or a service shows up in the UI and never answers.
        let manual = endpoints.filter(\.isManual)
        var named: [String: NWBrowser.Result] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            named[name] = result
        }
        endpoints = manual + endpoints.filter { !$0.isManual && named[$0.name] != nil }
        for (name, result) in named where !endpoints.contains(where: { $0.name == name }) {
            resolve(name: name, endpoint: result.endpoint)
        }
        log.debug("discovery: \(self.endpoints.count, privacy: .public) endpoint(s)")
    }

    /// Bonjour gives a service reference; a connection gives the address and port behind it.
    /// The connection is opened only to read `currentPath`, then cancelled.
    private func resolve(name: String, endpoint: NWEndpoint) {
        guard resolvers[name] == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let connection = NWConnection(to: endpoint, using: params)
        resolvers[name] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint
                connection.cancel()
                guard case let .hostPort(host, port)? = remote else { return }
                let address: String
                switch host {
                case let .ipv4(v4): address = "\(v4)".split(separator: "%").first.map(String.init) ?? "\(v4)"
                case let .ipv6(v6): address = "[\("\(v6)".split(separator: "%").first.map(String.init) ?? "\(v6)")]"
                case let .name(n, _): address = n
                @unknown default: return
                }
                Task { @MainActor in
                    self?.resolvers[name] = nil
                    self?.add(AgentEndpoint(name: name, host: address, port: Int(port.rawValue)))
                }
            case .failed, .cancelled:
                connection.cancel()
                Task { @MainActor in self?.resolvers[name] = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func add(_ endpoint: AgentEndpoint) {
        guard !endpoints.contains(where: { $0.id == endpoint.id }) else { return }
        endpoints.append(endpoint)
        log.debug("resolved \(endpoint.id, privacy: .public)")
    }
}
