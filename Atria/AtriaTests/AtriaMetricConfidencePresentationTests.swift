import XCTest
@testable import Atria

/// Contract tests for the deterministic metric presentation model.
///
/// The invariant under test is the one the dashboard kept violating: an
/// available value must survive every confidence downgrade, and "--" must mean
/// "not computable" rather than "uncertain".
final class AtriaMetricConfidencePresentationTests: XCTestCase {

    // MARK: - Numeric value survives reduced confidence

    func testRecoveryKeepsNumericValueAtLimitedConfidence() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 75,
            confidence: .unverified,
            usesHRV: true,
            isProvisional: false,
            isFromPreviousSleep: false
        )

        XCTAssertEqual(presentation.value, "75%")
        XCTAssertTrue(presentation.hasValue)
        XCTAssertEqual(presentation.level, .limited)
        // The caveat lives in the marker, never in place of the number.
        XCTAssertEqual(presentation.marker, "limited")
    }

    func testRecoveryKeepsNumericValueWhenHRVDidNotContribute() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 75,
            confidence: .unverified,
            usesHRV: false,
            isProvisional: false,
            isFromPreviousSleep: false
        )

        XCTAssertEqual(presentation.value, "75%")
        // "HRV pending" outranks the bare level: it names the missing input.
        XCTAssertEqual(presentation.marker, "HRV pending")
    }

    func testRecoveryProvisionalKeepsValueAndIsMarkedProvisional() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 75,
            confidence: .personalBaseline,
            usesHRV: true,
            isProvisional: true,
            isFromPreviousSleep: false
        )

        XCTAssertEqual(presentation.value, "75%")
        XCTAssertEqual(presentation.level, .provisional)
        XCTAssertEqual(presentation.marker, "provisional")
    }

    func testRecoveryAtHighConfidenceSaysNothingExtra() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 91,
            confidence: .validated,
            usesHRV: true,
            isProvisional: false,
            isFromPreviousSleep: false
        )

        XCTAssertEqual(presentation.value, "91%")
        XCTAssertEqual(presentation.level, .high)
        XCTAssertNil(presentation.marker, "a confident number needs no caveat")
    }

    func testRecoveryCarriedFromPreviousSleepExplainsItself() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 62,
            confidence: .personalBaseline,
            usesHRV: true,
            isProvisional: false,
            isFromPreviousSleep: true
        )

        XCTAssertEqual(presentation.value, "62%")
        XCTAssertEqual(presentation.marker, "prev. sleep")
    }

    // MARK: - No-value presentation

    func testRecoveryWithoutPercentIsTheOnlyNoValueBranch() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: nil,
            confidence: .learning,
            usesHRV: false,
            isProvisional: false,
            isFromPreviousSleep: false
        )

        XCTAssertEqual(presentation.value, AtriaCompactMetricPresentation.noValue)
        XCTAssertFalse(presentation.hasValue)
        XCTAssertEqual(presentation.marker, "HRV pending")
    }

    func testNoValueTokenIsTheTwoGlyphDash() {
        XCTAssertEqual(AtriaCompactMetricPresentation.noValue, "--")
    }

    // MARK: - Strain lower bound

    func testPartialStrainKeepsValueAndIsFlaggedAsLowerBound() {
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: 14.8,
            confidence: "local · partial-day wear"
        )

        XCTAssertEqual(presentation.value, "14.8")
        XCTAssertTrue(presentation.isLowerBound)
        XCTAssertEqual(presentation.marker, "lower bound")
        // Sparse wear integrates real load, so the number is a floor -- never a
        // reason to drop it.
        XCTAssertTrue(presentation.hasValue)
    }

    func testLowerBoundValueRendersWithGreaterOrEqualPrefixExactlyOnce() {
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: 14.8,
            confidence: "local · partial-day wear"
        )

        XCTAssertEqual(presentation.displayValue, "≥ 14.8")
    }

    func testCompleteStrainIsAPointEstimate() {
        // Deliberately not a value like 9.25: that is an exact binary tie, and
        // "%.1f" rounds half-to-even, so it formats as "9.2". Picking a non-tie
        // keeps this test about the point-estimate contract rather than about
        // printf's tie-breaking.
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: 9.27,
            confidence: "local"
        )

        XCTAssertEqual(presentation.value, "9.3")
        XCTAssertEqual(presentation.displayValue, "9.3")
        XCTAssertFalse(presentation.isLowerBound)
        XCTAssertNil(presentation.marker)
        XCTAssertEqual(presentation.level, .high)
    }

    func testAgeEstimatedMaxHRDowngradesConfidenceButKeepsTheNumber() {
        let presentation = AtriaCompactMetricPresentation.strain(
            strain: 11.4,
            confidence: "provisional · age-estimated max HR"
        )

        XCTAssertEqual(presentation.value, "11.4")
        XCTAssertEqual(presentation.level, .provisional)
        XCTAssertEqual(presentation.marker, "provisional")
    }

    /// Heart-rate reserve is undefined without a valid rest and max, so there is
    /// genuinely no number here -- this is the not-computable case, not a
    /// withheld value.
    func testStrainWithoutHeartRateReserveHasNoComputableValue() {
        for confidence in ["learning", "standby"] {
            let presentation = AtriaCompactMetricPresentation.strain(
                strain: 0,
                confidence: confidence
            )

            XCTAssertEqual(presentation.value,
                           AtriaCompactMetricPresentation.noValue,
                           "confidence: \(confidence)")
            XCTAssertEqual(presentation.marker, "HR pending", "confidence: \(confidence)")
            XCTAssertFalse(presentation.isLowerBound, "confidence: \(confidence)")
        }
    }

    func testStrainEvidenceParsingIsCaseInsensitive() {
        let evidence = AtriaCompactMetricPresentation.StrainEvidence.parse(
            confidence: "PROVISIONAL · AGE-ESTIMATED MAX HR · PARTIAL-DAY WEAR"
        )

        XCTAssertTrue(evidence.isComputable)
        XCTAssertTrue(evidence.isPartial)
        XCTAssertTrue(evidence.isAgeEstimatedMaxHR)
    }

    // MARK: - Fixed-height guarantee

    /// Card height is only stable if the status line can never wrap, so every
    /// marker the model can emit has to stay short. This is the machine-checked
    /// half of the "equal compact-card heights" requirement.
    func testEveryMarkerIsShortEnoughToNeverWrap() {
        var markers: [String?] = []

        for confidence in [Metrics.RecoveryEstimate.Confidence.learning,
                           .unverified,
                           .personalBaseline,
                           .validated] {
            for usesHRV in [true, false] {
                for isProvisional in [true, false] {
                    for fromPrevious in [true, false] {
                        for percent in [nil, 0, 50, 100] as [Int?] {
                            markers.append(AtriaCompactMetricPresentation.recovery(
                                percent: percent,
                                confidence: confidence,
                                usesHRV: usesHRV,
                                isProvisional: isProvisional,
                                isFromPreviousSleep: fromPrevious
                            ).marker)
                        }
                    }
                }
            }
        }

        for confidence in ["learning", "standby", "local",
                           "local · partial-day wear",
                           "provisional · age-estimated max HR",
                           "provisional · age-estimated max HR · partial sparse HR"] {
            markers.append(AtriaCompactMetricPresentation.strain(
                strain: 12.0,
                confidence: confidence
            ).marker)
        }

        XCTAssertFalse(markers.isEmpty)
        for marker in markers.compactMap({ $0 }) {
            XCTAssertLessThanOrEqual(marker.count, 14, "marker too long to fit one line: \(marker)")
            XCTAssertFalse(marker.contains("\n"), "marker must be single-line: \(marker)")
        }
    }

    // MARK: - Canonical pending check

    /// The regression this collapse was built to prevent: a producer moving off
    /// the word "Learning" onto "--" must not start reading as a real value.
    func testPendingCheckAcceptsEveryNotReadyToken() {
        for token in ["--", "\u{2014}", "Learning", "Building", "Preparing",
                      "learning", "  Learning  ", "", "   "] {
            XCTAssertTrue(AtriaCompactMetricPresentation.isPendingValue(token),
                          "should be pending: '\(token)'")
        }
    }

    func testPendingCheckDoesNotSwallowRealMeasurements() {
        for token in ["75%", "14.8", "≥ 14.8", "9.3", "42 ms", "8h 12m", "0", "0%"] {
            XCTAssertFalse(AtriaCompactMetricPresentation.isPendingValue(token),
                           "should be a real value: '\(token)'")
        }
    }

    func testEveryNoValuePresentationIsRecognisedAsPending() {
        let recovery = AtriaCompactMetricPresentation.recovery(
            percent: nil,
            confidence: .learning,
            usesHRV: false,
            isProvisional: false,
            isFromPreviousSleep: false
        )
        let strain = AtriaCompactMetricPresentation.strain(strain: 0, confidence: "learning")

        XCTAssertTrue(AtriaCompactMetricPresentation.isPendingValue(recovery.value))
        XCTAssertTrue(AtriaCompactMetricPresentation.isPendingValue(strain.value))
    }

    func testEveryComputedPresentationIsNotPending() {
        let recovery = AtriaCompactMetricPresentation.recovery(
            percent: 75,
            confidence: .unverified,
            usesHRV: false,
            isProvisional: true,
            isFromPreviousSleep: false
        )
        let strain = AtriaCompactMetricPresentation.strain(
            strain: 14.8,
            confidence: "local · partial-day wear"
        )

        XCTAssertFalse(AtriaCompactMetricPresentation.isPendingValue(recovery.value))
        XCTAssertFalse(AtriaCompactMetricPresentation.isPendingValue(strain.value))
        XCTAssertFalse(AtriaCompactMetricPresentation.isPendingValue(strain.displayValue))
    }
}
