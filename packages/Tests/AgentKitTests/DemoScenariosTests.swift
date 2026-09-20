import XCTest
@testable import AgentKit

/// The demo script is data, and the guarantee is that every chip sends a real utterance.
final class DemoScenariosTests: XCTestCase {
    func testGroupsAreTheFourActsOfTheDemo() {
        XCTAssertEqual(DemoScenarios.all.map(\.title), ["Teach", "Recall", "Act", "Profile"])
    }

    func testEveryPromptSendsSomething() {
        for prompt in DemoScenarios.allPrompts {
            XCTAssertFalse(prompt.label.isEmpty)
            XCTAssertFalse(
                prompt.utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(prompt.label) would be dropped by send(utterance:)"
            )
        }
    }

    /// Ids are the utterance, so a duplicate would collide in a `ForEach`.
    func testPromptsAreUnique() {
        let ids = DemoScenarios.allPrompts.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// A label with no separate utterance is sent as-is; that is the common case and it
    /// must not silently send an empty string.
    func testLabelIsTheDefaultUtterance() {
        XCTAssertEqual(DemoPrompt(label: "Go to your perch").utterance, "Go to your perch")
    }
}
