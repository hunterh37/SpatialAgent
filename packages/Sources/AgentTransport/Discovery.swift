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
        var found: [AgentEndpoint] = endpoints.filter(\.isManual)
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            // Resolution to an IP happens at connect time; NWEndpoint carries the service
            // reference and URLSession resolves `name.local`.
            found.append(
                AgentEndpoint(
                    name: name,
                    host: "\(name).local",
                    port: DiscoveryConstants.defaultPort
                )
            )
        }
        endpoints = found
        log.debug("discovery: \(found.count, privacy: .public) endpoint(s)")
    }
}
