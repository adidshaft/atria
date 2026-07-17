import SwiftUI
import CryptoKit

/// Anonymous research sharing (docs/24 §14.3 + §20 onboarding choice).
///
/// Core stance: your data stays yours. The choice is made explicitly during
/// onboarding (toggle shown ON, inspectable, declinable) or in Settings —
/// inspectable before it leaves, revocable anytime. The bundle is built from an
/// explicit ALLOWLIST schema (a field not modeled here cannot leak by
/// construction), identified only by a per-consent pseudonym that revocation
/// destroys, with all timestamps shifted to a day-0 relative epoch so absolute
/// calendar dates never leave the device (time-of-day and day spacing are
/// preserved — that is the research value).
enum AtriaResearchSharing {
    static let optInKey = "atria.dataSharing.optIn"
    static let pseudonymKey = "atria.dataSharing.pseudonymUUID"
    static let consentDateKey = "atria.dataSharing.consentDate"
    static let receiptsKey = "atria.dataSharing.receipts.v1"
    static let schemaVersion = 1

    static var isOptedIn: Bool {
        UserDefaults.standard.bool(forKey: optInKey)
    }

    static func grantConsent(now: Date = Date()) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: optInKey)
        defaults.set(UUID().uuidString, forKey: pseudonymKey)
        defaults.set(now.timeIntervalSince1970, forKey: consentDateKey)
        AtriaDebugLog("ATRIADBG research_sharing status=consented")
    }

    /// Revocation destroys the pseudonym: nothing shared afterwards can be
    /// linked to what was shared before.
    static func revokeConsent() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: optInKey)
        defaults.removeObject(forKey: pseudonymKey)
        defaults.removeObject(forKey: consentDateKey)
        AtriaResearchUploadQueue.clearOutbox(reason: "consent_revoked")
        AtriaDebugLog("ATRIADBG research_sharing status=revoked pseudonym_destroyed=1 outbox_cleared=1")
    }

    static var pseudonym: String? {
        UserDefaults.standard.string(forKey: pseudonymKey)
    }

    static func recordReceipt(digest: String, bytes: Int, now: Date = Date()) {
        let defaults = UserDefaults.standard
        var receipts = defaults.stringArray(forKey: receiptsKey) ?? []
        receipts.append("\(ISO8601DateFormatter().string(from: now))|\(digest.prefix(12))|\(bytes)")
        if receipts.count > 20 { receipts.removeFirst(receipts.count - 20) }
        defaults.set(receipts, forKey: receiptsKey)
    }

    static var lastReceipt: String? {
        UserDefaults.standard.stringArray(forKey: receiptsKey)?.last
    }
}

/// The allowlist schema. Every field here was deliberately chosen; anything not
/// modeled is excluded by construction. Times are seconds since the bundle's
/// day-0 (start of the earliest recorded day). No names, no device identifiers,
/// no absolute dates, no timezone, no free text — ever.
struct AtriaResearchBundlePayload: Codable {
    struct Manifest: Codable {
        let schema: Int
        let pseudonym: String
        let appVersion: String
        let ageBand: String
        let weightBandKg: String
        let heightBandCm: String
        let biologicalSex: String
    }

    struct Session: Codable {
        let startRel: Double
        let endRel: Double
        let kind: String
        let hrPoints: [[Double]]      // [tRel, bpm]
        let rrPoints: [[Double]]      // [tRel, ms]
        let restingStable: Int
        let hrv: Int?
    }

    struct Sleep: Codable {
        let startRel: Double
        let endRel: Double
        let durationS: Double
        let confidence: String
        let stageSeconds: [String: Double]
    }

    struct Workout: Codable {
        let startRel: Double
        let endRel: Double
        let label: String
        let avgHR: Int
        let peakHR: Int
    }

    struct Day: Codable {
        let dayIndex: Int
        let recoveryPercent: Int?
        let strain: Double?
        let sleepHours: Double?
        let restingHR: Int?
        let hrv: Int?
    }

    struct JournalAnswer: Codable {
        let questionID: String
        let dayIndex: Int
        let kind: String
        let value: Double?
    }

    let manifest: Manifest
    let sessions: [Session]
    let sleeps: [Sleep]
    let workouts: [Workout]
    let days: [Day]
    let journal: [JournalAnswer]
}

enum AtriaResearchBundleBuilder {
    struct Built {
        let url: URL
        let digest: String
        let bytes: Int
        let payload: AtriaResearchBundlePayload
    }

    /// Immutable references captured from the main-actor SessionStore before a
    /// research build. Swift arrays are copy-on-write, so this handoff is O(1):
    /// expanding every stored HR/RR point happens only after the detached task
    /// starts. The store never mutates these value snapshots off actor.
    struct BuildInput: @unchecked Sendable {
        let manifest: AtriaResearchBundlePayload.Manifest
        let sessions: [SavedSession]
        let sleeps: [UserConfirmedSleep]
        let workouts: [UserConfirmedWorkout]
        let days: [SavedDailyMetric]
        let journalAnswers: [AtriaJournalAnswer]
        let calendar: Calendar
    }

    static func ageBand(yearOfBirth: Int?, now: Date = Date()) -> String {
        guard let yearOfBirth, yearOfBirth > 1900 else { return "unknown" }
        let age = Calendar.current.component(.year, from: now) - yearOfBirth
        let lower = (age / 5) * 5
        return "\(lower)-\(lower + 4)"
    }

    static func band(_ value: Double, width: Double, unit: String) -> String {
        guard value > 0 else { return "unknown" }
        let lower = (value / width).rounded(.down) * width
        return "\(Int(lower))-\(Int(lower + width)) \(unit)"
    }

    /// Builds the anonymized bundle, or nil when not consented. The returned
    /// payload backs the "see exactly what leaves this phone" inspector.
    @MainActor
    static func build(store: SessionStore, now: Date = Date()) async -> Built? {
        guard AtriaResearchSharing.isOptedIn,
              let pseudonym = AtriaResearchSharing.pseudonym else { return nil }
        let calendar = Calendar.current
        let profile = store.profile
        let manifest = AtriaResearchBundlePayload.Manifest(
            schema: AtriaResearchSharing.schemaVersion,
            pseudonym: pseudonym,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            ageBand: ageBand(yearOfBirth: calendar.component(.year, from: now) - profile.age, now: now),
            weightBandKg: band(profile.weightKg, width: 5, unit: "kg"),
            heightBandCm: band(profile.heightCm, width: 5, unit: "cm"),
            biologicalSex: profile.biologicalSex.rawValue)
        store.journalAnswers.loadIfNeeded()
        let input = BuildInput(
            manifest: manifest,
            sessions: store.sessions,
            sleeps: store.confirmedSleeps,
            workouts: store.confirmedWorkouts,
            days: store.dailyMetricHistory,
            journalAnswers: store.journalAnswers.answers,
            calendar: calendar
        )

        // Session history can contain hundreds of thousands of points. The
        // previous implementation performed the complete nested-array build on
        // MainActor and detached only JSON encoding, which could freeze the UI
        // when foreground catch-up started after an app switch.
        return await Task.detached(priority: .utility) {
            guard let payload = makePayload(input: input) else { return nil }
            let bundleDays = payload.days
            return finishBuild(payload: payload,
                               pseudonym: pseudonym,
                               bundleDays: bundleDays)
        }.value
    }

    nonisolated static func makePayload(input: BuildInput) -> AtriaResearchBundlePayload? {
        var allDates: [Date] = input.sessions.map(\.start)
        allDates.append(contentsOf: input.sleeps.map(\.start))
        allDates.append(contentsOf: input.days.map(\.day))
        guard let earliest = allDates.min() else { return nil }
        let epoch0 = input.calendar.startOfDay(for: earliest)

        func rel(_ date: Date) -> Double {
            (date.timeIntervalSince(epoch0) * 10).rounded() / 10
        }
        func dayIndex(_ date: Date) -> Int {
            input.calendar.dateComponents([.day],
                                          from: epoch0,
                                          to: input.calendar.startOfDay(for: date)).day ?? 0
        }

        var bundleSessions: [AtriaResearchBundlePayload.Session] = []
        bundleSessions.reserveCapacity(input.sessions.count)
        for session in input.sessions {
            var hrPoints: [[Double]] = []
            hrPoints.reserveCapacity(session.points.count)
            for point in session.points {
                let tRel: Double = (point.t * 10).rounded() / 10
                hrPoints.append([tRel, Double(point.bpm)])
            }
            var rrPoints: [[Double]] = []
            rrPoints.reserveCapacity(session.rrPoints?.count ?? 0)
            for point in session.rrPoints ?? [] {
                let tRel: Double = (point.t * 10).rounded() / 10
                rrPoints.append([tRel, Double(point.ms)])
            }
            bundleSessions.append(AtriaResearchBundlePayload.Session(
                startRel: rel(session.start),
                endRel: rel(session.start.addingTimeInterval(session.duration)),
                kind: session.kind ?? "session",
                hrPoints: hrPoints,
                rrPoints: rrPoints,
                restingStable: session.restingStable,
                hrv: session.hrv))
        }
        let bundleSleeps = input.sleeps.map { sleep in
            var stages: [String: Double] = [:]
            for segment in sleep.stageSegments ?? [] {
                stages[segment.stage.rawValue, default: 0] += segment.end.timeIntervalSince(segment.start)
            }
            return AtriaResearchBundlePayload.Sleep(startRel: rel(sleep.start),
                                                    endRel: rel(sleep.end),
                                                    durationS: sleep.duration,
                                                    confidence: sleep.confidence,
                                                    stageSeconds: stages)
        }
        let bundleWorkouts = input.workouts.map { workout in
            AtriaResearchBundlePayload.Workout(startRel: rel(workout.start),
                                               endRel: rel(workout.end),
                                               label: workout.label,
                                               avgHR: workout.avgHR,
                                               peakHR: workout.peakHR)
        }
        let bundleDays = input.days.map { metric in
            AtriaResearchBundlePayload.Day(dayIndex: dayIndex(metric.day),
                                           recoveryPercent: metric.recoveryPercent,
                                           strain: metric.strain,
                                           sleepHours: metric.sleepDuration.map { $0 / 3600 },
                                           restingHR: metric.restingHR,
                                           hrv: metric.hrv)
        }
        let bundleJournal = input.journalAnswers.map { answer -> AtriaResearchBundlePayload.JournalAnswer in
            let kind: String
            let value: Double?
            switch answer.value {
            case .yes: kind = "boolean"; value = 1
            case .no: kind = "boolean"; value = 0
            case .timeOfDay(let minutes): kind = "timeOfDayMinutes"; value = Double(minutes)
            case .quantity(let count): kind = "quantity"; value = Double(count)
            case .scale(let level): kind = "scale1to5"; value = Double(level)
            }
            return AtriaResearchBundlePayload.JournalAnswer(questionID: answer.questionID,
                                                            dayIndex: dayIndex(answer.day),
                                                            kind: kind,
                                                            value: value)
        }

        return AtriaResearchBundlePayload(manifest: input.manifest,
                                          sessions: bundleSessions,
                                          sleeps: bundleSleeps,
                                          workouts: bundleWorkouts,
                                          days: bundleDays,
                                          journal: bundleJournal)
    }

    private nonisolated static func finishBuild(payload: AtriaResearchBundlePayload,
                                                pseudonym: String,
                                                bundleDays: [AtriaResearchBundlePayload.Day]) -> Built? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(payload),
              let compressed = try? AtriaBackupCompression.compressedArchiveData(from: json) else {
            return nil
        }
        let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        // Keep tmp tidy: stale bundles (incl. cancelled shares) are replaced,
        // never accumulated. Only files older than an hour are removed so a
        // concurrent build (nightly queue vs Send-now vs manual share) can
        // never delete another caller's just-written output.
        let tmp = FileManager.default.temporaryDirectory
        if let stale = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in stale where file.lastPathComponent.hasPrefix("atria-research-") {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if Date().timeIntervalSince(modified) > 3600 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        let name = "atria-research-\(pseudonym.prefix(8))-day\(bundleDays.map(\.dayIndex).max() ?? 0).json.gz"
        let url = tmp.appendingPathComponent(name)
        guard (try? compressed.write(to: url, options: .atomic)) != nil else { return nil }
        AtriaDebugLog("ATRIADBG research_bundle status=built sessions=%d sleeps=%d workouts=%d days=%d journal=%d bytes=%d digest=%@",
                      payload.sessions.count,
                      payload.sleeps.count,
                      payload.workouts.count,
                      payload.days.count,
                      payload.journal.count,
                      compressed.count,
                      String(digest.prefix(12)))
        return Built(url: url, digest: digest, bytes: compressed.count, payload: payload)
    }
}

/// Nightly upload pipeline (docs/24 §14.3, phase 2 — piggybacks the existing
/// BGProcessingTask; no dedicated infra of its own yet).
///
/// Bundles are built off `AtriaResearchBundleBuilder.build` and persisted to an
/// on-disk outbox. Atria's core is deliberately local-first with no network or
/// browser client anywhere in the app (enforced by
/// `test_local_first_core_has_no_network_or_browser_clients`), so this queue
/// never reaches for one either: the endpoint field only records *where a
/// future transport would send bundles*. With no transport wired in (the
/// state today, and the honest state until a server actually exists) this is
/// queue-only — bundles accumulate on device and nothing is attempted over the
/// network. No failure here is ever surfaced to the user; sharing is a
/// background gift, not a task they need to babysit.
enum AtriaResearchUploadQueue {
    static let endpointURLKey = "atria.research.endpointURL"
    private static let lastRunDayKey = "atria.research.upload.lastRunDay"
    private static let retentionDays = 7

    struct OutboxStats {
        let count: Int
        let totalBytes: Int
    }

    static var outboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("research-outbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Empty (the default) means queue-only mode — no server has been
    /// configured, let alone wired up to an actual transport.
    static var configuredEndpoint: String? {
        guard let raw = UserDefaults.standard.string(forKey: endpointURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    static var isEndpointConfigured: Bool { configuredEndpoint != nil }

    static func outboxStats() -> OutboxStats {
        let files = (try? FileManager.default.contentsOfDirectory(at: outboxDirectory,
                                                                   includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let totalBytes = files.reduce(0) { sum, file in
            sum + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return OutboxStats(count: files.count, totalBytes: totalBytes)
    }

    /// True when `now` falls inside the learned sleep window
    /// (atria.dutycycle.sleepWindowStartMin/EndMin), falling back to 03:00-05:00
    /// local before that window has been learned.
    static func isWithinSleepWindow(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let defaults = UserDefaults.standard
        var startMin = defaults.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowStartMin)
        var endMin = defaults.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowEndMin)
        if startMin <= 0 && endMin <= 0 {
            startMin = 3 * 60
            endMin = 5 * 60
        }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let nowMin = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMin <= endMin {
            return nowMin >= startMin && nowMin < endMin
        }
        return nowMin >= startMin || nowMin < endMin
    }

    /// The sharing rule as one pure, testable decision (2026-07-08, user
    /// request): transmit ONLY while the wearer is asleep OR not actively
    /// using the phone — and only when opted in, with data to send, and
    /// without spending a low battery unless charging. `withinSleepWindow`
    /// comes from `isWithinSleepWindow`; `phoneIdle` from the app's
    /// foreground / last-interaction state (supplied by the caller). This
    /// decides only WHEN a transmit attempt runs; an unconfigured endpoint
    /// still just queues locally, so nothing is fabricated or force-sent.
    enum TransmitDecision: Equatable {
        /// reason ∈ { "sleep_window", "phone_idle" }
        case eligible(reason: String)
        /// reason ∈ { "sharing_off", "nothing_pending", "low_battery", "phone_in_use" }
        case hold(reason: String)

        var isEligible: Bool {
            if case .eligible = self { return true }
            return false
        }

        var reason: String {
            switch self {
            case .eligible(let reason), .hold(let reason): return reason
            }
        }
    }

    /// Below this phone-battery fraction, hold background sharing unless the
    /// phone is charging (P4 battery care).
    static let lowBatteryHoldFraction = 0.20

    static func transmissionEligibility(optedIn: Bool,
                                        hasPending: Bool,
                                        withinSleepWindow: Bool,
                                        phoneIdle: Bool,
                                        batteryFraction: Double,
                                        isCharging: Bool) -> TransmitDecision {
        guard optedIn else { return .hold(reason: "sharing_off") }
        guard hasPending else { return .hold(reason: "nothing_pending") }
        // Negative battery = unknown (monitoring off): the battery guard fails
        // OPEN so an unknown reading never blocks — the sleep/idle guard below
        // still governs. A known low battery while unplugged holds.
        if batteryFraction >= 0, batteryFraction < lowBatteryHoldFraction, !isCharging {
            return .hold(reason: "low_battery")
        }
        if withinSleepWindow { return .eligible(reason: "sleep_window") }
        if phoneIdle { return .eligible(reason: "phone_idle") }
        return .hold(reason: "phone_in_use")
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    static func hasRunToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        UserDefaults.standard.string(forKey: lastRunDayKey) == dayKey(for: now, calendar: calendar)
    }

    private static func markRanToday(now: Date, calendar: Calendar) {
        UserDefaults.standard.set(dayKey(for: now, calendar: calendar), forKey: lastRunDayKey)
    }

    /// Entry point piggybacked on the existing BGProcessingTask
    /// (`AtriaApp.handleBackgroundTask`). Gated to the learned sleep window and
    /// at most once per calendar day.
    @MainActor
    static func runNightlyIfDue(store: SessionStore, now: Date = Date(), calendar: Calendar = .current, reason: String) async {
        guard AtriaResearchSharing.isOptedIn else {
            // Not sharing right now: still honor retention on whatever is left
            // in the outbox from before consent was revoked.
            pruneOutbox(now: now, calendar: calendar)
            return
        }
        guard isWithinSleepWindow(now: now, calendar: calendar) else {
            AtriaDebugLog("ATRIADBG research_upload status=skipped reason=%@ why=outside_sleep_window", reason)
            return
        }
        guard !hasRunToday(now: now, calendar: calendar) else {
            AtriaDebugLog("ATRIADBG research_upload status=skipped reason=%@ why=already_ran_today", reason)
            return
        }
        markRanToday(now: now, calendar: calendar)
        if let built = await AtriaResearchBundleBuilder.build(store: store, now: now) {
            _ = await enqueueAndAttemptTransport(built: built, now: now, reason: reason)
        } else {
            AtriaDebugLog("ATRIADBG research_upload status=skipped reason=%@ why=nothing_to_build", reason)
        }
        await attemptUploadOutstanding(now: now, reason: reason)
        pruneOutbox(now: now, calendar: calendar)
    }

    /// Foreground catch-up: iOS grants BGProcessingTask windows opportunistically
    /// and can starve a freshly-reinstalled app for days. If the nightly window
    /// was missed (we are past the sleep window, nothing ran today), build the
    /// day's bundle on foreground instead — same gates, same once-per-day mark,
    /// so the two paths can never double-build.
    static func runForegroundCatchUpIfMissed(store: SessionStore, now: Date = Date(), calendar: Calendar = .current) async {
        guard AtriaResearchSharing.isOptedIn else { return }
        guard !isWithinSleepWindow(now: now, calendar: calendar) else { return }
        guard !hasRunToday(now: now, calendar: calendar) else { return }
        markRanToday(now: now, calendar: calendar)
        AtriaDebugLog("ATRIADBG research_upload status=catchup reason=foreground_missed_nightly")
        if let built = await AtriaResearchBundleBuilder.build(store: store, now: now) {
            _ = await enqueueAndAttemptTransport(built: built, now: now, reason: "foreground_catchup")
        }
        pruneOutbox(now: now, calendar: calendar)
    }

    /// Manual "send now" from Settings: builds/persists immediately (ignoring
    /// the sleep-window and once-per-day gates, since the user explicitly
    /// asked), then attempts the transport step below. Returns the outbox file
    /// URL when the caller should fall back to the manual ShareLink flow (true
    /// today, always — see the type-level note on why) — nil would mean a real
    /// transport picked it up and it is fully handled.
    @MainActor
    static func sendNow(built: AtriaResearchBundleBuilder.Built, now: Date = Date()) async -> URL? {
        await enqueueAndAttemptTransport(built: built, now: now, reason: "manual_send_now")
    }

    @MainActor
    private static func enqueueAndAttemptTransport(built: AtriaResearchBundleBuilder.Built, now: Date, reason: String) async -> URL? {
        let outboxURL = persist(built: built, now: now)
        guard let configuredEndpoint else {
            AtriaDebugLog("ATRIADBG research_upload status=queued reason=%@ why=no_endpoint_configured bytes=%d",
                          reason, built.bytes)
            return outboxURL
        }
        AtriaDebugLog("ATRIADBG research_upload status=queued reason=%@ why=transport_unavailable endpoint=%@ bytes=%d",
                      reason, configuredEndpoint, built.bytes)
        return outboxURL
    }

    /// Retries whatever is still sitting in the outbox. Since this build ships
    /// no network client at all, this only ever re-confirms the queued state
    /// and logs it — it becomes real once a transport exists to plug in here.
    @MainActor
    private static func attemptUploadOutstanding(now: Date, reason: String) async {
        guard let configuredEndpoint else { return }
        let stats = outboxStats()
        guard stats.count > 0 else { return }
        AtriaDebugLog("ATRIADBG research_upload status=queued reason=%@ why=transport_unavailable endpoint=%@ outbox=%d",
                      reason, configuredEndpoint, stats.count)
    }

    /// Un-uploaded bundles older than 7 days are pruned; the newest bundle is
    /// always kept even if it is old (there is never nothing in the outbox to
    /// show while sharing is on).
    static func clearOutbox(reason: String) {
        let files = (try? FileManager.default.contentsOfDirectory(at: outboxDirectory,
                                                                   includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        if !files.isEmpty {
            AtriaDebugLog("ATRIADBG research_upload status=outbox_cleared reason=%@ files=%d", reason, files.count)
        }
    }

    static func pruneOutbox(now: Date = Date(), calendar: Calendar = .current) {
        let files = (try? FileManager.default.contentsOfDirectory(at: outboxDirectory,
                                                                   includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard AtriaResearchSharing.isOptedIn else {
            clearOutbox(reason: "opted_out")
            return
        }
        guard files.count > 1 else { return }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let sorted = files.sorted { modified($0) > modified($1) }
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        for file in sorted.dropFirst() where modified(file) < cutoff {
            try? FileManager.default.removeItem(at: file)
            AtriaDebugLog("ATRIADBG research_upload status=pruned file=%@", file.lastPathComponent)
        }
    }

    private static func persist(built: AtriaResearchBundleBuilder.Built, now: Date) -> URL? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let dateStamp = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let prefix = "atria-research-\(dateStamp)-"
        // One enqueue per day: replace any earlier bundle from the same day.
        if let existing = try? FileManager.default.contentsOfDirectory(at: outboxDirectory, includingPropertiesForKeys: nil) {
            for file in existing where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let name = "\(prefix)\(built.digest.prefix(8)).json.gz"
        let dest = outboxDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: built.url, to: dest)
        } catch {
            AtriaDebugLog("ATRIADBG research_upload status=enqueue_failed error=%@", String(describing: error))
            return nil
        }
        return dest
    }

}

/// Full-screen consent flow. The Agree button stays disabled until the user has
/// opened the inspector showing the REAL bundle that would leave the phone.
struct AtriaResearchConsentSheet: View {
    let buildPreview: () async -> AtriaResearchBundleBuilder.Built?
    let onConsented: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasInspected = false
    @State private var showInspector = false
    @State private var inspectorText = ""
    @State private var inspectorBytes = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Anonymous research sharing", systemImage: "shippingbox")
                        .font(.title3.weight(.bold))

                    Text("""
                    Atria is local-first. Your data lives on this phone and nowhere else — that does not change.

                    If you turn this on, you can send an anonymous copy of your recordings to the Atria developers to improve the recovery, sleep, and strain algorithms.

                    WHAT IS SHARED: heart-rate, heart-rate-variability, sleep, and workout series; daily scores; journal answers; your age range, weight range, height range, and sex.

                    WHAT IS NEVER SHARED: your name, email, device names, exact birth date, exact weight or height, location, timezone, or anything you type.

                    Dates are scrambled — we can see “day 3 of your recording” but never which calendar day it was. You are identified only by a random code with no connection to you. Turning this off destroys that code: nothing shared afterwards can be linked to what you shared before.

                    Sharing is a gift, not a requirement. Everything in Atria works exactly the same if you say no. Note: detailed heart data is unique to you; we strip identifiers, but patterns in the data itself are inherently yours.
                    """)
                    .font(.footnote)

                    Button {
                        Task {
                            await prepareInspector()
                            showInspector = true
                            // The agree-gate only opens on a REAL rendered bundle.
                            hasInspected = inspectorBytes > 0
                        }
                    } label: {
                        Label("See exactly what leaves this phone", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button {
                        AtriaResearchSharing.grantConsent()
                        onConsented()
                        dismiss()
                    } label: {
                        Text("I agree — share anonymously")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!hasInspected)

                    if !hasInspected {
                        Text("Review the bundle above before agreeing.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button("Not now") { dismiss() }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showInspector) {
                NavigationStack {
                    ScrollView {
                        Text(inspectorText)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .navigationTitle("Bundle contents (\(inspectorBytes / 1024) KB)")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.large])
            }
        }
    }

    private func prepareInspector() async {
        // Build a REAL preview with a temporary pseudonym (not persisted).
        let defaults = UserDefaults.standard
        let hadOptIn = defaults.bool(forKey: AtriaResearchSharing.optInKey)
        let previousPseudonym = defaults.string(forKey: AtriaResearchSharing.pseudonymKey)
        defaults.set(true, forKey: AtriaResearchSharing.optInKey)
        if previousPseudonym == nil {
            defaults.set("preview-\(UUID().uuidString.prefix(8))", forKey: AtriaResearchSharing.pseudonymKey)
        }
        defer {
            defaults.set(hadOptIn, forKey: AtriaResearchSharing.optInKey)
            if previousPseudonym == nil {
                defaults.removeObject(forKey: AtriaResearchSharing.pseudonymKey)
            }
        }
        guard let built = await buildPreview() else {
            inspectorText = "Bundle could not be built (no data yet)."
            inspectorBytes = 0
            return
        }
        inspectorBytes = built.bytes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var preview = AtriaResearchBundlePayload(manifest: built.payload.manifest,
                                                 sessions: Array(built.payload.sessions.prefix(1)),
                                                 sleeps: Array(built.payload.sleeps.prefix(2)),
                                                 workouts: Array(built.payload.workouts.prefix(2)),
                                                 days: Array(built.payload.days.prefix(3)),
                                                 journal: Array(built.payload.journal.prefix(5)))
        // Truncate the sample session's point arrays so the preview is readable;
        // the counts line makes the full volume explicit.
        if let first = preview.sessions.first {
            preview = AtriaResearchBundlePayload(
                manifest: preview.manifest,
                sessions: [AtriaResearchBundlePayload.Session(startRel: first.startRel,
                                                              endRel: first.endRel,
                                                              kind: first.kind,
                                                              hrPoints: Array(first.hrPoints.prefix(5)),
                                                              rrPoints: Array(first.rrPoints.prefix(5)),
                                                              restingStable: first.restingStable,
                                                              hrv: first.hrv)],
                sleeps: preview.sleeps,
                workouts: preview.workouts,
                days: preview.days,
                journal: preview.journal)
        }
        let header = """
        FULL BUNDLE: \(built.payload.sessions.count) sessions, \(built.payload.sleeps.count) sleeps, \
        \(built.payload.workouts.count) workouts, \(built.payload.days.count) days, \
        \(built.payload.journal.count) journal answers — \(built.bytes / 1024) KB compressed.
        SHA-256 \(built.digest.prefix(16))…
        Sample below (arrays truncated for reading; the real bundle contains the full series):

        """
        let body = (try? encoder.encode(preview)).flatMap { String(data: $0, encoding: .utf8) } ?? "encode failed"
        inspectorText = header + body
    }
}

/// Settings section: the toggle, the share row, and the receipts line.
struct AtriaResearchSharingSection: View {
    let buildBundle: () async -> AtriaResearchBundleBuilder.Built?
    @AtriaDefault(AtriaResearchSharing.optInKey) private var optedIn = false
    @State private var showConsent = false
    @State private var shareURL: URL?
    @State private var isSendingNow = false
    @State private var outboxStats = AtriaResearchUploadQueue.outboxStats()

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { optedIn },
                set: { wantsOn in
                    if wantsOn {
                        // Consent is granted by the sheet, never by the toggle.
                        showConsent = true
                    } else {
                        AtriaResearchSharing.revokeConsent()
                    }
                })) {
                Label("Share anonymously with developers", systemImage: "shippingbox")
            }
            .font(.subheadline)
            .accessibilityHint(researchSharingAccessibilityHint)

            if optedIn {
                Button {
                    Task {
                        if let built = await buildBundle() {
                            AtriaResearchSharing.recordReceipt(digest: built.digest, bytes: built.bytes)
                            shareURL = built.url
                        }
                    }
                } label: {
                    Label("Share anonymized bundle", systemImage: "square.and.arrow.up")
                }
                .font(.subheadline)

                Button {
                    guard !isSendingNow else { return }
                    isSendingNow = true
                    Task {
                        defer {
                            isSendingNow = false
                            outboxStats = AtriaResearchUploadQueue.outboxStats()
                        }
                        guard let built = await buildBundle() else { return }
                        // Falls back to the same manual ShareLink flow whenever
                        // there is no endpoint yet, or the upload attempt failed.
                        shareURL = await AtriaResearchUploadQueue.sendNow(built: built)
                    }
                } label: {
                    Label(isSendingNow ? "Sending…" : "Send now", systemImage: "paperplane")
                }
                .font(.subheadline)
                .disabled(isSendingNow)

                if let receipt = AtriaResearchSharing.lastReceipt {
                    Text("Last bundle: \(receipt.replacingOccurrences(of: "|", with: " · "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(outboxSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Anonymous research sharing")
        } footer: {
            Text(researchSharingFooter)
        }
        .onAppear { outboxStats = AtriaResearchUploadQueue.outboxStats() }
        .sheet(isPresented: $showConsent) {
            AtriaResearchConsentSheet(buildPreview: buildBundle) { }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                AtriaResearchShareSheetHost(url: shareURL)
            }
        }
    }

    private var researchSharingFooter: String {
        guard optedIn else { return "Optional · date-scrambled · inspect before sharing." }
        return AtriaResearchUploadQueue.isEndpointConfigured
            ? "Nightly · random ID · turn off anytime."
            : "No server yet · bundles stay on this phone."
    }

    private var researchSharingAccessibilityHint: String {
        optedIn
            ? "Uploads nightly during your sleep window using a random code. Turning sharing off destroys that code."
            : "Shares anonymized, date-scrambled recordings only after you inspect and consent."
    }

    private var outboxSummary: String {
        guard outboxStats.count > 0 else { return "Outbox: empty." }
        let kb = max(1, outboxStats.totalBytes / 1024)
        return "Outbox: \(outboxStats.count) bundle\(outboxStats.count == 1 ? "" : "s") queued, \(kb) KB on device."
    }
}

private struct AtriaResearchShareSheetHost: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("Send to Atria developers", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Text("Send via any channel you trust — the file itself is the anonymized bundle you inspected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
