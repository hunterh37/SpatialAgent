import RealityKit
import SpatialMemory
import UIKit
import simd

/// The low-poly props drawn at each landmark, assembled from RealityKit primitives.
///
/// Spec 06 rules out assets, so a food bowl is a squat cylinder with a rim ring and a cone of
/// seed in it, and a perch is a base, a pole and a crossbar. Recognisable silhouettes matter
/// more than polygon count here: a demo where the bird flies to a shape you can name reads as
/// purposeful, and one where it flies to a blue sphere reads as a debug build.
///
/// Geometry only. Where a prop sits is `LandmarkPlacer`'s business, and what the bird does
/// when it gets there is `HabitMemory`'s.
@MainActor
enum LandmarkProp {
    /// Flat, unlit-ish palette. Low-poly reads best with few, saturated, matte colours.
    private enum Paint {
        static let wood = UIColor(red: 0.62, green: 0.44, blue: 0.27, alpha: 1)
        static let woodDark = UIColor(red: 0.44, green: 0.30, blue: 0.18, alpha: 1)
        static let seed = UIColor(red: 0.85, green: 0.68, blue: 0.30, alpha: 1)
        static let ceramic = UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        static let water = UIColor(red: 0.30, green: 0.66, blue: 0.90, alpha: 1)
        static let fabric = UIColor(red: 0.90, green: 0.42, blue: 0.53, alpha: 1)
        static let fabricDark = UIColor(red: 0.74, green: 0.30, blue: 0.42, alpha: 1)
        static let wicker = UIColor(red: 0.80, green: 0.66, blue: 0.42, alpha: 1)
        static let toyA = UIColor(red: 0.40, green: 0.78, blue: 0.55, alpha: 1)
        static let toyB = UIColor(red: 0.98, green: 0.76, blue: 0.29, alpha: 1)
        static let leaf = UIColor(red: 0.29, green: 0.60, blue: 0.36, alpha: 1)
        static let terracotta = UIColor(red: 0.78, green: 0.40, blue: 0.26, alpha: 1)
        static let slate = UIColor(red: 0.36, green: 0.40, blue: 0.47, alpha: 1)
        static let marker = UIColor(red: 0.35, green: 0.62, blue: 0.95, alpha: 1)
    }

    /// Builds the prop for a landmark, origin at the floor, +Y up.
    static func make(_ style: PropStyle) -> Entity {
        let root = Entity()
        switch style {
        case .perch: buildPerch(into: root)
        case .foodBowl: buildBowl(into: root, contents: Paint.seed, heaped: true)
        case .waterDish: buildBowl(into: root, contents: Paint.water, heaped: false)
        case .cushion: buildCushion(into: root)
        case .toyBasket: buildToyBasket(into: root)
        case .desk: buildDesk(into: root)
        case .plant: buildPlant(into: root)
        case .marker: buildMarker(into: root)
        }
        return root
    }

    /// The pinch target. Deliberately a single generous sphere rather than per-part shapes:
    /// a prop assembled from eight primitives is eight things to miss at arm's length.
    static func grabRadius(for style: PropStyle) -> Float {
        switch style {
        case .desk: return 0.26
        case .perch, .toyBasket, .plant: return 0.18
        default: return 0.14
        }
    }

    // MARK: - Props

    /// Base disc, pole, crossbar. The silhouette is the whole point: it should read as a
    /// perch from across the room, because it is where the bird goes when nobody is talking.
    private static func buildPerch(into root: Entity) {
        root.addChild(cylinder(radius: 0.09, height: 0.02, color: Paint.woodDark, y: 0.01))
        root.addChild(cylinder(radius: 0.012, height: 0.30, color: Paint.wood, y: 0.16))
        let bar = box(size: SIMD3(0.26, 0.016, 0.016), color: Paint.wood, y: 0.31)
        root.addChild(bar)
        // Two end caps, so the crossbar has ends rather than just stopping.
        for x in [Float(-0.13), 0.13] {
            root.addChild(sphere(radius: 0.014, color: Paint.woodDark, at: SIMD3(x, 0.31, 0)))
        }
    }

    /// Squat cylinder, rim ring of small boxes, and a cone of contents. Same body for food
    /// and water: what differs is the fill colour and whether it is heaped or flat, which is
    /// exactly the real-world difference.
    private static func buildBowl(into root: Entity, contents: UIColor, heaped: Bool) {
        root.addChild(cylinder(radius: 0.085, height: 0.05, color: Paint.ceramic, y: 0.025))
        // The rim: eight blocks around the circle reads as faceted, which is the look.
        for index in 0 ..< 8 {
            let angle = Float(index) / 8 * 2 * .pi
            let segment = box(
                size: SIMD3(0.036, 0.018, 0.016),
                color: Paint.ceramic,
                y: 0.055
            )
            segment.position = SIMD3(cos(angle) * 0.082, 0.055, sin(angle) * 0.082)
            segment.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(segment)
        }
        if heaped {
            let heap = ModelEntity(
                mesh: .generateCone(height: 0.045, radius: 0.062),
                materials: [matte(contents)]
            )
            heap.position = SIMD3(0, 0.05, 0)
            root.addChild(heap)
        } else {
            root.addChild(cylinder(radius: 0.068, height: 0.008, color: contents, y: 0.052))
        }
    }

    /// Where the petting happens: a plump cushion, a tufting button, and a low back so it
    /// reads as a seat rather than a mat.
    private static func buildCushion(into root: Entity) {
        let pad = box(size: SIMD3(0.34, 0.09, 0.30), color: Paint.fabric, y: 0.045)
        root.addChild(pad)
        root.addChild(box(size: SIMD3(0.34, 0.02, 0.30), color: Paint.fabricDark, y: 0.005))
        root.addChild(sphere(radius: 0.018, color: Paint.fabricDark, at: SIMD3(0, 0.092, 0)))
        // Corner tufts, so the top face is not a flat plane.
        for x in [Float(-0.12), 0.12] {
            for z in [Float(-0.10), 0.10] {
                root.addChild(
                    sphere(radius: 0.011, color: Paint.fabricDark, at: SIMD3(x, 0.09, z))
                )
            }
        }
    }

    /// Open basket: a wicker tub, a rim, and three toys sticking out — a ball, a bell and a
    /// ring. The toys are what make "find a toy" legible when the bird lands here.
    private static func buildToyBasket(into root: Entity) {
        root.addChild(cylinder(radius: 0.13, height: 0.14, color: Paint.wicker, y: 0.07))
        root.addChild(cylinder(radius: 0.138, height: 0.018, color: Paint.woodDark, y: 0.145))
        root.addChild(sphere(radius: 0.045, color: Paint.toyA, at: SIMD3(0.04, 0.17, 0.02)))
        root.addChild(sphere(radius: 0.032, color: Paint.toyB, at: SIMD3(-0.05, 0.165, -0.03)))
        let ring = ModelEntity(
            mesh: .generateCylinder(height: 0.012, radius: 0.05),
            materials: [matte(Paint.fabric)]
        )
        ring.position = SIMD3(-0.02, 0.185, 0.06)
        ring.orientation = simd_quatf(angle: .pi / 2.6, axis: SIMD3(1, 0, 0.3))
        root.addChild(ring)
    }

    /// Top, four legs, a monitor slab. Scenery, not a need: it exists so the room has a
    /// landmark the bird visits for the user rather than for itself.
    private static func buildDesk(into root: Entity) {
        root.addChild(box(size: SIMD3(0.80, 0.03, 0.44), color: Paint.wood, y: 0.72))
        for x in [Float(-0.37), 0.37] {
            for z in [Float(-0.19), 0.19] {
                let leg = box(size: SIMD3(0.03, 0.70, 0.03), color: Paint.woodDark, y: 0.35)
                leg.position = SIMD3(x, 0.35, z)
                root.addChild(leg)
            }
        }
        let screen = box(size: SIMD3(0.32, 0.20, 0.015), color: Paint.slate, y: 0.86)
        screen.position = SIMD3(0, 0.86, -0.12)
        root.addChild(screen)
        root.addChild(cylinder(radius: 0.05, height: 0.012, color: Paint.slate, y: 0.742))
    }

    /// Tapered pot, stem, and four leaf blades at angles. The one prop the bird must not
    /// land on, so it is drawn tall enough to be obviously in the way.
    private static func buildPlant(into root: Entity) {
        let pot = ModelEntity(
            mesh: .generateCone(height: 0.16, radius: 0.10),
            materials: [matte(Paint.terracotta)]
        )
        // Inverted cone: wide at the top, which is what a pot is.
        pot.position = SIMD3(0, 0.08, 0)
        pot.orientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        root.addChild(pot)
        root.addChild(cylinder(radius: 0.10, height: 0.02, color: Paint.woodDark, y: 0.155))
        root.addChild(cylinder(radius: 0.012, height: 0.22, color: Paint.leaf, y: 0.27))
        for index in 0 ..< 4 {
            let angle = Float(index) / 4 * 2 * .pi
            let blade = box(size: SIMD3(0.16, 0.012, 0.05), color: Paint.leaf, y: 0.36)
            blade.position = SIMD3(cos(angle) * 0.07, 0.36, sin(angle) * 0.07)
            blade.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1))
            root.addChild(blade)
        }
    }

    /// The fallback for a landmark with no prop of its own: a faceted pin, not a ball.
    private static func buildMarker(into root: Entity) {
        root.addChild(cylinder(radius: 0.05, height: 0.012, color: Paint.slate, y: 0.006))
        let pin = ModelEntity(
            mesh: .generateCone(height: 0.12, radius: 0.045),
            materials: [matte(Paint.marker)]
        )
        pin.position = SIMD3(0, 0.07, 0)
        pin.orientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        root.addChild(pin)
        root.addChild(sphere(radius: 0.022, color: Paint.marker, at: SIMD3(0, 0.145, 0)))
    }

    // MARK: - Primitives

    private static func matte(_ color: UIColor) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: 0.85, isMetallic: false)
    }

    private static func box(size: SIMD3<Float>, color: UIColor, y: Float) -> ModelEntity {
        let entity = ModelEntity(
            mesh: .generateBox(size: size),
            materials: [matte(color)]
        )
        entity.position = SIMD3(0, y, 0)
        return entity
    }

    private static func cylinder(
        radius: Float,
        height: Float,
        color: UIColor,
        y: Float
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: .generateCylinder(height: height, radius: radius),
            materials: [matte(color)]
        )
        entity.position = SIMD3(0, y, 0)
        return entity
    }

    private static func sphere(
        radius: Float,
        color: UIColor,
        at position: SIMD3<Float>
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [matte(color)]
        )
        entity.position = position
        return entity
    }
}
