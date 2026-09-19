import XCTest
@testable import Atria

/// 2026-08-30 motion-quiescence bound refinement (owner-caught): the review
/// proposal claimed a 02:01 sleep onset for a night whose motion shards
/// showed a brief lull (02:00–02:30), sustained restlessness (02:45–04:10,
/// per-15-min mean |ΔG| 0.13–0.45 versus ≤0.08 asleep), and true settling
/// only from ~04:15 (owner correction: 04:37). HR sat near baseline through
/// the restlessness, so the HR lanes bridged the lull into the claimed
/// onset. These pin the pure scan (`SessionStore.motionQuiescenceRefinedBounds`)
/// and the candidate integration: refinement only ever narrows, fails closed
/// without sufficient evidence, and a candidate refined below its duration
/// floor dies with a named skip instead of proposing a sliver.
final class AtriaSleepQuiescenceRefinementTests: XCTestCase {
    // 23:30 IST — the same overnight-qualifying base the wake-exclusion
    // pins use. Civil-clock labels in comments below use the owner night's
    // shape (lull / restless / sleep), not literal wall times.
    private let base = Date(timeIntervalSince1970: 1_785_780_000)
    private let spanMinutes = 345  // ≈ the 02:01–07:45 proposal span

    private func epoch(offsetMinutes: Int,
                       minutes: Int = 5,
                       intensity: Double,
                       validated: Bool = true) -> AtriaRecoveredMotionEpoch {
        let start = base.addingTimeInterval(TimeInterval(offsetMinutes) * 60)
        let quiet = intensity
            <= SessionStore.sleepQuiescenceQuietIntensityCeiling
        return AtriaRecoveredMotionEpoch(
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes) * 60),
            rows: minutes * 60,
            validatedRows: validated ? minutes * 60 : 0,
            stillnessRatio: quiet ? 0.98 : 0.20,
            movementIntensity: intensity,
            p95VectorDelta: intensity * 1.3,
            maximumGapSeconds: 2,
            measurementValidated: validated,
            lowMotionQualified: validated && quiet,
            reason: validated ? "test" : "test_unvalidated"
        )
    }

    /// The measured owner night: 30-min lull, 105 min restlessness, then
    /// 3.5 h sustained quiet to the (correct) end.
    private func ownerNightEpochs(
        validated: Bool = true
    ) -> [AtriaRecoveredMotionEpoch] {
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for i in 0..<(spanMinutes / 5) {
            let minute = i * 5
            let intensity: Double
            if minute < 30 {
                intensity = 0.02   // the lull that seeded the false onset
            } else if minute < 135 {
                intensity = 0.45   // sustained restlessness (awake in bed)
            } else {
                intensity = 0.03   // real sleep onset onward
            }
            epochs.append(epoch(offsetMinutes: minute,
                                intensity: intensity,
                                validated: validated))
        }
        return epochs
    }

    private func quietEpochs(
        fromMinute: Int = 0,
        toMinute: Int? = nil
    ) -> [AtriaRecoveredMotionEpoch] {
        let upper = toMinute ?? spanMinutes
        var epochs: [AtriaRecoveredMotionEpoch] = []
        var minute = fromMinute
        while minute < upper {
            epochs.append(epoch(offsetMinutes: minute, intensity: 0.02))
            minute += 5
        }
        return epochs
    }

    private var windowEnd: Date {
        base.addingTimeInterval(TimeInterval(spanMinutes) * 60)
    }

    // MARK: - Pure scan

    func testOwnerNightRefinesOnsetPastBridgedRestlessness() throws {
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: ownerNightEpochs())
        // Acceptance (a): the onset anchors at the first sustained quiet run
        // AFTER the restlessness (minute 135 ≈ 04:15), never at the lull.
        XCTAssertEqual(refined.start.timeIntervalSince(base),
                       135 * 60,
                       accuracy: 1)
        XCTAssertEqual(refined.end, windowEnd,
                       "the proposed end was right; it must not move")
    }

    func testQuietThroughoutIsIdentity() throws {
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: quietEpochs())
        XCTAssertEqual(refined.start, base)
        XCTAssertEqual(refined.end, windowEnd)
    }

    func testNoEpochsAndUnvalidatedEpochsAreIdentity() throws {
        let none = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: [])
        XCTAssertEqual(none.start, base)
        XCTAssertEqual(none.end, windowEnd)
        // Acceptance (c): unvalidated epochs are provenance metadata, never
        // refinement evidence — the restless night must NOT refine.
        let unvalidated = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd,
            epochs: ownerNightEpochs(validated: false))
        XCTAssertEqual(unvalidated.start, base)
        XCTAssertEqual(unvalidated.end, windowEnd)
    }

    func testEstablishedSleepLocksOnsetAgainstMidNightWake() throws {
        // Quiet 60 min (>= the 45-min established-sleep floor), a 30-min
        // mid-night wake, then quiet: mid-sleep wake belongs to the duration
        // deduction, never to a boundary move.
        var epochs = quietEpochs(fromMinute: 0, toMinute: 60)
        for minute in stride(from: 60, to: 90, by: 5) {
            epochs.append(epoch(offsetMinutes: minute, intensity: 0.45))
        }
        epochs.append(contentsOf: quietEpochs(fromMinute: 90))
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: epochs)
        XCTAssertEqual(refined.start, base)
        XCTAssertEqual(refined.end, windowEnd)
    }

    func testTrailingSustainedRestlessnessTrimsEnd() throws {
        // Symmetry: quiet 300 min, then a sustained 45-min elevated tail —
        // the end clamps back to the last sustained quiet run.
        var epochs = quietEpochs(fromMinute: 0, toMinute: 300)
        for minute in stride(from: 300, to: spanMinutes, by: 5) {
            epochs.append(epoch(offsetMinutes: minute, intensity: 0.45))
        }
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: epochs)
        XCTAssertEqual(refined.start, base)
        XCTAssertEqual(refined.end.timeIntervalSince(base),
                       300 * 60,
                       accuracy: 1)
    }

    func testScatteredSubFloorTailDoesNotTrimEnd() throws {
        // Device-calibrated (2026-08-30 defect night): the real tail
        // (07:28–07:45) held scattered sub-floor stirring — normal light
        // morning sleep — and the proposed 07:45 end was CORRECT. The end
        // clamps only past SUSTAINED elevated evidence, never past
        // unqualified scatter.
        var epochs = quietEpochs(fromMinute: 0, toMinute: 325)
        for minute in stride(from: 325, to: spanMinutes, by: 5) {
            let stir = minute == 325 || minute == 335
            epochs.append(epoch(offsetMinutes: minute,
                                intensity: stir ? 0.45 : 0.02))
        }
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: epochs)
        XCTAssertEqual(refined.start, base)
        XCTAssertEqual(refined.end, windowEnd)
    }

    func testIsolatedSupportEpochIsAbsorbedIntoQuietRun() throws {
        // Sustained restlessness, then a 30-min trailing quiet run holding
        // one isolated support-level epoch (a rollover). Absorption keeps
        // the run continuous at 30 covered minutes, so it still anchors;
        // without absorption neither fragment reaches the 20-min floor.
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for minute in stride(from: 0, to: 315, by: 5) {
            epochs.append(epoch(offsetMinutes: minute, intensity: 0.45))
        }
        for minute in stride(from: 315, to: spanMinutes, by: 5) {
            let support = minute == 330
            epochs.append(epoch(offsetMinutes: minute,
                                intensity: support ? 0.30 : 0.02))
        }
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: epochs)
        XCTAssertEqual(refined.start.timeIntervalSince(base),
                       315 * 60,
                       accuracy: 1)
    }

    func testRefinementNeverWidensBeyondWindow() throws {
        // Acceptance (e): quiet epochs extending an hour past both bounds
        // must never move the start earlier or the end later.
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for minute in stride(from: -60, to: spanMinutes + 60, by: 5) {
            epochs.append(epoch(offsetMinutes: minute, intensity: 0.02))
        }
        let refined = try SessionStore.motionQuiescenceRefinedBounds(
            start: base, end: windowEnd, epochs: epochs)
        XCTAssertEqual(refined.start, base)
        XCTAssertEqual(refined.end, windowEnd)
    }

    // MARK: - Candidate integration

    private func overnightSession(
        epochs: [AtriaRecoveredMotionEpoch]?
    ) -> SavedSession {
        let hours = TimeInterval(spanMinutes) * 60
        let points = stride(from: 0.0, to: hours, by: 1.0).map {
            SavedSession.Point(
                t: $0,
                bpm: 58 + Int($0.truncatingRemainder(dividingBy: 7)) % 5
            )
        }
        var session = SavedSession(id: UUID(),
                                   start: base,
                                   end: base.addingTimeInterval(hours),
                                   label: "All-day wear",
                                   points: points)
        session.recoveredMotionEpochs = epochs
        return session
    }

    private func candidates(
        epochs: [AtriaRecoveredMotionEpoch]?
    ) -> [AggregateSleepCandidate] {
        // `.sessionOnly` keeps the host's device-use journal and external
        // stores out of the fixture (journal contamination pin).
        SessionStore.aggregateSleepCandidates(
            in: [overnightSession(epochs: epochs)],
            rest: 62,
            maxHR: 190,
            calendar: .current,
            historicalMotionPolicy: .sessionOnly
        )
    }

    func testAggregateCandidateOnsetRefinesToSustainedQuiet() {
        guard let candidate = candidates(epochs: ownerNightEpochs()).first
        else {
            XCTFail("expected an overnight review candidate")
            return
        }
        // Acceptance (a): start refines to the sustained quiet onset; the
        // end stays; duration follows the clamp (trimmed lead is never
        // credited sleep).
        XCTAssertEqual(candidate.start.timeIntervalSince(base),
                       135 * 60,
                       accuracy: 1)
        XCTAssertEqual(candidate.end, windowEnd)
        XCTAssertEqual(candidate.duration,
                       TimeInterval((spanMinutes - 135) * 60),
                       accuracy: 60)
        XCTAssertEqual(candidate.span,
                       TimeInterval((spanMinutes - 135) * 60),
                       accuracy: 1)
        XCTAssertTrue(candidate.reason.contains("quiescence"),
                      "refinement must leave a named diagnostic detail")
    }

    func testAggregateCandidateQuietNightBoundsUnchanged() {
        guard let candidate = candidates(epochs: quietEpochs()).first else {
            XCTFail("expected an overnight review candidate")
            return
        }
        // Acceptance (b): quiet throughout — bounds and duration unchanged.
        XCTAssertEqual(candidate.start, base)
        XCTAssertEqual(candidate.end, windowEnd)
        XCTAssertEqual(candidate.duration,
                       TimeInterval(spanMinutes * 60),
                       accuracy: 1)
        XCTAssertFalse(candidate.reason.contains("quiescence"))
    }

    func testAggregateCandidateWithoutMotionEvidenceUnchanged() {
        guard let candidate = candidates(epochs: nil).first else {
            XCTFail("expected an overnight review candidate")
            return
        }
        // Acceptance (c): no motion evidence — the HR-only proposal keeps
        // exactly today's bounds and duration (regression pin).
        XCTAssertEqual(candidate.start, base)
        XCTAssertEqual(candidate.end, windowEnd)
        XCTAssertEqual(candidate.duration, candidate.span, accuracy: 1)
        XCTAssertFalse(candidate.reason.contains("quiescence"))
    }

    func testAggregateCandidateRefinedBelowFloorDies() {
        // Acceptance (d): a night that is restless for all but a trailing
        // 30 quiet minutes refines below the 3-h main-sleep floor and must
        // die (named skip), never propose a sliver.
        var epochs: [AtriaRecoveredMotionEpoch] = []
        for minute in stride(from: 0, to: 315, by: 5) {
            epochs.append(epoch(offsetMinutes: minute, intensity: 0.45))
        }
        epochs.append(contentsOf: quietEpochs(fromMinute: 315))
        let all = candidates(epochs: epochs)
        XCTAssertTrue(
            all.filter { $0.end > base && $0.start < windowEnd }.isEmpty,
            "refined-below-floor candidate must die, got \(all.map(\.reason))"
        )
    }
}
