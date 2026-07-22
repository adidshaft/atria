import XCTest

final class AtriaBLEBatteryTransportPolicyStructureTests: XCTestCase {
    func testBatteryTransportPolicyOwnsExtractedStaticSurface() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let policy = try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEBatteryTransportPolicy.swift"),
            encoding: .utf8
        )

        let functionNames = [
            "shouldRequestBatteryRefresh",
            "shouldRequestProprietaryBatteryRefresh",
            "parseProprietaryBatteryResponse",
            "batteryNotificationRecoveryAction",
            "standardBatteryRefreshAction",
            "existingBatteryNotificationAction",
            "batteryLevelIsFresh",
            "notificationLeaseSupportsBatteryDisplay",
            "batteryNotificationConfirmationSupportsCurrentConnection",
            "batteryNotificationTransportEvidenceIsUsable",
            "batteryRestorationPreservesNotificationEpoch",
            "restoredCachedBatteryNotificationCanReuseEpoch",
            "recentReconnectBatteryBaselineIsDisplayEligible",
            "freshConnectedCachedBatteryBaselineIsDisplayEligible",
            "reconnectBatteryBaselineIsAwaitingProof",
            "reconnectBatteryDisplayLevel",
            "shouldPromoteReconnectBatteryBaseline",
            "batteryReconnectBaselineSourceIsLeaseEligible",
            "batteryConfirmationRetryDelay",
            "batteryChargeSourceCanAuthorizeCharging",
            "persistedBatteryNotificationLeaseSupportsDisplay",
            "batteryCacheSourceIsDisplayEligible",
            "invalidateImplausibleCachedBatteryTransitionIfNeeded",
            "invalidateUnverifiedCachedBatterySentinelIfNeeded",
        ]

        for name in functionNames {
            let declaration = "nonisolated static func \(name)("
            XCTAssertFalse(
                manager.contains(declaration),
                "AtriaBLEManager.swift must not regain extracted battery policy \(name)"
            )
            XCTAssertTrue(
                policy.contains(declaration),
                "AtriaBLEBatteryTransportPolicy.swift must own \(name)"
            )
        }

        for name in [
            "StandardBatteryRefreshAction",
            "BatteryNotificationRecoveryAction",
            "ExistingBatteryNotificationAction",
        ] {
            let declaration = "enum \(name): Equatable"
            XCTAssertFalse(manager.contains(declaration))
            XCTAssertTrue(policy.contains(declaration))
        }

        for forbidden in [
            "import CoreBluetooth",
            "import UIKit",
            "@Published",
            "CBCentralManager",
            "setNotifyValue(",
            "writeValue(",
            "assignIfChanged(",
            "Task {",
            "Task.detached",
            "Timer(",
        ] {
            XCTAssertFalse(
                policy.contains(forbidden),
                "Battery transport policy must not own runtime side effect \(forbidden)"
            )
        }

        let migrationStart = try XCTUnwrap(policy.range(
            of: "nonisolated static func invalidateImplausibleCachedBatteryTransitionIfNeeded("
        ))
        let ordinaryPolicy = policy[..<migrationStart.lowerBound]
        XCTAssertFalse(ordinaryPolicy.contains("defaults.set("))
        XCTAssertFalse(ordinaryPolicy.contains("removeObject("))

        let nonStaticFunctions = policy
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                $0.hasPrefix("func ")
                    || $0.hasPrefix("private func ")
                    || $0.hasPrefix("fileprivate func ")
                    || $0.hasPrefix("static func ")
            }
        XCTAssertTrue(
            nonStaticFunctions.isEmpty,
            "Every extracted policy entry point must remain nonisolated static: \(nonStaticFunctions)"
        )
    }
}
