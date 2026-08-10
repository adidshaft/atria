import CoreBluetooth
import XCTest
@testable import Atria

@MainActor
final class AtriaBLEObservedConnectionIdentityTests: XCTestCase {
    func testProvisionalDidConnectDoesNotPersistFirstUseIdentity() throws {
        let suiteName = "AtriaBLEObservedConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = UUID()

        XCTAssertFalse(
            AtriaBLEManager.persistObservedConnectedIdentity(
                identifier,
                evidence: .provisionalConnection,
                standardHeartRateCandidateWasWhoopQualified: true,
                defaults: defaults
            )
        )
        XCTAssertNil(
            defaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            )
        )
    }

    func testWhoopServicePromotesFirstUseIdentity() throws {
        let suiteName = "AtriaBLEObservedConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = UUID()

        XCTAssertTrue(
            AtriaBLEManager.persistObservedConnectedIdentity(
                identifier,
                evidence: .whoopService,
                standardHeartRateCandidateWasWhoopQualified: false,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            identifier.uuidString
        )
        XCTAssertFalse(
            AtriaBLEManager.persistObservedConnectedIdentity(
                identifier,
                evidence: .whoopService,
                standardHeartRateCandidateWasWhoopQualified: false,
                defaults: defaults
            )
        )
    }

    func testQualifiedStandardHeartRatePromotesButGeneric180DDoesNot() throws {
        let rejectedSuite = "AtriaBLEObservedConnectionIdentityTests.rejected.\(UUID().uuidString)"
        let rejectedDefaults = try XCTUnwrap(UserDefaults(suiteName: rejectedSuite))
        defer { rejectedDefaults.removePersistentDomain(forName: rejectedSuite) }
        let rejectedIdentifier = UUID()

        XCTAssertFalse(
            AtriaBLEManager.persistObservedConnectedIdentity(
                rejectedIdentifier,
                evidence: .standardHeartRateMeasurement,
                standardHeartRateCandidateWasWhoopQualified: false,
                defaults: rejectedDefaults
            )
        )
        XCTAssertNil(
            rejectedDefaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            "generic 180D/2A37 is not WHOOP identity authority"
        )

        let qualifiedSuite = "AtriaBLEObservedConnectionIdentityTests.qualified.\(UUID().uuidString)"
        let qualifiedDefaults = try XCTUnwrap(UserDefaults(suiteName: qualifiedSuite))
        defer { qualifiedDefaults.removePersistentDomain(forName: qualifiedSuite) }
        let qualifiedIdentifier = UUID()
        XCTAssertTrue(
            AtriaBLEManager.persistObservedConnectedIdentity(
                qualifiedIdentifier,
                evidence: .standardHeartRateMeasurement,
                standardHeartRateCandidateWasWhoopQualified: true,
                defaults: qualifiedDefaults
            )
        )
        XCTAssertEqual(
            qualifiedDefaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            qualifiedIdentifier.uuidString
        )
    }

    func testStaleSavedIdentityChangesOnlyAfterAuthoritativeValidation() throws {
        let suiteName = "AtriaBLEObservedConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldIdentifier = UUID()
        let newIdentifier = UUID()
        defaults.set(
            oldIdentifier.uuidString,
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        )

        XCTAssertFalse(
            AtriaBLEManager.persistObservedConnectedIdentity(
                newIdentifier,
                evidence: .provisionalConnection,
                standardHeartRateCandidateWasWhoopQualified: true,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            oldIdentifier.uuidString
        )
        XCTAssertTrue(
            AtriaBLEManager.persistObservedConnectedIdentity(
                newIdentifier,
                evidence: .whoopService,
                standardHeartRateCandidateWasWhoopQualified: false,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            newIdentifier.uuidString
        )
    }

    func testOnlyExactPoweredOffProducesBluetoothOffStatus() {
        let centralStates: [CBManagerState] = [
            .unknown, .resetting, .unsupported, .unauthorized, .poweredOff,
            .poweredOn
        ]
        let peripheralStates: [CBPeripheralState?] = [
            nil, .disconnected, .connecting, .connected, .disconnecting
        ]

        for centralState in centralStates {
            for peripheralState in peripheralStates {
                for hasSavedStrap in [false, true] {
                    for isActivelyScanning in [false, true] {
                        let result = AtriaBLEManager.derivedConnectionStatus(
                            centralState: centralState,
                            peripheralState: peripheralState,
                            hasSavedStrap: hasSavedStrap,
                            isActivelyScanning: isActivelyScanning
                        )
                        XCTAssertEqual(
                            result == .poweredOff,
                            centralState == .poweredOff,
                            "central=\(centralState.rawValue) peripheral=\(String(describing: peripheralState)) saved=\(hasSavedStrap) scan=\(isActivelyScanning)"
                        )
                    }
                }
            }
        }
    }

    func testUnavailableStatesStayDistinctFromPoweredOff() {
        XCTAssertEqual(
            AtriaBLEManager.derivedConnectionStatus(
                centralState: .unauthorized,
                peripheralState: .connected,
                hasSavedStrap: true,
                isActivelyScanning: true
            ),
            .disconnected
        )
        XCTAssertEqual(
            AtriaBLEManager.derivedConnectionStatus(
                centralState: .resetting,
                peripheralState: .disconnected,
                hasSavedStrap: true,
                isActivelyScanning: false
            ),
            .connecting
        )
        XCTAssertEqual(
            AtriaBLEManager.derivedConnectionStatus(
                centralState: .unknown,
                peripheralState: .connected,
                hasSavedStrap: false,
                isActivelyScanning: false
            ),
            .connected
        )
    }

    func testRetiredExactCallbackSourceCannotReachIdentityMutation() throws {
        let fence = AtriaBLECallbackEpochFence()
        let identifier = UUID()
        let retiredPeripheral = NSObject()
        let replacementPeripheral = NSObject()
        _ = fence.activate(
            peripheralID: identifier,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral)
        )
        let retiredSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: identifier,
            peripheralObjectID: ObjectIdentifier(retiredPeripheral),
            peripheralConnected: true
        ))

        _ = fence.activate(
            peripheralID: identifier,
            peripheralObjectID: ObjectIdentifier(replacementPeripheral)
        )
        XCTAssertFalse(
            fence.accepts(source: retiredSource, peripheralConnected: true),
            "same UUID is insufficient after an object-distinct owner replaces the source"
        )
        let replacementSource = try XCTUnwrap(fence.captureIfAccepted(
            peripheralID: identifier,
            peripheralObjectID: ObjectIdentifier(replacementPeripheral),
            peripheralConnected: true
        ))
        XCTAssertNotEqual(
            retiredSource.peripheralObjectID,
            replacementSource.peripheralObjectID
        )
        XCTAssertNotEqual(retiredSource.epoch, replacementSource.epoch)

        let source = try managerSource()
        let helperStart = try XCTUnwrap(source.range(
            of: "private func recordLinkObservedConnected("
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private func resetLinkDiagnosticsForDebugLaunch(",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(
            source[helperStart.lowerBound..<helperEnd.lowerBound]
        )
        XCTAssertTrue(helper.contains(
            "callbackSource: AtriaBLECallbackEpochFence.Source"
        ))
        XCTAssertFalse(helper.contains("callbackEpoch: UInt64"))

        let exactSourceGuard = try XCTUnwrap(helper.range(
            of: "guard acceptsBLECallback(\n                source: callbackSource,\n                peripheral: peripheral"
        ))
        let firstPromotionMutation = try XCTUnwrap(helper.range(
            of: "workoutHistoryPreemptionSuccessorGate.retire()"
        ))
        let durableIdentityWrite = try XCTUnwrap(helper.range(
            of: "Self.persistObservedConnectedIdentity("
        ))
        let successMutation = try XCTUnwrap(helper.range(
            of: "durableConnectedIdentityRecordedEpoch = callbackSource.epoch"
        ))
        XCTAssertLessThan(
            exactSourceGuard.lowerBound,
            firstPromotionMutation.lowerBound
        )
        XCTAssertLessThan(
            exactSourceGuard.lowerBound,
            durableIdentityWrite.lowerBound
        )
        XCTAssertLessThan(
            exactSourceGuard.lowerBound,
            successMutation.lowerBound
        )
    }

    func testDuplicateSavedDidConnectStillRunsIdempotentRecoveryReducers() throws {
        let source = try managerSource()
        let helperStart = try XCTUnwrap(source.range(
            of: "private func recordLinkConnected(peripheral: CBPeripheral)"
        ))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private func recordLinkObservedConnected(",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helper = String(
            source[helperStart.lowerBound..<helperEnd.lowerBound]
        )
        let savedIdentityGuard = try XCTUnwrap(helper.range(
            of: "guard defaults.string(forKey: LinkDefaults.savedPeripheralUUID)"
        ))
        let duplicateGate = try XCTUnwrap(helper.range(
            of: "if durableConnectedIdentityRecordedEpoch == callbackEpoch"
        ))
        let firstSuccessStamp = try XCTUnwrap(helper.range(
            of: "durableConnectedIdentityRecordedEpoch = callbackEpoch",
            range: duplicateGate.upperBound..<helper.endIndex
        ))
        XCTAssertLessThan(
            savedIdentityGuard.lowerBound,
            duplicateGate.lowerBound,
            "a provisional different UUID must return before duplicate handling"
        )

        let duplicatePath = String(
            helper[duplicateGate.lowerBound..<firstSuccessStamp.lowerBound]
        )
        XCTAssertTrue(duplicatePath.contains(
            "scheduleRangeLossBackfillIfNeeded(reason: \"did_connect\")"
        ))
        XCTAssertTrue(duplicatePath.contains(
            "reconcileHistoricalRecoveryPresentation(reason: \"did_connect\")"
        ))
        XCTAssertTrue(duplicatePath.contains("return"))
        XCTAssertFalse(duplicatePath.contains("LinkDefaults.successes"))
    }

    private func managerSource() throws -> String {
        let managerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        return try String(contentsOf: managerURL, encoding: .utf8)
    }
}
