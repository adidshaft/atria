import XCTest
@testable import Atria

/// Sleep wake-expansion (user 2026-07-08): a wake-then-sleep-again should EXTEND
/// the confirmed night. Locks the pure extend-only decision so it can only GROW
/// an AUTO night — never shrink, split, trim the head, absorb a separate nap, or
/// clobber a user-authored/edited night. (Hardened after an adversarial review
/// found a manual-night-clobber blocker + a head-trim.)
final class AtriaSleepExtendTests: XCTestCase {
    private func at(_ h: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + h * 3600) }

    private func candidate(kind: String = "unambiguous_hr", start: Date, end: Date) -> AggregateSleepCandidate {
        AggregateSleepCandidate(
            kind: kind, day: start, sessions: 1, start: start, end: end,
            duration: end.timeIntervalSince(start), span: end.timeIntervalSince(start),
            maxGap: 0, samples: 100, avgHR: 55, peakHR: 70, hrStandardDeviation: 3,
            medianHR: 55, hrP90: 62, elevatedSampleFraction: 0.01, restingHR: 52,
            confidence: .high, reason: "test", motionHintCount: 0, motionHintKinds: "",
            motionEvidenceSource: "none", motionEvidenceValidated: false, motionShortCount: 0,
            motionShortMean: nil, motionShortMin: nil, motionShortMax: nil, motionShortOverOneCount: 0,
            historicalMotionStatus: "none", historicalMotionReason: "none", historicalMotionRows: 0,
            historicalMotionValidatedRows: 0, historicalMotionCoverageSeconds: 0,
            historicalMotionMeanVectorDelta: nil, historicalMotionP95VectorDelta: nil,
            historicalMotionMagnitudeStdDev: nil, historicalMotionArchiveFirstUnix: 0,
            historicalMotionArchiveLastUnix: 0, historicalMotionNearestSeparationSeconds: 0,
            historicalMotionValidated: false)
    }

    private func sleep(source: String = "auto_sleep", start: Date, end: Date) -> UserConfirmedSleep {
        UserConfirmedSleep(
            id: "\(source)-\(Int(start.timeIntervalSince1970))", createdAt: start,
            start: start, end: end, source: source, confidence: "high", sessions: 1,
            samples: 100, avgHR: 55, peakHR: 70, restingHR: 52, hrv: 40, hrvWindowCount: 10,
            duration: end.timeIntervalSince(start), span: end.timeIntervalSince(start),
            reason: "test", motionSource: "none", motionValidated: false, stageSegments: nil)
    }

    func testExtendsAutoNightWhenReSleepGrowsIt() {
        // Confirmed auto night 0h→7h; user re-sleeps, candidate now spans 0h→9h.
        XCTAssertTrue(SessionStore.sleepExtendReplacement(
            existing: [sleep(start: at(0), end: at(7))], candidate: candidate(start: at(0), end: at(9))))
    }

    func testDoesNotExtendWhenNoLaterEnd() {
        let existing = [sleep(start: at(0), end: at(9))]
        XCTAssertFalse(SessionStore.sleepExtendReplacement(existing: existing, candidate: candidate(start: at(0), end: at(9))))
        XCTAssertFalse(SessionStore.sleepExtendReplacement(existing: existing, candidate: candidate(start: at(0), end: at(7))))
    }

    func testDoesNotExtendForNapCandidate() {
        XCTAssertFalse(SessionStore.sleepExtendReplacement(
            existing: [sleep(start: at(0), end: at(7))], candidate: candidate(kind: "nap_candidate", start: at(0), end: at(9))))
    }

    func testDoesNotAbsorbSeparateLaterWindow() {
        XCTAssertFalse(SessionStore.sleepExtendReplacement(
            existing: [sleep(start: at(0), end: at(7))], candidate: candidate(start: at(14), end: at(16))))
    }

    func testDoesNotExtendWhenOnlyANapOverlaps() {
        XCTAssertFalse(SessionStore.sleepExtendReplacement(
            existing: [sleep(source: "manual_nap", start: at(4), end: at(5.5))], candidate: candidate(start: at(4), end: at(9))))
    }

    // BLOCKER fix: a manual / user-adjusted night must NEVER be clobbered by extend.
    func testDoesNotClobberUserAuthoredNight() {
        for source in ["manual_sleep", "user_adjusted_sleep"] {
            XCTAssertFalse(SessionStore.sleepExtendReplacement(
                existing: [sleep(source: source, start: at(0), end: at(7))],
                candidate: candidate(start: at(0), end: at(9))),
                "\(source) must be left alone by the auto extend")
        }
        XCTAssertTrue(SessionStore.isUserAuthoredSleepSource("manual_sleep"))
        XCTAssertTrue(SessionStore.isUserAuthoredSleepSource("user_adjusted_nap"))
        XCTAssertFalse(SessionStore.isUserAuthoredSleepSource("auto_confirmed_sleep"))
    }

    // Head-trim fix: a later-starting cluster (e.g. split off by a >2h strap-dead
    // gap) must NOT extend — that would trim the head / fabricate across the gap.
    func testDoesNotTrimHeadWithLaterStartingCandidate() {
        XCTAssertFalse(SessionStore.sleepExtendReplacement(
            existing: [sleep(start: at(0), end: at(7))], candidate: candidate(start: at(2), end: at(9))))
    }
}
