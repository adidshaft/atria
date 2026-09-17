import XCTest
@testable import Atria

final class AtriaLiveHeartRatePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testContactLossDoesNotPresentCachedHeartRate() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 78,
            sensorHasContact: false,
            status: .connected,
            latestSampleHeartRate: 78,
            latestSampleAt: now.addingTimeInterval(-1),
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testStaleTimestampDoesNotPresentCachedHeartRate() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 78,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 78,
            latestSampleAt: now.addingTimeInterval(-7),
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testMissingTimestampDoesNotPresentCachedHeartRate() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 78,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: nil,
            latestSampleAt: nil,
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testFarFutureTimestampDoesNotRemainLive() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 78,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 78,
            latestSampleAt: now.addingTimeInterval(7),
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testRecentLegitimateHeartRateIsPreserved() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 0,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 78,
            latestSampleAt: now.addingTimeInterval(-5),
            now: now
        )

        XCTAssertEqual(heartRate, 78)
    }

    func testDisconnectedStateDoesNotPresentRecentHeartRate() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 78,
            sensorHasContact: true,
            status: .disconnected,
            latestSampleHeartRate: 78,
            latestSampleAt: now.addingTimeInterval(-1),
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testFutureTimestampDoesNotQualifyAsRecent() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 78,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 78,
            latestSampleAt: now.addingTimeInterval(1),
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testWorkoutHoldKeepsLastBPMWhenLivePulseZeros() {
        XCTAssertEqual(AtriaWorkoutHeartRateHold.displayed(live: 142, lastKnown: 88, retained: 61), 142)
        XCTAssertEqual(AtriaWorkoutHeartRateHold.displayed(live: 0, lastKnown: 88, retained: 61), 88)
        XCTAssertEqual(AtriaWorkoutHeartRateHold.displayed(live: 0, lastKnown: 0, retained: 61), 61)
        XCTAssertEqual(AtriaWorkoutHeartRateHold.displayed(live: 0, lastKnown: 0, retained: 0), 0)
    }

    func testWorkoutSessionBoundaryDoesNotClearDisplayHeartRate() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func resetLiveSessionStateAfterR10Boundary"))
        let end = try XCTUnwrap(source.range(of: "private func rememberDisplayHeartRate",
                                            range: start.upperBound..<source.endIndex))
        let reset = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(reset.contains("lastAcceptedHRAt = nil"))
        XCTAssertFalse(reset.contains("lastKnownDisplayHeartRate"),
                       "Start must not blank the last real BPM the HUD still needs")
        XCTAssertTrue(source.contains("rememberDisplayHeartRate(rate, at: sampleTime)"))
        XCTAssertTrue(source.contains("rememberDisplayHeartRate(last.bpm, at: last.t)"))
    }
}
