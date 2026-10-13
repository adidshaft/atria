import HealthKit
import SwiftUI

/// Sync & storage health (W4.1): the self-diagnosis the app owes its wearer
/// and the first thing support asks for. Every row reads state the app
/// already persists — nothing is measured on the main thread here, and a
/// value that is not known says so instead of guessing.
enum AtriaSyncHealth {
    /// Daily MetricKit exit counts for the most recent report (background
    /// stops iOS forced on the app). Written by `AtriaMainThreadWatchdog`.
    struct ExitSummary: Codable, Equatable {
        var periodEndUnix: TimeInterval
        var cpuLimit: Int
        var watchdog: Int
        var memoryLimit: Int
        var crashes: Int
        var normal: Int

        var forcedStops: Int { cpuLimit + watchdog + memoryLimit + crashes }
    }

    static let exitSummaryKey = "atria.metrickit.exitSummary.v1"

    struct Snapshot: Equatable {
        var linkState: String
        var heartRateAgeSeconds: Double?
        var syncedThrough: Date?
        var lastBackgroundRun: Date?
        var storageBytes: Int64?
        var storageTargetBytes: Int64?
        var storageRecordedAt: Date?
        var exits: ExitSummary?
    }

    /// Reads persisted state. Touches one small JSON file, so call it off
    /// the main thread (the screen uses `.task` + a detached load).
    static func load(now: Date = Date(),
                     defaults: UserDefaults = .standard,
                     diagnosisURL: URL = AtriaDiagnosisReport.fileURL()) -> Snapshot {
        var snapshot = Snapshot(linkState: "Unknown")
        if let data = try? Data(contentsOf: diagnosisURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let report = try? decoder.decode(AtriaDiagnosisReport.Snapshot.self, from: data) {
                snapshot.linkState = report.connection.status
                snapshot.heartRateAgeSeconds = report.connection.hrAgeSeconds
                    .map { $0 + max(0, now.timeIntervalSince(report.recordedAt)) }
            }
        }
        snapshot.syncedThrough = AtriaStrapMotionSyncStatus.persistedSyncedThrough(defaults: defaults, now: now)
        snapshot.lastBackgroundRun = lastBackgroundRun(defaults: defaults)
        if let data = defaults.data(forKey: AtriaManagedStorageInventory.receiptKey),
           let receipt = try? JSONDecoder().decode(AtriaManagedStorageInventory.Receipt.self, from: data) {
            snapshot.storageBytes = receipt.totalBytes
            snapshot.storageTargetBytes = receipt.managedHealthTargetBytes
            snapshot.storageRecordedAt = Date(timeIntervalSince1970: receipt.recordedAtUnix)
        }
        if let data = defaults.data(forKey: exitSummaryKey) {
            snapshot.exits = try? JSONDecoder().decode(ExitSummary.self, from: data)
        }
        return snapshot
    }

    /// Newest entry of the background-task journal ("<unix> <event>").
    static func lastBackgroundRun(defaults: UserDefaults = .standard) -> Date? {
        guard let last = defaults.stringArray(forKey: AtriaBackgroundTaskJournal.key)?.last,
              let unix = last.split(separator: " ").first.flatMap({ TimeInterval($0) }) else { return nil }
        return Date(timeIntervalSince1970: unix)
    }

    // MARK: Apple Health sleep readback (W4.3)

    /// Mirrors SessionStore's private `ConfirmedSleepDefaults.key`.
    static let confirmedSleepsKey = "atria.confirmedSleeps.v1"
    static let readbackDays = 30

    struct SleepReadback: Equatable {
        /// Civil days with an Atria-written asleep sample that Health returns.
        var nightsInHealth: Int
        /// Confirmed main sleeps (>= 3 h) Atria sends to Health (entered,
        /// edited, or with verified stages) that ended in the window.
        var confirmedNights: Int
    }

    /// Distinct civil days among `dates`.
    static func distinctDays(_ dates: [Date], calendar: Calendar = .current) -> Int {
        Set(dates.map { calendar.startOfDay(for: $0) }).count
    }

    static func confirmedMainSleepEnds(defaults: UserDefaults = .standard,
                                       since: Date) -> [Date] {
        guard let data = defaults.data(forKey: confirmedSleepsKey),
              let sleeps = try? JSONDecoder().decode([UserConfirmedSleep].self, from: data) else { return [] }
        return sleeps.filter {
            $0.end >= since && $0.end.timeIntervalSince($0.start) >= 3 * 3600
                && HealthKitExporter.sleepIsExportable($0)
        }.map(\.end)
    }

    /// nil when Health is unavailable or Atria may not write sleep (nothing
    /// to check). Reads only samples whose source is this app.
    static func sleepReadback(now: Date = Date()) async -> SleepReadback? {
        guard HKHealthStore.isHealthDataAvailable(),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let store = HKHealthStore()
        guard store.authorizationStatus(for: sleepType) == .sharingAuthorized,
              let since = Calendar.current.date(byAdding: .day, value: -readbackDays, to: now) else { return nil }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: since, end: now),
            HKQuery.predicateForObjects(from: HKSource.default())
        ])
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        ]
        let ends: [Date] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let asleep = (samples as? [HKCategorySample] ?? []).filter { asleepValues.contains($0.value) }
                continuation.resume(returning: asleep.map(\.endDate))
            }
            store.execute(query)
        }
        return SleepReadback(nightsInHealth: distinctDays(ends),
                             confirmedNights: distinctDays(confirmedMainSleepEnds(since: since)))
    }

    static func readbackText(_ readback: SleepReadback?) -> String {
        guard let readback else { return "Health export off" }
        if readback.confirmedNights == 0 { return "No nights to send yet" }
        return "\(min(readback.nightsInHealth, readback.confirmedNights)) of \(readback.confirmedNights) nights"
    }

    // MARK: Plain-language rows

    static func linkText(_ snapshot: Snapshot) -> String {
        let state = snapshot.linkState.lowercased()
        let base: String
        if state.contains("connected") && !state.contains("dis") { base = "Connected" }
        else if state.contains("connecting") || state.contains("reconnect") { base = "Connecting" }
        else if state == "unknown" { base = "Not seen yet" }
        else { base = "Not connected" }
        guard base == "Connected", let age = snapshot.heartRateAgeSeconds else { return base }
        return age < 60 ? "\(base) · heart rate live" : "\(base) · heart rate \(ageText(age)) ago"
    }

    /// How far the strap's saved history trails now; nil when unknown.
    static func backlog(_ snapshot: Snapshot, now: Date) -> TimeInterval? {
        snapshot.syncedThrough.map { max(0, now.timeIntervalSince($0)) }
    }

    static func syncText(_ snapshot: Snapshot, now: Date, calendar: Calendar = .current) -> String {
        guard let through = snapshot.syncedThrough else { return "Not synced yet" }
        let clock = AtriaStrapMotionSyncStatus.timeText(through, now: now, calendar: calendar)
        guard let lag = backlog(snapshot, now: now), lag >= 15 * 60 else { return "Up to date · \(clock)" }
        return "\(ageText(lag)) behind · through \(clock)"
    }

    static func storageText(_ snapshot: Snapshot) -> String {
        guard let bytes = snapshot.storageBytes else { return "Measuring at next launch" }
        let used = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        guard let target = snapshot.storageTargetBytes else { return used }
        return "\(used) · target \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file))"
    }

    static func exitText(_ exits: ExitSummary?) -> String {
        guard let exits else { return "No report from iOS yet" }
        if exits.forcedStops == 0 { return "None in the last report" }
        var parts: [String] = []
        if exits.cpuLimit > 0 { parts.append("\(exits.cpuLimit) for CPU use") }
        if exits.watchdog > 0 { parts.append("\(exits.watchdog) slow start") }
        if exits.memoryLimit > 0 { parts.append("\(exits.memoryLimit) for memory") }
        if exits.crashes > 0 { parts.append("\(exits.crashes) crash\(exits.crashes == 1 ? "" : "es")") }
        return parts.joined(separator: " · ")
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = Double(minutes) / 60
        if hours < 48 { return hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h" }
        return "\(Int((hours / 24).rounded())) days"
    }
}

/// Settings > Data > Sync & storage. One row per question support would ask.
struct AtriaSyncHealthScreen: View {
    @State private var snapshot: AtriaSyncHealth.Snapshot?
    @State private var sleepReadback: AtriaSyncHealth.SleepReadback?
    @State private var readbackDone = false

    var body: some View {
        Form {
            if let snapshot {
                let now = Date()
                Section {
                    LabeledContent("Strap", value: AtriaSyncHealth.linkText(snapshot))
                    LabeledContent("Strap history", value: AtriaSyncHealth.syncText(snapshot, now: now))
                    LabeledContent("Last background run",
                                   value: snapshot.lastBackgroundRun.map {
                                       AtriaStrapMotionSyncStatus.timeText($0, now: now, calendar: .current)
                                   } ?? "None recorded")
                }
                Section {
                    LabeledContent("On this iPhone", value: AtriaSyncHealth.storageText(snapshot))
                    LabeledContent("Stopped by iOS", value: AtriaSyncHealth.exitText(snapshot.exits))
                    LabeledContent("Sleep in Apple Health",
                                   value: readbackDone ? AtriaSyncHealth.readbackText(sleepReadback) : "Checking…")
                } footer: {
                    Text("iOS reports background stops once a day. Health gets nights with verified stages or your edits, last 30 days.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Sync & storage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            snapshot = await Task.detached(priority: .userInitiated) { AtriaSyncHealth.load() }.value
            sleepReadback = await AtriaSyncHealth.sleepReadback()
            readbackDone = true
        }
    }
}
