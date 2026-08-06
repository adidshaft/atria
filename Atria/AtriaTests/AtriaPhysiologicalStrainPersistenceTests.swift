import XCTest
@testable import Atria

final class AtriaPhysiologicalStrainPersistenceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2032,
                                           month: 1,
                                           day: day,
                                           hour: hour))!
    }

    func testActiveCycleStrainReplacesOnlyCycleOwningRollup() {
        let previous = DailyRollupStoreEntry(day: date(1, 0), strain: 9.2, calendar: calendar)
        let active = DailyRollupStoreEntry(day: date(2, 0), strain: 12.8, calendar: calendar)
        let rows = SessionStore.replacingActiveCycleStrain(
            in: [active, previous],
            cycleStart: date(2, 7),
            strain: 4.6,
            calendar: calendar
        )

        XCTAssertEqual(rows.first { calendar.isDate($0.day, inSameDayAs: date(2, 0)) }?.strain,
                       4.6)
        XCTAssertEqual(rows.first { calendar.isDate($0.day, inSameDayAs: date(1, 0)) }?.strain,
                       9.2)
    }

    func testLateWakeCycleContinuesAcrossCivilMidnightOnWakeDayRow() {
        let wakeDay = DailyRollupStoreEntry(day: date(2, 0), strain: 7.1, calendar: calendar)
        let nextCivilDay = DailyRollupStoreEntry(day: date(3, 0), strain: 1.8, calendar: calendar)
        let rows = SessionStore.replacingActiveCycleStrain(
            in: [nextCivilDay, wakeDay],
            cycleStart: date(2, 19),
            strain: 8.4,
            calendar: calendar
        )

        XCTAssertEqual(rows.first { calendar.isDate($0.day, inSameDayAs: date(2, 0)) }?.strain,
                       8.4,
                       "wake-to-wake strain stays on the recovery/wake row after midnight")
        XCTAssertEqual(rows.first { calendar.isDate($0.day, inSameDayAs: date(3, 0)) }?.strain,
                       1.8,
                       "the next civil row must not replace the still-active physiological day")
    }

    func testNoDurableCycleEvidenceClearsCivilDayStrainInsteadOfInventingLoad() {
        let row = DailyRollupStoreEntry(day: date(2, 0), strain: 6.5, calendar: calendar)
        let rows = SessionStore.replacingActiveCycleStrain(
            in: [row],
            cycleStart: date(2, 7),
            strain: nil,
            calendar: calendar
        )

        XCTAssertNil(rows.first?.strain)
    }

    func testSavedMetricAndRollupUseTheSameCycleAlignedStrain() {
        let metric = SavedDailyMetric(day: date(2, 0),
                                      recoveryPercent: 60,
                                      recoveryConfidence: "test",
                                      hrv: 55,
                                      restingHR: 60,
                                      respiratoryRate: 14,
                                      sleepDuration: 7 * 3_600,
                                      sleepSpan: 8 * 3_600,
                                      sleepStart: date(1, 23),
                                      sleepEnd: date(2, 7),
                                      sleepSource: "test",
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: 80,
                                      strain: 11.2)
        let aligned = SessionStore.replacingActiveCycleStrain(in: [metric],
                                                               cycleStart: date(2, 7),
                                                               strain: 4.6,
                                                               calendar: calendar)

        XCTAssertEqual(aligned.first?.strain, 4.6)
        XCTAssertEqual(aligned.first?.recoveryPercent, metric.recoveryPercent)
        XCTAssertEqual(aligned.first?.sleepEnd, metric.sleepEnd)
    }

    func testDailyRollupPreparationExcludesConfirmedSleepLikeHome() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sessionsFile = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
            .appendingPathComponent("Sessions.swift")
        let source = try String(contentsOf: sessionsFile, encoding: .utf8)
        let preparationStart = try XCTUnwrap(
            source.range(of: "private nonisolated static func makeDailyMetricRollupPreparation")
        )
        let preparationEnd = try XCTUnwrap(
            source.range(of: "nonisolated static func napHoursByMorningDay",
                         range: preparationStart.upperBound..<source.endIndex)
        )
        let preparation = String(source[preparationStart.lowerBound..<preparationEnd.lowerBound])

        XCTAssertTrue(
            preparation.contains(
                "excludedLoadIntervals: confirmedSleeps.map {\n" +
                "                DateInterval(start: $0.start, end: $0.end)\n" +
                "            }"
            ),
            "persisted daily strain must exclude the same confirmed sleep intervals as Home"
        )
    }
}
