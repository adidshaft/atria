import XCTest
@testable import Atria

final class AtriaHRVQualificationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func session(dayOffset: Int,
                         source: AtriaRRSourceProvenance?) -> SavedSession {
        let day = calendar.date(byAdding: .day,
                                value: dayOffset,
                                to: Date(timeIntervalSince1970: 1_800_000_000))!
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(6 * 60 * 60),
                            label: "Overnight HRV fixture",
                            points: [SavedSession.Point(t: 0, bpm: 52),
                                     SavedSession.Point(t: 6 * 60 * 60, bpm: 52)],
                            hrv: 42,
                            rrPoints: [SavedSession.RRPoint(t: 1, ms: 1_000, source: source)])
    }

    func testOnlyQualifiedStandardRRAccruesDistinctHRVDay() {
        let standard = session(dayOffset: 0, source: .standardHeartRateMeasurement2A37)
        let legacy = session(dayOffset: 1, source: nil)
        var baseline = PersonalBaseline()

        for session in [standard, legacy] {
            baseline.learn(fromResting: session.restingStable,
                           hrv: session.localRMSSD ?? 0,
                           at: session.end,
                           overnight: session.isOvernightHRVWindow(calendar: calendar))
        }

        XCTAssertEqual(standard.localRMSSD, 42)
        XCTAssertNil(legacy.localRMSSD)
        XCTAssertEqual(baseline.freshHRVSampleCount(now: legacy.end), 1)
    }

    func testMultipleQualifiedWindowsOnOneDayCountOnce() {
        let first = session(dayOffset: 0, source: .standardHeartRateMeasurement2A37)
        let second = session(dayOffset: 0, source: .standardHeartRateMeasurement2A37)
        var baseline = PersonalBaseline()

        for session in [first, second] {
            baseline.learn(fromResting: session.restingStable,
                           hrv: session.localRMSSD ?? 0,
                           at: session.end,
                           overnight: true)
        }

        XCTAssertEqual(baseline.freshHRVSampleCount(now: second.end), 1)
    }
}
