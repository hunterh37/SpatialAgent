import AgentProtocol
import Foundation

/// The state machine from spec/01-character.md, as a value type with no RealityKit in it.
///
///     idle ─▶ turning ─▶ walking ─▶ arriving ─▶ idle
///       │                                        ▲
///       ├─▶ listening ─▶ thinking ─▶ speaking ───┤
///       └─▶ gesturing ───────────────────────────┘
///
/// It is a state machine rather than a pile of `if`s precisely so the illegal transitions
/// are unrepresentable and testable without a headset.
public enum CharacterState: String, Sendable, Hashable, CaseIterable {
    case idle, turning, walking, arriving
    case listening, thinking, speaking, gesturing
}

public enum CharacterEvent: Sendable, Hashable {
    case addressed          // gaze acquired, or the text field focused
    case utteranceEnded     // user finished; `thinking` must be enterable within 400ms
    case firstToken         // model produced something
    case speechEnded
    case pathAccepted       // navmesh returned a path
    case turnComplete
    case arrived
    case settled
    case gestureStarted
    case gestureEnded
    case interrupted
}

public struct CharacterStateMachine: Sendable {
    public private(set) var state: CharacterState = .idle
    /// Crossfade duration for the transition just taken. Every transition crossfades;
    /// no hard cuts (spec/01-character.md).
    public private(set) var lastCrossfade: TimeInterval = 0.25

    public init() {}

    @discardableResult
    public mutating func handle(_ event: CharacterEvent) -> CharacterState {
        let next: CharacterState?
        switch (state, event) {
        case (_, .interrupted):
            next = .idle
        case (_, .addressed):
            // Addressing wins from any state: the character must show it is being addressed
            // before the utterance ends (spec/02-interaction.md).
            next = .listening
        case (.listening, .utteranceEnded):
            next = .thinking
        case (_, .utteranceEnded):
            next = .thinking
        case (.thinking, .firstToken), (.walking, .firstToken), (.arriving, .firstToken):
            next = .speaking
        case (.idle, .firstToken), (.turning, .firstToken), (.listening, .firstToken):
            next = .speaking
        case (.speaking, .speechEnded):
            next = .idle
        case (.idle, .pathAccepted), (.speaking, .pathAccepted), (.thinking, .pathAccepted),
             (.listening, .pathAccepted), (.arriving, .pathAccepted):
            next = .turning
        case (.turning, .turnComplete):
            next = .walking
        case (.walking, .arrived):
            next = .arriving
        case (.arriving, .settled):
            next = .idle
        case (_, .gestureStarted):
            next = .gesturing
        case (.gesturing, .gestureEnded):
            next = .idle
        default:
            next = nil
        }

        if let next, next != state {
            lastCrossfade = Self.crossfade(from: state, to: next)
            state = next
        }
        return state
    }

    /// 0.2–0.3s per spec. Entering `thinking` is the short end because it has a 400ms
    /// budget from end-of-utterance and the crossfade is inside it.
    static func crossfade(from: CharacterState, to: CharacterState) -> TimeInterval {
        switch to {
        case .thinking, .listening: return 0.2
        case .walking, .turning: return 0.25
        default: return 0.3
        }
    }
}
