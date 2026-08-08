import XCTest
@testable import Atria

final class SavedDailyMetricCodableTests: XCTestCase {
    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func metric(calendar: Calendar) throws -> SavedDailyMetric {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 10)))
        let sleepStart = day.addingTimeInterval(-8 * 3_600)
        let sleepEnd = day.addingTimeInterval(-30 * 60)
        return SavedDailyMetric(
            day: day,
            recoveryPercent: 82,
            recoveryConfidence: "frozen",
            hrv: 61,
            restingHR: 49,
            respiratoryRate: 13.4,
            sleepDuration: 7.5 * 3_600,
            sleepSpan: 8 * 3_600,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            sleepSource: "confirmed_sleep",
            sleepStageSegments: [
                SleepStageSegment(id: "deep-1", start: sleepStart, end: sleepStart.addingTimeInterval(1_800), stage: .deep)
            ],
            sleepConsistencyPercent: 91,
            strain: 6.7,
            skinTemperatureDeviationCelsius: 0.3
        )
    }

    func testCivilDayMaterializesOnSameDayAfterTravel() throws {
        let kolkata = try calendar("Asia/Kolkata")
        let losAngeles = try calendar("America/Los_Angeles")
        let original = try metric(calendar: kolkata)

        let encoder = JSONEncoder()
        encoder.userInfo[SavedDailyMetric.codingCalendarUserInfoKey] = kolkata
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.userInfo[SavedDailyMetric.codingCalendarUserInfoKey] = losAngeles
        let decoded = try decoder.decode(SavedDailyMetric.self, from: data)

        XCTAssertEqual(SavedDailyMetric.civilDay(for: original.day, calendar: kolkata), "2026-07-10")
        XCTAssertEqual(SavedDailyMetric.civilDay(for: decoded.day, calendar: losAngeles), "2026-07-10")
        XCTAssertEqual(decoded.day, losAngeles.startOfDay(for: decoded.day))
        XCTAssertEqual(decoded.sleepStart, original.sleepStart)
        XCTAssertEqual(decoded.sleepEnd, original.sleepEnd)
    }

    func testNewJSONRoundTripsEveryMetricField() throws {
        let kolkata = try calendar("Asia/Kolkata")
        let original = try metric(calendar: kolkata)
        let encoder = JSONEncoder()
        encoder.userInfo[SavedDailyMetric.codingCalendarUserInfoKey] = kolkata

        let data = try encoder.encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["civilDay"] as? String, "2026-07-10")
        XCTAssertEqual(object["civilTimeZoneOffsetSeconds"] as? Int, 19_800)
        XCTAssertNotNil(object["day"])

        let decoder = JSONDecoder()
        decoder.userInfo[SavedDailyMetric.codingCalendarUserInfoKey] = kolkata
        XCTAssertEqual(try decoder.decode(SavedDailyMetric.self, from: data), original)
    }

    func testLegacyJSONWithoutCivilFieldsStillDecodes() throws {
        let kolkata = try calendar("Asia/Kolkata")
        let original = try metric(calendar: kolkata)
        let encoder = JSONEncoder()
        encoder.userInfo[SavedDailyMetric.codingCalendarUserInfoKey] = kolkata
        let data = try encoder.encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "civilDay")
        object.removeValue(forKey: "civilTimeZoneOffsetSeconds")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SavedDailyMetric.self, from: legacyData)

        XCTAssertEqual(decoded, original)
    }

    func testVersionedRecoveryReceiptRoundTripsFrozenInputsAndBaselines() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = PersonalBaseline(restingHR: 52,
                                        hrvEMA: 63,
                                        sessions: 14,
                                        updated: day)
        let receipt = FrozenRecoverySummary.InputSnapshot(
            hrvRMSSD: 68,
            restingHeartRateBPM: 49,
            sleepDurationSeconds: 7.75 * 3_600,
            sleepEfficiency: 0.91,
            respiratoryRate: 13.2,
            baseline: baseline,
            respiratoryBaseline: (mean: 13.6, sd: 0.4, count: 14),
            now: day
        )
        let original = FrozenRecoverySummary(
            score: 74,
            confidence: Metrics.RecoveryEstimate.Confidence.personalBaseline.rawValue,
            source: FrozenRecoverySummary.recoveryV2Source,
            model: "recovery_v2",
            modelVersion: FrozenRecoverySummary.recoveryV2ModelVersion,
            scoredDay: day,
            usesHRV: true,
            detail: "frozen recovery receipt",
            contributors: [],
            inputSnapshot: receipt
        )

        let restored = try JSONDecoder().decode(
            FrozenRecoverySummary.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.modelVersion, FrozenRecoverySummary.recoveryV2ModelVersion)
        XCTAssertEqual(restored.inputSnapshot?.hrvRMSSD, 68)
        XCTAssertEqual(restored.inputSnapshot?.restingHeartRateBPM, 49)
        XCTAssertEqual(restored.inputSnapshot?.sleepEfficiency, 0.91)
        XCTAssertEqual(restored.inputSnapshot?.respiratoryRateBaseline?.mean, 13.6)
        XCTAssertEqual(restored.inputSnapshot?.recoveryComparison?.comparisonHorizonDays, 30)
        XCTAssertEqual(restored.inputSnapshot?.recoveryComparison?.asOf, day)
    }
}
