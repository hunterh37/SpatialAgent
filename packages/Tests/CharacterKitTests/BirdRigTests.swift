import XCTest
import simd
@testable import CharacterKit

#if canImport(RealityKit)
import RealityKit

/// Spec 06 §Proportions and §Budget. The ratios are the cuteness, so they are asserted rather
/// than eyeballed; the budget is asserted because it is the reason the rig is primitives at all.
@MainActor
final class BirdRigTests: XCTestCase {
    private func rig() -> BirdRig { BirdRig() }

    // MARK: Budget

    func testModelEntityCountIsWithinBudget() {
        XCTAssertLessThanOrEqual(rig().modelEntityCount, BirdRig.maxModelEntities)
    }

    func testCrestedVariantIsExactlyAtTheEntityBudget() {
        // The merged crest mesh exists so that the crested variant closes at 15, not 17.
        let crested = BirdRig(palette: .teal)
        XCTAssertTrue(BirdPalette.teal.hasCrest)
        XCTAssertEqual(crested.modelEntityCount, BirdRig.maxModelEntities)
    }

    func testMaterialCountIsWithinBudget() {
        XCTAssertLessThanOrEqual(rig().materialCount, BirdRig.maxMaterials)
        XCTAssertEqual(BirdPalette.materialCount, BirdRig.maxMaterials)
    }

    // MARK: Hierarchy

    func testEveryJointExistsAndIsNamed() {
        let rig = self.rig()
        for joint in BirdRig.Joint.allCases {
            let entity = rig.entity(joint)
            XCTAssertNotNil(entity, "missing \(joint.rawValue)")
            XCTAssertEqual(entity?.name, joint.rawValue)
        }
    }

    func testCrestIsAbsentOnACrestlessVariant() {
        let rig = BirdRig(palette: .moss)
        XCTAssertFalse(BirdPalette.moss.hasCrest)
        XCTAssertNil(rig.entity(.crest))
    }

    /// Attention must be independent of locomotion, so Head hangs off Bob and not off Body.
    func testHeadIsNotParentedToTheBody() {
        let rig = self.rig()
        XCTAssertEqual(rig.entity(.head)?.parent?.name, BirdRig.Joint.bob.rawValue)
        XCTAssertEqual(rig.entity(.body)?.parent?.name, BirdRig.Joint.bob.rawValue)
    }

    /// Feet inheriting body squash is how feet start sliding.
    func testFeetAreNotParentedToTheBody() {
        let rig = self.rig()
        XCTAssertEqual(rig.entity(.footL)?.parent?.name, BirdRig.Joint.bob.rawValue)
        XCTAssertEqual(rig.entity(.footR)?.parent?.name, BirdRig.Joint.bob.rawValue)
    }

    func testFaceIsParentedToTheHead() {
        let rig = self.rig()
        for joint in [BirdRig.Joint.eyeL, .eyeR, .beak, .browL, .browR, .crest] {
            XCTAssertEqual(rig.entity(joint)?.parent?.name, BirdRig.Joint.head.rawValue, "\(joint)")
        }
        XCTAssertEqual(rig.entity(.pupilL)?.parent?.name, BirdRig.Joint.eyeL.rawValue)
        XCTAssertEqual(rig.entity(.pupilR)?.parent?.name, BirdRig.Joint.eyeR.rawValue)
    }

    // MARK: Ratios

    func testHeadIsBetween70And75PercentOfBodyDiameter() {
        let ratio = BirdProportions().headToBodyRatio
        XCTAssertGreaterThanOrEqual(ratio, 0.70)
        XCTAssertLessThanOrEqual(ratio, 0.75)
    }

    func testEyeIsBetween30And36PercentOfHeadDiameter() {
        let ratio = BirdProportions().eyeToHeadRatio
        XCTAssertGreaterThanOrEqual(ratio, 0.30)
        XCTAssertLessThanOrEqual(ratio, 0.36)
    }

    func testSpecRatioCheckAgreesWithTheIndividualBounds() {
        XCTAssertTrue(BirdProportions().satisfiesSpecRatios)
    }

    /// The beak is short and blunt on purpose: length under 1.5 base diameters.
    func testBeakIsBluntNotCrowLike() {
        let p = BirdProportions()
        XCTAssertLessThan(p.beakLength / p.beakBaseDiameter, 1.5)
    }

    // MARK: Standing

    func testLowestPointSitsOnTheFloorPlane() {
        XCTAssertEqual(rig().lowestPointY, 0, accuracy: 0.001)
    }

    func testTheFeetAreWhatTouchTheFloor() {
        let p = BirdProportions()
        let footBottom = p.footHeight / 2 - p.footHeight / 2
        XCTAssertEqual(footBottom, 0, accuracy: 0.001)
        // And nothing else reaches below them.
        XCTAssertGreaterThanOrEqual(p.bodyCenterY - p.bodyHalfHeight, p.footHeight - 0.001)
    }

    func testCrownStandsAt22Centimetres() {
        XCTAssertEqual(rig().crownHeight, 0.22, accuracy: 0.001)
    }

    func testNormalizationIsUniformSoRatiosSurvive() {
        let p = BirdProportions()
        let scale = p.normalizationScale
        XCTAssertGreaterThan(scale, 0)
        // Uniform scale cannot change a ratio of two lengths.
        XCTAssertEqual((p.headDiameter * scale) / (p.bodyDiameter * scale), p.headToBodyRatio,
                       accuracy: 1e-6)
    }

    func testBodyRestsOnTheFeetWithNoGap() {
        let p = BirdProportions()
        XCTAssertEqual(p.bodyCenterY - p.bodyHalfHeight, p.footHeight, accuracy: 1e-6)
    }

    func testHeadOverlapsTheBodySoNoNeckIsNeeded() {
        let p = BirdProportions()
        XCTAssertLessThan(p.headCenterY - p.headRadius, p.bodyTopY)
        XCTAssertGreaterThan(p.headCenterY, p.bodyTopY)
    }

    // MARK: Palette

    func testEveryVariantKeepsThePupilsVisible() {
        for palette in BirdPalette.variants {
            XCTAssertGreaterThanOrEqual(
                palette.pupilContrast,
                BirdPalette.minimumPupilContrast,
                palette.name
            )
        }
    }

    func testVariantCountIsThreeToFive() {
        XCTAssertTrue((3...5).contains(BirdPalette.variants.count))
    }

    func testVariantLookupByName() {
        XCTAssertEqual(BirdPalette.variant(named: "plum"), .plum)
        XCTAssertNil(BirdPalette.variant(named: "nope"))
    }

    func testVariantNamesAreUnique() {
        let names = BirdPalette.variants.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
#endif
