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
}
