import Foundation
import Darwin

/// Always-on, pullable snapshot of why live HR/IMU, recovery/HRV/RHR, widgets,
/// Live Activity, and saved workouts currently disagree. Written to Documents
/// so `pull_atria_state.sh` can copy it without debug logging.
enum AtriaDiagnosisReport {
    static let schema = 1
    static let filename = "atria-diagnosis-v1.json"
    static let coalesceInterval: TimeInterval = 5
    static let maxEvents = 24
    static let liveStaleSeconds: TimeInterval = 15
    /// Compact 0x33 while sitting can be 30–60s apart (device 2026-09-18 167:
    /// sitting skip, packet age 46s). The 15s HR window must not call that an
    /// IMU drop or 6A/51 will storm a healthy 2A37 link.
    static let imuSittingFreshSeconds: TimeInterval = 120

    /// Tests point this at a temporary directory. Production uses Documents.
    static var documentsDirectoryOverride: URL?

    struct Connection: Equatable, Codable {
        var status: String
        var recovering: Bool
        var reconnectAgeSeconds: Double?
        var reconnectReason: String
        var hrAgeSeconds: Double?
        var imuAgeSeconds: Double?
        var stream5Confirmed: Bool
        var batteryPercent: Int?
        var officialAppRisk: String
        var workoutRecording: Bool
        var idleWindowPending: Int?
    }

    struct Metrics: Equatable, Codable {
        var settledHRV: Int?
        var liveHRV: Int?
        var overnightRHR: Int?
        var daytimeRHR: Int?
        var overnightRecovery: Int?
        var todayRecovery: Int?
        var todaySteps: Int?
        var todayStrain: Double? = nil
    }

    struct Workout: Equatable, Codable {
        var activityType: String
        var start: Date
        var end: Date
        var samples: Int
        var avgHR: Int? = nil
        var peakHR: Int? = nil
        var strain: Double? = nil
        var steps: Int? = nil
        var stepsAreEstimated: Bool? = nil
        var heartRateLoad: Int? = nil
        var reason: String
    }

    struct LiveActivity: Equatable, Codable {
        var recording: Bool
        var heartRate: Int
        var zone: String?
        var activityName: String? = nil
        var availability: String? = nil
        var strain: Double? = nil
        var steps: Int? = nil
        var elapsedSeconds: Int? = nil
        var activityKitCount: Int? = nil
    }

    struct Widget: Equatable, Codable {
        var hrv: Int?
        var rhr: Int?
        var recovery: Int?
        var heartRate: Int?
        var hrvCapturedAt: Date?
        var createdAt: Date?
        var steps: Int?
        var strain: Double? = nil
    }

    struct WindowPoint: Equatable, Codable {
        var day: String
        var value: Int
    }

    struct MetricWindows: Equatable, Codable {
        var hrvDay: Int?
        var hrvWeek: [WindowPoint]
        var hrvMonth: [WindowPoint]
        var recoveryDay: Int?
        var recoveryWeek: [WindowPoint]
        var recoveryMonth: [WindowPoint]
        var rhrDay: Int?
        var rhrWeek: [WindowPoint]
        var rhrMonth: [WindowPoint]
        var sleepDay: Int?
        var sleepWeek: [WindowPoint]
        var sleepMonth: [WindowPoint]
    }

    struct Event: Equatable, Codable {
        var at: Date
        var reason: String
        var discrepancies: [String]
    }

    struct Snapshot: Equatable, Codable {
        var schema: Int
        var recordedAt: Date
        var build: String
        var connection: Connection
        var metrics: Metrics
        var lastWorkout: Workout?
        var recentNoHeartRateWorkouts: [Workout]?
        var liveActivity: LiveActivity
        var widget: Widget
        var metricWindows: MetricWindows?
        var discrepancies: [String]
        var events: [Event]
    }

    private static let io = DispatchQueue(label: "atria.diagnosis.report")
    private static var lastWrittenAt: Date?
    private static var lastWritten: Snapshot?
    private static var recentEvents: [Event] = []

    static func fileURL() -> URL {
        let directory = documentsDirectoryOverride
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent(filename)
    }

    /// A live 2A37 pulse is stronger than a lagging CoreBluetooth `.connecting`
    /// string. Device 2026-09-18 163: diagnosis said Connecting… while HR age
    /// was 0.01s and `live_hr_notifying=1`.
    static func reportedConnectionStatus(
        status: AtriaBLEManager.Status,
        hrAgeSeconds: Double?,
        liveFreshnessSeconds: TimeInterval = 15
    ) -> AtriaBLEManager.Status {
        if status != .connected,
           let age = hrAgeSeconds,
           age >= 0,
           age <= liveFreshnessSeconds {
            return .connected
        }
        return status
    }

    static func make(
        now: Date,
        build: String,
        status: AtriaBLEManager.Status,
        recovering: Bool,
        reconnectAgeSeconds: Double?,
        reconnectReason: String,
        hrAgeSeconds: Double?,
        imuAgeSeconds: Double?,
        stream5Confirmed: Bool,
        batteryPercent: Int?,
        officialAppRisk: String,
        workoutRecording: Bool,
        settledHRV: Int?,
        liveHRV: Int?,
        overnightRHR: Int?,
        daytimeRHR: Int?,
        overnightRecovery: Int?,
        todayRecovery: Int?,
        lastWorkout: Workout?,
        recentNoHeartRateWorkouts: [Workout] = [],
        liveHeartRate: Int,
        liveZone: String?,
        widgetHeartRate: Int?,
        widgetHRV: Int? = nil,
        widgetRHR: Int? = nil,
        widgetRecovery: Int? = nil,
        widgetHRVCapturedAt: Date? = nil,
        widgetCreatedAt: Date? = nil,
        widgetSteps: Int? = nil,
        todaySteps: Int? = nil,
        widgetStrain: Double? = nil,
        todayStrain: Double? = nil,
        metricWindows: MetricWindows? = nil,
        liveActivityName: String? = nil,
        liveActivityAvailability: String? = nil,
        liveActivityStrain: Double? = nil,
        liveActivitySteps: Int? = nil,
        liveActivityElapsedSeconds: Int? = nil,
        compactAssembledAgeSeconds: Double? = nil,
        idleWindowPending: Int? = nil,
        compactSittingSkip: Bool = false,
        liveActivityKitCount: Int? = nil,
        liveActivityStartError: String? = nil
    ) -> Snapshot {
        let metrics = Metrics(
            settledHRV: settledHRV,
            liveHRV: liveHRV,
            overnightRHR: overnightRHR,
            daytimeRHR: daytimeRHR,
            overnightRecovery: overnightRecovery,
            todayRecovery: todayRecovery,
            todaySteps: todaySteps,
            todayStrain: todayStrain
        )
        let connection = Connection(
            status: status.rawValue,
            recovering: recovering,
            reconnectAgeSeconds: reconnectAgeSeconds,
            reconnectReason: reconnectReason,
            hrAgeSeconds: hrAgeSeconds,
            imuAgeSeconds: imuAgeSeconds,
            stream5Confirmed: stream5Confirmed,
            batteryPercent: batteryPercent,
            officialAppRisk: officialAppRisk,
            workoutRecording: workoutRecording,
            idleWindowPending: idleWindowPending
        )
        return Snapshot(
            schema: schema,
            recordedAt: now,
            build: build,
            connection: connection,
            metrics: metrics,
            lastWorkout: lastWorkout,
            recentNoHeartRateWorkouts: recentNoHeartRateWorkouts.isEmpty
                ? nil
                : recentNoHeartRateWorkouts,
            liveActivity: LiveActivity(
                recording: workoutRecording,
                heartRate: liveHeartRate,
                zone: liveHeartRate > 0 ? liveZone : nil,
                activityName: workoutRecording
                    ? liveActivityName
                    : (liveHeartRate > 0 ? "Live" : nil),
                availability: workoutRecording
                    ? (liveActivityAvailability ?? "live")
                    : (liveHeartRate > 0 ? "idle" : "unavailable"),
                strain: workoutRecording ? liveActivityStrain : nil,
                steps: liveHeartRate > 0 ? liveActivitySteps : nil,
                elapsedSeconds: workoutRecording ? liveActivityElapsedSeconds : nil,
                activityKitCount: liveActivityKitCount
            ),
            widget: Widget(
                hrv: widgetHRV ?? settledHRV,
                rhr: widgetRHR ?? overnightRHR,
                recovery: widgetRecovery ?? overnightRecovery ?? todayRecovery,
                heartRate: widgetHeartRate,
                hrvCapturedAt: widgetHRVCapturedAt,
                createdAt: widgetCreatedAt,
                steps: widgetSteps,
                strain: widgetStrain
            ),
            metricWindows: metricWindows,
            discrepancies: discrepancies(
                connection: connection,
                metrics: metrics,
                lastWorkout: lastWorkout,
                recentNoHeartRateWorkouts: recentNoHeartRateWorkouts,
                metricWindows: metricWindows,
                widgetSteps: widgetSteps,
                widgetHRV: widgetHRV,
                widgetRecovery: widgetRecovery,
                compactAssembledAgeSeconds: compactAssembledAgeSeconds,
                widgetStrain: widgetStrain,
                compactSittingSkip: compactSittingSkip,
                liveHeartRate: liveHeartRate,
                liveActivityKitCount: liveActivityKitCount,
                liveActivityStartError: liveActivityStartError
            ),
            events: []
        )
    }

    static func discrepancies(
        connection: Connection,
        metrics: Metrics,
        lastWorkout: Workout? = nil,
        recentNoHeartRateWorkouts: [Workout] = [],
        metricWindows: MetricWindows? = nil,
        widgetSteps: Int? = nil,
        widgetHRV: Int? = nil,
        widgetRecovery: Int? = nil,
        compactAssembledAgeSeconds: Double? = nil,
        widgetStrain: Double? = nil,
        compactSittingSkip: Bool = false,
        liveHeartRate: Int = 0,
        liveActivityKitCount: Int? = nil,
        liveActivityStartError: String? = nil
    ) -> [String] {
        var keys: [String] = []
        // Today/Day/Week/Month and the widget pin overnight settled HRV.
        // Live strap RMSSD during the day is expected to differ and is not
        // a tile split. Flag the widget when it disagrees with settled.
        if let settled = metrics.settledHRV,
           let widget = widgetHRV,
           abs(settled - widget) >= 8 {
            keys.append("hrv_widget_\(widget)_settled_\(settled)")
        }
        if let overnight = metrics.overnightRHR, let daytime = metrics.daytimeRHR, overnight != daytime {
            keys.append("rhr_overnight_\(overnight)_daytime_\(daytime)")
        }
        if let overnight = metrics.overnightRecovery, let today = metrics.todayRecovery, overnight != today {
            keys.append("recovery_overnight_\(overnight)_today_\(today)")
        }
        if connection.status == AtriaBLEManager.Status.connected.rawValue {
            if let age = connection.hrAgeSeconds, age > liveStaleSeconds {
                keys.append("hr_stale_while_connected")
            }
            if shouldFlagIMUStaleWhileConnected(
                imuAgeSeconds: connection.imuAgeSeconds,
                skippedSitting: compactSittingSkip
            ) {
                keys.append("imu_stale_while_connected")
            }
        }
        if connection.recovering {
            keys.append("status_reading")
        } else if connection.status == AtriaBLEManager.Status.disconnected.rawValue
                    || connection.status == AtriaBLEManager.Status.scanning.rawValue {
            keys.append("status_unavailable")
        }
        var seenNoHR = Set<String>()
        var noHR: [Workout] = []
        for workout in recentNoHeartRateWorkouts + [lastWorkout].compactMap({ $0 }) {
            guard workout.samples <= 0 else { continue }
            let identity = "\(workout.start.timeIntervalSince1970)-\(workout.activityType)"
            guard seenNoHR.insert(identity).inserted else { continue }
            noHR.append(workout)
        }
        if let workout = noHR.first {
            keys.append("workout_no_hr_\(workout.reason)")
        }
        if noHR.count > 1 {
            keys.append("workout_no_hr_count_\(noHR.count)")
        }
        if let pending = connection.idleWindowPending, pending > 0 {
            keys.append("idle_window_pending_\(pending)")
        }
        if let settled = metrics.settledHRV,
           let weekLast = metricWindows?.hrvWeek.last?.value,
           weekLast != settled {
            keys.append("hrv_week_last_\(weekLast)_settled_\(settled)")
        }
        if let settled = metrics.settledHRV,
           let monthLast = metricWindows?.hrvMonth.last?.value,
           monthLast != settled {
            keys.append("hrv_month_last_\(monthLast)_settled_\(settled)")
        }
        if let day = metricWindows?.recoveryDay ?? metrics.overnightRecovery,
           let weekLast = metricWindows?.recoveryWeek.last?.value,
           weekLast != day {
            keys.append("recovery_week_last_\(weekLast)_day_\(day)")
        }
        if let day = metricWindows?.recoveryDay ?? metrics.overnightRecovery,
           let monthLast = metricWindows?.recoveryMonth.last?.value,
           monthLast != day {
            keys.append("recovery_month_last_\(monthLast)_day_\(day)")
        }
        if let day = metricWindows?.rhrDay ?? metrics.overnightRHR,
           let weekLast = metricWindows?.rhrWeek.last?.value,
           weekLast != day {
            keys.append("rhr_week_last_\(weekLast)_day_\(day)")
        }
        if let day = metricWindows?.rhrDay ?? metrics.overnightRHR,
           let monthLast = metricWindows?.rhrMonth.last?.value,
           monthLast != day {
            keys.append("rhr_month_last_\(monthLast)_day_\(day)")
        }
        if let day = metricWindows?.sleepDay,
           let weekLast = metricWindows?.sleepWeek.last?.value,
           weekLast != day {
            keys.append("sleep_week_last_\(weekLast)_day_\(day)")
        }
        if let day = metricWindows?.sleepDay,
           let monthLast = metricWindows?.sleepMonth.last?.value,
           monthLast != day {
            keys.append("sleep_month_last_\(monthLast)_day_\(day)")
        }
        if let widget = widgetHRV,
           let settled = metrics.settledHRV,
           widget != settled {
            keys.append("widget_hrv_\(widget)_settled_\(settled)")
        }
        if let widget = widgetRecovery,
           let overnight = metrics.overnightRecovery,
           widget != overnight {
            keys.append("widget_recovery_\(widget)_overnight_\(overnight)")
        }
        if let widget = widgetSteps,
           let today = metrics.todaySteps,
           abs(widget - today) > AtriaHeldDailyStepFloor.contaminationSlack {
            keys.append("widget_steps_\(widget)_today_\(today)")
        }
        if let widget = widgetStrain,
           let today = metrics.todayStrain,
           abs(widget - today) >= 0.3 {
            let widgetTenths = Int((widget * 10).rounded())
            let todayTenths = Int((today * 10).rounded())
            keys.append("widget_strain_\(widgetTenths)_today_\(todayTenths)")
        }
        if let workout = lastWorkout, workout.samples > 0, workout.steps == 0 {
            keys.append("workout_zero_steps")
        }
        if liveHeartRate > 0, let count = liveActivityKitCount, count == 0 {
            keys.append("live_activity_kit_empty")
            if let liveActivityStartError,
               liveActivityStartError.localizedCaseInsensitiveContains("visibility") {
                keys.append("live_activity_start_visibility")
            }
        }
        if connection.status == AtriaBLEManager.Status.connected.rawValue,
           let age = compactAssembledAgeSeconds,
           age > 60,
           connection.stream5Confirmed
            || (connection.imuAgeSeconds ?? .greatestFiniteMagnitude) <= liveStaleSeconds {
            keys.append("compact_imu_assembled_stale")
        }
        return keys
    }

    static func compactIMUSittingSkipIsFresh(
        skippedSitting: Bool,
        imuAgeSeconds: Double?
    ) -> Bool {
        guard skippedSitting, let age = imuAgeSeconds, age >= 0,
              age <= imuSittingFreshSeconds else { return false }
        return true
    }

    static func shouldFlagIMUStaleWhileConnected(
        imuAgeSeconds: Double?,
        skippedSitting: Bool
    ) -> Bool {
        guard let age = imuAgeSeconds, age > liveStaleSeconds else { return false }
        return !compactIMUSittingSkipIsFresh(
            skippedSitting: skippedSitting,
            imuAgeSeconds: age
        )
    }

    /// Sleep-backed Day/Week/Month values for the same overnight numbers Today
    /// shows. Week and Month skip nights without sleep, so they cannot invent
    /// extra HRV points the Day sheet does not have.
    static func overnightMetricWindows(
        rollups: [DailyRollupStoreEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> MetricWindows {
        MetricWindows(
            hrvDay: AtriaHealthMetricEvidencePresentation.newestSettledHRVMilliseconds(from: rollups),
            hrvWeek: windowPoints(from: rollups, range: .week, now: now, calendar: calendar) { entry in
                guard let lnRMSSD = entry.lnRMSSD else { return nil }
                return Int(exp(lnRMSSD).rounded())
            },
            hrvMonth: windowPoints(from: rollups, range: .month, now: now, calendar: calendar) { entry in
                guard let lnRMSSD = entry.lnRMSSD else { return nil }
                return Int(exp(lnRMSSD).rounded())
            },
            recoveryDay: AtriaHealthMetricEvidencePresentation.newestSettledRecovery(from: rollups),
            recoveryWeek: windowPoints(from: rollups, range: .week, now: now, calendar: calendar) { $0.recovery },
            recoveryMonth: windowPoints(from: rollups, range: .month, now: now, calendar: calendar) { $0.recovery },
            rhrDay: AtriaHealthMetricEvidencePresentation.newestSettledRestingHeartRate(from: rollups),
            rhrWeek: windowPoints(from: rollups, range: .week, now: now, calendar: calendar) { $0.rhr },
            rhrMonth: windowPoints(from: rollups, range: .month, now: now, calendar: calendar) { $0.rhr },
            sleepDay: sleepMinutes(AtriaHealthMetricEvidencePresentation.newestSettledSleepSeconds(from: rollups)),
            sleepWeek: windowPoints(from: rollups, range: .week, now: now, calendar: calendar) {
                sleepMinutes($0.sleepSeconds)
            },
            sleepMonth: windowPoints(from: rollups, range: .month, now: now, calendar: calendar) {
                sleepMinutes($0.sleepSeconds)
            }
        )
    }

    private static func sleepMinutes(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        return Int((seconds / 60).rounded())
    }

    private static func windowPoints(
        from rollups: [DailyRollupStoreEntry],
        range: AtriaTrendRange,
        now: Date,
        calendar: Calendar,
        value: (DailyRollupStoreEntry) -> Int?
    ) -> [WindowPoint] {
        let interval = range.periodInterval(containing: now, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return AtriaOvernightMetricChartSeries.nights(
            from: rollups,
            interval: interval,
            calendar: calendar,
            day: \.day,
            value: { entry in
                guard (entry.sleepSeconds ?? 0) > 0 else { return nil }
                return value(entry).map(Double.init)
            }
        ).map {
            WindowPoint(
                day: formatter.string(from: $0.day),
                value: Int($0.value.rounded())
            )
        }
    }

    static func publish(_ snapshot: Snapshot, reason: String, force: Bool = false) {
        io.async {
            writeLocked(snapshot, reason: reason, force: force)
        }
    }

    static func flushForTesting() {
        io.sync {}
    }

    static func resetForTesting() {
        io.sync {
            lastWrittenAt = nil
            lastWritten = nil
            recentEvents = []
            try? FileManager.default.removeItem(at: fileURL())
        }
    }

    static func loadForTesting() -> Snapshot? {
        io.sync {
            guard let data = try? Data(contentsOf: fileURL()) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Snapshot.self, from: data)
        }
    }

    private static func writeLocked(_ snapshot: Snapshot, reason: String, force: Bool) {
        var next = snapshot
        let discrepanciesChanged = lastWritten?.discrepancies != next.discrepancies
        if force || discrepanciesChanged || lastWritten == nil {
            recentEvents.append(Event(
                at: next.recordedAt,
                reason: reason,
                discrepancies: next.discrepancies
            ))
            if recentEvents.count > maxEvents {
                recentEvents.removeFirst(recentEvents.count - maxEvents)
            }
        }
        next.events = recentEvents
        if !force,
           !discrepanciesChanged,
           let lastWrittenAt,
           next.recordedAt.timeIntervalSince(lastWrittenAt) < coalesceInterval {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(next) else { return }
        let url = fileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        lastWrittenAt = next.recordedAt
        lastWritten = next
    }
}
