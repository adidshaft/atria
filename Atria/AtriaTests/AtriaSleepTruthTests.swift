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
}
