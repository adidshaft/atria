import XCTest
@testable import Atria

final class AtriaStrapPowerPolicyTests: XCTestCase {
    func testChargingLeaseExpiresWithoutIndependentRenewal() {
        let evidenceAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            AtriaBLEManager.batteryChargeLeaseDecision(
                status: .charging,
                lastEvidenceAt: evidenceAt,
                now: evidenceAt.addingTimeInterval(89)
            ),
            .retain(remaining: 1)
        )
        XCTAssertEqual(
            AtriaBLEManager.batteryChargeLeaseDecision(
                status: .charging,
                lastEvidenceAt: evidenceAt,
                now: evidenceAt.addingTimeInterval(91)
            ),
            .expire,
            "Charging must not survive past the 90-second independently verified lease"
        )
        XCTAssertEqual(
            AtriaBLEManager.batteryChargeLeaseDecision(
                status: .charging,
                lastEvidenceAt: nil,
                now: evidenceAt
            ),
            .expire,
            "Charging without a verification timestamp must fail closed"
        )
        XCTAssertEqual(
            AtriaBLEManager.batteryChargeLeaseDecision(
                status: .charging,
                lastEvidenceAt: evidenceAt.addingTimeInterval(1),
                now: evidenceAt
            ),
            .expire,
            "Future-dated evidence must not create an unbounded lease"
        )
    }

    func testChargerRemovalEvidenceCannotBeOverruledByLatchedPoweredBits() {
        XCTAssertNil(AtriaBLEManager.acceptedBatteryChargeStatus(
            .charging,
            batteryLevel: 58,
            hasPlausibleRiseEvidence: true
        ), "a raw 2A1B powered bit cannot create or renew Charging")
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryChargeStatus(
            .charging,
            batteryLevel: 58,
            hasPlausibleRiseEvidence: false,
            currentConnectionPowerStateConfirmed: true
        ), .charging,
        "a current-link 2A1B notification must show an attached charger before SOC rises")
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryEventChargeStatus(
            reportedIsCharging: true,
            batteryLevel: 58
        ), .levelOnly, "a replayed stream-4 charge byte cannot keep Charging visible")
        XCTAssertEqual(AtriaBLEManager.chargeEvidenceFromBatteryLevelChange(
            previousLevel: 58,
            newLevel: 57
        ), .notCharging)

        let rise = AtriaBLEManager.BatteryRiseCandidate(
            startLevel: 54,
            startAt: Date(timeIntervalSince1970: 1_000),
            lastLevel: 58,
            lastAt: Date(timeIntervalSince1970: 1_060),
            confirmations: 3
        )
        XCTAssertNil(AtriaBLEManager.batteryRiseCandidateAfterExplicitChargeStatus(
            .notCharging,
            current: rise
        ), "charger-removal truth must revoke all pre-removal rise evidence")
    }

    func testReconnectCannotRetainStaleChargingProjection() {
        let now = Date(timeIntervalSince1970: 20_000)
        XCTAssertTrue(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-90),
            batteryRecentlyDropping: false,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-91),
            batteryRecentlyDropping: false,
            now: now
        ))
        XCTAssertFalse(AtriaBLEManager.shouldRetainPersistedChargingAcrossReconnect(
            persistedStatus: .charging,
            persistedAt: now.addingTimeInterval(-1),
            batteryRecentlyDropping: true,
            now: now
        ), "a detected drop is immediate charger-removal evidence")
    }

    func testCurrentLinkBatteryStatusNotificationCanAuthorizeShortChargingLease() {
        let connectedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(AtriaBLEManager.batteryStatusNotificationCanAuthorizeCharging(
            peripheralConnected: true,
            connectionStartedAt: connectedAt,
            notificationConfirmedAt: connectedAt.addingTimeInterval(1),
            statusReceivedAt: connectedAt.addingTimeInterval(2)
        ))
        XCTAssertFalse(AtriaBLEManager.batteryStatusNotificationCanAuthorizeCharging(
            peripheralConnected: true,
            connectionStartedAt: connectedAt,
            notificationConfirmedAt: connectedAt.addingTimeInterval(-1),
            statusReceivedAt: connectedAt.addingTimeInterval(2)
        ), "a cached prior-link confirmation cannot authorize charging")
        XCTAssertFalse(AtriaBLEManager.batteryStatusNotificationCanAuthorizeCharging(
            peripheralConnected: true,
            connectionStartedAt: connectedAt,
            notificationConfirmedAt: connectedAt.addingTimeInterval(3),
            statusReceivedAt: connectedAt.addingTimeInterval(2)
        ), "a status sample cannot be authorized by a later CCCD callback")
    }

    func testChargePersistenceDoesNotRefreshBatteryLevelTimestamp() throws {
        let suite = "AtriaStrapPowerPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(58, forKey: AtriaBLEManager.BatteryDefaults.level)
        defaults.set(1_000.0, forKey: AtriaBLEManager.BatteryDefaults.at)
        defaults.set("live_2A19", forKey: AtriaBLEManager.BatteryDefaults.source)

        AtriaBLEManager.persistBatteryChargeStatusProjection(
            .levelOnly,
            source: "live_charge_timeout",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(defaults.integer(forKey: AtriaBLEManager.BatteryDefaults.level), 58)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.at), 1_000)
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.source), "live_2A19")
        XCTAssertEqual(defaults.string(forKey: AtriaBLEManager.BatteryDefaults.chargeStatus),
                       AtriaBLEManager.BatteryChargeStatus.levelOnly.rawValue)
        XCTAssertEqual(defaults.double(forKey: AtriaBLEManager.BatteryDefaults.chargeAt), 2_000)
    }
}
