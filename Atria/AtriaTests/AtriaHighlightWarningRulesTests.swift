import XCTest
@testable import Atria

/// 2026-09-02: the Today highlights had two rules and both praised. A
/// resting HR above usual is the warning wearers most want to see, and an
/// HRV above usual is the other real signal the rollups carry. Same gates
/// as the existing rule: three prior mornings, whole-unit deltas.
final class AtriaHighlightWarningRulesTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_787_832_000)

    private func rollups(rhr: [Int?] = [], lnRMSSD: [Double?] = []) -> [DailyRollupStoreEntry] {
        let count = max(rhr.count, lnRMSSD.count)
        return (0..<count).map { offset in
            var entry = DailyRollupStoreEntry(day: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!),
                                              tzOffsetMinutes: 0,
                                              bedtimeMinutes: nil)
            if offset < rhr.count { entry.rhr = rhr[offset] }
            if offset < lnRMSSD.count { entry.lnRMSSD = lnRMSSD[offset] }
            return entry
        }
    }

    func testRestingHRAboveUsualWarnsInAmber() throws {
        let highlight = try XCTUnwrap(AtriaHighlights.topTwo(rollups: rollups(rhr: [60, 56, 57, 55]))
            .first { $0.id == "higher-rhr" })
        XCTAssertEqual(highlight.valuePhrase, "Resting HR 60")
        XCTAssertEqual(highlight.sentence, "4 bpm above usual")
        XCTAssertEqual(highlight.metric, .restingHeartRate)
        XCTAssertNil(AtriaHighlights.topTwo(rollups: rollups(rhr: [57, 56, 57, 55])).first { $0.id == "higher-rhr" },
                     "within two beats is not a warning")
    }

    func testHRVAboveUsualByATenthIsAHighlight() throws {
        let prior = [60.0, 60.0, 60.0].map { log($0) }
        let highlight = try XCTUnwrap(AtriaHighlights.topTwo(rollups: rollups(lnRMSSD: [log(66.0)] + prior))
            .first { $0.id == "higher-hrv" })
        XCTAssertEqual(highlight.valuePhrase, "HRV 66 ms")
        XCTAssertEqual(highlight.sentence, "6 ms above usual")
        XCTAssertNil(AtriaHighlights.topTwo(rollups: rollups(lnRMSSD: [log(64.0)] + prior)).first { $0.id == "higher-hrv" },
                     "under a tenth above is noise")
    }

    func testLowerAndHigherRestingHRNeverBothFire() {
        let ids = AtriaHighlights.topTwo(rollups: rollups(rhr: [52, 56, 57, 56])).map(\.id)
        XCTAssertTrue(ids.contains("lower-rhr"))
        XCTAssertFalse(ids.contains("higher-rhr"))
    }
}
