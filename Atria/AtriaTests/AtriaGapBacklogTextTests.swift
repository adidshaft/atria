import XCTest
@testable import Atria

/// The gap backlog must be a number on screen, computed the way the ledger
/// itself means it.
final class AtriaGapBacklogTextTests: XCTestCase {

    private func window(hoursSpan: Double,
                        missingSeconds: Int? = nil) -> AtriaHistoricalGapLedger.Window {
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        var bits: Data?
        if let missingSeconds {
            // A mask with exactly `missingSeconds` set bits.
            var data = Data(count: (missingSeconds + 7) / 8)
            for i in 0..<missingSeconds { data[i / 8] |= 1 << (i % 8) }
            bits = data
        }
        return .init(start: start,
                     end: start.addingTimeInterval(hoursSpan * 3_600),
                     reason: "test",
                     expectedSecondBits: bits)
    }

    func testACoalescedEnvelopeCountsItsMaskNotItsSpan() {
        // The device case: a 61.6 h envelope whose mask held 15.52 h. Counting
        // the span would claim four times the truth.
        let seconds = AtriaHomeRecoverySyncPresentation.unresolvedGapSeconds(
            windows: [window(hoursSpan: 61.6, missingSeconds: 55_886)],
            now: Date(timeIntervalSince1970: 1_757_000_000))
        XCTAssertEqual(seconds, 55_886, accuracy: 0.5)
    }

    func testAnOrdinaryWindowIsMissingEndToEnd() {
        let seconds = AtriaHomeRecoverySyncPresentation.unresolvedGapSeconds(
            windows: [window(hoursSpan: 0.5)],
            now: Date(timeIntervalSince1970: 1_757_000_000))
        XCTAssertEqual(seconds, 1_800, accuracy: 0.5)
    }

    func testAnOpenEndedWindowRunsToNow() {
        var open = window(hoursSpan: 1)
        open.end = nil
        let now = open.start.addingTimeInterval(120)
        XCTAssertEqual(AtriaHomeRecoverySyncPresentation.unresolvedGapSeconds(
            windows: [open], now: now), 120, accuracy: 0.5)
    }

    func testFormattingIsHonestAtEveryScale() {
        typealias P = AtriaHomeRecoverySyncPresentation
        XCTAssertNil(P.gapBacklogText(seconds: 30),
                     "under a minute is not worth a claim")
        XCTAssertEqual(P.gapBacklogText(seconds: 720), "12m of gaps")
        XCTAssertEqual(P.gapBacklogText(seconds: 55_886), "15.5h of gaps")
    }
}
