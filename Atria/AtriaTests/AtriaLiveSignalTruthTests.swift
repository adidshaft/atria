import XCTest
@testable import Atria

final class AtriaLiveSignalTruthTests: XCTestCase {
    func testConnectedTransportWithoutFreshHeartRateIsNotLive() {
        XCTAssertFalse(AtriaLiveSignalTruth.isLive(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: false
        ))
        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: false
        ), "Waiting")
        XCTAssertEqual(AtriaLiveSignalTruth.tone(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: false
        ), .waiting)
    }

    func testFreshHeartRateAndLiveStreamIsHealthy() {
        XCTAssertTrue(AtriaLiveSignalTruth.isLive(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: true
        ))
        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: true
        ), "Live")
        XCTAssertEqual(AtriaLiveSignalTruth.detailText(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: true
        ), "Heart rate live")
        XCTAssertEqual(AtriaLiveSignalTruth.tone(
            status: .connected,
            streamState: .live,
            hasRecentHeartRate: true
        ), .healthy)
    }

    func testConnectedNoSignalAndLowBatteryStayAttentionStates() {
        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .connected,
            streamState: .silentUnknown,
            hasRecentHeartRate: false
        ), "No signal")
        XCTAssertEqual(AtriaLiveSignalTruth.detailText(
            status: .connected,
            streamState: .silentUnknown,
            hasRecentHeartRate: false
        ), "Connected · no fresh heart rate")
        XCTAssertEqual(AtriaLiveSignalTruth.tone(
            status: .connected,
            streamState: .silentUnknown,
            hasRecentHeartRate: false
        ), .attention)

        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .connected,
            streamState: .lowBatteryReducedDetail,
            hasRecentHeartRate: false
        ), "Low battery")
        XCTAssertEqual(AtriaLiveSignalTruth.tone(
            status: .connected,
            streamState: .lowBatteryReducedDetail,
            hasRecentHeartRate: false
        ), .attention)
    }

    func testTransportStatesRemainQuietAndSpecific() {
        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .scanning,
            streamState: .unknown,
            hasRecentHeartRate: false
        ), "Finding")
        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .poweredOff,
            streamState: .unknown,
            hasRecentHeartRate: false
        ), "Bluetooth off")
        XCTAssertEqual(AtriaLiveSignalTruth.valueText(
            status: .disconnected,
            streamState: .unknown,
            hasRecentHeartRate: false
        ), "Off")
    }
}
