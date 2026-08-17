import XCTest
@testable import Atria

final class AtriaAnonymousDailyUploadScheduleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        suiteName = "atria.anonymous-upload.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utc
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute, second: 0))!
    }

    func testUnsetPreferredTimeDefaultsTo3AMLocal() {
        XCTAssertNil(defaults.object(forKey: AtriaAnonymousDailyUploadSchedule.preferredLocalMinutesKey))
        XCTAssertEqual(
            AtriaAnonymousDailyUploadSchedule.preferredLocalMinutes(defaults: defaults),
            3 * 60
        )
        XCTAssertEqual(
            AtriaAnonymousDailyUploadSchedule.resolvedPreferredLocalMinutes(nil),
            AtriaAnonymousDailyUploadSchedule.defaultPreferredLocalMinutes
        )
    }

    func testStoredCustomTimeIsTheOneUsed() {
        AtriaAnonymousDailyUploadSchedule.setPreferredLocalMinutes(4 * 60 + 15, defaults: defaults)
        XCTAssertEqual(
            AtriaAnonymousDailyUploadSchedule.preferredLocalMinutes(defaults: defaults),
            4 * 60 + 15
        )
        XCTAssertEqual(
            AtriaAnonymousDailyUploadSchedule.resolvedPreferredLocalMinutes(4 * 60 + 15),
            4 * 60 + 15
        )
        // Midnight is a stored custom time, not the unset default.
        AtriaAnonymousDailyUploadSchedule.setPreferredLocalMinutes(0, defaults: defaults)
        XCTAssertEqual(AtriaAnonymousDailyUploadSchedule.preferredLocalMinutes(defaults: defaults), 0)
    }

    func testDefault3AMIsDueOncePerLocalDayAndOptOutIsNeverDue() {
        let preferred = AtriaAnonymousDailyUploadSchedule.resolvedPreferredLocalMinutes(nil)
        XCTAssertEqual(preferred, 3 * 60)

        let before = date(year: 2026, month: 8, day: 17, hour: 2, minute: 59)
        let atDefault = date(year: 2026, month: 8, day: 17, hour: 3, minute: 0)
        let laterSameDay = date(year: 2026, month: 8, day: 17, hour: 15, minute: 12)
        let today = AtriaAnonymousDailyUploadSchedule.lastRunCivilDay(for: atDefault, calendar: calendar)

        XCTAssertFalse(
            AtriaAnonymousDailyUploadSchedule.isDue(
                optedIn: true,
                preferredLocalMinutes: preferred,
                now: before,
                lastRunCivilDay: nil,
                calendar: calendar
            ),
            "02:59 with default 3AM must not be due"
        )
        XCTAssertTrue(
            AtriaAnonymousDailyUploadSchedule.isDue(
                optedIn: true,
                preferredLocalMinutes: preferred,
                now: atDefault,
                lastRunCivilDay: nil,
                calendar: calendar
            ),
            "03:00 same day must be due once"
        )
        XCTAssertFalse(
            AtriaAnonymousDailyUploadSchedule.isDue(
                optedIn: true,
                preferredLocalMinutes: preferred,
                now: laterSameDay,
                lastRunCivilDay: today,
                calendar: calendar
            ),
            "a second call the same local day must not be due"
        )
        XCTAssertFalse(
            AtriaAnonymousDailyUploadSchedule.isDue(
                optedIn: false,
                preferredLocalMinutes: preferred,
                now: atDefault,
                lastRunCivilDay: nil,
                calendar: calendar
            ),
            "opted-out at 03:00 must never be due"
        )
    }

    func testQueueDueFunctionReadsPersistedTimeAndOptInFromDefaults() {
        let atDefault = date(year: 2026, month: 8, day: 17, hour: 3, minute: 0)
        XCTAssertFalse(
            AtriaResearchUploadQueue.isDailyUploadDue(now: atDefault, calendar: calendar, defaults: defaults),
            "clean defaults are opted out"
        )

        defaults.set(true, forKey: AtriaResearchSharing.optInKey)
        XCTAssertTrue(
            AtriaResearchUploadQueue.isDailyUploadDue(now: atDefault, calendar: calendar, defaults: defaults)
        )

        AtriaAnonymousDailyUploadSchedule.setPreferredLocalMinutes(6 * 60, defaults: defaults)
        XCTAssertFalse(
            AtriaResearchUploadQueue.isDailyUploadDue(now: atDefault, calendar: calendar, defaults: defaults),
            "stored 06:00 must replace the 03:00 default"
        )
        XCTAssertTrue(
            AtriaResearchUploadQueue.isDailyUploadDue(
                now: date(year: 2026, month: 8, day: 17, hour: 6, minute: 0),
                calendar: calendar,
                defaults: defaults
            )
        )
    }

    func testNightlyAndForegroundHooksCallTheSharedDueFunction() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria")
            .appendingPathComponent("AtriaResearchBundle.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let nightly = try XCTUnwrap(source.range(of: "static func runNightlyIfDue"))
        let foreground = try XCTUnwrap(source.range(of: "static func runForegroundCatchUpIfMissed"))
        let sendNow = try XCTUnwrap(source.range(of: "static func sendNow"))
        let nightlyBody = String(source[nightly.lowerBound..<foreground.lowerBound])
        let foregroundBody = String(source[foreground.lowerBound..<sendNow.lowerBound])

        XCTAssertTrue(nightlyBody.contains("guard isDailyUploadDue(now: now, calendar: calendar)"))
        XCTAssertFalse(nightlyBody.contains("isWithinSleepWindow"))
        XCTAssertTrue(foregroundBody.contains("guard isDailyUploadDue(now: now, calendar: calendar)"))
        XCTAssertFalse(foregroundBody.contains("isWithinSleepWindow"))
        XCTAssertTrue(source.contains("static func isDailyUploadDue"))
        XCTAssertTrue(source.contains("AtriaAnonymousDailyUploadSchedule.isDue("))
    }
}
