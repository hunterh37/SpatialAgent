import Foundation
import simd

/// Which perch the bird picks, and why it stops picking one.
///
/// The room has three perches and they are identical as records: same kind, same prop, same
/// height. Nothing distinguishes them except what has happened to the bird on each one. So
/// "go perch" is not a lookup with one answer — it is a choice over equals, and the only
/// input to it is `Place.knockOffs`, written when a hand swats the bird off.
///
/// That is the whole learning demo: tap "go perch" repeatedly, knock him off the one he
/// picks, and the choice moves. Nothing is scripted, nothing is hard-coded to a name, and
/// the number the choice is made from is visible on the record in the inspector.
public enum PerchMemory {
    /// How much one knock-off counts against a perch, in units of "visits". High enough
    /// that a single knock outweighs any amount of prior success: a bird that has been
    /// swatted once does not go back to argue about it.
    public static let knockWeight: Float = 8

    public struct Choice: Equatable, Sendable {
        public var place: Place?
        /// Perches ruled out by a knock-off, worst first. Named in the spoken line.
        public var avoided: [Place]
        /// Spoken before the flight, so the audience hears the reason.
        public var line: String
        /// True once at least one perch has been learned about.
        public var isLearned: Bool

        public var canAct: Bool { place != nil }
    }

    /// Every perch the bird could currently stand on.
    ///
    /// `SemanticMap.perches` and not a `kind == .perch` filter: the choice is narrated by
    /// name, so a record whose name is not one of the three colours has nothing the bird can
    /// say about it and must never be a candidate, whatever kind it was written with.
    public static func candidates(in map: SemanticMap) -> [Place] {
        map.perches.filter(\.isNavigable)
    }

    /// Lower is better. Knock-offs dominate; visits break ties among untouched perches so a
    /// perch that already worked stays the favourite instead of the choice wandering.
    public static func cost(_ place: Place) -> Float {
        Float(place.knockOffs) * knockWeight - Float(min(place.useCount, 4)) * 0.25
    }

    /// The perch to fly to. Ties break on the earlier-taught record, which makes the choice
    /// deterministic — a demo where the same state picks a different perch each tap is a
    /// demo that proves nothing.
    public static func best(in map: SemanticMap) -> Place? {
        candidates(in: map).min { a, b in
            let ca = cost(a), cb = cost(b)
            return ca == cb ? a.taughtAt < b.taughtAt : ca < cb
        }
    }

    /// The perches the bird now refuses, most-swatted first.
    public static func avoided(in map: SemanticMap) -> [Place] {
        candidates(in: map)
            .filter { $0.knockOffs > 0 }
            .sorted { $0.knockOffs > $1.knockOffs }
    }

    /// One choice, resolved and narrated.
    public static func choose(in map: SemanticMap) -> Choice {
        let avoid = avoided(in: map)
        guard let place = best(in: map) else {
            return Choice(
                place: nil,
                avoided: avoid,
                line: "I don't have anywhere to perch yet — show me and I'll remember.",
                isLearned: false
            )
        }
        return Choice(
            place: place,
            avoided: avoid,
            line: line(for: place, avoiding: avoid),
            isLearned: !avoid.isEmpty
        )
    }

    /// What every perch is worth right now, best first. The inspector row and the "what do
    /// you know" sentence are both built from this, so they cannot disagree.
    public static func ranking(in map: SemanticMap) -> [Place] {
        candidates(in: map).sorted { a, b in
            let ca = cost(a), cb = cost(b)
            return ca == cb ? a.taughtAt < b.taughtAt : ca < cb
        }
    }

    /// A sentence that names the avoidance, because an audience cannot see a counter.
    static func line(for place: Place, avoiding avoid: [Place]) -> String {
        guard let worst = avoid.first, worst.id != place.id else {
            return place.useCount > 0
                ? "\(place.name). Still the good one."
                : "\(place.name), then."
        }
        let times = worst.knockOffs == 1 ? "once" : "\(worst.knockOffs) times"
        if avoid.count == 1 {
            return "Not \(worst.name) — you knocked me off there \(times). \(place.name) instead."
        }
        let names = avoid.map(\.name)
        return "Not \(list(names)) any more. \(place.name) it is."
    }

    /// The learned half of the "what have I taught you" sentence.
    public static func summary(of map: SemanticMap) -> String? {
        let avoid = avoided(in: map)
        guard !avoid.isEmpty else { return nil }
        return "I stay off \(list(avoid.map(\.name)))"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

public extension SemanticMap {
    /// Counts a knock-off against a perch. Returns the new total, or nil if the id is not a
    /// place — a caller must not believe it taught something it never found.
    @discardableResult
    mutating func noteKnockOff(placeId: UUID) -> Int? {
        guard let index = places.firstIndex(where: { $0.id == placeId }) else { return nil }
        places[index].knockOffs += 1
        return places[index].knockOffs
    }

    /// Clears the aversion without touching the perches themselves: "forget that, try again".
    mutating func forgetKnockOffs() {
        for index in places.indices where places[index].knockOffs > 0 {
            places[index].knockOffs = 0
        }
    }
}

public extension MapStore {
    /// The perch the bird would pick right now.
    var chosenPerch: Place? { PerchMemory.best(in: map) }

    /// Records a knock-off and the episode that explains it. The episode is what makes
    /// "why won't you sit there?" answerable after the fact.
    @discardableResult
    func knockOff(placeId: UUID) -> Int? {
        let total = mutate { $0.noteKnockOff(placeId: placeId) }
        guard let total else { return nil }
        let name = map.places.first { $0.id == placeId }?.name ?? "that perch"
        record(
            Episode(
                placeId: placeId,
                kind: .declined,
                summary: "knocked off \(name) (\(total))"
            )
        )
        return total
    }

    /// Resolves and *counts* a perch visit, the way `visit(_:)` does for a need.
    @discardableResult
    func perch() -> PerchMemory.Choice {
        let choice = PerchMemory.choose(in: map)
        if let place = choice.place {
            mutate { $0.noteUse(placeId: place.id) }
            record(Episode(placeId: place.id, kind: .visited, summary: "perched on \(place.name)"))
        }
        return choice
    }

    func forgetKnockOffs() {
        mutate { $0.forgetKnockOffs() }
    }
}
