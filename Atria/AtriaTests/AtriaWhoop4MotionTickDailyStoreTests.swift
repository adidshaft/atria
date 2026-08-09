import XCTest
import UIKit
@testable import Atria

final class AtriaWhoop4MotionTickDailyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AtriaWhoop4MotionTickDailyStoreTests-\(UUID().uuidString)"
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testReceiptIsIsolatedByStrapAndPhysiologicalBoundary() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strapA = UUID().uuidString
        let strapB = UUID().uuidString
        let start = Date(timeIntervalSince1970: 10_000)
        let evidence = makeEvidence(start: start, ticks: 155, steps: 132)

        XCTAssertTrue(try store.save(evidence, strapIdentifier: strapA))
        XCTAssertEqual(
            store.load(strapIdentifier: strapA, windowStart: start),
            evidence
        )
        XCTAssertNil(store.load(strapIdentifier: strapB, windowStart: start))
        XCTAssertNil(
            store.load(
                strapIdentifier: strapA,
                windowStart: start.addingTimeInterval(60)
            )
        )
    }

    // Prior-day lower-bound lane (2026-08-08). The enumeration must exclude
    // today's civil day AND the open physiological cycle's civil day, so this
    // lane never keys the same civil date as the wake-to-wake current-cycle
    // receipt.
    func testCompletedPriorCivilDayWindowsExcludeTodayAndOpenCycleDay() throws {
        let cal = utcCalendar
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 14)))
        // Case 1: cycle woke this morning (same civil day as `now`).
        let cycleToday = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 6)))
        let windows = SessionStore.completedPriorCivilDayWindows(
            now: now, cycleStart: cycleToday, calendar: cal, backfillDays: 3
        )
        XCTAssertEqual(windows.count, 3)
        let yesterday = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 7)))
        XCTAssertEqual(windows.first?.start, yesterday, "newest window is yesterday at civil midnight")
        let todayStart = cal.startOfDay(for: now)
        for window in windows {
            XCTAssertEqual(window.duration, 86400, accuracy: 1)
            XCTAssertEqual(window.start, cal.startOfDay(for: window.start), "midnight-aligned")
            XCTAssertLessThan(window.start, todayStart, "never today")
        }
        for i in 1..<windows.count {
            XCTAssertEqual(windows[i].end, windows[i - 1].start, "contiguous, descending")
        }
        // Case 2: cycle crossed midnight (woke yesterday). The open-cycle civil
        // day (yesterday) must ALSO be excluded — newest is the day before it.
        let cycleCrossed = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 23)))
        let crossed = SessionStore.completedPriorCivilDayWindows(
            now: now, cycleStart: cycleCrossed, calendar: cal, backfillDays: 3
        )
        let aug6 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 6)))
        XCTAssertEqual(crossed.first?.start, aug6,
                       "open-cycle civil day (Aug 7) excluded; newest is Aug 6")
    }

    // A civil-midnight prior-day receipt (what the lane saves) must surface on
    // the week-chart source exactly as the current-cycle receipt does.
    func testPriorDayCivilMidnightReceiptsSurfaceViaRecentReceipts() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let cal = utcCalendar
        let fri = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 7)))
        let sat = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 8)))
        XCTAssertTrue(try store.save(makeEvidence(start: fri, ticks: 200, steps: 2200), strapIdentifier: strap))
        XCTAssertTrue(try store.save(makeEvidence(start: sat, ticks: 100, steps: 900), strapIdentifier: strap))
        // Reproduce the week-chart collapse (AtriaStrapStepsDetailSheet.loadWeekSteps).
        var map: [Date: Int] = [:]
        for receipt in store.recentReceipts(strapIdentifier: strap, limit: 14) {
            let day = cal.startOfDay(for: receipt.windowStart)
            map[day] = max(map[day] ?? 0, receipt.steps)
        }
        XCTAssertEqual(map[fri], 2200, "Friday lower bound surfaces")
        XCTAssertEqual(map[sat], 900, "Saturday lower bound surfaces")
    }

    func testV16ReceiptCannotMasqueradeAsV17Authority() throws {
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 10_000)
        let evidence = makeEvidence(start: start, ticks: 155, steps: 132)
        let writer = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        XCTAssertTrue(try writer.save(evidence, strapIdentifier: strap))

        let stateURL = directory.appendingPathComponent(
            "whoop4-motion-tick-days-v1.json"
        )
        let current = try String(contentsOf: stateURL, encoding: .utf8)
        let stale = current.replacingOccurrences(
            of: "whoop4-impact-gait-ensemble-v17",
            with: "whoop4-impact-gait-ensemble-v16"
        )
        XCTAssertNotEqual(stale, current)
        try XCTUnwrap(stale.data(using: .utf8)).write(
            to: stateURL,
            options: .atomic
        )

        let reader = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        XCTAssertNil(
            reader.load(strapIdentifier: strap, windowStart: start),
            "a durable v16 subtotal must be recomputed under v17"
        )
    }

    func testCurrentCycleAttemptSignatureInvalidatesForEvidenceAuthority() throws {
        let start = Date(timeIntervalSince1970: 9_000)
        let strap = "strap-a"
        let authority = AtriaWhoop4MotionBankCoverageLedger
            .ProjectionAuthority(
                algorithmVersion:
                    AtriaWhoop4MotionBankCoverageLedger.algorithmVersion,
                strapIdentifier: strap,
                closed: [],
                openStart: start
            )
        let source = HistoricalArchive.makeConsumerSourceFingerprint(
            catalogGeneration: 1,
            descriptors: []
        )
        let base = try XCTUnwrap(
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start.addingTimeInterval(1),
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint:
                    HistoricalArchive.makeConsumerSourceFingerprint(
                        catalogGeneration: 2,
                        descriptors: []
                    ),
                compactSourceIdentifier: "compact-1"
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepReceiptAttemptSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source,
                compactSourceIdentifier: "compact-2"
            )
        )
    }

    func testLegacyCompactMigrationSignatureTracksSourceCycleAndCoverage() throws {
        let start = Date(timeIntervalSince1970: 9_000)
        let strap = "strap-a"
        let source = HistoricalArchive.makeConsumerSourceFingerprint(
            catalogGeneration: 1,
            descriptors: []
        )
        let authority = AtriaWhoop4MotionBankCoverageLedger
            .ProjectionAuthority(
                algorithmVersion:
                    AtriaWhoop4MotionBankCoverageLedger.algorithmVersion,
                strapIdentifier: strap,
                closed: [],
                openStart: start
            )
        let base = try XCTUnwrap(
            SessionStore.currentCycleStepCompactMigrationSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source
            )
        )

        XCTAssertEqual(
            base,
            SessionStore.currentCycleStepCompactMigrationSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint: source
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepCompactMigrationSignature(
                strapIdentifier: strap,
                cycleStart: start.addingTimeInterval(1),
                coverageAuthority: authority,
                sourceFingerprint: source
            )
        )
        XCTAssertNotEqual(
            base,
            SessionStore.currentCycleStepCompactMigrationSignature(
                strapIdentifier: strap,
                cycleStart: start,
                coverageAuthority: authority,
                sourceFingerprint:
                    HistoricalArchive.makeConsumerSourceFingerprint(
                        catalogGeneration: 2,
                        descriptors: []
                    )
            )
        )
    }

    func testOlderOrWeakerReplayCannotReplaceReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 20_000)
        let strong = makeEvidence(
            start: start,
            ticks: 310,
            steps: 264,
            capturedAfter: 240,
            known: 220
        )
        let weaker = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 180,
            known: 160
        )

        XCTAssertTrue(try store.save(strong, strapIdentifier: strap))
        XCTAssertFalse(try store.save(weaker, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            strong
        )
    }

    func testNewerMonotonicSubtotalReplacesReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 30_000)
        let first = makeEvidence(start: start, ticks: 155, steps: 132)
        let second = makeEvidence(
            start: start,
            ticks: 315,
            steps: 268,
            capturedAfter: 360,
            known: 330
        )

        XCTAssertTrue(try store.save(first, strapIdentifier: strap))
        XCTAssertTrue(try store.save(second, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            second
        )
    }

    func testStrongerReplayMayCorrectFalsePositiveStepsDownward() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 40_000)
        let partial = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 180,
            known: 160
        )
        let corrected = makeEvidence(
            start: start,
            ticks: 315,
            steps: 126,
            capturedAfter: 360,
            known: 330
        )

        XCTAssertTrue(try store.save(partial, strapIdentifier: strap))
        XCTAssertTrue(try store.save(corrected, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            corrected
        )
    }

    func testDurableCurrentCycleReceiptFillsMissingAsyncProjection() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 50_000)
        let receipt = makeEvidence(
            start: start,
            ticks: 315,
            steps: 268,
            capturedAfter: 360,
            known: 330
        )
        XCTAssertTrue(try store.save(receipt, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifier: strap,
            windowStart: start,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].state, .missing)
        XCTAssertEqual(merged[0].knownStepDeltaSum, 268)
        XCTAssertEqual(merged[0].knownCoverageSeconds, 330)
        XCTAssertEqual(merged[0].dayStart, start)
        let presentation = AtriaDailyStepPresentation.resolve(
            day: start,
            now: start.addingTimeInterval(360),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: merged,
            physiologicalDayStart: start,
            calendar: utcCalendar
        )
        // Pin migrated 2026-08-05: valueText shows the clean number by the
        // 26057206 product decision ("~2% accurate strap steps get no ≥/~
        // qualifier"); partial-coverage honesty lives in detailText and
        // accessibilityText, and the .partial completeness assert below
        // still pins it.
        XCTAssertEqual(presentation.valueText, "268")
        XCTAssertEqual(presentation.completeness, .partial)
        XCTAssertEqual(presentation.source, .verifiedCanonical)
    }

    func testQualifiedReceiptEntersProductProjection() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 55_000)
        XCTAssertTrue(
            try store.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )

        let product = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifier: strap,
            windowStart: start,
            calendar: utcCalendar
        )
        let retainedResearch = store.load(
            strapIdentifier: strap,
            windowStart: start
        )

        XCTAssertTrue(
            AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified
        )
        XCTAssertEqual(product.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(product.first?.state, .missing)
        XCTAssertEqual(retainedResearch?.steps, 268)
    }

    func testQualifiedReceiptProjectionIsNeverRemovedAsUnqualified() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 57_000)
        let evidence = makeEvidence(
            start: start,
            ticks: 315,
            steps: 268,
            capturedAfter: 180,
            known: 160
        )
        XCTAssertTrue(try store.save(evidence, strapIdentifier: strap))
        let staleInjected = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "1970-01-01",
            dayStart: start,
            dayEnd: evidence.capturedThrough,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: evidence.steps,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: evidence.knownCoverageSeconds,
            missingCoverageSeconds: evidence.missingCoverageSeconds
        )
        var genuineCanonical = staleInjected
        genuineCanonical = .init(
            localDay: genuineCanonical.localDay,
            dayStart: genuineCanonical.dayStart,
            dayEnd: genuineCanonical.dayEnd,
            state: genuineCanonical.state,
            stepCount: genuineCanonical.stepCount,
            knownStepDeltaSum: genuineCanonical.knownStepDeltaSum,
            knownEpochCount: 2,
            rejectedOrUnknownEpochCount:
                genuineCanonical.rejectedOrUnknownEpochCount,
            knownCoverageSeconds: genuineCanonical.knownCoverageSeconds,
            missingCoverageSeconds: genuineCanonical.missingCoverageSeconds
        )

        let filtered = store.removingUnqualifiedResearchEvidence(
            from: [staleInjected, genuineCanonical]
        )

        XCTAssertTrue(
            AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified
        )
        XCTAssertEqual(filtered, [staleInjected, genuineCanonical])
    }

    func testDurableReceiptWinsOnlyWhenItsCoverageIsStronger() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 60_000)
        XCTAssertTrue(
            try store.save(
                makeEvidence(
                    start: start,
                    ticks: 315,
                    steps: 268,
                    capturedAfter: 360,
                    known: 330
                ),
                strapIdentifier: strap
            )
        )
        let strongerProjection = stepDay(
            start: start,
            end: start.addingTimeInterval(480),
            steps: 300,
            known: 450
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [strongerProjection],
            strapIdentifier: strap,
            windowStart: start,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], strongerProjection)
    }

    func testExactCanonicalCurrentCycleOutranksPartialReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 70_000)
        XCTAssertTrue(
            try store.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )
        let exact = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "1970-01-01",
            dayStart: start,
            dayEnd: start.addingTimeInterval(600),
            state: .available,
            stepCount: 271,
            knownStepDeltaSum: 271,
            knownEpochCount: 10,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 600,
            missingCoverageSeconds: 0
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [exact],
            strapIdentifier: strap,
            windowStart: start,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged, [exact])
    }

    func testSavedLinkIdentifierPublishesReceiptBeforeHistoryIdentityReturns()
        throws {
        let suite = "AtriaWhoop4MotionTickDailyStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 80_000)
        defaults.set(
            strap,
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        )
        XCTAssertTrue(
            try store.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )

        let identifiers = AtriaWhoop4MotionTickDailyStore
            .persistedStrapIdentifiers(defaults: defaults)
        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: identifiers,
            windowStart: start,
            now: start.addingTimeInterval(360),
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(identifiers, [strap])
        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
    }

    func testCurrentSavedLinkReplacesFormerVerifiedHistoryIdentity() throws {
        let suite = "AtriaWhoop4MotionTickDailyStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let formerStrap = UUID().uuidString
        let currentStrap = UUID().uuidString
        defaults.set(
            formerStrap,
            forKey: AtriaBLEManager.OfflineSyncDefaults
                .verifiedHistoryPeripheralID
        )
        defaults.set(
            currentStrap,
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        )

        XCTAssertEqual(
            AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers(
                defaults: defaults
            ),
            [currentStrap],
            "a former strap must not contribute to the current cycle"
        )
    }

    func testRelaunchReloadsDurableReceiptFromDisk() throws {
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 90_000)
        let firstProcess =
            AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        XCTAssertTrue(
            try firstProcess.save(
                makeEvidence(start: start, ticks: 315, steps: 268),
                strapIdentifier: strap
            )
        )

        let relaunched =
            AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let merged = relaunched.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: start.addingTimeInterval(360),
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(merged.first?.state, .missing)
    }

    func testContainedCurrentCivilDayReceiptIsSafePartialLowerBound() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 172_800)
        let receiptStart = cycleStart.addingTimeInterval(3_600)
        XCTAssertTrue(
            try store.save(
                makeEvidence(
                    start: receiptStart,
                    ticks: 315,
                    steps: 268,
                    capturedAfter: 360,
                    known: 330
                ),
                strapIdentifier: strap
            )
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: cycleStart,
            now: receiptStart.addingTimeInterval(360),
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.dayStart, cycleStart)
        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(merged.first?.state, .missing)
        XCTAssertEqual(merged.first?.missingCoverageSeconds, 3_600 + 270)
    }

    func testContainedReceiptRemainsCurrentAcrossCivilMidnight() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        // Wake at 20:00 UTC, first verified bank starts at 21:00, and the
        // active physiological cycle remains open after civil midnight.
        let cycleStart = Date(timeIntervalSince1970: 20 * 3_600)
        let receiptStart = cycleStart.addingTimeInterval(3_600)
        let afterMidnight = Date(timeIntervalSince1970: 24 * 3_600 + 600)
        XCTAssertTrue(
            try store.save(
                .init(
                    windowStart: receiptStart,
                    windowEnd: afterMidnight,
                    motionTicks: 315,
                    steps: 268,
                    knownCoverageSeconds: 3_600,
                    missingCoverageSeconds: 7_800,
                    decodedRows: 3_600,
                    capturedThrough: afterMidnight
                ),
                strapIdentifier: strap
            )
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: cycleStart,
            now: afterMidnight,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.dayStart, cycleStart)
        XCTAssertEqual(merged.first?.knownStepDeltaSum, 268)
        XCTAssertEqual(merged.first?.state, .missing)
        XCTAssertEqual(merged.first?.missingCoverageSeconds, 3_600 + 7_800)
    }

    func testReceiptBeforeCurrentCycleNeverMasqueradesAsToday() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let oldStart = Date(timeIntervalSince1970: 172_800)
        let newCycle = oldStart.addingTimeInterval(60)
        XCTAssertTrue(
            try store.save(
                makeEvidence(
                    start: oldStart,
                    ticks: 315,
                    steps: 268,
                    capturedAfter: 180,
                    known: 330
                ),
                strapIdentifier: strap
            )
        )

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: newCycle,
            now: oldStart.addingTimeInterval(180),
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertTrue(merged.isEmpty)
    }

    // 2026-07-31: prior-cycle disclosure lookup. The newest receipt that
    // closed before the wake boundary is returned separately for copy-only
    // disclosure and never merges into the current cycle's projected days.
    func testLatestPriorCycleReceiptIsDisclosedSeparatelyFromToday() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let olderStart = Date(timeIntervalSince1970: 100_000)
        let priorStart = olderStart.addingTimeInterval(86_400)
        // makeEvidence windows close at +600; the new cycle begins after the
        // prior window has fully closed.
        let newCycle = priorStart.addingTimeInterval(700)
        let todayStart = newCycle.addingTimeInterval(60)
        XCTAssertTrue(try store.save(
            makeEvidence(start: olderStart, ticks: 1_100, steps: 999),
            strapIdentifier: strap
        ))
        XCTAssertTrue(try store.save(
            makeEvidence(start: priorStart, ticks: 1_600, steps: 1_435),
            strapIdentifier: strap
        ))
        XCTAssertTrue(try store.save(
            makeEvidence(start: todayStart, ticks: 90, steps: 74),
            strapIdentifier: strap
        ))

        let prior = store.latestReceipt(
            before: newCycle,
            strapIdentifiers: [strap],
            includeUnqualifiedResearchEvidence: true
        )
        XCTAssertEqual(prior?.windowStart, priorStart,
                       "the newest closed prior window wins")
        XCTAssertEqual(prior?.steps, 1_435)

        // Today's open-cycle receipt must never be offered as prior-cycle
        // disclosure, and the prior-cycle steps must not enter projected days
        // for the new cycle (the masquerade guard stays authoritative).
        XCTAssertNotEqual(prior?.windowStart, todayStart)
        XCTAssertNil(store.latestReceipt(
            before: olderStart,
            strapIdentifiers: [strap],
            includeUnqualifiedResearchEvidence: true
        ))
        XCTAssertNil(store.latestReceipt(
            before: newCycle,
            strapIdentifiers: [UUID().uuidString],
            includeUnqualifiedResearchEvidence: true
        ))
    }

    func testReceiptOverlappingWakeBoundaryIsNotDisclosedAsPrior() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let priorStart = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(try store.save(
            makeEvidence(start: priorStart, ticks: 1_600, steps: 1_435),
            strapIdentifier: strap
        ))
        // The receipt's window (start..start+600) crosses this boundary, so
        // its subtotal may straddle both cycles and must not be disclosed.
        let midWindowBoundary = priorStart.addingTimeInterval(300)
        XCTAssertNil(store.latestReceipt(
            before: midWindowBoundary,
            strapIdentifiers: [strap],
            includeUnqualifiedResearchEvidence: true
        ))
    }

    func testRecentReceiptsReturnNewestFirstAndIsolateStrap() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let first = Date(timeIntervalSince1970: 100_000)
        let second = first.addingTimeInterval(86_400)
        let third = second.addingTimeInterval(86_400)
        for (start, steps) in [(first, 100), (second, 200), (third, 300)] {
            XCTAssertTrue(try store.save(
                makeEvidence(start: start, ticks: steps + 40, steps: steps),
                strapIdentifier: strap
            ))
        }

        let receipts = store.recentReceipts(strapIdentifier: strap)
        XCTAssertEqual(receipts.map(\.windowStart), [third, second, first])
        XCTAssertEqual(
            store.recentReceipts(strapIdentifier: strap, limit: 2)
                .map(\.steps),
            [300, 200]
        )
        XCTAssertTrue(
            store.recentReceipts(strapIdentifier: UUID().uuidString).isEmpty
        )
    }

    func testCompleteDurableReceiptPublishesExactCount() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 100_000)
        let complete = HistoricalArchive.MotionTickDayEvidence(
            windowStart: start,
            windowEnd: start.addingTimeInterval(600),
            motionTicks: 320,
            steps: 271,
            knownCoverageSeconds: 600,
            missingCoverageSeconds: 0,
            decodedRows: 20,
            capturedThrough: start.addingTimeInterval(600)
        )
        XCTAssertTrue(try store.save(complete, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: start.addingTimeInterval(600),
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )

        XCTAssertEqual(merged.first?.state, .available)
        XCTAssertEqual(merged.first?.stepCount, 271)
    }

    func testObservedMotionWithNoQualifiedCadenceIsNotPublishedAsZero()
        throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 110_000)
        let unresolved = makeEvidence(
            start: start,
            ticks: 7_097,
            steps: 0,
            capturedAfter: 600,
            known: 530
        )
        XCTAssertTrue(try store.save(unresolved, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: unresolved.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )
        let day = try XCTUnwrap(merged.first)
        XCTAssertEqual(day.state, .missing)
        XCTAssertNil(day.stepCount)
        XCTAssertEqual(day.knownCoverageSeconds, 0)
        XCTAssertGreaterThan(day.missingCoverageSeconds, 0)

        let presentation = AtriaDailyStepPresentation.resolve(
            day: start,
            now: unresolved.capturedThrough,
            liveCount: 4_257,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: unresolved.capturedThrough,
            canonicalDays: merged,
            physiologicalDayStart: start,
            calendar: utcCalendar
        )
        XCTAssertNil(presentation.count)
        XCTAssertEqual(
            presentation.unavailabilityReason,
            .motionObservedCountUnresolved
        )
        XCTAssertEqual(
            presentation.detailText,
            "Strap motion found · count still resolving"
        )
    }

    func testTrueStationaryCompleteReceiptMayPublishVerifiedZero() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 160_000)
        let stationary = HistoricalArchive.MotionTickDayEvidence(
            windowStart: start,
            windowEnd: start.addingTimeInterval(600),
            motionTicks: 0,
            steps: 0,
            knownCoverageSeconds: 600,
            missingCoverageSeconds: 0,
            decodedRows: 600,
            capturedThrough: start.addingTimeInterval(600)
        )
        XCTAssertTrue(try store.save(stationary, strapIdentifier: strap))

        let merged = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: stationary.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )
        XCTAssertEqual(merged.first?.state, .available)
        XCTAssertEqual(merged.first?.stepCount, 0)
    }

    func testCompactReceiptPlanNeverAdmitsCanonicalFallback() {
        XCTAssertEqual(
            SessionStore.currentCycleStepReceiptReadPlan(
                compactReadQualified: true
            ),
            .publishCompact,
            "a durable compact subtotal must not wait behind exact or recovered work"
        )
        XCTAssertEqual(
            SessionStore.currentCycleStepReceiptReadPlan(
                compactReadQualified: false
            ),
            .compactOnlyMissing,
            "a compact miss must not authorize JSONL from a hot caller"
        )
    }

    func testLegacyMigrationAdmissionRequiresSafeBackgroundMaintenance() {
        func admitted(
            background: Bool = true,
            thermal: ProcessInfo.ThermalState = .nominal,
            lowPower: Bool = false,
            battery: UIDevice.BatteryState = .charging,
            level: Float = 0.8,
            exactOwner: Bool = false,
            recoveredOwner: Bool = false
        ) -> Bool {
            SessionStore.shouldAdmitBoundedLegacyCurrentCycleStepMigration(
                isBackgroundMaintenance: background,
                thermalState: thermal,
                isLowPowerModeEnabled: lowPower,
                batteryState: battery,
                batteryLevel: level,
                exactRecoveryOwnsPriority: exactOwner,
                recoveredCycleEngaged: recoveredOwner
            )
        }

        XCTAssertTrue(admitted())
        XCTAssertFalse(admitted(background: false))
        XCTAssertFalse(admitted(thermal: .serious))
        XCTAssertFalse(admitted(thermal: .critical))
        XCTAssertFalse(admitted(lowPower: true))
        XCTAssertFalse(admitted(exactOwner: true))
        XCTAssertFalse(admitted(recoveredOwner: true))
        XCTAssertFalse(admitted(battery: .unknown, level: -1))
        XCTAssertFalse(admitted(battery: .unplugged, level: 0.49))
    }

    func testLegacyMigrationSourceBudgetIsExactAndFailsClosed() {
        let mebibyte = UInt64(1_024 * 1_024)
        let budget = HistoricalArchive.MotionTickDayEvidenceMigrationBudget(
            maximumFileCount: 4,
            maximumTotalBytes: 32 * mebibyte
        )
        func descriptor(
            index: Int,
            size: UInt64,
            compressed: Bool = false
        ) -> AtriaHistoricalJSONLRecentScanner.FileDescriptor {
            let suffix = compressed
                ? AtriaHistoricalSealedJSONLCompression.artifactExtension
                : "jsonl"
            return .init(
                url: URL(fileURLWithPath: "/tmp/migration-\(index).\(suffix)"),
                size: size,
                modificationTime: TimeInterval(index),
                resourceIdentifier: "migration-\(index)"
            )
        }

        let exactBoundary = (0..<4).map {
            descriptor(index: $0, size: 8 * mebibyte)
        }
        XCTAssertTrue(
            HistoricalArchive.motionTickDayEvidenceMigrationSourcesFitBudget(
                exactBoundary,
                budget: budget
            )
        )
        XCTAssertFalse(
            HistoricalArchive.motionTickDayEvidenceMigrationSourcesFitBudget(
                exactBoundary + [descriptor(index: 4, size: 0)],
                budget: budget
            ),
            "the file-count boundary plus one must be refused"
        )
        XCTAssertFalse(
            HistoricalArchive.motionTickDayEvidenceMigrationSourcesFitBudget(
                [descriptor(index: 0, size: 32 * mebibyte + 1)],
                budget: budget
            ),
            "the byte boundary plus one must be refused"
        )
        XCTAssertFalse(
            HistoricalArchive.motionTickDayEvidenceMigrationSourcesFitBudget(
                [descriptor(index: 0, size: 1, compressed: true)],
                budget: budget
            ),
            "compressed sources can expand beyond their admitted disk size"
        )
    }

    func testVerifiedOffloadRefreshBypassesUnrelatedHistoryPriorityFence() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sessions = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let ble = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(sessions.range(
            of: "private func refreshCurrentCycleStrapStepReceipt"
        ))
        let end = try XCTUnwrap(sessions.range(
            of: "/// Loads one older verified canonical page",
            range: start.upperBound..<sessions.endIndex
        ))
        let body = String(sessions[start.lowerBound..<end.lowerBound])
        // Every interactive/current-link callback is compact-only. Neither a
        // compact miss nor a prior-day refresh can reach canonical JSONL.
        XCTAssertTrue(body.contains(
            "case .publishCompact"
        ))
        XCTAssertTrue(body.contains(
            "case .compactOnlyMissing"
        ))
        XCTAssertNotNil(body.range(
            of: "AtriaWhoop4MotionTickCompactStore.shared\n                .motionTickDayEvidenceRead("
        ))
        XCTAssertTrue(body.contains(
            "Self.currentCycleStepReceiptQueue.async"
        ), "compact receipt work must not wait behind lifetime archive projections")
        XCTAssertFalse(body.contains(
            "HistoricalArchive.motionTickDayEvidenceRead("
        ))
        XCTAssertFalse(body.contains(
            "Self.historySnapshotProjectionQueue"
        ))
        XCTAssertFalse(body.contains(
            "refreshPriorCivilDayStrapStepReceipts"
        ))
        XCTAssertTrue(body.contains(
            "AtriaWhoop4MotionTickDailyStore.shared.save("
        ))
        XCTAssertFalse(body.contains(
            "exactRecoveryProjectionOwnsArchivePriority"
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"finalized_bank_offload\""
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"session_store_init\""
        ))
        XCTAssertFalse(sessions.contains(
            "prepareCurrentCycleStrapStepReceipt"
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"compact_generation_durable\""
        ), "partial durable compact progress must refresh the daily receipt")
        XCTAssertTrue(sessions.contains(
            ".didSynchronizeNotification"
        ))
        XCTAssertTrue(ble.contains(
            "reason: \"compact_generation_durable\""
        ))
        XCTAssertTrue(ble.contains(
            "allowRetry: false"
        ), "post-fsync ticket verification must not start another BLE drain")
        XCTAssertTrue(body.contains(
            "if !changed"
        ))
        XCTAssertTrue(body.contains(
            ".didSaveNotification"
        ), "an unchanged durable receipt must still refresh relaunch surfaces")
    }

    func testLegacyCanonicalMotionMigratesOnlyThroughBoundedBackgroundLane()
        throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourcesURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let migrationStart = try XCTUnwrap(sessions.range(
            of: "func scheduleBoundedLegacyCurrentCycleStepMigrationIfSafe("
        ))
        let refreshStart = try XCTUnwrap(sessions.range(
            of: "private func refreshCurrentCycleStrapStepReceipt",
            range: migrationStart.upperBound..<sessions.endIndex
        ))
        let migration = String(
            sessions[migrationStart.lowerBound..<refreshStart.lowerBound]
        )

        XCTAssertTrue(sessions.contains(
            "private struct CurrentCycleStepLegacyMigrationAdmission"
        ))
        XCTAssertTrue(migration.contains(
            "shouldAdmitBoundedLegacyCurrentCycleStepMigration("
        ))
        XCTAssertTrue(migration.contains(
            "Self.historySnapshotProjectionQueue.async"
        ))
        XCTAssertTrue(migration.contains(
            ".boundedLegacyMotionTickDayEvidenceMigrationRead("
        ))
        XCTAssertTrue(migration.contains(
            "Self.currentCycleStepLegacyMigrationMaximumFileCount"
        ))
        XCTAssertTrue(migration.contains(
            "Self.currentCycleStepLegacyMigrationMaximumTotalBytes"
        ))
        XCTAssertTrue(migration.contains(
            "sourceBefore == sourceAfter"
        ))
        XCTAssertTrue(migration.contains(
            "Date() <= admission.expiresAt"
        ))
        XCTAssertTrue(migration.contains(
            "currentCycleStepCompactMigrationGeneration"
        ))
        XCTAssertTrue(migration.contains(
            "== admission.generation"
        ))
        XCTAssertFalse(migration.contains(
            "Self.historySnapshotProjectionQueue.sync"
        ))
        XCTAssertFalse(migration.contains(
            "HistoricalArchive.motionTickDayEvidenceRead("
        ))
        XCTAssertTrue(sessions.contains(
            "UIApplication.shared.applicationState == .background"
        ))

        let archive = try String(
            contentsOf: sourcesURL.appendingPathComponent(
                "HistoricalArchive.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(archive.contains(
            "func boundedLegacyMotionTickDayEvidenceMigrationRead("
        ))
        XCTAssertTrue(archive.contains(
            "motionTickDayEvidenceMigrationSourcesFitBudget("
        ))
        XCTAssertTrue(archive.contains(
            "guard !descriptor.isCompressed"
        ))

        let app = try String(
            contentsOf: sourcesURL.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        let backgroundMigration = try XCTUnwrap(app.range(
            of: "scheduleBoundedLegacyCurrentCycleStepMigrationIfSafe("
        ))
        let eventualProjection = try XCTUnwrap(app.range(
            of: "requestBackgroundArchiveProjectionIfSafe(",
            range: backgroundMigration.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(
            backgroundMigration.lowerBound,
            eventualProjection.lowerBound,
            "bounded migration must preserve the eventual guarded full projection"
        )
    }

    func testArchiveWideMotionReadersShareOneSerialConsumerLane() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourcesURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let ble = try String(
            contentsOf: sourcesURL.appendingPathComponent(
                "AtriaBLEManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(sessions.contains(
            "historySnapshotProjectionQueue =\n        HistoricalArchive.consumerProjectionQueue"
        ))
        XCTAssertTrue(sessions.contains(
            "workoutStepEvidenceQueue = DispatchQueue("
        ), "confirmed-workout compact reads must not queue a lifetime archive consumer")
        XCTAssertTrue(sessions.contains(
            "private static let currentCycleStepReceiptQueue = DispatchQueue("
        ))
        XCTAssertTrue(ble.contains(
            "HistoricalArchive.consumerProjectionQueue.async"
        ))

        let historyStart = try XCTUnwrap(sessions.range(
            of: "private func refreshHistorySnapshotCache"
        ))
        let historyEnd = try XCTUnwrap(sessions.range(
            of: "private func refreshCurrentCycleStrapStepReceipt",
            range: historyStart.upperBound..<sessions.endIndex
        ))
        let historyBody = String(
            sessions[historyStart.lowerBound..<historyEnd.lowerBound]
        )
        XCTAssertFalse(historyBody.contains(
            "HistoricalArchive.motionTickDayEvidence("
        ), "history refresh must consume the durable receipt, not decode it again")
        // 2026-07-31: history retention reads the recent durable receipts
        // (prior cycles stay visible across relaunch) instead of only the
        // exact current-window record — still the durable store, never a
        // fresh archive decode.
        XCTAssertTrue(historyBody.contains(
            "AtriaWhoop4MotionTickDailyStore.shared.recentReceipts("
        ))

        let home = try String(
            contentsOf: sourcesURL.appendingPathComponent(
                "AtriaHomeView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(home.contains(
            "ble.$status.removeDuplicates().map { _ in () }"
        ))
        XCTAssertTrue(home.contains(
            "ble.$isBluetoothReady.removeDuplicates().map { _ in () }"
        ))
        let historyPublisher = try XCTUnwrap(home.range(
            of: "store.$historySnapshot"
        ))
        let historyPublisherEnd = try XCTUnwrap(home.range(
            of: ".store(in: &cancellables)",
            range: historyPublisher.upperBound..<home.endIndex
        ))
        let historyPublisherBody = String(
            home[historyPublisher.lowerBound..<historyPublisherEnd.upperBound]
        )
        XCTAssertTrue(historyPublisherBody.contains(
            "self?.publishCoreLive()"
        ))
    }

    private func makeEvidence(
        start: Date,
        ticks: Int,
        steps: Int,
        capturedAfter: TimeInterval = 180,
        known: Int = 160
    ) -> HistoricalArchive.MotionTickDayEvidence {
        .init(
            windowStart: start,
            windowEnd: start.addingTimeInterval(600),
            motionTicks: ticks,
            steps: steps,
            knownCoverageSeconds: known,
            missingCoverageSeconds: 600 - known,
            decodedRows: 20,
            capturedThrough: start.addingTimeInterval(capturedAfter)
        )
    }

    private func stepDay(
        start: Date,
        end: Date,
        steps: Int,
        known: Int
    ) -> AtriaHistoricalDailyConsumerProjection.StepDay {
        .init(
            localDay: "1970-01-01",
            dayStart: start,
            dayEnd: end,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: steps,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: known,
            missingCoverageSeconds: max(
                0,
                Int(end.timeIntervalSince(start)) - known
            )
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
