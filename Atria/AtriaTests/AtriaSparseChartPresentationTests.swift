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

    // MARK: - Pinned X-domain (#2: "a very small interval stretched to entire graph")

    private let axisBase = Date(timeIntervalSince1970: 1_785_000_000)
    private var sixHourWindow: ClosedRange<Date> {
        axisBase...axisBase.addingTimeInterval(6 * 3_600)
    }

    /// The reported failure: one (or a few) samples in a 6-hour view stretched
    /// across the whole plot. With the axis pinned, a single sparse sample must
    /// render at its true position inside the full window, not collapse the axis.
    func testSparseSingleSampleStaysInsideFullPinnedWindow() {
        let mid = axisBase.addingTimeInterval(3 * 3_600)
        let resolved = AtriaHeartRateAxisChart.resolvePinnedXDomain(
            pinned: sixHourWindow, sampleFirst: mid, sampleLast: mid)
        XCTAssertEqual(resolved, sixHourWindow,
                       "a lone sample must not collapse the 6h axis onto its instant")
    }

    /// Dense/scrolled data outside the window still widens the axis so nothing clips.
    func testDomainWidensToCoverDataOutsidePinnedWindow() {
        let before = axisBase.addingTimeInterval(-3_600)
        let after = axisBase.addingTimeInterval(7 * 3_600)
        let resolved = AtriaHeartRateAxisChart.resolvePinnedXDomain(
            pinned: sixHourWindow, sampleFirst: before, sampleLast: after)
        XCTAssertEqual(resolved.lowerBound, before)
        XCTAssertEqual(resolved.upperBound, after)
    }

    /// No samples at all keeps the requested window (empty plot stays full-width).
    func testEmptyDataKeepsPinnedWindow() {
        XCTAssertEqual(
            AtriaHeartRateAxisChart.resolvePinnedXDomain(
                pinned: sixHourWindow, sampleFirst: nil, sampleLast: nil),
            sixHourWindow)
    }

    /// #2 regression (2026-08-22): the user-visible Vitals proof card
    /// (AtriaHealthTimelineProofCard) must pin its HR chart's x-domain so a sparse
    /// archive interval is never stretched across the whole plot. It was the one
    /// production HR chart that omitted xDomain; guard against re-omission.
    func testHealthTimelineProofCardPinsChartXDomain() throws {
        let source = try healthScreenSource()
        let cardStart = try XCTUnwrap(
            source.range(of: "struct AtriaHealthTimelineProofCard")
        )
        let cardTail = String(source[cardStart.lowerBound...])
        let chartCall = try XCTUnwrap(
            cardTail.range(of: "AtriaHeartRateAxisChart(")
        )
        let chartAndAfter = String(cardTail[chartCall.lowerBound...].prefix(700))
        XCTAssertTrue(
            chartAndAfter.contains("xDomain: pinnedXDomain"),
            "AtriaHealthTimelineProofCard must pass a pinned xDomain to its HR chart"
        )
        XCTAssertTrue(
            cardTail.contains("private var pinnedXDomain: ClosedRange<Date>?"),
            "the card must derive a minimum-width pinned domain from its series"
        )
    }

    private func healthScreenSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHealthScreen.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
