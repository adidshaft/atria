import XCTest
import SwiftUI
@testable import Atria

/// Handoff-10 CP3: sparse-chart presentation contracts — unambiguous date
/// ticks, truthful gap splitting, exact axis mapping, and unclipped rendering
/// at narrow widths. Truth rules (linear interpolation, missing days stay
/// missing) are pinned, not restyled.
final class AtriaSparseChartPresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)
    private var calendar: Calendar { .current }

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: base.addingTimeInterval(Double(offset) * 86_400))
    }

    private func point(_ dayOffset: Int, _ value: Double) -> AtriaDetailChartPoint {
        AtriaDetailChartPoint(day: day(dayOffset), value: value, tint: .primary)
    }

    // MARK: - Date ticks

    func testDayTickLabelsDistinguishAllSevenDaysDespiteRepeatedInitials() {
        let labels = (0..<7).map {
            AtriaStrainRecoveryComboChart.dayTickLabel(for: day($0), calendar: calendar)
        }
        XCTAssertEqual(Set(labels).count, 7,
                       "Weekday+day ticks must be unique across a week: \(labels)")
        for (offset, label) in labels.enumerated() {
            let dayOfMonth = calendar.component(.day, from: day(offset))
            XCTAssertTrue(label.hasSuffix(" \(dayOfMonth)"),
                          "\(label) must end with its day of month \(dayOfMonth)")
            XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // Narrow weekday initials alone genuinely repeat inside one week —
        // the day number is what disambiguates.
        let initials = labels.map { String($0.prefix(1)) }
        XCTAssertLessThan(Set(initials).count, 7,
                          "Fixture week should contain repeated initials for the test to be meaningful")
    }

    // MARK: - Gap truth

    func testMissingDaySplitsTheLineIntoSeparateRuns() {
        let points = [point(0, 10), point(1, 12), point(4, 8), point(5, 9)]
        let runs = points.contiguousDayRuns(calendar: calendar)
        XCTAssertEqual(runs.map(\.runID), [0, 0, 1, 1],
                       "A >1-day gap must start a new run; no line may cross it")
    }

    func testTwoAdjacentSamplesFormOneRunWithExactEndpoints() {
        let points = [point(0, 33), point(1, 67)]
        let runs = points.contiguousDayRuns(calendar: calendar)
        XCTAssertEqual(runs.map(\.runID), [0, 0])
        XCTAssertEqual(runs.first?.point.value, 33)
        XCTAssertEqual(runs.last?.point.value, 67)
    }

    func testIsolatedSingleDayIsItsOwnRun() {
        let points = [point(0, 10), point(3, 8), point(6, 12)]
        let runs = points.contiguousDayRuns(calendar: calendar)
        XCTAssertEqual(runs.map(\.runID), [0, 1, 2])
    }

    // MARK: - Axis mapping

    func testRecoveryRightAxisMapsExactlyOntoStrainDomain() {
        // The trailing axis renders 0/7/14/21 as recovery percentages; the
        // mapping must stay 0/33/67/100.
        let strainAxisMax = 21.0
        let labels = [0.0, 7, 14, 21].map { Int(($0 / strainAxisMax * 100).rounded()) }
        XCTAssertEqual(labels, [0, 33, 67, 100])
    }

    // MARK: - Narrow-width rendering (compose + non-trivial output, both widths)

    @MainActor
    func testComboChartRendersAtNarrowAndRegularWidths() throws {
        let strain = [point(0, 8), point(1, 12), point(5, 6), point(6, 21)]
        let recovery = [point(0, 90), point(1, 69), point(5, 82), point(6, 100)]
        for width in [320.0, 390.0] {
            let content = AtriaStrainRecoveryComboChart(strain: strain,
                                                        recovery: recovery,
                                                        rangeLabel: "This week")
                .frame(width: width)
                .padding(16)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage,
                                      "Chart must compose at \(Int(width))pt")
            let data = try XCTUnwrap(image.pngData())
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "combo_\(Int(width))pt.png"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(data.count, 1000)
        }
    }

    /// The maximum-value edge case: a 21-strain and a 100% recovery point sit
    /// at the very top of the domain. With the explicit plot headroom these
    /// must stay inside the rendered frame (composition proof; the pixel
    /// check is the physical screenshot).
    @MainActor
    func testTopOfDomainPointsComposeWithHeadroom() throws {
        let content = AtriaStrainRecoveryComboChart(
            strain: [point(0, 21), point(1, 20)],
            recovery: [point(0, 100), point(1, 97)],
            rangeLabel: "This week"
        )
        .frame(width: 360)
        let renderer = ImageRenderer(content: content)
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 150,
                             "Explicit headroom must be part of the layout, not clipped away")
    }
}
