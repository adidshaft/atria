import XCTest
@testable import Atria

/// Owner screenshots + direction, 2026-08-24:
///   * the small "Strap steps" face rendered a bare "--",
///   * Sleep and Strain both read blue on the medium face,
///   * the large face was clipped top and bottom,
///   * "the steps one shows 10 things on a square".
///
/// The widget extension is a separate target and is not linked into this test
/// bundle, so these follow the established source-scan pattern used by
/// `AtriaMetricTruthUXTests` and `AtriaWidgetBatteryInvalidationTests`.
final class AtriaWidgetMinimalFaceTests: XCTestCase {

    private func widgetSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func entryViewSlice(_ source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: "struct AtriaWidgetEntryView: View")
        )
        let end = try XCTUnwrap(
            source.range(of: "private struct AtriaWidgetRecoveryGauge")
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - 2d: one identity hue per metric, shared with the app

    func testSleepAndStrainAreNotBothBlueAndMatchTheAppIdentityHues() throws {
        let source = try widgetSource()

        // The app's rule (Metrics.swift): strain is electric blue #0093E7
        // ("effort is always cool"), sleep owns purple "so it stays distinct
        // from strain".
        XCTAssertTrue(source.contains("""
        private let atriaWidgetSleepIdentityColor = Color(red: 0.51,
                                                          green: 0.35,
                                                          blue: 1.0)
        """), "sleep must carry the app's electric-sleep purple")

        XCTAssertFalse(
            source.contains(".sleep: return .indigo"),
            "SwiftUI .indigo is blue-family and reads as Strain's blue"
        )
        XCTAssertFalse(
            source.contains("tint: .indigo"),
            "the sleep ring must use the shared identity hue too"
        )
        XCTAssertFalse(
            source.contains("case .strain: return .orange"),
            "the widget disagreed with itself: strain was electric blue in "
                + "dailyTint and orange in the metric tiles"
        )
        XCTAssertTrue(
            source.contains("case .strain: return atriaWidgetStrainIdentityColor")
        )
        XCTAssertTrue(
            source.contains("case .sleep: return atriaWidgetSleepIdentityColor")
        )
    }

    func testSecondaryVitalsKeepDistinctIdentityHuesRatherThanRawSwiftUITints() throws {
        let source = try widgetSource()
        XCTAssertTrue(
            source.contains("case .rhr: return atriaWidgetRHRIdentityColor")
        )
        XCTAssertTrue(
            source.contains("case .hrv: return atriaWidgetHRVIdentityColor")
        )
        XCTAssertFalse(source.contains("case .rhr: return .mint"))
        XCTAssertFalse(source.contains("case .hrv: return .pink"))
    }

    // MARK: - 2b: one purpose per widget size

    func testSmallSquareCarriesOneHeroNotAMultiRowWhiteboardList() throws {
        let source = try widgetSource()
        let entry = try entryViewSlice(source)

        let smallStart = try XCTUnwrap(
            entry.range(of: "private var standardSmallWidget")
        )
        let smallEnd = try XCTUnwrap(entry.range(
            of: "private var recoveryHeroValueText",
            range: smallStart.upperBound..<entry.endIndex
        ))
        let small = String(entry[smallStart.lowerBound..<smallEnd.lowerBound])

        XCTAssertFalse(
            small.contains("AtriaWidgetWhiteboardList"),
            "the square must not pack the multi-row whiteboard list"
        )
        XCTAssertTrue(small.contains("Text(recoveryHeroValueText)"),
                      "the square leads with one hero value")
        XCTAssertTrue(small.contains("Text(\"Recovery\")"))
    }

    func testSmallHeroNeverFabricatesAPercentItDoesNotHave() throws {
        let source = try widgetSource()
        XCTAssertTrue(source.contains(
            "entry.snapshot?.recoveryPercent.map { \"\\($0)%\" } ?? \"Learning\""
        ), "an uncomputed recovery must read Learning, never a number")
    }

    /// Home Screen small and large already say "Learning". The medium daily
    /// overview printed "--" as the value while its own detail said
    /// "Learning" — two words for the same missing percent, and a lie next
    /// to the small widget on the same screen. Lock Screen accessories keep
    /// "--" for space.
    func testMediumDailyRecoveryValueUsesLearningLikeTheOtherHomeScreenFaces() throws {
        let source = try widgetSource()
        let start = try XCTUnwrap(source.range(of: "private func dailyValue(_ metric:"))
        let end = try XCTUnwrap(source.range(
            of: "private func dailyDetail(_ metric:",
            range: start.upperBound..<source.endIndex
        ))
        let daily = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(daily.contains("?? \"Learning\""),
                      "the medium recovery value must use the canonical not-ready word")
        XCTAssertFalse(daily.contains("?? \"--\""),
                       "Home Screen recovery must not say -- while the small hero says Learning")
        let accessStart = try XCTUnwrap(source.range(of: "private func dailyAccessibilityLabel"))
        let accessEnd = try XCTUnwrap(source.range(
            of: "private var recoveryOnlyWidget",
            range: accessStart.upperBound..<source.endIndex
        ))
        let access = String(source[accessStart.lowerBound..<accessEnd.lowerBound])
        XCTAssertTrue(access.contains("map { \"\\($0) percent\" } ?? \"Learning\""),
                      "VoiceOver must speak the same word the face shows")
        XCTAssertFalse(access.contains("map { \"\\($0) percent\" } ?? \"unavailable\""),
                       "unavailable was the VoiceOver stand-in for the old --")
    }

    func testLargeFaceDropsTheRedundantListThatOverflowedTheContainer() throws {
        let source = try widgetSource()
        let entry = try entryViewSlice(source)

        let largeStart = try XCTUnwrap(
            entry.range(of: "private var systemLargeWidget")
        )
        let largeEnd = try XCTUnwrap(entry.range(
            of: "private var widgetHeader",
            range: largeStart.upperBound..<entry.endIndex
        ))
        let large = String(entry[largeStart.lowerBound..<largeEnd.lowerBound])

        XCTAssertFalse(
            large.contains("AtriaWidgetWhiteboardList"),
            "the large face was clipped top and bottom; the whiteboard list "
                + "duplicated the four metric tiles below it"
        )
        // The content that earns its place stays.
        XCTAssertTrue(large.contains("recoverySummaryRow"))
        XCTAssertTrue(large.contains("LazyVGrid"))
        XCTAssertTrue(large.contains("controlButtons"))
    }

    // MARK: - 2c: hold-last-good instead of a bare "--"

    func testStaleStepsHoldTheLastKnownCountDimmedInsteadOfBlanking() throws {
        let source = try widgetSource()

        XCTAssertTrue(source.contains("struct Rendered: Equatable"))
        XCTAssertTrue(
            source.contains("func rendered(_ snapshot: AtriaWidgetSnapshot?, now: Date) -> Rendered")
        )
        // Only cumulative day-scoped values may be held.
        XCTAssertTrue(source.contains("guard case .steps = self,"),
                      "the hold must be limited to the cumulative step total")
        // The held value must be visually separated from a current one.
        XCTAssertTrue(source.contains(
            "rendered.isStaleLastKnown ? .secondary : .primary"
        ), "a held value must be dimmed, never shown as current")
        XCTAssertTrue(source.contains(".foregroundStyle(valueTint)"))
    }

    func testHeldStepValueStillPrefersTheAppRenderedStringSoWidgetAndAppAgree() throws {
        let source = try widgetSource()
        // 2a: the widget must not invent a parallel formatting path.
        XCTAssertTrue(source.contains("""
                    text: snapshot.stepsValueText
                        ?? atriaStepValueText(snapshot, steps: lastKnown),
        """), "the held value reuses the app-rendered string first")
    }

    func testStaleCaptionRemainsSoTheDimmedNumberIsNeverMistakenForCurrent() throws {
        let source = try widgetSource()
        XCTAssertTrue(source.contains(
            "return \"Step stale · last \\(atriaCaptureTimeText(capturedAt))\""
        ), "the honest stale caption is what licenses showing a held number")
    }
}
