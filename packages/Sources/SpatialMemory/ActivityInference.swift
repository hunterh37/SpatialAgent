import Foundation
import simd

/// Turns episodes into time-of-day bands, and bands into a behavior switch.
///
/// Spec 07 §Learned behavior: in a place tagged with an activity, during that activity's
/// observed band, the bird settles and goes quiet instead of following. This is the payoff
/// for "this is where I brainstorm", and it has to be observable within a few sessions or
/// the feature is not earning its complexity — which is why bands come from what actually
/// happened rather than from anything the user was asked to type.
public enum ActivityInference {
    /// One visit is not a habit. Two at the same hour on different days is the smallest
    /// thing worth changing behavior over.
    public static let minimumObservations = 2
    /// Episodes closer together than this are the same band.
    public static let clusterGapMinutes = 90
    /// A band is padded either side of what was observed, so arriving ten minutes early
    /// does not read as a different activity.
    public static let bandPaddingMinutes = 30

    // MARK: Band formation

    /// Bands for one place, from the episodes that happened in it.
    public static func bands(
        from episodes: [Episode],
        placeId: UUID,
        calendar: Calendar = .current
    ) -> [Activity.Band] {
        let minutes = episodes
            .filter { $0.placeId == placeId && $0.kind == .visited }
            .map { minuteOfDay(of: $0.timestamp, calendar: calendar) }
            .sorted()
        guard !minutes.isEmpty else { return [] }

        var clusters: [[Int]] = [[minutes[0]]]
        for minute in minutes.dropFirst() {
            if minute - (clusters[clusters.count - 1].last ?? minute) <= clusterGapMinutes {
                clusters[clusters.count - 1].append(minute)
            } else {
                clusters.append([minute])
            }
        }

        return clusters.compactMap { cluster in
            guard cluster.count >= minimumObservations else { return nil }
            return Activity.Band(
                startMinute: max(0, (cluster.first ?? 0) - bandPaddingMinutes),
                endMinute: min(1439, (cluster.last ?? 0) + bandPaddingMinutes),
                observations: cluster.count
            )
        }
    }

    /// Recomputes every activity's bands from the episode history.
    ///
    /// Idempotent and total rather than incremental: episodes are the record of what
    /// happened, so deriving from all of them means a deleted episode actually un-learns the
    /// habit it contributed to. An incremental counter would keep a band the user erased.
    public static func learn(in map: inout SemanticMap, calendar: Calendar = .current) {
        let episodes = map.episodes
        for index in map.activities.indices {
            guard let placeId = map.activities[index].placeId else { continue }
            let learned = bands(from: episodes, placeId: placeId, calendar: calendar)
            guard !learned.isEmpty else { continue }
            map.activities[index].bands = learned
        }
    }

    // MARK: The behavior switch

    /// What the bird should do about the user right now.
    public enum Response: Equatable, Sendable {
        /// Stay with the user: the default, and what an unmapped room always produces.
        case follow
        /// Settle nearby and go quiet, because the user is doing the thing they told the
        /// bird about.
        case settle(activity: String)
    }

    /// Follow or settle, from where the user is and what time it is.
    public static func response(
        forUserAt position: SIMD3<Float>,
        in map: SemanticMap,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Response {
        let minute = minuteOfDay(of: now, calendar: calendar)
        guard let place = map.containingPlace(of: position) else { return .follow }
        // A `quiet` rule over the same spot says the same thing more strongly, but it is a
        // rule rather than an inference and it is handled where rules are enforced.
        let active = map.activities.first {
            $0.placeId == place.id && $0.isActive(atMinute: minute)
        }
        guard let active else { return .follow }
        return .settle(activity: active.name)
    }

    /// Records that the user was somewhere, which is the raw material bands are made of.
    public static func noteVisit(
        to place: Place,
        at date: Date = Date(),
        in map: inout SemanticMap
    ) {
        map.record(
            Episode(
                timestamp: date,
                placeId: place.id,
                kind: .visited,
                summary: "user in \(place.name)"
            )
        )
    }

    static func minuteOfDay(of date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}
