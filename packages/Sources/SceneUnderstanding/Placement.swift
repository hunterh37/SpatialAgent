import Foundation
import simd

/// Launch placement rules (spec/05-scene.md + spec/01-character.md).
///
/// The character is placed on the nearest reachable floor point that is at least 1.0m from
/// the user, in front of them, and not inside geometry. If no such point exists the app says
/// so rather than placing the character badly — hence the optional return.
public enum Placement {
    public static let minimumUserDistance: Float = 1.0
    public static let preferredUserDistance: Float = 1.6
    /// Half-angle of the "in view" cone, in radians (~±45°).
    public static let viewHalfAngle: Float = .pi / 4

    public struct Pose: Sendable, Hashable {
        public var position: SIMD3<Float>
        /// Yaw in radians, facing the user.
        public var yaw: Float

        public init(position: SIMD3<Float>, yaw: Float) {
            self.position = position
            self.yaw = yaw
        }
    }

    public static func initialPose(
        in mesh: NavMesh,
        userPosition: SIMD3<Float>,
        userForward: SIMD3<Float>
    ) -> Pose? {
        let forward = normalizedPlanar(userForward)
        var best: (SIMD3<Float>, Float)?

        // Sample the cone in front of the user, near-to-far, and take the first reachable
        // point past the minimum distance. Sampling beats scanning the whole grid: the
        // result must read as "it is standing over there", not "it is in the far corner".
        var distance = preferredUserDistance
        while distance <= 3.5 {
            var angle = -viewHalfAngle
            while angle <= viewHalfAngle {
                let direction = rotateY(forward, by: angle)
                let candidate = userPosition + direction * distance
                if let clamped = mesh.clamp(candidate, maxRadius: 0.5) {
                    let d = planarDistance(clamped, userPosition)
                    guard d >= minimumUserDistance else { angle += .pi / 18; continue }
                    let score = abs(d - preferredUserDistance) + abs(angle)
                    if best == nil || score < best!.1 { best = (clamped, score) }
                }
                angle += .pi / 18
            }
            if let best { return Pose(position: best.0, yaw: yawFacing(best.0, userPosition)) }
            distance += 0.25
        }
        return nil
    }

    public static func yawFacing(_ from: SIMD3<Float>, _ target: SIMD3<Float>) -> Float {
        let d = target - from
        return atan2(d.x, d.z)
    }

    public static func planarDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }

    private static func normalizedPlanar(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let planar = SIMD3(v.x, 0, v.z)
        return simd_length(planar) < 1e-4 ? SIMD3(0, 0, -1) : simd_normalize(planar)
    }

    private static func rotateY(_ v: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        SIMD3(
            v.x * cos(angle) - v.z * sin(angle),
            v.y,
            v.x * sin(angle) + v.z * cos(angle)
        )
    }
}
