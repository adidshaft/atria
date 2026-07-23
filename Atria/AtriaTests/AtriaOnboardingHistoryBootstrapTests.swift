import XCTest
@testable import Atria

final class AtriaOnboardingHistoryBootstrapTests: XCTestCase {
    func testCompletionRequiresTerminalLivePublicationAndSameStrap() {
        XCTAssertTrue(AtriaOnboardingHistoryBootstrapPolicy.canComplete(
            durableTransportAuthorityAndLiveRestored: true,
            recoveredDataPublished: true,
            requestedPeripheralIdentifier: "strap-a",
            currentPeripheralIdentifier: "strap-a"
        ))
        XCTAssertFalse(AtriaOnboardingHistoryBootstrapPolicy.canComplete(
            durableTransportAuthorityAndLiveRestored: false,
            recoveredDataPublished: true,
            requestedPeripheralIdentifier: "strap-a",
            currentPeripheralIdentifier: "strap-a"
        ))
        XCTAssertFalse(AtriaOnboardingHistoryBootstrapPolicy.canComplete(
            durableTransportAuthorityAndLiveRestored: true,
            recoveredDataPublished: false,
            requestedPeripheralIdentifier: "strap-a",
            currentPeripheralIdentifier: "strap-a"
        ))
        XCTAssertFalse(AtriaOnboardingHistoryBootstrapPolicy.canComplete(
            durableTransportAuthorityAndLiveRestored: true,
            recoveredDataPublished: true,
            requestedPeripheralIdentifier: "strap-a",
            currentPeripheralIdentifier: "strap-b"
        ))
    }

    func testFreshStartPolicyNeverClaimsAnUnverifiedPhysicalStrapErase() {
        let policy = AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.self

        XCTAssertEqual(policy.title, "Start a new Atria timeline")
        XCTAssertTrue(policy.summary.contains("reconciles"))
        XCTAssertTrue(policy.disclosure.contains("does not send a physical-erase command"))
        XCTAssertTrue(policy.disclosure.contains("verified replay pages are acknowledged"))
        XCTAssertTrue(policy.interruptionDisclosure.contains("never discards unseen strap data"))
        XCTAssertEqual(policy.completionDetail(importedRows: 4),
                       "Existing strap records were saved. Your new Atria timeline has started.")
        XCTAssertEqual(policy.completionDetail(importedRows: 0),
                       "Strap history was verified. Your new Atria timeline has started.")
    }

    func testPersistedInFlightSnapshotCanBeReloadedForCrashResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let url = root.appendingPathComponent("bootstrap.json")
        let snapshot = AtriaOnboardingHistoryBootstrap.Snapshot(
            phase: .importing,
            peripheralIdentifier: "strap-a",
            importedRows: 120,
            attempt: 2,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            detail: "Resuming"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: url, options: .atomic)

        XCTAssertEqual(AtriaOnboardingHistoryBootstrap.load(from: url), snapshot)
    }

    func testOnboardingReasonIsAnExplicitHistoryRequest() {
        XCTAssertTrue(AtriaBLEManager.isExplicitUserOfflineSyncReason(
            "onboarding_initial_import"
        ))
    }

    func testPairingPreflightRequiresConnectedSafeIdleBoundaryEvenWithFreshHR() {
        XCTAssertTrue(AtriaBLEManager.shouldAttemptOnboardingPairingPreflight(
            linkConnected: true,
            currentConnectionHasFreshHeartRate: true,
            activeExplicitWorkout: false,
            historyTransportActive: false,
            freshHistoryOwnerCutoverPending: false,
            preflightInFlight: false,
            alreadyAttemptedForConnection: false
        ))
        let denied: [(Bool, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, false, false, false, false, false),
            (true, false, true, false, false, false, false),
            (true, false, false, true, false, false, false),
            (true, false, false, false, true, false, false),
            (true, false, false, false, false, true, false),
            (true, false, false, false, false, false, true),
        ]
        for input in denied {
            XCTAssertFalse(AtriaBLEManager.shouldAttemptOnboardingPairingPreflight(
                linkConnected: input.0,
                currentConnectionHasFreshHeartRate: input.1,
                activeExplicitWorkout: input.2,
                historyTransportActive: input.3,
                freshHistoryOwnerCutoverPending: input.4,
                preflightInFlight: input.5,
                alreadyAttemptedForConnection: input.6
            ))
        }
    }

    func testPairingPreflightSourceIsReadOnlyAndBootstrapStillRequiresFreshHR() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        let manager = try String(
            contentsOf: appURL.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let bootstrap = try String(
            contentsOf: appURL.appendingPathComponent("AtriaOnboardingHistoryBootstrap.swift"),
            encoding: .utf8
        )
        let begin = try XCTUnwrap(manager.range(
            of: "func requestOnboardingPairingPreflightIfNeeded()"
        )?.lowerBound)
        let end = try XCTUnwrap(manager.range(
            of: "/// Advance the already-armed explicit generation",
            range: begin..<manager.endIndex
        )?.lowerBound)
        let body = String(manager[begin..<end])

        XCTAssertTrue(body.contains("Cmd.getDataRange"))
        XCTAssertTrue(body.contains("[0x00]"))
        XCTAssertTrue(body.contains("mode: .withResponse"))
        XCTAssertTrue(body.contains("permitsRangeRetry"))
        XCTAssertFalse(body.contains("Cmd.sendHistoricalData"))
        XCTAssertFalse(body.contains("Cmd.historicalDataResult"))
        XCTAssertFalse(body.contains("Cmd.abortHistoricalTransmits"))
        XCTAssertFalse(body.contains("historyTransportPhaseFence.activate"))
        XCTAssertFalse(body.contains("cancelPeripheralConnection"))
        XCTAssertFalse(body.contains("lastAcceptedHRAt ="))
        XCTAssertFalse(body.contains("heartRate ="))

        let request = try XCTUnwrap(bootstrap.range(
            of: "ble.requestOnboardingPairingPreflightIfNeeded()"
        )?.lowerBound)
        let freshGate = try XCTUnwrap(bootstrap.range(
            of: "guard ble.currentConnectionHasFreshHeartRate else"
        )?.lowerBound)
        let historyRequest = try XCTUnwrap(bootstrap.range(
            of: ".requestOfflineHistoricalSyncAwaitingCompletion("
        )?.lowerBound)
        XCTAssertLessThan(request, freshGate)
        XCTAssertTrue(bootstrap.contains("ble.$onboardingPairingPreflightInFlight"))
        XCTAssertTrue(bootstrap.contains(".filter { !$0 }"))
        let inFlightReturn = try XCTUnwrap(bootstrap.range(
            of: "if ble.onboardingPairingPreflightInFlight"
        )?.lowerBound)
        XCTAssertLessThan(request, inFlightReturn)
        XCTAssertLessThan(inFlightReturn, freshGate)
        XCTAssertLessThan(request, historyRequest)
        XCTAssertTrue(String(bootstrap[inFlightReturn..<freshGate]).contains("return"),
                      "pairing preflight must finish before fresh-HR import admission")
    }

    func testOnboardingReentersBootstrapWhenPairingPreflightFinishes() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let flowURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOnboardingFlow.swift")
        let flow = try String(contentsOf: flowURL, encoding: .utf8)
        let observer = try XCTUnwrap(flow.range(
            of: ".onChange(of: ble.onboardingPairingPreflightInFlight)"
        )?.lowerBound)
        let observerBody = String(flow[observer...].prefix(420))
        XCTAssertTrue(observerBody.contains("guard wasInFlight, !isInFlight else { return }"))
        XCTAssertTrue(observerBody.contains("historyBootstrap.startOrResumeIfPossible()"))
    }

    func testBootstrapSourceNamesTheFailClosedCompletionBoundaries() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOnboardingHistoryBootstrap.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("every exact retirement"))
        XCTAssertTrue(source.contains("raw+identity fsync"))
        XCTAssertTrue(source.contains("HISTORY_COMPLETE"))
        XCTAssertTrue(source.contains("matched 22/00"))
        XCTAssertTrue(source.contains("fresh live HR"))
        XCTAssertTrue(source.contains("all five receipts"))
        XCTAssertTrue(source.contains("requestAndAwaitRecoveredDataPublication"))
        XCTAssertTrue(source.contains("Your new Atria timeline has started"))
    }

    func testOnboardingTransportAuthorityRequiresDurableTerminalOrVerifiedEmptyCursor() {
        XCTAssertTrue(AtriaBLEManager.onboardingHistoryTransportAuthorityIsValid(
            terminalReceived: true,
            durableTerminalAuthority: true,
            verifiedEmptyCursor: false
        ))
        XCTAssertFalse(AtriaBLEManager.onboardingHistoryTransportAuthorityIsValid(
            terminalReceived: true,
            durableTerminalAuthority: false,
            verifiedEmptyCursor: false
        ))
        XCTAssertTrue(AtriaBLEManager.onboardingHistoryTransportAuthorityIsValid(
            terminalReceived: false,
            durableTerminalAuthority: false,
            verifiedEmptyCursor: true
        ))
        XCTAssertFalse(AtriaBLEManager.onboardingHistoryTransportAuthorityIsValid(
            terminalReceived: false,
            durableTerminalAuthority: false,
            verifiedEmptyCursor: false
        ))
        XCTAssertFalse(AtriaBLEManager.onboardingConsumerReceiptsAreComplete(
            required: true,
            receipted: false
        ))
        XCTAssertTrue(AtriaBLEManager.onboardingConsumerReceiptsAreComplete(
            required: true,
            receipted: true
        ))
        XCTAssertTrue(AtriaBLEManager.onboardingConsumerReceiptsAreComplete(
            required: false,
            receipted: false
        ))
    }

    func testAutomaticProjectionDefersForHistoryOrIncompleteOnboarding() {
        XCTAssertTrue(SessionStore.shouldDeferAutomaticRecoveredDataRecomputation(
            historyTransportOwnsLink: true,
            onboardingComplete: true,
            allowsIncompleteOnboarding: false
        ))
        XCTAssertTrue(SessionStore.shouldDeferAutomaticRecoveredDataRecomputation(
            historyTransportOwnsLink: false,
            onboardingComplete: false,
            allowsIncompleteOnboarding: false
        ))
        XCTAssertFalse(SessionStore.shouldDeferAutomaticRecoveredDataRecomputation(
            historyTransportOwnsLink: false,
            onboardingComplete: false,
            allowsIncompleteOnboarding: true
        ))
        XCTAssertFalse(SessionStore.shouldDeferAutomaticRecoveredDataRecomputation(
            historyTransportOwnsLink: false,
            onboardingComplete: true,
            allowsIncompleteOnboarding: false
        ))
    }
}
