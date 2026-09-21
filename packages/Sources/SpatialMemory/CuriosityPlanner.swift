import Foundation
import simd

/// What the bird asks about, and — much more importantly — how rarely.
///
/// Spec 07 §Curiosity. The budget is a product requirement (PRD §9), not a tuning knob: a
/// creature that asks a question every few minutes is a creature people turn off. Every
/// clause below is enforced here rather than left to the prompt, because a prompt-level
/// budget is a budget that a bad sample ignores.
public struct CuriosityPlanner: Codable, Sendable {
    // MARK: The budget (PRD §9)

    /// At most one question per 10 minutes.
    public static let minimumGap: TimeInterval = 10 * 60
    /// At most 4 per session.
    public static let perSessionLimit = 4
    /// Never within 30s of a user utterance.
    public static let utteranceQuiet: TimeInterval = 30
    /// A declined or ignored question suppresses that candidate for 7 days.
    public static let suppression: TimeInterval = 7 * 24 * 60 * 60
    /// Two ignores in a session stops questions for the rest of it.
    public static let ignoreLimit = 2
    /// A question is asked from next to the thing: "what's this?" from across the room is
    /// unanswerable and is therefore not a question, it is noise.
    public static let askingDistance: Float = 0.8

    /// What the bird could ask about.
    public struct Candidate: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            /// A region the user keeps standing in that has no name.
            case unnamedRegion
            /// A device with no spatial binding: it exists in the home and nowhere in the room.
            case unboundDevice
            /// A place with no activity attached.
            case placeWithoutActivity
        }

        public var id: String
        public var kind: Kind
        public var position: SIMD3<Float>
        /// What the bird says. Filled by the caller so the wording stays out of the budget.
        public var subject: String

        public init(id: String, kind: Kind, position: SIMD3<Float>, subject: String) {
            self.id = id
            self.kind = kind
            self.position = position
            self.subject = subject
        }
    }

    // MARK: State

    /// Candidates already asked about, ever. Never twice about the same one.
    public private(set) var asked: Set<String> = []
    /// Candidate id -> when its suppression ends.
    public private(set) var suppressedUntil: [String: Date] = [:]
    public private(set) var lastAskedAt: Date?
    public private(set) var askedThisSession = 0
    public private(set) var ignoredThisSession = 0
    public private(set) var lastUtteranceAt: Date?

    public init() {}

    // MARK: Session lifecycle

    /// A new session resets the per-session counters and nothing else: suppression and the
    /// never-twice rule outlive the app being closed, which is the point of them.
    public mutating func beginSession() {
        askedThisSession = 0
        ignoredThisSession = 0
    }

    public mutating func noteUtterance(at date: Date = Date()) {
        lastUtteranceAt = date
    }

    public mutating func noteAsked(_ candidate: Candidate, at date: Date = Date()) {
        asked.insert(candidate.id)
        lastAskedAt = date
        askedThisSession += 1
    }

    /// The user said no. That candidate is done for a week.
    public mutating func noteDeclined(_ candidate: Candidate, at date: Date = Date()) {
        suppressedUntil[candidate.id] = date.addingTimeInterval(Self.suppression)
    }

    /// The user said nothing at all. Same suppression, plus it counts toward the stop.
    public mutating func noteIgnored(_ candidate: Candidate, at date: Date = Date()) {
        suppressedUntil[candidate.id] = date.addingTimeInterval(Self.suppression)
        ignoredThisSession += 1
    }

    /// Two ignores and the bird stops asking for the rest of the session.
    public var isStoppedForSession: Bool { ignoredThisSession >= Self.ignoreLimit }

    // MARK: The gate

    /// Why a question was not asked. Returned rather than a bare nil so the reason is
    /// testable one clause at a time.
    public enum Refusal: Equatable, Sendable {
        case tooSoon
        case sessionLimitReached
        case tooSoonAfterAnUtterance
        case insideAQuietRule
        case stoppedAfterIgnores
        case nothingToAskAbout
    }

    /// Whether a question may be asked at all, independent of what it would be about.
    public func budgetAllows(now: Date, userPosition: SIMD3<Float>, map: SemanticMap) -> Refusal? {
        if isStoppedForSession { return .stoppedAfterIgnores }
        if askedThisSession >= Self.perSessionLimit { return .sessionLimitReached }
        if let last = lastAskedAt, now.timeIntervalSince(last) < Self.minimumGap {
            return .tooSoon
        }
        if let spoken = lastUtteranceAt, now.timeIntervalSince(spoken) < Self.utteranceQuiet {
            return .tooSoonAfterAnUtterance
        }
        if !map.rules(containing: userPosition, kind: .quiet).isEmpty {
            return .insideAQuietRule
        }
        return nil
    }

    /// The next question, or nil. Candidates are ranked by proximity to what the user is
    /// attending to, then by kind.
    public func next(
        from candidates: [Candidate],
        now: Date = Date(),
        userPosition: SIMD3<Float>,
        attention: SIMD3<Float>? = nil,
        map: SemanticMap
    ) -> Candidate? {
        guard budgetAllows(now: now, userPosition: userPosition, map: map) == nil else {
            return nil
        }
        let focus = attention ?? userPosition
        return candidates
            .filter { isEligible($0, now: now) }
            .min { rank($0, focus: focus) < rank($1, focus: focus) }
    }

    /// Whether one candidate is allowed, ignoring the session-wide budget.
    public func isEligible(_ candidate: Candidate, now: Date = Date()) -> Bool {
        if asked.contains(candidate.id) { return false }
        if let until = suppressedUntil[candidate.id], now < until { return false }
        return true
    }

    /// The question is asked from next to the thing, looking at it, so the plan carries
    /// where to stand.
    public func isCloseEnoughToAsk(_ candidate: Candidate, birdPosition: SIMD3<Float>) -> Bool {
        simd_length(
            SIMD3(
                candidate.position.x - birdPosition.x,
                0,
                candidate.position.z - birdPosition.z
            )
        ) <= Self.askingDistance
    }

    private func rank(_ candidate: Candidate, focus: SIMD3<Float>) -> Float {
        let distance = simd_length(
            SIMD3(candidate.position.x - focus.x, 0, candidate.position.z - focus.z)
        )
        // Kind is a tiebreak, not the primary term: what the user is looking at beats what
        // the bird finds structurally interesting.
        let kindWeight: Float
        switch candidate.kind {
        case .unnamedRegion: return distance
        case .unboundDevice: kindWeight = 0.5
        case .placeWithoutActivity: kindWeight = 1.0
        }
        return distance + kindWeight
    }

    // MARK: Candidate generation

    /// Candidates the map itself implies: devices with no object bound to them, and taught
    /// places with no activity attached.
    public static func candidates(
        in map: SemanticMap,
        deviceIds: [String: String] = [:],
        unnamedRegions: [SIMD3<Float>] = []
    ) -> [Candidate] {
        var out: [Candidate] = []

        let bound = Set(map.objects.compactMap(\.deviceId))
        for (id, name) in deviceIds.sorted(by: { $0.key < $1.key }) where !bound.contains(id) {
            // No position: the whole question is "where is this?", asked from the user.
            out.append(
                Candidate(id: "device:\(id)", kind: .unboundDevice, position: .zero, subject: name)
            )
        }

        let placesWithActivities = Set(map.activities.compactMap(\.placeId))
        for place in map.places where !placesWithActivities.contains(place.id) {
            out.append(
                Candidate(
                    id: "place:\(place.id.uuidString)",
                    kind: .placeWithoutActivity,
                    position: place.position,
                    subject: place.name
                )
            )
        }

        for (index, region) in unnamedRegions.enumerated() where map.containingPlace(of: region) == nil {
            out.append(
                Candidate(
                    id: "region:\(index)",
                    kind: .unnamedRegion,
                    position: region,
                    subject: "that spot"
                )
            )
        }
        return out
    }
}
