import XCTest
@testable import Atria

final class AtriaDiagnosisReportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AtriaDiagnosisReport.documentsDirectoryOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-diagnosis-\(UUID().uuidString)", isDirectory: true)
        AtriaDiagnosisReport.resetForTesting()
    }

    override func tearDown() {
        AtriaDiagnosisReport.resetForTesting()
        if let directory = AtriaDiagnosisReport.documentsDirectoryOverride {
            try? FileManager.default.removeItem(at: directory)
        }
        AtriaDiagnosisReport.documentsDirectoryOverride = nil
        super.tearDown()
    }

    func testDiscrepanciesNameOvernightVersusTodayRecoveryAndZeroHRWorkout() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "93",
            status: .connected,
            recovering: true,
            reconnectAgeSeconds: 12,
            reconnectReason: "workout_start",
            hrAgeSeconds: 40,
            imuAgeSeconds: 41,
            stream5Confirmed: true,
            batteryPercent: 59,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 65,
            overnightRHR: 55,
            daytimeRHR: 84,
            overnightRecovery: 79,
            todayRecovery: 38,
            lastWorkout: .init(
                activityType: "Strength",
                start: now.addingTimeInterval(-3_600),
                end: now.addingTimeInterval(-1_800),
                samples: 0,
                peakHR: nil,
                reason: "user_confirmed_no_hr"
            ),
            liveHeartRate: 80,
            liveZone: "Z1",
            widgetHeartRate: 80
        )
        XCTAssertTrue(snapshot.discrepancies.contains("hrv_today_settled_77_live_65"))
        XCTAssertTrue(snapshot.discrepancies.contains("rhr_overnight_55_daytime_84"))
        XCTAssertTrue(snapshot.discrepancies.contains("recovery_overnight_79_today_38"))
        XCTAssertTrue(snapshot.discrepancies.contains("hr_stale_while_connected"))
        XCTAssertTrue(snapshot.discrepancies.contains("imu_stale_while_connected"))
        XCTAssertTrue(snapshot.discrepancies.contains("status_reading"))
        XCTAssertTrue(snapshot.discrepancies.contains("workout_no_hr_user_confirmed_no_hr"))

        let twoWorkouts = AtriaDiagnosisReport.make(
            now: now,
            build: "94",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: true,
            batteryPercent: 72,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 78,
            todayRecovery: 78,
            lastWorkout: .init(
                activityType: "Walking",
                start: now.addingTimeInterval(-1_800),
                end: now.addingTimeInterval(-600),
                samples: 0,
                peakHR: nil,
                reason: "no_strap_hr_samples"
            ),
            recentNoHeartRateWorkouts: [
                .init(
                    activityType: "Strength",
                    start: now.addingTimeInterval(-3_600),
                    end: now.addingTimeInterval(-1_800),
                    samples: 0,
                    peakHR: nil,
                    reason: "no_strap_hr_samples"
                ),
                .init(
                    activityType: "Walking",
                    start: now.addingTimeInterval(-1_800),
                    end: now.addingTimeInterval(-600),
                    samples: 0,
                    peakHR: nil,
                    reason: "no_strap_hr_samples"
                )
            ],
            liveHeartRate: 97,
            liveZone: "Z2",
            widgetHeartRate: 97
        )
        XCTAssertTrue(twoWorkouts.discrepancies.contains("workout_no_hr_no_strap_hr_samples"))
        XCTAssertTrue(twoWorkouts.discrepancies.contains("workout_no_hr_count_2"))
        XCTAssertEqual(twoWorkouts.recentNoHeartRateWorkouts?.map(\.activityType), ["Strength", "Walking"])
    }

    func testPublishWritesPullableJSONAndCoalescesUnchangedHeartbeats() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AtriaDiagnosisReport.make(
            now: now,
            build: "93",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 2,
            imuAgeSeconds: 2,
            stream5Confirmed: true,
            batteryPercent: 59,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 79,
            todayRecovery: 79,
            lastWorkout: nil,
            liveHeartRate: 80,
            liveZone: "Z1",
            widgetHeartRate: 80
        )
        AtriaDiagnosisReport.publish(first, reason: "core_live", force: true)
        AtriaDiagnosisReport.flushForTesting()
        XCTAssertNotNil(AtriaDiagnosisReport.loadForTesting())

        var second = first
        second.recordedAt = now.addingTimeInterval(1)
        AtriaDiagnosisReport.publish(second, reason: "core_live")
        AtriaDiagnosisReport.flushForTesting()
        let loaded = try XCTUnwrap(AtriaDiagnosisReport.loadForTesting())
        XCTAssertEqual(loaded.recordedAt, now)
        XCTAssertEqual(loaded.schema, 1)
        XCTAssertEqual(loaded.events.count, 1)
        XCTAssertEqual(loaded.events.first?.reason, "core_live")
    }

    func testInventoryListsTheDiagnosisFile() {
        XCTAssertTrue(
            AtriaManagedStorageInventory.categoryPaths
                .first { $0.category == "sessions_and_daily" }?
                .paths.contains("atria-diagnosis-v1.json") == true
        )
    }
}
