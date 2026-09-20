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
}

public struct DirectiveResolver: Sendable {
    public init() {}

    public func resolve(
        _ directive: CharacterDirective,
        characterPosition: SIMD3<Float>,
        userPosition: SIMD3<Float>,
        places: [Place],
        devicePositions: [String: SIMD3<Float>],
        navMesh: NavMesh?
    ) -> ResolvedDirective {
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
        case .missingScene:
            return "I'm still working out the shape of the room."
        }
    }
}
