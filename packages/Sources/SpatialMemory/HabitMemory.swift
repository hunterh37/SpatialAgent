import Foundation
import simd

/// Resolving a *need* against the map, which is the one thing in the demo that is a decision
/// rather than a script.
///
/// "I'm hungry" names no landmark. The destination comes out of `SemanticMap`: the place
/// whose `PlaceKind` answers that need, most-used first, skipping anything that has not
/// relocalized. Delete the bowl and the same utterance produces a question instead of a
/// flight — which is the only way an audience can tell memory from choreography.
public enum HabitMemory {
    public struct Decision: Equatable, Sendable {
        public var need: Need
        /// Nil when nothing in the map answers the need yet.
        public var place: Place?
        /// Spoken before the bird moves, so the lookup is audible.
        public var line: String
        /// True when the bird has been here for this need before, which is the sentence
        /// that makes it sound learned rather than configured.
        public var isLearned: Bool

        public var canAct: Bool { place != nil }
    }

    /// The place that answers a need. Ties break on use count, then on how recently it was
    /// taught: a second bowl taught later is the one the user meant.
    public static func place(for need: Need, in map: SemanticMap) -> Place? {
        // Sleepy is the one need with more than one candidate, and the choice between them
        // is learned rather than counted: `PerchMemory` subtracts the perches he has been
        // knocked off. Routed here so "go settle" and "go perch" can never disagree.
        if need == .sleepy { return PerchMemory.best(in: map) }
        return map.places
            .filter { $0.kind == need.kind && $0.isNavigable }
            .max { a, b in
                a.useCount == b.useCount ? a.taughtAt < b.taughtAt : a.useCount < b.useCount
            }
    }

    /// One need, resolved and narrated.
    public static func decide(_ need: Need, in map: SemanticMap) -> Decision {
        guard let place = place(for: need, in: map) else {
            return Decision(
                need: need,
                place: nil,
                line: "I don't know where I \(need.verb) yet — show me and I'll remember.",
                isLearned: false
            )
        }
        // A perch answers with the avoidance, because "been there 3 times" is the wrong
        // sentence for a place he is choosing *again* after being swatted off another.
        if need == .sleepy {
            let choice = PerchMemory.choose(in: map)
            return Decision(
                need: need,
                place: choice.place,
                line: choice.line,
                isLearned: choice.isLearned
            )
        }
        let learned = place.useCount > 0
        let line = learned
            ? "\(place.name) — that's where I \(need.verb). Been there \(place.useCount)\(place.useCount == 1 ? " time" : " times")."
            : "You showed me \(place.name). That's where I \(need.verb) now."
        return Decision(need: need, place: place, line: line, isLearned: learned)
    }

    /// What the bird would choose on its own, given nothing but the map and the clock. Used
    /// by the "do what you think I want" beat: needs are checked in a fixed order and the
    /// first one the map can answer wins, so the branch taken is always explainable.
    public static func strongestNeed(in map: SemanticMap, order: [Need] = Need.allCases) -> Need? {
        order.first { place(for: $0, in: map) != nil }
    }

    /// Everything it has been taught, phrased as a sentence rather than a list. Built from
    /// the map at speak time: reset the room and this shortens.
    public static func inventory(of map: SemanticMap) -> String {
        let learned = Need.allCases.compactMap { need -> String? in
            guard let place = place(for: need, in: map) else { return nil }
            return "I \(need.verb) at \(place.name)"
        }
        var offLimits = map.rules.map(\.name)
        offLimits.append(contentsOf: PerchMemory.avoided(in: map).map(\.name))
        if learned.isEmpty, offLimits.isEmpty {
            return "Nothing yet. This room is new to me."
        }
        var parts = learned
        if !offLimits.isEmpty {
            parts.append("and I stay off \(list(offLimits))")
        }
        return parts.joined(separator: ", ") + "."
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

public extension MapStore {
    /// Resolves and *counts* the visit in one call. The count is the learning: the bowl the
    /// bird is sent to most is the bowl it picks when nobody names one.
    @discardableResult
    func visit(_ need: Need) -> HabitMemory.Decision {
        let decision = HabitMemory.decide(need, in: map)
        if let place = decision.place {
            mutate { $0.noteUse(placeId: place.id) }
            record(
                Episode(
                    placeId: place.id,
                    kind: .visited,
                    summary: "went to \(place.name) to \(need.verb)"
                )
            )
        }
        return decision
    }

    func place(for need: Need) -> Place? { HabitMemory.place(for: need, in: map) }

    var inventory: String { HabitMemory.inventory(of: map) }
}
