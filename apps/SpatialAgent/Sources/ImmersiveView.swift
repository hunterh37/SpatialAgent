import AgentKit
import CharacterKit
import DesignSystem
import RealityKit
import SceneUnderstanding
import SwiftUI
import simd

/// The character in the room. Rendering and per-frame motion only — what the character
/// *does* is decided in `agentd` (docs/architecture.md §8).
///
/// The body is the procedural bird of spec 06: no asset, no animation library, one
/// `SceneEvents.Update` subscription driving every transform.
struct ImmersiveView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var session: AgentSession

    @State private var character = CharacterEntity()
    @State private var lastUpdate = CACurrentMediaTime()

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.addChild(character.root)
            content.add(root)

            // Nothing to load: the bird is generated from primitives at init (spec 06).
            placeCharacter()

            if let bubble = attachments.entity(for: "bubble") {
                // Anchored above the head and billboarded, so it is never occluded by the
                // character itself (spec/02-interaction.md).
                bubble.components.set(BillboardComponent())
                character.root.addChild(bubble)
                bubble.position = SIMD3(0, CharacterEntity.targetHeight + 0.18, 0)
            }

            session.bindCharacter(
                onDirective: { character.apply($0) },
                onSignal: { character.signal($0) }
            )

            // The inspector's selection, drawn where the record actually is.
            let highlight = ModelEntity(
                mesh: .generateSphere(radius: 0.06),
                materials: [UnlitMaterial(color: .cyan)]
            )
            highlight.isEnabled = false
            root.addChild(highlight)

            _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                if let position = model.highlightedRecord {
                    highlight.position = SIMD3(position.x, position.y + 0.06, position.z)
                    highlight.isEnabled = true
                } else {
                    highlight.isEnabled = false
                }
                let now = CACurrentMediaTime()
                let delta = Float(min(now - lastUpdate, 0.1))
                lastUpdate = now
                character.update(deltaTime: delta, userPosition: model.scene.userPosition)
                session.characterPosition = character.position
            }
        } attachments: {
            Attachment(id: "bubble") {
                if session.isStreaming || !session.currentReply.isEmpty {
                    SpeechBubble(text: session.currentReply, isStreaming: session.isStreaming)
                }
            }
        }
        .gesture(
            // Tapping the character is the v0.1 stand-in for gaze addressing.
            SpatialTapGesture().targetedToAnyEntity().onEnded { _ in session.addressed() }
        )
    }

    private func placeCharacter() {
        guard let mesh = model.scene.navMesh else {
            model.placementProblem = "I can't see the floor yet."
            return
        }
        guard
            let pose = Placement.initialPose(
                in: mesh,
                userPosition: model.scene.userPosition,
                userForward: model.scene.userForward,
                // Presence follows the map: perches and the user's usual place for this
                // hour beat the nearest legal floor point (spec/07-memory.md).
                map: session.places.map
            )
        else {
            // No valid point: say so rather than placing it badly.
            model.placementProblem = "There's no clear spot on the floor for me to stand."
            return
        }
        model.placementProblem = nil
        character.place(at: pose)
        session.characterPosition = pose.position
    }
}
