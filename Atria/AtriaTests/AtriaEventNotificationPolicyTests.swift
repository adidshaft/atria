import XCTest
@testable import Atria

/// Pure-policy coverage for the event notifications added 2026-08-13: the
/// durable event-key dedup ledger, the bedtime wind-down timing derivation,
/// and the catch-up-completion observation policy.
final class AtriaEventNotificationPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AtriaEventNotificationPolicyTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Event-key dedup

    func testAnEventKeyNeverNotifiesTwice() {
        XCTAssertFalse(AtriaNotificationEventKeyStore.hasNotified("secondSleep.2026-08-13",
                                                                  defaults: defaults))
        AtriaNotificationEventKeyStore.recordNotified("secondSleep.2026-08-13",
                                                      defaults: defaults)
        XCTAssertTrue(AtriaNotificationEventKeyStore.hasNotified("secondSleep.2026-08-13",
                                                                 defaults: defaults))
        // A different physical event stays independent.
        XCTAssertFalse(AtriaNotificationEventKeyStore.hasNotified("secondSleep.2026-08-14",
                                                                  defaults: defaults))
    }

    func testRecordingTheSameKeyTwiceStoresItOnce() {
        AtriaNotificationEventKeyStore.recordNotified("catchup.1", defaults: defaults)
        AtriaNotificationEventKeyStore.recordNotified("catchup.1", defaults: defaults)
        let stored = defaults.stringArray(forKey: AtriaNotificationEventKeyStore.defaultsKey) ?? []
        XCTAssertEqual(stored.filter { $0 == "catchup.1" }.count, 1)
    }

    func testLedgerStaysBoundedEvictingOldestFirst() {
        for index in 0..<(AtriaNotificationEventKeyStore.capacity + 10) {
            AtriaNotificationEventKeyStore.recordNotified("event.\(index)", defaults: defaults)
        }
        let stored = defaults.stringArray(forKey: AtriaNotificationEventKeyStore.defaultsKey) ?? []
        XCTAssertEqual(stored.count, AtriaNotificationEventKeyStore.capacity)
        XCTAssertFalse(AtriaNotificationEventKeyStore.hasNotified("event.0", defaults: defaults),
                       "oldest key evicted")
        XCTAssertTrue(AtriaNotificationEventKeyStore.hasNotified(
            "event.\(AtriaNotificationEventKeyStore.capacity + 9)",
            defaults: defaults
        ))
    }

    // MARK: Bedtime wind-down timing

    func testNoReminderUntilTheSleepWindowIsLearned() {
        XCTAssertNil(AtriaBedtimeWindDownPolicy.reminderMinutes(sleepWindowStartMinutes: 0),
                     "no generic fallback hour: the reminder derives only from learned data")
        XCTAssertNil(AtriaBedtimeWindDownPolicy.reminderMinutes(sleepWindowStartMinutes: -5))
        XCTAssertNil(AtriaBedtimeWindDownPolicy.reminderMinutes(sleepWindowStartMinutes: 1440))
    }

    func testReminderLandsAnHourBeforeTheLearnedMedianBedtime() {
        // The duty-cycle window start is median bedtime - 60. A 23:00 window
        // start means a midnight bedtime; the reminder fires at 23:00 sharp
        // (one hour ahead, and NOT at windowStart+15 where the evening journal
        // check-in already fires).
        XCTAssertEqual(AtriaBedtimeWindDownPolicy.reminderMinutes(sleepWindowStartMinutes: 23 * 60),
                       23 * 60)
    }

    func testNextTargetRollsToTomorrowWhenTheMomentHasPassed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let reminderMinutes = 22 * 60
        let beforeReminder = date(hour: 20, minute: 0, calendar: calendar)
        let target = AtriaBedtimeWindDownPolicy.nextTarget(now: beforeReminder,
                                                           reminderMinutes: reminderMinutes,
                                                           calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: target), 22)
        XCTAssertTrue(calendar.isDate(target, inSameDayAs: beforeReminder))

        let afterReminder = date(hour: 23, minute: 30, calendar: calendar)
        let rolled = AtriaBedtimeWindDownPolicy.nextTarget(now: afterReminder,
                                                           reminderMinutes: reminderMinutes,
                                                           calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: rolled), 22)
        XCTAssertFalse(calendar.isDate(rolled, inSameDayAs: afterReminder),
                       "a passed reminder moment schedules for tomorrow")
    }

    func testBedtimeCopyMentionsDebtOnlyWhenDebtIsReal() {
        let none = AtriaBedtimeWindDownPolicy.content(sleepDebtHours: nil)
        let trivial = AtriaBedtimeWindDownPolicy.content(sleepDebtHours: 0.4)
        let real = AtriaBedtimeWindDownPolicy.content(sleepDebtHours: 2.0)
        XCTAssertFalse(none.body.lowercased().contains("sleep need"))
        XCTAssertFalse(trivial.body.lowercased().contains("sleep need"),
                       "sub-threshold debt must not be dramatized")
        XCTAssertTrue(real.body.lowercased().contains("sleep need"))
    }

    // MARK: Catch-up completion policy

    private let hour: Double = 3600

    func testAFarBehindFrontierRecordsAMarker() {
        let now = 1_800_000_000.0
        XCTAssertEqual(
            AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: nil,
                                                    frontierUnix: now - 8 * hour,
                                                    nowUnix: now),
            .recordMarker(frontierUnix: now - 8 * hour)
        )
    }

    func testAnExistingEarlierMarkerIsKeptAcrossBehindPasses() {
        let now = 1_800_000_000.0
        XCTAssertEqual(
            AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: now - 10 * hour,
                                                    frontierUnix: now - 6 * hour,
                                                    nowUnix: now),
            .none,
            "the earliest marker measures the whole catch-up, not its tail"
        )
    }

    func testALongCatchUpNotifiesOnceWithAStableEventKey() {
        let now = 1_800_000_000.0
        let marker = now - 9 * hour
        let action = AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: marker,
                                                             frontierUnix: now - 30,
                                                             nowUnix: now)
        guard case .notify(let span, let eventKey) = action else {
            return XCTFail("expected notify, got \(action)")
        }
        XCTAssertEqual(span, 9 * hour - 30, accuracy: 1)
        XCTAssertEqual(eventKey, "catchup.\(Int(marker))",
                       "the event key is the marker frontier: replayed passes dedup")
    }

    func testAShortCatchUpClearsTheMarkerSilently() {
        let now = 1_800_000_000.0
        XCTAssertEqual(
            AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: now - 1 * hour,
                                                    frontierUnix: now - 10,
                                                    nowUnix: now),
            .clearMarker,
            "a brief lag is not worth a notification"
        )
    }

    func testInBetweenBehindStateNeitherNotifiesNorClears() {
        let now = 1_800_000_000.0
        XCTAssertEqual(
            AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: now - 9 * hour,
                                                    frontierUnix: now - 30 * 60,
                                                    nowUnix: now),
            .none,
            "still catching up: keep the marker, stay silent"
        )
    }

    func testMissingOrBogusFrontierNeverActs() {
        let now = 1_800_000_000.0
        XCTAssertEqual(AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: nil,
                                                               frontierUnix: nil,
                                                               nowUnix: now), .none)
        XCTAssertEqual(AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: nil,
                                                               frontierUnix: 0,
                                                               nowUnix: now), .none)
        XCTAssertEqual(AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: nil,
                                                               frontierUnix: now + hour,
                                                               nowUnix: now),
                       .none,
                       "a future frontier is corrupt evidence, not a catch-up")
    }

    func testParkedIntervalEventKeyIsStablePerParkEvent() {
        XCTAssertEqual(AtriaEventNotificationContent.parkedIntervalEventKey(parkedAtUnix: 1_799_999_999.7),
                       "parkedInterval.1799999999")
        XCTAssertNotEqual(
            AtriaEventNotificationContent.parkedIntervalEventKey(parkedAtUnix: 1_799_999_999),
            AtriaEventNotificationContent.parkedIntervalEventKey(parkedAtUnix: 1_800_000_050),
            "a fresh park (new evidence, new park moment) is a new event"
        )
    }

    private func date(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 13,
                                           hour: hour, minute: minute))!
    }
}
