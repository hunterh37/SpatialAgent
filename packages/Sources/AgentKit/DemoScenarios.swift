import Foundation

/// Canned utterances for a demo, sent verbatim through `AgentSession.send(utterance:)`.
///
/// They are data, not a second input path: a chip produces exactly the string a person would
/// have typed, so nothing downstream can behave differently for a demo than for a user. That
/// is the whole reason this is a list of strings rather than a set of direct tool calls.
///
/// The order is the story: teach the room, ask what it remembers, ask it to act, then show
/// that the memory is about the person and not only the room.
public struct DemoPrompt: Identifiable, Hashable, Sendable {
    /// Chip text.
    public let label: String
    /// What is actually sent. Often longer than the label.
    public let utterance: String

    public var id: String { utterance }

    public init(label: String, utterance: String? = nil) {
        self.label = label
        self.utterance = utterance ?? label
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
    /// Teaching prompts name the same landmarks `LandmarkPreset.demoRoom` places, so a room
    /// set up with the checklist and a room taught by speech answer the recall prompts
    /// identically.
    public static let teach = DemoScenarioGroup(
        title: "Teach",
        symbol: "graduationcap.fill",
        prompts: [
            DemoPrompt(label: "This is my desk"),
            DemoPrompt(label: "This is your perch"),
            DemoPrompt(label: "Don't go near the plant"),
            DemoPrompt(label: "Morning standup", utterance: "This is where I do morning standup"),
        ]
    )

    public static let recall = DemoScenarioGroup(
        title: "Recall",
        symbol: "brain.head.profile",
        prompts: [
            DemoPrompt(label: "Where's my perch?"),
            DemoPrompt(label: "What do you know?", utterance: "What have I taught you about this room?"),
            DemoPrompt(label: "What do you remember about me?"),
        ]
    )

    public static let act = DemoScenarioGroup(
        title: "Act",
        symbol: "figure.walk",
        prompts: [
            DemoPrompt(label: "Go to your perch"),
            DemoPrompt(label: "Turn on the desk lamp"),
            DemoPrompt(label: "Set a 10 minute timer"),
        ]
    )

    public static let profile = DemoScenarioGroup(
        title: "Profile",
        symbol: "person.text.rectangle",
        prompts: [
            DemoPrompt(label: "Ask me something about myself"),
            DemoPrompt(label: "Remember I drink oat milk"),
            DemoPrompt(label: "Forget what I said about coffee"),
        ]
    )

    public static let all: [DemoScenarioGroup] = [teach, recall, act, profile]

    /// Every utterance, flattened. Used by tests to assert the list stays sendable.
    public static var allPrompts: [DemoPrompt] { all.flatMap(\.prompts) }
}
