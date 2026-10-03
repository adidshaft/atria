import XCTest
@testable import Atria

/// No-data bands on intraday charts (visual pass 2026-09-24): gaps become
/// labeled bands, reasons need evidence, indeterminate never reads confident.
final class AtriaChartNoDataBandsTests: XCTestCase {
    typealias B = AtriaChartNoDataBands
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func minutes(_ range: Range<Int>) -> [Date] {
        range.map { t0.addingTimeInterval(Double($0) * 60) }
    }

    private var domain: ClosedRange<Date> { t0...t0.addingTimeInterval(240 * 60) }

    func testInteriorLeadingAndTrailingGapsBecomeNoDataBands() {
        let dates = minutes(30..<100) + minutes(160..<200)
        let bands = B.bands(sampleDates: dates, domain: domain, now: .distantFuture)
        XCTAssertEqual(bands.count, 3)
        XCTAssertEqual(bands.map(\.reason), [.noData, .noData, .noData])
        XCTAssertEqual(bands[0].start, t0)
        XCTAssertEqual(bands[1].start, t0.addingTimeInterval(99 * 60))
        XCTAssertEqual(bands[1].end, t0.addingTimeInterval(160 * 60))
        XCTAssertEqual(bands[2].end, domain.upperBound)
    }

    func testShortHiccupsAndBucketCadenceAreNotGaps() {
        // Five-minute buckets with one missing bucket: spacing, not a gap.
        let buckets = stride(from: 0, to: 240, by: 5).filter { $0 != 100 }
            .map { t0.addingTimeInterval(Double($0) * 60) }
        XCTAssertTrue(B.bands(sampleDates: buckets, domain: domain, now: .distantFuture).isEmpty)
    }

    func testNoSamplesMeansNoBandsTheEmptyStateSpeaksInstead() {
        XCTAssertTrue(B.bands(sampleDates: [], domain: domain).isEmpty)
    }

    func testBandsNeverExtendIntoTheFuture() {
        let now = t0.addingTimeInterval(120 * 60)
        let bands = B.bands(sampleDates: minutes(0..<60), domain: domain, now: now)
        XCTAssertEqual(bands.last?.end, now)
    }

    func testProvenOffWristCoverageNamesNotWorn() {
        let dates = minutes(0..<60) + minutes(120..<240)
        let evidence = AtriaChartGapEvidence(
            offWristSpans: [DateInterval(start: t0.addingTimeInterval(58 * 60),
                                         end: t0.addingTimeInterval(121 * 60))])
        let bands = B.bands(sampleDates: dates, domain: domain, now: .distantFuture, evidence: evidence)
        XCTAssertEqual(bands.map(\.reason), [.notWorn])
    }

    func testPartialEvidenceFailsClosedToNoData() {
        let dates = minutes(0..<60) + minutes(120..<240)
        // Covers only half of the 61-minute gap.
        let evidence = AtriaChartGapEvidence(
            offWristSpans: [DateInterval(start: t0.addingTimeInterval(59 * 60),
                                         end: t0.addingTimeInterval(90 * 60))])
        let bands = B.bands(sampleDates: dates, domain: domain, now: .distantFuture, evidence: evidence)
        XCTAssertEqual(bands.map(\.reason), [.noData])
    }

    func testIndeterminateAndUnrecoverableVerdictsNeverCarryAConfidentReason() {
        XCTAssertNil(AtriaChartGapReason.confident(from: .indeterminate))
        XCTAssertNil(AtriaChartGapReason.confident(from: .unrecoverable(reason: "terminal_stall")))
        XCTAssertNil(AtriaChartGapReason.confident(from: .wornUndrained(recoverable: false)))
        XCTAssertEqual(AtriaChartGapReason.confident(from: .offWrist), .notWorn)
        XCTAssertEqual(AtriaChartGapReason.confident(from: .charging), .charging)
        XCTAssertEqual(AtriaChartGapReason.confident(from: .wornUndrained(recoverable: true)), .syncing)
        // An indeterminate ledger verdict on real render-path evidence stays "No data".
        let verdict = AtriaGapWearClassification.classify(.init(windowStart: t0,
                                                                windowEnd: t0.addingTimeInterval(3_600)))
        XCTAssertEqual(verdict, .indeterminate)
        XCTAssertNil(AtriaChartGapReason.confident(from: verdict))
    }

    func testChargingOutranksNotWornWhenBothCover() {
        let gap = DateInterval(start: t0, duration: 3_600)
        let evidence = AtriaChartGapEvidence(
            offWristSpans: [gap],
            classifiedWindows: [.init(interval: gap, reason: .charging)])
        XCTAssertEqual(B.reason(for: gap, evidence: evidence), .charging)
    }

    func testLabelsOnlyOnBandsWideEnoughToHoldThem() {
        let wide = AtriaChartGapBand(start: t0, end: t0.addingTimeInterval(60 * 60), reason: .noData)
        let narrow = AtriaChartGapBand(start: t0, end: t0.addingTimeInterval(20 * 60), reason: .noData)
        XCTAssertTrue(B.showsLabel(wide, domain: domain))
        XCTAssertFalse(B.showsLabel(narrow, domain: domain))
        // 2026-10-03: one label per reason, on the widest band.
        let secondWide = AtriaChartGapBand(start: wide.end.addingTimeInterval(3_600),
                                           end: wide.end.addingTimeInterval(3_600 + wide.duration * 0.9),
                                           reason: wide.reason)
        XCTAssertTrue(B.showsLabel(secondWide, domain: domain), "both qualify on their own")
        XCTAssertEqual(B.labelledBandIDs([secondWide, wide, narrow], domain: domain), [wide.id])
    }

    func testReasonCopyIsShortAndPlain() {
        XCTAssertEqual(AtriaChartGapReason.allCases.map(\.label),
                       ["Not worn", "Charging", "Syncing…", "No data"])
    }
}
