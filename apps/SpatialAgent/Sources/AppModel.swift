import AgentKit
import AgentTransport
import HomeBridge
import Observation
import SceneUnderstanding
import SwiftUI

/// App-level wiring: which concrete collaborators the packages get, and the immersive-space
/// lifecycle. No behaviour.
@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceId = "room"

    enum SpacePhase { case closed, opening, open }

    var spacePhase: SpacePhase = .closed
    /// Set when placement finds no valid floor point. The app says so rather than placing
    /// the character badly (spec/05-scene.md).
    var placementProblem: String?
    /// Position of the taught record selected in the map inspector, highlighted in the room
    /// so "which desk did I call that" is answerable by looking (spec/07-memory.md
    /// §Inspection).
    var highlightedRecord: SIMD3<Float>?

    let discovery = AgentDiscovery()
    let session: AgentSession
    /// Seeds the demo room and replays chip scripts when no Mac is attached.
    let demo: DemoDirector
    let home: RemoteHomeProvider
    let scene: any SceneProviding

    init() {
        let home = RemoteHomeProvider()
        self.home = home
        session = AgentSession(home: home)
        demo = DemoDirector(session: session)
        #if targetEnvironment(simulator)
        // The simulator has no plane detection; the fixture room keeps the loop runnable
        // there and mirrors mocks/scenarios/apartment.yaml.
        scene = FixtureSceneProvider.apartment()
        #else
        scene = ARKitSceneProvider()
        #endif
        session.attach(scene: scene)
    }

    func start() async {
        discovery.start()
        #if targetEnvironment(simulator)
        connectToFirstAvailable()
        #endif
        await scene.start()
    }

    func connectToFirstAvailable() {
        guard let endpoint = discovery.endpoints.first else { return }
        session.connect(to: endpoint)
    }
}
