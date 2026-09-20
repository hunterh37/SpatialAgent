import RealityKit
import SwiftUI
import SceneUnderstanding
import SpatialMemory
import simd

/// The blue spheres you grab: one per placed landmark, drawn in the immersive scene.
///
/// Rendering and gesture plumbing only. Where a dragged marker ends up is written by
/// `LandmarkPlacer.move`, so a drag and a spoken correction land in the map identically
/// (docs/architecture.md §1).
@MainActor
final class LandmarkMarkers {
    /// Name the drag gesture matches on, so grabbing the bird is never a landmark drag.
    static let componentName = "landmark"

    let root = Entity()
    private var spheres: [String: ModelEntity] = [:]

    private static let radius: Float = 0.045

    /// Mirrors the map onto the scene: adds new markers, moves existing ones, drops removed.
    func sync(to markers: [LandmarkPlacer.Marker], dragging: String?) {
        let live = Set(markers.map(\.id))
        for (id, entity) in spheres where !live.contains(id) {
            entity.removeFromParent()
            spheres.removeValue(forKey: id)
        }
        for marker in markers {
            let entity = spheres[marker.id] ?? make(marker)
            // A marker under the finger is driven by the gesture, not by the record it is
            // about to overwrite — otherwise it snaps back on every frame of the drag.
            if marker.id != dragging { entity.position = marker.position }
        }
    }

    /// The preset id behind an entity the gesture hit, or nil when it is not a marker.
    func presetId(for entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            if let id = spheres.first(where: { $0.value === current })?.key { return id }
            node = current.parent
        }
        return nil
    }

    func position(of id: String) -> SIMD3<Float>? { spheres[id]?.position }

    func setPosition(_ position: SIMD3<Float>, for id: String) {
        spheres[id]?.position = position
    }

    private func make(_ marker: LandmarkPlacer.Marker) -> ModelEntity {
        // The perch reads brighter: it is the one marker whose placement changes idle
        // behaviour, so it should be findable without reading a label.
        let color: UIColor = marker.isHomePerch ? .systemTeal : .systemBlue
        let entity = ModelEntity(
            mesh: .generateSphere(radius: Self.radius),
            materials: [SimpleMaterial(color: color, roughness: 0.2, isMetallic: false)]
        )
        entity.name = "\(Self.componentName).\(marker.id)"
        entity.position = marker.position
        // Collision radius is deliberately larger than the sphere: a 4.5cm target is hard
        // to pinch at arm's length.
        entity.collision = CollisionComponent(shapes: [.generateSphere(radius: 0.09)])
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        root.addChild(entity)
        spheres[marker.id] = entity
        return entity
    }
}
