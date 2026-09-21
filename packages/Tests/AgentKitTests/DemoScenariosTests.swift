import AgentProtocol
import SpatialMemory
import XCTest
@testable import AgentKit

/// The demo script is data, and the guarantee is that every chip sends a real utterance.
final class DemoScenariosTests: XCTestCase {
    func testGroupsAreTheActsOfTheDemo() {
        XCTAssertEqual(
            DemoScenarios.all.map(\.title),
            ["Teach", "Needs", "Perches", "Recall", "Act"]
        )
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

/// The scripted half: a chip has to do something with no server attached, and every place it
/// names has to be a place the preset room actually contains.
final class DemoScriptTests: XCTestCase {
    func testEveryScriptedPlaceIsALandmarkInTheDemoRoom() {
        let known = Set(LandmarkPreset.demoRoom.map { $0.name.lowercased() })
        for prompt in DemoScenarios.allPrompts {
            for action in prompt.script {
                guard case let .directive(directive) = action, let place = directive.place
                else { continue }
                XCTAssertTrue(
                    known.contains(place.lowercased()),
                    "\(prompt.label) targets \"\(place)\", which no preset places"
                )
            }
        }
    }

    func testTeachActionsNameRealPresets() {
        for prompt in DemoScenarios.allPrompts {
            for action in prompt.script {
                guard case let .teach(id) = action else { continue }
                XCTAssertNotNil(LandmarkPreset.preset(id: id), "\(prompt.label): no preset \(id)")
            }
        }
    }

    func testTheActGroupMovesTheBird() {
        for prompt in DemoScenarios.act.prompts {
            XCTAssertTrue(prompt.movesTheBird, "\(prompt.label) would be a chip that does nothing")
        }
    }

    /// The Needs group is the memory claim: not one of its chips may name a landmark, or the
    /// destination would be in the script rather than in the map.
    func testNoNeedChipNamesALandmark() {
        let names = LandmarkPreset.demoRoom.map { $0.name.lowercased() }
        for prompt in DemoScenarios.needs.prompts {
            let utterance = prompt.utterance.lowercased()
            for name in names {
                XCTAssertFalse(
                    utterance.contains(name),
                    "\(prompt.label) names \(name); the map should be answering, not the chip"
                )
            }
            XCTAssertTrue(
                prompt.script.contains {
                    switch $0 {
                    case .satisfy, .perch: return true
                    default: return false
                    }
                },
                "\(prompt.label) has no need to resolve"
            )
        }
    }

    /// Every need has a chip, so nothing in `HabitMemory` is unreachable from the stage.
    /// Sleep is reached through `.perch` rather than `.satisfy`, because the perch beat is a
    /// choice between three equals rather than a lookup with one answer.
    func testEveryNeedIsReachableFromAChip() {
        var covered: Set<Need> = []
        for prompt in DemoScenarios.allPrompts {
            for action in prompt.script {
                switch action {
                case let .satisfy(need): covered.insert(need)
                case .perch: covered.insert(.sleepy)
                default: break
                }
            }
        }
        XCTAssertEqual(covered, Set(Need.allCases))
    }

    /// The perch group is the aversion demo, and it only works if "go perch" can be tapped
    /// again and again: the answer is supposed to change between taps.
    func testGoPerchIsRepeatableAndNamesNoPerch() {
        let goPerch = DemoScenarios.perches.prompts[0]
        XCTAssertTrue(goPerch.repeatable)
        XCTAssertTrue(goPerch.movesTheBird)
        for preset in LandmarkPreset.perches {
            XCTAssertFalse(
                goPerch.utterance.lowercased().contains(preset.name.lowercased()),
                "the chip names \(preset.name); the memory should be choosing"
            )
        }
    }

    /// The run of show has to teach before it asks: a need beat that plays before the
    /// landmark it resolves against is a beat that demos the failure case on stage.
    func testRunOfShowTeachesBeforeItAsks() {
        XCTAssertTrue(DemoScenarios.runOfShow.allSatisfy { !$0.script.isEmpty })

        var taught: Set<String> = []
        for prompt in DemoScenarios.runOfShow {
            for action in prompt.script {
                switch action {
                case let .teach(id):
                    taught.insert(id)
                case let .satisfy(need):
                    let preset = LandmarkPreset.preset(for: need)
                    XCTAssertNotNil(preset, "no preset answers \(need)")
                    XCTAssertTrue(
                        taught.contains(preset?.id ?? ""),
                        "\(prompt.label) asks for \(need) before anything places it"
                    )
                default:
                    continue
                }
            }
        }
    }

    /// A beat that never lands is a bird that teleports; every walk is followed by time.
    func testWalksAreGivenTimeToLand() {
        for prompt in DemoScenarios.allPrompts {
            for (index, action) in prompt.script.enumerated() {
                guard case let .directive(directive) = action, directive.kind == .walkTo,
                      index + 1 < prompt.script.count
                else { continue }
                if case .pause = prompt.script[index + 1] { continue }
                if case .say = prompt.script[index + 1] { continue }
                XCTFail("\(prompt.label): step after the walk gives it no time to land")
            }
        }
    }
}
