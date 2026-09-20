import Foundation
import SpatialMemory
import simd

/// The five teaching acts of spec 07 §Teaching, named as the server names them.
public enum TeachingAct: String, CaseIterable, Sendable {
    case namePlace = "name_place"
    case nameObject = "name_object"
    case forbidRegion = "forbid_region"
    case nameActivity = "name_activity"
    case correctName = "correct_name"

    /// Whether the act needs somewhere to have been looked at. Correcting a name re-targets
    /// the most recent referent, so it is the one act that works with no gaze at all.
    public var needsGaze: Bool { self != .correctName }
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

    /// Applies an act. `hard` only matters for `forbid_region`.
    public func apply(
        _ act: TeachingAct,
        name: String,
        deviceId: String? = nil,
        hard: Bool = true,
        allowNesting: Bool = false
    ) async -> TeachingOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if act == .correctName {
            return correct(to: trimmed)
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

        case .correctName:
            return .failed("unreachable")
        }
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
