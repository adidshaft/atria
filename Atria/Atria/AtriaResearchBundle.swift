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
    // v3 puts every temporal field on one day-zero-relative axis. v2 mixed
    // session-relative HR/RR offsets with day-zero motion and labels, which
    // made a future validation set impossible to align without guessing.
    // v4 adds explicit sleep-stage provenance so an Atria-generated
    // hypnogram cannot be mistaken for a PSG/reference label in a validation
    // corpus. v5 adds only frozen, versioned Recovery receipts so a later
    // calibration study cannot rebuild historical model inputs from live data.
    static let schemaVersion = 5

    static var isOptedIn: Bool {
        UserDefaults.standard.bool(forKey: optInKey)
    }

    static func grantConsent(now: Date = Date(), previewPseudonym: String? = nil) {
        let defaults = UserDefaults.standard
        let resolvedPseudonym = previewPseudonym.flatMap(UUID.init(uuidString:))?.uuidString
            ?? UUID().uuidString
        defaults.set(true, forKey: optInKey)
        defaults.set(resolvedPseudonym, forKey: pseudonymKey)
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
        Task {
            await AtriaResearchUploadQueue.clearOutbox(reason: "consent_revoked")
        }
        AtriaDebugLog("ATRIADBG research_sharing status=revoked pseudonym_destroyed=1 outbox_clear_queued=1")
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
        /// Bounded features from independently recovered gravity evidence. No
        /// raw IMU frames, location, device identifier, or free text leaves
        /// the phone; these windows only preserve label-to-sensor alignment.
        struct MotionEpoch: Codable {
            let startRel: Double
            let endRel: Double
            let rows: Int
            let validatedRows: Int
            let stillnessRatio: Double?
            let movementIntensity: Double?
            let p95VectorDelta: Double?
            let maximumGapSeconds: Int
            let measurementValidated: Bool
            let lowMotionQualified: Bool
            let source: String
        }

        let startRel: Double
        let endRel: Double
        let kind: String
        let hrPoints: [[Double]]      // [tRel, bpm]
        let rrPoints: [[Double]]      // [tRel, ms]
        let motionEpochs: [MotionEpoch]
        let restingStable: Int
        let hrv: Int?
    }

    struct Sleep: Codable {
        let startRel: Double
        let endRel: Double
        let durationS: Double
        let confidence: String
        /// These stage totals are generated by Atria's research projection.
        /// They are useful for inspecting a bundle but must never act as the
        /// reference target for validating Atria sleep staging.
        let stageProvenance: String
        let stageReferenceEligible: Bool
        let stageSeconds: [String: Double]
    }

    struct Workout: Codable {
        let startRel: Double
        let endRel: Double
        /// Canonical picker value, never the free-form workout title. Every
        /// row is user-confirmed and is for evaluation—not a prediction.
        let activityType: String
        let labelSource: String
        let avgHR: Int
        let peakHR: Int
    }

    struct Day: Codable {
        /// The frozen inputs that actually produced a persisted Recovery score.
        /// This deliberately excludes free-form contributor copy, raw dates,
        /// and any later baseline recomputation. Nil means a legacy or
        /// incomplete recovery record and is not a training/evaluation row.
        struct RecoveryReceipt: Codable {
            let score: Int
            let confidence: String
            let model: String
            let modelVersion: Int
            let usesHRV: Bool
            let hrvRMSSD: Double?
            let restingHeartRateBPM: Double?
            let sleepDurationSeconds: Double?
            let sleepEfficiency: Double?
            let respiratoryRate: Double?
            let comparisonHorizonDays: Int?
            let recentQualificationHorizonDays: Int?
            let recentQualifiedRestingDays: Int?
            let recentQualifiedHRVNights: Int?
        }

        let dayIndex: Int
        let recoveryPercent: Int?
        let recoveryReceipt: RecoveryReceipt?
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

    /// Builds the anonymized bundle only after consent. Use `preview` for the
    /// consent inspector; it is intentionally a distinct, non-uploading path.
    @MainActor
    static func build(store: SessionStore, now: Date = Date()) async -> Built? {
        guard AtriaResearchSharing.isOptedIn,
              let pseudonym = AtriaResearchSharing.pseudonym else { return nil }
        return await makeBuiltBundle(store: store, now: now, pseudonym: pseudonym)
    }

    /// Builds a local-only consent preview. The generated pseudonym is not
    /// persisted or transmitted; the consent sheet adopts it only after its
    /// inspector has been opened and the user explicitly agrees.
    @MainActor
    static func preview(store: SessionStore, now: Date = Date()) async -> Built? {
        await makeBuiltBundle(store: store, now: now, pseudonym: UUID().uuidString)
    }

    @MainActor
    private static func makeBuiltBundle(store: SessionStore,
                                        now: Date,
                                        pseudonym: String) async -> Built? {
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
        // Every record that can carry an exported label or measurement must
        // participate in the epoch. Otherwise a manual workout or journal
        // answer that predates the first saved session would serialize with a
        // negative coordinate, breaking the bundle's single time contract.
        var allDates: [Date] = input.sessions.map(\.start)
        allDates.append(contentsOf: input.sleeps.map(\.start))
        allDates.append(contentsOf: input.workouts.map(\.start))
        allDates.append(contentsOf: input.days.map(\.day))
        allDates.append(contentsOf: input.journalAnswers.map(\.day))
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
                // Do not emit malformed offsets outside the saved session. A
                // point is only useful to research if it has an unambiguous
                // absolute position on the bundle's one relative timeline.
                guard point.t.isFinite,
                      point.t >= 0,
                      point.t <= session.duration,
                      point.bpm > 0 else { continue }
                hrPoints.append([rel(session.start.addingTimeInterval(point.t)), Double(point.bpm)])
            }
            var rrPoints: [[Double]] = []
            rrPoints.reserveCapacity(session.rrPoints?.count ?? 0)
            for point in session.rrPoints ?? [] {
                guard point.t.isFinite,
                      point.t >= 0,
                      point.t <= session.duration,
                      point.ms > 0 else { continue }
                rrPoints.append([rel(session.start.addingTimeInterval(point.t)), Double(point.ms)])
            }
            let sessionEnd = session.start.addingTimeInterval(session.duration)
            let motionEpochs: [AtriaResearchBundlePayload.Session.MotionEpoch] = (session.recoveredMotionEpochs ?? [])
                .filter { $0.end > session.start && $0.start < sessionEnd }
                .compactMap { epoch in
                    // A recovered epoch may slightly overhang the session
                    // that retained it. Clip to the true session interval so
                    // all emitted timestamps remain bounded and align with
                    // HR/RR points instead of leaking a negative pre-session
                    // coordinate.
                    let epochStart = max(epoch.start, session.start)
                    let epochEnd = min(epoch.end, sessionEnd)
                    guard epochEnd > epochStart else { return nil }
                    return AtriaResearchBundlePayload.Session.MotionEpoch(
                        startRel: rel(epochStart),
                        endRel: rel(epochEnd),
                        rows: epoch.rows,
                        validatedRows: epoch.validatedRows,
                        stillnessRatio: epoch.stillnessRatio,
                        movementIntensity: epoch.movementIntensity,
                        p95VectorDelta: epoch.p95VectorDelta,
                        maximumGapSeconds: epoch.maximumGapSeconds,
                        measurementValidated: epoch.measurementValidated,
                        lowMotionQualified: epoch.lowMotionQualified,
                        source: AtriaRecoveredMotionEpoch.source
                    )
                }
            bundleSessions.append(AtriaResearchBundlePayload.Session(
                startRel: rel(session.start),
                endRel: rel(sessionEnd),
                kind: session.kind ?? "session",
                hrPoints: hrPoints,
                rrPoints: rrPoints,
                motionEpochs: motionEpochs,
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
                                                    stageProvenance: "atria_derived_research_only_not_reference",
                                                    stageReferenceEligible: false,
                                                    stageSeconds: stages)
        }
        let bundleWorkouts = input.workouts.map { workout in
            let activityType = AtriaWorkoutActivityType.resolved(
                activityType: workout.activityType,
                subtype: workout.activitySubtype,
                label: workout.label
            )
            return AtriaResearchBundlePayload.Workout(startRel: rel(workout.start),
                                                      endRel: rel(workout.end),
                                                      activityType: activityType.rawValue,
                                                      labelSource: "user_confirmed",
                                                      avgHR: workout.avgHR,
                                                      peakHR: workout.peakHR)
        }
        let bundleDays = input.days.map { metric in
            AtriaResearchBundlePayload.Day(dayIndex: dayIndex(metric.day),
                                           recoveryPercent: metric.recoveryPercent,
                                           recoveryReceipt: recoveryReceipt(for: metric.recoverySummary),
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

    nonisolated private static func recoveryReceipt(
        for summary: FrozenRecoverySummary?
    ) -> AtriaResearchBundlePayload.Day.RecoveryReceipt? {
        guard let summary,
              let model = summary.model,
              let modelVersion = summary.modelVersion,
              let input = summary.inputSnapshot else {
            return nil
        }
        return .init(score: summary.score,
                     confidence: summary.confidence,
                     model: model,
                     modelVersion: modelVersion,
                     usesHRV: summary.usesHRV,
                     hrvRMSSD: input.hrvRMSSD,
                     restingHeartRateBPM: input.restingHeartRateBPM,
                     sleepDurationSeconds: input.sleepDurationSeconds,
                     sleepEfficiency: input.sleepEfficiency,
                     respiratoryRate: input.respiratoryRate,
                     comparisonHorizonDays: input.recoveryComparison?.comparisonHorizonDays,
                     recentQualificationHorizonDays: input.recoveryComparison?.recentQualificationHorizonDays,
                     recentQualifiedRestingDays: input.recoveryComparison?.recentQualifiedRestingDays,
                     recentQualifiedHRVNights: input.recoveryComparison?.recentQualifiedHRVNights)
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

    struct OutboxStats: Sendable {
        let count: Int
        let totalBytes: Int

        static let empty = OutboxStats(count: 0, totalBytes: 0)
    }

    private enum OutboxOperation: @unchecked Sendable {
        case stats
        case persist(source: URL, digest: String, now: Date)
        case clear(reason: String)
        case prune(cutoff: Date)
    }

    private enum OutboxOperationResult: @unchecked Sendable {
        case stats(OutboxStats)
        case persisted(URL?)
        case finished
    }

    /// One FIFO utility queue owns every outbox directory scan and mutation.
    /// Consent changes, background maintenance, and manual sends therefore
    /// cannot race each other or perform filesystem work on MainActor.
    private static let outboxWorker = AtriaCoalescingSerialWorker<OutboxOperation, OutboxOperationResult>(
        label: "com.adidshaft.atria.research-outbox",
        qos: .utility
    ) { operation in
        performOutboxOperation(operation)
    }

    static var outboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("research-outbox", isDirectory: true)
    }

    /// Empty (the default) means queue-only mode — no server has been
    /// configured, let alone wired up to an actual transport.
    static var configuredEndpoint: String? {
        guard let raw = UserDefaults.standard.string(forKey: endpointURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    static var isEndpointConfigured: Bool { configuredEndpoint != nil }

    static func outboxStats() async -> OutboxStats {
        switch await outboxWorker.performAsync(.stats) {
        case .stats(let stats):
            return stats
        case .persisted, .finished:
            return .empty
        }
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
            await pruneOutbox(now: now, calendar: calendar)
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
        await pruneOutbox(now: now, calendar: calendar)
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
        await pruneOutbox(now: now, calendar: calendar)
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
        let outboxURL = await persist(built: built, now: now)
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
        let stats = await outboxStats()
        guard stats.count > 0 else { return }
        AtriaDebugLog("ATRIADBG research_upload status=queued reason=%@ why=transport_unavailable endpoint=%@ outbox=%d",
                      reason, configuredEndpoint, stats.count)
    }

    /// Un-uploaded bundles older than 7 days are pruned; the newest bundle is
    /// always kept even if it is old (there is never nothing in the outbox to
    /// show while sharing is on).
    static func clearOutbox(reason: String) async {
        _ = await outboxWorker.performAsync(.clear(reason: reason))
    }

    static func pruneOutbox(now: Date = Date(), calendar: Calendar = .current) async {
        guard AtriaResearchSharing.isOptedIn else {
            await clearOutbox(reason: "opted_out")
            return
        }
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        _ = await outboxWorker.performAsync(.prune(cutoff: cutoff))
    }

    private static func persist(built: AtriaResearchBundleBuilder.Built, now: Date) async -> URL? {
        switch await outboxWorker.performAsync(.persist(source: built.url, digest: built.digest, now: now)) {
        case .persisted(let url):
            return url
        case .stats, .finished:
            return nil
        }
    }

    private nonisolated static func performOutboxOperation(
        _ operation: OutboxOperation
    ) -> OutboxOperationResult {
        let fileManager = FileManager.default
        let directory = outboxDirectory
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        switch operation {
        case .stats:
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let totalBytes = files.reduce(0) { sum, file in
                sum + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return .stats(OutboxStats(count: files.count, totalBytes: totalBytes))

        case .clear(let reason):
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files {
                try? fileManager.removeItem(at: file)
            }
            if !files.isEmpty {
                AtriaDebugLog(
                    "ATRIADBG research_upload status=outbox_cleared reason=%@ files=%d",
                    reason,
                    files.count
                )
            }
            return .finished

        case .prune(let cutoff):
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            guard files.count > 1 else { return .finished }
            func modified(_ url: URL) -> Date {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            }
            let sorted = files.sorted { modified($0) > modified($1) }
            for file in sorted.dropFirst() where modified(file) < cutoff {
                try? fileManager.removeItem(at: file)
                AtriaDebugLog("ATRIADBG research_upload status=pruned file=%@", file.lastPathComponent)
            }
            return .finished

        case .persist(let source, let digest, let now):
            return .persisted(
                persist(source: source, digest: digest, now: now, directory: directory)
            )
        }
    }

    private nonisolated static func persist(
        source: URL,
        digest: String,
        now: Date,
        directory: URL
    ) -> URL? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let dateStamp = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let prefix = "atria-research-\(dateStamp)-"
        // One enqueue per day: replace any earlier bundle from the same day.
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in existing where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let name = "\(prefix)\(digest.prefix(8)).json.gz"
        let dest = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
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
    @State private var previewPseudonym: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Anonymous research sharing", systemImage: "shippingbox")
                        .font(.title3.weight(.bold))

                    Text("""
                    Atria is local-first. Your data lives on this phone and nowhere else — that does not change.

                    If you turn this on, you can send an anonymous copy of your recordings to the Atria developers to improve the recovery, sleep, and strain algorithms.

                    WHAT IS SHARED: heart-rate, heart-rate-variability, sleep, user-confirmed activity type, and timestamp-shifted motion features; daily scores; journal answers; your age range, weight range, height range, and sex.

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
                        AtriaResearchSharing.grantConsent(previewPseudonym: previewPseudonym)
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
        previewPseudonym = built.payload.manifest.pseudonym
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
                                                              motionEpochs: Array(first.motionEpochs.prefix(3)),
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
    /// A pre-consent, on-device-only bundle for the mandatory inspector.
    let buildPreview: () async -> AtriaResearchBundleBuilder.Built?
    /// The consent-gated bundle used only by manual / queued sharing actions.
    let buildBundle: () async -> AtriaResearchBundleBuilder.Built?
    @AtriaDefault(AtriaResearchSharing.optInKey) private var optedIn = false
    @State private var showConsent = false
    @State private var shareURL: URL?
    @State private var isSendingNow = false
    @State private var outboxStats = AtriaResearchUploadQueue.OutboxStats.empty

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
                        }
                        guard let built = await buildBundle() else { return }
                        // Falls back to the same manual ShareLink flow whenever
                        // there is no endpoint yet, or the upload attempt failed.
                        shareURL = await AtriaResearchUploadQueue.sendNow(built: built)
                        outboxStats = await AtriaResearchUploadQueue.outboxStats()
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
        .task { outboxStats = await AtriaResearchUploadQueue.outboxStats() }
        .sheet(isPresented: $showConsent) {
            AtriaResearchConsentSheet(buildPreview: buildPreview) { }
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
