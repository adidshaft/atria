import XCTest
import SwiftUI
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
        // The score is complete for the evidence it used; name the actual
        // provenance instead of implying that the numeric result is pending.
        // Migrated 2026-07-31 (device review): "RHR-only" was developer
        // shorthand; the marker now names the evidence in plain words.
        XCTAssertEqual(presentation.marker, "resting HR")
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
        XCTAssertEqual(presentation.marker, "estimate")
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
        XCTAssertEqual(presentation.marker, "estimate")
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

    /// The status line falls back to `shortLabel` whenever a metric is confident
    /// enough to need no marker, so these are subject to the same width contract.
    /// The raw confidence names they replace ("personal baseline") are 17
    /// characters and would wrap.
    func testEveryShortLabelIsShortEnoughToNeverWrap() {
        for level in AtriaMetricConfidenceLevel.allCases {
            XCTAssertLessThanOrEqual(level.shortLabel.count, 14,
                                     "short label too long: \(level.shortLabel)")
            XCTAssertFalse(level.shortLabel.isEmpty,
                           "status line must never be blank for \(level)")
        }
    }

    /// Recovery carried from a previous sleep must say so even at high
    /// confidence -- otherwise a stale-looking number gets no explanation at all.
    func testCarryOverMarkerOutranksHighConfidenceSilence() {
        let presentation = AtriaCompactMetricPresentation.recovery(
            percent: 88,
            confidence: .validated,
            usesHRV: true,
            isProvisional: false,
            isFromPreviousSleep: true
        )

        XCTAssertEqual(presentation.level, .high)
        XCTAssertEqual(presentation.marker, "prev. sleep")
    }

    // MARK: - Expanded detail provenance

    private func provenance(
        displayValue: String = "75%",
        level: AtriaMetricConfidenceLevel = .limited,
        isLowerBound: Bool = false,
        usesHRV: Bool? = true,
        hrCoverageFraction: Double? = nil,
        sourceLabel: String = "strap",
        observedAt: Date? = nil,
        valueStatusTint: Color? = nil
    ) -> AtriaMetricProvenance {
        AtriaMetricProvenance(displayValue: displayValue,
                              level: level,
                              isLowerBound: isLowerBound,
                              usesHRV: usesHRV,
                              hrCoverageFraction: hrCoverageFraction,
                              sourceLabel: sourceLabel,
                              observedAt: observedAt,
                              valueStatusTint: valueStatusTint)
    }

    func testCoverageTextRoundsToWholePercent() {
        XCTAssertEqual(provenance(hrCoverageFraction: 0.68).coverageText, "HR coverage 68%")
        XCTAssertEqual(provenance(hrCoverageFraction: 1.0).coverageText, "HR coverage 100%")
        XCTAssertEqual(provenance(hrCoverageFraction: 0.0).coverageText, "HR coverage 0%")
    }

    /// Absence must read as "not measured", never as zero. Day-level gap counts
    /// genuinely do not exist, so nothing may synthesise them.
    func testUnmeasuredCoverageProducesNoTextRatherThanZero() {
        XCTAssertNil(provenance(hrCoverageFraction: nil).coverageText)
    }

    func testLowerBoundReasonOutranksEverythingElse() {
        let detail = provenance(level: .provisional, isLowerBound: true, usesHRV: false)

        XCTAssertEqual(detail.reducedConfidenceReason,
                       "Strap wear covered only part of the day, so accumulated load is a floor, not a total.")
        XCTAssertEqual(detail.improvementHint, "Wear the strap for more of the day.")
    }

    func testMissingHRVIsExplainedConcretely() {
        let detail = provenance(level: .limited, usesHRV: false)

        XCTAssertEqual(detail.reducedConfidenceReason,
                       "HRV was not available for this score, so it was computed from resting heart rate alone.")
        XCTAssertNotNil(detail.improvementHint)
    }

    func testHighConfidenceExplainsNothingAndAsksForNothing() {
        let detail = provenance(level: .high, usesHRV: true)

        XCTAssertNil(detail.reducedConfidenceReason)
        XCTAssertNil(detail.improvementHint)
    }

    /// Anything below high confidence owes the user both a reason and a way out.
    func testEveryReducedLevelStatesAReasonAndAnImprovement() {
        for level in AtriaMetricConfidenceLevel.allCases where level != .high {
            let detail = provenance(level: level, usesHRV: true)
            XCTAssertNotNil(detail.reducedConfidenceReason, "no reason for \(level)")
            XCTAssertNotNil(detail.improvementHint, "no improvement path for \(level)")
        }
    }

    // MARK: - Status colour

    /// Confidence answers "how far can I trust this", which is a different axis
    /// from "is this number good". Red belongs to a genuinely poor measured
    /// value; reusing it for low confidence would read as "your recovery is bad"
    /// when it means "we are less sure of it".
    func testConfidenceStatusNeverBorrowsTheRedReservedForPoorValues() {
        for level in AtriaMetricConfidenceLevel.allCases {
            XCTAssertNotEqual(level.statusTint, AtriaMetricZoneLevel.red.tint,
                              "\(level) must not claim the poor-value colour")
        }
    }

    func testTrustedConfidenceReadsGreenAndCaveatedReadsAmber() {
        XCTAssertEqual(AtriaMetricConfidenceLevel.high.statusTint, AtriaMetricZoneLevel.green.tint)
        XCTAssertEqual(AtriaMetricConfidenceLevel.moderate.statusTint, AtriaMetricZoneLevel.green.tint)
        XCTAssertEqual(AtriaMetricConfidenceLevel.limited.statusTint, AtriaMetricZoneLevel.yellow.tint)
        XCTAssertEqual(AtriaMetricConfidenceLevel.provisional.statusTint, AtriaMetricZoneLevel.yellow.tint)
    }

    /// The documented honesty guard: an ungraded value must stay neutral.
    /// Painting a colour around a number with no standing asserts one it has not
    /// earned -- the same reason the recovery hero goes grey around "--".
    func testAnUngradedValueCarriesNoStatusColour() {
        XCTAssertNil(provenance(displayValue: AtriaCompactMetricPresentation.noValue).valueStatusTint,
                     "a value with no grade must render neutral, never green")
    }

    func testAGradedValueKeepsItsZoneColour() {
        let graded = provenance(valueStatusTint: AtriaMetricZoneLevel.red.tint)

        XCTAssertEqual(graded.valueStatusTint, AtriaMetricZoneLevel.red.tint,
                       "a genuinely poor value must still be able to read red")
    }

    /// Source-text pin: the builders must keep withholding the zone while a
    /// metric has no standing to be graded.
    func testBuildersWithholdStatusColourFromUngradedMetrics() throws {
        let today = try source("Atria/AtriaTodayScreen.swift")

        XCTAssertTrue(today.contains("displayHero.recoveryEstimate.percent == nil"),
                      "recovery must withhold its zone while there is no score")
        XCTAssertTrue(today.contains("|| isPendingHeroValue(displayHero.strainValue))"),
                      "strain must withhold its zone while incomplete or pending")
    }

    // MARK: - Wiring

    /// The model and its rendering are both covered, but nothing guarded the
    /// wiring BETWEEN them. If a future edit drops the `provenance:` argument at
    /// the call site, or removes the card from a metric case, every other test
    /// here still passes and the expanded detail silently loses the section it
    /// exists for. These are source-text pins in the same idiom the project
    /// already uses (see AtriaStrainDetailPresentationTests).
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTodayPassesProvenanceIntoTheDetailSheet() throws {
        let today = try source("Atria/AtriaTodayScreen.swift")

        XCTAssertTrue(today.contains("provenance: provenance(for: detail)"),
                      "the detail sheet must still be handed provenance")
        XCTAssertTrue(today.contains("private func provenance(for detail: AtriaMetricDetailKind) -> AtriaMetricProvenance?"),
                      "the builder must still exist")
    }

    /// Strain is the metric whose confidence is derived from measured day wear,
    /// so its coverage row is the one that must not quietly go missing.
    func testStrainProvenanceCarriesMeasuredCoverage() throws {
        let today = try source("Atria/AtriaTodayScreen.swift")

        XCTAssertTrue(today.contains("hrCoverageFraction: displayHero.dayWearCoverageFraction"),
                      "strain provenance must report real measured coverage")
    }

    /// Recovery is scored from the night, not day-long wear, and strain takes no
    /// HRV input. Both nils are deliberate: an absent row means "not measured at
    /// this scope" rather than zero, and pinning them stops either being
    /// "helpfully" filled in later with a fabricated value.
    func testDeliberateNilsAreNotQuietlyFilledIn() throws {
        let today = try source("Atria/AtriaTodayScreen.swift")

        XCTAssertTrue(today.contains("hrCoverageFraction: nil"),
                      "recovery must not claim day wear coverage it does not use")
        XCTAssertTrue(today.contains("usesHRV: nil"),
                      "strain must not claim an HRV contribution it never had")
    }

    /// "Timestamp/source of the underlying data" is part of the expanded-detail
    /// contract. Recovery has a real one -- the end of the night it was computed
    /// from -- so it must be reported rather than left blank.
    func testRecoveryProvenanceReportsTheNightItCameFrom() throws {
        let today = try source("Atria/AtriaTodayScreen.swift")

        XCTAssertTrue(today.contains("observedAt: latestDisplaySleep?.end"),
                      "recovery must stamp the night its score came from")
    }

    /// Strain has no exposed last-accepted-sample time. Stamping it with Date()
    /// would report when the sheet was drawn, not when the data was observed --
    /// a render time dressed as provenance. Absent is the honest claim, so pin it.
    func testStrainProvenanceDoesNotInventARenderTimestamp() throws {
        let today = try source("Atria/AtriaTodayScreen.swift")

        XCTAssertFalse(today.contains("observedAt: Date()"),
                       "a render time must never be presented as observation time")
    }

    func testBothProvenanceMetricsStillRenderTheCard() throws {
        let overview = try source("Atria/AtriaOverviewSections.swift")
        // Call form changed when the card was extracted from three private
        // methods on the sheet into its own view. The pin caught that drift, as
        // intended -- it just happened to be my own drift.
        let occurrences = overview
            .components(separatedBy: "AtriaMetricProvenanceCard(provenance: provenance)")
            .count - 1

        XCTAssertEqual(occurrences, 2,
                       "recovery and strain must each still render the provenance card")
        XCTAssertTrue(overview.contains("provenance: AtriaMetricProvenance? = nil"),
                      "the sheet must still accept provenance")
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
