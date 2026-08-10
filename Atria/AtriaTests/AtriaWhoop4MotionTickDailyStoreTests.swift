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

    func testSameCountNewerCapturedThroughReplacesDurableReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 10_000)
        let first = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 180,
            known: 160
        )
        let renewed = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 240,
            known: 160
        )

        XCTAssertTrue(try store.save(first, strapIdentifier: strap))
        XCTAssertTrue(
            try store.save(renewed, strapIdentifier: strap),
            "an unchanged count still carries a newer verified-through clock"
        )
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            renewed
        )
    }

    func testLaterCaptureWithLowerCoverageMergesPriorVerifiedSubtotal() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 10_000)
        let firstCapturedThrough = start.addingTimeInterval(65_150)
        let first = HistoricalArchive.MotionTickDayEvidence(
            windowStart: start,
            windowEnd: start.addingTimeInterval(85_420),
            motionTicks: 2_635,
            steps: 1_299,
            knownCoverageSeconds: 44_058,
            missingCoverageSeconds: 41_362,
            decodedRows: 47_809,
            capturedThrough: firstCapturedThrough
        )
        let candidate = HistoricalArchive.MotionTickDayEvidence(
            windowStart: start,
            windowEnd: start.addingTimeInterval(95_000),
            motionTicks: 2_900,
            steps: 1_340,
            knownCoverageSeconds: 43_000,
            missingCoverageSeconds: 52_000,
            decodedRows: 50_000,
            capturedThrough: firstCapturedThrough.addingTimeInterval(9_554)
        )

        XCTAssertTrue(try store.save(first, strapIdentifier: strap))
        XCTAssertTrue(try store.save(candidate, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            .init(
                windowStart: candidate.windowStart,
                windowEnd: candidate.windowEnd,
                motionTicks: first.motionTicks,
                steps: first.steps,
                knownCoverageSeconds: first.knownCoverageSeconds,
                missingCoverageSeconds: 95_000 - 44_058,
                decodedRows: candidate.decodedRows,
                capturedThrough: candidate.capturedThrough
            )
        )
    }

    func testLowerCoverageWithoutLaterCaptureCannotReplaceReceipt() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 20_000)
        let first = makeEvidence(
            start: start,
            ticks: 2_635,
            steps: 1_299,
            capturedAfter: 240,
            known: 220
        )
        let candidate = makeEvidence(
            start: start,
            ticks: 2_900,
            steps: 1_340,
            capturedAfter: 240,
            known: 200
        )

        XCTAssertTrue(try store.save(first, strapIdentifier: strap))
        XCTAssertFalse(try store.save(candidate, strapIdentifier: strap))
        XCTAssertEqual(
            store.load(strapIdentifier: strap, windowStart: start),
            first
        )
    }

    func testSameClockCorrectionChangesPublicationContentRevision() throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 10_000)
        let first = makeEvidence(
            start: start,
            ticks: 155,
            steps: 132,
            capturedAfter: 240,
            known: 160
        )
        let corrected = makeEvidence(
            start: start,
            ticks: 149,
            steps: 126,
            capturedAfter: 240,
            known: 160
        )

        XCTAssertTrue(try store.save(first, strapIdentifier: strap))
        let firstReceipt = try XCTUnwrap(store.currentCyclePublication(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: first.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        ).receipt)

        XCTAssertTrue(try store.save(corrected, strapIdentifier: strap))
        let correctedReceipt = try XCTUnwrap(store.currentCyclePublication(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: corrected.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        ).receipt)

        XCTAssertEqual(firstReceipt.evidence.capturedThrough,
                       correctedReceipt.evidence.capturedThrough)
        XCTAssertEqual(correctedReceipt.evidence, corrected)
        XCTAssertEqual(correctedReceipt.sourceIdentifier, strap)
        XCTAssertEqual(correctedReceipt.contentRevision.count, 64)
        XCTAssertNotEqual(firstReceipt.contentRevision,
                          correctedReceipt.contentRevision)
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

    func testNewerUnresolvedReceiptInvalidatesOlderPartialProjection()
        throws {
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let start = Date(timeIntervalSince1970: 150_000)
        let stationaryPrefix = makeEvidence(
            start: start,
            ticks: 0,
            steps: 0,
            capturedAfter: 180,
            known: 160
        )
        XCTAssertTrue(
            try store.save(stationaryPrefix, strapIdentifier: strap)
        )
        let priorProjection = store.mergingCurrentCycleReceipt(
            into: [],
            strapIdentifiers: [strap],
            windowStart: start,
            now: stationaryPrefix.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )
        XCTAssertEqual(priorProjection.first?.knownCoverageSeconds, 160)
        XCTAssertEqual(
            priorProjection.first?.dayEnd,
            stationaryPrefix.capturedThrough
        )

        let unresolved = makeEvidence(
            start: start,
            ticks: 28,
            steps: 0,
            capturedAfter: 360,
            known: 330
        )
        XCTAssertTrue(try store.save(unresolved, strapIdentifier: strap))
        let cached = try XCTUnwrap(
            store.load(strapIdentifier: strap, windowStart: start)
        )
        XCTAssertEqual(cached.capturedThrough, unresolved.capturedThrough)
        XCTAssertEqual(cached.motionTicks, 28)

        let refreshed = store.mergingCurrentCycleReceipt(
            into: priorProjection,
            strapIdentifiers: [strap],
            windowStart: start,
            now: unresolved.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: utcCalendar
        )
        let day = try XCTUnwrap(refreshed.first)
        XCTAssertEqual(
            day.dayEnd,
            unresolved.capturedThrough,
            "the latest durable receipt must invalidate the stale prefix clock"
        )
        XCTAssertEqual(day.state, .missing)
        XCTAssertNil(day.stepCount)
        XCTAssertEqual(day.knownCoverageSeconds, 0)

        let presentation = AtriaDailyStepPresentation.resolve(
            day: start,
            now: unresolved.capturedThrough,
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: refreshed,
            physiologicalDayStart: start,
            calendar: utcCalendar
        )
        XCTAssertNil(presentation.count)
        XCTAssertEqual(
            presentation.unavailabilityReason,
            .motionObservedCountUnresolved
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

    func testReceiptWindowsUseCurrentThenImmediatelyPriorMainSleepCycle()
        throws {
        let calendar = utcCalendar
        let priorWake = try XCTUnwrap(calendar.date(from: .init(
            year: 2026,
            month: 8,
            day: 9,
            hour: 7
        )))
        let currentWake = try XCTUnwrap(calendar.date(from: .init(
            year: 2026,
            month: 8,
            day: 10,
            hour: 7
        )))
        let now = try XCTUnwrap(calendar.date(from: .init(
            year: 2026,
            month: 8,
            day: 10,
            hour: 12
        )))
        let sleeps = [
            makeSleep(
                id: "prior",
                start: priorWake.addingTimeInterval(-8 * 60 * 60),
                end: priorWake
            ),
            makeSleep(
                id: "current",
                start: currentWake.addingTimeInterval(-8 * 60 * 60),
                end: currentWake
            ),
        ]

        let windows = SessionStore.currentAndPriorStepReceiptWindows(
            now: now,
            confirmedSleeps: sleeps,
            calendar: calendar
        )

        XCTAssertEqual(windows.map(\.role), [.current, .immediatelyPrior])
        XCTAssertEqual(
            windows.map(\.interval),
            [
                .init(start: currentWake, end: now),
                .init(start: priorWake, end: currentWake),
            ]
        )
        XCTAssertEqual(windows.count, 2, "no older cycle is admitted")
    }

    func testReceiptWindowsUseOnlyTwoMostRecentNoSleepFallbackCycles()
        throws {
        let calendar = utcCalendar
        let wake = try XCTUnwrap(calendar.date(from: .init(
            year: 2026,
            month: 8,
            day: 7,
            hour: 7
        )))
        let sleep = makeSleep(
            id: "anchor",
            start: wake.addingTimeInterval(-8 * 60 * 60),
            end: wake
        )
        let firstFallback = try XCTUnwrap(
            AtriaPhysiologicalCycle.firstNoSleepFallback(
                after: wake,
                eventTimeZoneIdentifier: "UTC",
                calendar: calendar
            )
        )
        let secondFallback = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: 1,
            to: firstFallback
        ))
        let now = secondFallback.addingTimeInterval(2 * 60 * 60)

        let windows = SessionStore.currentAndPriorStepReceiptWindows(
            now: now,
            confirmedSleeps: [sleep],
            calendar: calendar
        )

        XCTAssertEqual(windows.map(\.role), [.current, .immediatelyPrior])
        XCTAssertEqual(
            windows.map(\.interval),
            [
                .init(start: secondFallback, end: now),
                .init(start: firstFallback, end: secondFallback),
            ]
        )
        XCTAssertFalse(windows.contains {
            abs($0.interval.start.timeIntervalSince(wake)) < 1
        }, "the worker must never expand to a third/older cycle")
    }

    func testInitialFallbackReceiptWindowsPreserveDSTCalendarBoundaries()
        throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(
            identifier: "America/Los_Angeles"
        ))
        let now = try XCTUnwrap(calendar.date(from: .init(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        )))

        let windows = SessionStore.currentAndPriorStepReceiptWindows(
            now: now,
            confirmedSleeps: [],
            calendar: calendar
        )
        let expectedCurrent = AtriaPhysiologicalCycle.current(
            now: now,
            confirmedSleeps: [],
            calendar: calendar
        ).start
        let expectedPrior = AtriaPhysiologicalCycle.current(
            now: expectedCurrent.addingTimeInterval(-0.001),
            confirmedSleeps: [],
            calendar: calendar
        ).start

        XCTAssertEqual(windows.map(\.role), [.current, .immediatelyPrior])
        XCTAssertEqual(windows[0].interval.start, expectedCurrent)
        XCTAssertEqual(windows[1].interval.start, expectedPrior)
        XCTAssertEqual(windows[1].interval.end, expectedCurrent)
        XCTAssertEqual(
            calendar.component(.hour, from: windows[0].interval.start),
            calendar.component(.hour, from: windows[1].interval.start),
            "DST must preserve the physiological fallback's local clock"
        )
    }

    func testPriorReceiptAdvancesWhenNewCurrentCycleCompactReadIsMissing()
        throws {
        let calendar = utcCalendar
        let priorWake = Date(timeIntervalSince1970: 1_786_252_400)
        let currentWake = priorWake.addingTimeInterval(24 * 60 * 60)
        let now = currentWake.addingTimeInterval(2 * 60 * 60)
        let sleeps = [
            makeSleep(
                id: "prior",
                start: priorWake.addingTimeInterval(-8 * 60 * 60),
                end: priorWake
            ),
            makeSleep(
                id: "current",
                start: currentWake.addingTimeInterval(-8 * 60 * 60),
                end: currentWake
            ),
        ]
        let windows = SessionStore.currentAndPriorStepReceiptWindows(
            now: now,
            confirmedSleeps: sleeps,
            calendar: calendar
        )
        let prior = try XCTUnwrap(
            windows.first { $0.role == .immediatelyPrior }
        )
        let current = try XCTUnwrap(windows.first { $0.role == .current })
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString
        let foreignStrap = UUID().uuidString
        let old = makeWindowEvidence(
            prior.interval,
            ticks: 900,
            steps: 700,
            known: 8_000,
            capturedThrough: prior.interval.start.addingTimeInterval(12 * 60 * 60)
        )
        let strengthened = makeWindowEvidence(
            prior.interval,
            ticks: 1_800,
            steps: 1_450,
            known: 52_000,
            capturedThrough: prior.interval.end.addingTimeInterval(-60)
        )
        XCTAssertTrue(try store.save(old, strapIdentifier: strap))
        XCTAssertTrue(try store.save(old, strapIdentifier: foreignStrap))
        let oldRevision = try XCTUnwrap(store.currentCyclePublication(
            into: [],
            strapIdentifiers: [strap],
            windowStart: prior.interval.start,
            now: old.capturedThrough,
            includeUnqualifiedResearchEvidence: true,
            calendar: calendar
        ).receipt?.contentRevision)

        try replayCompactReceiptReads(
            windows: windows,
            reads: [
                .current: .incomplete,
                .immediatelyPrior: .qualified(strengthened),
            ],
            store: store,
            strapIdentifier: strap
        )

        XCTAssertNil(store.load(
            strapIdentifier: strap,
            windowStart: current.interval.start
        ), "a missing current compact read must not fabricate a receipt")
        XCTAssertEqual(
            store.load(
                strapIdentifier: strap,
                windowStart: prior.interval.start
            ),
            strengthened
        )
        XCTAssertEqual(
            store.load(
                strapIdentifier: foreignStrap,
                windowStart: prior.interval.start
            ),
            old,
            "prior replay remains isolated to the selected strap"
        )
        let strengthenedPublication = try XCTUnwrap(
            store.currentCyclePublication(
                into: [],
                strapIdentifiers: [strap],
                windowStart: prior.interval.start,
                now: strengthened.capturedThrough,
                includeUnqualifiedResearchEvidence: true,
                calendar: calendar
            ).receipt
        )
        XCTAssertEqual(
            strengthenedPublication.evidence.capturedThrough,
            strengthened.capturedThrough
        )
        XCTAssertEqual(
            strengthenedPublication.evidence.knownCoverageSeconds,
            strengthened.knownCoverageSeconds
        )
        XCTAssertNotEqual(
            strengthenedPublication.contentRevision,
            oldRevision
        )
    }

    func testCurrentAndPriorQualifiedReadsPublishBothBoundedWindows() throws {
        let calendar = utcCalendar
        let priorWake = Date(timeIntervalSince1970: 1_786_252_400)
        let currentWake = priorWake.addingTimeInterval(24 * 60 * 60)
        let now = currentWake.addingTimeInterval(2 * 60 * 60)
        let windows = SessionStore.currentAndPriorStepReceiptWindows(
            now: now,
            confirmedSleeps: [
                makeSleep(
                    id: "prior",
                    start: priorWake.addingTimeInterval(-8 * 60 * 60),
                    end: priorWake
                ),
                makeSleep(
                    id: "current",
                    start: currentWake.addingTimeInterval(-8 * 60 * 60),
                    end: currentWake
                ),
            ],
            calendar: calendar
        )
        let current = try XCTUnwrap(windows.first { $0.role == .current })
        let prior = try XCTUnwrap(
            windows.first { $0.role == .immediatelyPrior }
        )
        let currentEvidence = makeWindowEvidence(
            current.interval,
            ticks: 200,
            steps: 160,
            known: 6_000,
            capturedThrough: current.interval.end
        )
        let priorEvidence = makeWindowEvidence(
            prior.interval,
            ticks: 1_800,
            steps: 1_450,
            known: 52_000,
            capturedThrough: prior.interval.end
        )
        let store = AtriaWhoop4MotionTickDailyStore(directoryURL: directory)
        let strap = UUID().uuidString

        try replayCompactReceiptReads(
            windows: windows,
            reads: [
                .current: .qualified(currentEvidence),
                .immediatelyPrior: .qualified(priorEvidence),
            ],
            store: store,
            strapIdentifier: strap
        )

        XCTAssertEqual(
            store.load(
                strapIdentifier: strap,
                windowStart: current.interval.start
            ),
            currentEvidence
        )
        XCTAssertEqual(
            store.load(
                strapIdentifier: strap,
                windowStart: prior.interval.start
            ),
            priorEvidence
        )
        XCTAssertEqual(
            Set(store.recentReceipts(
                strapIdentifier: strap,
                limit: 10
            ).map(\.windowStart)),
            Set(windows.map { $0.interval.start })
        )
    }

    func testCurrentCycleReceiptCoalescerBoundsNotificationStorm() {
        var coalescer = AtriaCurrentCycleStepReceiptReadCoalescer()

        XCTAssertTrue(coalescer.admit(reason: "first", now: 0))
        for index in 0..<1_000 {
            XCTAssertFalse(coalescer.admit(
                reason: "storm_\(index)",
                now: 0.05
            ))
            XCTAssertLessThanOrEqual(coalescer.outstandingWorkUpperBound, 2)
        }

        XCTAssertTrue(coalescer.inFlight)
        XCTAssertEqual(coalescer.trailingReason, "storm_999")
        XCTAssertEqual(coalescer.outstandingWorkUpperBound, 2)
        XCTAssertEqual(
            coalescer.finish(
                now: 0.1,
                minimumStartInterval: 5
            ) ?? -1,
            4.9,
            accuracy: 0.000_001
        )
        guard case .wait(let remaining) =
                coalescer.activateCooldown(now: 4.9) else {
            return XCTFail("cooldown activated before its deadline")
        }
        XCTAssertEqual(remaining, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(
            coalescer.activateCooldown(now: 5),
            .start("storm_999")
        )
        XCTAssertTrue(coalescer.inFlight)
        XCTAssertNil(coalescer.trailingReason)
        XCTAssertEqual(coalescer.outstandingWorkUpperBound, 1)
    }

    func testCurrentCycleReceiptFailureDrainAllowsOneFreshTrailingRead() {
        var coalescer = AtriaCurrentCycleStepReceiptReadCoalescer()

        XCTAssertTrue(coalescer.admit(reason: "missing_strap", now: 10))
        XCTAssertFalse(coalescer.admit(reason: "cycle_changed", now: 10.1))
        XCTAssertFalse(coalescer.admit(
            reason: "latest_compact_checkpoint",
            now: 10.2
        ))

        // Production calls the same finish operation from a defer, including
        // missing-strap, empty-coverage, compact-miss, and save-error paths.
        XCTAssertEqual(
            coalescer.finish(
                now: 10.25,
                minimumStartInterval: 5
            ) ?? -1,
            4.75,
            accuracy: 0.000_001
        )
        let activation = coalescer.activateCooldown(now: 15)
        XCTAssertEqual(activation, .start("latest_compact_checkpoint"))
        XCTAssertEqual(coalescer.outstandingWorkUpperBound, 1)
        XCTAssertNil(coalescer.finish(
            now: 20,
            minimumStartInterval: 5
        ))
        XCTAssertEqual(coalescer.outstandingWorkUpperBound, 0)
    }

    func testCurrentCycleReceiptStormReadRateIsTimeBounded() {
        var coalescer = AtriaCurrentCycleStepReceiptReadCoalescer()
        let minimumInterval: TimeInterval = 5
        var scheduledWake: TimeInterval?
        var readStarts: [TimeInterval] = []

        for tick in 0...120 {
            let now = TimeInterval(tick) * 0.5
            if let wake = scheduledWake, wake <= now {
                if case .start = coalescer.activateCooldown(now: wake) {
                    readStarts.append(wake)
                    let finishedAt = wake + 0.05
                    scheduledWake = coalescer.finish(
                        now: finishedAt,
                        minimumStartInterval: minimumInterval
                    ).map { finishedAt + $0 }
                } else {
                    scheduledWake = nil
                }
            }

            if coalescer.admit(reason: "storm_\(tick)", now: now) {
                readStarts.append(now)
                let finishedAt = now + 0.05
                scheduledWake = coalescer.finish(
                    now: finishedAt,
                    minimumStartInterval: minimumInterval
                ).map { finishedAt + $0 }
            }
            XCTAssertLessThanOrEqual(coalescer.outstandingWorkUpperBound, 2)
        }

        XCTAssertEqual(readStarts.first, 0)
        XCTAssertLessThanOrEqual(readStarts.count, 13)
        for pair in zip(readStarts, readStarts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1 - pair.0,
                minimumInterval - 0.000_001
            )
        }
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
        // current nor immediately-prior miss can reach canonical JSONL.
        XCTAssertTrue(body.contains(
            "case .publishCompact"
        ))
        XCTAssertTrue(body.contains(
            "case .compactOnlyMissing"
        ))
        XCTAssertTrue(body.contains(".motionTickDayEvidenceRead("))
        XCTAssertTrue(body.contains(
            "Self.currentCycleStepReceiptQueue.async"
        ), "compact receipt work must not wait behind lifetime archive projections")
        XCTAssertTrue(body.contains(
            "currentCycleStepReceiptReadCoalescer.admit("
        ))
        XCTAssertTrue(body.contains(
            "defer {\n                Self.scheduleCurrentCycleStepReceiptReadFinish("
        ), "every worker exit must drain the single coalesced trailing request")
        XCTAssertTrue(body.contains(
            "currentCycleStepReceiptReadCoalescer.finish("
        ))
        XCTAssertTrue(body.contains(
            "currentCycleStepReceiptMinimumStartInterval"
        ))
        XCTAssertTrue(body.contains(
            "startCurrentCycleStrapStepReceiptRead(reason: trailingReason)"
        ))
        let queueStart = try XCTUnwrap(body.range(
            of: "Self.currentCycleStepReceiptQueue.async"
        )?.lowerBound)
        let workerClock = try XCTUnwrap(body.range(
            of: "let now = Date()"
        )?.lowerBound)
        let workerCycle = try XCTUnwrap(body.range(
            of: "let receiptWindows = Self.currentAndPriorStepReceiptWindows("
        )?.lowerBound)
        let workerCoverage = try XCTUnwrap(body.range(
            of: "let coverage = AtriaWhoop4MotionBankCoverageLedger.intervals("
        )?.lowerBound)
        XCTAssertLessThan(queueStart, workerClock)
        XCTAssertLessThan(queueStart, workerCycle)
        XCTAssertLessThan(queueStart, workerCoverage)
        XCTAssertTrue(body.contains("for window in receiptWindows"))
        XCTAssertTrue(body.contains("if coverage.isEmpty"))
        XCTAssertTrue(body.contains("if window.role == .current"))
        XCTAssertTrue(body.contains("continue"),
                      "a missing current window must not suppress prior replay")
        XCTAssertTrue(sessions.contains(
            "role: .immediatelyPrior"
        ))
        XCTAssertFalse(body.contains(
            "completedPriorCivilDayWindows("
        ), "the hot worker is physiological-cycle bounded, never civil-day backfill")
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

    private func makeWindowEvidence(
        _ interval: DateInterval,
        ticks: Int,
        steps: Int,
        known: Int,
        capturedThrough: Date
    ) -> HistoricalArchive.MotionTickDayEvidence {
        let duration = max(0, Int(interval.duration.rounded(.down)))
        return .init(
            windowStart: interval.start,
            windowEnd: interval.end,
            motionTicks: ticks,
            steps: steps,
            knownCoverageSeconds: known,
            missingCoverageSeconds: max(0, duration - known),
            decodedRows: max(2, known / 5),
            capturedThrough: capturedThrough
        )
    }

    private func makeSleep(
        id: String,
        start: Date,
        end: Date,
        eventTimeZoneIdentifier: String = "UTC"
    ) -> UserConfirmedSleep {
        UserConfirmedSleep(
            id: id,
            createdAt: end,
            start: start,
            end: end,
            source: "manual_sleep",
            confidence: "user",
            sessions: 1,
            samples: 100,
            avgHR: 52,
            peakHR: 60,
            restingHR: 48,
            hrv: 60,
            hrvWindowCount: 4,
            duration: end.timeIntervalSince(start),
            span: end.timeIntervalSince(start),
            reason: "test",
            motionSource: "test",
            motionValidated: true,
            stageSegments: nil,
            eventTimeZoneIdentifier: eventTimeZoneIdentifier
        )
    }

    private func replayCompactReceiptReads(
        windows: [AtriaCurrentCycleStepReceiptWindow],
        reads: [
            AtriaCurrentCycleStepReceiptWindow.Role:
                HistoricalArchive.MotionTickDayEvidenceRead
        ],
        store: AtriaWhoop4MotionTickDailyStore,
        strapIdentifier: String
    ) throws {
        XCTAssertLessThanOrEqual(windows.count, 2)
        for window in windows {
            let read = reads[window.role] ?? .incomplete
            let qualified: Bool
            if case .qualified = read {
                qualified = true
            } else {
                qualified = false
            }
            switch SessionStore.currentCycleStepReceiptReadPlan(
                compactReadQualified: qualified
            ) {
            case .publishCompact:
                guard case .qualified(let evidence) = read else {
                    return XCTFail("publish plan requires qualified evidence")
                }
                _ = try store.save(
                    evidence,
                    strapIdentifier: strapIdentifier
                )
            case .compactOnlyMissing:
                continue
            }
        }
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
