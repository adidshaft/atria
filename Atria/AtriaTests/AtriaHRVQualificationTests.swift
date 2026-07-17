import XCTest
@testable import Atria

final class AtriaHRVQualificationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func session(dayOffset: Int,
                         source: AtriaRRSourceProvenance?,
                         hour: Int = 23,
                         sufficientRR: Bool = true) -> SavedSession {
        let day = calendar.date(byAdding: .day,
                                value: dayOffset,
                                to: Date(timeIntervalSince1970: 1_800_000_000))!
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        let rrPoints: [SavedSession.RRPoint] = sufficientRR
            ? stride(from: 1.0, through: 16 * 60.0, by: 1.0).map { offset in
                SavedSession.RRPoint(t: offset,
                                     ms: Int(offset).isMultiple(of: 2) ? 980 : 1_020,
                                     source: source)
            }
            : [SavedSession.RRPoint(t: 1, ms: 1_000, source: source)]
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(6 * 60 * 60),
                            label: "Overnight HRV fixture",
                            points: [SavedSession.Point(t: 0, bpm: 52),
                                     SavedSession.Point(t: 6 * 60 * 60, bpm: 52)],
                            hrv: 42,
                            rrPoints: rrPoints)
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

    func testPersistedHRVCannotBypassInsufficientRREvidence() {
        let sparse = session(dayOffset: 0,
                             source: .standardHeartRateMeasurement2A37,
                             sufficientRR: false)

        XCTAssertTrue(sparse.hasQualifiedStandardRRProvenance)
        XCTAssertNil(sparse.localRMSSD)
        XCTAssertEqual(sparse.localHRVWindowCount, 0)
    }

    func testQualifiedDaytimeRRDoesNotAdvanceOvernightTrustCount() {
        let daytime = session(dayOffset: 0,
                              source: .standardHeartRateMeasurement2A37,
                              hour: 13)
        var baseline = PersonalBaseline()

        baseline.learn(fromResting: daytime.restingStable,
                       hrv: daytime.localRMSSD ?? 0,
                       at: daytime.end,
                       overnight: daytime.isOvernightHRVWindow(calendar: calendar))

        XCTAssertEqual(daytime.localRMSSD, 42)
        XCTAssertFalse(daytime.isOvernightHRVWindow(calendar: calendar))
        XCTAssertEqual(baseline.freshHRVSampleCount(now: daytime.end), 0)
    }
}
