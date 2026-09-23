import XCTest
@testable import Atria

/// 2026-09-02: the weekly trend bars used raw system green/yellow/red with
/// invented bands (strain 8/13, sleep 6.5h/7.5h). The palette rule lives in
/// Metrics: strain is one cool hue because recovery owns the green/amber/red
/// axis, and sleep zones are percent of the night's own need. Bars now come
/// from those authorities.
final class AtriaWeeklyTrendTintTests: XCTestCase {
    private static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Atria")

    func testBarsComeFromTheColourAuthoritiesNotInventedBands() throws {
        let overview = try String(contentsOf: Self.appDirectory.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertFalse(overview.contains("private func selectedTrendColor"))
        XCTAssertFalse(overview.contains("value >= 13 ? .red"), "no invented strain bands")
        XCTAssertFalse(overview.contains("value >= 7.5 ? .green"), "no fixed-hours sleep bands")
        XCTAssertTrue(overview.contains("entry.strain.map { (entry.day, $0, Metrics.strainColor($0)) }"))
        XCTAssertTrue(overview.contains("entry.recovery.map { (entry.day, Double($0), Metrics.recoveryColor($0)) }"))
        XCTAssertTrue(overview.contains("entry.sleepPerformance.map { AtriaTriRing.zoneTint(.sleep, percent: Double($0)) }"))
        XCTAssertTrue(overview.contains("?? Metrics.electricSleep"),
                      "a night without a need percent keeps the sleep identity hue, never a fabricated zone")
        XCTAssertTrue(overview.contains(".foregroundStyle(point.tint)"))
    }

    func testCaptionsDescribeWhatTheBarsNowEncode() throws {
        let overview = try String(contentsOf: Self.appDirectory.appendingPathComponent("AtriaOverviewSections.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(overview.contains("\"One hue · bar height is the day's strain\""))
        XCTAssertTrue(overview.contains("\"By % of sleep need · green 85–110 · yellow 70–84 · red <70\""))
        XCTAssertFalse(overview.contains("Green 7.5h+"))
    }

    func testStrainStaysOneHueAtEveryIntensity() {
        XCTAssertEqual(Metrics.strainColor(2), Metrics.strainColor(14))
        XCTAssertEqual(Metrics.strainColor(21), Metrics.electricStrain)
    }
}
