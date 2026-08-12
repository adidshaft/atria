import XCTest
@testable import Atria

/// The missed-data banner must never over-promise recovery. It used to show the
/// gap's AGE ("Data gap · 85.4 h") as if that were missing data AND imply a sync
/// would bring it back, when only what is still on the strap ring buffer is
/// actually recoverable. These pin the honest copy mapping.
final class AtriaMissedDataBannerPresentationTests: XCTestCase {
    private func homeSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
            .appendingPathComponent("AtriaHomeView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func copy(pending: Int,
                      protectsLive: Bool,
                      secondsSinceLastFlush: TimeInterval? = nil,
                      leaseActive: Bool = false) -> AtriaMissedDataBannerPresentation.Copy {
        AtriaMissedDataBannerPresentation.copy(strapPendingRecords: pending,
                                               protectsLiveStream: protectsLive,
                                               secondsSinceLastFlush: secondsSinceLastFlush,
                                               backgroundLeaseActive: leaseActive)
    }

    func testLargeOldGapWithNothingLeftOnStrapIsHonestlyUnrecoverable() {
        // The exact 85.4h-age case: the strap has essentially nothing bankable
        // left, so the banner must NOT offer a (futile) sync and must say it
        // cannot be recovered rather than dangling a scary hours number.
        let c = copy(pending: 90, protectsLive: false) // ~1.5 min on strap
        XCTAssertFalse(c.offersRecovery)
        XCTAssertEqual(c.title, "Some earlier data wasn't recorded")
        // Reassuring, not alarming: it does not affect new data.
        XCTAssertTrue(c.subtitle.lowercased().contains("unaffected"))
        // No misleading number (e.g. the 85.4h gap-age) anywhere in the copy.
        XCTAssertNil(c.title.rangeOfCharacter(from: .decimalDigits))
        XCTAssertNil(c.subtitle.rangeOfCharacter(from: .decimalDigits))
    }

    func testRealBankedBacklogOffersHonestRecoverableAmount() {
        // >= ~5 min still on the strap is genuinely recoverable: offer sync and
        // state the real recoverable amount, not the gap age.
        let c = copy(pending: 20 * 60, protectsLive: false) // 20 min bankable
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.title, "Catching up history")
        XCTAssertTrue(c.subtitle.contains("~20 min"))
    }

    func testBoundaryAtRecoverableFloor() {
        let floor = AtriaMissedDataBannerPresentation.recoverableRecordFloor
        XCTAssertTrue(copy(pending: floor, protectsLive: false).offersRecovery)
        XCTAssertFalse(copy(pending: floor - 1, protectsLive: false).offersRecovery)
    }

    func testProtectedLiveStreamNeverReadsAsLost() {
        // Recoverability gates the message even while live HR is protected:
        // with a genuine banked backlog on the strap, live-protected reads as a
        // deferred catch-up (recoverable), never as loss.
        let recoverable = copy(pending: 20 * 60, protectsLive: true)
        XCTAssertTrue(recoverable.offersRecovery)
        XCTAssertEqual(recoverable.title, "Live HR protected")
        // But an OLD gap that is gone stays honestly "wasn't recorded" even while
        // live HR streams — live being fine does not make the old data recoverable.
        let goneWhileLive = copy(pending: 90, protectsLive: true)
        XCTAssertFalse(goneWhileLive.offersRecovery)
        XCTAssertEqual(goneWhileLive.title, "Some earlier data wasn't recorded")
    }

    func testNegativeOrZeroPendingIsClamped() {
        let c = copy(pending: -50, protectsLive: false)
        XCTAssertFalse(c.offersRecovery) // clamps to 0 → unrecoverable branch
    }

    // MARK: - Live drain progress (2026-08-03 device forensics)

    func testRecentDurableFlushReadsAsActivelyDrainingNotStuck() {
        // The bug: a 28-min-stale "~8 min on the strap" read as frozen while the
        // drain was flushing every ~2 min. A recent durable flush must lead with
        // the fresh signal, not the stale pending count.
        let c = copy(pending: 8 * 60, protectsLive: false, secondsSinceLastFlush: 120)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.title, "Catching up history")
        XCTAssertTrue(c.subtitle.contains("synced"))
        XCTAssertTrue(c.subtitle.contains("2m ago"))
        // The stale minutes count is NOT what leads the line anymore.
        XCTAssertFalse(c.subtitle.contains("~8 min"))
    }

    func testActiveDrainOverridesLiveProtectedIdleCopy() {
        // Even while live HR is streaming, a recent flush proves the background
        // lane is draining underneath — so it must say "catching up", not the
        // "when idle" deferral copy that implied nothing was happening.
        let c = copy(pending: 8 * 60, protectsLive: true, secondsSinceLastFlush: 60)
        XCTAssertEqual(c.title, "Catching up history")
        XCTAssertTrue(c.subtitle.lowercased().contains("catching up"))
        XCTAssertFalse(c.subtitle.lowercased().contains("when idle"))
    }

    func testActiveBackgroundLeaseCountsAsDrainingWithoutAFlushTime() {
        let c = copy(pending: 8 * 60, protectsLive: false, secondsSinceLastFlush: nil, leaseActive: true)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.subtitle, "Catching up now")
    }

    func testStaleFlushFallsBackToDeferredCopy() {
        // A flush older than the active window is NOT "actively draining"; with no
        // lease, recoverable-but-idle copy applies.
        let stale = AtriaMissedDataBannerPresentation.activeDrainRecencyWindow + 60
        let c = copy(pending: 8 * 60, protectsLive: false, secondsSinceLastFlush: stale)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertFalse(c.subtitle.contains("synced"))
        XCTAssertTrue(c.subtitle.contains("~8 min"))
    }

    func testRelativeAgoFormatting() {
        XCTAssertEqual(AtriaMissedDataBannerPresentation.relativeAgo(30), "just now")
        XCTAssertEqual(AtriaMissedDataBannerPresentation.relativeAgo(120), "2m ago")
        XCTAssertEqual(AtriaMissedDataBannerPresentation.relativeAgo(3 * 3600), "3h ago")
    }

    // MARK: - Stale pending count must not hide recovery (2026-08-07)

    func testStaleLowCountWithPendingBacklogKeepsSyncAffordance() {
        // The 3 AM case: count=132 observed 18h ago while ~7,300 records sat on
        // the strap and the durable backlog ticket was still pending. A dead
        // number must not declare the gap gone.
        let c = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 132,
            protectsLiveStream: false,
            secondsSinceLastFlush: nil,
            backgroundLeaseActive: false,
            debtObservedAgeSeconds: 18 * 3600,
            backlogPending: true)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.title, "Catching up history")
        // The stale count must not be presented as a recoverable amount.
        XCTAssertFalse(c.subtitle.contains("min"))
    }

    func testStaleCountWithActiveDrainLeadsWithFreshFlushSignal() {
        let c = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 132,
            protectsLiveStream: false,
            secondsSinceLastFlush: 120,
            backgroundLeaseActive: true,
            debtObservedAgeSeconds: 18 * 3600,
            backlogPending: true)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertTrue(c.subtitle.contains("synced"))
    }

    func testStaleCountWithLiveProtectionStaysRecoverable() {
        let c = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 0,
            protectsLiveStream: true,
            secondsSinceLastFlush: nil,
            backgroundLeaseActive: false,
            debtObservedAgeSeconds: nil,
            backlogPending: true)
        XCTAssertTrue(c.offersRecovery)
        XCTAssertEqual(c.title, "Live HR protected")
    }

    func testStaleLowCountWithoutBacklogStaysHonestlyUnrecoverable() {
        // No durable backlog ticket and only a stale low count: nothing says
        // there is data to get back — keep the calm unrecoverable copy.
        let c = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 90,
            protectsLiveStream: false,
            secondsSinceLastFlush: nil,
            backgroundLeaseActive: false,
            debtObservedAgeSeconds: 18 * 3600,
            backlogPending: false)
        XCTAssertFalse(c.offersRecovery)
        XCTAssertEqual(c.title, "Some earlier data wasn't recorded")
    }

    func testFreshLowCountStillReadsAsGoneEvenWithBacklogTicket() {
        // A FRESH observation below the floor is real evidence the data is
        // effectively gone — the ticket alone must not dangle a futile sync.
        let c = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 90,
            protectsLiveStream: false,
            secondsSinceLastFlush: nil,
            backgroundLeaseActive: false,
            debtObservedAgeSeconds: 60,
            backlogPending: true)
        XCTAssertFalse(c.offersRecovery)
    }

    func testVisibleSyncActionsQueueExactConnectedCatchUpInsteadOfGenericCutover() throws {
        let source = try homeSource()
        XCTAssertTrue(source.contains(
            "ble.queueConnectedRawHistoryCatchUpIntent(\n                reason: \"pull_to_refresh\""
        ))
        XCTAssertTrue(source.contains(
            "ble.queueConnectedRawHistoryCatchUpIntent(\n                    reason: \"home_missed_data_banner\""
        ))
        XCTAssertFalse(source.contains(
            "requestOfflineHistoricalSyncIfNeeded(reason: \"home_missed_data_banner\""
        ))

        let tapStart = try XCTUnwrap(source.range(
            of: "private func handleSyncTap()"
        ))
        let tapEnd = try XCTUnwrap(source.range(
            of: "private var copyBlock: some View",
            range: tapStart.upperBound..<source.endIndex
        ))
        let tap = String(source[tapStart.lowerBound..<tapEnd.lowerBound])
        let queueCall = try XCTUnwrap(tap.range(of: "onSync()"))
        let protection = try XCTUnwrap(tap.range(
            of: "if protectsLiveStream"
        ))
        XCTAssertLessThan(queueCall.lowerBound, protection.lowerBound)
        XCTAssertTrue(tap.contains("Queued · live tracking stays on"))
        XCTAssertFalse(tap.contains("requestOfflineHistoricalSyncIfNeeded("))
    }
}

/// The compact recovery chip shows the durable archive frontier without
/// dropping its existing saved-record progress or inventing a time when the
/// frontier is unavailable.
final class AtriaHomeRecoverySyncPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_US") }

    private func date(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026,
                                           month: 8,
                                           day: day,
                                           hour: hour,
                                           minute: minute))!
    }

    func testSyncingCopyIncludesSavedCountAndDurableThroughTime() {
        let frontier = date(day: 9, hour: 9, minute: 34)
        let copy = AtriaHomeRecoverySyncPresentation.copy(
            savedRecords: 271,
            drainedThroughUnix: frontier.timeIntervalSince1970,
            now: date(day: 9, hour: 19, minute: 0),
            calendar: calendar,
            locale: locale
        )

        XCTAssertTrue(copy.title.hasPrefix("Syncing strap history · 271 saved · through "))
        XCTAssertTrue(copy.title.contains("9:34"))
        XCTAssertTrue(copy.title.contains("AM"))
        XCTAssertTrue(copy.accessibilityLabel.contains("271 records durably saved"))
        XCTAssertTrue(copy.accessibilityLabel.contains("durably synced through"))
    }

    func testCompactCopyKeepsBothProgressSignalsOnNarrowWidths() {
        let frontier = date(day: 9, hour: 9, minute: 34)
        let copy = AtriaHomeRecoverySyncPresentation.copy(
            savedRecords: 271,
            drainedThroughUnix: frontier.timeIntervalSince1970,
            now: date(day: 9, hour: 19, minute: 0),
            calendar: calendar,
            locale: locale
        )

        // The compact fallback keeps the "history" channel word so it never
        // reads as if all data is behind — only "strap" is dropped for width.
        XCTAssertEqual(copy.compactTitle,
                       copy.title.replacingOccurrences(of: "Syncing strap history",
                                                       with: "Syncing history"))
        XCTAssertTrue(copy.compactTitle.hasPrefix("Syncing history"))
        XCTAssertTrue(copy.compactTitle.contains("271 saved"))
        XCTAssertTrue(copy.compactTitle.contains("through"))
        XCTAssertLessThan(copy.compactTitle.count, copy.title.count)
    }

    func testMissingInvalidOrFutureFrontierNeverInventsThroughTime() {
        let now = date(day: 9, hour: 19, minute: 0)
        let invalidFrontiers: [Double?] = [
            nil,
            0,
            .nan,
            now.addingTimeInterval(60).timeIntervalSince1970
        ]
        for frontier in invalidFrontiers {
            let copy = AtriaHomeRecoverySyncPresentation.copy(
                savedRecords: 271,
                drainedThroughUnix: frontier,
                now: now,
                calendar: calendar,
                locale: locale
            )
            XCTAssertEqual(copy.title, "Syncing strap history · 271 saved")
            XCTAssertFalse(copy.accessibilityLabel.contains("synced through"))
        }
    }

    func testOlderFrontierDisambiguatesTheDay() {
        let yesterday = AtriaHomeRecoverySyncPresentation.copy(
            savedRecords: 0,
            drainedThroughUnix: date(day: 8, hour: 22, minute: 15).timeIntervalSince1970,
            now: date(day: 9, hour: 19, minute: 0),
            calendar: calendar,
            locale: locale
        )
        XCTAssertTrue(yesterday.title.contains("through"))
        XCTAssertTrue(yesterday.title.contains("yesterday"))
        XCTAssertFalse(yesterday.title.contains("saved"))
    }
}

/// The Overview sync-progress footer must be honest (real frontier, real
/// activity state) and quiet (hidden entirely when caught up).
final class AtriaSyncProgressFooterPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }

    // Fixed "now": 2026-08-07 ~05:00 IST.
    private var now: Date { Date(timeIntervalSince1970: 1_786_059_000) }

    private func footer(drainedAgo: TimeInterval? = 19 * 3600,
                        backlogPending: Bool = true,
                        debtRecords: Int? = nil,
                        debtAge: TimeInterval? = nil,
                        flushAgo: TimeInterval? = nil,
                        lease: Bool = false,
                        liveHeartRateIsCurrent: Bool = false)
        -> AtriaSyncProgressFooterPresentation.Footer? {
        AtriaSyncProgressFooterPresentation.footer(
            drainedThroughUnix: drainedAgo.map { now.timeIntervalSince1970 - $0 },
            backlogPending: backlogPending,
            debtRecords: debtRecords,
            debtObservedAgeSeconds: debtAge,
            secondsSinceLastFlush: flushAgo,
            backgroundLeaseActive: lease,
            liveHeartRateIsCurrent: liveHeartRateIsCurrent,
            now: now,
            calendar: calendar)
    }

    func testHiddenWhenNothingToCatchUp() {
        // A recent frontier with no ticket and no debt info → quiet screen.
        XCTAssertNil(footer(drainedAgo: 10 * 60, backlogPending: false))
        // Fresh caught-up debt hides even an hours-old frontier (the lag is
        // phone-side processing, not missing strap data).
        XCTAssertNil(footer(backlogPending: false, debtRecords: 60, debtAge: 30))
    }

    func testFreshDeepDebtShowsEvenWithoutTicket() {
        XCTAssertNotNil(footer(backlogPending: false, debtRecords: 7_000, debtAge: 30))
    }

    func testHoursBehindFrontierShowsEvenWithClearedTicketAndStaleDebt() {
        // The strap-off trap (2026-08-07): ticket cleared, count 41 min stale,
        // 12 h behind — the footer vanished. "Behind" is itself the reason to
        // show; a stale count must not hide it.
        let f = footer(backlogPending: false, debtRecords: 4_867, debtAge: 41 * 60)
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.detail.contains("history backlog"))
    }

    func testBehindFrontierAndActivityAreHonest() {
        let f = footer(flushAgo: 120, liveHeartRateIsCurrent: true)
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.active)
        XCTAssertTrue(f!.detail.contains("19h 0m history backlog"))
        XCTAssertTrue(f!.detail.contains("live HR current"))
        XCTAssertTrue(f!.detail.contains("catching up now"))
        XCTAssertTrue(f!.headline.contains("Strap history through"))
        XCTAssertTrue(f!.headline.contains("yesterday"),
                      "a 19h-old frontier at 5 AM lands yesterday morning")
    }

    func testSilentDrainReadsPausedNotLying() {
        let f = footer(flushAgo: 45 * 60)
        XCTAssertNotNil(f)
        XCTAssertFalse(f!.active)
        XCTAssertTrue(f!.detail.contains("paused"))
    }

    func testLeaseCountsAsActiveWithoutFlushTimestamp() {
        let f = footer(flushAgo: nil, lease: true)
        XCTAssertTrue(f!.active)
    }

    func testMissingFrontierNeverInventsATime() {
        let f = footer(drainedAgo: nil)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.headline, "Strap history backfill")
        XCTAssertFalse(f!.detail.contains("history backlog"))
    }

    func testTodayFrontierOmitsDayLabel() {
        let f = footer(drainedAgo: 30 * 60, flushAgo: 60)
        XCTAssertNotNil(f)
        XCTAssertFalse(f!.headline.contains("yesterday"))
        XCTAssertTrue(f!.detail.contains("30m history backlog"))
    }
}
