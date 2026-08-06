import XCTest
import SwiftUI
@testable import Atria

/// Daily stress trend (§3.3, 2026-08-04): contracts for the archive projection
/// and a render proof for the card, since no fixture reaches the stress detail.
final class AtriaStressDailyTrendTests: XCTestCase {
    private let calendar = Calendar.current
    private let reference = Date(timeIntervalSince1970: 1_785_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset,
                      to: calendar.startOfDay(for: reference))!
    }

    /// An archive day with `samples` readings split across the bands.
    private func archiveDay(daysAgo: Int, calm: Int, medium: Int = 0, high: Int = 0)
        -> AtriaStressDistributionArchive.Day {
        AtriaStressDistributionArchive.Day(
            day: day(daysAgo),
            distribution: AtriaStressDistribution(calmSamples: calm,
                                                  mediumSamples: medium,
                                                  highSamples: high),
            lastSampleAt: day(daysAgo).addingTimeInterval(12 * 3_600))
    }

    func testMeasuredTrendDaysAppliesTheSameFloorAsTypicalComparison() {
        var archive = AtriaStressDistributionArchive()
        // 12 samples on one day (measured), 4 on another (below the floor).
        for i in 0..<12 {
            archive.record(level: .calm, at: day(1).addingTimeInterval(Double(i) * 60),
                           calendar: calendar)
        }
        for i in 0..<4 {
            archive.record(level: .high, at: day(2).addingTimeInterval(Double(i) * 60),
                           calendar: calendar)
        }
        let measured = archive.measuredTrendDays()
        XCTAssertEqual(measured.count, 1)
        XCTAssertEqual(measured.first.map { calendar.startOfDay(for: $0.day) }, day(1))
    }

    @MainActor
    func testRenderDailyTrendCardForVisualReview() throws {
        // 9 measured days over a 14-day frame with a wear gap, exercising all
        // three bands and blank (unmeasured) days.
        let days = [13, 12, 10, 9, 8, 4, 3, 1, 0].enumerated().map { index, offset in
            archiveDay(daysAgo: offset,
                       calm: 40 + index * 5,
                       medium: (index % 3) * 8,
                       high: index % 2 == 0 ? 3 : 0)
        }
        let content = AtriaStressDailyTrendCard(days: days,
                                                referenceDate: reference,
                                                calendar: calendar)
            .frame(width: 361)
            .padding(16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let data = try XCTUnwrap(renderer.uiImage?.pngData())
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "stress_daily_trend.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ATRIA_SNAPSHOT_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("stress_daily_trend.png"))
        }
        XCTAssertGreaterThan(data.count, 1000)
    }

    @MainActor
    func testUnderThreeMeasuredDaysRendersBuildingStateNotAPlot() throws {
        let days = [archiveDay(daysAgo: 0, calm: 20), archiveDay(daysAgo: 1, calm: 30)]
        let card = AtriaStressDailyTrendCard(days: days,
                                             referenceDate: reference,
                                             calendar: calendar)
            .frame(width: 361)
        // Renders (no crash) and stays compact — the building state is a text
        // line, far shorter than the 120pt chart it replaces.
        let renderer = ImageRenderer(content: card)
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertLessThan(image.size.height, 120)
    }
}
