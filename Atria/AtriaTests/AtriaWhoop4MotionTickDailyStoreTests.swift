import XCTest
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
        XCTAssertEqual(presentation.valueText, "≥268")
        XCTAssertEqual(presentation.completeness, .partial)
        XCTAssertEqual(presentation.source, .verifiedCanonical)
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
            calendar: utcCalendar
        )

        XCTAssertEqual(merged, [exact])
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
