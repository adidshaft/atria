import XCTest
@testable import Atria

final class AtriaRecoveryDriversTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
    }

    func testDriversCompareTodayWithThePersonalBaselineAndRankByMagnitude() {
        var rollups: [DailyRollupStoreEntry] = []
        for offset in 1...20 {
            rollups.append(DailyRollupStoreEntry(day: day(offset),
                                                 lnRMSSD: log(50),
                                                 rhr: 55,
                                                 sleepSeconds: 7 * 3_600,
                                                 calendar: calendar))
        }
        // Today: HRV much higher (+15 ms), RHR slightly lower (-1), sleep short (-1 h).
        rollups.append(DailyRollupStoreEntry(day: day(0), lnRMSSD: log(65), rhr: 54,
                                             sleepSeconds: 6 * 3_600, calendar: calendar))
        let drivers = AtriaRecoveryDrivers.make(rollups: rollups, now: now, calendar: calendar)
        XCTAssertEqual(drivers.map(\.kind), [.hrv, .sleep, .restingHeartRate])
        XCTAssertEqual(drivers[0].valueText, "+15 ms")
        XCTAssertEqual(drivers[0].favourable, true)
        XCTAssertEqual(drivers[1].valueText, "-60m")
        XCTAssertEqual(drivers[1].favourable, false)
        XCTAssertNil(drivers[2].favourable, "a 1 bpm change is level, not good or bad")
        XCTAssertEqual(drivers[2].arrow, "equal")
    }

    func testThinBaselineOrMissingTodayShowsNothing() {
        var rollups = (1...5).map {
            DailyRollupStoreEntry(day: day($0), rhr: 55, calendar: calendar)
        }
        rollups.append(DailyRollupStoreEntry(day: day(0), rhr: 60, calendar: calendar))
        XCTAssertTrue(AtriaRecoveryDrivers.make(rollups: rollups, now: now, calendar: calendar).isEmpty,
                      "5 baseline days is below the 7-day personal floor")
        let noToday = (1...20).map { DailyRollupStoreEntry(day: day($0), rhr: 55, calendar: calendar) }
        XCTAssertTrue(AtriaRecoveryDrivers.make(rollups: noToday, now: now, calendar: calendar).isEmpty)
    }

    func testStrainUsesYesterdayAgainstTheDaysBeforeIt() {
        var rollups = (2...20).map { DailyRollupStoreEntry(day: day($0), strain: 8, calendar: calendar) }
        rollups.append(DailyRollupStoreEntry(day: day(1), strain: 14, calendar: calendar))
        let strain = AtriaRecoveryDrivers.make(rollups: rollups, now: now, calendar: calendar)
            .first { $0.kind == .strain }
        XCTAssertEqual(strain?.valueText, "+6.0")
        XCTAssertEqual(strain?.favourable, false)
    }

    func testBedtimeBaselineWrapsAroundMidnight() {
        // Usual bedtime straddles midnight (23:50 / 00:10); tonight 00:40 is 40 min late,
        // not ~12 hours early as an arithmetic mean would say.
        var rollups = (1...14).map {
            DailyRollupStoreEntry(day: day($0), bedtimeMinutes: $0 % 2 == 0 ? 1_430 : 10, calendar: calendar)
        }
        rollups.append(DailyRollupStoreEntry(day: day(0), bedtimeMinutes: 40, calendar: calendar))
        let bedtime = AtriaRecoveryDrivers.make(rollups: rollups, now: now, calendar: calendar)
            .first { $0.kind == .bedtime }
        XCTAssertEqual(bedtime?.valueText, "40m late")
        XCTAssertEqual(bedtime?.favourable, false)
    }

    func testTodayPlacesTheStripUnderTheRingsAndOpensRecovery() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("AtriaRecoveryDrivers.make(rollups: dayDescendingRollups, now: Date())"))
        XCTAssertTrue(source.contains("onOpen: { openMetricDetail(.recovery) })"))
    }
}

/// W4.4: the requested context tags exist and carry their effect class.
final class AtriaW44JournalTagEffectTests: XCTestCase {
    func testRequestedContextTagsCarryTheirExpectedEffect() {
        typealias Tag = BehaviorJournalEntry.Tag
        XCTAssertEqual(Tag.caffeine.expectedEffect, .disruptive)       // caffeine after mid-afternoon
        XCTAssertEqual(Tag.screenInBed.expectedEffect, .disruptive)    // late screen
        XCTAssertEqual(Tag.sauna.expectedEffect, .supportive)
        XCTAssertEqual(Tag.coldExposure.expectedEffect, .supportive)
        XCTAssertEqual(Tag.unwell.expectedEffect, .disruptive)         // illness
        XCTAssertEqual(Tag.caffeine.prompt, "Coffee, tea, or caffeine after mid-afternoon?")
    }
}
