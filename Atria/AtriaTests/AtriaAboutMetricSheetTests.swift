import XCTest
@testable import Atria

/// Knowledge slice 5 (2026-08-01): the "About <metric>" education sheets carry
/// real, honest copy. These are content contracts, not view tests -- the pure
/// model is asserted so a future edit can't quietly ship an empty card or drop
/// the canonical unverified-decoder copy.
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

    func testBloodOxygenExplainsItsUnverifiedDecoderWithCanonicalCopy() {
        let spo2 = AtriaAboutMetric.bloodOxygen
        XCTAssertTrue(spo2.showsWhyBlank)
        XCTAssertEqual(spo2.computeCardTitle, "WHY IT'S BLANK")
        // 2026-08-01: the middle card now carries the full "why it's blank"
        // explanation (derived ratio-of-ratios value + the decode-vs-calibrate
        // question) shown when the user taps SpO2, not the compact long form.
        XCTAssertEqual(spo2.computeCardBody, AtriaSpO2Copy.whyBlank)
        // ...and the honesty note carries both canonical short lines verbatim.
        XCTAssertTrue(spo2.honestyNote.contains(AtriaSpO2Copy.wontFakeAPercentage),
                      "SpO2 honesty note must use canonical \"won't fake a percentage\" copy")
        XCTAssertTrue(spo2.honestyNote.contains(AtriaSpO2Copy.decoderNotVerified),
                      "SpO2 honesty note must name the unverified app decoder")
        // Never a fabricated percentage anywhere in the SpO2 copy.
        for text in [spo2.definition, spo2.computeCardBody, spo2.honestyNote] {
            XCTAssertFalse(text.contains("%"), "SpO2 copy must never render a percentage: \(text)")
        }
    }

    // 2026-08-01: SpO2 copy reframed from a strap/hardware limitation to an app
    // limitation — the WHOOP 4 carries the SpO2 sensor (supportsSpO2 == true),
    // Atria just has no validated decoder yet. The honesty invariant (never a
    // fabricated %) is unchanged; only the availability framing moved.
    func testCanonicalSpO2ConstantsUseAppLimitationFraming() {
        XCTAssertEqual(AtriaSpO2Copy.wontFakeAPercentage, "Atria won't fake a percentage.")
        XCTAssertEqual(AtriaSpO2Copy.decoderNotVerified, "Decoder not verified")
        XCTAssertEqual(AtriaSpO2Copy.notAvailableOnThisStrap,
                       "Not available on this strap")
        XCTAssertEqual(AtriaSpO2Copy.longUnavailable,
                       "Atria can't yet produce a validated SpO2 reading from this strap's sensor. Rather than estimate, it leaves this blank — and tells you why.")
        // The supported-strap state names the app limitation and does not imply
        // that simply waiting will make a value appear.
        XCTAssertFalse(AtriaSpO2Copy.decoderNotVerified.localizedCaseInsensitiveContains("strap"))
        XCTAssertFalse(AtriaSpO2Copy.decoderNotVerified.localizedCaseInsensitiveContains("yet"))
        XCTAssertFalse(AtriaSpO2Copy.longUnavailable.contains("can't produce"))
    }

    // Tapping SpO2 opens the About sheet; its "WHY IT'S BLANK" card must explain
    // the real reason — SpO2 is a derived (ratio-of-ratios) value, and the open
    // decode-vs-calibrate question — never a fabricated %.
    func testBloodOxygenAboutSheetExplainsTheDerivedReason() {
        let body = AtriaAboutMetric.bloodOxygen.computeCardBody
        XCTAssertEqual(body, AtriaSpO2Copy.whyBlank)
        XCTAssertTrue(body.contains("ratio of ratios"))
        XCTAssertTrue(body.contains("red versus infrared"))
        XCTAssertTrue(body.lowercased().contains("calibration"))
        XCTAssertFalse(body.contains("%"))
        XCTAssertEqual(AtriaAboutMetric.bloodOxygen.computeCardTitle, "WHY IT'S BLANK")
    }

    func testOnlyUnverifiedExperimentalSignalsUseWhyBlankEducation() {
        XCTAssertTrue(AtriaAboutMetric.bloodOxygen.showsWhyBlank)
        XCTAssertTrue(AtriaAboutMetric.skinTemperature.showsWhyBlank)
        XCTAssertTrue(AtriaAboutMetric.skinTemperature.computeCardBody.contains("has not verified"))
        XCTAssertTrue(AtriaAboutMetric.skinTemperature.honestyNote.contains("Decoder not verified"))

        for metric in AtriaAboutMetric.allCases
            where metric != .bloodOxygen && metric != .skinTemperature {
            XCTAssertFalse(metric.showsWhyBlank, "\(metric) should be a computed metric")
            XCTAssertEqual(metric.computeCardTitle, "HOW ATRIA COMPUTES IT")
        }
    }
}
