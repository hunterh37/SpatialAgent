import AgentProtocol
import Foundation
import SceneUnderstanding
import SpatialMemory
import simd

/// Turns symbolic intent into something the renderer can execute.
///
/// This is the client half of the rule in docs/architecture.md §3b: the model emits intent,
/// never coordinates. Everything spatial is resolved here, against the navmesh and the place
/// table the *client* owns, so a hallucinated place name produces a clarifying question
/// rather than a character inside a wall.
public enum ResolvedDirective: Sendable, Equatable {
    case walk(path: [SIMD3<Float>])
    case look(at: SIMD3<Float>)
    case point(at: SIMD3<Float>)
    case emote(Emotion)
    case gesture
    case idle
    /// The client could not resolve it. The character asks, from where it stands
    /// (spec/02-interaction.md) — it does not walk first and ask later.
    case unresolved(reason: UnresolvedReason)
}

public enum UnresolvedReason: Sendable, Equatable {
    case unknownPlace(String)
    case unreachable(String)
    case unknownDevice(String)
    case missingScene
    /// Two or more taught things are equally plausible referents for "that". The bird asks
    /// which, because acting on the wrong device is a worse outcome than a question.
    case ambiguousReference([String])
    /// "That" with nothing looked at and nothing recent to mean.
    case nothingReferenced
}

/// What "that" turned out to mean (spec 07 §Learned behavior, deixis).
public enum DeicticResolution: Sendable, Equatable {
    case object(MapObject)
    /// More than one taught thing is in reach of the gaze.
    case ambiguous([MapObject])
    case none
}

public struct DirectiveResolver: Sendable {
    public init() {}

    /// How far from the gaze hit a taught object may be and still be what was meant.
    public static let deicticRadius: Float = 0.45
    /// Two candidates within this much of each other are a question, not a ranking.
    public static let ambiguityMargin: Float = 0.15

    /// Resolves "that" against gaze and the taught object table.
    ///
    /// This is what closes item 4 of docs/middle-layer-todo.md without putting a coordinate
    /// on the wire: the model says `deviceId: "that"`, and the binding between a thing in the
    /// room and a device id lives in `SpatialMemory` on the client. A near-tie is deliberately
    /// a question rather than a best guess — the whole point of a device binding is that the
    /// bird acts on the thing the user meant.
    public func resolveDeixis(
        gaze: SIMD3<Float>?,
        objects: [MapObject],
        radius: Float = DirectiveResolver.deicticRadius
    ) -> DeicticResolution {
        guard let gaze else { return .none }
        let ranked = objects
            .map { ($0, simd_length(SIMD3($0.position.x - gaze.x, 0, $0.position.z - gaze.z))) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return .none }
        let contenders = ranked.filter { $0.1 - best.1 <= Self.ambiguityMargin }
        if contenders.count > 1 { return .ambiguous(contenders.map(\.0)) }
        return .object(best.0)
    }

    /// True when the model's device reference is deictic rather than an id it read off the
    /// device list.
    public static func isDeictic(_ reference: String?) -> Bool {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return ["that", "this", "it", "that one", "this one"].contains(reference)
    }

    public func resolve(
        _ directive: CharacterDirective,
        characterPosition: SIMD3<Float>,
        userPosition: SIMD3<Float>,
        places: [Place],
        devicePositions: [String: SIMD3<Float>],
        navMesh: NavMesh?,
        objects: [MapObject] = [],
        gaze: SIMD3<Float>? = nil
    ) -> ResolvedDirective {
        // "Turn *that* off" is resolved here, against gaze plus the taught object table,
        // before anything looks at the device id as an id.
        var directive = directive
        if Self.isDeictic(directive.deviceId) {
            switch resolveDeixis(gaze: gaze, objects: objects) {
            case let .object(object):
                guard let deviceId = object.deviceId else {
                    return .unresolved(reason: .unknownDevice(object.name))
                }
                directive.deviceId = deviceId
            case let .ambiguous(candidates):
                return .unresolved(reason: .ambiguousReference(candidates.map(\.name)))
            case .none:
                return .unresolved(reason: .nothingReferenced)
            }
        }

        switch directive.kind {
        case .idle:
            return .idle

        case .emote:
            return .emote(directive.emotion ?? .neutral)

        case .gesture:
            return .gesture

        case .lookAt:
            switch directive.target {
            case .user, .none:
                return .look(at: userPosition)
            case .place:
                guard let name = directive.place else {
                    return .unresolved(reason: .unknownPlace(""))
                }
                guard let place = lookup(name, in: places) else {
                    return .unresolved(reason: .unknownPlace(name))
                }
                return .look(at: place.position)
            case .device:
                guard let id = directive.deviceId, let p = devicePositions[id] else {
                    return .unresolved(reason: .unknownDevice(directive.deviceId ?? ""))
                }
                return .look(at: p)
            }

        case .point:
            if let id = directive.deviceId {
                guard let p = devicePositions[id] else {
                    return .unresolved(reason: .unknownDevice(id))
                }
                return .point(at: p)
            }
            if let name = directive.place {
                guard let place = lookup(name, in: places) else {
                    return .unresolved(reason: .unknownPlace(name))
                }
                return .point(at: place.position)
            }
            return .point(at: userPosition)

        case .walkTo:
            guard let navMesh else { return .unresolved(reason: .missingScene) }
            let target: SIMD3<Float>
            if let name = directive.place {
                guard let place = lookup(name, in: places) else {
                    return .unresolved(reason: .unknownPlace(name))
                }
                target = place.position
            } else if let id = directive.deviceId {
                guard let p = devicePositions[id] else {
                    return .unresolved(reason: .unknownDevice(id))
                }
                target = p
            } else {
                return .unresolved(reason: .unknownPlace(""))
            }

            // Every path is clamped to reachable floor. The worst failure is the character
            // standing still, never walking through the couch (docs/architecture.md §4).
            guard let path = navMesh.path(from: characterPosition, to: target) else {
                return .unresolved(reason: .unreachable(directive.place ?? directive.deviceId ?? ""))
            }
            return .walk(path: path)
        }
    }

    /// Case-insensitive exact match only. Fuzzy matching here would reintroduce guessing at
    /// exactly the layer spec 07 forbids it: an unknown name becomes a question.
    private func lookup(_ name: String, in places: [Place]) -> Place? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return places.first { $0.nameKey == key }
    }
}

public extension UnresolvedReason {
    /// Spoken in character, never an error dialog or a code (spec/02-interaction.md).
    var spokenLine: String {
        switch self {
        case let .unknownPlace(name) where !name.isEmpty:
            return "I don't know where \"\(name)\" is yet. Want to show me?"
        case .unknownPlace:
            return "Where do you want me to go?"
        case let .unreachable(name):
            return "I can't find a way over to the \(name) from here."
        case .unknownDevice:
            return "I don't know which device that is."
        case let .ambiguousReference(names) where names.count >= 2:
            return "The \(names[0]) or the \(names[1])?"
        case .ambiguousReference:
            return "Which one do you mean?"
        case .nothingReferenced:
            return "Which one? Look at it and say that again."
        case .missingScene:
            return "I'm still working out the shape of the room."
        }
    }
}
