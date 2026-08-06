import XCTest
@testable import Atria

final class AtriaMetricTruthGateTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sleepNight(
        id: String,
        start: Date,
        end: Date,
        respiratoryRate: Double?,
        source: String = "auto_confirmed_sleep",
        confirmed: Bool = true
    ) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(
            id: id,
            day: utcCalendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: end.timeIntervalSince(start),
            restingHR: 54,
            hrv: 60,
            hrvWindowCount: 4,
            respiratoryRate: respiratoryRate,
            sleepEfficiency: 0.9,
            confidence: confirmed ? "high" : "review_needed",
            source: source,
            confirmed: confirmed,
            stageSegments: [],
            eventTimeZoneIdentifier: "UTC"
        )
    }

    func testUnvalidatedSkinTemperatureCandidateNeverBecomesAHealthReading() {
        let unvalidatedCandidate = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: 1.7,
            baselineSessions: 5,
            candidateFrames: 84,
            candidateValues: 12
        )

        let projected = SessionStore.skinTemperatureDeviationSummary(
            finalizedDeviationCelsius: 0.4,
            fallback: unvalidatedCandidate,
            validatedSource: false
        )

        XCTAssertNil(projected.latestDeltaCelsius)
        XCTAssertFalse(projected.isReady)
        XCTAssertEqual(projected.valueText, "--")
        XCTAssertEqual(projected.baselineSessions, 0)
        XCTAssertEqual(projected.candidateFrames, 84)
        XCTAssertEqual(projected.candidateValues, 12)
        XCTAssertNil(Metrics.skinTemperatureDeviationZone(projected,
                                                          decoderAvailable: false))
    }

    func testValidatedSkinTemperatureUsesOnlyFinalizedDeviation() {
        let candidate = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: 1.7,
            baselineSessions: 2,
            candidateFrames: 84,
            candidateValues: 12
        )

        let projected = SessionStore.skinTemperatureDeviationSummary(
            finalizedDeviationCelsius: 0.4,
            fallback: candidate,
            validatedSource: true
        )

        XCTAssertEqual(projected.latestDeltaCelsius, 0.4)
        XCTAssertTrue(projected.isReady)
        XCTAssertEqual(projected.baselineSessions, 2)
        XCTAssertEqual(projected.candidateFrames, 84)
        XCTAssertEqual(projected.candidateValues, 12)
    }

    func testValidatedSkinTemperatureDoesNotInventCompactedBaselineCount() {
        let compacted = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: nil,
            baselineSessions: 0,
            candidateFrames: 84,
            candidateValues: 12
        )

        let projected = SessionStore.skinTemperatureDeviationSummary(
            finalizedDeviationCelsius: 0.4,
            fallback: compacted,
            validatedSource: true
        )

        XCTAssertEqual(projected.latestDeltaCelsius, 0.4)
        XCTAssertEqual(projected.baselineSessions, 0)
        XCTAssertEqual(
            projected.footnoteText,
            "Relative sleep-only deviation from a persisted qualified sleep baseline; no absolute temperature."
        )
    }

    func testExperimentalRespirationUsesOneCurrentConfirmedMainSleepForValueAndZone() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let mainEnd = now.addingTimeInterval(-60 * 60)
        let main = sleepNight(
            id: "current-main",
            start: mainEnd.addingTimeInterval(-8 * 60 * 60),
            end: mainEnd,
            respiratoryRate: 14.6
        )
        let review = sleepNight(
            id: "newer-review",
            start: now.addingTimeInterval(-2 * 60 * 60),
            end: now.addingTimeInterval(-10 * 60),
            respiratoryRate: 22.4,
            source: "sleep_episode_review",
            confirmed: false
        )
        let nap = sleepNight(
            id: "newer-nap",
            start: now.addingTimeInterval(-3 * 60 * 60),
            end: now.addingTimeInterval(-2 * 60 * 60),
            respiratoryRate: 21.2,
            source: "manual_nap"
        )
        let priorMains = (1...3).map { offset in
            let end = main.start!.addingTimeInterval(-Double(offset) * 24 * 60 * 60)
            return sleepNight(
                id: "prior-\(offset)",
                start: end.addingTimeInterval(-8 * 60 * 60),
                end: end,
                respiratoryRate: 14.0
            )
        }
        let snapshot = SleepHistorySnapshot(
            nights: [review, nap, main] + priorMains,
            confirmedCount: 5,
            candidateCount: 1
        )

        let presentation = AtriaExperimentalRespiratoryRatePresentation.resolve(
            snapshot: snapshot,
            now: now,
            calendar: utcCalendar,
            greenDelta: 1.5,
            yellowDelta: 3
        )

        XCTAssertEqual(presentation.sourceID, main.id)
        XCTAssertEqual(presentation.value, main.respiratoryRate)
        XCTAssertEqual(presentation.valueText, main.respiratoryRateText)
        XCTAssertEqual(presentation.state, .research)
        XCTAssertEqual(
            presentation.zone,
            Metrics.respiratoryRateZone(
                main.respiratoryRate,
                baseline: snapshot.respiratoryBaselineMean,
                baselineSamples: snapshot.respiratoryBaselineCount,
                greenDelta: 1.5,
                yellowDelta: 3
            )
        )
        XCTAssertEqual(
            presentation.detail,
            "Current confirmed main sleep · compared with your sleep baseline."
        )
    }

    func testExperimentalRespirationRejectsReviewNapAndStaleMainSleep() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let staleEnd = now.addingTimeInterval(-(25 * 60 * 60))
        let staleMain = sleepNight(
            id: "stale-main",
            start: staleEnd.addingTimeInterval(-8 * 60 * 60),
            end: staleEnd,
            respiratoryRate: 14.2
        )
        let review = sleepNight(
            id: "fresh-review",
            start: now.addingTimeInterval(-3 * 60 * 60),
            end: now.addingTimeInterval(-30 * 60),
            respiratoryRate: 18.8,
            source: "sleep_episode_review",
            confirmed: false
        )
        let nap = sleepNight(
            id: "fresh-nap",
            start: now.addingTimeInterval(-2 * 60 * 60),
            end: now.addingTimeInterval(-60 * 60),
            respiratoryRate: 19.4,
            source: "manual_nap"
        )
        let snapshot = SleepHistorySnapshot(
            nights: [review, nap, staleMain],
            confirmedCount: 2,
            candidateCount: 1
        )

        let presentation = AtriaExperimentalRespiratoryRatePresentation.resolve(
            snapshot: snapshot,
            now: now,
            calendar: utcCalendar,
            greenDelta: 1.5,
            yellowDelta: 3
        )

        XCTAssertNil(presentation.sourceID)
        XCTAssertNil(presentation.value)
        XCTAssertEqual(presentation.valueText, "--")
        XCTAssertEqual(presentation.state, .learning)
        XCTAssertNil(presentation.zone)
        XCTAssertEqual(presentation.detail, "Needs a current confirmed main sleep.")
    }

    func testExperimentalRespirationDoesNotBorrowReviewValueWhenCurrentMainIsUnqualified() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let mainEnd = now.addingTimeInterval(-60 * 60)
        let main = sleepNight(
            id: "current-main-without-respiration",
            start: mainEnd.addingTimeInterval(-8 * 60 * 60),
            end: mainEnd,
            respiratoryRate: nil
        )
        let review = sleepNight(
            id: "review-with-respiration",
            start: now.addingTimeInterval(-3 * 60 * 60),
            end: now.addingTimeInterval(-20 * 60),
            respiratoryRate: 20.1,
            source: "sleep_episode_review",
            confirmed: false
        )
        let snapshot = SleepHistorySnapshot(
            nights: [review, main],
            confirmedCount: 1,
            candidateCount: 1
        )

        let presentation = AtriaExperimentalRespiratoryRatePresentation.resolve(
            snapshot: snapshot,
            now: now,
            calendar: utcCalendar,
            greenDelta: 1.5,
            yellowDelta: 3
        )

        XCTAssertEqual(presentation.sourceID, main.id)
        XCTAssertNil(presentation.value)
        XCTAssertEqual(presentation.state, .learning)
        XCTAssertNil(presentation.zone)
        XCTAssertEqual(
            presentation.detail,
            "Current confirmed main sleep has no qualified respiratory rate."
        )
    }
}
