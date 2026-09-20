import AgentProtocol
import Foundation
import SpatialMemory
import simd

/// Walkable floor as a coarse occupancy grid, plus A* over it.
///
/// Pure geometry: no ARKit, no RealityKit. That is deliberate — the navmesh is the piece
/// that makes hallucinated navigation impossible rather than merely unlikely
/// (spec/05-scene.md), so it has to be unit-testable on Linux-grade tooling with a fixture
/// floor plan, not only on a headset.
public struct NavMesh: Sendable {
    /// Cell size in metres. 10cm trades path smoothness for rebuild cost; the character is
    /// ~45cm tall (spec/01-character.md) so this is roughly a quarter of its footprint.
    public static let cellSize: Float = 0.1

    /// Obstacles are inflated by this margin so the character never grazes furniture.
    public static let clearance: Float = 0.15

    public private(set) var origin: SIMD2<Float>
    public private(set) var width: Int
    public private(set) var depth: Int
    private var walkable: [Bool]
    /// Floor height per cell, so a path carries Y and the feet stay in contact.
    private var height: [Float]

    /// Hard `forbidden` regions, kept after subtraction so `contains` questions can be
    /// answered without re-deriving them from the grid.
    public private(set) var forbiddenRegions: [CircleRegion] = []
    /// `fragile` regions. These are *not* subtracted: the bird may path near them, it may
    /// not land on them or gesture at them (spec 07 §Rules). Subtracting them would make a
    /// coffee table with a vase on it into a wall.
    public private(set) var fragileRegions: [CircleRegion] = []

    public init(origin: SIMD2<Float>, width: Int, depth: Int) {
        self.origin = origin
        self.width = max(0, width)
        self.depth = max(0, depth)
        walkable = Array(repeating: false, count: self.width * self.depth)
        height = Array(repeating: 0, count: self.width * self.depth)
    }

    public var walkableCellCount: Int { walkable.lazy.filter { $0 }.count }

    public var floorArea: Double {
        Double(walkableCellCount) * Double(Self.cellSize * Self.cellSize)
    }

    // MARK: - Building

    public mutating func addFloor(rect: FloorRect) {
        for index in cells(in: rect) {
            walkable[index] = true
            height[index] = rect.y
        }
    }

    /// Obstacle footprints are subtracted after floors are added, and inflated by
    /// `clearance`. Order matters: a floor plane added after an obstacle would re-open it.
    public mutating func subtractObstacle(rect: FloorRect) {
        for index in cells(in: rect.expanded(by: Self.clearance)) {
            walkable[index] = false
        }
    }

    /// Subtracts a hard `forbidden` rule from the walkable surface.
    ///
    /// This is the only acceptable enforcement (spec 07 §Enforcement): a hard rule expressed
    /// as a prompt instruction is a rule that gets violated on a bad sample, and one
    /// violation of "don't touch this" costs the user's trust permanently. Once the cells are
    /// gone, a model that decides to go there simply gets no path.
    public mutating func subtractForbidden(_ region: CircleRegion) {
        forbiddenRegions.append(region)
        // Inflated by the same clearance as furniture: pathing along the exact edge of a
        // forbidden region reads as pushing against it.
        let inflated = region.expanded(by: Self.clearance)
        for index in cells(in: inflated.boundingRect) where inflated.contains(worldXZ(index)) {
            walkable[index] = false
        }
    }

    /// Records a `fragile` region without touching the walkable surface.
    public mutating func addFragile(_ region: CircleRegion) {
        fragileRegions.append(region)
    }

    /// True when the point is inside any hard forbidden region. Nothing may be placed here
    /// and no path may pass through it.
    public func isForbidden(_ point: SIMD3<Float>) -> Bool {
        forbiddenRegions.contains { $0.contains(SIMD2(point.x, point.z)) }
    }

    /// The bird may hop past a fragile region but never land on it or gesture at it.
    public func allowsLanding(at point: SIMD3<Float>) -> Bool {
        !isForbidden(point) && !fragileRegions.contains { $0.contains(SIMD2(point.x, point.z)) }
    }

    public func isWalkable(_ point: SIMD3<Float>) -> Bool {
        guard let index = index(for: SIMD2(point.x, point.z)) else { return false }
        return walkable[index]
    }

    /// Nearest walkable point to `point`, searching outward. Returns nil when the mesh has
    /// no reachable floor at all — the app then says so rather than placing the character
    /// badly (spec/05-scene.md).
    public func clamp(_ point: SIMD3<Float>, maxRadius: Float = 3.0) -> SIMD3<Float>? {
        if let index = index(for: SIMD2(point.x, point.z)), walkable[index] {
            return SIMD3(point.x, height[index], point.z)
        }
        let steps = Int(maxRadius / Self.cellSize)
        guard let start = cell(for: SIMD2(point.x, point.z)) else { return nil }
        for ring in 1...max(1, steps) {
            var best: (SIMD3<Float>, Float)?
            for dx in -ring...ring {
                for dz in -ring...ring where abs(dx) == ring || abs(dz) == ring {
                    let c = (x: start.x + dx, z: start.z + dz)
                    guard let index = index(forCell: c), walkable[index] else { continue }
                    let world = worldPosition(cell: c, y: height[index])
                    let distance = simd_distance(world, point)
                    if best == nil || distance < best!.1 { best = (world, distance) }
                }
            }
            if let best { return best.0 }
        }
        return nil
    }

    // MARK: - Pathing

    /// A* on the grid with 8-way movement. Returns waypoints in world space, or nil when
    /// the destination is unreachable — an unreachable `walkTo` fails to `idle` plus a
    /// spoken acknowledgement; it never partially walks toward a wall (spec/01-character.md).
    public func path(from: SIMD3<Float>, to: SIMD3<Float>) -> [SIMD3<Float>]? {
        guard
            let startPoint = clamp(from), let goalPoint = clamp(to),
            let start = cell(for: SIMD2(startPoint.x, startPoint.z)),
            let goal = cell(for: SIMD2(goalPoint.x, goalPoint.z)),
            let startIndex = index(forCell: start), let goalIndex = index(forCell: goal),
            walkable[startIndex], walkable[goalIndex]
        else { return nil }

        if startIndex == goalIndex { return [goalPoint] }

        var open: [(index: Int, f: Float)] = [(startIndex, 0)]
        var cameFrom: [Int: Int] = [:]
        var g: [Int: Float] = [startIndex: 0]
        var closed = Set<Int>()

        func heuristic(_ a: Int, _ b: Int) -> Float {
            let ca = cell(forIndex: a), cb = cell(forIndex: b)
            return simd_distance(
                SIMD2<Float>(Float(ca.x), Float(ca.z)),
                SIMD2<Float>(Float(cb.x), Float(cb.z))
            )
        }

        while !open.isEmpty {
            open.sort { $0.f < $1.f }
            let current = open.removeFirst().index
            if current == goalIndex { return reconstruct(cameFrom, from: goalIndex) }
            closed.insert(current)

            let c = cell(forIndex: current)
            for dx in -1...1 {
                for dz in -1...1 where !(dx == 0 && dz == 0) {
                    let n = (x: c.x + dx, z: c.z + dz)
                    guard let ni = index(forCell: n), walkable[ni], !closed.contains(ni) else {
                        continue
                    }
                    // Diagonals may not cut a corner past an obstacle.
                    if dx != 0, dz != 0 {
                        guard
                            let a = index(forCell: (x: c.x + dx, z: c.z)), walkable[a],
                            let b = index(forCell: (x: c.x, z: c.z + dz)), walkable[b]
                        else { continue }
                    }
                    let step: Float = (dx != 0 && dz != 0) ? 1.41421 : 1
                    let tentative = (g[current] ?? .greatestFiniteMagnitude) + step
                    if tentative < (g[ni] ?? .greatestFiniteMagnitude) {
                        cameFrom[ni] = current
                        g[ni] = tentative
                        let f = tentative + heuristic(ni, goalIndex)
                        if let existing = open.firstIndex(where: { $0.index == ni }) {
                            open[existing].f = f
                        } else {
                            open.append((ni, f))
                        }
                    }
                }
            }
        }
        return nil
    }

    private func reconstruct(_ cameFrom: [Int: Int], from goal: Int) -> [SIMD3<Float>] {
        var chain = [goal]
        var node = goal
        while let previous = cameFrom[node] {
            chain.append(previous)
            node = previous
        }
        let cells = chain.reversed().map { index -> SIMD3<Float> in
            worldPosition(cell: cell(forIndex: index), y: height[index])
        }
        return simplify(Array(cells))
    }

    /// Collapses collinear runs so locomotion turns at corners rather than every 10cm.
    private func simplify(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        for i in 1..<(points.count - 1) {
            let a = simd_normalize(points[i] - out[out.count - 1])
            let b = simd_normalize(points[i + 1] - points[i])
            if simd_dot(a, b) < 0.999 { out.append(points[i]) }
        }
        out.append(points[points.count - 1])
        return out
    }

    // MARK: - Indexing

    private func cell(for xz: SIMD2<Float>) -> (x: Int, z: Int)? {
        let local = (xz - origin) / Self.cellSize
        return (Int(local.x.rounded(.down)), Int(local.y.rounded(.down)))
    }

    private func cell(forIndex index: Int) -> (x: Int, z: Int) {
        (index % width, index / width)
    }

    private func index(forCell c: (x: Int, z: Int)) -> Int? {
        guard c.x >= 0, c.x < width, c.z >= 0, c.z < depth else { return nil }
        return c.z * width + c.x
    }

    private func index(for xz: SIMD2<Float>) -> Int? {
        guard let c = cell(for: xz) else { return nil }
        return index(forCell: c)
    }

    private func worldXZ(_ index: Int) -> SIMD2<Float> {
        let c = cell(forIndex: index)
        return SIMD2(
            origin.x + (Float(c.x) + 0.5) * Self.cellSize,
            origin.y + (Float(c.z) + 0.5) * Self.cellSize
        )
    }

    private func worldPosition(cell c: (x: Int, z: Int), y: Float) -> SIMD3<Float> {
        SIMD3(
            origin.x + (Float(c.x) + 0.5) * Self.cellSize,
            y,
            origin.y + (Float(c.z) + 0.5) * Self.cellSize
        )
    }

    private func cells(in rect: FloorRect) -> [Int] {
        guard
            let lo = cell(for: SIMD2(rect.minX, rect.minZ)),
            let hi = cell(for: SIMD2(rect.maxX, rect.maxZ))
        else { return [] }
        var out: [Int] = []
        for z in lo.z...max(lo.z, hi.z) {
            for x in lo.x...max(lo.x, hi.x) {
                guard let index = index(forCell: (x, z)) else { continue }
                out.append(index)
            }
        }
        return out
    }
}

/// Axis-aligned footprint on the floor plane. ARKit planes and mesh bounds are reduced to
/// this before they reach the navmesh, which keeps the mesh format independent of ARKit.
public struct FloorRect: Sendable, Hashable {
    public var center: SIMD3<Float>
    public var extent: SIMD2<Float>

    public init(center: SIMD3<Float>, extent: SIMD2<Float>) {
        self.center = center
        self.extent = extent
    }

    public var y: Float { center.y }
    public var minX: Float { center.x - extent.x / 2 }
    public var maxX: Float { center.x + extent.x / 2 }
    public var minZ: Float { center.z - extent.y / 2 }
    public var maxZ: Float { center.z + extent.y / 2 }

    public func expanded(by margin: Float) -> FloorRect {
        FloorRect(center: center, extent: extent + SIMD2(margin * 2, margin * 2))
    }
}

/// A taught rule's region on the floor plane. Circular because that is how radius is
/// captured — from a surface extent, not from a drawn polygon (spec 07 §Capture).
public struct CircleRegion: Sendable, Hashable {
    public var center: SIMD2<Float>
    public var radius: Float

    public init(center: SIMD2<Float>, radius: Float) {
        self.center = center
        self.radius = max(0, radius)
    }

    public init(_ rule: Rule) {
        self.init(center: SIMD2(rule.position.x, rule.position.z), radius: rule.radius)
    }

    public func contains(_ point: SIMD2<Float>) -> Bool {
        simd_length(point - center) <= radius
    }

    public func expanded(by margin: Float) -> CircleRegion {
        CircleRegion(center: center, radius: radius + margin)
    }

    var boundingRect: FloorRect {
        FloorRect(
            center: SIMD3(center.x, 0, center.y),
            extent: SIMD2(radius * 2, radius * 2)
        )
    }
}

public enum NavMeshBuilder {
    /// Builds a grid sized to the union of the floor rects, with a one-metre border so
    /// `clamp` has room to search outward at the edges.
    ///
    /// Rules are applied last, after obstacles: a floor plane or an obstacle arriving later
    /// in the list must not be able to re-open a region the user forbade.
    public static func build(
        floors: [FloorRect],
        obstacles: [FloorRect],
        rules: [Rule] = []
    ) -> NavMesh? {
        guard !floors.isEmpty else { return nil }
        let minX = floors.map(\.minX).min()! - 1
        let maxX = floors.map(\.maxX).max()! + 1
        let minZ = floors.map(\.minZ).min()! - 1
        let maxZ = floors.map(\.maxZ).max()! + 1
        var mesh = NavMesh(
            origin: SIMD2(minX, minZ),
            width: Int(((maxX - minX) / NavMesh.cellSize).rounded(.up)),
            depth: Int(((maxZ - minZ) / NavMesh.cellSize).rounded(.up))
        )
        for floor in floors { mesh.addFloor(rect: floor) }
        for obstacle in obstacles { mesh.subtractObstacle(rect: obstacle) }
        for rule in rules where rule.kind == .forbidden && rule.severity == .hard {
            mesh.subtractForbidden(CircleRegion(rule))
        }
        for rule in rules where rule.kind == .fragile {
            mesh.addFragile(CircleRegion(rule))
        }
        return mesh
    }
}
