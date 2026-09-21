import XCTest
import simd
@testable import SpatialMemory

/// The demo-room presets and the single-home-perch invariant they rely on.
final class LandmarkPresetTests: XCTestCase {
    func testDemoRoomCoversTheScriptedLandmarks() {
        let ids = LandmarkPreset.demoRoom.map(\.id)
        XCTAssertEqual(
            ids,
            [
                "perch-left", "perch-middle", "perch-right", "food-bowl", "water-dish",
                "petting-spot", "toy-basket", "workspace", "plant",
            ]
        )
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(LandmarkPreset.demoRoom.map(\.name)).count, ids.count)
    }

    /// Every need but one has exactly one landmark that answers it, which is what makes an
    /// unqualified "go eat" resolvable without a name in the utterance. Sleepy is the
    /// exception on purpose: three perches, and which one is learned.
    func testEveryNeedHasExactlyOneLandmarkExceptSleep() {
        for need in Need.allCases where need != .sleepy {
            let matches = LandmarkPreset.demoRoom.filter { $0.kind == need.kind }
            XCTAssertEqual(matches.count, 1, "\(need) is answered by \(matches.count) presets")
            XCTAssertEqual(LandmarkPreset.preset(for: need)?.kind, need.kind)
        }
        XCTAssertEqual(LandmarkPreset.demoRoom.filter { $0.kind == .perch }.count, 3)
    }

    /// A landmark with no prop of its own would be drawn as a pin, and every preset in the
    /// room is a thing the audience should recognise on sight.
    func testEveryPresetDrawsARealProp() {
        for preset in LandmarkPreset.demoRoom {
            XCTAssertNotEqual(preset.prop, .marker, "\(preset.id) is still a generic pin")
        }
    }

    /// Three perches, identical in every way a record can be identical, and placed first.
    /// Identical is the requirement: if one were taller or nearer, the bird preferring it
    /// would prove nothing about memory.
    func testThreeIdenticalPerchesComeFirst() {
        let perches = LandmarkPreset.perches
        XCTAssertEqual(perches.count, 3)
        XCTAssertEqual(Array(LandmarkPreset.demoRoom.prefix(3)), perches)
        XCTAssertEqual(Set(perches.map(\.height)), [LandmarkPreset.perchHeight])
        XCTAssertEqual(Set(perches.map(\.prop)), [.perch])
        XCTAssertEqual(Set(perches.map(\.radius)).count, 1)
        // And they are somewhere a hand can reach: head height, not ceiling height.
        XCTAssertEqual(LandmarkPreset.perchHeight, 1.0)
    }

    func testThePlantCarriesAFragileRule() {
        let plant = try! XCTUnwrap(LandmarkPreset.preset(id: "plant"))
        XCTAssertEqual(plant.rule, .fragile)
        XCTAssertFalse(Rule.Kind.fragile.isAlwaysHard)
    }

    // MARK: Home perch

    private func mapWithTwoPlaces() -> (SemanticMap, Place, Place) {
        var map = SemanticMap()
        let shelf = Place(name: "the red perch", position: SIMD3(1, 0, 0), kind: .perch)
        let ledge = Place(name: "the ledge", position: SIMD3(-1, 0, 0))
        map.upsert(shelf)
        map.upsert(ledge)
        return (map, shelf, ledge)
    }

    func testHomePerchIsTheOnlyPerchWhenThereIsOne() {
        let (map, shelf, _) = mapWithTwoPlaces()
        XCTAssertEqual(map.homePerch?.id, shelf.id)
    }

    /// Promotion no longer unseats a coloured perch: there are three of them and they are
    /// equals. What it does clear out is a perch the room has no colour for — the record the
    /// learned choice must never see, because the spoken line would read it out by name.
    func testPromotingDemotesOnlyThePerchTheRoomHasNoColourFor() {
        var (map, shelf, ledge) = mapWithTwoPlaces()
        let stray = Place(name: "your perch", position: SIMD3(0, 0, 2), kind: .perch)
        map.upsert(stray)

        XCTAssertTrue(map.setHomePerch(id: ledge.id))

        XCTAssertEqual(map.place(id: shelf.id)?.kind, .perch, "coloured perches coexist")
        XCTAssertEqual(map.place(id: stray.id)?.kind, .generic, "demoted, not deleted")
        XCTAssertEqual(map.places.count, 3)
        XCTAssertEqual(map.homePerch?.id, shelf.id, "a promoted record with no colour is not a candidate")
    }

    func testSettingAnUnknownHomePerchFails() {
        var (map, shelf, _) = mapWithTwoPlaces()
        XCTAssertFalse(map.setHomePerch(id: UUID()))
        XCTAssertEqual(map.homePerch?.id, shelf.id)
    }
}

/// Perch colour: three poles that behave identically are only tellable apart by paint, so the
/// paint has to be distinct, stable across launches, and never handed to a non-perch.
final class PropTintTests: XCTestCase {
    func testThePerchesAreThreeDifferentColours() {
        let tints = LandmarkPreset.demoRoom.filter(\.isPerch).map(\.tint)
        XCTAssertEqual(tints.count, 3)
        XCTAssertEqual(Set(tints).count, 3)
    }

    func testPerchNamesMatchTheirPaint() {
        let named: [(String, PropTint)] = [
            ("the red perch", PropTint.perchPalette[0]),
            ("the blue perch", PropTint.perchPalette[1]),
            ("the amber perch", PropTint.perchPalette[2]),
        ]
        for (name, tint) in named {
            let preset = LandmarkPreset.demoRoom.first { $0.name == name }
            XCTAssertEqual(preset?.tint, tint, "\(name) is not painted the colour it is called")
        }
    }

    func testEverythingElseKeepsItsOwnPalette() {
        for preset in LandmarkPreset.demoRoom where !preset.isPerch {
            XCTAssertEqual(preset.tint, .wood, "\(preset.id) was tinted; only perches are")
        }
    }

    /// A perch that changes colour between launches cannot be referred to by its colour.
    func testAnUntintedPerchGetsAStableColour() {
        let first = PropTint.stable(for: "perch-taught-by-speech")
        XCTAssertEqual(first, PropTint.stable(for: "perch-taught-by-speech"))
        XCTAssertTrue(PropTint.perchPalette.contains(first))
    }

    func testShadingStaysInRange() {
        let shaded = PropTint(1, 1, 1).shaded()
        XCTAssertLessThan(shaded.red, 1)
        XCTAssertGreaterThan(shaded.red, 0)
        XCTAssertEqual(PropTint(2, -1, 0.5).red, 1)
        XCTAssertEqual(PropTint(2, -1, 0.5).green, 0)
    }
}
