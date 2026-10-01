import XCTest
import SwiftUI
@testable import Atria

/// Renders the 7-day steps bar chart to a PNG (kept as an XCTAttachment) for
/// visual review, and proves it composes with a fixed weekday axis + a gap day.
final class AtriaStepsWeekChartSnapshotTests: XCTestCase {
    @MainActor
    func testRenderStepsWeekForVisualReview() throws {
        // Seven wake-to-wake cycles; one has no reading (no bar) to show the
        // honest gap, and the newest is the open cycle.
        let wake = Date(timeIntervalSince1970: 1_785_000_000)
        let steps: [Int?] = [5120, 12680, 9310, nil, 6740, 11020, 4158]
        let bars = steps.enumerated().map { index, value in
            AtriaStepsWeekChart.CycleBar(
                start: wake.addingTimeInterval(Double(index - 6) * 86_400),
                steps: value,
                isPartial: index == 6,
                isCurrent: index == 6
            )
        }

        let content = AtriaStepsWeekChart(bars: bars, goal: 10000)
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
