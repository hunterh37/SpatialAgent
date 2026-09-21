import AgentKit
import SwiftUI

/// Entry point only. `apps/` contains no logic (docs/architecture.md §1) — every behaviour
/// below lives in a package with its own tests and runs without a headset.
@main
struct SpatialAgentApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "control") {
            ContentView()
                .environment(model)
                .environmentObject(model.session)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)

        ImmersiveSpace(id: AppModel.immersiveSpaceId) {
            ImmersiveView()
                .environment(model)
                .environmentObject(model.session)
        }
        // Mixed, not full: the character stands on the user's real floor, in passthrough.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
