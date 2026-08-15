import XCTest
@testable import Atria

/// ITEM-2/ITEM-3 2026-08-15: the sleep detail sheet explains the need it
/// shows (frozen receipt itemization + a tonight projection that moves) and
/// its stage empty-states say what will unlock a hypnogram.
final class AtriaSleepDetailLegibilityTests: XCTestCase {
    func testComponentsSummaryTextItemizesTheReceipt() {
        let components = AtriaSleepBudget.sleepNeedComponents(baseHours: 8.0,
                                                              yesterdayStrain: 15.0,
                                                              debtHours: 2.0,
                                                              sameDayNapHours: 0.5)
        let text = AtriaSleepNeedLedgerPresentation.componentsSummaryText(for: components)
        XCTAssertTrue(text.hasPrefix("8 h base"), "base always leads, got: \(text)")
        XCTAssertTrue(text.contains("strain"), "a real strain adder is named")
        XCTAssertTrue(text.contains("debt"), "a real debt adder is named")
        XCTAssertTrue(text.contains("naps"), "a real nap credit is named")

        let quiet = AtriaSleepBudget.sleepNeedComponents(baseHours: 8.0,
                                                         yesterdayStrain: nil,
                                                         debtHours: 0,
                                                         sameDayNapHours: 0)
        let quietText = AtriaSleepNeedLedgerPresentation.componentsSummaryText(for: quiet)
        XCTAssertEqual(quietText, "8 h base",
                       "zero adders drop out instead of printing +0m noise")
    }

    func testTonightProjectionMovesWithTodayTRIMPAndClampDisclosed() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let snapshot = SleepHistorySnapshot(rollups: [], confirmedSleeps: [], calendar: utc)

        let restDay = snapshot.tonightProjectedNeedComponents(baseNeedHours: 8.0,
                                                              todayTRIMP: nil,
                                                              todayStrainFallback: nil)
        let hardDay = snapshot.tonightProjectedNeedComponents(baseNeedHours: 8.0,
                                                              todayTRIMP: 187.9,
                                                              todayStrainFallback: nil)
        XCTAssertGreaterThan(hardDay.totalHours, restDay.totalHours,
                             "today's accruing TRIMP must raise tonight's projection")
        XCTAssertEqual(hardDay.strainAdderHours, 0.62 * (15.0 - 8.0) / 7.0, accuracy: 0.02,
                       "TRIMP flows through the display authority, no new coefficients")
    }

    func testUnavailableStagesDetailNamesTheUnlockPerTransport() {
        let base = "Your sleep duration is saved."
        let catchingUp = AtriaSleepHypnogramCard.unavailableStagesDetail(
            base: base, motionAvailability: .catchingUp)
        XCTAssertTrue(catchingUp.contains("catching up now"),
                      "an active motion sync names itself, got: \(catchingUp)")

        let hrOnly = AtriaSleepHypnogramCard.unavailableStagesDetail(
            base: base, motionAvailability: .unavailableInCurrentTransport)
        XCTAssertTrue(hrOnly.contains("heart-rate-only"),
                      "an HR-only link never promises motion, got: \(hrOnly)")
        XCTAssertTrue(hrOnly.contains("labeled HR-only estimate"),
                      "the honest alternative is named, got: \(hrOnly)")

        let generic = AtriaSleepHypnogramCard.unavailableStagesDetail(
            base: base, motionAvailability: nil)
        XCTAssertTrue(generic.hasPrefix(base))
        XCTAssertTrue(generic.contains("Stages validate after the strap syncs motion"))
    }
}
