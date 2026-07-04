import SwiftUI
import CryptoKit

/// Opt-in anonymous research sharing (docs/24 §14.3, phase 1 — zero infra).
///
/// Core stance: your data stays yours; sharing is a GIFT — default OFF,
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
        AtriaDebugLog("ATRIADBG research_sharing status=revoked pseudonym_destroyed=1")
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
        let sessions = store.sessions
        var allDates: [Date] = sessions.map { $0.start }
        allDates.append(contentsOf: store.confirmedSleeps.map { $0.start })
        allDates.append(contentsOf: store.dailyMetricHistory.map { $0.day })
        guard let earliest = allDates.min() else { return nil }
        let epoch0 = calendar.startOfDay(for: earliest)

        func rel(_ date: Date) -> Double {
            (date.timeIntervalSince(epoch0) * 10).rounded() / 10
        }
        func dayIndex(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: epoch0, to: calendar.startOfDay(for: date)).day ?? 0
        }

        let profile = store.profile
        let manifest = AtriaResearchBundlePayload.Manifest(
            schema: AtriaResearchSharing.schemaVersion,
            pseudonym: pseudonym,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            ageBand: ageBand(yearOfBirth: calendar.component(.year, from: now) - profile.age, now: now),
            weightBandKg: band(profile.weightKg, width: 5, unit: "kg"),
            heightBandCm: band(profile.heightCm, width: 5, unit: "cm"),
            biologicalSex: profile.biologicalSex.rawValue)

        var bundleSessions: [AtriaResearchBundlePayload.Session] = []
        bundleSessions.reserveCapacity(sessions.count)
        for session in sessions {
            var hrPoints: [[Double]] = []
            hrPoints.reserveCapacity(session.points.count)
            for point in session.points {
                let tRel: Double = (point.t * 10).rounded() / 10
                hrPoints.append([tRel, Double(point.bpm)])
            }
            var rrPoints: [[Double]] = []
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
        let bundleSleeps = store.confirmedSleeps.map { sleep in
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
        let bundleWorkouts = store.confirmedWorkouts.map { workout in
            AtriaResearchBundlePayload.Workout(startRel: rel(workout.start),
                                               endRel: rel(workout.end),
                                               label: workout.label,
                                               avgHR: workout.avgHR,
                                               peakHR: workout.peakHR)
        }
        let bundleDays = store.dailyMetricHistory.map { metric in
            AtriaResearchBundlePayload.Day(dayIndex: dayIndex(metric.day),
                                           recoveryPercent: metric.recoveryPercent,
                                           strain: metric.strain,
                                           sleepHours: metric.sleepDuration.map { $0 / 3600 },
                                           restingHR: metric.restingHR,
                                           hrv: metric.hrv)
        }
        store.journalAnswers.loadIfNeeded()
        let bundleJournal = store.journalAnswers.answers.map { answer -> AtriaResearchBundlePayload.JournalAnswer in
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

        let payload = AtriaResearchBundlePayload(manifest: manifest,
                                                 sessions: bundleSessions,
                                                 sleeps: bundleSleeps,
                                                 workouts: bundleWorkouts,
                                                 days: bundleDays,
                                                 journal: bundleJournal)
        // Encode + gzip + digest of a multi-MB payload must not block the UI.
        return await Task.detached(priority: .userInitiated) {
            finishBuild(payload: payload, pseudonym: pseudonym, bundleDays: bundleDays)
        }.value
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
        // never accumulated.
        let tmp = FileManager.default.temporaryDirectory
        if let stale = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for file in stale where file.lastPathComponent.hasPrefix("atria-research-") {
                try? FileManager.default.removeItem(at: file)
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
                    .buttonStyle(.bordered)

                    Button {
                        AtriaResearchSharing.grantConsent()
                        onConsented()
                        dismiss()
                    } label: {
                        Text("I agree — share anonymously")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
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
    @AppStorage(AtriaResearchSharing.optInKey) private var optedIn = false
    @State private var showConsent = false
    @State private var shareURL: URL?

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

                if let receipt = AtriaResearchSharing.lastReceipt {
                    Text("Last bundle: \(receipt.replacingOccurrences(of: "|", with: " · "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Anonymous research sharing")
        } footer: {
            Text(optedIn
                 ? "Identified only by a random code. Turning this off destroys the code — future shares cannot be linked to past ones."
                 : "Off by default. Sharing is a gift: an anonymized, date-scrambled copy of your recordings, inspectable before anything leaves this phone.")
        }
        .sheet(isPresented: $showConsent) {
            AtriaResearchConsentSheet(buildPreview: buildBundle) { }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                AtriaResearchShareSheetHost(url: shareURL)
            }
        }
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
                .buttonStyle(.borderedProminent)
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

