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

    func testLastWorkoutDiagnosisKeepsMeasuredHeartRateAndStrain() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "112",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: true,
            batteryPercent: 71,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 74,
            todayRecovery: 38,
            lastWorkout: .init(
                activityType: "Running",
                start: now.addingTimeInterval(-240),
                end: now,
                samples: 242,
                avgHR: 93,
                peakHR: 102,
                strain: 0.2,
                reason: "duration_below_10m_and_hr_below_threshold"
            ),
            liveHeartRate: 87,
            liveZone: "Z2",
            widgetHeartRate: 87
        )
        XCTAssertEqual(snapshot.lastWorkout?.samples, 242)
        XCTAssertEqual(snapshot.lastWorkout?.avgHR, 93)
        XCTAssertEqual(snapshot.lastWorkout?.strain, 0.2)
    }

    func testLastWorkoutDiagnosisKeepsZeroGyroStepsAndFlagsThem() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "115",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: true,
            batteryPercent: 69,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 74,
            todayRecovery: 38,
            lastWorkout: .init(
                activityType: "Walking",
                start: now.addingTimeInterval(-81),
                end: now,
                samples: 84,
                avgHR: 99,
                peakHR: 112,
                strain: 0.06,
                steps: 0,
                stepsAreEstimated: true,
                reason: "duration_below_10m_and_hr_below_threshold"
            ),
            liveHeartRate: 103,
            liveZone: "Z2",
            widgetHeartRate: 103,
            todaySteps: 2245
        )
        XCTAssertEqual(snapshot.lastWorkout?.steps, 0)
        XCTAssertEqual(snapshot.lastWorkout?.stepsAreEstimated, true)
        XCTAssertTrue(snapshot.discrepancies.contains("workout_zero_steps"))
    }

    func testLiveActivityDiagnosisKeepsLockScreenFacts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "112",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: true,
            batteryPercent: 71,
            officialAppRisk: "cleared",
            workoutRecording: true,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 74,
            todayRecovery: 38,
            lastWorkout: nil,
            liveHeartRate: 88,
            liveZone: "Z2",
            widgetHeartRate: 88,
            liveActivityName: "Running",
            liveActivityAvailability: "live",
            liveActivityStrain: 0.1,
            liveActivitySteps: 12,
            liveActivityElapsedSeconds: 211
        )
        XCTAssertEqual(snapshot.liveActivity.recording, true)
        XCTAssertEqual(snapshot.liveActivity.heartRate, 88)
        XCTAssertEqual(snapshot.liveActivity.activityName, "Running")
        XCTAssertEqual(snapshot.liveActivity.availability, "live")
        XCTAssertEqual(snapshot.liveActivity.strain, 0.1)
        XCTAssertEqual(snapshot.liveActivity.steps, 12)
        XCTAssertEqual(snapshot.liveActivity.elapsedSeconds, 211)
    }

    func testIdleDiagnosisDoesNotKeepAPhantomLiveActivityWorkout() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "116",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 0.4,
            imuAgeSeconds: 0.2,
            stream5Confirmed: true,
            batteryPercent: 68,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: nil,
            overnightRHR: 55,
            daytimeRHR: 75,
            overnightRecovery: 74,
            todayRecovery: 38,
            lastWorkout: nil,
            liveHeartRate: 85,
            liveZone: "Z2",
            widgetHeartRate: 85,
            liveActivityName: "Workout",
            liveActivityAvailability: "unavailable",
            liveActivityStrain: 0,
            liveActivitySteps: 3535,
            liveActivityElapsedSeconds: 0
        )
        XCTAssertEqual(snapshot.liveActivity.recording, false)
        XCTAssertEqual(snapshot.liveActivity.heartRate, 85)
        XCTAssertEqual(snapshot.liveActivity.activityName, "Live")
        XCTAssertEqual(snapshot.liveActivity.availability, "idle")
        XCTAssertEqual(snapshot.liveActivity.zone, "Z2")
        XCTAssertEqual(snapshot.liveActivity.steps, 3535,
                       "idle Live shows daily steps on the Lock Screen (device 156); diagnosis must report them")
        XCTAssertNil(snapshot.liveActivity.elapsedSeconds)
        XCTAssertEqual(snapshot.widget.heartRate, 85)
    }

    func testIdleLiveActivityDiagnosisReadsDailyStepsNotWorkoutSteps() throws {
        let home = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(home.contains("liveActivitySnapshot?.dailySteps"),
                      "idle diagnosis must copy the same daily steps the lock preview shows")
        XCTAssertTrue(home.contains("liveWorkoutIsActive"),
                      "workout diagnosis still uses session steps")
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
        XCTAssertTrue(
            AtriaManagedStorageInventory.categoryPaths
                .first { $0.category == "sessions_and_daily" }?
                .paths.contains("atria-pending-deeplink-v1.txt") == true
        )
        XCTAssertTrue(
            AtriaManagedStorageInventory.categoryPaths
                .first { $0.category == "sessions_and_daily" }?
                .paths.contains("atria-overnight-hrv-restore-v1.json") == true
        )
    }

    func testOvernightMetricWindowsKeepOneHRVNumberAcrossDayWeekMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let thursday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 12))!
        let rollups = [
            DailyRollupStoreEntry(
                day: calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!,
                lnRMSSD: log(40),
                sleepSeconds: 25_000,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))!,
                recovery: 78,
                rhr: 61,
                sleepSeconds: 20_000,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!,
                recovery: 54,
                lnRMSSD: log(45),
                rhr: 61,
                sleepSeconds: 15_000,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!,
                recovery: 76,
                lnRMSSD: log(77),
                rhr: 55,
                sleepSeconds: 26_100,
                calendar: calendar
            ),
            DailyRollupStoreEntry(
                day: calendar.date(from: DateComponents(year: 2026, month: 9, day: 17))!,
                recovery: 38,
                rhr: 75,
                calendar: calendar
            ),
        ]
        let windows = AtriaDiagnosisReport.overnightMetricWindows(
            rollups: rollups,
            now: thursday,
            calendar: calendar
        )
        XCTAssertEqual(windows.hrvDay, 77)
        XCTAssertEqual(windows.hrvWeek.map(\.value), [45, 77])
        XCTAssertEqual(windows.hrvMonth.map(\.value), [40, 45, 77])
        XCTAssertEqual(windows.hrvWeek.last?.value, windows.hrvDay)
        XCTAssertEqual(windows.hrvMonth.last?.value, windows.hrvDay)
        XCTAssertEqual(windows.recoveryDay, 76)
        XCTAssertEqual(windows.recoveryWeek.map(\.value), [54, 76])
        XCTAssertFalse(windows.recoveryWeek.map(\.value).contains(38))
        XCTAssertEqual(windows.rhrDay, 55)
        XCTAssertEqual(windows.rhrWeek.map(\.value), [61, 55])
        XCTAssertFalse(windows.rhrWeek.map(\.value).contains(75))
        XCTAssertEqual(windows.sleepDay, 435)
        XCTAssertEqual(windows.sleepWeek.map(\.value), [250, 435])
        XCTAssertEqual(windows.sleepMonth.last?.value, windows.sleepDay)

        let snapshot = AtriaDiagnosisReport.make(
            now: thursday,
            build: "99",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: true,
            batteryPercent: 78,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: 75,
            overnightRecovery: 76,
            todayRecovery: 38,
            lastWorkout: nil,
            liveHeartRate: 105,
            liveZone: "Z1",
            widgetHeartRate: 105,
            metricWindows: windows
        )
        XCTAssertFalse(snapshot.discrepancies.contains { $0.hasPrefix("hrv_week_last_") })
        XCTAssertFalse(snapshot.discrepancies.contains { $0.hasPrefix("hrv_month_last_") })
        XCTAssertFalse(snapshot.discrepancies.contains { $0.hasPrefix("recovery_week_last_") })
        XCTAssertFalse(snapshot.discrepancies.contains { $0.hasPrefix("rhr_week_last_") })
        XCTAssertFalse(snapshot.discrepancies.contains { $0.hasPrefix("sleep_week_last_") })
    }

    func testOvernightClockNamesYesterdayMorningNotTheLivePatchTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 13, minute: 10))!
        let captured = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 0))!
        XCTAssertEqual(
            AtriaOvernightClockText.status(captured, now: now, calendar: calendar),
            "Yesterday morning"
        )
    }

    func testDiagnosisReadsThePublishedWidgetPayloadWithoutDayFenceFailClosed() throws {
        let home = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let intents = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaAppIntents.swift"), encoding: .utf8)
        XCTAssertTrue(intents.contains("static func loadPublishedPayload()"))
        XCTAssertTrue(home.contains("AtriaIntentSnapshotStore.loadPublishedPayload()"))
        XCTAssertFalse(
            home.contains("let publishedWidget = AtriaIntentSnapshotStore.loadLatestSnapshot()"),
            "diagnosis must print the stored overnight payload even if the today-fence would hide it"
        )
        XCTAssertTrue(home.contains("widgetSteps: publishedWidget?.steps"))
        XCTAssertTrue(home.contains("todaySteps: core.dailyStepPresentation.count"))
        XCTAssertTrue(home.contains("compactAssembledAgeSeconds:"))
        XCTAssertTrue(home.contains("idleWindowPending:"))
        XCTAssertTrue(home.contains("retireStuckIdleWindowLeftoverIfNeeded("))
    }

    func testDiscrepanciesNameWidgetStepsVersusTodaySteps() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "106",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: true,
            batteryPercent: 74,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 77,
            liveHRV: 77,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 76,
            todayRecovery: 76,
            lastWorkout: nil,
            liveHeartRate: 80,
            liveZone: "Z1",
            widgetHeartRate: 80,
            widgetSteps: 10_946,
            todaySteps: 1_901
        )
        XCTAssertTrue(snapshot.discrepancies.contains("widget_steps_10946_today_1901"))
        XCTAssertEqual(snapshot.widget.steps, 10_946)
        XCTAssertEqual(snapshot.metrics.todaySteps, 1_901)
    }

    func testDiscrepanciesNameStaleCompactAssemblerWhileStream5IsLive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AtriaDiagnosisReport.make(
            now: now,
            build: "128",
            status: .connected,
            recovering: false,
            reconnectAgeSeconds: nil,
            reconnectReason: "",
            hrAgeSeconds: 1,
            imuAgeSeconds: 1,
            stream5Confirmed: false,
            batteryPercent: 43,
            officialAppRisk: "cleared",
            workoutRecording: false,
            settledHRV: 53,
            liveHRV: 53,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 71,
            todayRecovery: 71,
            lastWorkout: nil,
            liveHeartRate: 80,
            liveZone: "Z1",
            widgetHeartRate: 80,
            widgetHRV: 53,
            widgetRecovery: 71,
            compactAssembledAgeSeconds: 3_600
        )
        XCTAssertTrue(snapshot.discrepancies.contains("compact_imu_assembled_stale"))
    }

    func testDiscrepanciesNameStuckIdleWindowLeftoverPending() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stuck = AtriaDiagnosisReport.make(
            now: now,
            build: "147",
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
            settledHRV: 53,
            liveHRV: 53,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 71,
            todayRecovery: 71,
            lastWorkout: nil,
            liveHeartRate: 84,
            liveZone: "Z1",
            widgetHeartRate: 84,
            idleWindowPending: 5
        )
        XCTAssertEqual(stuck.connection.idleWindowPending, 5)
        XCTAssertTrue(stuck.discrepancies.contains("idle_window_pending_5"))

        let clear = AtriaDiagnosisReport.make(
            now: now,
            build: "147",
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
            settledHRV: 53,
            liveHRV: 53,
            overnightRHR: 55,
            daytimeRHR: nil,
            overnightRecovery: 71,
            todayRecovery: 71,
            lastWorkout: nil,
            liveHeartRate: 84,
            liveZone: "Z1",
            widgetHeartRate: 84,
            idleWindowPending: 0
        )
        XCTAssertFalse(clear.discrepancies.contains { $0.hasPrefix("idle_window_pending_") })
    }
}
