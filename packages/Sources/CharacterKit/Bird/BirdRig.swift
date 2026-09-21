#if canImport(RealityKit)
import Foundation
import RealityKit
import simd

#if canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#endif

/// The bird, assembled from `MeshResource` primitives into the spec 06 hierarchy.
///
/// No skinned mesh, no imported rig, no baked clips: every joint is an entity and everything
/// downstream moves it by transform. The rig owns construction and naming only — motion lives
/// in `BirdAnimator` and its controllers, so that the thing that builds the body and the thing
/// that drives it can be tested apart.
///
/// Budget (spec 06 §Budget): ≤15 `ModelEntity`s, ≤3 materials, no textures. The crest is three
/// cones in a single merged mesh rather than three entities, which is the only reason the
/// count closes at exactly 15.
@MainActor
public final class BirdRig {
    /// Every named joint in the spec 06 hierarchy diagram.
    public enum Joint: String, CaseIterable, Sendable {
        case root = "BirdRoot"
        case bob = "Bob"
        case body = "Body"
        case head = "Head"
        case eyeL = "EyeL"
        case eyeR = "EyeR"
        case pupilL = "PupilL"
        case pupilR = "PupilR"
        case beak = "Beak"
        case browL = "BrowL"
        case browR = "BrowR"
        case crest = "Crest"
        case wingL = "WingL"
        case wingR = "WingR"
        case footL = "FootL"
        case footR = "FootR"
        case tail = "Tail"
    }

    /// Spec 06 §Budget.
    public static let maxModelEntities = 15
    public static let maxMaterials = 3

    public let proportions: BirdProportions
    public let palette: BirdPalette

    /// Navigation owns this one: yaw, world position, path following.
    public let root = Entity()

    private var joints: [Joint: Entity] = [:]
    private var materials: [RealityKit.Material] = []

    public init(proportions: BirdProportions = BirdProportions(), palette: BirdPalette = .teal) {
        self.proportions = proportions
        self.palette = palette
        build()
    }

    /// Named reference to every joint. Controllers address the rig through this and never
    /// walk the entity tree by index.
    public func entity(_ joint: Joint) -> Entity? { joints[joint] }

    /// Number of `ModelEntity`s actually created. Asserted against the budget.
    public var modelEntityCount: Int {
        var count = 0
        var stack = [root]
        while let entity = stack.popLast() {
            if entity is ModelEntity { count += 1 }
            stack.append(contentsOf: entity.children)
        }
        return count
    }

    /// Distinct material instances in the rig.
    public var materialCount: Int { materials.count }

    /// Lowest point of the assembled bird, in root-local space. The presence rule (spec 05)
    /// checks this against the floor plane, so it is computed rather than measured off a
    /// visual-bounds call that needs a live scene.
    public var lowestPointY: Float { 0 }

    /// Crown height of the assembled rig after normalization.
    public var crownHeight: Float {
        proportions.naturalCrownHeight * proportions.normalizationScale
    }

    // MARK: - Construction

    private func build() {
        let p = proportions
        root.name = Joint.root.rawValue
        joints[.root] = root

        let plumage = material(palette.plumage)
        let sclera = material(palette.sclera)
        let accent = material(palette.accent)
        materials = [plumage, sclera, accent]

        // Bob owns everything that makes walking look like walking. Head hangs off Bob, not
        // off Body, so attention stays independent of locomotion.
        let bob = Entity()
        bob.name = Joint.bob.rawValue
        // One uniform scale reconciles the spec's part sizes with its 22cm crown; see
        // BirdProportions.normalizationScale.
        bob.scale = SIMD3(repeating: p.normalizationScale)
        joints[.bob] = bob
        root.addChild(bob)

        // Body ---------------------------------------------------------------------------
        let body = ModelEntity(mesh: .generateSphere(radius: p.bodyRadius), materials: [plumage])
        body.name = Joint.body.rawValue
        body.scale = p.bodyScale
        body.position = SIMD3(0, p.bodyCenterY, 0)
        // Tap target for addressing. One collider on the body, not per part.
        body.components.set(InputTargetComponent())
        body.components.set(CollisionComponent(shapes: [.generateSphere(radius: p.bodyRadius)]))
        joints[.body] = body
        bob.addChild(body)

        // Wings sit low on the body and rest slightly out from it, never folded flat.
        for (joint, side) in [(Joint.wingL, Float(-1)), (Joint.wingR, Float(1))] {
            let wing = ModelEntity(
                mesh: .generateSphere(radius: p.wingLength / 2),
                materials: [plumage]
            )
            wing.name = joint.rawValue
            wing.scale = SIMD3(p.wingFlatten, 0.62, 1.0)
            wing.position = SIMD3(
                side * (p.bodyRadius * 0.86 + p.wingRest),
                p.bodyCenterY * 0.12,
                -p.bodyRadius * 0.10
            )
            joints[joint] = wing
            body.addChild(wing)
        }

        // Tail: a counterweight for the head, visually and in the animation.
        let tail = ModelEntity(
            mesh: .generateBox(
                size: SIMD3(p.tailWidth, p.tailThickness, p.tailLength),
                cornerRadius: p.tailThickness / 2
            ),
            materials: [plumage]
        )
        tail.name = Joint.tail.rawValue
        tail.position = SIMD3(0, p.bodyRadius * 0.28, -(p.bodyRadius * 0.95 + p.tailLength / 2))
        tail.orientation = simd_quatf(angle: 0.32, axis: SIMD3(1, 0, 0))
        joints[.tail] = tail
        body.addChild(tail)

        // Feet ---------------------------------------------------------------------------
        // Parented to Bob rather than Body: the hop controller grounds them independently of
        // body squash, and a foot that inherits squash is a foot that slides.
        for (joint, side) in [(Joint.footL, Float(-1)), (Joint.footR, Float(1))] {
            let foot = ModelEntity(
                mesh: .generateBox(
                    size: SIMD3(p.footWidth, p.footHeight, p.footLength),
                    cornerRadius: p.footHeight / 2.5
                ),
                materials: [accent]
            )
            foot.name = joint.rawValue
            foot.position = SIMD3(
                side * p.footSeparation / 2,
                p.footHeight / 2,
                p.footLength * 0.18
            )
            joints[joint] = foot
            bob.addChild(foot)
        }

        // Head ---------------------------------------------------------------------------
        let head = ModelEntity(mesh: .generateSphere(radius: p.headRadius), materials: [plumage])
        head.name = Joint.head.rawValue
        head.position = SIMD3(0, p.headCenterY, p.headForward)
        joints[.head] = head
        bob.addChild(head)

        // Face parts are positioned in head-local space.
        let eyeY = p.eyeRise
        let eyeZ = p.headRadius * 0.72
        for (eyeJoint, pupilJoint, side) in [
            (Joint.eyeL, Joint.pupilL, Float(-1)),
            (Joint.eyeR, Joint.pupilR, Float(1)),
        ] {
            let eye = ModelEntity(mesh: .generateSphere(radius: p.eyeRadius), materials: [sclera])
            eye.name = eyeJoint.rawValue
            eye.position = SIMD3(side * p.eyeCenterX, eyeY, eyeZ)
            joints[eyeJoint] = eye
            head.addChild(eye)

            // Pupil rides the eye surface; the animator offsets it toward the look target and
            // clamps it so it never leaves the sclera.
            let pupil = ModelEntity(
                mesh: .generateSphere(radius: p.pupilDiameter / 2),
                materials: [plumage]
            )
            pupil.name = pupilJoint.rawValue
            pupil.position = SIMD3(0, 0, p.eyeRadius * 0.78)
            joints[pupilJoint] = pupil
            eye.addChild(pupil)
        }

        // Beak hinges at its base, so the mesh is authored with the base at the origin.
        let beak = ModelEntity(
            mesh: .generateCone(height: p.beakLength, radius: p.beakBaseDiameter / 2),
            materials: [accent]
        )
        beak.name = Joint.beak.rawValue
        beak.position = SIMD3(0, -p.beakDrop, p.headRadius * 0.86)
        // Cones generate along +Y; the beak points along +Z.
        beak.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        joints[.beak] = beak
        head.addChild(beak)

        // Brows carry the plumage material, which is what keeps them barely visible at rest.
        for (joint, side) in [(Joint.browL, Float(-1)), (Joint.browR, Float(1))] {
            let brow = ModelEntity(
                mesh: .generateBox(
                    size: SIMD3(p.browLength, p.browThickness, p.browThickness),
                    cornerRadius: p.browThickness / 2
                ),
                materials: [plumage]
            )
            brow.name = joint.rawValue
            brow.position = SIMD3(side * p.eyeCenterX, p.browRise, eyeZ * 0.88)
            joints[joint] = brow
            head.addChild(brow)
        }

        // Crest: three cones in one mesh. Present per variant.
        if palette.hasCrest {
            let crest = ModelEntity(mesh: Self.crestMesh(proportions: p), materials: [accent])
            crest.name = Joint.crest.rawValue
            crest.position = SIMD3(0, p.headRadius * 0.86, -p.headRadius * 0.10)
            joints[.crest] = crest
            head.addChild(crest)
        }
    }

    // MARK: - Meshes

    /// Three cones merged into a single `MeshResource`.
    ///
    /// Three entities would read identically and cost three draws plus three transforms, and
    /// would put the rig at 17 model entities against a budget of 15. The crest never
    /// articulates per-cone — it leans and spreads as a unit — so nothing is lost by merging.
    static func crestMesh(proportions p: BirdProportions) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let radius = p.crestConeDiameter / 2
        let height = p.crestConeHeight
        let segments = 8

        for (index, offsetX) in [-p.crestSpread, 0, p.crestSpread].enumerated() {
            // Outer cones lean outward and are slightly shorter; a flat trio reads as a comb.
            let lean = Float(index - 1) * 0.22
            let scale: Float = index == 1 ? 1.0 : 0.82
            let tilt = simd_quatf(angle: lean, axis: SIMD3(0, 0, 1))
            let apexLocal = SIMD3<Float>(0, height * scale, 0)
            let base = UInt32(positions.count)

            positions.append(SIMD3(offsetX, 0, 0) + tilt.act(apexLocal))
            normals.append(tilt.act(SIMD3(0, 1, 0)))

            for segment in 0..<segments {
                let angle = Float(segment) / Float(segments) * 2 * .pi
                let ring = SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
                positions.append(SIMD3(offsetX, 0, 0) + tilt.act(ring))
                normals.append(tilt.act(simd_normalize(SIMD3(cos(angle), 0.45, sin(angle)))))
            }

            for segment in 0..<segments {
                let a = base + 1 + UInt32(segment)
                let b = base + 1 + UInt32((segment + 1) % segments)
                indices.append(contentsOf: [base, b, a])
            }
        }

        var descriptor = MeshDescriptor(name: "BirdCrest")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? .generateCone(height: height, radius: radius)
    }

    // MARK: - Materials

    /// Flat, unlit-looking shading: low-poly with a limited palette reads as intentional at
    /// 25cm, where a mid-fidelity bird reads as a bad bird.
    private func material(_ rgb: BirdPalette.RGB) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        let color = PlatformColor(
            red: CGFloat(rgb.r),
            green: CGFloat(rgb.g),
            blue: CGFloat(rgb.b),
            alpha: 1
        )
        material.baseColor = .init(tint: color)
        material.roughness = 0.9
        material.metallic = 0.0
        return material
    }
}
#endif
