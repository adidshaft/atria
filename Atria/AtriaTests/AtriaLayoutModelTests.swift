import XCTest
@testable import Atria

final class AtriaLayoutModelTests: XCTestCase {
    func testVitalsSectionOrderRepairsMalformedAndDuplicateCSV() {
        let csv = "profile,unknown,hrv,profile"

        XCTAssertEqual(AtriaVitalsSection.ordered(from: csv),
                       [.profile, .hrv, .pulse, .recoveryStrain])
    }

    func testVitalsSectionDragAndBoundaryMovesStayStable() {
        let defaultCSV = AtriaVitalsSection.allCases.map(\.rawValue).joined(separator: ",")

        XCTAssertEqual(AtriaVitalsSection.draggedSection(from: AtriaVitalsSection.hrv.dragPayload), .hrv)
        XCTAssertNil(AtriaVitalsSection.draggedSection(from: "hrv"))
        XCTAssertEqual(AtriaVitalsSection.moving(.profile, before: .pulse, in: defaultCSV),
                       "profile,pulse,hrv,recoveryStrain")
        XCTAssertEqual(AtriaVitalsSection.moving(.pulse, direction: -1, in: defaultCSV), defaultCSV)
        XCTAssertEqual(AtriaVitalsSection.moving(.profile, direction: 1, in: defaultCSV), defaultCSV)
        XCTAssertEqual(AtriaVitalsSection.moving(.hrv, direction: 1, in: defaultCSV),
                       "pulse,recoveryStrain,hrv,profile")
    }

    func testTodayMetricVisibleReorderPreservesHiddenSlots() {
        let order = "recovery,respiratoryRate,hrv,stress,sleep"
        let hidden = AtriaTodayMetric.hiddenStorageValue(for: Set([AtriaTodayMetric.respiratoryRate.rawValue]))

        XCTAssertEqual(AtriaTodayMetric.moving(.stress,
                                               before: .hrv,
                                               in: order,
                                               hiddenCSV: hidden),
                       "recovery,respiratoryRate,stress,hrv,sleep,rhr,steps,load,hrZones,workouts,strainCompare,vo2max,sleepHistory,sleepEfficiency,sleepPerformance,bodyTemp,calories,trend,insights,strain,bloodOxygen,bioAge")
    }

    func testTodayMetricDragPayloadRejectsRawValues() {
        XCTAssertEqual(AtriaTodayMetric.draggedMetric(from: AtriaTodayMetric.stress.dragPayload), .stress)
        XCTAssertNil(AtriaTodayMetric.draggedMetric(from: AtriaTodayMetric.stress.rawValue))
    }

    func testTodaySectionOrderRepairsMalformedAndDuplicateCSV() {
        XCTAssertEqual(AtriaTodayScreen.orderedTodaySections(from: "coach,unknown,plan,coach"),
                       [.coach, .plan, .shortcuts, .weeklyPlan, .glance])
    }

    func testTodayScreenGlanceMetricsUsesValidatedLayoutConfig() {
        var config = AtriaHomeLayoutConfig.default
        config.glanceMetrics = ["hrv", "unknown", "hrv", "sleepPerformance"]

        XCTAssertEqual(AtriaTodayScreen.glanceMetrics(for: config), [.hrv, .sleepPerformance])
    }

    func testHomeLayoutMovesGlanceCardsByStableMetricKey() {
        var config = AtriaHomeLayoutConfig.default
        let original = config.glanceMetrics

        config.moveGlanceMetric("workouts", before: "hrv")

        XCTAssertEqual(config.glanceMetrics.first, "workouts")
        XCTAssertEqual(Set(config.glanceMetrics), Set(original))
        XCTAssertEqual(config.glanceMetrics.count, original.count)

        config.moveGlanceMetric("unknown", before: "hrv")
        XCTAssertEqual(config.glanceMetrics.first, "workouts", "Unknown payloads must be ignored")
    }

    func testHomeLayoutAccessibleGlanceShiftHonorsBoundaries() {
        var config = AtriaHomeLayoutConfig.default
        let original = config.glanceMetrics

        config.shiftGlanceMetric(original[1], direction: -1)
        XCTAssertEqual(config.glanceMetrics.prefix(2), [original[1], original[0]])

        config.shiftGlanceMetric(original[1], direction: -1)
        XCTAssertEqual(config.glanceMetrics.prefix(2), [original[1], original[0]],
                       "Moving the first card up must be a no-op")

        config.shiftGlanceMetric(config.glanceMetrics.last!, direction: 1)
        XCTAssertEqual(Set(config.glanceMetrics), Set(original))
        XCTAssertEqual(config.glanceMetrics.count, original.count)
    }

    func testTodayMetricLegacyPreferenceMigrationDropsNonMetricsAndMergesSteps() {
        let legacyOrder = "workout,recovery,strapSteps,backfill,hapticAlerts,sleep,unknown,steps"
        XCTAssertEqual(AtriaTodayMetric.ordered(from: legacyOrder),
                       [.workouts, .recovery, .steps, .sleep, .hrv, .stress, .rhr, .respiratoryRate, .load, .hrZones, .strainCompare, .vo2max, .sleepHistory, .sleepEfficiency, .sleepPerformance, .bodyTemp, .calories, .trend, .insights, .strain, .bloodOxygen, .bioAge])

        let legacyHidden = AtriaTodayMetric.hiddenStorageValue(for: Set(["strapSteps", "backfill", "hapticAlerts", "unknown", "bloodOxygen"]))
        XCTAssertEqual(legacyHidden, "bloodOxygen,steps")

        let visible = AtriaTodayMetric.visibleOrdered(orderCSV: legacyOrder, hiddenCSV: legacyHidden)
        XCTAssertFalse(visible.contains(.steps))
        XCTAssertTrue(visible.contains(.workouts))
        XCTAssertFalse(visible.map(\.rawValue).contains("workout"))
    }

    // MARK: - Visibility/IA fix (2026-07-05)

    /// The default deck used to ship only 12 of the 14-card cap, hiding two
    /// metrics (sleep efficiency, fitness age) that are fully computed today.
    func testDefaultHomeLayoutConfigHas14TilesIncludingSleepEfficiencyAndBioAge() {
        let config = AtriaHomeLayoutConfig.default.validated()

        XCTAssertEqual(config.glanceMetrics.count, 8)
        XCTAssertTrue(config.glanceMetrics.contains("sleepEfficiency"))
        XCTAssertTrue(config.glanceMetrics.contains("bioAge"))
    }

    /// `AtriaHomeLayoutCatalog.metricKeys` and `AtriaTodayMetric` must stay
    /// parallel -- `AtriaTodayScreen.glanceItems` silently drops any key
    /// missing from either side.
    func testHomeLayoutCatalogAndTodayMetricStayParallel() {
        let catalogKeys = Set(AtriaHomeLayoutCatalog.metricKeys)
        let enumKeys = Set(AtriaTodayMetric.allCases.map(\.rawValue))

        XCTAssertEqual(catalogKeys, enumKeys)
    }

    /// Sleep performance and the honest SpO2 tile must be addable via BOTH
    /// catalogs: the validation catalog (`AtriaHomeLayoutCatalog`) and the
    /// Customize sheet's toggle-list catalog (`AtriaTodayMetric.defaultGlanceOrder`).
    func testSleepPerformanceAndBloodOxygenAddableViaBothCatalogs() {
        XCTAssertTrue(AtriaHomeLayoutCatalog.metricKeys.contains("sleepPerformance"))
        XCTAssertTrue(AtriaHomeLayoutCatalog.metricKeys.contains("bloodOxygen"))
        XCTAssertTrue(AtriaTodayMetric.defaultGlanceOrder.contains(.sleepPerformance))
        XCTAssertTrue(AtriaTodayMetric.defaultGlanceOrder.contains(.bloodOxygen))

        var config = AtriaHomeLayoutConfig.default
        config.glanceMetrics = ["sleepPerformance", "bloodOxygen"]
        XCTAssertEqual(config.validated().glanceMetrics, ["sleepPerformance", "bloodOxygen"])
    }

    /// Route audit (visibilitySpec §3): every glance tile that has a real or
    /// honest-partial detail must map to an `AtriaMetricDetailKind`, so no
    /// tile with a route silently dead-ends.
    func testGlanceRouteMapCoversNewDetailKinds() {
        let routedRawValues: Set<String> = [
            "recovery", "strain", "strainCompare", "hrv", "rhr", "respiratoryRate",
            "sleep", "sleepHistory", "sleepEfficiency", "sleepPerformance",
            "vo2max", "bioAge", "bodyTemp", "hrZones"
        ]
        for raw in routedRawValues {
            XCTAssertNotNil(AtriaTodayMetric(rawValue: raw), "\(raw) should still be a valid AtriaTodayMetric case")
        }
    }
}
