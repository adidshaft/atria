import XCTest
@testable import Atria

/// Clean-slate durability: after the user taps "Start fresh" to abandon an
/// un-drainable banked backlog, the backlog detectors must stop chasing the
/// pre-reset records (the history reads a degraded strap drops the link on),
/// yet must resume normally once genuinely new post-reset data drains — and
/// must be completely inert for any strap that never ran Start fresh.
final class AtriaCleanSlateBacklogSuppressionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "atria.cleanslate.tests"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private typealias K = AtriaBLEManager.OfflineSyncDefaults

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func reason() -> AtriaBLEManager.StrapBacklogReason {
        AtriaBLEManager.strapBacklogReason(now: now, defaults: defaults,
                                           processInstanceID: "test-proc")
    }

    // Healthy strap that never ran Start fresh: fresh large debt → .freshDebt.
    func testFreshDebtDetectedWhenNotAbandoned() {
        defaults.set(50_000, forKey: K.flushDebtPendingRecords)
        defaults.set(now.timeIntervalSince1970, forKey: K.flushDebtObservedAt)
        XCTAssertFalse(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        XCTAssertEqual(reason(), .freshDebt)
    }

    // After Start fresh (abandon=now, frontier=now), the same fresh large debt
    // is suppressed → .none (stops the read that drops the link).
    func testFreshDebtSuppressedAfterStartFresh() {
        defaults.set(now.timeIntervalSince1970, forKey: K.historyAbandonedThroughUnix)
        defaults.set(now.timeIntervalSince1970, forKey: K.drainedThroughUnix)
        defaults.set(50_000, forKey: K.flushDebtPendingRecords)
        defaults.set(now.timeIntervalSince1970, forKey: K.flushDebtObservedAt)
        XCTAssertTrue(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        XCTAssertEqual(reason(), .none)
    }

    // Stale frontier normally → .frontierStale; suppressed after Start fresh.
    func testFrontierStaleSuppressedAfterStartFresh() {
        // Frontier 2h behind now.
        let staleFrontier = now.addingTimeInterval(-2 * 3600).timeIntervalSince1970
        defaults.set(staleFrontier, forKey: K.drainedThroughUnix)
        XCTAssertEqual(reason(), .frontierStale)
        // Abandon at (frontier) so frontier <= abandon → suppressed.
        defaults.set(staleFrontier, forKey: K.historyAbandonedThroughUnix)
        XCTAssertTrue(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        XCTAssertEqual(reason(), .none)
    }

    // Suppression LIFTS once real new data drains past the abandoned instant.
    func testSuppressionLiftsWhenFrontierAdvancesPastAbandon() {
        let abandon = now.addingTimeInterval(-3 * 3600).timeIntervalSince1970
        defaults.set(abandon, forKey: K.historyAbandonedThroughUnix)
        // Frontier advanced 10 min past the abandon instant = genuine new data.
        defaults.set(abandon + 600, forKey: K.drainedThroughUnix)
        XCTAssertFalse(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        // Fresh large debt now detected again (real post-reset backlog).
        defaults.set(50_000, forKey: K.flushDebtPendingRecords)
        defaults.set(now.timeIntervalSince1970, forKey: K.flushDebtObservedAt)
        XCTAssertEqual(reason(), .freshDebt)
    }

    // A genuine new-gap ticket still wins even while abandoned (small recent
    // window that should still drain).
    func testTicketStillWinsWhileAbandoned() {
        defaults.set(now.timeIntervalSince1970, forKey: K.historyAbandonedThroughUnix)
        defaults.set(now.timeIntervalSince1970, forKey: K.drainedThroughUnix)
        defaults.set(true, forKey: K.rangeLossBackfillPending)
        XCTAssertEqual(reason(), .ticket)
    }

    // Boundary: frontier exactly at abandon (within 1s) is still suppressed;
    // frontier just past (>1s) is not.
    func testFrontierBoundary() {
        let abandon = now.timeIntervalSince1970
        defaults.set(abandon, forKey: K.historyAbandonedThroughUnix)
        defaults.set(abandon + 1, forKey: K.drainedThroughUnix)
        XCTAssertTrue(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
        defaults.set(abandon + 2, forKey: K.drainedThroughUnix)
        XCTAssertFalse(AtriaBLEManager.historyAbandonedSuppressesBacklog(defaults: defaults))
    }

    func testLaunchArgStartFreshIsTheSameInAppPathAndInertWhenOmitted() throws {
        XCTAssertFalse(
            AtriaBLEManager.shouldApplyLaunchArgStartFresh(
                arguments: ["--atria-idle-window-drain-enable"]
            ),
            "unflagged launches must not Start fresh"
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldApplyLaunchArgStartFresh(arguments: [])
        )
        XCTAssertFalse(
            AtriaBLEManager.shouldApplyLaunchArgStartFresh(
                arguments: [AtriaBLEManager.historyConsumeToNowLaunchArgument]
            ),
            "consume-to-now consent is not Start-fresh"
        )
        XCTAssertTrue(
            AtriaBLEManager.shouldApplyLaunchArgStartFresh(
                arguments: [AtriaBLEManager.startFreshClearGapLaunchArgument]
            )
        )
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        XCTAssertTrue(source.contains("shouldApplyLaunchArgStartFresh(arguments:"))
        XCTAssertTrue(
            source.contains("startFreshAcceptingMissedDataLoss(reason: \"launch_arg_start_fresh\")")
        )
        let applyStart = try XCTUnwrap(source.range(of: "func applyLaunchAutomation("))
        let applyEnd = try XCTUnwrap(source.range(
            of: "if arguments.contains(\"--atria-full-protocol-mode\")",
            range: applyStart.upperBound..<source.endIndex
        ))
        let apply = String(source[applyStart.lowerBound..<applyEnd.lowerBound])
        XCTAssertTrue(apply.contains("shouldApplyLaunchArgStartFresh(arguments:"))
        XCTAssertFalse(
            apply.contains("startFreshAcceptingMissedDataLoss(")
                && !apply.contains("shouldApplyLaunchArgStartFresh(")
        )
    }
}

/// Auto-surfacing of the clean slate: a degraded strap that can't drain must be
/// OFFERED "Start fresh" automatically, not nag forever. Pure decision tests
/// over the consecutive zero-progress slice counter (the un-foolable signal).
final class AtriaGapTerminalStallTests: XCTestCase {
    private let threshold = AtriaMissedDataBannerPresentation.terminalStallSlices // 5
    private let window = AtriaMissedDataBannerPresentation.terminalStallWindow    // 4h
    private typealias P = AtriaMissedDataBannerPresentation

    func testNotStalledWithoutBacklog() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: false,
            sequenceGapParkedTerminal: false,
            consecutiveZeroProgressSlices: 99,
            secondsSinceRangeLossRequested: 99 * 3600))
    }

    func testStalledWhenSequenceGapParked() {
        XCTAssertTrue(P.gapIsTerminallyStalled(
            backlogPending: true,
            sequenceGapParkedTerminal: true,
            consecutiveZeroProgressSlices: 0,
            secondsSinceRangeLossRequested: 60))
    }

    // The degraded-strap case: enough consecutive failed history reads → stalled.
    func testStalledWhenSlicesCrossThreshold() {
        XCTAssertTrue(P.gapIsTerminallyStalled(
            backlogPending: true,
            sequenceGapParkedTerminal: false,
            consecutiveZeroProgressSlices: threshold,
            secondsSinceRangeLossRequested: 60))
    }

    // Persistent signal: the gap has stayed pending past the window → stalled,
    // even with the (relaunch-reset) slice counter still low.
    func testStalledWhenEpisodeAgeExceedsWindow() {
        XCTAssertTrue(P.gapIsTerminallyStalled(
            backlogPending: true,
            sequenceGapParkedTerminal: false,
            consecutiveZeroProgressSlices: 1,
            secondsSinceRangeLossRequested: window + 60))
    }

    // Neither signal tripped: few failed slices AND a young episode → not stalled.
    func testNotStalledBelowBothThresholds() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: true,
            sequenceGapParkedTerminal: false,
            consecutiveZeroProgressSlices: threshold - 1,
            secondsSinceRangeLossRequested: 30 * 60))
    }

    // Healthy: progress reset the counter AND the episode is fresh → not stalled.
    func testNotStalledWhenHealthy() {
        XCTAssertFalse(P.gapIsTerminallyStalled(
            backlogPending: true,
            sequenceGapParkedTerminal: false,
            consecutiveZeroProgressSlices: 0,
            secondsSinceRangeLossRequested: 5 * 60))
    }

    /// Device 2026-09-05: pending backfill + 4h of zero-row drains. Accept
    /// the unrecoverable interval; do not re-arm; do not wipe nights.
    func testAcceptsTerminalHistoryLossWithoutWipingNights() {
        let suite = "atria.terminal-loss.tests"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pendingKey = AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending
        defaults.set(true, forKey: pendingKey)
        defaults.set(now.timeIntervalSince1970 - P.terminalStallWindow - 60,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt)
        defaults.set("long_wear_range_loss",
                     forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillReason)
        defaults.set(4, forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices)

        XCTAssertTrue(P.acceptTerminalHistoryLossIfNeeded(defaults: defaults, now: now))
        XCTAssertFalse(defaults.bool(forKey: pendingKey))
        XCTAssertNil(defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt))
        XCTAssertFalse(P.acceptTerminalHistoryLossIfNeeded(defaults: defaults, now: now),
                       "a second pass is a no-op")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Device 2026-09-05 14:46: accepting the stall cleared pending, then the
    /// next connect re-armed the same long-wear ticket because stall requires
    /// pending=true. Remember the drain cursor so re-arm stays skipped until
    /// the strap actually ACKs a newer page.
    func testAcceptedLossSkipsRearmUntilDrainCursorAdvances() {
        let suite = "atria.terminal-loss.rearm.tests"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cursor: TimeInterval = 1_799_000_000
        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set(now.timeIntervalSince1970 - P.terminalStallWindow - 60,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt)
        defaults.set(5, forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices)
        defaults.set(cursor, forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix)

        XCTAssertTrue(P.shouldSkipRangeLossRearm(defaults: defaults, now: now))
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending))
        XCTAssertEqual(
            defaults.double(forKey: AtriaBLEManager.OfflineSyncDefaults.unrecoverableHistoryAcceptedCursorUnix),
            cursor,
            accuracy: 0.001
        )
        XCTAssertTrue(P.shouldSkipRangeLossRearm(defaults: defaults, now: now),
                      "cleared pending must not re-arm the same cursor")
        defaults.set(cursor + 60,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix)
        XCTAssertFalse(P.shouldSkipRangeLossRearm(defaults: defaults, now: now),
                       "a later ACK'd page may re-arm")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    /// Device 2026-09-08: Overview "Last fill 9:44 AM Friday" is
    /// `historyDrainCursorUnix` 1788495274 (2026-09-04 09:44 Asia/Kolkata).
    /// Accepting that interval as unrecoverable must not freeze Saturday–Tuesday
    /// gaps that start after the cursor.
    func testAcceptedFriday944CursorStillSkipsThatIntervalButNotALaterGap() {
        let friday944: TimeInterval = 1_788_495_274
        XCTAssertTrue(
            P.shouldSkipRangeLossRearm(
                acceptedCursorUnix: friday944,
                drainCursorUnix: friday944
            ),
            "the abandoned Friday 9:44 interval stays skipped while the cursor is parked there"
        )
        XCTAssertTrue(
            P.shouldSkipRangeLossRearm(
                acceptedCursorUnix: friday944,
                drainCursorUnix: friday944,
                proposedGapStartUnix: friday944
            ),
            "a gap that starts on the accepted cursor is the same unfillable interval"
        )
        XCTAssertFalse(
            P.shouldSkipRangeLossRearm(
                acceptedCursorUnix: friday944,
                drainCursorUnix: friday944,
                proposedGapStartUnix: friday944 + 24 * 60 * 60
            ),
            "a strictly later gap remains eligible to drain"
        )
        let saturdayStart = Date(timeIntervalSince1970: friday944 + 24 * 60 * 60)
        let laterStart = P.earliestGapStartStrictlyAfter(
            acceptedCursorUnix: friday944,
            windows: [
                .init(start: Date(timeIntervalSince1970: friday944 - 3600),
                      end: Date(timeIntervalSince1970: friday944),
                      reason: "abandoned_prefix"),
                .init(start: saturdayStart,
                      end: saturdayStart.addingTimeInterval(3600),
                      reason: "later_gap")
            ]
        )
        XCTAssertEqual(laterStart ?? -1,
                       saturdayStart.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNil(
            P.earliestGapStartStrictlyAfter(
                acceptedCursorUnix: friday944,
                windows: [
                    .init(start: Date(timeIntervalSince1970: friday944 - 3600),
                          end: Date(timeIntervalSince1970: friday944),
                          reason: "abandoned_prefix")
                ]
            )
        )
    }

    /// Device 2026-09-08: accepted=drainCursor=1788495274, slices=13, pending
    /// later Saturday gap. Skip-rearm must stay false, leftover Friday zeros
    /// must not accept-away the later ticket, and admitting the later interval
    /// resets the slice count.
    func testDeviceFridayStallSlicesDoNotAcceptAwayALaterGapTicket() throws {
        let suite = "atria.friday944.later-gap.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            AtriaHistoricalGapLedger.resetStorageForTesting(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        let friday944: TimeInterval = 1_788_495_274
        let now = Date(timeIntervalSince1970: 1_788_850_000)
        let saturdayStart = Date(timeIntervalSince1970: friday944 + 24 * 60 * 60)
        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set(now.timeIntervalSince1970 - P.terminalStallWindow - 60,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt)
        defaults.set(13, forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices)
        defaults.set(friday944, forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix)
        defaults.set(friday944,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.unrecoverableHistoryAcceptedCursorUnix)
        XCTAssertTrue(
            AtriaHistoricalGapLedger.recordObservedGap(
                start: saturdayStart,
                end: saturdayStart.addingTimeInterval(3_600),
                reason: "later_gap",
                defaults: defaults
            )
        )

        XCTAssertTrue(P.hasActionableGapAfterAcceptedCursor(defaults: defaults))
        XCTAssertFalse(
            P.shouldSkipRangeLossRearm(defaults: defaults, now: now),
            "a later ledger gap must remain eligible despite leftover Friday stall slices"
        )
        XCTAssertTrue(
            defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending),
            "skip-rearm must not clear the later ticket"
        )
        XCTAssertFalse(
            P.acceptTerminalHistoryLossIfNeeded(defaults: defaults, now: now),
            "leftover Friday stall slices must not accept-away a Saturday–Tuesday ticket"
        )
        XCTAssertTrue(
            defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)
        )
        XCTAssertEqual(
            defaults.integer(forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices),
            0,
            "accepting leftover Friday zeros against a later gap resets the slice count"
        )
        defaults.set(13, forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices)
        XCTAssertTrue(P.resetZeroProgressSlicesForLaterGapAdmission(defaults: defaults))
        XCTAssertEqual(
            defaults.integer(forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices),
            0
        )

        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: managerURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func markRangeLossBackfillRequired("))
        let end = try XCTUnwrap(source.range(
            of: "private func preserveLongWearRangeLossRecovery(",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("resetZeroProgressSlicesForLaterGapAdmission("))
        XCTAssertTrue(body.contains("connectedRawCatchUpConsecutiveZeroProgressSlices = 0"))
        XCTAssertTrue(body.contains("applyResilientHistoryDrainSeekIfNeeded("))
        XCTAssertTrue(source.contains("applyResilientHistoryDrainSeekIfNeeded("))
        let syncStart = try XCTUnwrap(source.range(of: "let connectedRawHistoryCatchUpStartFrontierUnix"))
        let syncPrefix = String(source[source.index(syncStart.lowerBound, offsetBy: -1600)..<syncStart.lowerBound])
        XCTAssertTrue(
            syncPrefix.contains("applyResilientHistoryDrainSeekIfNeeded("),
            "drain start must skip-ahead the seek cursor before using it as the slice frontier"
        )
        XCTAssertTrue(
            syncPrefix.contains("skipped_drain_cover_live"),
            "a stuck oldest-first park must release the radio instead of starting another drain"
        )
    }

    func testResilientSeekMovesFridayParkOffTheDeadPageAndUnblocksLaterAdmission() {
        let suite = "atria.friday944.seek.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let friday944: TimeInterval = 1_788_495_274
        let now = Date(timeIntervalSince1970: 1_788_850_000)
        let startFresh: TimeInterval = 1_788_580_144
        defaults.set(friday944, forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix)
        defaults.set(friday944,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.unrecoverableHistoryAcceptedCursorUnix)
        defaults.set(startFresh, forKey: AtriaBLEManager.OfflineSyncDefaults.historyAbandonedThroughUnix)
        defaults.set(startFresh, forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix)

        let seek = P.applyResilientHistoryDrainSeekIfNeeded(defaults: defaults, now: now)
        XCTAssertEqual(seek ?? -1, friday944 + AtriaBLEManager.historyDrainUnrecoverableSkipEpsilon,
                       accuracy: 0.001)
        XCTAssertEqual(
            defaults.double(forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix),
            friday944 + AtriaBLEManager.historyDrainUnrecoverableSkipEpsilon,
            accuracy: 0.001
        )
        XCTAssertEqual(
            defaults.double(forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix),
            startFresh,
            accuracy: 0.001,
            "skip-ahead is a seek, not a newest-record claim"
        )
        XCTAssertFalse(
            P.shouldSkipRangeLossRearm(defaults: defaults, now: now),
            "after leaving the dead page, later drain admission must not stay skipped"
        )
        XCTAssertNil(
            P.applyResilientHistoryDrainSeekIfNeeded(defaults: defaults, now: now),
            "idempotent once the cursor is already off the dead page"
        )
    }

    /// Device 2026-09-08: after skip-ahead left Friday 9:44, drain parked on
    /// Saturday 09:28 with no_rows / first-frame timeout. That page is lost.
    /// Bring the cursor to now and do not re-arm the abandoned prefix.
    func testStuckSaturdayParkBringsCursorToNowAndSkipsAbandonedPrefix() {
        let suite = "atria.cover-live.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let friday944: TimeInterval = 1_788_495_274
        let saturday928: TimeInterval = 1_788_580_736.647
        let now = Date(timeIntervalSince1970: 1_788_850_000)
        defaults.set(saturday928, forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix)
        defaults.set(friday944,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.unrecoverableHistoryAcceptedCursorUnix)
        defaults.set(false, forKey: AtriaBLEManager.OfflineSyncDefaults.lastDrainAttemptYieldedRows)
        defaults.set(1, forKey: AtriaBLEManager.OfflineSyncDefaults.consecutiveZeroProgressSlices)
        defaults.set("no_rows", forKey: AtriaBLEManager.OfflineSyncDefaults.lastStatus)
        defaults.set(true, forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)

        let seek = P.applyResilientHistoryDrainSeekIfNeeded(defaults: defaults, now: now)
        XCTAssertEqual(seek ?? -1, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            defaults.double(forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix),
            now.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            defaults.double(forKey: AtriaBLEManager.OfflineSyncDefaults.historyCoverLiveUnix),
            now.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertFalse(defaults.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending))
        XCTAssertTrue(
            P.shouldSkipRangeLossRearm(
                acceptedCursorUnix: now.timeIntervalSince1970,
                drainCursorUnix: now.timeIntervalSince1970,
                proposedGapStartUnix: saturday928
            ),
            "the abandoned Saturday prefix must not re-arm after cover-live"
        )
        XCTAssertNil(
            P.applyResilientHistoryDrainSeekIfNeeded(defaults: defaults, now: now),
            "cover-live is idempotent for this park"
        )
        XCTAssertTrue(
            P.shouldSkipRangeLossRearm(defaults: defaults, now: now),
            "cover-live must not re-arm history when a reconnect opens a later gap"
        )
    }

    func testLiveWorkoutAndCoverLiveKeepHistoryFromWinningTransport() {
        XCTAssertFalse(
            AtriaR10StepLeasePolicy.shouldClaimHistoryTransport(
                manualWorkoutActive: true
            ),
            "a user-started workout keeps proprietary transport off history"
        )
        XCTAssertFalse(
            AtriaR10StepLeasePolicy.historyOwnsTransportForStepLease(
                manualWorkoutActive: true, historySyncInProgress: true
            )
        )
        let suite = "atria.cover-live.workout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_788_850_000)
        defaults.set(now.timeIntervalSince1970,
                     forKey: AtriaBLEManager.OfflineSyncDefaults.historyCoverLiveUnix)
        XCTAssertTrue(
            P.shouldSkipRangeLossRearm(defaults: defaults, now: now),
            "cover-live skip-rearm remains in force during the live workout"
        )
    }
}
