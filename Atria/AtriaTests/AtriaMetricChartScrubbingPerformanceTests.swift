import XCTest
@testable import Atria

final class AtriaMetricChartScrubbingPerformanceTests: XCTestCase {
    func testPreparedDataResolvesNearestPointAndCompanionsWithoutScanning() {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let points = (0..<4).map { offset in
            AtriaDetailChartPoint(day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                  value: Double(offset),
                                  tint: .blue)
        }
        let companion = [AtriaDetailChartPoint(day: points[2].day, value: 42, tint: .green)]
        let prepared = AtriaMetricChartPreparedData(points: points,
                                                    priorPoints: [],
                                                    baselineBounds: nil,
                                                    priorAverage: nil,
                                                    companionPoints: [companion],
                                                    calendar: calendar)

        XCTAssertEqual(prepared.nearestPointIndex(to: points[2].day.addingTimeInterval(60)), 2)
        XCTAssertEqual(prepared.companionPointIndex(at: 0, on: points[2].day), 0)
        XCTAssertNil(prepared.companionPointIndex(at: 0, on: points[1].day))
    }

    private func overviewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testScrubbingOwnsOnlySelectionStateAndUsesPreparedStaticInputs() throws {
        let source = try overviewSource()
        let sheetStart = try XCTUnwrap(source.range(of: "struct AtriaMetricDetailSheet: View"))
        let chartStart = try XCTUnwrap(source.range(of: "private struct AtriaPreparedMetricChart: View"))
        let sheet = String(source[sheetStart.lowerBound..<chartStart.lowerBound])
        let chartEnd = try XCTUnwrap(source.range(of: "private struct AtriaStrainWorkoutRow", range: chartStart.lowerBound..<source.endIndex))
        let chart = String(source[chartStart.lowerBound..<chartEnd.lowerBound])

        XCTAssertFalse(sheet.contains("@State private var scrubbedDay"))
        XCTAssertTrue(chart.contains("@State private var scrubbedDay"))
        XCTAssertTrue(sheet.contains("struct AtriaMetricChartPreparedData"))
        XCTAssertTrue(sheet.contains("pointTimes = points.map"))
        XCTAssertTrue(sheet.contains("companionIndicesByDay = companionPoints.map"))
        XCTAssertTrue(sheet.contains("minMaxPoints = points.filter"))
        XCTAssertTrue(sheet.contains("@State private var metricChartPreparedDataCache"))
        XCTAssertTrue(sheet.contains("preparationInput: preparation.valueKey ?? preparationInput"))
        XCTAssertTrue(sheet.contains("metricChartPreparedDataCache.value(for: cacheKey)"))
        XCTAssertTrue(chart.contains("prepared: AtriaMetricChartPreparedData"))
        XCTAssertFalse(chart.contains("prepared = AtriaMetricChartPreparedData"))
        XCTAssertTrue(chart.contains(".chartYScale(domain: prepared.domain)"))
    }

    func testScrubRenderPathHasNoLinearPointOrCompanionScan() throws {
        let source = try overviewSource()
        let preparedStart = try XCTUnwrap(source.range(of: "struct AtriaMetricChartPreparedData"))
        let selectionStart = try XCTUnwrap(source.range(of: "private var selectedPointIndex: Int?"))
        let chartEnd = try XCTUnwrap(source.range(of: "private struct AtriaStrainWorkoutRow", range: selectionStart.lowerBound..<source.endIndex))
        let preparedPath = String(source[preparedStart.lowerBound..<selectionStart.lowerBound])
        let scrubPath = String(source[selectionStart.lowerBound..<chartEnd.lowerBound])

        XCTAssertTrue(preparedPath.contains("while lower < upper"))
        XCTAssertTrue(preparedPath.contains("func nearestPointIndex"))
        XCTAssertTrue(scrubPath.contains("selectedPointIndex"))
        XCTAssertTrue(scrubPath.contains("prepared.nearestPointIndex"))
        XCTAssertTrue(scrubPath.contains("prepared.companionPointIndex"))
        XCTAssertFalse(scrubPath.contains("points.min(by:"))
        XCTAssertFalse(scrubPath.contains("companion.points.first"))
        XCTAssertFalse(scrubPath.contains("Calendar.current.isDate($0.day"))
        XCTAssertFalse(scrubPath.contains(".chartYScale(domain: chartDomain"))
    }
}
