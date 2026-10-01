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
