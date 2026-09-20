import AgentKit
import CharacterKit
import DesignSystem
import RealityKit
import SceneUnderstanding
import SpatialMemory
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
    /// Hand tracking runs its own ARKit session; the scene provider's session owns world and
    /// plane data and has a different lifetime (it survives leaving the immersive space).
    @State private var hands = HandTrackingSession()
    /// The grabbable blue landmark spheres, and which one a pinch currently owns.
    @State private var markers = LandmarkMarkers()
    @State private var dragging: String?
    @State private var dragStart: SIMD3<Float>?

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.addChild(character.root)
            root.addChild(markers.root)
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
                onSignal: { character.signal($0) },
                onMood: { character.note($0) }
            )

            // Palm debug marker: green where an offered palm was detected, which is also
            // exactly the point the bird flies to. One sphere, so "detection works" and
            // "it flies to the right place" are the same observation.
            let palmMarker = ModelEntity(
                mesh: .generateSphere(radius: 0.02),
                materials: [UnlitMaterial(color: .green)]
            )
            palmMarker.isEnabled = false
            root.addChild(palmMarker)

            // The inspector's selection, drawn where the record actually is.
            let highlight = ModelEntity(
                mesh: .generateSphere(radius: 0.06),
                materials: [UnlitMaterial(color: .cyan)]
            )
            highlight.isEnabled = false
            root.addChild(highlight)

            // Debug-only presence checks need the mesh the character is standing on.
            character.navMeshForAssertions = model.scene.navMesh

            _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                if let position = model.highlightedRecord {
                    highlight.position = SIMD3(position.x, position.y + 0.06, position.z)
                    highlight.isEnabled = true
                } else {
                    highlight.isEnabled = false
                }
                markers.sync(to: session.landmarks?.markers ?? [], dragging: dragging)
                let now = CACurrentMediaTime()
                let delta = Float(min(now - lastUpdate, 0.1))
                lastUpdate = now
                let palm = hands.update(deltaTime: delta)
                if let palm {
                    palmMarker.position = palm.landing
                    palmMarker.isEnabled = true
                } else {
                    palmMarker.isEnabled = false
                }
                character.offerPalm(palm)

                character.update(deltaTime: delta, userPosition: model.scene.userPosition)
                session.characterPosition = character.position
                // Presence: once the conversation has been over long enough, the bird walks
                // back to the taught home perch. The policy is `IdleReturn`; this only says
                // when to ask.
                session.tickIdle()
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
            SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                guard markers.presetId(for: value.entity) == nil else { return }
                session.addressed()
            }
        )
        // Grab a landmark sphere and move it. The map is written once, on release: a drag
        // is one correction, not sixty anchor writes.
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    guard let id = markers.presetId(for: value.entity) else { return }
                    if dragging != id {
                        dragging = id
                        dragStart = markers.position(of: id)
                    }
                    guard let start = dragStart else { return }
                    let translation = value.convert(
                        value.translation3D, from: .local, to: .scene
                    )
                    markers.setPosition(start + SIMD3<Float>(translation), for: id)
                }
                .onEnded { value in
                    guard
                        let id = dragging,
                        let preset = LandmarkPreset.preset(id: id),
                        let point = markers.position(of: id)
                    else { return }
                    _ = value
                    dragging = nil
                    dragStart = nil
                    Task { await session.landmarks?.move(preset, to: point) }
                }
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
