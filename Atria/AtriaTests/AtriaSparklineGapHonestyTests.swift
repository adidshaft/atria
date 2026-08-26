import XCTest
@testable import Atria

/// A line chart joins the points it is given. If the days between two points
/// were never measured, joining them draws a reading the strap never took —
/// and unlike a missing bar, nothing about a continuous line says "absent".
///
/// The Vitals health-monitor sparkline was the last per-day line in the app
/// that did not break. Its feed compactMaps unmeasured days away, so its seven
/// most recent MEASURED values can span far more than seven calendar days, and
/// its axis labels only the first and last of them — so a month-wide gap and a
/// contiguous week rendered identically.
///
/// These are structural, not string pins: each is bounded by the enclosing
/// declaration rather than by a character distance, because five source-scan
/// tests broke on unrelated formatting changes on 2026-08-26, and two of those
/// had silently slid onto a different function and were asserting nothing.
final class AtriaSparklineGapHonestyTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/\(name)"),
            encoding: .utf8
        )
    }

    /// The body of `AtriaHealthMonitorSparkline`, bounded by the next
    /// top-level `private struct` / `private enum` / `extension`.
    private func sparklineDeclaration() throws -> String {
        let text = try source("AtriaVitalsCollectionSections.swift")
        guard let start = text.range(of: "private struct AtriaHealthMonitorSparkline") else {
            XCTFail("AtriaHealthMonitorSparkline is gone — this test has no subject")
            return ""
        }
        let rest = text[start.upperBound...]
        let terminators = ["\nprivate struct ", "\nprivate enum ", "\nstruct ", "\nextension "]
        let end = terminators.compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<end])
    }

    func testTheVitalsSparklineSplitsItsLineAtUnmeasuredDays() throws {
        let declaration = try sparklineDeclaration()

        XCTAssertTrue(declaration.contains("AtriaTrendGapPolicy.assigningSegments"),
                      "the sparkline must split observed days into contiguous runs")
        XCTAssertTrue(declaration.contains("series: .value("),
                      "a run id is only honoured if it is passed as the LineMark series")
    }

    func testAnIsolatedMeasuredDayStaysVisibleAsAPoint() throws {
        // A run of length one draws no line. Without a mark it disappears from
        // a chart that still counts it, so the sparse-grammar singleton rule
        // has to be applied here too.
        let declaration = try sparklineDeclaration()

        XCTAssertTrue(declaration.contains("AtriaTrendSparseGrammar.singletonSegments"),
                      "single-day runs must be identified")
        XCTAssertTrue(declaration.contains("PointMark"),
                      "and drawn, or a lone measured day renders as nothing")
    }

    /// The real behaviour, asserted through the shared policy rather than the
    /// view: this is what the sparkline now delegates to.
    func testTheGapPolicyItDelegatesToActuallySeparatesNonAdjacentDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: day0)!
        }

        // Two adjacent days, a nine-day hole, then three adjacent days.
        let samples = [0, 1, 10, 11, 12].map {
            AtriaTrendPoint.Sample(date: day($0), value: 60)
        }
        let segments = AtriaTrendGapPolicy.assigningSegments(to: samples, calendar: calendar)
            .map(\.segment)

        XCTAssertEqual(segments, [0, 0, 1, 1, 1],
                       "the nine-day hole must start a new run, not be drawn through")
        XCTAssertEqual(Set(segments).count, 2, "exactly two runs, so exactly one break")
        XCTAssertTrue(AtriaTrendSparseGrammar.singletonSegments(segments).isEmpty,
                      "neither run is a singleton here")
    }

    func testALoneMeasuredDayBetweenTwoHolesIsItsOwnSingletonRun() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))

        let samples = [0, 5, 9, 10].map {
            AtriaTrendPoint.Sample(date: calendar.date(byAdding: .day, value: $0, to: day0)!,
                                   value: 55)
        }
        let segments = AtriaTrendGapPolicy.assigningSegments(to: samples, calendar: calendar)
            .map(\.segment)

        XCTAssertEqual(segments, [0, 1, 2, 2])
        XCTAssertEqual(AtriaTrendSparseGrammar.singletonSegments(segments), [0, 1],
                       "day 0 and day 5 each stand alone and would vanish without a PointMark")
    }
}
