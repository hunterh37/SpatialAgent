import AgentProtocol
import SceneUnderstanding
import XCTest
import simd
@testable import CharacterKit

final class CharacterStateMachineTests: XCTestCase {
    func testAddressToSpeechPath() {
        var m = CharacterStateMachine()
        XCTAssertEqual(m.handle(.addressed), .listening)
        XCTAssertEqual(m.handle(.utteranceEnded), .thinking)
        XCTAssertEqual(m.handle(.firstToken), .speaking)
        XCTAssertEqual(m.handle(.speechEnded), .idle)
    }

    func testLocomotionPath() {
        var m = CharacterStateMachine()
        XCTAssertEqual(m.handle(.pathAccepted), .turning)
        XCTAssertEqual(m.handle(.turnComplete), .walking)
        XCTAssertEqual(m.handle(.arrived), .arriving)
        XCTAssertEqual(m.handle(.settled), .idle)
    }

    /// `thinking` must be enterable within 400ms of an utterance ending, before the model
    /// has produced anything — so it must not require passing through `listening`.
    func testThinkingIsReachableDirectlyFromAnyState() {
        for state in CharacterState.allCases {
            var m = CharacterStateMachine()
            m.forceForTesting(state)
            XCTAssertEqual(m.handle(.utteranceEnded), .thinking, "from \(state)")
        }
    }

    func testEveryTransitionCrossfades() {
        var m = CharacterStateMachine()
        m.handle(.addressed)
        XCTAssertGreaterThanOrEqual(m.lastCrossfade, 0.2)
        XCTAssertLessThanOrEqual(m.lastCrossfade, 0.3)
    }

    func testIllegalTransitionIsANoOp() {
        var m = CharacterStateMachine()
        XCTAssertEqual(m.handle(.turnComplete), .idle)
    }
}

final class DirectiveResolverTests: XCTestCase {
    private let resolver = DirectiveResolver()

    private func mesh() -> NavMesh {
        NavMeshBuilder.build(
            floors: [FloorRect(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6))],
            obstacles: []
        )!
    }

    private let kitchen = PlaceRecord(name: "Kitchen", position: SIMD3(2, 0, -2))

    func testWalkToKnownPlaceProducesClampedPath() {
        let result = resolver.resolve(
            CharacterDirective(kind: .walkTo, place: "kitchen"),
            characterPosition: SIMD3(-1, 0, 1),
            userPosition: .zero,
            places: [kitchen],
            devicePositions: [:],
            navMesh: mesh()
        )
        guard case let .walk(path) = result else { return XCTFail("expected walk, got \(result)") }
        XCTAssertFalse(path.isEmpty)
    }

    /// An unknown name is a clarifying question, never a guess (spec/05-scene.md).
    func testUnknownPlaceIsUnresolvedNotGuessed() {
        let result = resolver.resolve(
            CharacterDirective(kind: .walkTo, place: "conservatory"),
            characterPosition: .zero,
            userPosition: .zero,
            places: [kitchen],
            devicePositions: [:],
            navMesh: mesh()
        )
        XCTAssertEqual(result, .unresolved(reason: .unknownPlace("conservatory")))
    }

    func testWalkWithoutSceneIsUnresolved() {
        let result = resolver.resolve(
            CharacterDirective(kind: .walkTo, place: "kitchen"),
            characterPosition: .zero,
            userPosition: .zero,
            places: [kitchen],
            devicePositions: [:],
            navMesh: nil
        )
        XCTAssertEqual(result, .unresolved(reason: .missingScene))
    }

    func testLookAtUserDefaultsToUserPosition() {
        let result = resolver.resolve(
            CharacterDirective(kind: .lookAt, target: .user),
            characterPosition: .zero,
            userPosition: SIMD3(0, 1.5, 2),
            places: [],
            devicePositions: [:],
            navMesh: mesh()
        )
        XCTAssertEqual(result, .look(at: SIMD3(0, 1.5, 2)))
    }

    func testUnresolvedReasonsSpeakRatherThanShowCodes() {
        XCTAssertFalse(UnresolvedReason.unknownPlace("attic").spokenLine.contains("unknownPlace"))
        XCTAssertTrue(UnresolvedReason.unknownPlace("attic").spokenLine.contains("attic"))
    }
}

extension CharacterStateMachine {
    /// Test-only seam. Production transitions always go through `handle`.
    mutating func forceForTesting(_ state: CharacterState) {
        while self.state != state {
            let before = self.state
            switch state {
            case .listening: handle(.addressed)
            case .thinking: handle(.addressed); handle(.utteranceEnded)
            case .speaking: handle(.addressed); handle(.utteranceEnded); handle(.firstToken)
            case .turning: handle(.pathAccepted)
            case .walking: handle(.pathAccepted); handle(.turnComplete)
            case .arriving: handle(.pathAccepted); handle(.turnComplete); handle(.arrived)
            case .gesturing: handle(.gestureStarted)
            case .idle: handle(.interrupted)
            }
            if self.state == before { break }
        }
    }
}
