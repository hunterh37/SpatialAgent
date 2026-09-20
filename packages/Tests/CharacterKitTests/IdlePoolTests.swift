import XCTest
@testable import CharacterKit

/// Spec 06 §Idle.
final class IdlePoolTests: XCTestCase {
    private let frame: Float = 1.0 / 90.0

    private func selections(_ count: Int, configure: (inout IdlePool) -> Void = { _ in })
        -> [IdlePool.Behavior] {
        var pool = IdlePool(seed: 0xA11CE)
        configure(&pool)
        return (0..<count).map { _ in pool.select() }
    }

    // MARK: Distribution

    func testNoBehaviorEverRepeatsImmediately() {
        let picks = selections(1000)
        for (a, b) in zip(picks, picks.dropFirst()) {
            XCTAssertNotEqual(a, b)
        }
    }

    func testEveryBehaviorIsReachable() {
        let picks = Set(selections(1000))
        XCTAssertEqual(picks.count, IdlePool.Behavior.allCases.count)
    }

    /// Every behavior stays reachable at the extremes of both shifts, or the pool quietly
    /// shrinks to seven behaviors exactly when the bird is in an unusual state.
    func testEveryBehaviorIsReachableAtEveryExtreme() {
        for mood in [Float(-1), 0, 1] {
            for silence in [Float(0), 60, 600] {
                let picks = Set(selections(2000) { pool in
                    pool.mood = mood
                    pool.userSilence = silence
                })
                XCTAssertEqual(
                    picks.count,
                    IdlePool.Behavior.allCases.count,
                    "mood \(mood), silence \(silence)"
                )
            }
        }
    }

    func testWeightsAreNeverZero() {
        for mood in [Float(-1), 0, 1] {
            for silence in [Float(0), 600] {
                var pool = IdlePool()
                pool.mood = mood
                pool.userSilence = silence
                for behavior in IdlePool.Behavior.allCases {
                    XCTAssertGreaterThan(pool.weight(for: behavior), 0)
                }
            }
        }
    }

    // MARK: Weight shifts

    private func share(of behavior: IdlePool.Behavior, mood: Float, silence: Float) -> Float {
        let picks = selections(4000) { pool in
            pool.mood = mood
            pool.userSilence = silence
        }
        return Float(picks.filter { $0 == behavior }.count) / Float(picks.count)
    }

    func testHighMoodMakesTheBirdMoreEnergetic() {
        let low = share(of: .smallHop, mood: -1, silence: 0)
        let high = share(of: .smallHop, mood: 1, silence: 0)
        XCTAssertGreaterThan(high, low)
    }

    func testSilenceMakesTheBirdMoreSelfDirected() {
        let attended = share(of: .preenWing, mood: 0, silence: 0)
        let ignored = share(of: .preenWing, mood: 0, silence: 600)
        XCTAssertGreaterThan(ignored, attended)
    }

    func testSilenceMakesTheBirdLookAroundLess() {
        let attended = share(of: .lookAround, mood: 0, silence: 0)
        let ignored = share(of: .lookAround, mood: 0, silence: 600)
        XCTAssertLessThan(ignored, attended)
    }

    func testSilenceDampensEnergy() {
        let attended = share(of: .stretchWings, mood: 1, silence: 0)
        let ignored = share(of: .stretchWings, mood: 1, silence: 600)
        XCTAssertLessThan(ignored, attended)
    }

    func testWeightShiftsAreMonotonicInMood() {
        var pool = IdlePool()
        var previous: Float = 0
        for mood in stride(from: Float(-1), through: 1, by: 0.25) {
            pool.mood = mood
            let weight = pool.weight(for: .smallHop)
            XCTAssertGreaterThan(weight, previous)
            previous = weight
        }
    }

    func testSilenceSaturatesRatherThanRunningAway() {
        var pool = IdlePool()
        pool.userSilence = 60
        let atAMinute = pool.weight(for: .settle)
        pool.userSilence = 36_000
        XCTAssertEqual(pool.weight(for: .settle), atAMinute, accuracy: 1e-6)
    }

    // MARK: Timing

    func testTheBirdIsNeverStillForLongerThanTheTimer() {
        var pool = IdlePool(seed: 7)
        var idleGap: Float = 0
        var worstGap: Float = 0
        var behaviors = 0
        var elapsed: Float = 0
        while elapsed < 120 {
            let fired = pool.update(deltaTime: frame)
            elapsed += frame
            if fired != nil {
                behaviors += 1
                worstGap = max(worstGap, idleGap)
                idleGap = 0
            } else if !pool.isBusy {
                idleGap += frame
            }
        }
        // Two minutes of observation, per the spec's "done" condition.
        XCTAssertGreaterThan(behaviors, 10)
        XCTAssertLessThanOrEqual(worstGap, IdlePool.intervalRange.upperBound + 0.05)
    }

    func testTimerStaysInTheFourToNineSecondRange() {
        var pool = IdlePool(seed: 42)
        var gaps: [Float] = []
        var gap: Float = 0
        var elapsed: Float = 0
        while elapsed < 300 {
            let fired = pool.update(deltaTime: frame)
            elapsed += frame
            if fired != nil {
                gaps.append(gap)
                gap = 0
            } else if !pool.isBusy {
                gap += frame
            }
        }
        XCTAssertGreaterThan(gaps.count, 20)
        for gap in gaps.dropFirst() {
            XCTAssertGreaterThanOrEqual(gap, IdlePool.intervalRange.lowerBound - 0.05)
            XCTAssertLessThanOrEqual(gap, IdlePool.intervalRange.upperBound + 0.05)
        }
    }

    func testABehaviorRunsForItsDurationBeforeTheNextOne() {
        var pool = IdlePool(seed: 3)
        var elapsed: Float = 0
        while pool.current == nil, elapsed < 20 {
            _ = pool.update(deltaTime: frame)
            elapsed += frame
        }
        let behavior = try? XCTUnwrap(pool.current)
        var busyTime: Float = 0
        while pool.isBusy {
            XCTAssertNil(pool.update(deltaTime: frame), "overlapping idle behaviors")
            busyTime += frame
        }
        XCTAssertEqual(busyTime, behavior?.duration ?? 0, accuracy: 0.03)
    }

    func testInterruptStopsTheCurrentBehavior() {
        var pool = IdlePool(seed: 11)
        var elapsed: Float = 0
        while pool.current == nil, elapsed < 20 {
            _ = pool.update(deltaTime: frame)
            elapsed += frame
        }
        pool.interrupt()
        XCTAssertNil(pool.current)
        XCTAssertFalse(pool.isBusy)
    }

    func testEveryBehaviorHasARealDuration() {
        for behavior in IdlePool.Behavior.allCases {
            XCTAssertGreaterThan(behavior.duration, 0.2)
            XCTAssertLessThan(behavior.duration, 4.0)
        }
    }

    func testThereAreExactlyEightBehaviors() {
        XCTAssertEqual(IdlePool.Behavior.allCases.count, 8)
    }
}
