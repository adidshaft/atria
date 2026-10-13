import XCTest
@testable import Atria

final class AtriaStrainPacingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func testOnlyTheFirstCrossingOfADayIsRecorded() {
        let first = AtriaStrainPacing.recordingCrossing(strain: 13.2, target: 13, now: at(0, 21, 15),
                                                        existing: [:], calendar: calendar)
        XCTAssertEqual(first?.values.first, 21 * 60 + 15)
        XCTAssertNil(AtriaStrainPacing.recordingCrossing(strain: 15, target: 13, now: at(0, 22, 0),
                                                         existing: first ?? [:], calendar: calendar))
        XCTAssertNil(AtriaStrainPacing.recordingCrossing(strain: 12.9, target: 13, now: at(0, 22, 0),
                                                         existing: [:], calendar: calendar),
                     "below target is not a crossing")
        XCTAssertNil(AtriaStrainPacing.recordingCrossing(strain: 20, target: nil, now: at(0, 22, 0),
                                                         existing: [:], calendar: calendar))
    }

    func testTypicalTimeNeedsFivePastDaysAndIgnoresToday() {
        var crossings: AtriaStrainPacing.Crossings = [:]
        for (offset, minute) in [(1, 1290), (2, 1300), (3, 1280), (4, 1310)] {
            crossings[AtriaStrainPacing.dayKey(at(offset, 12, 0), calendar: calendar)] = minute
        }
        crossings[AtriaStrainPacing.dayKey(now, calendar: calendar)] = 600
        XCTAssertNil(AtriaStrainPacing.typicalCrossingMinute(crossings: crossings, now: now, calendar: calendar))
        crossings[AtriaStrainPacing.dayKey(at(5, 12, 0), calendar: calendar)] = 1295
        XCTAssertEqual(AtriaStrainPacing.typicalCrossingMinute(crossings: crossings, now: now, calendar: calendar), 1295)
    }

    func testTypicalTimeWrapsMidnight() {
        var crossings: AtriaStrainPacing.Crossings = [:]
        for (offset, minute) in [(1, 1430), (2, 5), (3, 1435), (4, 15), (5, 1425)] {
            crossings[AtriaStrainPacing.dayKey(at(offset, 12, 0), calendar: calendar)] = minute
        }
        let typical = AtriaStrainPacing.typicalCrossingMinute(crossings: crossings, now: now, calendar: calendar)
        XCTAssertEqual(typical, 1435, "the median sits near midnight, not at noon")
    }

    func testRingSuffixAppearsOnlyBeforeTheTargetIsMet() {
        var crossings: AtriaStrainPacing.Crossings = [:]
        for offset in 1...6 {
            crossings[AtriaStrainPacing.dayKey(at(offset, 12, 0), calendar: Calendar.current)] = 21 * 60 + 30
        }
        XCTAssertEqual(AtriaTodayScreen.strainUsuallyReachedSuffix(strain: 9.1, target: 13, now: now,
                                                                   crossings: crossings), " · by 21:30")
        XCTAssertEqual(AtriaTodayScreen.strainUsuallyReachedSuffix(strain: 13.5, target: 13, now: now,
                                                                   crossings: crossings), "")
        XCTAssertEqual(AtriaTodayScreen.strainUsuallyReachedSuffix(strain: 9.1, target: 13, now: now,
                                                                   crossings: [:]), "")
    }

    func testCrossingsAreRecordedAtTheHeroPublishPoint() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("AtriaStrainPacing.noteStrain(next.strain, target: next.guidance.target)"))
    }
}
