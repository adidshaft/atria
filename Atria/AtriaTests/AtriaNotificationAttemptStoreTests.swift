import XCTest
@testable import Atria

/// Tests for the durable record of why a notification did or did not happen.
final class AtriaNotificationAttemptStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "AtriaNotificationAttemptStoreTests"
    private let kind = "morning_checkin"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAnAttemptSurvivesAsAReadableRecord() {
        AtriaNotificationAttemptStore.record(kind: kind,
                                             outcome: .blockedByAuthorization,
                                             reason: "authorization_denied",
                                             at: now,
                                             defaults: defaults)

        let stored = AtriaNotificationAttemptStore.latest(kind: kind, defaults: defaults)

        XCTAssertEqual(stored?.outcome, .blockedByAuthorization)
        XCTAssertEqual(stored?.reason, "authorization_denied")
        XCTAssertEqual(stored?.at, now)
    }

    func testNoRecordReadsAsNilRatherThanADefault() {
        XCTAssertNil(AtriaNotificationAttemptStore.latest(kind: kind, defaults: defaults))
        XCTAssertFalse(AtriaNotificationAttemptStore.needsInAppFallback(
            kind: kind, now: now, defaults: defaults))
    }

    func testTheLatestAttemptReplacesThePrevious() {
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .failed,
                                             reason: "boom", at: now, defaults: defaults)
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .scheduled,
                                             reason: "target_day_2026-07-28",
                                             at: now.addingTimeInterval(60), defaults: defaults)

        XCTAssertEqual(AtriaNotificationAttemptStore.latest(kind: kind, defaults: defaults)?.outcome,
                       .scheduled)
    }

    // MARK: - Fallback policy

    /// Only outcomes where the system route genuinely cannot deliver oblige an
    /// in-app prompt.
    func testOnlyUndeliverableOutcomesRequestAFallback() {
        XCTAssertTrue(AtriaNotificationAttempt.Outcome.blockedByAuthorization.needsInAppFallback)
        XCTAssertTrue(AtriaNotificationAttempt.Outcome.failed.needsInAppFallback)

        XCTAssertFalse(AtriaNotificationAttempt.Outcome.scheduled.needsInAppFallback)
        XCTAssertFalse(AtriaNotificationAttempt.Outcome.skippedInactive.needsInAppFallback)
        XCTAssertFalse(AtriaNotificationAttempt.Outcome.deferred.needsInAppFallback)
    }

    /// A toggle the user set themselves must never be overridden by an in-app
    /// prompt -- honouring it is the entire point of the toggle.
    func testAUserDisabledToggleNeverTriggersAFallback() {
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .blockedByToggle,
                                             reason: "toggle_off", at: now, defaults: defaults)

        XCTAssertFalse(AtriaNotificationAttempt.Outcome.blockedByToggle.needsInAppFallback)
        XCTAssertFalse(AtriaNotificationAttemptStore.needsInAppFallback(
            kind: kind, now: now, defaults: defaults))
    }

    func testAuthorizationDenialRaisesAFallbackSameDay() {
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .blockedByAuthorization,
                                             reason: "authorization_denied",
                                             at: now, defaults: defaults)

        XCTAssertTrue(AtriaNotificationAttemptStore.needsInAppFallback(
            kind: kind, now: now.addingTimeInterval(3 * 3600), defaults: defaults))
    }

    /// A denial from a previous day must not keep raising a prompt about this
    /// morning.
    func testAStaleDenialDoesNotRaiseAFallback() {
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .blockedByAuthorization,
                                             reason: "authorization_denied",
                                             at: now, defaults: defaults)

        XCTAssertFalse(AtriaNotificationAttemptStore.needsInAppFallback(
            kind: kind, now: now.addingTimeInterval(3 * 86_400), defaults: defaults))
    }

    func testASuccessfulScheduleClearsTheNeedForAFallback() {
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .blockedByAuthorization,
                                             reason: "authorization_denied",
                                             at: now, defaults: defaults)
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .scheduled,
                                             reason: "target_day_2026-07-28",
                                             at: now.addingTimeInterval(60), defaults: defaults)

        XCTAssertFalse(AtriaNotificationAttemptStore.needsInAppFallback(
            kind: kind, now: now.addingTimeInterval(120), defaults: defaults))
    }

    func testClearRemovesTheRecord() {
        AtriaNotificationAttemptStore.record(kind: kind, outcome: .failed,
                                             reason: "boom", at: now, defaults: defaults)
        AtriaNotificationAttemptStore.clear(kind: kind, defaults: defaults)

        XCTAssertNil(AtriaNotificationAttemptStore.latest(kind: kind, defaults: defaults))
    }

    /// The scheduler and the fallback must read the same record.
    func testSchedulerAndFallbackAgreeOnTheKey() {
        XCTAssertEqual(LocalNotificationScheduler.morningCheckInKind, "morning_checkin")
    }

    // MARK: - The two morning notifications are split by what they claim

    /// They must stay separate records. Collapsing them would make "no rich
    /// summary" and "no nudge at all" indistinguishable, which is the exact
    /// ambiguity this work exists to remove.
    func testTheTwoMorningNotificationsAreTrackedSeparately() {
        XCTAssertNotEqual(LocalNotificationScheduler.morningSummaryKind,
                          LocalNotificationScheduler.morningCheckInKind)

        AtriaNotificationAttemptStore.record(kind: LocalNotificationScheduler.morningSummaryKind,
                                             outcome: .deferred,
                                             reason: "awaiting_confirmed_sleep_metric",
                                             at: now, defaults: defaults)

        XCTAssertEqual(AtriaNotificationAttemptStore.latest(
            kind: LocalNotificationScheduler.morningSummaryKind, defaults: defaults)?.reason,
                       "awaiting_confirmed_sleep_metric")
        XCTAssertNil(AtriaNotificationAttemptStore.latest(
            kind: LocalNotificationScheduler.morningCheckInKind, defaults: defaults),
                     "deferring the rich summary must not imply the plain nudge was touched")
    }

    /// A deferred rich summary must NOT raise the in-app journal prompt. The
    /// plain nudge is unconditional and still went out, so prompting again would
    /// double up on a morning that was never actually silent.
    func testADeferredRichSummaryDoesNotRaiseTheInAppFallback() {
        AtriaNotificationAttemptStore.record(kind: LocalNotificationScheduler.morningSummaryKind,
                                             outcome: .deferred,
                                             reason: "awaiting_confirmed_sleep_metric",
                                             at: now, defaults: defaults)

        XCTAssertFalse(AtriaNotificationAttemptStore.needsInAppFallback(
            kind: LocalNotificationScheduler.morningSummaryKind, now: now, defaults: defaults))
    }

    /// Source-text pin for the split itself: the rich summary requires a
    /// persisted sleep-derived metric, and the plain nudge deliberately has no
    /// such gate. If someone later "fixes" the asymmetry, the 2026-07-08 silent
    /// morning comes back.
    func testTheConfirmedBoundaryGatesOnlyTheRichSummary() throws {
        let sessions = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sessions.contains("let sleepDuration = metric.sleepDuration"),
                      "the rich summary must still require persisted sleep-derived metrics")
        XCTAssertTrue(sessions.contains("reason: \"awaiting_confirmed_sleep_metric\""),
                      "a deferred rich summary must leave a durable reason")
    }
}
