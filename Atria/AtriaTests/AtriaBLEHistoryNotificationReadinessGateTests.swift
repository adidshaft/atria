import XCTest
@testable import Atria

final class AtriaBLEHistoryNotificationReadinessGateTests: XCTestCase {
    private let required: Set<String> = ["rx", "stream4", "stream5", "stream7"]

    func testTXDiscoveryAloneCannotOpenHistoryCommandBarrier() {
        let gate = AtriaBLEHistoryNotificationReadinessGate(
            requiredNotifications: required
        )

        XCTAssertEqual(
            gate.decision(
                linkConnected: true,
                txAvailable: true,
                activeNotifications: ["rx"]
            ),
            .waitingForNotifications(missing: ["stream4", "stream5", "stream7"])
        )
    }

    func testBarrierOpensOnlyWithConnectedLinkTXAndEveryRequiredNotification() {
        let gate = AtriaBLEHistoryNotificationReadinessGate(
            requiredNotifications: required
        )

        XCTAssertEqual(
            gate.decision(
                linkConnected: false,
                txAvailable: true,
                activeNotifications: required
            ),
            .waitingForConnectedLink
        )
        XCTAssertEqual(
            gate.decision(
                linkConnected: true,
                txAvailable: false,
                activeNotifications: required
            ),
            .waitingForTX
        )
        XCTAssertEqual(
            gate.decision(
                linkConnected: true,
                txAvailable: true,
                activeNotifications: required
            ),
            .ready
        )
    }

    func testNotificationBecomingInactiveClosesBarrierAgain() {
        let gate = AtriaBLEHistoryNotificationReadinessGate(
            requiredNotifications: required
        )

        XCTAssertEqual(
            gate.decision(
                linkConnected: true,
                txAvailable: true,
                activeNotifications: required.subtracting(["stream5"])
            ),
            .waitingForNotifications(missing: ["stream5"])
        )
    }

    func testWriteConfirmationWindowCoversObservedPhysicalLatencyAndRemainsBounded() {
        let observedCallbackLatency: TimeInterval = 8.6

        XCTAssertGreaterThan(
            AtriaBLEHistoryWriteConfirmationPolicy.timeout,
            observedCallbackLatency
        )
        XCTAssertEqual(AtriaBLEHistoryWriteConfirmationPolicy.timeout, 15)
        XCTAssertEqual(AtriaBLEHistoryWriteConfirmationPolicy.pollInterval, 0.1)
        XCTAssertEqual(AtriaBLEHistoryWriteConfirmationPolicy.maximumPollAttempts, 150)
    }

    func testPostNotificationSettleCoversSuccessfulPhysicalCadence() {
        let successfulFinalNotifyToWriteDelay: TimeInterval = 2.77
        let failedFinalNotifyToWriteDelay: TimeInterval = 0.155

        XCTAssertEqual(
            AtriaBLEHistoryWriteConfirmationPolicy.postNotificationSettleInterval,
            3
        )
        XCTAssertGreaterThan(
            AtriaBLEHistoryWriteConfirmationPolicy.postNotificationSettleInterval,
            successfulFinalNotifyToWriteDelay
        )
        XCTAssertGreaterThan(
            AtriaBLEHistoryWriteConfirmationPolicy.postNotificationSettleInterval,
            failedFinalNotifyToWriteDelay
        )
    }
}
