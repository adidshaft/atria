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
}
