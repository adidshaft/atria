import XCTest
import SwiftUI
@testable import Atria

/// One metric, one glyph, one hue. Ten separate audit findings (2026-08-28)
/// said the same thing from different angles: three parallel tables covered
/// symbol OR tint but never both, so screens drifted apart.
final class AtriaMetricIdentityTests: XCTestCase {

    /// A glyph belongs to exactly one metric. Respiration and VO2max shared
    /// `lungs.fill` inside a single Vitals grid, so the two were not
    /// distinguishable at a glance.
    func testNoTwoMetricsShareAGlyph() {
        var owner: [String: AtriaTodayMetric] = [:]
        for metric in AtriaTodayMetric.allCases {
            let glyph = metric.systemImage
            if let existing = owner[glyph] {
                XCTFail("\(glyph) is worn by both \(existing) and \(metric)")
            }
            owner[glyph] = metric
        }
    }

    /// Resting HR is blue and HRV is rose — the rule Metrics.swift documents
    /// and four surfaces had swapped.
    func testRestingHeartRateAndHRVKeepTheirDocumentedHues() {
        XCTAssertEqual(AtriaTodayMetric.rhr.identityTint(), Metrics.electricRHR)
        XCTAssertEqual(AtriaTodayMetric.hrv.identityTint(), Metrics.electricHRV)
        XCTAssertNotEqual(AtriaTodayMetric.rhr.identityTint(),
                          AtriaTodayMetric.hrv.identityTint())
    }

    /// Recovery must not wear the glyph that means Resting HR.
    func testRecoveryDoesNotWearTheRestingHeartRateGlyph() {
        XCTAssertNotEqual(AtriaTodayMetric.recovery.systemImage,
                          AtriaTodayMetric.rhr.systemImage)
    }

    /// Effort is cool, never warm: a hard day must not read as poor recovery.
    func testStrainFamilyStaysCool() {
        for metric in [AtriaTodayMetric.strain, .strainCompare, .load,
                       .hrZones, .calories] {
            XCTAssertEqual(metric.identityTint(), Metrics.electricStrain,
                           "\(metric) drifted out of the strain family")
        }
    }

    /// Sleep owns purple so it stays distinct from strain.
    func testSleepFamilyIsOneHue() {
        for metric in [AtriaTodayMetric.sleep, .sleepHistory,
                       .sleepEfficiency, .sleepPerformance] {
            XCTAssertEqual(metric.identityTint(), Metrics.electricSleep)
        }
    }

    /// Exactly two metrics may paint their VALUE instead of their identity.
    /// A third member is a bug: it means a surface started grading a hue that
    /// every other surface uses to mean "this is which metric".
    func testOnlyRecoveryAndStepsGradeTheirTint() {
        let graded = AtriaTodayMetric.allCases.filter(\.usesValueGradedTint)
        XCTAssertEqual(Set(graded), Set([.recovery, .steps]),
                       "a new value-graded metric needs an explicit decision")
    }

    /// Blood oxygen has no verified decoder, so it must not wear a confident
    /// hue — that would imply a reading exists.
    func testBloodOxygenStaysUntinted() {
        XCTAssertEqual(AtriaTodayMetric.bloodOxygen.identityTint(), .secondary)
    }

    /// Every detail route and About page maps to a real metric identity, so a
    /// sheet cannot disagree with the card that opened it.
    func testEveryDetailRouteAndAboutPageResolvesToAnIdentity() {
        for kind in AtriaMetricDetailKind.allCases {
            XCTAssertFalse(kind.identitySystemImage.isEmpty,
                           "\(kind) has no identity glyph")
        }
        for about in AtriaAboutMetric.allCases {
            XCTAssertFalse(about.identity.systemImage.isEmpty)
        }
    }

    /// The battery ladder existed twice, byte-identical, in one file.
    func testTheBatteryLadderLivesInExactlyOnePlace() throws {
        let home = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8)
        // Pin the LADDER, not the string: `battery.25percent` is also the
        // semantic "low battery" glyph for connection diagnoses and the
        // low-battery stream states, which are legitimate separate uses. The
        // defect was the level->symbol switch existing twice, and its
        // signature is the `..<13` bucket.
        XCTAssertFalse(home.contains("case ..<13: return \"battery.0percent\""),
                       "the level->symbol ladder must live only in "
                           + "AtriaBatteryIdentity")
        XCTAssertEqual(AtriaBatteryIdentity.systemImage(percent: 4), "battery.0percent")
        XCTAssertEqual(AtriaBatteryIdentity.systemImage(percent: 50), "battery.50percent")
        XCTAssertEqual(AtriaBatteryIdentity.systemImage(percent: 50, isCharging: true),
                       "battery.100percent.bolt")
    }
}
