import SceneUnderstanding
import XCTest
import simd
@testable import CharacterKit

#if canImport(RealityKit)

/// Spec 07 §Acknowledgement. Teaching that produces only a toast is a failed teaching act,
/// so every act is checked for motion inside the budget rather than for a return value.
@MainActor
final class TeachingResponseTests: XCTestCase {
    private let frame: Float = 1.0 / 90.0
    private let user = SIMD3<Float>(0, 1.5, -1.2)
    private let target = SIMD3<Float>(1.2, 0, -1.0)

    private func character() -> CharacterEntity {
        let character = CharacterEntity()
        character.place(at: Placement.Pose(position: .zero, yaw: 0))
        // Settle to neutral so a change is a change.
        for _ in 0..<90 { character.update(deltaTime: frame, userPosition: user) }
        return character
    }

    private func path() -> [SIMD3<Float>] { [SIMD3(0.6, 0, -0.5), target] }

    // MARK: Motion within 400ms

    func testEveryActProducesMotionWithinTheBudget() {
        for act in TeachingAct.allCases {
            let character = self.character()
            let before = character.face.expressionParameters.vector
            character.acknowledge(act, name: "the desk", target: target, path: path())

            var elapsed: Float = 0
            var movedAt: Float?
            while elapsed < Float(TeachingResponse.motionBudget) {
                character.update(deltaTime: frame, userPosition: user)
                elapsed += frame
                if movedAt == nil, character.face.expressionParameters.vector != before {
                    movedAt = elapsed
                }
            }
            XCTAssertNotNil(movedAt, "\(act) produced no visible motion")
            XCTAssertLessThan(movedAt!, Float(TeachingResponse.motionBudget), "\(act)")
        }
    }

    func testTheLookHappensImmediatelyAndDoesNotWaitForTheRecord() {
        let character = self.character()
        character.acknowledge(.namePlace, name: "the desk", target: target, path: nil)
        character.update(deltaTime: frame, userPosition: user)
        // Attention is on the target rather than on the user.
        XCTAssertNotNil(character.attention.target)
        XCTAssertEqual(character.attention.target, target)
    }

    // MARK: Expressions

    func testForbiddingPlaysScolded() {
        let character = self.character()
        character.acknowledge(.forbidRegion, name: "the shrine", target: target, path: path())
        XCTAssertEqual(character.face.expression, .scolded)
        XCTAssertEqual(TeachingResponse.expression(for: .forbidRegion), .scolded)
    }

    func testNamingActsPlayCurious() {
        for act in [TeachingAct.namePlace, .nameObject, .nameActivity] {
            XCTAssertEqual(TeachingResponse.expression(for: act), .curious, "\(act)")
        }
    }

    func testAnAcceptedCorrectionPlaysHappy() {
        XCTAssertEqual(TeachingResponse.expression(for: .correctName), .happy)
    }

    func testEveryActHasADistinctEnoughFace() {
        let expressions = Set(TeachingAct.allCases.map { TeachingResponse.expression(for: $0) })
        XCTAssertEqual(expressions.count, 3, "naming, forbidding and correcting must differ")
    }

    // MARK: Saying the name back

    func testEveryActSaysTheNameBack() {
        for act in TeachingAct.allCases {
            let line = TeachingResponse.spokenLine(for: act, name: "the coffee machine")
            XCTAssertTrue(line.contains("the coffee machine"), "\(act) did not say the name back")
        }
    }

    func testForbiddingWithNoNameStillSpeaks() {
        let line = TeachingResponse.spokenLine(for: .forbidRegion, name: "")
        XCTAssertFalse(line.isEmpty)
        XCTAssertTrue(line.contains("Not there"))
    }

    // MARK: Hopping

    func testAReachableTargetIsHoppedTo() {
        let character = self.character()
        let plan = character.acknowledge(
            .namePlace, name: "the desk", target: target, path: path()
        )
        XCTAssertEqual(plan.hopTo, target)
        XCTAssertEqual(character.machine.state, .walking)
    }

    func testAnUnreachableTargetIsLookedAtNotWalkedTo() {
        let character = self.character()
        let plan = character.acknowledge(.namePlace, name: "the ledge", target: target, path: [])
        XCTAssertNil(plan.hopTo)
        XCTAssertNotNil(plan.lookAt)
        XCTAssertNotEqual(character.machine.state, .walking)
    }

    /// Hopping onto the thing it was just told to stay away from is the wrong reading of
    /// "don't go here".
    func testForbiddingNeverHopsToTheRegion() {
        let character = self.character()
        let plan = character.acknowledge(
            .forbidRegion, name: "the shrine", target: target, path: path()
        )
        XCTAssertNil(plan.hopTo)
        XCTAssertNotEqual(character.machine.state, .walking)
        XCTAssertEqual(plan.lookAt, target, "it still looks at what it was told to avoid")
    }

    func testTheBirdKeepsWatchingTheTargetWhileHoppingToIt() {
        let character = self.character()
        character.acknowledge(.namePlace, name: "the desk", target: target, path: path())
        for _ in 0..<40 { character.update(deltaTime: frame, userPosition: user) }
        XCTAssertEqual(character.attention.target, target)
    }
}
#endif
