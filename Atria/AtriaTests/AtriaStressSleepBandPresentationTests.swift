import XCTest
import SwiftUI
@testable import Atria

/// Sleep-band presentation (2026-08-20): stress minutes whose stored fact
/// carries `sleepContext == .asleep` render as a dedicated Sleep band
/// (`Metrics.electricSleep`) instead of a Calm / Moderate / High zone color,
/// and the drag-inspection cards, legends, and accessibility labels name it
/// "Sleep". Presentation only — scores are never altered or hidden, so every
/// score-derived aggregate keeps counting these minutes.
final class AtriaStressSleepBandPresentationTests: XCTestCase {
    /// Post-2026-08-06 time base (2026-08-18T00:00:00Z): fixtures anchored
    /// before that date can collide with this host's persisted device-use
    /// journal in integration surfaces, so no new fixture uses them.
    private let base = Date(timeIntervalSince1970: 1_787_011_200)

    private func reading(
        minute: Int,
        score: Double,
        sleep: AtriaPhysiologicalStressModel.SleepContext = .unavailable
    ) -> AtriaStressDetailReading {
        AtriaStressDetailReading(date: base.addingTimeInterval(Double(minute) * 60),
                                 score: score,
                                 sleepContext: sleep)
    }

    // MARK: - Band mapping

    func testAsleepMinuteResolvesToSleepBandRegardlessOfScore() {
        // Sleep is a context classification, not a score band: even a
        // REM-driven 2.8 stays Sleep — that HR rise is not waking stress.
        for score in [0.2, 1.4, 2.8] {
            XCTAssertEqual(
                AtriaStressMinuteBand.resolve(reading(minute: 0, score: score, sleep: .asleep)),
                .sleep,
                "score \(score) while asleep must classify as Sleep"
            )
        }
        XCTAssertEqual(AtriaStressMinuteBand.sleep.displayName, "Sleep")
    }

    func testAwakeAndUnavailableMinutesKeepScoreResolvedZones() {
        XCTAssertEqual(AtriaStressMinuteBand.resolve(reading(minute: 0, score: 0.4, sleep: .awake)),
                       .zone(.calm))
        XCTAssertEqual(AtriaStressMinuteBand.resolve(reading(minute: 1, score: 1.4)),
                       .zone(.moderate))
        XCTAssertEqual(AtriaStressMinuteBand.resolve(reading(minute: 2, score: 2.4, sleep: .awake)),
                       .zone(.high))
        XCTAssertEqual(AtriaStressMinuteBand.zone(.moderate).displayName, "Moderate")
    }

    func testSleepBandUsesElectricSleepTintAndZonesKeepZoneTints() {
        XCTAssertEqual(AtriaStressMinuteBand.sleep.tint, Metrics.electricSleep)
        XCTAssertEqual(AtriaStressMinuteBand.zone(.calm).tint, Metrics.electricGreen)
        XCTAssertEqual(AtriaStressMinuteBand.zone(.moderate).tint, Metrics.electricYellow)
        XCTAssertEqual(AtriaStressMinuteBand.zone(.high).tint, Metrics.electricRed)
        XCTAssertNotEqual(AtriaStressMinuteBand.sleep.tint,
                          AtriaStressMinuteBand.zone(.high).tint,
                          "the Sleep band must be visually distinct from every stress zone")
    }

    // MARK: - Inspection copy

    func testInspectionScoreLineSaysSleepForAsleepMinutesAndZoneOtherwise() {
        let asleep = reading(minute: 0, score: 2.37, sleep: .asleep)
        let asleepLine = AtriaStressMinuteBand.scoreLine(asleep)
        // The numeric score stays visible (no suppression), formatted exactly
        // as the awake variant formats it; only the classification word moves.
        let expectedScore = 2.37.formatted(.number.precision(.fractionLength(2)))
        XCTAssertEqual(asleepLine, "\(expectedScore) · Sleep")

        let awake = reading(minute: 1, score: 2.37, sleep: .awake)
        XCTAssertEqual(AtriaStressMinuteBand.scoreLine(awake), "\(expectedScore) · High")

        let unavailable = reading(minute: 2, score: 1.02)
        let moderateScore = 1.02.formatted(.number.precision(.fractionLength(2)))
        XCTAssertEqual(AtriaStressMinuteBand.scoreLine(unavailable),
                       "\(moderateScore) · Moderate")
    }

    func testScoreOnlyScoreLineOverloadMatchesTheReadingAuthority() {
        // Activity's day-chart scrub card carries only the recorded score and
        // confirmed-sleep membership; its line must be byte-identical to what
        // the full reading would produce (2026-08-29 shared scrub grammar).
        let asleep = reading(minute: 0, score: 2.37, sleep: .asleep)
        XCTAssertEqual(AtriaStressMinuteBand.scoreLine(score: 2.37, isAsleep: true),
                       AtriaStressMinuteBand.scoreLine(asleep))
        let awake = reading(minute: 1, score: 1.4, sleep: .awake)
        XCTAssertEqual(AtriaStressMinuteBand.scoreLine(score: 1.4, isAsleep: false),
                       AtriaStressMinuteBand.scoreLine(awake))
        XCTAssertEqual(AtriaStressMinuteBand.scoreLine(score: 0.4, isAsleep: false),
                       "\(0.4.formatted(.number.precision(.fractionLength(2)))) · Calm")
    }

    // MARK: - Legend gating

    func testSleepLegendEntryGatesOnVisibleSleepMinutes() {
        XCTAssertFalse(AtriaStressMinuteBand.containsSleepMinutes([]))
        XCTAssertFalse(AtriaStressMinuteBand.containsSleepMinutes([
            reading(minute: 0, score: 0.4, sleep: .awake),
            reading(minute: 1, score: 1.4),
        ]), "awake / unavailable-only windows must not grow a Sleep legend entry")
        XCTAssertTrue(AtriaStressMinuteBand.containsSleepMinutes([
            reading(minute: 0, score: 0.4, sleep: .awake),
            reading(minute: 1, score: 0.5, sleep: .asleep),
        ]))
    }

    // MARK: - Accessibility strings

    func testVitalsTimelineAccessibilityNamesTheSleepBandOnlyWhenPresent() {
        let without = AtriaVitalsStressTimelineCopy.accessibilityLabel(containsSleep: false)
        XCTAssertEqual(without, AtriaVitalsStressTimelineCopy.accessibilityLabel)
        XCTAssertFalse(without.contains("Sleep band"))

        let with = AtriaVitalsStressTimelineCopy.accessibilityLabel(containsSleep: true)
        XCTAssertTrue(with.hasPrefix(AtriaVitalsStressTimelineCopy.accessibilityLabel),
                      "the sleep sentence extends the zone grammar, never replaces it")
        XCTAssertTrue(with.contains(AtriaStressMinuteBand.accessibilityDisclosure))
        XCTAssertTrue(with.contains("High is 2 to 3"),
                      "zone scale copy must survive the sleep disclosure")
    }

    func testVitalsScaleRowAccessibilityNamesTheSleepBandOnlyWhenPresent() {
        let without = AtriaVitalsStressTimelineCopy.scaleAccessibilityLabel(containsSleep: false)
        XCTAssertTrue(without.contains("Calm from 0 to 1"))
        XCTAssertFalse(without.contains("Sleep band"))

        let with = AtriaVitalsStressTimelineCopy.scaleAccessibilityLabel(containsSleep: true)
        XCTAssertTrue(with.contains("High from 2 to 3"))
        XCTAssertTrue(with.contains(AtriaStressMinuteBand.accessibilityDisclosure))
    }

    func testAccessibilityDisclosureNamesTheBandSleepAndStaysHonest() {
        let disclosure = AtriaStressMinuteBand.accessibilityDisclosure
        XCTAssertTrue(disclosure.contains("Sleep band"))
        XCTAssertTrue(disclosure.localizedCaseInsensitiveContains("confirmed sleep"),
                      "the band claims confirmed sleep, never a live guess (#30 stays open)")
        XCTAssertFalse(disclosure.localizedCaseInsensitiveContains("no stress"),
                       "the disclosure reclassifies rendering; it must not deny the measured score")
    }

    // MARK: - Aggregates stay truthful

    func testScoreAggregatesStillCountSleepMinutes() {
        // 15 elevated minutes, all confirmed sleep: the Sleep band changes the
        // visual classification only — elevated-window evidence is computed
        // from scores and must EXCLUDE nothing.
        let readings = (0..<15).map {
            reading(minute: $0, score: 2.4, sleep: .asleep)
        }
        let evidence = AtriaStressElevatedEvidence.analyze(readings)
        XCTAssertTrue(evidence.isSupported)
        XCTAssertEqual(evidence.windows.count, 1)
        XCTAssertEqual(evidence.windows.first?.readingCount, 15,
                       "sleep minutes stay inside score-derived aggregates")
    }

    func testSleepClassificationNeverMutatesTheReadingScore() {
        let scored = reading(minute: 0, score: 1.73, sleep: .asleep)
        XCTAssertEqual(scored.score, 1.73, accuracy: 1e-12,
                       "presentation classification must leave the stored score byte-identical")
        XCTAssertEqual(scored.sleepContext, .asleep)
    }
}
