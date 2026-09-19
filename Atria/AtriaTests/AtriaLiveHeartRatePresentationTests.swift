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
            latestSampleAt: now.addingTimeInterval(-16),
            now: now
        )

        XCTAssertEqual(heartRate, 0)
    }

    func testTenSecondIdleBeatStillPresents() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 82,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 82,
            latestSampleAt: now.addingTimeInterval(-10.3),
            now: now
        )

        XCTAssertEqual(heartRate, 82)
    }

    func testConnectingWithFreshSamplePresentsHeartRate() {
        let heartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: 82,
            sensorHasContact: true,
            status: .connecting,
            latestSampleHeartRate: 82,
            latestSampleAt: now.addingTimeInterval(-4),
            now: now
        )

        XCTAssertEqual(heartRate, 82)
    }

    func testLiveHeartRateWindowMatchesDiagnosisStaleSeconds() {
        XCTAssertEqual(AtriaHomeModel.liveHeartRateFreshnessInterval,
                       AtriaDiagnosisReport.liveStaleSeconds)
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

    func testDiagnosisPrefersFreshSessionBeatOverFrozenPulse() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let displayed = AtriaHomeModel.diagnosisDisplayedHeartRate(
            pulseHeartRate: 51,
            bleHeartRate: 0,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 76,
            latestSampleAt: now.addingTimeInterval(-0.7),
            retained: 51,
            now: now
        )
        XCTAssertEqual(displayed, 76)
    }

    func testDiagnosisFallsBackToPulseWhenSessionIsStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let displayed = AtriaHomeModel.diagnosisDisplayedHeartRate(
            pulseHeartRate: 51,
            bleHeartRate: 0,
            sensorHasContact: true,
            status: .connected,
            latestSampleHeartRate: 76,
            latestSampleAt: now.addingTimeInterval(-20),
            retained: 48,
            now: now
        )
        XCTAssertEqual(displayed, 51)
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

    func testDiagnosisHeartRateAgeUsesSessionSampleWhenAcceptedClockIsNil() {
        let sample = now.addingTimeInterval(-2)
        XCTAssertEqual(
            AtriaHomeModel.diagnosisHeartRateAgeSeconds(
                lastAcceptedAt: nil,
                latestSampleAt: sample,
                now: now
            ),
            2
        )
        XCTAssertEqual(
            AtriaHomeModel.latestHeartRateCapturedAt(
                lastAcceptedAt: now.addingTimeInterval(-8),
                latestSampleAt: sample
            ),
            sample
        )
        XCTAssertNil(
            AtriaHomeModel.diagnosisHeartRateAgeSeconds(
                lastAcceptedAt: nil,
                latestSampleAt: nil,
                now: now
            )
        )
    }

    func testDiagnosisIMUAgeUsesCompactAssemblyWhenR10ClockIsNil() {
        let compact = now.addingTimeInterval(-4)
        XCTAssertEqual(
            AtriaHomeModel.diagnosisIMUAgeSeconds(
                motionCapturedAt: nil,
                compactAssembledAt: compact,
                now: now
            ),
            4
        )
        XCTAssertEqual(
            AtriaHomeModel.diagnosisIMUAgeSeconds(
                motionCapturedAt: now.addingTimeInterval(-12),
                compactAssembledAt: compact,
                now: now
            ),
            4
        )
        XCTAssertEqual(
            AtriaHomeModel.diagnosisIMUAgeSeconds(
                motionCapturedAt: nil,
                compactAssembledAt: now.addingTimeInterval(-2400),
                compactPacketAt: now.addingTimeInterval(-3),
                now: now
            ),
            3,
            "sitting skip must not report IMU missing while type-33 packets are live"
        )
        XCTAssertNil(
            AtriaHomeModel.diagnosisIMUAgeSeconds(
                motionCapturedAt: nil,
                compactAssembledAt: nil,
                now: now
            )
        )
    }
}
