import XCTest
@testable import Atria

final class AtriaSleepTruthTests: XCTestCase {
    private func night(id: String,
                       hours: Double,
                       confirmed: Bool,
                       dayOffset: TimeInterval = 0) -> SleepHistorySnapshot.Night {
        let day = Date(timeIntervalSince1970: 1_800_000_000 + dayOffset)
        let start = day.addingTimeInterval(22 * 60 * 60)
        return SleepHistorySnapshot.Night(id: id,
                                          day: day,
                                          start: start,
                                          end: start.addingTimeInterval(hours * 60 * 60),
                                          duration: hours * 60 * 60,
                                          restingHR: 52,
                                          hrv: confirmed ? 48 : nil,
                                          respiratoryRate: confirmed ? 14.2 : nil,
                                          sleepEfficiency: confirmed ? 0.9 : nil,
                                          confidence: confirmed ? "confirmed" : "candidate",
                                          source: confirmed ? "manual_sleep" : "sleep_candidate",
                                          confirmed: confirmed,
                                          stageSegments: [])
    }

    func testUnconfirmedCandidateCannotBecomeAuthoritativeMainSleep() {
        let candidate = night(id: "candidate", hours: 9, confirmed: false)
        let snapshot = SleepHistorySnapshot(nights: [candidate],
                                            confirmedCount: 0,
                                            candidateCount: 1)

        XCTAssertNil(snapshot.latestMainSleep)
        XCTAssertEqual(snapshot.latestReviewable?.id, candidate.id)
        XCTAssertEqual(snapshot.averageDurationText, "--")
        XCTAssertNil(snapshot.sleepConsistencyPercent)
        XCTAssertEqual(snapshot.sleepBudgetDebtHours(baseNeedHours: 8), 0)
    }

    func testCandidateCannotChangeConfirmedSleepDebtOrAverage() throws {
        let candidate = night(id: "candidate", hours: 2, confirmed: false)
        let confirmed = night(id: "confirmed", hours: 7, confirmed: true, dayOffset: -86_400)
        let snapshot = SleepHistorySnapshot(nights: [candidate, confirmed],
                                            confirmedCount: 1,
                                            candidateCount: 1)

        XCTAssertEqual(snapshot.latestMainSleep?.id, confirmed.id)
        XCTAssertEqual(snapshot.averageDurationText, "7h 0m")
        XCTAssertEqual(snapshot.sleepBudgetDebtHours(baseNeedHours: 8), 1, accuracy: 0.001)
    }

    func testNewestReviewCandidateIsVisibleWithoutBecomingAuthoritative() {
        let candidate = night(id: "candidate", hours: 6, confirmed: false)
        let confirmed = night(id: "confirmed", hours: 7, confirmed: true, dayOffset: -86_400)
        let snapshot = SleepHistorySnapshot(nights: [candidate, confirmed],
                                            confirmedCount: 1,
                                            candidateCount: 1)

        XCTAssertEqual(snapshot.latestDisplayEvidence?.id, candidate.id)
        XCTAssertEqual(snapshot.latestMainSleep?.id, confirmed.id)
        XCTAssertEqual(snapshot.averageDurationText, "7h 0m")
        XCTAssertEqual(snapshot.sleepBudgetDebtHours(baseNeedHours: 8), 1, accuracy: 0.001)
    }

    func testHistoricalConsistencyUsesOnlyNightsAvailableByThatMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2032,
                                               month: 1,
                                               day: day,
                                               hour: hour))!
        }
        func savedNight(id: String,
                        wakeDay: Int,
                        wakeHour: Int,
                        durationHours: Double) -> SleepHistorySnapshot.Night {
            let end = date(wakeDay, wakeHour)
            return SleepHistorySnapshot.Night(
                id: id,
                day: calendar.startOfDay(for: end),
                start: end.addingTimeInterval(-durationHours * 3_600),
                end: end,
                duration: durationHours * 3_600,
                restingHR: 55,
                hrv: nil,
                respiratoryRate: nil,
                sleepEfficiency: 0.9,
                confidence: "confirmed",
                source: "overnight_sleep",
                confirmed: true,
                stageSegments: [],
                eventTimeZoneIdentifier: "UTC"
            )
        }

        let regular = (1...5).map {
            savedNight(id: "regular-\($0)", wakeDay: $0, wakeHour: 8, durationHours: 8)
        }
        let first = regular[0]
        let fifth = regular[4]
        let laterIrregular = savedNight(id: "later", wakeDay: 6, wakeHour: 15, durationHours: 4)
        let snapshot = SleepHistorySnapshot(
            nights: [laterIrregular] + Array(regular.reversed()),
            confirmedCount: 6,
            candidateCount: 0
        )

        XCTAssertNil(snapshot.sleepConsistencyPercent(asOf: first.day,
                                                      calendar: calendar),
                     "one night cannot create historical consistency")
        XCTAssertEqual(snapshot.sleepConsistencyPercent(asOf: fifth.day,
                                                        calendar: calendar),
                       100,
                       "a later irregular night must not rewrite the prior morning")
        XCTAssertEqual(snapshot.sleepConsistencyPercent(asOf: laterIrregular.day,
                                                        calendar: calendar),
                       snapshot.sleepConsistencyPercent)
        XCTAssertLessThan(snapshot.sleepConsistencyPercent ?? 100, 100)
        XCTAssertNil(snapshot.sleepConsistencyPercent(asOf: date(7, 0),
                                                      calendar: calendar),
                     "a no-sleep day must not masquerade as an observed consistency row")
    }

    func testDisplayedDebtMatchesRecencyWeightedSleepNeedLedger() {
        let newest = night(id: "newest", hours: 7, confirmed: true)
        let older = night(id: "older", hours: 4, confirmed: true, dayOffset: -86_400)
        let snapshot = SleepHistorySnapshot(nights: [newest, older],
                                            confirmedCount: 2,
                                            candidateCount: 0)

        // Oldest shortfall: 4h × 0.75 decay; newest shortfall: 1h.
        XCTAssertEqual(snapshot.sleepBudgetDebtHours(baseNeedHours: 8), 4, accuracy: 0.001)
        XCTAssertEqual(snapshot.sleepDebtText(goalHours: 8), "4 h")
        XCTAssertEqual(snapshot.sleepDebtFootnote(goalHours: 8),
                       "Weighted 7-night shortfall vs 8 h goal.")
    }

    func testProductionSnapshotRetainsTwelveWeeksOfCompactSleepHistory() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let sleeps = (0..<100).map { offset -> UserConfirmedSleep in
            let end = reference.addingTimeInterval(-Double(offset) * 86_400)
            let start = end.addingTimeInterval(-7 * 3_600)
            return UserConfirmedSleep(id: "sleep-\(offset)",
                                      createdAt: end,
                                      start: start,
                                      end: end,
                                      source: "manual_sleep",
                                      confidence: "confirmed",
                                      sessions: 1,
                                      samples: 100,
                                      avgHR: 55,
                                      peakHR: 70,
                                      restingHR: 50,
                                      hrv: nil,
                                      hrvWindowCount: nil,
                                      duration: 7 * 3_600,
                                      span: 7 * 3_600,
                                      reason: "fixture",
                                      motionSource: "manual",
                                      motionValidated: false,
                                      stageSegments: nil)
        }

        let snapshot = SleepHistorySnapshot(rollups: [], confirmedSleeps: sleeps)

        XCTAssertEqual(snapshot.nights.count, SleepHistorySnapshot.maximumResidentNightCount)
        XCTAssertEqual(snapshot.nights.first?.id, "sleep-0")
        XCTAssertEqual(snapshot.nights.last?.id, "sleep-83")
    }

    func testConfirmedSleepProjectionPreservesDurableSaveTimestamp() throws {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let savedAt = end.addingTimeInterval(42 * 60)
        let sleep = UserConfirmedSleep(
            id: "saved-night",
            createdAt: savedAt,
            start: end.addingTimeInterval(-7 * 3_600),
            end: end,
            source: "manual_sleep",
            confidence: "confirmed",
            sessions: 1,
            samples: 100,
            avgHR: 55,
            peakHR: 70,
            restingHR: 50,
            hrv: 45,
            hrvWindowCount: 3,
            duration: 7 * 3_600,
            span: 7 * 3_600,
            reason: "fixture",
            motionSource: "manual",
            motionValidated: false,
            stageSegments: nil
        )

        let snapshot = SleepHistorySnapshot(rollups: [], confirmedSleeps: [sleep])

        XCTAssertEqual(try XCTUnwrap(snapshot.latestMainSleep).savedAt, savedAt)
    }

    func testPhysicalResumedSleepCreditsOnlyClassifiedNonAwakeTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        func date(day: Int, hour: Int, minute: Int, second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026,
                                               month: 7,
                                               day: day,
                                               hour: hour,
                                               minute: minute,
                                               second: second))!
        }
        func sleep(id: String,
                   start: Date,
                   end: Date,
                   duration: TimeInterval,
                   source: String,
                   stages: [SleepStageSegment]? = nil) -> UserConfirmedSleep {
            UserConfirmedSleep(id: id,
                               createdAt: end,
                               start: start,
                               end: end,
                               source: source,
                               confidence: "user_confirmed_hr_only",
                               sessions: 2,
                               samples: 1_000,
                               avgHR: 62,
                               peakHR: 85,
                               restingHR: 59,
                               hrv: 38,
                               hrvWindowCount: 3,
                               duration: duration,
                               span: end.timeIntervalSince(start),
                               reason: "physical-regression",
                               motionSource: "user_review",
                               motionValidated: false,
                               stageSegments: stages,
                               eventTimeZoneIdentifier: "Asia/Kolkata")
        }

        let main = sleep(id: "physical-main",
                         start: date(day: 28, hour: 22, minute: 52, second: 49),
                         end: date(day: 29, hour: 6, minute: 14, second: 37),
                         duration: 22_557.396,
                         source: "sleep_review_hr_only")
        let resumedStart = date(day: 29, hour: 12, minute: 19, second: 7)
        let resumedEnd = date(day: 29, hour: 14, minute: 35)
        let resumedSpan = resumedEnd.timeIntervalSince(resumedStart)
        let awakeEnd = resumedStart.addingTimeInterval(3_982)
        let resumed = sleep(
            id: "physical-resumed",
            start: resumedStart,
            end: resumedEnd,
            duration: 7_764,
            source: "resumed_sleep",
            stages: [
                SleepStageSegment(id: "awake",
                                  start: resumedStart,
                                  end: awakeEnd,
                                  stage: .awake),
                SleepStageSegment(id: "sleep",
                                  start: awakeEnd,
                                  end: resumedEnd,
                                  stage: .light)
            ]
        )
        let snapshot = SleepHistorySnapshot(rollups: [],
                                            confirmedSleeps: [main, resumed],
                                            calendar: calendar)
        let combined = try XCTUnwrap(snapshot.latestMainSleep)
        let classifiedResumedSleep = resumedSpan - 3_982

        XCTAssertEqual(resumed.effectiveSleepDuration,
                       classifiedResumedSleep,
                       accuracy: 0.01)
        XCTAssertEqual(combined.duration,
                       main.duration + classifiedResumedSleep,
                       accuracy: 0.01)
        XCTAssertEqual(combined.durationText, "7h 25m")
        XCTAssertEqual(combined.end, resumed.end)
        XCTAssertTrue(
            combined.displayStageSegments.isEmpty,
            "partial stage epochs must not masquerade as a complete breakdown of the 7h25 physiological episode"
        )
        XCTAssertEqual(combined.stageEvidence, .none)
        XCTAssertEqual(
            combined.sleepEfficiency ?? 0,
            combined.duration / resumed.end.timeIntervalSince(main.start),
            accuracy: 0.0001,
            "the long awake separation and resumed wake epochs receive zero sleep credit"
        )
        XCTAssertLessThan(combined.duration,
                          resumed.end.timeIntervalSince(main.start))
    }

    func testCompleteStageTimelineRemainsPresentableWhenItReconcilesWithSleepCredit() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let awakeEnd = start.addingTimeInterval(30 * 60)
        let lightEnd = awakeEnd.addingTimeInterval(3.5 * 3_600)
        let remEnd = lightEnd.addingTimeInterval(1.5 * 3_600)
        let end = remEnd.addingTimeInterval(2 * 3_600)
        let night = SleepHistorySnapshot.Night(
            id: "coherent-stages",
            day: start,
            start: start,
            end: end,
            duration: 7 * 3_600,
            restingHR: 55,
            hrv: 48,
            respiratoryRate: 14,
            sleepEfficiency: 7 / 7.5,
            confidence: "ready",
            source: "validated_sleep_stages",
            confirmed: true,
            stageSegments: [
                SleepStageSegment(id: "awake",
                                  start: start,
                                  end: awakeEnd,
                                  stage: .awake),
                SleepStageSegment(id: "light",
                                  start: awakeEnd,
                                  end: lightEnd,
                                  stage: .light),
                SleepStageSegment(id: "rem",
                                  start: lightEnd,
                                  end: remEnd,
                                  stage: .rem),
                SleepStageSegment(id: "deep",
                                  start: remEnd,
                                  end: end,
                                  stage: .deep),
            ]
        )

        XCTAssertEqual(night.stageEvidence, .validated)
        XCTAssertEqual(night.displayStageSegments.count, 4)
        XCTAssertEqual(night.stageDuration(.awake), 30 * 60, accuracy: 0.01)
        XCTAssertEqual(
            night.displayStageSegments
                .filter { $0.stage != .awake }
                .reduce(0) { $0 + $1.duration },
            night.duration,
            accuracy: 0.01
        )
    }
}
