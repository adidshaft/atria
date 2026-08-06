import XCTest
import SwiftUI
@testable import Atria

/// Renders the About sheet WITH a last-30-days mini-trend (P1) to a PNG for
/// visual review — the real install is too young (under 5 readings) for the
/// card to appear on-device, so this is the proof the card composes: gap-broken
/// line, per-reading dots, honest count+range caption. Not an assertion test
/// beyond "a non-trivial image rendered".
final class AtriaAboutMetricSheetSnapshotTests: XCTestCase {
    @MainActor
    func testRenderAboutSheetWithTrendForVisualReview() throws {
        let calendar = Calendar.current
        let reference = Date(timeIntervalSince1970: 1_785_000_000)
        // 14 nights of HRV around 60 ms with a 4-night wear gap in the middle,
        // so the render proves the line breaks at the gap instead of bridging it.
        let offsets = [0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15, 16, 17]
        let values: [Double] = [64, 58, 61, 66, 70, 63, 55, 57, 60, 68, 72, 65, 59, 62]
        let rollups = zip(offsets, values).map { offset, value in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -offset,
                                                     to: reference)!,
                                  lnRMSSD: log(value),
                                  calendar: calendar)
        }
        let trend = try XCTUnwrap(AtriaAboutMetricTrend.make(for: .hrv,
                                                             rollups: rollups,
                                                             referenceDate: reference,
                                                             calendar: calendar))

        let content = AtriaAboutMetricSheet(metric: .hrv, trend: trend).sheetContent
            .frame(width: 393)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            XCTFail("ImageRenderer produced no image")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "about_sheet_hrv_trend.png"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Simulator tests can write host paths; TEST_RUNNER_ATRIA_SNAPSHOT_DIR
        // makes the PNG reviewable without digging through the xcresult bundle.
        if let dir = ProcessInfo.processInfo.environment["ATRIA_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("about_sheet_hrv_trend.png")
            try data.write(to: url)
        }
        XCTAssertGreaterThan(data.count, 1000, "expected a non-trivial PNG")
    }
}
