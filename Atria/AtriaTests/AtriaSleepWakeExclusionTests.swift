import XCTest
@testable import Atria

/// Regression for the 2026-08-04 user-caught defect: a recovered sleep
/// candidate spanning 11:33PM–8:59AM reported duration == span while the
/// drained archive held 110–596mg wrist movement (vs ≤6mg still) through a
/// ~40-minute awake stretch (user typing, strap worn). Candidate duration
/// must exclude SUSTAINED validated wake movement.
final class AtriaSleepWakeExclusionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_785_780_000)

    private func epoch(offsetMinutes: Int,
                       minutes: Int = 5,
                       lowMotion: Bool,
                       validated: Bool = true) -> AtriaRecoveredMotionEpoch {
        let start = base.addingTimeInterval(TimeInterval(offsetMinutes) * 60)
        return AtriaRecoveredMotionEpoch(
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes) * 60),
            rows: minutes * 60,
            validatedRows: validated ? minutes * 60 : 0,
            stillnessRatio: lowMotion ? 0.98 : 0.20,
            movementIntensity: lowMotion ? 0.004 : 0.35,
            p95VectorDelta: lowMotion ? 0.006 : 0.45,
            maximumGapSeconds: 2,
            measurementValidated: validated,
            lowMotionQualified: lowMotion,
            reason: validated ? "test" : "test_unvalidated"
        )
    }

    func testSustainedWakeBlockIsCounted() {
        // 6h sleep shape: still epochs except a 40-minute wake block.
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for i in 0..<72 {  // 72 x 5min = 6h
            let wake = (i >= 30 && i < 38)  // minutes 150-190 = 40min awake
            epochs.append(epoch(offsetMinutes: i * 5, lowMotion: !wake))
        }
        let awake = AtriaRecoveredMotionAnalytics.sustainedAwakeSeconds(
            epochs: epochs, start: base, end: base.addingTimeInterval(6 * 3600))
        XCTAssertEqual(awake, 40 * 60, accuracy: 1)
    }

    func testBriefStirringIsNeverDeducted() {
        // A single 5-minute movement epoch (rollover) stays under the 10-min
        // sustained floor.
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for i in 0..<72 {
            epochs.append(epoch(offsetMinutes: i * 5, lowMotion: i != 30))
        }
        let awake = AtriaRecoveredMotionAnalytics.sustainedAwakeSeconds(
            epochs: epochs, start: base, end: base.addingTimeInterval(6 * 3600))
        XCTAssertEqual(awake, 0)
    }

    func testUnvalidatedEpochsAreNeverTrusted() {
        // 40 minutes of movement but NOT measurement-validated: no deduction —
        // the helper must not guess from untrusted evidence.
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for i in 0..<72 {
            let wake = (i >= 30 && i < 38)
            epochs.append(epoch(offsetMinutes: i * 5, lowMotion: !wake, validated: !wake))
        }
        let awake = AtriaRecoveredMotionAnalytics.sustainedAwakeSeconds(
            epochs: epochs, start: base, end: base.addingTimeInterval(6 * 3600))
        XCTAssertEqual(awake, 0)
    }

    func testTwoSeparateWakeBlocksBothCount() {
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for i in 0..<108 {  // 9h — this night's shape
            let wakeA = (i >= 74 && i < 79)   // 25min ≈ the 05:40-06:05 stretch
            let wakeB = (i >= 83 && i < 86)   // 15min ≈ later activity
            epochs.append(epoch(offsetMinutes: i * 5, lowMotion: !(wakeA || wakeB)))
        }
        let awake = AtriaRecoveredMotionAnalytics.sustainedAwakeSeconds(
            epochs: epochs, start: base, end: base.addingTimeInterval(9 * 3600))
        XCTAssertEqual(awake, (25 + 15) * 60, accuracy: 1)
    }

    func testAggregateCandidateDurationExcludesSustainedWake() {
        // End-to-end: a recovered-style continuous-HR session whose attached
        // motion epochs contain a 40-minute validated wake block must yield a
        // candidate with duration ≈ span - 40min, never duration == span.
        let start = base
        let hours: TimeInterval = 7 * 3600
        let points = stride(from: 0.0, to: hours, by: 1.0).map {
            SavedSession.Point(t: $0, bpm: 58 + Int($0.truncatingRemainder(dividingBy: 7)) % 5)
        }
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for i in 0..<84 {  // 84 x 5min = 7h
            let wake = (i >= 66 && i < 74)  // 40min near the end (the 05:40-06:20 shape)
            epochs.append(epoch(offsetMinutes: i * 5, lowMotion: !wake))
        }
        var session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(hours),
                                   label: "All-day wear",
                                   points: points)
        session.recoveredMotionEpochs = epochs
        let candidates = SessionStore.aggregateSleepCandidates(
            in: [session],
            rest: 62,
            maxHR: 190,
            calendar: .current,
            historicalMotionPolicy: .sessionOnly
        )
        guard let candidate = candidates.first else {
            XCTFail("expected a sleep candidate for a 7h low-HR overnight session")
            return
        }
        XCTAssertLessThan(candidate.duration, candidate.span - 35 * 60,
                          "duration must exclude the sustained 40min wake block")
        XCTAssertGreaterThan(candidate.duration, candidate.span - 45 * 60,
                             "deduction should be ≈ the wake block, not more")
    }
}
