import XCTest
@testable import Atria

final class AtriaStrainDetailPresentationTests: XCTestCase {
    func testCurrentCycleContextIsDayOnlyAndFailsClosed() {
        XCTAssertTrue(AtriaStrainDetailContextPolicy.showsCurrentCycle(
            range: .day,
            usesCurrentCycle: true,
            isPreparingSelectedPeriod: false
        ))
        for aggregateRange in AtriaTrendRange.allCases where aggregateRange != .day {
            XCTAssertFalse(AtriaStrainDetailContextPolicy.showsCurrentCycle(
                range: aggregateRange,
                usesCurrentCycle: true,
                isPreparingSelectedPeriod: false
            ), "\(aggregateRange) is an aggregate, not today's live context")
        }
        XCTAssertFalse(AtriaStrainDetailContextPolicy.showsCurrentCycle(
            range: .day,
            usesCurrentCycle: false,
            isPreparingSelectedPeriod: false
        ))
        XCTAssertFalse(AtriaStrainDetailContextPolicy.showsCurrentCycle(
            range: .day,
            usesCurrentCycle: true,
            isPreparingSelectedPeriod: true
        ))
    }

    func testWorkoutRowsDistinguishBoundedWorkoutStrainFromDayStrain() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("workout strain"))
        XCTAssertTrue(source.contains("Each value is this workout’s heart-rate strain. Day strain above combines your full sleep-to-sleep day."))
    }

    func testTargetRailUsesWhoopScaleAndTwoPointTargetBand() {
        XCTAssertEqual(AtriaStrainTargetPresentation.progress(for: 10.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AtriaStrainTargetPresentation.progress(for: 30), 1, accuracy: 0.0001)
        XCTAssertEqual(AtriaStrainTargetPresentation.targetRange(for: 12), 11...13)
        XCTAssertEqual(AtriaStrainTargetPresentation.targetRange(for: 0.5), 0...1.5)
    }

    func testStrainDetailUsesCompactTargetRailInsteadOfLargeCircularGauge() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let detailTemplate = try XCTUnwrap(source.range(of: "private var detailTemplate: some View"))
        let start = try XCTUnwrap(
            source.range(of: "case .strain:", range: detailTemplate.upperBound..<source.endIndex)
        )
        let end = try XCTUnwrap(source.range(of: "case .sleepPerformance:", range: start.upperBound..<source.endIndex))
        let strainDetail = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(strainDetail.contains("heroStyle: .strain(score: strainHeroRawValue"))
        XCTAssertFalse(strainDetail.contains("AtriaStrainBandGauge("))
        XCTAssertTrue(source.contains("private struct AtriaStrainScoreHero"))
        XCTAssertTrue(source.contains("AtriaStrainTargetPresentation.progress(for: score)"))
    }

    func testHistoricalStrainDetailGatesCurrentCycleWorkoutContext() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let detailTemplate = try XCTUnwrap(source.range(of: "private var detailTemplate: some View"))
        let start = try XCTUnwrap(
            source.range(of: "case .strain:", range: detailTemplate.upperBound..<source.endIndex)
        )
        let end = try XCTUnwrap(
            source.range(of: "case .sleepPerformance:", range: start.upperBound..<source.endIndex)
        )
        let strainDetail = String(source[start.lowerBound..<end.lowerBound])
        // 2026-08-29 minimalism restructure: the live-cycle cards moved into
        // the contributors slot (behind "Show details"); the cycle gate moved
        // with them, so the gated span now sits between `} contributors: {`
        // and `} chart:`.
        let contributorsStart = try XCTUnwrap(
            strainDetail.range(of: "} contributors: {")
        )
        let chartStart = try XCTUnwrap(
            strainDetail.range(of: "} chart:", range: contributorsStart.upperBound..<strainDetail.endIndex)
        )
        let contributorsSlot = String(strainDetail[contributorsStart.lowerBound..<chartStart.lowerBound])
        let gateStart = try XCTUnwrap(
            contributorsSlot.range(of: "if showsCurrentPhysiologicalCycleContext {"),
            "every live-cycle card must stay behind the cycle gate"
        )
        let gatedCards = String(contributorsSlot[gateStart.lowerBound...])

        XCTAssertTrue(gatedCards.contains("strainWorkoutSection"))
        XCTAssertTrue(gatedCards.contains("strainZoneHistogramCard"))
        XCTAssertTrue(gatedCards.contains("strainActivityMixCard"))
        XCTAssertTrue(gatedCards.contains("AtriaMetricContributorRows"),
                      "Today's workout and zone contributor rows must be absent on past days")
        XCTAssertTrue(strainDetail.contains("target: showsCurrentPhysiologicalCycleContext"),
                      "A past-day hero must not be classified against today's target")
        // Above the fold only the combo card remains (no cycle-gated card may
        // render before the contributors slot).
        let aboveFold = String(strainDetail[strainDetail.startIndex..<contributorsStart.lowerBound])
        XCTAssertTrue(aboveFold.contains("strainRecoveryComboCard"))
        for gated in ["strainWorkoutSection", "strainZoneHistogramCard",
                      "strainActivityMixCard", "strainCardioLiftingSplitCard"] {
            XCTAssertFalse(aboveFold.contains(gated),
                           "\(gated) must live behind the Show-details reveal")
        }

        let projectionStart = try XCTUnwrap(
            source.range(of: "private var showsCurrentPhysiologicalCycleContext: Bool")
        )
        let truthStart = try XCTUnwrap(
            source.range(of: "private var currentCycleStrainTruth",
                         range: projectionStart.upperBound..<source.endIndex)
        )
        let projection = String(source[projectionStart.lowerBound..<truthStart.lowerBound])
        XCTAssertTrue(projection.contains("AtriaStrainDetailContextPolicy.showsCurrentCycle("))
        XCTAssertTrue(source.contains("return range == .day ? \"Saved day\" : \"Period average\""))
    }

    func testPartialDayStrainKeepsMeasuredNumberAndAddsLimitation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let overviewURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let overview = try String(contentsOf: overviewURL, encoding: .utf8)
        let valueStart = try XCTUnwrap(overview.range(of: "private var strainHeroValue: String"))
        let valueEnd = try XCTUnwrap(overview.range(of: "private var dayStrainMetricsIncomplete", range: valueStart.upperBound..<overview.endIndex))
        let valueProjection = String(overview[valueStart.lowerBound..<valueEnd.lowerBound])

        XCTAssertTrue(overview.contains("currentCycleStrainLimitation?.compactState"))
        XCTAssertTrue(overview.contains("?? \"Strain data incomplete\""))
        XCTAssertFalse(valueProjection.contains("return \"Incomplete\""),
                       "partial evidence must not replace a real strain number")
        // The "≥" lower-bound marker was removed from strain 2026-08-27 at the
        // owner's request (steps lost the same marker earlier). Partial
        // cumulative strain is STILL disclosed — by the limitation state and
        // the "Strain data incomplete" copy asserted just above, and by
        // `dayStrainMetricsIncomplete` continuing to drive them. What changed
        // is that the disclosure is words beside the number rather than a
        // symbol welded to it.
        XCTAssertFalse(valueProjection.contains("\"≥ \\(value)\""),
                       "the lower-bound marker is gone from the number itself")
        // Checked on the whole file, not the value slice: the value expression
        // no longer branches on incompleteness at all, which is the point of
        // the change. The signal itself must still exist and still drive the
        // disclosure asserted above.
        XCTAssertTrue(overview.contains("private var dayStrainMetricsIncomplete"),
                      "incompleteness must still be tracked and disclosed")
        XCTAssertTrue(overview.contains(
            "value: currentCycleStrainTruth.exactTrendValue"
        ), "partial cumulative strain must be withheld from exact chart aggregates")

        let todayURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let today = try String(contentsOf: todayURL, encoding: .utf8)
        XCTAssertFalse(today.contains("hasPrefix(\"≥\")"),
                       "Today must not sniff a prefix that no longer exists; "
                           + "partialness is read from the confidence string")
        XCTAssertTrue(today.contains("displayHero.strainConfidence.localizedCaseInsensitiveContains(\"partial\")"))
        // Partial evidence keeps the measured number and names the concrete
        // limitation instead of collapsing every cause into generic sparse-HR
        // copy. The lower-bound MARKER is gone (2026-08-27) but the limitation
        // copy that explains it is exactly what must remain.
        XCTAssertTrue(today.contains("currentStrainLimitation?.compactState"))
        XCTAssertTrue(today.contains("?? \"Strain data incomplete\""))
        XCTAssertFalse(today.contains("\"≥ \\(displayHero.strainValue)\""),
                       "the ring value is the measured number alone")
    }

    func testNoEvidenceStrainRemainsLearningInsteadOfInventedZero() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let homeURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: homeURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "var strainValue: String"))
        let end = try XCTUnwrap(source.range(of: "var strainDetail: String", range: start.upperBound..<source.endIndex))
        let projection = String(source[start.lowerBound..<end.lowerBound])

        // 2026-07-31: 81eea260 moved the value composition into the single
        // Metrics.StrainPresentation authority; the home projection must
        // delegate to it rather than reimplement the tokens locally.
        XCTAssertTrue(projection.contains("Metrics.StrainPresentation.resolve("))
        XCTAssertTrue(projection.contains(".valueText"))

        // The invariant this test is named for is unchanged and now enforced
        // inside the shared authority: no evidence must never become an
        // invented zero — learning/standby resolves to `nil`, and the value
        // line only ever carries a numeral, a `≥` lower bound, or "--".
        let metricsURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Metrics.swift")
        let metrics = try String(contentsOf: metricsURL, encoding: .utf8)
        let presentationStart = try XCTUnwrap(metrics.range(of: "struct StrainPresentation"))
        let presentationEnd = try XCTUnwrap(metrics.range(
            of: "var coverageText: String?",
            range: presentationStart.upperBound..<metrics.endIndex
        ))
        let presentation = String(metrics[presentationStart.lowerBound..<presentationEnd.lowerBound])
        XCTAssertTrue(presentation.contains("localizedCaseInsensitiveContains(\"learning\")"))
        XCTAssertTrue(presentation.contains("return AtriaCompactMetricPresentation.noValue"))
        XCTAssertFalse(presentation.contains("return \"0\""),
                       "no evidence must never be presented as a measured zero")
        XCTAssertTrue(presentation.contains("String(format: \"%.1f\", value)"))
        XCTAssertFalse(presentation.contains("\"≥ \\(numeric)\""),
                       "removed 2026-08-27; partialness now reads as "
                           + "\"Partial · N% tracked\" beside the value")
    }
}
