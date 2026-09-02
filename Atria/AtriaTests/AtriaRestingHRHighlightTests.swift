import XCTest
@testable import Atria

/// Phone 2026-09-02: the Today highlight read "Resting HR lower than usual"
/// and said neither the reading nor how far. The row now carries both,
/// rounded to whole beats against the prior week's average.
final class AtriaRestingHRHighlightTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_787_832_000)

    private func rollups(latest: Int, prior: [Int]) -> [DailyRollupStoreEntry] {
        ([latest] + prior).enumerated().map { offset, rhr in
            var entry = DailyRollupStoreEntry(day: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!),
                                              tzOffsetMinutes: 0,
                                              bedtimeMinutes: nil)
            entry.rhr = rhr
            return entry
        }
    }

    func testRowCarriesTheReadingAndTheDistanceBelowUsual() throws {
        let highlight = try XCTUnwrap(AtriaHighlights.topTwo(rollups: rollups(latest: 52, prior: [56, 57, 56]))
            .first { $0.id == "lower-rhr" })
        XCTAssertEqual(highlight.valuePhrase, "Resting HR 52")
        XCTAssertEqual(highlight.sentence, "4 bpm below usual")
    }

    func testWithinTwoBeatsIsNotAHighlight() {
        XCTAssertNil(AtriaHighlights.topTwo(rollups: rollups(latest: 55, prior: [56, 57, 56]))
            .first { $0.id == "lower-rhr" })
    }
}
