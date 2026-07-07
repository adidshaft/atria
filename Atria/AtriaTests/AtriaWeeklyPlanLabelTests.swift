import XCTest
@testable import Atria

/// The "This week" label shows a plain date range (2026-07-08 UX audit)
/// instead of the ISO week number "W28".
final class AtriaWeeklyPlanLabelTests: XCTestCase {
    func testWeekLabelIsAPlainDateRangeNotAnISOWeekNumber() {
        let plan = WeeklyPlan(rollups: [], now: Date(timeIntervalSince1970: 1_783_600_000))
        let text = plan.dateRangeText
        XCTAssertFalse(text.isEmpty, "should produce a label")
        XCTAssertFalse(text.contains("W"), "no month abbreviation contains W, so this catches an ISO 'W28': \(text)")
        XCTAssertTrue(text.contains("–"), "should be a start–end range: \(text)")
        // Leads with a month abbreviation (plain language), not a digit.
        XCTAssertTrue(text.first?.isLetter == true, "should start with a month name: \(text)")
    }
}
