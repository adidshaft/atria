import XCTest
@testable import Atria

final class AtriaTrendShiftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 28 days: index 0 = today. `week(i)`/`base(i)` supply the RHR value.
    private func rollups(days: Int = 28,
                         rhr: (Int) -> Int?) -> [DailyRollupStoreEntry] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).map { offset in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                                  rhr: rhr(offset),
                                  calendar: calendar)
        }
    }

    func testClearWeeklyRiseSurfacesAsAFact() {
        // Baseline 54±1, last week 58±1: well past 2 bpm and p << 0.05.
        let data = rollups { $0 < 7 ? 58 + ($0 % 2) : 54 + ($0 % 2) }
        let shift = AtriaTrendShift.shifts(rollups: data, now: now, calendar: calendar).first
        XCTAssertEqual(shift?.metric, .restingHeartRate)
        XCTAssertEqual(shift?.headline, "Resting HR up 4 bpm this week")
        XCTAssertEqual(shift?.isFavourable, false)
        XCTAssertLessThan(shift?.pValue ?? 1, AtriaTrendShift.significance)
    }

    func testNoisyWeekDoesNotPassTheGate() {
        // Same mean shift on average but huge spread: Welch keeps it quiet.
        let data = rollups { offset in
            offset < 7 ? [48, 70, 50, 68, 52, 66, 54][offset] : 54 + (offset % 2)
        }
        XCTAssertTrue(AtriaTrendShift.shifts(rollups: data, now: now, calendar: calendar).isEmpty)
    }

    func testSmallButSignificantChangeBelowMinimumEffectSaysNothing() {
        // 1 bpm, perfectly consistent: statistically "real", not worth a sentence.
        let data = rollups { $0 < 7 ? 55 : 54 }
        XCTAssertTrue(AtriaTrendShift.shifts(rollups: data, now: now, calendar: calendar).isEmpty)
    }

    func testTooFewDaysSaysNothing() {
        // Four days in the week and ten in the baseline: below both floors.
        let data = rollups { offset in
            if offset < 7 { return offset < 4 ? 60 : nil }
            return offset < 17 ? 54 : nil
        }
        XCTAssertTrue(AtriaTrendShift.shifts(rollups: data, now: now, calendar: calendar).isEmpty)
    }

    func testWindowsDoNotOverlap() {
        // A spike only on day 7 (first baseline day) must not move the week.
        let data = rollups { $0 == 7 ? 90 : 54 + ($0 % 2) }
        XCTAssertTrue(AtriaTrendShift.shifts(rollups: data, now: now, calendar: calendar)
            .allSatisfy { $0.metric != .restingHeartRate || $0.weekMean < 56 })
    }

    func testSleepAndHRVUseDisplayUnitsAndFavourableDirection() {
        let today = calendar.startOfDay(for: now)
        let cal = calendar
        var data: [DailyRollupStoreEntry] = []
        for offset in 0..<28 {
            let jitter = Double(offset % 2)
            let hrvMs: Double = offset < 7 ? 62.0 + jitter : 50.0 + jitter
            let sleepHours: Double = offset < 7 ? 7.5 : 6.5
            let day: Date = cal.date(byAdding: .day, value: -offset, to: today)!
            data.append(DailyRollupStoreEntry(day: day,
                                              lnRMSSD: log(hrvMs),
                                              sleepSeconds: sleepHours * 3_600 + jitter * 300,
                                              calendar: cal))
        }
        let shifts = AtriaTrendShift.shifts(rollups: data, now: now, calendar: calendar)
        let hrv = shifts.first { $0.metric == .hrv }
        let sleep = shifts.first { $0.metric == .sleepDuration }
        XCTAssertEqual(hrv?.headline, "HRV up 12 ms this week")
        XCTAssertEqual(hrv?.isFavourable, true)
        XCTAssertEqual(sleep?.headline, "Sleep up 60 min a night this week")
        XCTAssertEqual(sleep?.isFavourable, true)
    }

    func testLearnedInsightsCarryTheMostNotableShift() {
        let data = rollups { $0 < 7 ? 58 + ($0 % 2) : 54 + ($0 % 2) }
        let insights = AtriaLearnedInsights.insights(rollups: data, now: now, calendar: calendar)
        let weekly = insights.first { $0.kind == .vitalsWeeklyShift }
        XCTAssertEqual(weekly?.headline, "Resting HR up 4 bpm this week")
        XCTAssertEqual(weekly?.ringFamily, .recovery)
        XCTAssertEqual(weekly?.isPositive, false)
    }

    func testWeeklyReportReadsCarryOnlyWeekScopedFindings() {
        let data = rollups { $0 < 7 ? 58 + ($0 % 2) : 54 + ($0 % 2) }
        let learned = AtriaLearnedInsights.insights(rollups: data, now: now, calendar: calendar)
        let reads = AtriaTodayScreen.weeklyReportReads(learned: learned, behavior: [])
        XCTAssertTrue(reads.contains { $0.headline == "Resting HR up 4 bpm this week" })
        let weekKinds = learned.filter { AtriaTodayScreen.weeklyReportKinds.contains($0.kind) }.count
        XCTAssertEqual(reads.count, weekKinds, "single-morning reads stay on Today, not in the week")
    }
}
