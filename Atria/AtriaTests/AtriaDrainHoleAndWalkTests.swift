import XCTest
@testable import Atria

/// 2026-09-30 device pull: live HR paused ~2 min every ~10 min for history
/// drain slices, and each pause cost five minutes of stress. Drained history
/// fills those holes without touching minutes that already have live HR.
final class AtriaStressArchiveHoleFillTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var personalization: AtriaPhysiologicalStressModel.Personalization {
        .init(restingHeartRate: 60,
              maximumHeartRate: 190,
              restingBaselineDayCount: 20,
              hrvBaseline: .init(medianLnRMSSD: log(80),
                                 robustScale: 0.2,
                                 qualifiedDayCount: 20))
    }

    private typealias Replay = AtriaHistoricalStressReplay

    private func rows(from start: TimeInterval, to end: TimeInterval, bpm: Int) -> [Replay.HeartRateRow] {
        stride(from: start, to: end, by: 1).map {
            Replay.HeartRateRow(date: now.addingTimeInterval($0), bpm: bpm + Int($0.truncatingRemainder(dividingBy: 3)))
        }
    }

    /// Two live sessions 30 min apart in total: the first has an internal
    /// 2-minute drain hole, then a 2-minute gap before the second.
    private func liveSnapshot() -> Replay.Snapshot {
        let first = rows(from: -1_800, to: -1_320, bpm: 80) + rows(from: -1_200, to: -900, bpm: 80)
        let second = rows(from: -780, to: -60, bpm: 82)
        return Replay.Snapshot(
            sessions: [
                .init(id: UUID(), start: now.addingTimeInterval(-780), end: now.addingTimeInterval(-60),
                      heartRates: second, rrIntervals: []),
                .init(id: UUID(), start: now.addingTimeInterval(-1_800), end: now.addingTimeInterval(-900),
                      heartRates: first, rrIntervals: []),
            ],
            personalization: personalization,
            now: now
        )
    }

    func testDrainedRowsFillLiveHolesAndScoreMoreMinutes() {
        let live = liveSnapshot()
        let archive = rows(from: -1_800, to: -60, bpm: 95)
        let filled = Replay.fillingHeartRateHoles(in: live, from: archive)

        let liveDates = Set(live.sessions.flatMap(\.heartRates).map(\.date))
        let filledRows = filled.sessions.flatMap(\.heartRates)
        // Every live row survives with its live value; archive rows only land
        // where there was no live HR.
        for row in filledRows where liveDates.contains(row.date) {
            XCTAssertNotEqual(row.bpm / 5, 95 / 5, "an archive value replaced live HR at \(row.date)")
        }
        let added = filledRows.filter { !liveDates.contains($0.date) }
        XCTAssertEqual(added.count, 120 + 120, "the internal hole and the between-session gap")
        XCTAssertEqual(filled.sessions.count, 3, "the between-session gap becomes one archive session")
        XCTAssertEqual(filled.sessions.map(\.start), filled.sessions.map(\.start).sorted(by: >),
                       "the caller's newest-first order is kept")

        let before = Replay.evaluate(live).facts.count
        let after = Replay.evaluate(filled).facts.count
        XCTAssertGreaterThan(after, before + 8, "each filled hole restores its five-minute warm-up")
    }

    func testNoArchiveOrNoHolesLeavesSnapshotUnchanged() {
        let live = liveSnapshot()
        XCTAssertEqual(Replay.fillingHeartRateHoles(in: live, from: []), live)
        let onlyOverlapping = rows(from: -700, to: -100, bpm: 95)
        XCTAssertEqual(Replay.fillingHeartRateHoles(in: live, from: onlyOverlapping), live)
    }
}

final class AtriaWalkBoutDetectorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ counts: [Int]) -> [AtriaStrapStepMinuteLog.Minute] {
        counts.enumerated().compactMap { index, steps in
            steps > 0 ? .init(start: base.addingTimeInterval(TimeInterval(index * 60)), steps: steps) : nil
        }
    }

    func testTenMinuteWalkWithOneSlowCrossingIsOneFinishedBout() throws {
        let counts = [3, 0] + Array(repeating: 105, count: 5) + [30] + Array(repeating: 110, count: 5) + [2, 0, 0, 0, 0]
        let now = base.addingTimeInterval(TimeInterval(counts.count * 60))
        let bout = try XCTUnwrap(AtriaWalkBoutDetector.latestBout(minutes: minutes(counts), now: now))
        XCTAssertEqual(bout.start, base.addingTimeInterval(120))
        XCTAssertEqual(bout.durationSeconds, 11 * 60)
        XCTAssertEqual(bout.steps, 5 * 105 + 30 + 5 * 110)
        XCTAssertFalse(bout.ongoing)
    }

    func testDeskShufflingAndShortWalksAreNotWalks() {
        let desk = Array(repeating: 12, count: 40)
        let short = [0] + Array(repeating: 110, count: 6) + [0, 0, 0, 0]
        for counts in [desk, short] {
            let now = base.addingTimeInterval(TimeInterval(counts.count * 60))
            XCTAssertNil(AtriaWalkBoutDetector.latestBout(minutes: minutes(counts), now: now))
        }
    }

    func testWalkInProgressIsOngoing() throws {
        let counts = Array(repeating: 100, count: 9)
        let now = base.addingTimeInterval(TimeInterval(counts.count * 60 - 20))
        let bout = try XCTUnwrap(AtriaWalkBoutDetector.latestBout(minutes: minutes(counts), now: now))
        XCTAssertTrue(bout.ongoing)
    }

    func testMinuteLogStoresDeltasAndNeverFabricatesStepsAcrossResetsOrSilence() {
        let log = AtriaStrapStepMinuteLog()
        log.record(sessionSteps: 500, at: base)                               // baseline only
        log.record(sessionSteps: 560, at: base.addingTimeInterval(30))        // +60
        log.record(sessionSteps: 10, at: base.addingTimeInterval(45))         // session reset: nothing
        log.record(sessionSteps: 50, at: base.addingTimeInterval(70))         // +40 next minute
        log.record(sessionSteps: 900, at: base.addingTimeInterval(600))       // after silence: nothing
        XCTAssertEqual(log.snapshot().map(\.steps), [60, 40])
    }
}

/// Device 2026-09-29/30 battery curve: 45→19 in 5 min, 39→70 in 6 min with no
/// charger seen, then 70 shown all night while the real level fell to 30.
final class AtriaBatteryRateLimitTests: XCTestCase {
    private typealias BLE = AtriaBLEManager
    private let t0 = Date(timeIntervalSince1970: 1_790_700_000)

    private func minutes(_ value: Double) -> Date { t0.addingTimeInterval(value * 60) }

    func testInstantJumpsAreQuarantinedFromEverySource() {
        guard case .quarantine = BLE.batteryLevelAcceptanceDecision(
            previousLevel: 39, previousAcceptedAt: t0, incomingLevel: 70,
            receivedAt: minutes(6), pending: nil
        ) else { return XCTFail("a 31-point rise in 6 min without charging is not physical") }
        guard case .quarantine = BLE.batteryEventAcceptanceDecision(
            previousLevel: 45, previousAcceptedAt: t0,
            reading: .init(level: 19, millivolts: 3_600, isCharging: false),
            receivedAt: minutes(5), pending: nil
        ) else { return XCTFail("the 0x30 event may no longer move the display anywhere at once") }
    }

    func testNormalDischargeChargingAndLongGapsStillLandImmediately() {
        XCTAssertEqual(BLE.batteryLevelAcceptanceDecision(
            previousLevel: 45, previousAcceptedAt: t0, incomingLevel: 44,
            receivedAt: minutes(30), pending: nil), .accept)
        XCTAssertEqual(BLE.batteryLevelAcceptanceDecision(
            previousLevel: 40, previousAcceptedAt: t0, incomingLevel: 41,
            receivedAt: minutes(1), pending: nil), .accept, "cable charge, 1%/min")
        XCTAssertEqual(BLE.batteryEventAcceptanceDecision(
            previousLevel: 39, previousAcceptedAt: t0,
            reading: .init(level: 30, millivolts: 3_700, isCharging: false),
            receivedAt: minutes(8 * 60), pending: nil), .accept, "a night away from the phone")
        XCTAssertNil(BLE.batteryImplausibleRateCorroborationSpan(
            previousLevel: 30, previousAcceptedAt: t0, incomingLevel: 75,
            receivedAt: minutes(45)), "an unseen 45-minute charge is physically possible")
    }

    func testAWrongDisplayedValueIsCorrectedBySlowNotifyingSource() {
        // Display wrongly at 70; the strap truly reads ~30 and 2A19 only
        // notifies on change. Two agreeing readings 10+ min apart correct it.
        var pending: BLE.BatteryDropCandidate?
        guard case .quarantine(let first) = BLE.batteryLevelAcceptanceDecision(
            previousLevel: 70, previousAcceptedAt: t0, incomingLevel: 30,
            receivedAt: minutes(5), pending: pending
        ) else { return XCTFail("first contradicting reading waits for corroboration") }
        pending = first
        XCTAssertEqual(BLE.batteryLevelAcceptanceDecision(
            previousLevel: 70, previousAcceptedAt: t0, incomingLevel: 29,
            receivedAt: minutes(50), pending: pending
        ), .accept, "the old rule needed 3 readings inside 5 minutes and never got them")
    }
}

/// Owner 2026-09-30: backlog catch-up while worn happens overnight / on
/// charge, read from the wearer rather than the clock.
final class AtriaBacklogCatchUpWindowTests: XCTestCase {
    private typealias B = AtriaBLEManager
    private let now = Date(timeIntervalSince1970: 1_790_700_000)

    func testWindowOpensOnPhoneChargeOrDeepRestOnly() {
        XCTAssertTrue(B.backlogCatchUpWindowOpen(phoneCharging: true, appForeground: true,
                                                 stepsQuietFor: 0, heartRate: 120, restingHeartRate: 55))
        XCTAssertTrue(B.backlogCatchUpWindowOpen(phoneCharging: false, appForeground: false,
                                                 stepsQuietFor: 50 * 60, heartRate: 58, restingHeartRate: 55),
                      "asleep at 1 pm counts: the clock is never consulted")
        XCTAssertFalse(B.backlogCatchUpWindowOpen(phoneCharging: false, appForeground: false,
                                                  stepsQuietFor: 50 * 60, heartRate: 80, restingHeartRate: 55),
                       "sitting still but awake")
        XCTAssertFalse(B.backlogCatchUpWindowOpen(phoneCharging: false, appForeground: false,
                                                  stepsQuietFor: 10 * 60, heartRate: 58, restingHeartRate: 55))
        XCTAssertFalse(B.backlogCatchUpWindowOpen(phoneCharging: false, appForeground: true,
                                                  stepsQuietFor: 50 * 60, heartRate: 58, restingHeartRate: 55))
    }

    func testWornDaytimeLinkIsNeverPausedAndWindowSlicesRunLongAndOften() {
        XCTAssertFalse(B.largeBacklogSliceIsDue(pendingRecords: 16_045, lastSliceFinishedAt: nil,
                                                lastSliceYieldedRows: true, now: now, catchUpWindowOpen: false))
        XCTAssertTrue(B.largeBacklogSliceIsDue(pendingRecords: 16_045,
                                               lastSliceFinishedAt: now.addingTimeInterval(-61),
                                               lastSliceYieldedRows: true, now: now, catchUpWindowOpen: true))
        XCTAssertEqual(B.backlogSliceLimit(attendedForeground: false, catchUpWindow: true),
                       B.backlogCatchUpSliceLimit)
        XCTAssertEqual(B.backlogSliceLimit(attendedForeground: true, catchUpWindow: true),
                       B.backlogSliceForegroundLimit, "a user looking at the app gets live HR back fast")
        XCTAssertFalse(B.shouldFinishIdleWindowHistoryDrainAtACKBoundary(
            idleWindowDrainOwnsLink: true, acknowledgedPages: 40, sliceStartPendingRecords: 16_045,
            heartRatePauseElapsed: B.backlogSliceBackgroundLimit, catchUpWindow: true))
    }

    func testWindowDrainsASmallBacklogTooNotOnlyALargeOne() {
        XCTAssertTrue(B.largeBacklogSliceIsDue(pendingRecords: 292,
                                               lastSliceFinishedAt: now.addingTimeInterval(-61),
                                               lastSliceYieldedRows: true, now: now, catchUpWindowOpen: true))
        XCTAssertFalse(B.largeBacklogSliceIsDue(pendingRecords: 100,
                                                lastSliceFinishedAt: nil,
                                                lastSliceYieldedRows: true, now: now, catchUpWindowOpen: true),
                       "a dry live tail is still not backlog")
        XCTAssertFalse(B.largeBacklogSliceIsDue(pendingRecords: 292, lastSliceFinishedAt: nil,
                                                lastSliceYieldedRows: true, now: now),
                       "legacy callers keep the 3 h rule")
    }

    func testDrySliceCannotParkCatchUpInsideTheWindow() {
        XCTAssertFalse(B.largeBacklogSliceIsDue(pendingRecords: 16_045,
                                                lastSliceFinishedAt: now.addingTimeInterval(-3_600),
                                                lastSliceYieldedRows: false, now: now, catchUpWindowOpen: false))
        XCTAssertFalse(B.largeBacklogSliceIsDue(pendingRecords: 16_045,
                                                lastSliceFinishedAt: now.addingTimeInterval(-120),
                                                lastSliceYieldedRows: false, now: now, catchUpWindowOpen: true))
        XCTAssertTrue(B.largeBacklogSliceIsDue(pendingRecords: 16_045,
                                               lastSliceFinishedAt: now.addingTimeInterval(-601),
                                               lastSliceYieldedRows: false, now: now, catchUpWindowOpen: true))
    }

    /// Owner 2026-10-01: steps within ~30-40 min. Below the 3 h large-backlog
    /// threshold a worn, awake link now gets one short slice per 30 min.
    func testKeepUpSliceSyncsHalfAnHourOfDataEveryHalfHour() {
        let due = B.keepUpSliceIsDue(pendingRecords: 200, lastSliceFinishedAt: now.addingTimeInterval(-1_801),
                                     catchUpWindowOpen: false, now: now)
        XCTAssertTrue(due)
        XCTAssertFalse(B.keepUpSliceIsDue(pendingRecords: 200, lastSliceFinishedAt: now.addingTimeInterval(-600),
                                          catchUpWindowOpen: false, now: now), "at most one per 30 min")
        XCTAssertFalse(B.keepUpSliceIsDue(pendingRecords: 100, lastSliceFinishedAt: nil,
                                          catchUpWindowOpen: false, now: now), "a dry live tail is not backlog")
        XCTAssertFalse(B.keepUpSliceIsDue(pendingRecords: 200, lastSliceFinishedAt: nil,
                                          catchUpWindowOpen: true, now: now), "the window has its own rules")
        XCTAssertFalse(B.keepUpSliceIsDue(pendingRecords: 16_000, lastSliceFinishedAt: nil,
                                          catchUpWindowOpen: false, now: now), "large backlogs wait for the window")
        XCTAssertFalse(B.shouldFinishIdleWindowHistoryDrainAtACKBoundary(
            idleWindowDrainOwnsLink: true, acknowledgedPages: 2, sliceStartPendingRecords: 200,
            heartRatePauseElapsed: 20), "a keep-up slice is not one page")
        XCTAssertTrue(B.shouldFinishIdleWindowHistoryDrainAtACKBoundary(
            idleWindowDrainOwnsLink: true, acknowledgedPages: 20, sliceStartPendingRecords: 200,
            heartRatePauseElapsed: B.keepUpSliceLimit))
        XCTAssertEqual(B.idleWindowHistoryDrainAbsoluteBudgetLimit(chargingOrOffWrist: false,
                                                                   keepUpBacklog: true), B.keepUpSliceLimit)
    }
}

/// Device 2026-10-01: every day's strain carried the morning snapshot's
/// "unavailable" quality, so history showed "--" and the trend dropped it.
final class AtriaStrainMorningFreezeTests: XCTestCase {
    func testMorningFreezeArtifactNoLongerHidesARealStrain() {
        let resolved = Metrics.StrainPresentation.resolve(value: 8.7, coverageFraction: 0,
                                                          baseConfidence: "dated history",
                                                          persistedQuality: .unavailable)
        XCTAssertEqual(resolved.value, 8.7)
        XCTAssertNotEqual(resolved.quality, .unavailable)
    }

    func testGenuinePartialAndUnavailableEvidenceIsUnchanged() {
        XCTAssertEqual(Metrics.StrainPresentation.resolve(value: 8.7, coverageFraction: 0.4,
                                                          baseConfidence: "dated history",
                                                          persistedQuality: .partial).quality, .partial)
        XCTAssertEqual(Metrics.StrainPresentation.resolve(value: 8.7, coverageFraction: 0.5,
                                                          baseConfidence: "dated history",
                                                          persistedQuality: .unavailable).quality, .unavailable,
                       "an unavailable verdict with real coverage is not the morning artifact")
        XCTAssertNil(Metrics.StrainPresentation.resolve(value: nil, coverageFraction: 0,
                                                        baseConfidence: "dated history",
                                                        persistedQuality: .unavailable).value)
    }
}

/// Owner 2026-10-01: show the wearer how to flush a backlog faster.
final class AtriaFasterSyncTipTests: XCTestCase {
    func testTipOnlyWhileALargeBacklogWaitsAndMatchesThePhoneState() {
        typealias P = AtriaHomeRecoverySyncPresentation
        XCTAssertNil(P.fasterSyncTip(strapPendingRecords: nil, phoneCharging: false))
        XCTAssertNil(P.fasterSyncTip(strapPendingRecords: 300, phoneCharging: false),
                     "a small backlog keeps up on its own")
        XCTAssertEqual(P.fasterSyncTip(strapPendingRecords: 7_650, phoneCharging: false)?.title,
                       "Tip · Charge & lock your phone to sync faster")
        XCTAssertEqual(P.fasterSyncTip(strapPendingRecords: 7_650, phoneCharging: true)?.title,
                       "Tip · Lock your phone to sync faster")
    }
}

/// 2026-10-01 pull: 14 gap windows sat at 0% behind the drain cursor; the
/// full-drain authority minted for one of them stayed draining and deferred
/// every recovered projection.
final class AtriaGapWindowsDrainedPastTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "AtriaGapWindowsDrainedPastTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            AtriaHistoricalGapLedger.resetStorageForTesting(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    private func addClosedWindow(at start: Date, seconds: TimeInterval, defaults: UserDefaults) {
        XCTAssertTrue(AtriaHistoricalGapLedger.beginGap(at: start, reason: "disconnect", defaults: defaults))
        XCTAssertTrue(AtriaHistoricalGapLedger.closeOpenGap(at: start.addingTimeInterval(seconds),
                                                            defaults: defaults))
    }

    func testWindowsTheDrainHasPassedSettleAndLaterOnesStay() throws {
        try withDefaults { defaults in
            let base = Date(timeIntervalSince1970: 1_790_840_000)
            addClosedWindow(at: base, seconds: 62, defaults: defaults)
            addClosedWindow(at: base.addingTimeInterval(3_600), seconds: 61, defaults: defaults)
            XCTAssertEqual(AtriaHistoricalGapLedger.windows(defaults: defaults).count, 2)

            let cursor = base.addingTimeInterval(1_800).timeIntervalSince1970
            let settlement = try XCTUnwrap(AtriaHistoricalGapLedger.settleWindowsDrainedPast(
                cursorUnix: cursor, defaults: defaults))
            XCTAssertEqual(settlement.settledWindows, 1)
            XCTAssertEqual(settlement.remainingWindows, 1)
            let left = AtriaHistoricalGapLedger.windows(defaults: defaults)
            XCTAssertEqual(left.map(\.start), [base.addingTimeInterval(3_600)],
                           "the window ahead of the cursor can still be drained")
        }
    }

    func testCursorJustPastTheEndWaitsForTheMargin() throws {
        try withDefaults { defaults in
            let base = Date(timeIntervalSince1970: 1_790_840_000)
            addClosedWindow(at: base, seconds: 62, defaults: defaults)
            let end = base.addingTimeInterval(62).timeIntervalSince1970
            let early = AtriaHistoricalGapLedger.settleWindowsDrainedPast(cursorUnix: end + 30,
                                                                         defaults: defaults)
            XCTAssertEqual(early?.settledWindows, 0)
            let late = AtriaHistoricalGapLedger.settleWindowsDrainedPast(
                cursorUnix: end + AtriaHistoricalGapLedger.drainedPastMargin, defaults: defaults)
            XCTAssertEqual(late?.settledWindows, 1)
        }
    }

    func testOpenWindowAndUnknownCursorAreNeverSettled() throws {
        try withDefaults { defaults in
            let base = Date(timeIntervalSince1970: 1_790_840_000)
            XCTAssertTrue(AtriaHistoricalGapLedger.beginGap(at: base, reason: "disconnect", defaults: defaults))
            XCTAssertNil(AtriaHistoricalGapLedger.settleWindowsDrainedPast(cursorUnix: 0, defaults: defaults))
            let settlement = AtriaHistoricalGapLedger.settleWindowsDrainedPast(
                cursorUnix: base.addingTimeInterval(86_400).timeIntervalSince1970, defaults: defaults)
            XCTAssertEqual(settlement?.settledWindows, 0, "an open window's end is not known yet")
            XCTAssertTrue(AtriaHistoricalGapLedger.hasOpenWindow(defaults: defaults))
        }
    }
}

/// 2026-10-01 post-gym pull: a draining authority refused the oldest-first
/// slice that drains toward its own gap; history sat at 20:43 for 80 min.
final class AtriaDrainingAuthorityAdmitsSliceTests: XCTestCase {
    func testOldestFirstSlicesPassADrainingAuthority() {
        typealias B = AtriaBLEManager
        XCTAssertTrue(B.drainingAuthorityAdmitsHistoryRequest(reason: "idle_window_drain", strandedResume: false))
        XCTAssertTrue(B.drainingAuthorityAdmitsHistoryRequest(reason: "natural_gap_drain", strandedResume: false))
        XCTAssertTrue(B.drainingAuthorityAdmitsHistoryRequest(reason: "interrupted_full_drain_relaunch", strandedResume: false))
        XCTAssertFalse(B.drainingAuthorityAdmitsHistoryRequest(reason: "maintenance_ticker", strandedResume: false),
                       "other lanes still wait for the persisted resume")
        XCTAssertTrue(B.drainingAuthorityAdmitsHistoryRequest(reason: "maintenance_ticker", strandedResume: true))
    }
}

/// Owner 2026-10-01: activities never share time. A detection 9:36–10:07
/// that grazed a saved 9:22–9:37 walk was shown overlapping it.
final class AtriaActivityOverlapPolicyTests: XCTestCase {
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_790_870_000 + minutes * 60) }

    func testAGrazingDetectionIsTrimmedToTheFreeStretch() {
        let walk = DateInterval(start: at(0), end: at(15))
        let free = AtriaActivityOverlapPolicy.freeWindow(DateInterval(start: at(14), end: at(45)),
                                                         occupied: [walk])
        XCTAssertEqual(free, DateInterval(start: at(15), end: at(45)))
    }

    func testTheLongestGapWinsBetweenTwoSavedActivities() {
        let free = AtriaActivityOverlapPolicy.freeWindow(
            DateInterval(start: at(0), end: at(60)),
            occupied: [DateInterval(start: at(10), end: at(20)), DateInterval(start: at(50), end: at(70))]
        )
        XCTAssertEqual(free, DateInterval(start: at(20), end: at(50)))
    }

    func testAnAlmostCoveredDetectionIsNotOffered() {
        XCTAssertNil(AtriaActivityOverlapPolicy.freeWindow(
            DateInterval(start: at(0), end: at(20)),
            occupied: [DateInterval(start: at(-5), end: at(17))]
        ), "three minutes left is not an activity")
    }

    func testAClearDetectionIsUnchanged() {
        let window = DateInterval(start: at(0), end: at(30))
        XCTAssertEqual(AtriaActivityOverlapPolicy.freeWindow(window, occupied: [DateInterval(start: at(40), end: at(50))]),
                       window)
    }
}

final class AtriaActivityTimelineStripLayoutTests: XCTestCase {
    func testBackToBackPillsNeverOverlapAndStayInside() {
        let frames = AtriaActivityTimelineStripLayout.frames(
            spans: [(300, 305), (306, 309), (308, 312)], width: 312)
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.x + a.width, b.x, "pills must not overlap")
        }
        XCTAssertLessThanOrEqual(frames.last!.x + frames.last!.width, 312)
        XCTAssertGreaterThanOrEqual(frames.first!.x, 0)
    }

    func testWidePillsKeepTheirTimePosition() {
        let frames = AtriaActivityTimelineStripLayout.frames(spans: [(10, 80), (120, 200)], width: 300)
        XCTAssertEqual(frames[0].x, 10)
        XCTAssertEqual(frames[1].x, 120)
        XCTAssertEqual(frames[1].width, 80)
    }
}

/// Owner 2026-10-01: Steps headline and bars count the same wake-to-wake
/// window, and the sheet says where strap motion has synced to.
final class AtriaStepsSinceWakeTests: XCTestCase {
    func testCycleFallbackFoldsReceiptsIntoTheCycleHoldingTheirMiddle() {
        let base = Date(timeIntervalSince1970: 1_790_800_000)
        let windows = [DateInterval(start: base, end: base.addingTimeInterval(86_400)),
                       DateInterval(start: base.addingTimeInterval(86_400), end: base.addingTimeInterval(2 * 86_400))]
        func receipt(_ s: TimeInterval, _ e: TimeInterval, _ steps: Int) -> HistoricalArchive.MotionTickDayEvidence {
            HistoricalArchive.MotionTickDayEvidence(
                windowStart: base.addingTimeInterval(s), windowEnd: base.addingTimeInterval(e),
                motionTicks: steps * 2, steps: steps, knownCoverageSeconds: Int(e - s),
                missingCoverageSeconds: 0, decodedRows: 100, capturedThrough: base.addingTimeInterval(e))
        }
        let totals = AtriaStepsWeekChart.cycleStepTotals(
            receipts: [receipt(0, 86_000, 6_000),
                       receipt(10_000, 20_000, 900),          // contained duplicate
                       receipt(86_400, 150_000, 4_200)],
            windows: windows)
        XCTAssertEqual(totals[windows[0].start], 6_000)
        XCTAssertEqual(totals[windows[1].start], 4_200)
    }

    func testCompactLabelsStayShort() {
        XCTAssertEqual(AtriaStepsWeekChart.compactCountLabel(steps: 8_508, isPartial: false), "8.5k")
        XCTAssertEqual(AtriaStepsWeekChart.compactCountLabel(steps: 5_762, isPartial: true), "5.8k+")
        XCTAssertEqual(AtriaStepsWeekChart.compactCountLabel(steps: 640, isPartial: false), "640")
    }

    func testSyncStatusNamesWhereMotionHasReached() {
        let now = Date(timeIntervalSince1970: 1_790_873_000)
        XCTAssertTrue(AtriaStrapMotionSyncStatus.make(syncedThrough: now.addingTimeInterval(-300), now: now).isUpToDate)
        let behind = AtriaStrapMotionSyncStatus.make(syncedThrough: now.addingTimeInterval(-6_060), now: now)
        XCTAssertFalse(behind.isUpToDate)
        XCTAssertTrue(behind.title.hasPrefix("Synced to "))
        XCTAssertEqual(behind.detail, "1 h 41 min of motion still on the strap")
        XCTAssertEqual(AtriaStrapMotionSyncStatus.make(syncedThrough: nil, now: now).title,
                       "Waiting for first sync")
    }
}

/// Owner 2026-10-02: after the 07:38 wake Today showed yesterday's 9.0
/// strain (a previous-cycle aggregate read as the new cycle's load), and the
/// rings showed no target zones.
final class AtriaTodayStrainAndRingTargetTests: XCTestCase {
    func testAnAggregateFromAnotherCycleIsNotThisCyclesLoad() {
        let wake = Date(timeIntervalSince1970: 1_790_906_933)
        XCTAssertTrue(AtriaHomeModel.savedAggregateDescribesCycle(aggregateCycleStart: wake, cycleStart: wake))
        XCTAssertFalse(AtriaHomeModel.savedAggregateDescribesCycle(
            aggregateCycleStart: wake.addingTimeInterval(-81_000), cycleStart: wake))
    }

    func testStrainBandIsTargetPlusMinusTheGreenBand() throws {
        let band = try XCTUnwrap(AtriaRingMetricProjection.strainTargetBand(12, greenBand: 1.5))
        XCTAssertEqual(band.lowerBound, 10.5 / 21, accuracy: 0.0001)
        XCTAssertEqual(band.upperBound, 13.5 / 21, accuracy: 0.0001)
        XCTAssertNil(AtriaRingMetricProjection.strainTargetBand(nil, greenBand: 1.5))
        let top = try XCTUnwrap(AtriaRingMetricProjection.strainTargetBand(20.5, greenBand: 1.5))
        XCTAssertEqual(top.upperBound, 1, "the band stays on the ring")
    }

    func testRecoveryAndSleepZonesFollowTheirGreenThresholds() throws {
        let recovery = try XCTUnwrap(AtriaRingMetricProjection.recoveryTargetBand(greenLower: 67))
        XCTAssertEqual(recovery.lowerBound, 0.67, accuracy: 0.0001)
        XCTAssertEqual(recovery.upperBound, 1)
        XCTAssertEqual(AtriaRingMetricProjection.sleepTargetBand, 0.85...1.0)
    }
}

/// Owner 2026-10-02: four "Couldn't sleep" answers, 0 awake minutes; sleep
/// efficiency stuck at "--" after the night's motion synced; one status
/// grammar (ready / calculating / syncing) for every insight.
final class AtriaSleepTruthAndReadinessTests: XCTestCase {
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_790_880_000 + minutes * 60) }

    func testAnsweredWakeBecomesAwakeAndCoverageIsUnchanged() {
        let segments = [
            SleepStageSegment(id: "research-hr-estimate-v1-a", start: at(0), end: at(60), stage: .light),
            SleepStageSegment(id: "research-hr-estimate-v1-b", start: at(60), end: at(120), stage: .deep),
        ]
        let out = SleepStageSegment.overlayingConfirmedWake(
            segments, wake: [DateInterval(start: at(50), end: at(70))])
        let awake = out.filter { $0.stage == .awake }.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(awake, 20 * 60, accuracy: 0.5)
        XCTAssertEqual(out.reduce(0) { $0 + $1.duration }, 120 * 60, accuracy: 0.5,
                       "the night keeps its full coverage")
        XCTAssertTrue(out.allSatisfy { $0.id.hasPrefix("research-hr-estimate-v1-") },
                      "provenance lane is preserved")
        XCTAssertEqual(out.first?.start, at(0))
        XCTAssertEqual(out.last?.end, at(120))
    }

    func testNoAnswersLeaveStagesUntouched() {
        let segments = [SleepStageSegment(id: "x", start: at(0), end: at(30), stage: .rem)]
        XCTAssertEqual(SleepStageSegment.overlayingConfirmedWake(segments, wake: []), segments)
    }

    func testReadinessSaysSyncingCalculatingOrWhy() {
        let end = at(0)
        XCTAssertEqual(AtriaInsightReadiness.resolve(isComputed: true, dataEnd: end, syncedThrough: nil), .ready)
        XCTAssertEqual(AtriaInsightReadiness.resolve(isComputed: false, dataEnd: end, syncedThrough: at(-30)),
                       .syncing(through: at(-30)))
        XCTAssertEqual(AtriaInsightReadiness.resolve(isComputed: false, dataEnd: end, syncedThrough: at(10)),
                       .calculating)
        XCTAssertEqual(AtriaInsightReadiness.resolve(isComputed: false, dataEnd: end, syncedThrough: at(90),
                                                     unavailableReason: "No motion that night"),
                       .unavailable("No motion that night"),
                       "fully synced an hour ago and still missing is final, not pending")
        XCTAssertEqual(AtriaInsightReadiness.calculating.label(), "Calculating")
    }

    func testANightThatJustFinishedSyncingSkipsTheThrottle() {
        let sleep = UserConfirmedSleep(id: "s", createdAt: at(-10), start: at(-400), end: at(-10),
                                       source: "aggregate_sleep", confidence: "user_confirmed_hr_only",
                                       sessions: 1, samples: 100, avgHR: 60, peakHR: 90, restingHR: 55,
                                       hrv: nil, hrvWindowCount: 0, respiratoryRate: nil,
                                       duration: 390 * 60, span: 390 * 60, reason: "test",
                                       motionSource: "historical_gravity_recovered_epoch_v1_missing", motionValidated: false, stageSegments: nil,
                                       eventTimeZoneIdentifier: nil)
        let throttled = SessionStore.compactMotionSleepEvidenceUpgradeCandidateWindows(
            now: at(0), lastAttempt: at(-5), upgradeInFlight: false, recomputeIdle: true,
            confirmedSleeps: [sleep], syncedThrough: at(-20), syncedThroughAtLastAttempt: at(-30))
        XCTAssertNil(throttled, "motion not synced past the night yet: keep the throttle")
        let fired = SessionStore.compactMotionSleepEvidenceUpgradeCandidateWindows(
            now: at(0), lastAttempt: at(-5), upgradeInFlight: false, recomputeIdle: true,
            confirmedSleeps: [sleep], syncedThrough: at(-2), syncedThroughAtLastAttempt: at(-20))
        XCTAssertEqual(fired?.count, 1, "the night's motion just finished syncing: upgrade now")
    }

    // 2026-10-02 device: the recovered night's consumers waited on a full scan
    // watermarked 10-01 22:23 while the dependency needed 10-02 02:43 and the
    // drain cursor was already 10-02 13:29. Oldest-first drain never sends
    // another HISTORY_COMPLETE, so the cursor closes it.
    func testDrainCursorClosesPendingFullScanDependencyOnlyWhenItCoversTheEnd() {
        let previous = Date(timeIntervalSince1970: 1_790_873_620)
        let requiredEnd = Date(timeIntervalSince1970: 1_790_891_580)
        let now = Date(timeIntervalSince1970: 1_790_936_000)
        XCTAssertEqual(
            HistoricalArchive.fullScanWatermarkClosingDependency(
                previous: previous, requiredEnd: requiredEnd,
                drainCursorUnix: 1_790_931_554, now: now),
            Date(timeIntervalSince1970: 1_790_931_554))
        XCTAssertNil(HistoricalArchive.fullScanWatermarkClosingDependency(
            previous: previous, requiredEnd: requiredEnd,
            drainCursorUnix: 1_790_880_000, now: now),
            "a cursor short of the end proves nothing new")
        XCTAssertNil(HistoricalArchive.fullScanWatermarkClosingDependency(
            previous: requiredEnd, requiredEnd: requiredEnd,
            drainCursorUnix: 1_790_931_554, now: now),
            "an already-closed dependency is not re-minted")
        XCTAssertEqual(
            HistoricalArchive.fullScanWatermarkClosingDependency(
                previous: previous, requiredEnd: requiredEnd,
                drainCursorUnix: now.timeIntervalSince1970 + 600, now: now),
            now, "never claims beyond now")
    }

    func testCoverageFailureRetiresOncePerDependencyWhenDrainCursorCoversIt() {
        XCTAssertTrue(AtriaBLEManager.shouldRetireCoverageFailureForDrainCursor(
            requiredEndUnix: 100, drainCursorUnix: 200,
            lastRetryFingerprint: nil, fingerprint: "c-100"))
        XCTAssertFalse(AtriaBLEManager.shouldRetireCoverageFailureForDrainCursor(
            requiredEndUnix: 100, drainCursorUnix: 200,
            lastRetryFingerprint: "c-100", fingerprint: "c-100"))
        XCTAssertFalse(AtriaBLEManager.shouldRetireCoverageFailureForDrainCursor(
            requiredEndUnix: 100, drainCursorUnix: 50,
            lastRetryFingerprint: nil, fingerprint: "c-100"))
    }

    // 2026-10-03 owner: "many fake workouts/activity". Low-confidence
    // candidates surface only when long and genuinely elevated in HR-reserve
    // terms (rest 54 / max 191 here; the rule scales to any wearer).
    func testLowConfidenceActivitySuggestionsNeedLengthAndReserve() {
        typealias S = SavedSession
        XCTAssertTrue(S.lowConfidenceActivitySuggestionQualifies(
            duration: 16 * 60, averageHR: 120, rest: 54, maxHR: 191), "a brisk walk")
        XCTAssertFalse(S.lowConfidenceActivitySuggestionQualifies(
            duration: 40 * 60, averageHR: 95, rest: 54, maxHR: 191), "a stressful drive")
        XCTAssertFalse(S.lowConfidenceActivitySuggestionQualifies(
            duration: 12 * 60, averageHR: 135, rest: 54, maxHR: 191), "a flight of stairs")
        XCTAssertTrue(S.lowConfidenceActivitySuggestionQualifies(
            duration: 20 * 60, averageHR: 92, rest: 40, maxHR: 170),
            "the same reserve on a fitter heart qualifies")
    }

    // 2026-10-03 owner: recommendations live in the detail sheets; the strain
    // ring carries only a notch.
    func testStrainRecommendationStatesRangeAndRecoveryReason() throws {
        XCTAssertNil(Coach.strainRecommendation(recovery: nil, target: 12))
        let high = try XCTUnwrap(Coach.strainRecommendation(recovery: 74, target: 17))
        XCTAssertEqual(high.action, "Aim for 15–19 strain today")
        XCTAssertTrue(high.reason.contains("74%") && high.reason.contains("hard day"))
        let low = try XCTUnwrap(Coach.strainRecommendation(recovery: 25, target: 9))
        XCTAssertEqual(low.action, "Aim for 7–11 strain today")
        XCTAssertTrue(low.reason.contains("light"))
        XCTAssertEqual(try XCTUnwrap(Coach.strainRecommendation(recovery: 90, target: 20)).action,
                       "Aim for 18–21 strain today", "never past the scale")
    }

    func testTypicalWakeIsTheMedianAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ h: Int, _ m: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: h, minute: m))!
        }
        XCTAssertEqual(AtriaSleepPlanner.typicalWakeMinute(
            wakes: [at(8, 0), at(7, 38), at(8, 57), at(7, 50)], calendar: calendar), 8 * 60)
        XCTAssertEqual(AtriaSleepPlanner.typicalWakeMinute(
            wakes: [at(23, 50), at(0, 10), at(0, 5)], calendar: calendar), 5,
            "wakes around midnight stay together")
        XCTAssertNil(AtriaSleepPlanner.typicalWakeMinute(wakes: [at(8, 0)], calendar: calendar),
                     "one night is not a typical wake")
        let rec = AtriaSleepPlanner.recommendation(needHours: 8, goal: .peak,
                                                   wakeByMinutes: 8 * 60, nightEfficiencies: [])
        XCTAssertNotNil(rec)
        XCTAssertNil(AtriaSleepPlanner.recommendation(needHours: nil, goal: .peak,
                                                      wakeByMinutes: 8 * 60, nightEfficiencies: []))
    }

    // 2026-10-03 owner: learnings as a stacked feed, never restating the rings
    // (a ring-cloning "Today's read" bar was removed on 2026-09-18).
    func testLearningsFeedSkipsRingRestatingKinds() {
        func insight(_ kind: AtriaLearnedInsight.Kind) -> AtriaLearnedInsight {
            AtriaLearnedInsight(id: kind.rawValue, kind: kind, headline: kind.rawValue,
                                detail: "", isPositive: false, asOf: Date(timeIntervalSince1970: 0))
        }
        let items = AtriaTodayLearningsFeed.items(
            learned: [insight(.daySnapshot), insight(.sleepDebt), insight(.readiness),
                      insight(.hrvDrift), insight(.yesterdayStrain)],
            behavior: [])
        XCTAssertEqual(items.map(\.headline), ["sleepDebt", "hrvDrift"])

        // Tapping removes a card; the same finding stays gone, a changed one
        // (new numbers) is new information and returns.
        let raw = AtriaTodayLearningsFeed.remembering(items[0].dismissalKey, in: "")
        let dismissed = Set(raw.split(separator: "\n").map(String.init))
        XCTAssertEqual(AtriaTodayLearningsFeed.visible(items, dismissed: dismissed).map(\.headline),
                       ["hrvDrift"])
        let changed = AtriaTodayLearningsFeed.items(
            learned: [AtriaLearnedInsight(id: "sleepDebt", kind: .sleepDebt, headline: "sleepDebt now 2h",
                                          detail: "", isPositive: false, asOf: Date(timeIntervalSince1970: 0))],
            behavior: [])
        XCTAssertEqual(AtriaTodayLearningsFeed.visible(changed, dismissed: dismissed).count, 1)
    }

    // Owner 2026-10-03: "recalibrate towards WHOOP". Re-expressing a saved
    // day on the new curve must equal scoring its load on the new curve.
    func testStrainRecalibrationIsExactForSavedDays() {
        for load in [20.0, 55.0, 106.0, 122.0, 300.0] {
            let old = 21 * (1 - exp(-load / 150))
            let expected = AtriaStrainLoadModel.displayScore(fromLoad: load)
            XCTAssertEqual(AtriaStrainLoadModel.rescaledDisplayScore(old, fromLoadScale: 150, toLoadScale: 100),
                           expected, accuracy: 1e-9)
        }
        XCTAssertEqual(AtriaStrainLoadModel.displayScore(fromLoad: 55), 8.88, accuracy: 0.01,
                       "a 49-minute strength hour reads about 9")
        XCTAssertEqual(AtriaStrainLoadModel.displayScore(fromLoad: 122), 14.80, accuracy: 0.01)
    }

    // 2026-10-03 owner: "a lot of UI space is taken by nested cards".
    func testOnlyTopLevelCardsDrawASurface() {
        XCTAssertTrue(AtriaInsetCardModifier.drawsSurface(depth: 0, hueTinted: false))
        XCTAssertFalse(AtriaInsetCardModifier.drawsSurface(depth: 1, hueTinted: false),
                       "a card inside a card flows in its parent")
        XCTAssertTrue(AtriaInsetCardModifier.drawsSurface(depth: 2, hueTinted: true),
                      "metric chips keep their identity surface")
    }

    // A version-3 workout whose HR is gone is re-expressed exactly; an older
    // curve version is not guessed at.
    func testHRlessVersion3WorkoutStrainIsReexpressedExactly() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var v3 = UserConfirmedWorkout(id: "strength", createdAt: start, start: start,
                                      end: start.addingTimeInterval(2940), label: "Strength",
                                      source: "test", confidence: "high", sessions: 1,
                                      samples: 0, avgHR: 129, peakHR: 175, p95HR: 160,
                                      p99HR: 170, thresholdHR: 124, streamCoveragePercent: 100,
                                      observedDuration: 2940, reason: "test",
                                      strain: 6.27, zoneSeconds: [:])
        v3.strainCalibrationVersion = 3
        let migrated = SessionStore.reexpressedVersion3WorkoutStrain(v3)
        XCTAssertEqual(migrated.strainCalibrationVersion, 4)
        XCTAssertEqual(try XCTUnwrap(migrated.strain),
                       AtriaStrainLoadModel.rescaledDisplayScore(6.27, fromLoadScale: 150, toLoadScale: 100),
                       accuracy: 1e-9)
        var v2 = v3
        v2.strainCalibrationVersion = 2
        XCTAssertEqual(SessionStore.reexpressedVersion3WorkoutStrain(v2).strain, 6.27)
    }
}
