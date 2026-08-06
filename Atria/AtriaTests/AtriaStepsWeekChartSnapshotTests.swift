import XCTest
import SwiftUI
@testable import Atria

/// Renders the 7-day steps bar chart to a PNG (kept as an XCTAttachment) for
/// visual review, and proves it composes with a fixed weekday axis + a gap day.
final class AtriaStepsWeekChartSnapshotTests: XCTestCase {
    @MainActor
    func testRenderStepsWeekForVisualReview() throws {
        // Use Calendar.current so the day-start keys match the chart's own
        // Calendar.current bucketing (a fixed UTC calendar would land keys on a
        // different day and render the empty state).
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_785_000_000))
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: -offset, to: end)!
        }
        // Six of seven days have a verified total; one mid-week day is missing
        // (no bar) to show the honest gap.
        let stepsByDay: [Date: Int] = [
            day(0): 8432, day(1): 11020, day(2): 6740,
            day(4): 9310, day(5): 12680, day(6): 5120,
        ]

        let content = AtriaStepsWeekChart(stepsByDay: stepsByDay,
                                          goal: 10000,
                                          referenceDate: end)
            .frame(width: 360, height: 210)
            .padding(16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "steps_week_chart.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(data.count, 1000, "expected a non-trivial PNG")
    }
}
