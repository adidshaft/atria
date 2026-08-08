import XCTest
@testable import Atria

final class AtriaGraphInspectorTests: XCTestCase {
    func testSegmentedPointsLeaveRealCollectionGap() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = AtriaInspectableGraph.segmentedPoints([
            (start, 70),
            (start.addingTimeInterval(5), 72),
            (start.addingTimeInterval(120), 74),
            (start.addingTimeInterval(125), 76)
        ], gapThreshold: 10)

        XCTAssertEqual(points.map(\.segment), [0, 0, 1, 1])
        XCTAssertEqual(points.map(\.value), [70, 72, 74, 76])
    }

    func testNearestReadingUsesRecordedPointWithoutInterpolation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let graph = AtriaInspectableGraph(
            title: "Test",
            subtitle: nil,
            content: .timeSeries([
                .init(title: "HR",
                      unit: " bpm",
                      tint: .red,
                      points: [
                        .init(date: start, value: 60),
                        .init(date: start.addingTimeInterval(20), value: 90)
                      ])
            ])
        )

        let selected = try XCTUnwrap(graph.nearestReadings(to: start.addingTimeInterval(12)).first)
        XCTAssertEqual(selected.point.date, start.addingTimeInterval(20))
        XCTAssertEqual(selected.point.value, 90)
    }

    func testInspectorHasOneLandscapeOrientationContract() {
        XCTAssertEqual(AtriaGraphInspectorOrientationPolicy.transitionMask, .allButUpsideDown)
        XCTAssertEqual(AtriaGraphInspectorOrientationPolicy.presentedMask, .landscape)
        XCTAssertEqual(AtriaGraphInspectorOrientationPolicy.preferredOrientation, .landscapeRight)
    }

    func testInspectorKeepsLandscapeFallbackWhenGeometryRequestIsRejected() throws {
        let (_, contents) = try source("AtriaGraphInspector.swift")
        XCTAssertTrue(contents.contains("let portraitFallback = proxy.size.height > proxy.size.width"))
        XCTAssertTrue(contents.contains(".rotationEffect(.degrees(portraitFallback ? 90 : 0))"))
        XCTAssertTrue(contents.contains("requestOrientation(AtriaGraphInspectorOrientationPolicy.presentedMask"))
        XCTAssertTrue(contents.contains("adjustVisibleDuration(by: 0.5)"))
        XCTAssertTrue(contents.contains("adjustVisibleDuration(by: 2)"))
        XCTAssertTrue(contents.contains(".chartXSelection(value: $selectedDate)"))
        XCTAssertGreaterThanOrEqual(contents.components(separatedBy: ".chartXAxis {").count - 1, 2)
        XCTAssertTrue(contents.contains("AxisValueLabel"))
    }

    func testExpandedAndHealthMonitorGraphsExposeReadableXAxisAndUseLandscapeCanvas() throws {
        let (_, expanded) = try source("AtriaExpandedChart.swift")
        let (_, vitals) = try source("AtriaVitalsCollectionSections.swift")

        XCTAssertTrue(expanded.contains("let landscapeHeight = min(proxy.size.width, proxy.size.height) - 24"))
        XCTAssertTrue(expanded.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        XCTAssertTrue(expanded.contains(".chartXAxis {"))
        XCTAssertTrue(expanded.contains("AxisValueLabel"))

        XCTAssertTrue(vitals.contains("AxisMarks(values: compactAxisDates)"))
        XCTAssertTrue(vitals.contains("Text(date, format: .dateTime.weekday(.narrow))"))
        XCTAssertTrue(vitals.contains("selectedTime: .constant(nil),\n                                        showsXAxis: true)"))
        XCTAssertTrue(vitals.contains(".defaultDigits(amPM: .narrow)"),
                      "the compact HR preview must not truncate long minute/meridiem labels")
        XCTAssertTrue(vitals.contains("private static var portraitRestoreTask: Task<Void, Never>?"))
        XCTAssertTrue(vitals.contains("generation == presentationGeneration"),
                      "a stale portrait restoration must not override a reopened landscape graph")
    }

    func testStandaloneGraphSurfacesUseSharedInspector() throws {
        let sources = try [
            "AtriaHealthspanDetailView.swift",
            "AtriaStressDetailView.swift",
            "AtriaHealthScreen.swift",
            "Insights.swift",
            "Sessions.swift",
            "AtriaActivityMonitor.swift",
            "AtriaVitalsCollectionSections.swift",
            "HRV.swift"
        ].map(source)

        for (name, contents) in sources {
            XCTAssertTrue(contents.contains(".atriaInspectableGraph("), "Missing inspector route in \(name)")
        }

        let (_, health) = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains("private var inspectorGraph: AtriaInspectableGraph"))
        XCTAssertTrue(health.contains("segment: $0.segment"),
                      "overnight HR/load inspection must preserve real collection gaps")

        // Overview metric charts deliberately own a richer period/comparison
        // full-screen route through `expandedChartConfig` + `onExpand`. The
        // next test verifies that route metric-by-metric; requiring the shared
        // modifier here as well would assert an implementation spelling, not a
        // missing user capability, and made the suite contradict itself.
    }

    func testEverySavedMetricTrendCanOpenLandscapeInspector() throws {
        let (_, contents) = try source("AtriaOverviewSections.swift")
        let requiredExpandedConfigs = [
            "case .recovery:",
            "case .hrv:",
            "case .restingHeartRate:",
            "case .respiratoryRate:",
            "case .sleep:",
            "case .strain:",
            "case .sleepPerformance:",
            "case .fitnessAge:"
        ]
        let configStart = try XCTUnwrap(contents.range(of: "private var expandedChartConfig:"))
        let configEnd = try XCTUnwrap(
            contents.range(of: "private var behaviorsMoveYouCard", range: configStart.upperBound..<contents.endIndex)
        )
        let config = String(contents[configStart.lowerBound..<configEnd.lowerBound])

        for metricCase in requiredExpandedConfigs {
            XCTAssertTrue(config.contains(metricCase), "Missing expanded chart config for \(metricCase)")
        }
        XCTAssertGreaterThanOrEqual(contents.components(separatedBy: "onExpand: { showExpandedChart = true }").count - 1,
                                    requiredExpandedConfigs.count)
    }

    private func source(_ name: String) throws -> (String, String) {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria/\(name)")
        return (name, try String(contentsOf: url, encoding: .utf8))
    }
}
