import AgentProtocol
import SceneUnderstanding
import SpatialMemory
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

    private let kitchen = Place(name: "Kitchen", position: SIMD3(2, 0, -2))

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

/// Spec 07 §Learned behavior, deixis: "turn *that* off" resolves through gaze plus the taught
/// object table, on the client, with no coordinate ever having reached the server.
final class DeicticResolverTests: XCTestCase {
    private let resolver = DirectiveResolver()

    private func object(
        _ name: String,
        at x: Float,
        device: String? = "light.lamp"
    ) -> MapObject {
        MapObject(name: name, position: SIMD3(x, 0.8, 0), deviceId: device)
    }

    private func mesh() -> NavMesh {
        NavMeshBuilder.build(
            floors: [FloorRect(center: .zero, extent: SIMD2(6, 6))],
            obstacles: []
        )!
    }

    private func directive(deviceId: String) -> CharacterDirective {
        CharacterDirective(kind: .point, target: .device, deviceId: deviceId)
    }

    private func resolve(
        _ reference: String,
        objects: [MapObject],
        gaze: SIMD3<Float>?
    ) -> ResolvedDirective {
        resolver.resolve(
            directive(deviceId: reference),
            characterPosition: .zero,
            userPosition: SIMD3(0, 1.5, 2),
            places: [],
            devicePositions: objects.reduce(into: [:]) { out, object in
                if let id = object.deviceId { out[id] = object.position }
            },
            navMesh: mesh(),
            objects: objects,
            gaze: gaze
        )
    }

    func testThatResolvesToTheTaughtObjectUnderTheGaze() {
        let lamp = object("the lamp", at: 1.0, device: "light.lamp")
        let resolved = resolve("that", objects: [lamp], gaze: SIMD3(1.05, 0.8, 0))
        XCTAssertEqual(resolved, .point(at: lamp.position))
    }

    func testEveryDeicticWordResolves() {
        let lamp = object("the lamp", at: 1.0)
        for word in ["that", "this", "it", "That One"] {
            XCTAssertTrue(DirectiveResolver.isDeictic(word), word)
            XCTAssertEqual(resolve(word, objects: [lamp], gaze: lamp.position), .point(at: lamp.position))
        }
        XCTAssertFalse(DirectiveResolver.isDeictic("light.lamp"))
    }

    func testARealDeviceIdIsNotTreatedAsDeictic() {
        let lamp = object("the lamp", at: 1.0, device: "light.lamp")
        // No gaze at all, and it still resolves: an id is an id.
        XCTAssertEqual(
            resolve("light.lamp", objects: [lamp], gaze: nil),
            .point(at: lamp.position)
        )
    }

    /// The ambiguous case produces a question, not a guess.
    func testTwoEquallyPlausibleThingsProduceAQuestion() {
        let lamp = object("the lamp", at: 1.0, device: "light.lamp")
        let speaker = object("the speaker", at: 1.06, device: "media.speaker")
        let resolved = resolve("that", objects: [lamp, speaker], gaze: SIMD3(1.03, 0.8, 0))

        guard case let .unresolved(.ambiguousReference(names)) = resolved else {
            return XCTFail("expected a question, got \(resolved)")
        }
        XCTAssertEqual(Set(names), ["the lamp", "the speaker"])
        XCTAssertTrue(resolved.isUnresolved)
    }

    func testAClearWinnerIsNotAmbiguous() {
        let lamp = object("the lamp", at: 1.0, device: "light.lamp")
        let speaker = object("the speaker", at: 1.4, device: "media.speaker")
        XCTAssertEqual(
            resolve("that", objects: [lamp, speaker], gaze: SIMD3(1.0, 0.8, 0)),
            .point(at: lamp.position)
        )
    }

    func testThatWithNothingLookedAtAsksRatherThanGuessing() {
        let lamp = object("the lamp", at: 1.0)
        guard case .unresolved(.nothingReferenced) = resolve("that", objects: [lamp], gaze: nil)
        else { return XCTFail("a guess was made with no gaze") }
    }

    func testThatPointingAtNothingTaughtAsksRatherThanGuessing() {
        let lamp = object("the lamp", at: 1.0)
        guard case .unresolved(.nothingReferenced) = resolve(
            "that", objects: [lamp], gaze: SIMD3(5, 0.8, 0)
        ) else { return XCTFail("resolved to something out of reach of the gaze") }
    }

    func testATaughtThingWithNoDeviceBindingCannotBeActedOn() {
        let plant = object("the plant", at: 1.0, device: nil)
        guard case .unresolved(.unknownDevice) = resolve(
            "that", objects: [plant], gaze: plant.position
        ) else { return XCTFail("acted on something with no device behind it") }
    }

    func testEveryUnresolvedReasonIsSpokenInCharacter() {
        for reason: UnresolvedReason in [
            .ambiguousReference(["the lamp", "the speaker"]),
            .ambiguousReference([]),
            .nothingReferenced,
        ] {
            XCTAssertFalse(reason.spokenLine.isEmpty)
            XCTAssertFalse(reason.spokenLine.contains("_"), "reads like a code: \(reason.spokenLine)")
        }
    }
}

private extension ResolvedDirective {
    var isUnresolved: Bool {
        if case .unresolved = self { return true }
        return false
    }
}
