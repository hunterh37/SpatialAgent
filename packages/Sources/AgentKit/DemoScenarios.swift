import AgentProtocol
import Foundation
import SpatialMemory

/// One step of a scripted demo beat.
///
/// A beat exists so a chip is not only an utterance: with no Mac attached there is no model
/// to answer and no directive to make the bird move, and a demo that needs a laptop on the
/// same Wi-Fi is a demo that does not happen. The actions replay exactly what the server
/// would have sent — `CharacterDirective`s and spoken lines — through the same client path,
/// so nothing downstream can tell a scripted beat from a live one.
public enum DemoAction: Hashable, Sendable {
    /// Spoken in character, into the transcript.
    case say(String)
    /// Replayed through the resolver exactly as a server directive is.
    case directive(CharacterDirective)
    /// Wall-clock beat, so a flight lands before the next line is spoken.
    case pause(TimeInterval)
    /// Places a `LandmarkPreset` by id, so a teaching chip really writes the map.
    case teach(preset: String)
    /// Flips a mock device, so "turn on the desk lamp" changes something visible.
    case device(id: String, on: Bool)
    /// The beat that is a decision rather than a line: resolve a need against the map, say
    /// what was found and why, then fly there and count the visit. With the landmark
    /// missing it asks to be shown instead, which is the same code path saying "I don't
    /// know" — and the only reason an audience believes the rest.
    case satisfy(Need)
    /// Speaks the map back, built at speak time. Reset the room and this sentence shortens.
    case inventory
    /// Picks the need itself, then satisfies it. No landmark and no need in the utterance.
    case decide
    /// The beat that is a *learned* choice rather than a lookup: pick one of three identical
    /// perches, say why that one, and fly up onto it. Tap it repeatedly and knock him off
    /// between taps and the answer moves — which is the only way an audience can tell
    /// learning from a lookup table.
    case perch
    /// Clears the knock-off counts without touching the perches. "Forgive me", on a chip,
    /// so the learning demo can be run twice in one session.
    case forgetKnockOffs
}

public extension DemoAction {
    static func walk(to place: String) -> DemoAction {
        .directive(CharacterDirective(kind: .walkTo, place: place, target: .place))
    }

    static func look(at place: String) -> DemoAction {
        .directive(CharacterDirective(kind: .lookAt, place: place, target: .place))
    }

    static func point(at place: String) -> DemoAction {
        .directive(CharacterDirective(kind: .point, place: place, target: .place))
    }

    static var lookAtUser: DemoAction {
        .directive(CharacterDirective(kind: .lookAt, target: .user))
    }

    static func emote(_ emotion: Emotion) -> DemoAction {
        .directive(CharacterDirective(kind: .emote, emotion: emotion))
    }

    static var gesture: DemoAction { .directive(CharacterDirective(kind: .gesture)) }
}

/// Canned utterances for a demo, sent verbatim through `AgentSession.send(utterance:)` when a
/// server is attached, and replayed from `script` when one is not.
///
/// They are data, not a second input path: a chip produces exactly the string a person would
/// have typed. That is the whole reason this is a list of strings rather than a set of direct
/// tool calls.
///
/// The order is the story: teach the room, ask what it remembers, ask it to act, then show
/// that the memory is about the person and not only the room.
public struct DemoPrompt: Identifiable, Hashable, Sendable {
    /// Chip text.
    public let label: String
    /// What is actually sent. Often longer than the label.
    public let utterance: String
    /// Offline replay. Empty means the chip is talk-only and needs a server to do anything.
    public let script: [DemoAction]
    /// True when tapping the chip again is the point rather than a mistake. "Go perch" is
    /// the only one: the answer is supposed to change between taps.
    public let repeatable: Bool

    public var id: String { utterance }

    /// True when tapping this chip moves the bird even with nothing connected.
    public var movesTheBird: Bool {
        script.contains {
            if case let .directive(directive) = $0 {
                return directive.kind == .walkTo || directive.kind == .lookAt
                    || directive.kind == .point
            }
            switch $0 {
            case .teach, .satisfy, .decide, .perch: return true
            default: return false
            }
        }
    }

    public init(
        label: String,
        utterance: String? = nil,
        script: [DemoAction] = [],
        repeatable: Bool = false
    ) {
        self.label = label
        self.utterance = utterance ?? label
        self.script = script
        self.repeatable = repeatable
    }
}

public struct DemoScenarioGroup: Identifiable, Hashable, Sendable {
    public let title: String
    /// SF Symbol for the group header.
    public let symbol: String
    public let prompts: [DemoPrompt]

    public var id: String { title }

    public init(title: String, symbol: String, prompts: [DemoPrompt]) {
        self.title = title
        self.symbol = symbol
        self.prompts = prompts
    }
}

public enum DemoScenarios {
    /// Landmark names, spelled once. Every script target has to be a name the room actually
    /// holds, or the resolver answers with a question instead of a flight.
    public enum Landmark {
        // Perches are named by colour: the three are behaviourally identical, so the only
        // way to say which one the bird chose is to say what colour it is.
        public static let redPerch = "the red perch"
        public static let bluePerch = "the blue perch"
        public static let amberPerch = "the amber perch"
        public static let desk = "my desk"
        public static let food = "the food bowl"
        public static let water = "the water dish"
        public static let petting = "the petting spot"
        public static let toys = "the toy basket"
        public static let plant = "the plant"
    }

    /// Act one: the room means nothing yet, so every chip here writes a record. Each one
    /// places a real world-anchored landmark and the bird flies to it once, which is what
    /// makes the next act legible — it has been there before.
    public static let teach = DemoScenarioGroup(
        title: "Teach",
        symbol: "graduationcap.fill",
        prompts: [
            DemoPrompt(
                label: "These are your perches",
                utterance: "These three are yours",
                script: [
                    .lookAtUser,
                    .teach(preset: "perch-left"),
                    .teach(preset: "perch-middle"),
                    .teach(preset: "perch-right"),
                    .say("Three of them. Red, blue, amber — I'll work out which one I like."),
                    .look(at: Landmark.bluePerch),
                    .pause(0.5),
                    .perch,
                    .pause(2.2),
                    .emote(.happy),
                ]
            ),
            DemoPrompt(
                label: "You eat here",
                utterance: "This is where you eat",
                script: [
                    .lookAtUser,
                    .teach(preset: "food-bowl"),
                    .say("The bowl. Got it — this is where I eat."),
                    .look(at: Landmark.food),
                    .pause(0.5),
                    .walk(to: Landmark.food),
                    .pause(2.2),
                    .emote(.happy),
                ]
            ),
            DemoPrompt(
                label: "Your water is here",
                utterance: "This is your water dish",
                script: [
                    .teach(preset: "water-dish"),
                    .say("Water. Noted."),
                    .look(at: Landmark.water),
                    .pause(0.5),
                    .walk(to: Landmark.water),
                    .pause(2.0),
                ]
            ),
            DemoPrompt(
                label: "I pet you here",
                utterance: "This is where I pet you",
                script: [
                    .lookAtUser,
                    .teach(preset: "petting-spot"),
                    .say("Here? I'll remember that one."),
                    .walk(to: Landmark.petting),
                    .pause(2.2),
                    .emote(.happy),
                    .gesture,
                ]
            ),
            DemoPrompt(
                label: "Your toys live here",
                utterance: "This is where your toys are kept",
                script: [
                    .teach(preset: "toy-basket"),
                    .say("Toys. In the basket."),
                    .look(at: Landmark.toys),
                    .pause(0.5),
                    .walk(to: Landmark.toys),
                    .pause(2.2),
                    .emote(.happy),
                ]
            ),
            DemoPrompt(
                label: "Stay off the plant",
                utterance: "Don't go near the plant",
                script: [
                    .teach(preset: "plant"),
                    .look(at: Landmark.plant),
                    .say("Noted — the plant is off limits. I'll route around it."),
                    .pause(0.8),
                    .walk(to: Landmark.petting),
                    .pause(2.4),
                    .emote(.concerned),
                ]
            ),
        ]
    )

    /// Act two: nothing here names a landmark. Every destination is resolved out of the map
    /// by `HabitMemory`, so these chips answer differently after a reset — which is the
    /// difference between a demo and a cartoon.
    public static let needs = DemoScenarioGroup(
        title: "Needs",
        symbol: "brain.head.profile",
        prompts: [
            DemoPrompt(
                label: "Go eat",
                utterance: "You must be hungry",
                script: [.lookAtUser, .emote(.thinking), .pause(0.4), .satisfy(.hungry)]
            ),
            DemoPrompt(
                label: "Go get a drink",
                utterance: "Go get a drink",
                script: [.emote(.thinking), .pause(0.3), .satisfy(.thirsty)]
            ),
            DemoPrompt(
                label: "Go play",
                utterance: "Go find yourself a toy",
                script: [.emote(.happy), .pause(0.3), .satisfy(.bored)]
            ),
            DemoPrompt(
                label: "Come get pets",
                utterance: "Come get some pets",
                script: [.lookAtUser, .emote(.happy), .satisfy(.lonely)]
            ),
            DemoPrompt(
                label: "Go settle down",
                utterance: "Time to settle down",
                // `.satisfy(.sleepy)` rather than a bare `.perch`: settling has to go
                // through the need, or the chip flies him to a perch without the habit
                // memory ever being asked which one — which is the thing being demoed.
                script: [.emote(.thinking), .satisfy(.sleepy)]
            ),
        ]
    )

    /// Act two and a half: the aversion. Three perches, nothing to choose between them but
    /// what has happened to him on each, so this group is the only one in the demo whose
    /// answer the *audience* changes — with their hand, mid-run.
    public static let perches = DemoScenarioGroup(
        title: "Perches",
        symbol: "bird.fill",
        prompts: [
            DemoPrompt(
                label: "Go perch",
                utterance: "Go perch",
                script: [.lookAtUser, .emote(.thinking), .pause(0.3), .perch],
                repeatable: true
            ),
            DemoPrompt(
                label: "Which perches do you avoid?",
                utterance: "Why won't you sit there?",
                script: [.lookAtUser, .emote(.thinking), .pause(0.4), .inventory]
            ),
            DemoPrompt(
                label: "Forgive the swats",
                utterance: "Forget about that — try them all again",
                script: [
                    .forgetKnockOffs,
                    .say("...fine. Clean slate."),
                    .emote(.happy),
                    .pause(0.4),
                    .perch,
                ]
            ),
        ]
    )

    /// Act three: recall with nothing prompting the content. Both lines are built from the
    /// map when they are spoken.
    public static let recall = DemoScenarioGroup(
        title: "Recall",
        symbol: "text.book.closed.fill",
        prompts: [
            DemoPrompt(
                label: "What do you know?",
                utterance: "What have I taught you about this room?",
                script: [.lookAtUser, .emote(.thinking), .pause(0.5), .inventory, .lookAtUser]
            ),
            DemoPrompt(
                label: "Where do you eat?",
                script: [
                    .lookAtUser,
                    .emote(.thinking),
                    .pause(0.4),
                    .point(at: Landmark.food),
                    .satisfy(.hungry),
                ]
            ),
            DemoPrompt(
                label: "Do what you think I want",
                script: [.lookAtUser, .emote(.thinking), .pause(0.6), .decide]
            ),
        ]
    )

    /// Act four: the things that are still worth having on stage but do not touch memory.
    public static let act = DemoScenarioGroup(
        title: "Act",
        symbol: "figure.walk",
        prompts: [
            DemoPrompt(
                label: "Go to my desk",
                script: [
                    .lookAtUser,
                    .say("On my way."),
                    .walk(to: Landmark.desk),
                    .pause(2.4),
                    .emote(.happy),
                ]
            ),
            DemoPrompt(
                label: "Turn on the desk lamp",
                script: [
                    .look(at: Landmark.desk),
                    .say("Desk lamp on."),
                    .walk(to: Landmark.desk),
                    .pause(2.0),
                    .device(id: "light.desk", on: true),
                    .point(at: Landmark.desk),
                    .emote(.happy),
                ]
            ),
        ]
    )

    public static let all: [DemoScenarioGroup] = [teach, needs, perches, recall, act]

    /// Every utterance, flattened. Used by tests to assert the list stays sendable.
    public static var allPrompts: [DemoPrompt] { all.flatMap(\.prompts) }

    /// The run of show: teach where it eats, ask it to eat without naming the bowl, add a
    /// constraint, teach a second need, then hand it the decision. Every beat after the
    /// first reads something the beat before it wrote.
    public static let runOfShow: [DemoPrompt] = [
        teach.prompts[1],  // this is where you eat
        needs.prompts[0],  // you must be hungry -> resolves to the bowl
        teach.prompts[5],  // stay off the plant
        teach.prompts[3],  // this is where I pet you
        needs.prompts[3],  // come get pets -> resolves to the cushion
        recall.prompts[0], // what have I taught you -> spoken from the map
        recall.prompts[2], // do what you think I want -> picks its own need
    ]
}
