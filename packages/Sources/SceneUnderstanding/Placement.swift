import Foundation
import SpatialMemory
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

    /// How much a map-preferred spot may bend the placement score.
    ///
    /// A preference, not an override: every hard constraint in spec 05 — reachable floor,
    /// past the minimum distance, in view, out of forbidden regions — still decides whether a
    /// candidate is legal at all, and this only reorders the legal ones. A bird that stands
    /// inside the couch because the couch is a perch has learned the wrong lesson.
    public static let perchBonus: Float = 0.9
    public static let usualPlaceBonus: Float = 0.6

    /// Placement that knows the room (spec 07 §Learned behavior).
    ///
    /// Prefers `perch` regions and the place the user most often occupies at this time of
    /// day over the nearest legal floor point. With an empty map this is exactly
    /// `initialPose`, which is why the map version is the same function with a bias rather
    /// than a second implementation that can drift from it.
    public static func initialPose(
        in mesh: NavMesh,
        userPosition: SIMD3<Float>,
        userForward: SIMD3<Float>,
        map: SemanticMap,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Pose? {
        let perches = map.rules.filter { $0.kind == .perch }
        // The taught home perch is a *place*, not a rule: the landmark checklist and "this
        // is your perch" both write `PlaceKind.perch`, and launch placement has to honour
        // that or the bird ignores the one spot the user chose for it.
        let home = map.homePerch
        let usual = usualPlace(in: map, now: now, calendar: calendar)
        guard !perches.isEmpty || home != nil || usual != nil else {
            return initialPose(in: mesh, userPosition: userPosition, userForward: userForward)
        }
        return initialPose(
            in: mesh,
            userPosition: userPosition,
            userForward: userForward
        ) { candidate in
            var bonus: Float = 0
            if perches.contains(where: { $0.contains(candidate) }) { bonus += perchBonus }
            if let home, home.isNavigable, home.contains(candidate) { bonus += perchBonus }
            if let usual, usual.contains(candidate) { bonus += usualPlaceBonus }
            return bonus
        }
    }

    /// The place with an activity whose observed band covers now. Ties break on the activity
    /// seen most often, because "where you usually are at this hour" is a frequency claim.
    public static func usualPlace(
        in map: SemanticMap,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Place? {
        let minute = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        let active = map.activities
            .filter { $0.isActive(atMinute: minute) }
            .sorted { $0.bands.reduce(0) { $0 + $1.observations } > $1.bands.reduce(0) { $0 + $1.observations } }
        for activity in active {
            if let id = activity.placeId, let place = map.place(id: id) { return place }
        }
        return nil
    }

    public static func initialPose(
        in mesh: NavMesh,
        userPosition: SIMD3<Float>,
        userForward: SIMD3<Float>,
        bonus: (SIMD3<Float>) -> Float = { _ in 0 }
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
                if let clamped = mesh.clamp(candidate, maxRadius: 0.5),
                   mesh.allowsLanding(at: clamped) {
                    let d = planarDistance(clamped, userPosition)
                    guard d >= minimumUserDistance else { angle += .pi / 18; continue }
                    // Lower is better; the map's preference subtracts from the score and
                    // can never make an illegal candidate legal, only reorder legal ones.
                    let score = abs(d - preferredUserDistance) + abs(angle) - bonus(clamped)
                    if best == nil || score < best!.1 { best = (clamped, score) }
                }
                angle += .pi / 18
            }
            distance += 0.25
        }
        // Every ring is scored before choosing, rather than the first ring with any hit
        // winning: a map preference two rings out has to be able to beat a bare floor point
        // one ring in, and the distance term still keeps the bird from crossing the room.
        guard let best else { return nil }
        return Pose(position: best.0, yaw: yawFacing(best.0, userPosition))
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
