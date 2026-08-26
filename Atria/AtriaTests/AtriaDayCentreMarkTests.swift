import XCTest
@testable import Atria

/// `AxisValueLabel(centered:)` centres a label within the step to the NEXT axis
/// mark, not within the bar's `unit`. The two coincide only at a one-day
/// stride. Charts that pick marks with `.automatic(desiredCount:)` therefore
/// cannot use it: the stride follows the window width, so the label drifts
/// further from its bar the more days you show.
///
/// `dayCentreMarks` sidesteps the whole question by putting the mark where the
/// bar's middle already is, which is correct at every stride.
final class AtriaDayCentreMarkTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day,
                      value: offset,
                      to: calendar.startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000)))!
    }

    private func domain(days: Int) -> ClosedRange<Date> {
        day(0)...day(days)
    }

    func testEveryMarkSitsAtTheCentreOfItsOwnDay() {
        let marks = AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: 7),
                                                           targetCount: 4,
                                                           calendar: calendar)
        for mark in marks {
            let components = calendar.dateComponents([.hour, .minute], from: mark)
            XCTAssertEqual(components.hour, 12, "a day-unit bar is centred at noon")
            XCTAssertEqual(components.minute, 0)
        }
    }

    func testAWiderWindowDoesNotMoveALabelOffItsBar() {
        // The defect this replaces: at desiredCount 4 over 30 days the
        // automatic stride is about a week, and `centered: true` pushed each
        // label ~3.5 days right — onto a different bar entirely. Here the
        // offset from the day it names is 12h no matter how wide the window is.
        for span in [7, 14, 30, 90] {
            let marks = AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: span),
                                                               targetCount: 4,
                                                               calendar: calendar)
            XCTAssertFalse(marks.isEmpty, "\(span)-day window produced no marks")
            for mark in marks {
                let owningDay = calendar.startOfDay(for: mark)
                XCTAssertEqual(mark.timeIntervalSince(owningDay), 12 * 3_600, accuracy: 1,
                               "\(span)-day window: mark drifted off its day's centre")
            }
        }
    }

    func testMarkCountStaysNearTheRequestedDensity() {
        // Density is why `.automatic` was used in the first place — 90 daily
        // labels would be unreadable. Sampling must keep roughly the requested
        // number, never one per day.
        let marks = AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: 90),
                                                           targetCount: 6,
                                                           calendar: calendar)
        XCTAssertLessThanOrEqual(marks.count, 6)
        XCTAssertGreaterThanOrEqual(marks.count, 4)
    }

    func testTheFirstDayIsAlwaysMarked() {
        let marks = AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: 30),
                                                           targetCount: 4,
                                                           calendar: calendar)
        XCTAssertEqual(marks.first, calendar.date(byAdding: .hour, value: 12, to: day(0)))
    }

    func testMarksAreOrderedAndDistinct() {
        let marks = AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: 30),
                                                           targetCount: 4,
                                                           calendar: calendar)
        XCTAssertEqual(marks, marks.sorted())
        XCTAssertEqual(Set(marks).count, marks.count)
    }

    func testASingleDayWindowStillProducesOneCentredMark() {
        let marks = AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: 1),
                                                           targetCount: 4,
                                                           calendar: calendar)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first, calendar.date(byAdding: .hour, value: 12, to: day(0)))
    }

    func testDegenerateInputsReturnNothingRatherThanCrashing() {
        let instant = day(3)...day(3)
        XCTAssertTrue(AtriaChartVisualGrammar.dayCentreMarks(in: instant,
                                                             targetCount: 4,
                                                             calendar: calendar).isEmpty)
        XCTAssertTrue(AtriaChartVisualGrammar.dayCentreMarks(in: domain(days: 7),
                                                             targetCount: 0,
                                                             calendar: calendar).isEmpty)
    }

    func testEveryMarkLiesInsideTheDomain() {
        let range = domain(days: 14)
        let marks = AtriaChartVisualGrammar.dayCentreMarks(in: range,
                                                           targetCount: 4,
                                                           calendar: calendar)
        for mark in marks {
            XCTAssertTrue(range.contains(mark), "a mark outside the domain is not drawn")
        }
    }
}
