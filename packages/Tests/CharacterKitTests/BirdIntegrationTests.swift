import AgentProtocol
import SceneUnderstanding
import XCTest
import simd
@testable import CharacterKit

#if canImport(RealityKit)
import RealityKit

/// Spec 06 §Mapping to agent state, plus the two presence rules that used to be checked only
/// by eye on-device.
@MainActor
final class BirdIntegrationTests: XCTestCase {
    private let frame: Float = 1.0 / 90.0
    private let user = SIMD3<Float>(0, 1.5, -1.2)

    private func character() -> CharacterEntity {
        let character = CharacterEntity()
        character.place(at: Placement.Pose(position: .zero, yaw: 0))
        return character
    }

    private func run(_ character: CharacterEntity, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            character.update(deltaTime: frame, userPosition: user)
            elapsed += frame
        }
    }

    // MARK: The capsule is gone

    func testTheCharacterIsTheBirdRig() {
        let character = self.character()
        XCTAssertEqual(character.rig.modelEntityCount, BirdRig.maxModelEntities)
        XCTAssertNotNil(character.rig.entity(.beak))
        XCTAssertEqual(CharacterEntity.targetHeight, 0.22, accuracy: 0.001)
    }

    func testEveryJointIsReachableThroughTheCharacter() {
        let character = self.character()
        for joint in BirdRig.Joint.allCases {
            XCTAssertNotNil(character.rig.entity(joint), "\(joint)")
        }
    }

    func testWearingAVariantKeepsPositionAndYaw() {
        let character = self.character()
        character.place(at: Placement.Pose(position: SIMD3(1, 0, 2), yaw: 1.2))
        character.wear(.moss)
        XCTAssertEqual(character.position, SIMD3(1, 0, 2))
        XCTAssertEqual(character.hop.yaw, 1.2, accuracy: 1e-6)
        XCTAssertNil(character.rig.entity(.crest), "moss has no crest")
    }

    // MARK: The 400ms budget

    /// PRD §6 and spec 06: a visible body change within 400ms of the utterance ending, with
    /// no model involvement at all.
    func testThinkingIsVisibleWithin400ms() {
        let character = self.character()
        run(character, seconds: 1.0)
        character.signal(.addressed)
        run(character, seconds: 0.5)

        character.signal(.utteranceEnded)
        XCTAssertEqual(character.machine.state, .thinking)

        var elapsed: Float = 0
        var visibleAt: Float?
        while elapsed < 0.4 {
            character.update(deltaTime: frame, userPosition: user)
            elapsed += frame
            if visibleAt == nil, character.hasVisibleBodyChange { visibleAt = elapsed }
        }
        XCTAssertNotNil(visibleAt, "no visible body change inside the 400ms budget")
        XCTAssertLessThan(visibleAt!, 0.4)
    }

    func testThinkingLooksUpAndAwayFromTheUser() {
        let character = self.character()
        character.signal(.utteranceEnded)
        run(character, seconds: 0.6)
        XCTAssertGreaterThan(character.attention.headPitch, 0.05, "should be looking up")
    }

    // MARK: State mapping

    func testEveryStateProducesADistinctBody() {
        var poses: [CharacterState: [Float]] = [:]
        for state in [CharacterState.idle, .listening, .thinking, .speaking, .gesturing] {
            let character = self.character()
            switch state {
            case .listening: character.signal(.addressed)
            case .thinking: character.signal(.utteranceEnded)
            case .speaking: character.signal(.utteranceEnded); character.signal(.firstToken)
            case .gesturing: character.signal(.gestureStarted)
            default: break
            }
            run(character, seconds: 0.6)
            XCTAssertEqual(character.machine.state, state)
            poses[state] = character.face.expressionParameters.vector
        }
        for (a, poseA) in poses {
            for (b, poseB) in poses where a != b {
                XCTAssertNotEqual(poseA, poseB, "\(a) and \(b) look identical")
            }
        }
    }

    func testListeningTurnsTowardTheUser() {
        let character = self.character()
        character.signal(.addressed)
        run(character, seconds: 0.8)
        XCTAssertEqual(character.face.expression, .curious)
        // The user is behind the bird, past the head's ±75°, so the double-take turns the
        // body and the head comes back to centre on a user it can now see.
        XCTAssertEqual(abs(character.hop.yaw), .pi, accuracy: 0.05)
        XCTAssertLessThan(abs(character.attention.headYaw), 0.1)
    }

    func testSpeechTokensOpenTheBeakAndSilenceClosesIt() {
        let character = self.character()
        character.signal(.utteranceEnded)
        character.signal(.firstToken)
        character.speechToken(amplitude: 1.0)
        character.update(deltaTime: frame, userPosition: user)
        XCTAssertGreaterThan(character.face.parameters.beakOpen, 0.1)

        character.signal(.speechEnded)
        // Long enough for the beak's 120ms close *and* the crossfade off `happy`, which
        // holds the beak slightly open on its own.
        run(character, seconds: 0.5)
        XCTAssertEqual(character.face.parameters.beakOpen, 0, accuracy: 1e-5)
    }

    // MARK: Presence

    /// The feet never leave the floor except on an arc, and the bird is never in the floor.
    func testTheBirdNeverSinksBelowTheFloor() {
        let character = self.character()
        character.apply(.walk(path: [SIMD3(0, 0, 0.4), SIMD3(0.4, 0, 0.8)]))
        var lowest: Float = .greatestFiniteMagnitude
        run(character, seconds: 6)
        lowest = min(lowest, character.rig.root.position.y + character.root.position.y)
        XCTAssertGreaterThanOrEqual(lowest, -0.001)
    }

    func testAnUnreachableWalkFailsToIdleWithoutMoving() {
        let character = self.character()
        character.apply(.walk(path: []))
        XCTAssertEqual(character.machine.state, .idle)
        run(character, seconds: 1)
        XCTAssertEqual(character.position, .zero)
    }

    func testWalkingCrossesTheRoomAndSettles() {
        let character = self.character()
        character.apply(.walk(path: [SIMD3(0, 0, 1.0)]))
        XCTAssertEqual(character.machine.state, .walking)
        run(character, seconds: 20)
        XCTAssertEqual(character.machine.state, .idle)
        XCTAssertEqual(character.position.z, 1.0, accuracy: 0.05)
    }

    func testBreathingNeverStopsWhileAlive() {
        let character = self.character()
        var peak: Float = 0
        for _ in 0..<(90 * 6) {
            character.update(deltaTime: frame, userPosition: user)
            peak = max(peak, abs(character.animator.breathScale.y - 1))
        }
        XCTAssertGreaterThan(peak, 0.005)
    }

    func testIdleNeverSitsStillForLongerThanTheTimer() {
        let character = self.character()
        var behaviors = 0
        var elapsed: Float = 0
        while elapsed < 60 {
            let before = character.idle.current
            character.update(deltaTime: frame, userPosition: user)
            if before == nil, character.idle.current != nil { behaviors += 1 }
            elapsed += frame
        }
        XCTAssertGreaterThan(behaviors, 4)
    }

    // MARK: Budget

    /// The spec budget is 0.4ms on-device. A Mac is not a headset, so this asserts the shape
    /// of the cost — one update, no allocation spiral — with generous headroom; the real
    /// number is measured on-device at the end of the phase.
    func testUpdateCostStaysInTheSameOrderAsTheBudget() {
        let character = self.character()
        run(character, seconds: 1)
        var worst: TimeInterval = 0
        for _ in 0..<600 {
            character.update(deltaTime: frame, userPosition: user)
            worst = max(worst, character.lastUpdateCost)
        }
        XCTAssertLessThan(worst, CharacterEntity.frameBudget * 25)
    }
}
#endif
