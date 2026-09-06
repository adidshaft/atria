import XCTest
import UserNotifications
@testable import Atria

/// The delivery-posture model behind the 2026-08-28 owner report: months of
/// notifications delivered provisionally (quietly) with nothing in the app
/// saying so. The classification and the one-shot upgrade-card rule are pure.
final class AtriaNotificationProminenceTests: XCTestCase {

    // MARK: - Classification

    func testProvisionalIsQuietAndUpgradeableInApp() {
        let state = AtriaNotificationProminence.classify(.provisional)
        XCTAssertEqual(state, .quiet)
        XCTAssertTrue(state.canRequestUpgradeInApp)
    }

    func testAuthorizedAndEphemeralAreFull() {
        XCTAssertEqual(AtriaNotificationProminence.classify(.authorized), .full)
        XCTAssertEqual(AtriaNotificationProminence.classify(.ephemeral), .full)
        XCTAssertFalse(AtriaNotificationProminence.full.canRequestUpgradeInApp)
    }

    func testDeniedNeedsSystemSettingsNotAnInAppPrompt() {
        let state = AtriaNotificationProminence.classify(.denied)
        XCTAssertEqual(state, .denied)
        XCTAssertFalse(state.canRequestUpgradeInApp,
                       "requestAuthorization after a denial is a silent no-op; "
                           + "only iOS Settings can change it")
    }

    // MARK: - The one-shot Today card

    func testQuietWithRealDeliveriesShowsTheCard() {
        XCTAssertTrue(AtriaNotificationProminenceUpgradeCard.shouldShow(
            prominence: .quiet, hasDeliveredQuietly: true,
            dismissed: false, masterToggleOn: true))
    }

    func testQuietWithNothingDeliveredYetStaysSilent() {
        XCTAssertFalse(AtriaNotificationProminenceUpgradeCard.shouldShow(
            prominence: .quiet, hasDeliveredQuietly: false,
            dismissed: false, masterToggleOn: true),
            "before anything was delivered quietly the posture costs nothing")
    }

    func testDismissalIsForever() {
        XCTAssertFalse(AtriaNotificationProminenceUpgradeCard.shouldShow(
            prominence: .quiet, hasDeliveredQuietly: true,
            dismissed: true, masterToggleOn: true))
    }

    func testADenialNeverGetsTheCard() {
        XCTAssertFalse(AtriaNotificationProminenceUpgradeCard.shouldShow(
            prominence: .denied, hasDeliveredQuietly: true,
            dismissed: false, masterToggleOn: true),
            "the wearer already answered; the Settings row stays honest instead")
    }

    func testFullAuthorizationNeverGetsTheCard() {
        XCTAssertFalse(AtriaNotificationProminenceUpgradeCard.shouldShow(
            prominence: .full, hasDeliveredQuietly: true,
            dismissed: false, masterToggleOn: true))
    }

    func testMasterToggleOffSuppressesTheCard() {
        XCTAssertFalse(AtriaNotificationProminenceUpgradeCard.shouldShow(
            prominence: .quiet, hasDeliveredQuietly: true,
            dismissed: false, masterToggleOn: false))
    }

    // MARK: - Quiet-delivery evidence

    func testEventKeyLedgerCountsAsEvidence() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertFalse(AtriaNotificationProminenceUpgradeCard
            .hasQuietDeliveryEvidence(defaults: defaults))
        defaults.set(["sleep_review|123"], forKey: "atria.notification.eventKeys.v1")
        XCTAssertTrue(AtriaNotificationProminenceUpgradeCard
            .hasQuietDeliveryEvidence(defaults: defaults))
        defaults.removePersistentDomain(forName: #function)
    }

    func testScheduledMorningAttemptCountsAsEvidence() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        AtriaNotificationAttemptStore.record(kind: "morning_checkin",
                                             outcome: .scheduled,
                                             reason: "target_day_x",
                                             defaults: defaults)
        XCTAssertTrue(AtriaNotificationProminenceUpgradeCard
            .hasQuietDeliveryEvidence(defaults: defaults))
        defaults.removePersistentDomain(forName: #function)
    }
}
