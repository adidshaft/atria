import Foundation

/// Always-on, pullable snapshot of why live HR/IMU, recovery/HRV/RHR, widgets,
/// Live Activity, and saved workouts currently disagree. Written to Documents
/// so `pull_atria_state.sh` can copy it without debug logging.
enum AtriaDiagnosisReport {
    static let schema = 1
    static let filename = "atria-diagnosis-v1.json"
    static let coalesceInterval: TimeInterval = 5
    static let maxEvents = 24
    static let liveStaleSeconds: TimeInterval = 15

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
    }

    struct Metrics: Equatable, Codable {
        var settledHRV: Int?
        var liveHRV: Int?
        var overnightRHR: Int?
        var daytimeRHR: Int?
        var overnightRecovery: Int?
        var todayRecovery: Int?
    }

    struct Workout: Equatable, Codable {
        var activityType: String
        var start: Date
        var end: Date
        var samples: Int
        var peakHR: Int?
        var reason: String
    }

    struct LiveActivity: Equatable, Codable {
        var recording: Bool
        var heartRate: Int
        var zone: String?
    }

    struct Widget: Equatable, Codable {
        var hrv: Int?
        var rhr: Int?
        var recovery: Int?
        var heartRate: Int?
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
        widgetHeartRate: Int?
    ) -> Snapshot {
        let metrics = Metrics(
            settledHRV: settledHRV,
            liveHRV: liveHRV,
            overnightRHR: overnightRHR,
            daytimeRHR: daytimeRHR,
            overnightRecovery: overnightRecovery,
            todayRecovery: todayRecovery
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
            workoutRecording: workoutRecording
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
                zone: liveZone
            ),
            widget: Widget(
                hrv: settledHRV,
                rhr: overnightRHR,
                recovery: overnightRecovery ?? todayRecovery,
                heartRate: widgetHeartRate
            ),
            discrepancies: discrepancies(
                connection: connection,
                metrics: metrics,
                lastWorkout: lastWorkout,
                recentNoHeartRateWorkouts: recentNoHeartRateWorkouts
            ),
            events: []
        )
    }

    static func discrepancies(
        connection: Connection,
        metrics: Metrics,
        lastWorkout: Workout? = nil,
        recentNoHeartRateWorkouts: [Workout] = []
    ) -> [String] {
        var keys: [String] = []
        if let settled = metrics.settledHRV, let live = metrics.liveHRV, abs(settled - live) >= 8 {
            keys.append("hrv_today_settled_\(settled)_live_\(live)")
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
            if let age = connection.imuAgeSeconds, age > liveStaleSeconds {
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
        return keys
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
