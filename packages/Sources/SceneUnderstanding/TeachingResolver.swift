import Foundation
import SpatialMemory
import simd

/// The teaching acts of spec 07 §Teaching, named as the server names them.
public enum TeachingAct: String, CaseIterable, Sendable {
    case namePlace = "name_place"
    case nameObject = "name_object"
    case forbidRegion = "forbid_region"
    case nameActivity = "name_activity"
    case correctName = "correct_name"
    case setHomePerch = "set_home_perch"

    /// Whether the act needs somewhere to have been looked at. Correcting a name re-targets
    /// the most recent referent, so it is the one act that works with no gaze at all.
    public var needsGaze: Bool { needsGaze(place: nil) }

    /// Whether the act needs gaze *given what the server supplied*. Naming an existing place
    /// as the perch is a promotion of a record that already has a position, so asking the
    /// user to look somewhere would be asking for something already known.
    public func needsGaze(place: String?) -> Bool {
        switch self {
        case .correctName: return false
        case .setHomePerch:
            return (place ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }
}

/// What happened, in enough detail for the bird to say it back.
public enum TeachingOutcome: Equatable, Sendable {
    /// A new record. The bird says the name back.
    case taught(TeachingAct, name: String, id: UUID)
    /// The name already existed and was updated. The bird says so — "that's the kitchen now".
    case corrected(TeachingAct, name: String, id: UUID)
    /// Gaze had no valid hit. The act stays open for one follow-up turn.
    case needsGaze
    /// Naming inside an existing place: ask once, with exactly two answers (C4).
    case needsDisambiguation(existing: Place, name: String, act: TeachingAct)
    case failed(String)
}

/// Turns a teaching tool call into a map record.
///
/// The server states the act and the name; everything spatial happens here. That split is
/// why a coordinate never has to leave the device for teaching to work
/// (spec 07 §Enforcement).
@MainActor
public final class TeachingResolver {
    private let store: MapStore
    private let gaze: GazeCapture
    private let anchors: AnchorBinding?

    /// The record the last act touched. `correct_name` re-targets this one.
    public private(set) var mostRecentReferent: UUID?

    public init(store: MapStore, gaze: GazeCapture, anchors: AnchorBinding? = nil) {
        self.store = store
        self.gaze = gaze
        self.anchors = anchors
    }

    /// Applies an act. `hard` only matters for `forbid_region`; `place` only for
    /// `set_home_perch`, where it names a place that may already exist.
    public func apply(
        _ act: TeachingAct,
        name: String,
        deviceId: String? = nil,
        hard: Bool = true,
        allowNesting: Bool = false,
        place: String? = nil
    ) async -> TeachingOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if act == .correctName {
            return correct(to: trimmed)
        }

        if act == .setHomePerch {
            return await perch(named: place?.isEmpty == false ? place : (trimmed.isEmpty ? nil : trimmed))
        }

        guard let target = gaze.target() else { return .needsGaze }
        guard !trimmed.isEmpty || act == .forbidRegion else {
            return .failed("no name was heard")
        }

        // Naming inside an existing place is a question, not an overwrite (spec 07
        // §Disambiguation). Asked once, and only when this is a new name.
        if act == .namePlace, !allowNesting,
           let existing = store.map.needsDisambiguation(naming: trimmed, at: target.point) {
            return .needsDisambiguation(existing: existing, name: trimmed, act: act)
        }

        let anchorId = await anchors?.anchor(at: target.point)
        let relocalized = anchors?.hasRelocalized(anchorId) ?? true

        switch act {
        case .namePlace:
            let place = Place(
                name: trimmed,
                position: target.point,
                radius: target.radius,
                kind: kind(for: target),
                anchorId: anchorId,
                hasRelocalized: relocalized
            )
            return finish(act, name: trimmed, outcome: store.add(place))

        case .nameObject:
            let object = MapObject(
                name: trimmed,
                position: target.point,
                deviceId: deviceId,
                placeId: store.map.containingPlace(of: target.point)?.id,
                anchorId: anchorId,
                hasRelocalized: relocalized
            )
            return finish(act, name: trimmed, outcome: store.add(object))

        case .forbidRegion:
            let label = trimmed.isEmpty ? "there" : trimmed
            let rule = Rule(
                name: label,
                kind: hard ? .forbidden : .fragile,
                severity: hard ? .hard : .soft,
                position: target.point,
                radius: target.radius,
                anchorId: anchorId,
                hasRelocalized: relocalized
            )
            return finish(act, name: label, outcome: store.add(rule))

        case .nameActivity:
            // Bound to the containing place when there is one, and to a new place named
            // after the activity when there is not — an activity with nowhere to happen is
            // not something the bird can ever act on.
            var placeId = store.map.containingPlace(of: target.point)?.id
            if placeId == nil {
                let place = Place(
                    name: trimmed,
                    position: target.point,
                    radius: target.radius,
                    kind: .workspace,
                    anchorId: anchorId,
                    hasRelocalized: relocalized
                )
                switch store.add(place) {
                case let .created(id), let .corrected(id): placeId = id
                }
            }
            let activity = Activity(name: trimmed, placeId: placeId)
            return finish(act, name: trimmed, outcome: store.add(activity))

        case .correctName, .setHomePerch:
            return .failed("unreachable")
        }
    }

    // MARK: - Perch

    /// How near the gaze point has to be to an existing perch for "this is your perch" to
    /// mean that one. Generous, because the user is looking at a pole from across a room.
    private static let perchBindRadius: Float = 0.75

    /// "this is your perch".
    ///
    /// This act never invents a name. The room's perches are the three coloured presets and
    /// the learned-choice line says one of those names out loud, so a record called
    /// anything else is a perch the audience cannot see referred to. In order: the perch the
    /// user is looking at, then the next coloured preset that has not been placed yet, and
    /// only when all three are down does the looked-at place get promoted under its own name.
    private func perch(named requested: String?) async -> TeachingOutcome {
        let wanted = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !wanted.isEmpty, let existing = store.map.place(named: wanted) {
            return bind(to: existing)
        }

        guard let target = gaze.target() else { return .needsGaze }

        // Looking at a perch is a reference to it, not a request for another one.
        let near = store.map.perches
            .filter { simd_distance($0.position, target.point) <= max($0.radius, Self.perchBindRadius) }
            .min { simd_distance($0.position, target.point) < simd_distance($1.position, target.point) }
        if let near {
            return bind(to: near)
        }

        let anchorId = await anchors?.anchor(at: target.point)
        let relocalized = anchors?.hasRelocalized(anchorId) ?? true

        // Adopting the next unplaced preset gives the new perch a colour the user can say
        // and the prop the checklist would have drawn: name, height and tint all come from
        // `LandmarkPreset`, and the placer keys the prop off the name.
        if let preset = LandmarkPreset.perches.first(where: { store.map.place(named: $0.name) == nil }) {
            let outcome = store.add(
                Place(
                    name: preset.name,
                    position: target.point,
                    radius: target.radius,
                    kind: preset.kind,
                    anchorId: anchorId,
                    hasRelocalized: relocalized,
                    elevation: preset.height
                )
            )
            return finish(.setHomePerch, name: preset.name, outcome: outcome)
        }

        // All three colours are down, so this is the user calling something else a perch.
        // The record keeps the name they taught it; nothing new is named here either.
        guard let existing = store.map.containingPlace(of: target.point) else {
            return .failed("all three perches are already placed")
        }
        return bind(to: existing)
    }

    /// Promotes an existing record to a perch and reports it. No rename, ever.
    private func bind(to place: Place) -> TeachingOutcome {
        store.setHomePerch(id: place.id)
        gaze.endAct()
        mostRecentReferent = place.id
        store.record(
            Episode(
                placeId: place.id,
                kind: .taught,
                summary: "\(TeachingAct.setHomePerch.rawValue): \(place.name)"
            )
        )
        return .corrected(.setHomePerch, name: place.name, id: place.id)
    }

    /// Resolves a disambiguation the user answered with "nest it inside".
    public func nest(name: String, act: TeachingAct, deviceId: String? = nil) async
        -> TeachingOutcome {
        // Nesting a place under a place is an object inside it: the user wanted a thing in
        // the study, not a second study.
        await apply(.nameObject, name: name, deviceId: deviceId)
    }

    /// Resolves a disambiguation the user answered with "rename the existing one".
    public func rename(existing: Place, to name: String) -> TeachingOutcome {
        let renamed = store.mutate { $0.rename(placeId: existing.id, to: name) }
        guard renamed else { return .failed("that name is already taken by something else") }
        mostRecentReferent = existing.id
        store.record(
            Episode(placeId: existing.id, kind: .taught, summary: "renamed to \(name)")
        )
        return .corrected(.correctName, name: name, id: existing.id)
    }

    // MARK: - Correction

    /// "no, that's the kitchen" re-targets the most recent referent.
    private func correct(to name: String) -> TeachingOutcome {
        guard !name.isEmpty else { return .failed("no name was heard") }
        guard let id = mostRecentReferent else {
            return .failed("there is nothing recent to correct")
        }
        if let place = store.map.place(id: id) {
            return rename(existing: place, to: name)
        }
        let renamed = store.mutate { $0.rename(objectId: id, to: name) }
        guard renamed else { return .failed("that name is already taken by something else") }
        store.record(Episode(objectId: id, kind: .taught, summary: "renamed to \(name)"))
        return .corrected(.correctName, name: name, id: id)
    }

    // MARK: - Helpers

    private func finish(
        _ act: TeachingAct,
        name: String,
        outcome: SemanticMap.Outcome
    ) -> TeachingOutcome {
        gaze.endAct()
        switch outcome {
        case let .created(id):
            mostRecentReferent = id
            store.record(Episode(kind: .taught, summary: "\(act.rawValue): \(name)"))
            return .taught(act, name: name, id: id)
        case let .corrected(id):
            mostRecentReferent = id
            store.record(Episode(kind: .taught, summary: "\(act.rawValue) corrected: \(name)"))
            return .corrected(act, name: name, id: id)
        }
    }

    private func kind(for target: GazeTarget) -> PlaceKind {
        switch target.surface {
        case .floor: return .floor
        case .surface: return .surface
        case .objectCluster: return .generic
        }
    }
}
