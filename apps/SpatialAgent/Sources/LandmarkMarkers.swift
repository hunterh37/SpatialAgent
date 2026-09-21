import RealityKit
import SwiftUI
import SceneUnderstanding
import SpatialMemory
import simd

/// The props you grab: one low-poly object per placed landmark, drawn in the immersive scene.
///
/// Rendering and gesture plumbing only. What each landmark looks like is `LandmarkProp`, and
/// where a dragged one ends up is written by `LandmarkPlacer.move`, so a drag and a spoken
/// correction land in the map identically (docs/architecture.md §1).
@MainActor
final class LandmarkMarkers {
    /// Name the drag gesture matches on, so grabbing the bird is never a landmark drag.
    static let componentName = "landmark"

    let root = Entity()
    /// The grabbable wrapper per preset id. The prop hangs underneath it, so swapping the
    /// prop never invalidates the gesture's hit entity.
    private var markers: [String: Entity] = [:]
    /// The prop style currently drawn, so a style change rebuilds and a move does not.
    private var styles: [String: PropStyle] = [:]
    /// The shape inputs the prop was built from. A perch's height and its knock-off bands
    /// are geometry, so a change to either has to rebuild the prop the same way a style
    /// change does — otherwise the bird starts avoiding a perch that still looks pristine.
    private var shapes: [String: ShapeKey] = [:]

    private struct ShapeKey: Equatable {
        var style: PropStyle
        var height: Float
        var knockOffs: Int
        /// Paint is part of the build rather than a material swap: the prop is an assembly
        /// of primitives with per-part colours, so recolouring it is rebuilding it.
        var tint: PropTint

        init(_ marker: LandmarkPlacer.Marker) {
            style = marker.prop
            height = marker.height
            knockOffs = marker.knockOffs
            tint = marker.tint
        }
    }

    /// Mirrors the map onto the scene: adds new props, moves existing ones, drops removed.
    func sync(to markers: [LandmarkPlacer.Marker], dragging: String?) {
        let live = Set(markers.map(\.id))
        for (id, entity) in self.markers where !live.contains(id) {
            entity.removeFromParent()
            self.markers.removeValue(forKey: id)
            styles.removeValue(forKey: id)
            shapes.removeValue(forKey: id)
        }
        for marker in markers {
            let entity = self.markers[marker.id] ?? make(marker)
            if shapes[marker.id] != ShapeKey(marker) { rebuildProp(on: entity, marker: marker) }
            // A marker under the finger is driven by the gesture, not by the record it is
            // about to overwrite — otherwise it snaps back on every frame of the drag.
            if marker.id != dragging { entity.position = marker.position }
        }
    }

    /// The preset id behind an entity the gesture hit, or nil when it is not a marker.
    func presetId(for entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if let id = markers.first(where: { $0.value === current })?.key { return id }
            node = current.parent
        }
        return nil
    }

    func position(of id: String) -> SIMD3<Float>? { markers[id]?.position }

    func setPosition(_ position: SIMD3<Float>, for id: String) {
        markers[id]?.position = position
    }

    private func make(_ marker: LandmarkPlacer.Marker) -> Entity {
        let entity = Entity()
        entity.name = "\(Self.componentName).\(marker.id)"
        entity.position = marker.position
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        root.addChild(entity)
        markers[marker.id] = entity
        rebuildProp(on: entity, marker: marker)
        return entity
    }

    /// Swaps the drawn prop and resizes the pinch target to match it. Collision is a single
    /// sphere sized by `LandmarkProp`: props are eight-part assemblies, and per-part shapes
    /// would make them eight things to miss at arm's length.
    private func rebuildProp(on entity: Entity, marker: LandmarkPlacer.Marker) {
        for child in entity.children { child.removeFromParent() }
        entity.addChild(
            LandmarkProp.make(
                marker.prop,
                height: marker.height,
                knockOffs: marker.knockOffs,
                tint: marker.tint
            )
        )
        let radius = LandmarkProp.grabRadius(for: marker.prop)
        entity.components.set(CollisionComponent(shapes: [
            // Offset upward: props sit on the floor, so a sphere centred on the origin is
            // half underneath it. For an elevated prop the grabbable part is the top — you
            // move a perch by its bar, not by the foot of its pole.
            .generateSphere(radius: radius)
                .offsetBy(translation: SIMD3(0, max(radius * 0.7, marker.height), 0)),
        ]))
        styles[marker.id] = marker.prop
        shapes[marker.id] = ShapeKey(marker)
    }
}
