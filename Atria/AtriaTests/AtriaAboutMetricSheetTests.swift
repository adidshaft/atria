import XCTest
@testable import Atria

/// Knowledge slice 5 (2026-08-01): the "About <metric>" education sheets carry
/// real, honest copy. These are content contracts, not view tests -- the pure
/// model is asserted so a future edit can't quietly ship an empty card or drop
/// the canonical hardware-unavailable copy.
final class AtriaAboutMetricSheetTests: XCTestCase {
    func testEveryMetricHasNonEmptyEducationCopy() {
        for metric in AtriaAboutMetric.allCases {
            XCTAssertFalse(metric.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(metric) title is empty")
            XCTAssertFalse(metric.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(metric) definition is empty")
            XCTAssertFalse(metric.computeCardBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(metric) compute card body is empty")
            XCTAssertFalse(metric.honestyNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(metric) honesty note is empty")
            XCTAssertFalse(metric.computeCardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(metric) compute card title is empty")
            XCTAssertFalse(metric.glyph.isEmpty, "\(metric) glyph is empty")
        }
    }

    func testComputedMetricsUsePlainLanguageNotLabJargon() {
        // Mirrors the static-gate honesty rule: end-user education copy must not
        // leak lab-only shorthand. Keep this in step with the app-wide ban list.
        let banned = ["RMSSD", "lnRMSSD", "RR interval", "artifact", "IMU", "telemetry"]
        for metric in AtriaAboutMetric.allCases {
            let corpus = [metric.definition, metric.computeCardBody, metric.honestyNote]
                .joined(separator: " ")
            for term in banned {
                // Word-boundary match, mirroring the static gate — a substring
                // check would false-positive on words like "maximum" (imu).
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
                let hit = corpus.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                XCTAssertFalse(hit, "\(metric) copy leaks lab jargon: \(term)")
            }
        }
    }

    func testBloodOxygenIsHardwareUnavailableWithCanonicalCopy() {
        let spo2 = AtriaAboutMetric.bloodOxygen
        XCTAssertTrue(spo2.isHardwareUnavailable)
        XCTAssertEqual(spo2.computeCardTitle, "WHY IT'S BLANK")
        // The middle card carries the canonical long-form unavailable copy...
        XCTAssertEqual(spo2.computeCardBody, AtriaSpO2Copy.longUnavailable)
        // ...and the honesty note carries both canonical short lines verbatim.
        XCTAssertTrue(spo2.honestyNote.contains(AtriaSpO2Copy.wontFakeAPercentage),
                      "SpO2 honesty note must use canonical \"won't fake a percentage\" copy")
        XCTAssertTrue(spo2.honestyNote.contains(AtriaSpO2Copy.notAvailableOnStrap),
                      "SpO2 honesty note must use canonical \"not available on this strap\" copy")
        // Never a fabricated percentage anywhere in the SpO2 copy.
        for text in [spo2.definition, spo2.computeCardBody, spo2.honestyNote] {
            XCTAssertFalse(text.contains("%"), "SpO2 copy must never render a percentage: \(text)")
        }
    }

    func testCanonicalSpO2ConstantsMatchDesign() {
        XCTAssertEqual(AtriaSpO2Copy.wontFakeAPercentage, "Atria won't fake a percentage.")
        XCTAssertEqual(AtriaSpO2Copy.notAvailableOnStrap, "Not available on this strap.")
        XCTAssertEqual(AtriaSpO2Copy.longUnavailable,
                       "This strap's sensor can't produce a validated SpO2 reading. Rather than estimate, Atria leaves it blank — and tells you why.")
    }

    func testOnlyBloodOxygenIsHardwareUnavailable() {
        for metric in AtriaAboutMetric.allCases where metric != .bloodOxygen {
            XCTAssertFalse(metric.isHardwareUnavailable, "\(metric) should be a computed metric")
            XCTAssertEqual(metric.computeCardTitle, "HOW ATRIA COMPUTES IT")
        }
    }
}
