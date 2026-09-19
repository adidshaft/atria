import XCTest
@testable import Atria

final class AtriaOvernightMetricChartSeriesTests: XCTestCase {
    func testTrailingWeekKeepsISTShortSleepNightBesideLongerNights() throws {
        let json = """
        [
          {"day":"2026-09-18","tzOffsetMinutes":330,"lnRMSSD":3.970291913552122,"sleepSeconds":24925.55300796032,"recovery":69,"rhr":55},
          {"day":"2026-09-17","tzOffsetMinutes":330,"rhr":91},
          {"day":"2026-09-16","tzOffsetMinutes":330,"lnRMSSD":4.343805421853684,"sleepSeconds":26100,"recovery":75,"rhr":55},
          {"day":"2026-09-15","tzOffsetMinutes":330,"lnRMSSD":3.8918202981106265,"sleepSeconds":15693.279502868652,"recovery":52,"rhr":61}
        ]
        """
        let rollups = try JSONDecoder().decode([DailyRollupStoreEntry].self, from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12, minute: 5))!
        let week = AtriaTrendRange.week.periodInterval(containing: now, calendar: calendar)
        let month = AtriaTrendRange.month.periodInterval(containing: now, calendar: calendar)

        func hrv(_ interval: DateInterval) -> [Double] {
            AtriaOvernightMetricChartSeries.nights(
                from: rollups,
                interval: interval,
                calendar: calendar,
                day: \.day,
                value: { entry in
                    guard let lnRMSSD = entry.lnRMSSD, (entry.sleepSeconds ?? 0) > 0 else { return nil }
                    return Double(Int(exp(lnRMSSD).rounded()))
                }
            ).map(\.value)
        }

        XCTAssertEqual(hrv(week), [49, 77, 53])
        XCTAssertEqual(hrv(month), [49, 77, 53])

        let windows = AtriaDiagnosisReport.overnightMetricWindows(
            rollups: rollups,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(windows.hrvWeek.map(\.value), [49, 77, 53])
        XCTAssertEqual(windows.hrvMonth.map(\.value), [49, 77, 53])
        XCTAssertEqual(windows.recoveryWeek.map(\.value), [52, 75, 69])

        let domain = AtriaTrendChartScale.domain(values: [49, 77, 53])
        XCTAssertLessThanOrEqual(domain.lowerBound, 49)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 77)
    }

    func testNewerBlankRowDoesNotHideOlderOvernightValueOnTheSameDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let interval = DateInterval(
            start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 12))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 9, day: 19))!
        )
        let newerBlank = DailyRollupStoreEntry(day: day, calendar: calendar)
        let olderNight = DailyRollupStoreEntry(
            day: day,
            lnRMSSD: log(49),
            sleepSeconds: 15_693,
            calendar: calendar
        )
        let nights = AtriaOvernightMetricChartSeries.nights(
            from: [newerBlank, olderNight],
            interval: interval,
            calendar: calendar,
            day: \.day,
            value: { entry in
                guard let lnRMSSD = entry.lnRMSSD, (entry.sleepSeconds ?? 0) > 0 else { return nil }
                return Double(Int(exp(lnRMSSD).rounded()))
            }
        )
        XCTAssertEqual(nights.map(\.value), [49])
    }

    func testHoleyUserAdjustedNightMatchesDiagnosisWeekHRVAndChartDomain() throws {
        let json = """
        [
          {"day":"2026-09-18","tzOffsetMinutes":330,"lnRMSSD":3.970291913552122,"sleepSeconds":24925.55300796032,"recovery":69,"rhr":55},
          {"day":"2026-09-16","tzOffsetMinutes":330,"lnRMSSD":4.343805421853684,"sleepSeconds":26100,"recovery":75,"rhr":55},
          {"day":"2026-09-15","tzOffsetMinutes":330,"lnRMSSD":3.6888794541139363,"sleepSeconds":5112,"recovery":29,"rhr":67}
        ]
        """
        let rollups = try JSONDecoder().decode([DailyRollupStoreEntry].self, from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 13, minute: 21))!

        let windows = AtriaDiagnosisReport.overnightMetricWindows(
            rollups: rollups,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(windows.hrvWeek.map(\.value), [40, 77, 53])
        XCTAssertEqual(windows.hrvWeek.map(\.day), ["2026-09-15", "2026-09-16", "2026-09-18"])

        let domain = AtriaTrendChartScale.domain(values: windows.hrvWeek.map { Double($0.value) })
        XCTAssertLessThanOrEqual(domain.lowerBound, 40)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 77)
    }

    func testLearningIntervalCountsTheSameOvernightHRVNightsAsWeek() throws {
        let json = """
        [
          {"day":"2026-09-18","tzOffsetMinutes":330,"lnRMSSD":3.970291913552122,"sleepSeconds":24925.55300796032,"recovery":69,"rhr":55},
          {"day":"2026-09-16","tzOffsetMinutes":330,"lnRMSSD":4.343805421853684,"sleepSeconds":26100,"recovery":75,"rhr":55},
          {"day":"2026-09-15","tzOffsetMinutes":330,"lnRMSSD":3.6888794541139363,"sleepSeconds":5112,"recovery":31,"rhr":67}
        ]
        """
        let rollups = try JSONDecoder().decode([DailyRollupStoreEntry].self, from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 14, minute: 20))!
        let interval = AtriaOvernightMetricChartSeries.learningInterval(
            now: now,
            calendar: calendar
        )
        let nights = AtriaOvernightMetricChartSeries.nights(
            from: rollups,
            interval: interval,
            calendar: calendar,
            day: \.day,
            value: { entry in
                guard let lnRMSSD = entry.lnRMSSD, (entry.sleepSeconds ?? 0) > 0 else { return nil }
                return Double(Int(exp(lnRMSSD).rounded()))
            }
        )
        XCTAssertEqual(nights.map(\.value), [40, 77, 53])
        XCTAssertEqual(interval.duration / 86_400, 14, accuracy: 0.01)
    }
}
