import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    let ble: AtriaBLEManager
    let store: SessionStore
    @State private var showOnboarding = false

    var body: some View {
        AtriaHomeContainer(ble: ble, store: store)
            .equatable()
            .onAppear {
                let debugOnboardingStep = Self.debugOnboardingStepArgument()
                let debugCompletesOnboarding = AtriaDeveloperMode.isEnabled
                    && ProcessInfo.processInfo.arguments.contains("--atria-complete-onboarding")
                showOnboarding = debugOnboardingStep != nil || (!store.profile.hasCompletedOnboarding && !debugCompletesOnboarding)
            }
            .sheet(isPresented: $showOnboarding) {
                ProfileOnboardingView(profile: store.profile,
                                      debugInitialStep: Self.debugOnboardingStepArgument()) { profile in
                    store.completeOnboarding(with: profile)
                    showOnboarding = false
                }
                .interactiveDismissDisabled()
            }
    }

    private static func debugOnboardingStepArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
#if DEBUG
        guard let index = arguments.firstIndex(of: "--atria-ui-onboarding-step") else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return "welcome" }
        return arguments[valueIndex]
#else
        return nil
#endif
    }
}

private struct DailyEvidenceCard: View {
    @EnvironmentObject var store: SessionStore
    @State private var lastLogKey = ""
    @State private var confirmationStatus = ""
    @State private var sleepConfirmationStatus = ""
    let restFallback: Int

    private struct Summary {
        let sessionsToday: Int
        let savedMinutes: Int
        let rrSaved: Int
        let detections: [ActivityDetection]
        let savedWorkout: SavedWorkoutAttemptStatus
        let confirmedWorkouts: Int
        let sleepEvidence: SleepEvidenceStatus
        let confirmedSleeps: Int

        var workouts: Int { detections.filter { $0.kind == .workout }.count }
        var restCandidates: Int { detections.filter { $0.kind == .restCandidate }.count }
        var sleepCandidates: Int {
            let detected = detections.filter { $0.kind == .sleepCandidate }.count
            return max(detected, sleepEvidence.candidates)
        }
        var activityCandidates: Int { detections.filter { $0.kind == .activityCandidate }.count }
        var workoutSignalPresent: Bool {
            savedWorkout.ready || savedWorkout.strengthCandidate || savedWorkout.nearMiss || savedWorkout.source != "none"
        }
        var sleepSignalPresent: Bool {
            sleepEvidence.ready || sleepEvidence.fallbackAvailable || sleepCandidates > 0
        }
        var activitySignals: Int {
            activityCandidates + (workoutSignalPresent && workouts == 0 ? 1 : 0)
        }
    }

    var body: some View {
        let summary = makeSummary()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Detected locally", systemImage: "list.bullet.clipboard.fill")
                    .font(.headline)
                Spacer()
                Text("\(summary.sessionsToday) sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                miniMetric("Saved", "\(summary.savedMinutes)m", "today", "externaldrive.fill", .blue, summary.savedMinutes > 0)
                miniMetric("Activity", "\(summary.activitySignals)", summary.confirmedWorkouts > 0 ? "\(summary.confirmedWorkouts) confirmed" : (summary.activitySignals > 0 ? "maybe" : "not yet"), "figure.walk.motion", .orange, summary.activitySignals > 0)
                miniMetric("Rest", "\(summary.restCandidates)", summary.restCandidates > 0 ? "unconfirmed" : "not yet", "chair.lounge.fill", .cyan, summary.restCandidates > 0)
                miniMetric("Sleep", "\(summary.sleepCandidates)", summary.confirmedSleeps > 0 ? "\(summary.confirmedSleeps) confirmed" : (summary.sleepSignalPresent ? "maybe" : "not yet"), "bed.double.fill", .cyan, summary.sleepSignalPresent)
                miniMetric("RR", "\(summary.rrSaved)", summary.rrSaved > 0 ? "saved" : "not yet", "waveform.path.ecg", .purple, summary.rrSaved > 0)
            }

            if summary.detections.isEmpty && !summary.workoutSignalPresent && !summary.sleepSignalPresent {
                Label("No saved activity or sleep signal yet; keep Atria open while wearing the strap.",
                      systemImage: "record.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            } else {
                VStack(spacing: 8) {
                    if summary.workoutSignalPresent {
                        workoutSignalRow(summary.savedWorkout)
                        if !confirmationStatus.isEmpty {
                            Text(confirmationStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if summary.sleepSignalPresent {
                        sleepSignalRow(summary.sleepEvidence)
                        if !sleepConfirmationStatus.isEmpty {
                            Text(sleepConfirmationStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    ForEach(Array(summary.detections.prefix(3).enumerated()), id: \.offset) { _, detection in
                        row(detection)
                    }
                }
            }
        }
        .padding()
        .atriaCard(cornerRadius: 22, emphasis: .soft)
        .onAppear { log(summary: summary, reason: "appear") }
        .onReceive(store.$sessions) { _ in log(summary: makeSummary(), reason: "sessions_changed") }
    }

    private func makeSummary() -> Summary {
        let calendar = Calendar.current
        let rest = store.baseline.restingInt ?? restFallback
        let cutoff = Date().addingTimeInterval(-36 * 60 * 60)
        let today = store.sessions.filter { calendar.isDateInToday($0.start) }
        let recentHistory = store.sessions
            .filter { $0.end >= cutoff && !calendar.isDateInToday($0.start) }
            .sorted { $0.start > $1.start }
            .prefix(40)
        let detectionSource = today + recentHistory
        let detections = detectionSource
            .compactMap { $0.detectedActivity(rest: rest, maxHR: store.profile.maxHR) }
            .sorted { $0.start > $1.start }
        let workout = store.savedWorkoutAttemptStatusFast(rest: rest, maxHR: store.profile.maxHR)
        let sleep = store.sleepEvidenceStatus(rest: rest, calendar: calendar)
        return Summary(sessionsToday: today.count,
                       savedMinutes: Int(today.reduce(0) { $0 + $1.duration } / 60),
                       rrSaved: today.reduce(0) { $0 + $1.rrSampleCount },
                       detections: detections,
                       savedWorkout: workout,
                       confirmedWorkouts: store.confirmedWorkouts.count,
                       sleepEvidence: sleep,
                       confirmedSleeps: store.confirmedSleeps.count)
    }

    private func miniMetric(_ title: String,
                            _ value: String,
                            _ detail: String,
                            _ system: String,
                            _ color: Color,
                            _ ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: system)
                    .foregroundStyle(ready ? color : .secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ detection: ActivityDetection) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(detection.kind))
                .foregroundStyle(color(detection))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(detection.kind.rawValue)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(detection.confidence.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color(detection))
                    Spacer(minLength: 0)
                    Text(detection.start, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(formatMinutes(detection.duration)) · avg \(detection.avgHR) · peak \(detection.peakHR)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(detection.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sleepSignalRow(_ sleep: SleepEvidenceStatus) -> some View {
        let ready = sleep.ready
        let title = ready ? "Sleep detected" : "Possible sleep"
        let detail = "\(formatMinutes(sleep.fallbackDuration)) · span \(formatMinutes(sleep.fallbackSpan)) · chunks \(sleep.fallbackSessions) · \(sleep.fallbackSource.replacingOccurrences(of: "_", with: " "))"
        let rowColor: Color = ready ? .green : .cyan
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "bed.double.fill")
                .foregroundStyle(rowColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(sleep.confidence)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(rowColor)
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if !ready {
                    Text("Saved as user-confirmed sleep only; automatic sleep still needs validated motion evidence.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Button {
                        let rest = store.baseline.restingInt ?? restFallback
                        if let confirmed = store.confirmBestSleepCandidateForUI(rest: rest) {
                            sleepConfirmationStatus = "Confirmed sleep as \(confirmed.confidence.replacingOccurrences(of: "_", with: " "))."
                        } else {
                            sleepConfirmationStatus = "No confirmable sleep signal yet."
                        }
                    } label: {
                        Label("Confirm Sleep", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .atriaCardAction(prominent: false, tint: .green)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func workoutSignalRow(_ workout: SavedWorkoutAttemptStatus) -> some View {
        let title = workout.ready ? "Workout detected" : (workout.strengthCandidate ? "Strength-like signal" : (workout.nearMiss ? "Activity near miss" : "Saved activity reviewed"))
        let detail = "\(formatMinutes(workout.duration)) · HR p95/p99 \(workout.p95HR)/\(workout.p99HR) peak \(workout.peakHR) · \(workout.captureDiagnosis.replacingOccurrences(of: "_", with: " "))"
        let rowColor: Color = workout.ready ? .green : .orange
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: workout.ready ? "checkmark.circle.fill" : "figure.strengthtraining.traditional")
                .foregroundStyle(rowColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(workout.ready ? "medium" : "low")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(rowColor)
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if !workout.ready {
                    Text("Not counted as workout until activity evidence is stronger.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Button {
                        let rest = store.baseline.restingInt ?? restFallback
                        if let confirmed = store.confirmBestWorkoutCandidateForUI(rest: rest,
                                                                                  maxHR: store.profile.maxHR) {
                            confirmationStatus = "Confirmed for Health as \(confirmed.confidence.replacingOccurrences(of: "_", with: " "))."
                        } else {
                            confirmationStatus = "No confirmable activity signal yet."
                        }
                    } label: {
                        Label("Confirm Activity", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .atriaCardAction(prominent: false, tint: rowColor)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ kind: ActivityDetection.Kind) -> String {
        switch kind {
        case .activityCandidate: return "figure.walk.motion"
        case .workout: return "figure.run"
        case .sleepCandidate: return "bed.double.fill"
        case .restCandidate: return "chair.lounge.fill"
        }
    }

    private func color(_ detection: ActivityDetection) -> Color {
        switch detection.confidence {
        case .low: return .orange
        case .medium: return detection.kind == .workout ? .red : .teal
        case .high: return .green
        }
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes >= 60 {
            return "\(minutes / 60)h\(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    private func log(summary: Summary, reason: String) {
        let top = summary.detections.first
        let key = [
            "\(summary.sessionsToday)",
            "\(summary.savedMinutes)",
            "\(summary.rrSaved)",
            "\(summary.workouts)",
            "\(summary.restCandidates)",
            "\(summary.sleepCandidates)",
            "\(summary.activitySignals)",
            "\(summary.confirmedWorkouts)",
            "\(summary.confirmedSleeps)",
            summary.sleepEvidence.state,
            summary.sleepEvidence.blocker,
            top?.kind.rawValue ?? "none",
            top?.confidence.rawValue ?? "none",
            top?.reason ?? "none",
            summary.savedWorkout.captureDiagnosis
        ].joined(separator: "|")
        guard key != lastLogKey else { return }
        lastLogKey = key
        AtriaDebugLog("ATRIADBG daily_evidence_ui reason=%@ sessions_today=%d saved_minutes=%d rr_saved=%d detections=%d workouts=%d rest_candidates=%d sleep_candidates=%d activity_candidates=%d confirmed_workouts=%d confirmed_sleeps=%d sleep_signal=%d sleep_state=%@ sleep_motion_validated=%d workout_signal=%d workout_diagnosis=%@ top_kind=%@ top_confidence=%@ top_duration_s=%d top_avg_hr=%d top_peak_hr=%d top_reason=%@ rest_diagnostic_only=1 diagnostic_only=%d",
                      reason,
                      summary.sessionsToday,
                      summary.savedMinutes,
                      summary.rrSaved,
                      summary.detections.count,
                      summary.workouts,
                      summary.restCandidates,
                      summary.sleepCandidates,
                      summary.activitySignals,
                      summary.confirmedWorkouts,
                      summary.confirmedSleeps,
                      summary.sleepSignalPresent ? 1 : 0,
                      summary.sleepEvidence.state,
                      summary.sleepEvidence.motionValidated ? 1 : 0,
                      summary.workoutSignalPresent ? 1 : 0,
                      summary.savedWorkout.captureDiagnosis,
                      top?.kind.rawValue ?? "none",
                      top?.confidence.rawValue ?? "none",
                      Int(top?.duration.rounded() ?? 0),
                      top?.avgHR ?? 0,
                      top?.peakHR ?? 0,
                      top?.reason ?? "none",
                      1)
    }
}

private struct CollectionReliabilityCard: View {
    @EnvironmentObject var ble: AtriaBLEManager
    @State private var tick = Date()
    @State private var lastLogKey = ""

    private struct Summary {
        let connected: Bool
        let heartRate: Int
        let longWear: Bool
        let checkpointArmed: Bool
        let checkpointInterval: Int
        let checkpointSource: String
        let checkpointLastStatus: String
        let checkpointLastSamples: Int
        let checkpointLastDuration: Int
        let journal: ActiveSessionJournal.Diagnostics
        let sampleStatus: String
        let sampleReason: String
        let acceptedSamples: Int
        let acceptedGaps: Int
        let maxAcceptedGap: Double
        let watchdogLastStatus: String
        let watchdogLastSource: String
        let watchdogLastAction: String
        let watchdogLastAge: Int
        let watchdogRecoveries: Int
        let rrPresenceStatus: String
        let rrPresenceAction: String
        let rrPresenceRRGap: Double
        let rrPresenceAcceptedGap: Double
        let rrPresenceSamples: Int
        let rrPresenceValues: Int
        let rrPresenceAge: Int
        let officialAppMayBeInstalled: Bool

        var checkpointSaved: Bool {
            checkpointLastStatus.hasPrefix("saved")
        }

        var protected: Bool {
            longWear && checkpointArmed && (journal.fresh || checkpointSaved) && !officialAppMayBeInstalled
        }

        var rrPresent: Bool {
            journal.hasCurrentRR
        }

        var savedRRPresent: Bool {
            rrPresenceValues > 0
        }

        var effectiveRRPresenceStatus: String {
            if journal.fresh && journal.samples > 0 && !journal.hasCurrentRR {
                return "segment_hr_only"
            }
            if journal.hasCurrentRR {
                return "rr_present"
            }
            if savedRRPresent {
                return "saved_rr_only"
            }
            return rrPresenceStatus
        }

        var statusText: String {
            if officialAppMayBeInstalled { return "App conflict" }
            if protected && rrPresent { return "protected" }
            if protected { return "HR protected" }
            if longWear || checkpointArmed { return "warming" }
            return "learning"
        }

        var action: String {
            if officialAppMayBeInstalled {
                return "The official strap app may reclaim BLE in the background. Close or remove it before relying on Atria."
            }
            if !connected { return "Keep the phone near the strap until BLE reconnects." }
            if !longWear || !checkpointArmed { return "Keep Atria open so long-wear checkpoints arm." }
            if !journal.fresh && !checkpointSaved { return "Waiting for the first protected checkpoint." }
            if !rrPresent && savedRRPresent { return "Current segment is HR-only; saved HRV window stays ready." }
            if !rrPresent { return "HR is protected; HRV stays learning until real RR returns." }
            return "Local backup is protected; keep wearing while Atria logs on device."
        }
    }

    var body: some View {
        let summary = makeSummary()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Local backup", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Text(summary.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.protected ? .green : .orange)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                miniMetric("Long wear",
                           summary.longWear ? "on" : "off",
                           summary.checkpointArmed ? "\(summary.checkpointInterval)s" : "not ready",
                           "record.circle.fill",
                           .teal,
                           summary.longWear && summary.checkpointArmed)
                miniMetric("Journal",
                           summary.journal.fresh ? "fresh" : (summary.journal.present ? "stale" : "missing"),
                           "\(summary.journal.samples) HR · \(summary.journal.rrValues) RR",
                           "externaldrive.fill.badge.checkmark",
                           .blue,
                           summary.journal.fresh)
                miniMetric("RR",
                           summary.rrPresent ? "present" : "missing",
                           summary.rrPresent ? "\(summary.journal.rrCoverage3Percent)% coverage" : summary.effectiveRRPresenceStatus,
                           "waveform.path.ecg",
                           .purple,
                           summary.rrPresent)
                miniMetric("Watchdog",
                           "\(summary.watchdogRecoveries)",
                           summary.watchdogLastStatus,
                           "arrow.triangle.2.circlepath",
                           .orange,
                           summary.watchdogLastStatus == "none" || summary.watchdogLastStatus == "ok")
            }

            if summary.officialAppMayBeInstalled {
                Label("The official strap app or its widgets can interrupt strap ownership and fragment saved sessions.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(summary.action, systemImage: summary.protected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(summary.protected ? .green : .secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.78)
        }
        .padding()
        .atriaCard(cornerRadius: 22, emphasis: .soft)
        .onAppear { log(summary: summary, reason: "appear") }
        .onChange(of: ble.status) { _, _ in log(summary: makeSummary(), reason: "ble_status") }
        .onChange(of: ble.heartRate) { _, _ in log(summary: makeSummary(), reason: "hr") }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { date in
            tick = date
            log(summary: makeSummary(), reason: "timer")
        }
    }

    private func makeSummary() -> Summary {
        _ = tick
        let defaults = UserDefaults.standard
        let watchdogAt = defaults.object(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastAt) as? Double
        let rrAt = defaults.object(forKey: AtriaBLEManager.RRPresenceDefaults.at) as? Double
        let watchdogAge = watchdogAt.map { max(0, Int((Date().timeIntervalSince1970 - $0).rounded())) } ?? -1
        let rrAge = rrAt.map { max(0, Int((Date().timeIntervalSince1970 - $0).rounded())) } ?? -1
        return Summary(connected: ble.status == .connected,
                       heartRate: ble.heartRate,
                       longWear: ble.longWearModeEnabled,
                       checkpointArmed: defaults.bool(forKey: AtriaBLEManager.CheckpointDefaults.armed),
                       checkpointInterval: Int(defaults.double(forKey: AtriaBLEManager.CheckpointDefaults.interval)),
                       checkpointSource: defaults.string(forKey: AtriaBLEManager.CheckpointDefaults.source) ?? "none",
                       checkpointLastStatus: defaults.string(forKey: AtriaBLEManager.CheckpointDefaults.lastStatus) ?? "none",
                       checkpointLastSamples: defaults.integer(forKey: AtriaBLEManager.CheckpointDefaults.lastSamples),
                       checkpointLastDuration: defaults.integer(forKey: AtriaBLEManager.CheckpointDefaults.lastDuration),
                       journal: ActiveSessionJournal.diagnostics(),
                       sampleStatus: defaults.string(forKey: AtriaBLEManager.SampleDefaults.lastStatus) ?? "none",
                       sampleReason: defaults.string(forKey: AtriaBLEManager.SampleDefaults.lastReason) ?? "none",
                       acceptedSamples: defaults.integer(forKey: AtriaBLEManager.SampleDefaults.acceptedSamples),
                       acceptedGaps: defaults.integer(forKey: AtriaBLEManager.SampleDefaults.acceptedGaps),
                       maxAcceptedGap: defaults.double(forKey: AtriaBLEManager.SampleDefaults.maxAcceptedGap),
                       watchdogLastStatus: defaults.string(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastStatus) ?? "none",
                       watchdogLastSource: defaults.string(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastSource) ?? "none",
                       watchdogLastAction: defaults.string(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.lastAction) ?? "none",
                       watchdogLastAge: watchdogAge,
                       watchdogRecoveries: defaults.integer(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.noDataCount)
                           + defaults.integer(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.hrContinuityCount)
                           + defaults.integer(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.acceptedHRCount)
                           + defaults.integer(forKey: AtriaBLEManager.WatchdogRecoveryDefaults.rrPresenceCount),
                       rrPresenceStatus: defaults.string(forKey: AtriaBLEManager.RRPresenceDefaults.status) ?? "none",
                       rrPresenceAction: defaults.string(forKey: AtriaBLEManager.RRPresenceDefaults.action) ?? "none",
                       rrPresenceRRGap: defaults.double(forKey: AtriaBLEManager.RRPresenceDefaults.rrGap),
                       rrPresenceAcceptedGap: defaults.double(forKey: AtriaBLEManager.RRPresenceDefaults.acceptedGap),
                       rrPresenceSamples: defaults.integer(forKey: AtriaBLEManager.RRPresenceDefaults.samples),
                       rrPresenceValues: defaults.integer(forKey: AtriaBLEManager.RRPresenceDefaults.rrValues),
                       rrPresenceAge: rrAge,
                       officialAppMayBeInstalled: OfficialAppCoexistenceRisk.mayBeInstalled)
    }

    private func miniMetric(_ title: String,
                            _ value: String,
                            _ detail: String,
                            _ system: String,
                            _ color: Color,
                            _ ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: system)
                    .foregroundStyle(ready ? color : .secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(detail.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func log(summary: Summary, reason: String) {
        let key = [
            "\(summary.connected ? 1 : 0)",
            "\(summary.heartRate)",
            "\(summary.longWear ? 1 : 0)",
            "\(summary.checkpointArmed ? 1 : 0)",
            summary.checkpointLastStatus,
            "\(summary.journal.fresh ? 1 : 0)",
            "\(summary.journal.samples)",
            "\(summary.journal.rrValues)",
            summary.rrPresenceStatus,
            summary.effectiveRRPresenceStatus,
            "\(summary.rrPresenceValues)",
            summary.watchdogLastStatus,
            "\(summary.watchdogRecoveries)",
            "\(summary.officialAppMayBeInstalled ? 1 : 0)"
        ].joined(separator: "|")
        guard key != lastLogKey else { return }
        lastLogKey = key
        AtriaDebugLog("ATRIADBG collection_reliability_ui reason=%@ protected=%d connected=%d hr=%d long_wear=%d checkpoint_armed=%d checkpoint_interval_s=%d checkpoint_source=%@ checkpoint_last_status=%@ checkpoint_last_samples=%d checkpoint_last_duration_s=%d journal_present=%d journal_fresh=%d journal_samples=%d journal_rr_values=%d journal_duration_s=%d journal_rr_max_gap_s=%.1f journal_rr_coverage_3s_percent=%d rr_present=%d rr_presence_status=%@ rr_presence_action=%@ rr_presence_rr_gap_s=%.1f rr_presence_accepted_gap_s=%.1f rr_presence_samples=%d rr_presence_values=%d rr_presence_age_s=%d sample_status=%@ sample_reason=%@ accepted_samples=%d accepted_gaps=%d max_accepted_gap_s=%.1f watchdog_recoveries=%d watchdog_last_status=%@ watchdog_last_source=%@ watchdog_last_action=%@ watchdog_last_age_s=%d official_app_may_be_installed=%d fail_closed=1",
                      reason,
                      summary.protected ? 1 : 0,
                      summary.connected ? 1 : 0,
                      summary.heartRate,
                      summary.longWear ? 1 : 0,
                      summary.checkpointArmed ? 1 : 0,
                      summary.checkpointInterval,
                      summary.checkpointSource,
                      summary.checkpointLastStatus,
                      summary.checkpointLastSamples,
                      summary.checkpointLastDuration,
                      summary.journal.present ? 1 : 0,
                      summary.journal.fresh ? 1 : 0,
                      summary.journal.samples,
                      summary.journal.rrValues,
                      Int(summary.journal.duration.rounded()),
                      summary.journal.maxRRGap,
                      summary.journal.rrCoverage3Percent,
                      summary.rrPresent ? 1 : 0,
                      summary.effectiveRRPresenceStatus,
                      summary.rrPresenceAction,
                      summary.rrPresenceRRGap,
                      summary.rrPresenceAcceptedGap,
                      summary.rrPresenceSamples,
                      summary.rrPresenceValues,
                      summary.rrPresenceAge,
                      summary.sampleStatus,
                      summary.sampleReason,
                      summary.acceptedSamples,
                      summary.acceptedGaps,
                      summary.maxAcceptedGap,
                      summary.watchdogRecoveries,
                      summary.watchdogLastStatus,
                      summary.watchdogLastSource,
                      summary.watchdogLastAction,
                      summary.watchdogLastAge,
                      summary.officialAppMayBeInstalled ? 1 : 0)
    }
}

private enum OfficialAppCoexistenceRisk {
    static var mayBeInstalled: Bool {
        guard let url = URL(string: "whoop://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

struct AtriaDashboardBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(colors: gradientColors,
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
        .overlay(alignment: .topTrailing) {
            // Radial gradient glow instead of a blurred circle: same soft look,
            // but no blur modifier pass (blur is very expensive, especially in the
            // Simulator, and was a source of UI lag).
            Circle()
                .fill(RadialGradient(colors: [topGlowColor, .clear],
                                     center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .offset(x: 70, y: -70)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(RadialGradient(colors: [bottomGlowColor, .clear],
                                     center: .center, startRadius: 0, endRadius: 140))
                .frame(width: 280, height: 280)
                .offset(x: -80, y: 90)
        }
    }

    private var gradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.020, green: 0.024, blue: 0.034),
                Color(red: 0.024, green: 0.030, blue: 0.044),
                Color(red: 0.016, green: 0.020, blue: 0.030)
            ]
        }
        return [
            Color(red: 0.96, green: 0.97, blue: 0.99),
            Color(red: 0.89, green: 0.93, blue: 0.98),
            Color(red: 0.97, green: 0.96, blue: 0.94)
        ]
    }

    private var topGlowColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.12) : Color.white.opacity(0.42)
    }

    private var bottomGlowColor: Color {
        colorScheme == .dark ? Color.blue.opacity(0.10) : Color.cyan.opacity(0.12)
    }
}

struct ProfileOnboardingView: View {
    @State private var draft: AthleteProfile
    let onComplete: (AthleteProfile) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep = .welcome
    @State private var officialAppMayBeInstalled = OfficialAppCoexistenceRisk.mayBeInstalled
    @State private var didRecheckOfficialApp = false

    private enum OnboardingStep: Int, CaseIterable {
        case welcome
        case coexistence
        case connect
        case profile

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .profile }

        init?(debugName: String?) {
            guard let debugName else { return nil }
            switch debugName.lowercased() {
            case "welcome": self = .welcome
            case "coexistence": self = .coexistence
            case "connect", "strap": self = .connect
            case "profile": self = .profile
            default: return nil
            }
        }
    }

    init(profile: AthleteProfile,
         debugInitialStep: String? = nil,
         onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        _step = State(initialValue: OnboardingStep(debugName: debugInitialStep) ?? .welcome)
        self.onComplete = onComplete
    }

    private func recheckOfficialApp() {
        let installed = OfficialAppCoexistenceRisk.mayBeInstalled
        didRecheckOfficialApp = true
        if reduceMotion {
            officialAppMayBeInstalled = installed
        } else {
            withAnimation(.snappy(duration: 0.28)) { officialAppMayBeInstalled = installed }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        switch step {
                        case .welcome: welcomeStep
                        case .coexistence: coexistenceStep
                        case .connect: connectStep
                        case .profile: profileStep
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 124)
                    .transition(.opacity)
                    .id(step)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !step.isFirst {
                        Button {
                            advance(to: OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 14) {
                    onboardingProgressDots
                    Button {
                        if step.isLast {
                            onComplete(draft)
                        } else {
                            advance(to: OnboardingStep(rawValue: step.rawValue + 1) ?? .profile)
                        }
                    } label: {
                        Text(primaryButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .blue)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .coexistence: return officialAppMayBeInstalled ? "I’ll do this — continue" : "Continue"
        case .connect: return "Continue"
        case .profile: return "Use this profile"
        }
    }

    private func advance(to next: OnboardingStep) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: 0.28)) { step = next }
        }
    }

    private var onboardingProgressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: item == step ? 22 : 7, height: 7)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: step)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Image("AtriaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .accessibilityLabel("Atria")
                Text("Welcome to Atria")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Your strap, your data — free and entirely on your phone.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                onboardingFeatureRow(icon: "lock.shield.fill",
                                     tint: .green,
                                     title: "Local data",
                                     detail: "No account, cloud, or subscription.")
                onboardingFeatureRow(icon: "waveform.path.ecg",
                                     tint: .pink,
                                     title: "Strap first",
                                     detail: "Heart rate drives every score.")
                onboardingFeatureRow(icon: "checkmark.seal.fill",
                                     tint: .blue,
                                     title: "Confidence shown",
                                     detail: "Unready metrics stay marked.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    // MARK: - Step 2: app coexistence

    @ViewBuilder
    private var coexistenceStep: some View {
        if officialAppMayBeInstalled {
            officialAppConflictStep
        } else {
            officialAppClearStep
        }
    }

    private var officialAppConflictStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Make room for Atria")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("The official strap app can reclaim the strap and fragment readings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Pick one")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                onboardingNumberedStep(1,
                                       title: "Delete the official strap app (recommended)",
                                       detail: "Remove App, then Delete App.")
                onboardingNumberedStep(2,
                                       title: "Or fully disable it",
                                       detail: "Log out, then disable Bluetooth.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            VStack(alignment: .leading, spacing: 12) {
                Label("Why this matters", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("iOS gives one app strap ownership.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    recheckOfficialApp()
                } label: {
                    Label("I removed it — recheck", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .atriaCardAction(tint: .orange)

                if didRecheckOfficialApp && officialAppMayBeInstalled {
                    Label("Official strap app still detected.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    private var officialAppClearStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.green)
                Text(didRecheckOfficialApp ? "Nicely done" : "You’re clear")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("No competing app detected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                onboardingFeatureRow(icon: "antenna.radiowaves.left.and.right",
                                     tint: .green,
                                     title: "One reader at a time",
                                     detail: "Atria owns the strap.")
                onboardingFeatureRow(icon: "bell.badge",
                                     tint: .blue,
                                     title: "We’ll warn you",
                                     detail: "Interference becomes visible.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    // MARK: - Step 3: Connect your strap

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Connect your strap")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Atria reads your strap over Bluetooth.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                onboardingNumberedStep(1,
                                       title: "Put the strap on",
                                       detail: "Wear it snug.")
                onboardingNumberedStep(2,
                                       title: "Keep your phone nearby",
                                       detail: "Atria connects on its own.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            Label("Switch apps freely; don’t force quit.",
                  systemImage: "hand.raised.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Label("No strap nearby? Continue anyway.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 4: Profile

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set your max heart rate")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Atria uses this for strain and effort.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("How should we set it?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                onboardingSourcePicker

                HStack(spacing: 12) {
                    onboardingStepperCard(title: "Your age",
                                          value: "\(draft.age)",
                                          detail: "13-100") {
                        draft.age = max(13, draft.age - 1)
                    } increment: {
                        draft.age = min(100, draft.age + 1)
                    }

                    onboardingStepperCard(title: "Measured max",
                                          value: "\(draft.measuredMaxHR)",
                                          detail: "120-220 bpm") {
                        draft.measuredMaxHR = max(120, draft.measuredMaxHR - 1)
                    } increment: {
                        draft.measuredMaxHR = min(220, draft.measuredMaxHR + 1)
                    }
                }

                Picker("Sex", selection: $draft.biologicalSex) {
                    ForEach(AthleteProfile.BiologicalSex.allCases) { sex in
                        Text(sex.label).tag(sex)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    onboardingStepperCard(title: "Weight",
                                          value: draft.weightKg > 0 ? "\(Int(draft.weightKg.rounded()))" : "--",
                                          detail: "kg") {
                        draft.weightKg = draft.weightKg <= 0 ? 70 : max(30, draft.weightKg - 1)
                    } increment: {
                        draft.weightKg = draft.weightKg <= 0 ? 70 : min(250, draft.weightKg + 1)
                    }

                    onboardingStepperCard(title: "Height",
                                          value: draft.heightCm > 0 ? "\(Int(draft.heightCm.rounded()))" : "--",
                                          detail: "cm optional") {
                        draft.heightCm = draft.heightCm <= 0 ? 170 : max(120, draft.heightCm - 1)
                    } increment: {
                        draft.heightCm = draft.heightCm <= 0 ? 170 : min(230, draft.heightCm + 1)
                    }
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your max heart rate")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text("\(draft.maxHR)")
                        .font(.title3.weight(.bold).monospacedDigit())
                }

                Text(draft.maxHRSource == .ageEstimate ? "Age estimate; measured is better." : "Measured max selected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    onboardingMetricPill(label: "Source", value: draft.maxHRSource.label, tint: .cyan)
                    onboardingMetricPill(label: "Age", value: "\(draft.age)", tint: .green)
                    onboardingMetricPill(label: "Weight", value: draft.weightKg > 0 ? "\(Int(draft.weightKg.rounded())) kg" : "Add", tint: .orange)
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    private func onboardingFeatureRow(icon: String,
                                      tint: Color,
                                      title: String,
                                      detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func onboardingNumberedStep(_ number: Int,
                                        title: String,
                                        detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var onboardingSourcePicker: some View {
        HStack(spacing: 8) {
            ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                Button {
                    if reduceMotion {
                        draft.maxHRSource = source
                    } else {
                        withAnimation(.snappy(duration: 0.22)) {
                            draft.maxHRSource = source
                        }
                    }
                } label: {
                    Text(source.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .atriaGlassSelectable(selected: draft.maxHRSource == source)
            }
        }
        .padding(8)
        .atriaCard(emphasis: .soft)
    }

    private func onboardingStepperCard(title: String,
                                       value: String,
                                       detail: String,
                                       decrement: @escaping () -> Void,
                                       increment: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.24), lineWidth: 1)
                }
        )
    }

    private func onboardingMetricPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? tint.opacity(0.10) : tint.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.20), lineWidth: 1)
                }
        )
    }
}

extension View {
    /// Cheap selectable chrome for in-scroll controls. Real Liquid Glass stays on
    /// floating toolbar/safe-area controls; repeated glass buttons in cards and
    /// grids are too expensive during scroll.
    @ViewBuilder
    func atriaGlassSelectable(selected: Bool, tint: Color = .blue) -> some View {
        self.buttonStyle(AtriaSegmentButtonStyle(selected: selected, tint: tint))
    }
}

private struct ProfileOnboardingSourceButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.11 : 0.72),
                                colorScheme == .dark
                                    ? Color(red: 0.060, green: 0.078, blue: 0.116).opacity(0.84)
                                    : Color.white.opacity(0.44)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28), lineWidth: 1)
                        }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct ProfileOnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.92 : 1))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                    .fill(
                        LinearGradient(colors: colorScheme == .dark
                            ? [
                                Color(red: 0.18, green: 0.52, blue: 0.98),
                                Color(red: 0.06, green: 0.28, blue: 0.82)
                            ]
                            : [
                                Color(red: 0.24, green: 0.56, blue: 0.98),
                                Color(red: 0.12, green: 0.40, blue: 0.90)
                            ],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.28), lineWidth: 1)
                    }
            )
            .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private struct ProfileOnboardingStepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.88 : 1))
            .padding(.vertical, 10)
            .atriaCard(emphasis: .soft)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Minimal heart-rate sparkline.
struct Sparkline: View, Equatable {
    let values: [Int]

    static func == (lhs: Sparkline, rhs: Sparkline) -> Bool {
        lhs.values == rhs.values
    }

    var body: some View {
        Group {
            if values.count > 1 {
                SparklineShape(values: values)
                    .stroke(.red.gradient, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct SparklineShape: Shape, Equatable {
    let values: [Int]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }

        let lo = Double(values.min() ?? 0)
        let hi = Double(values.max() ?? 1)
        let span = max(hi - lo, 1)

        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.width * CGFloat(Double(index) / Double(values.count - 1))
            let y = rect.height * CGFloat(1 - (Double(value) - lo) / span)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

#Preview {
    ContentView(ble: AtriaBLEManager(), store: SessionStore())
}
