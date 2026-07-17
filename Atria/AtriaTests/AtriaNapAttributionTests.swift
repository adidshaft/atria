import XCTest
@testable import Atria

final class AtriaNapAttributionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2032, month: 7, day: day, hour: hour))!
    }

    private func night(id: String,
                       day: Date,
                       start: Date,
                       end: Date,
                       source: String) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: calendar.startOfDay(for: day),
                                   start: start,
                                   end: end,
                                   duration: end.timeIntervalSince(start),
                                   restingHR: 52,
                                   hrv: 45,
                                   respiratoryRate: 14,
                                   sleepEfficiency: 0.9,
                                   confidence: "manual_user_entered",
                                   source: source,
                                   confirmed: true,
                                   stageSegments: [])
    }

    func testNapCreditsNextMainSleepInsteadOfItsCivilDay() {
        let priorMain = night(id: "prior-main",
                              day: date(6, 7),
                              start: date(5, 23),
                              end: date(6, 7),
                              source: "manual_sleep")
        let beforeBedNap = night(id: "before-bed-nap",
                                 day: date(6, 16),
                                 start: date(6, 15),
                                 end: date(6, 16),
                                 source: "manual_nap")
        let nextMain = night(id: "next-main",
                             day: date(7, 7),
                             start: date(6, 23),
                             end: date(7, 7),
                             source: "manual_sleep")
        let afterWakeNap = night(id: "after-wake-nap",
                                 day: date(7, 15),
                                 start: date(7, 14),
                                 end: date(7, 15),
                                 source: "manual_nap")
        let snapshot = SleepHistorySnapshot(nights: [afterWakeNap, nextMain, beforeBedNap, priorMain],
                                            confirmedCount: 4,
                                            candidateCount: 0)

        let byMorning = SessionStore.napHoursByMorningDay(sleep: snapshot, calendar: calendar)

        XCTAssertEqual(byMorning[calendar.startOfDay(for: date(7, 7))], 1)
        XCTAssertNil(byMorning[calendar.startOfDay(for: date(6, 7))],
                     "Tuesday's nap must not retroactively improve Tuesday morning")
    }
}
