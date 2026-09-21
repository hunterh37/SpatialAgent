import HomeBridge
import SwiftUI

/// The Mac companion: the piece of the product that can actually touch HomeKit.
///
/// HomeKit is absent from the visionOS SDK (docs/middle-layer-todo.md §1), so the headset
/// holds the confirmation gate and this app holds the authorization and the execution. It is
/// deliberately tiny — a window that says what it is doing and a switch to stop it — because
/// everything it knows how to do already lives in `HomeBridge` and `agentd`.
@main
struct SpatialAgentHomeApp: App {
    @StateObject private var model = CompanionModel()

    var body: some Scene {
        WindowGroup("SpatialAgent Home") {
            CompanionView()
                .environmentObject(model)
                .frame(minWidth: 460, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var state: CompanionServer.State = .stopped
    @Published private(set) var devices: [String] = []
    @Published private(set) var log: [CompanionServer.Entry] = []
    @Published private(set) var homeKind: String

    private let home: any HomeProviding
    private let server: CompanionServer

    init() {
        // HomeKit where it exists, the shared mock everywhere else, so the companion is
        // runnable and demoable on a machine with no Home set up.
        #if canImport(HomeKit) && !os(visionOS)
        let provider: any HomeProviding = HomeKitBridge()
        homeKind = "HomeKit"
        #else
        let provider: any HomeProviding = MockHomeProvider()
        homeKind = "Mock home (HomeKit unavailable on this platform)"
        #endif
        home = provider
        server = CompanionServer(home: provider)

        server.onStateChange = { [weak self] state in self?.state = state }
        server.onLog = { [weak self] entry in self?.log.append(entry) }
    }

    func start() async {
        server.start()
        await refresh()
    }

    func stop() {
        server.stop()
    }

    func refresh() async {
        try? await home.refresh()
        devices = home.devices.map { "\($0.name) · \($0.kind.rawValue)" }
    }
}
