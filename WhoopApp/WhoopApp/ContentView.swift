import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let ble: WhoopBLEManager
    let store: SessionStore
    @State private var showOnboarding = false

    var body: some View {
        AtriaHomeContainer(ble: ble, store: store)
            .equatable()
            .onAppear {
                let debugCompletesOnboarding = ProcessInfo.processInfo.arguments.contains("--whoop-complete-onboarding")
                showOnboarding = !store.profile.hasCompletedOnboarding && !debugCompletesOnboarding
            }
            .sheet(isPresented: $showOnboarding) {
                ProfileOnboardingView(profile: store.profile) { profile in
                    store.completeOnboarding(with: profile)
                    showOnboarding = false
                }
                .interactiveDismissDisabled()
            }
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
                miniMetric("Activity", "\(summary.activitySignals)", summary.confirmedWorkouts > 0 ? "\(summary.confirmedWorkouts) confirmed" : (summary.activitySignals > 0 ? "candidate" : "none"), "figure.walk.motion", .orange, summary.activitySignals > 0)
                miniMetric("Rest", "\(summary.restCandidates)", summary.restCandidates > 0 ? "candidate" : "none", "chair.lounge.fill", .cyan, summary.restCandidates > 0)
                miniMetric("Sleep", "\(summary.sleepCandidates)", summary.confirmedSleeps > 0 ? "\(summary.confirmedSleeps) confirmed" : (summary.sleepSignalPresent ? "candidate" : "none"), "bed.double.fill", .cyan, summary.sleepSignalPresent)
                miniMetric("RR", "\(summary.rrSaved)", summary.rrSaved > 0 ? "saved" : "none", "waveform.path.ecg", .purple, summary.rrSaved > 0)
            }

            if summary.detections.isEmpty && !summary.workoutSignalPresent && !summary.sleepSignalPresent {
                Label("No saved activity or sleep candidate yet; keep Atria open while wearing the strap.",
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
        let title = ready ? "Sleep detected" : "Sleep candidate"
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
                            sleepConfirmationStatus = "No confirmable sleep candidate yet."
                        }
                    } label: {
                        Label("Confirm Sleep", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
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
                            confirmationStatus = "No confirmable activity candidate yet."
                        }
                    } label: {
                        Label("Confirm Activity", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
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
        WHOOPDebugLog("WHOOPDBG daily_evidence_ui reason=%@ sessions_today=%d saved_minutes=%d rr_saved=%d detections=%d workouts=%d rest_candidates=%d sleep_candidates=%d activity_candidates=%d confirmed_workouts=%d confirmed_sleeps=%d sleep_signal=%d sleep_state=%@ sleep_motion_validated=%d workout_signal=%d workout_diagnosis=%@ top_kind=%@ top_confidence=%@ top_duration_s=%d top_avg_hr=%d top_peak_hr=%d top_reason=%@ rest_diagnostic_only=1 diagnostic_only=%d",
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
    @EnvironmentObject var ble: WhoopBLEManager
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

        var checkpointSaved: Bool {
            checkpointLastStatus.hasPrefix("saved")
        }

        var protected: Bool {
            longWear && checkpointArmed && (journal.fresh || checkpointSaved)
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
            if protected && rrPresent { return "protected" }
            if protected { return "HR protected" }
            if longWear || checkpointArmed { return "warming" }
            return "learning"
        }

        var action: String {
            if !connected { return "Keep the phone near the strap until BLE reconnects." }
            if !longWear || !checkpointArmed { return "Keep Atria open so long-wear checkpoints arm." }
            if !journal.fresh && !checkpointSaved { return "Waiting for the first protected checkpoint." }
            if !rrPresent && savedRRPresent { return "Current segment is HR-only; saved HRV window stays ready." }
            if !rrPresent { return "HR is protected; HRV stays learning until real RR returns." }
            return "Collection is protected; keep wearing while Atria logs locally."
        }
    }

    var body: some View {
        let summary = makeSummary()
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Collection", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Text(summary.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.protected ? .green : .orange)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                miniMetric("Long wear",
                           summary.longWear ? "on" : "off",
                           summary.checkpointArmed ? "\(summary.checkpointInterval)s" : "not armed",
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

            Label(summary.action, systemImage: summary.protected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(summary.protected ? .green : .secondary)
                .lineLimit(2)
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
        let watchdogAt = defaults.object(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.lastAt) as? Double
        let rrAt = defaults.object(forKey: WhoopBLEManager.RRPresenceDefaults.at) as? Double
        let watchdogAge = watchdogAt.map { max(0, Int((Date().timeIntervalSince1970 - $0).rounded())) } ?? -1
        let rrAge = rrAt.map { max(0, Int((Date().timeIntervalSince1970 - $0).rounded())) } ?? -1
        return Summary(connected: ble.status == .connected,
                       heartRate: ble.heartRate,
                       longWear: ble.longWearModeEnabled,
                       checkpointArmed: defaults.bool(forKey: WhoopBLEManager.CheckpointDefaults.armed),
                       checkpointInterval: Int(defaults.double(forKey: WhoopBLEManager.CheckpointDefaults.interval)),
                       checkpointSource: defaults.string(forKey: WhoopBLEManager.CheckpointDefaults.source) ?? "none",
                       checkpointLastStatus: defaults.string(forKey: WhoopBLEManager.CheckpointDefaults.lastStatus) ?? "none",
                       checkpointLastSamples: defaults.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastSamples),
                       checkpointLastDuration: defaults.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastDuration),
                       journal: ActiveSessionJournal.diagnostics(),
                       sampleStatus: defaults.string(forKey: WhoopBLEManager.SampleDefaults.lastStatus) ?? "none",
                       sampleReason: defaults.string(forKey: WhoopBLEManager.SampleDefaults.lastReason) ?? "none",
                       acceptedSamples: defaults.integer(forKey: WhoopBLEManager.SampleDefaults.acceptedSamples),
                       acceptedGaps: defaults.integer(forKey: WhoopBLEManager.SampleDefaults.acceptedGaps),
                       maxAcceptedGap: defaults.double(forKey: WhoopBLEManager.SampleDefaults.maxAcceptedGap),
                       watchdogLastStatus: defaults.string(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.lastStatus) ?? "none",
                       watchdogLastSource: defaults.string(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.lastSource) ?? "none",
                       watchdogLastAction: defaults.string(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.lastAction) ?? "none",
                       watchdogLastAge: watchdogAge,
                       watchdogRecoveries: defaults.integer(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.noDataCount)
                           + defaults.integer(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.hrContinuityCount)
                           + defaults.integer(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.acceptedHRCount)
                           + defaults.integer(forKey: WhoopBLEManager.WatchdogRecoveryDefaults.rrPresenceCount),
                       rrPresenceStatus: defaults.string(forKey: WhoopBLEManager.RRPresenceDefaults.status) ?? "none",
                       rrPresenceAction: defaults.string(forKey: WhoopBLEManager.RRPresenceDefaults.action) ?? "none",
                       rrPresenceRRGap: defaults.double(forKey: WhoopBLEManager.RRPresenceDefaults.rrGap),
                       rrPresenceAcceptedGap: defaults.double(forKey: WhoopBLEManager.RRPresenceDefaults.acceptedGap),
                       rrPresenceSamples: defaults.integer(forKey: WhoopBLEManager.RRPresenceDefaults.samples),
                       rrPresenceValues: defaults.integer(forKey: WhoopBLEManager.RRPresenceDefaults.rrValues),
                       rrPresenceAge: rrAge)
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
            "\(summary.watchdogRecoveries)"
        ].joined(separator: "|")
        guard key != lastLogKey else { return }
        lastLogKey = key
        WHOOPDebugLog("WHOOPDBG collection_reliability_ui reason=%@ protected=%d connected=%d hr=%d long_wear=%d checkpoint_armed=%d checkpoint_interval_s=%d checkpoint_source=%@ checkpoint_last_status=%@ checkpoint_last_samples=%d checkpoint_last_duration_s=%d journal_present=%d journal_fresh=%d journal_samples=%d journal_rr_values=%d journal_duration_s=%d journal_rr_max_gap_s=%.1f journal_rr_coverage_3s_percent=%d rr_present=%d rr_presence_status=%@ rr_presence_action=%@ rr_presence_rr_gap_s=%.1f rr_presence_accepted_gap_s=%.1f rr_presence_samples=%d rr_presence_values=%d rr_presence_age_s=%d sample_status=%@ sample_reason=%@ accepted_samples=%d accepted_gaps=%d max_accepted_gap_s=%.1f watchdog_recoveries=%d watchdog_last_status=%@ watchdog_last_source=%@ watchdog_last_action=%@ watchdog_last_age_s=%d fail_closed=1",
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
                      summary.watchdogLastAge)
    }
}

struct AtriaDashboardBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(colors: gradientColors,
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(topGlowColor)
                .frame(width: 240, height: 240)
                .blur(radius: 28)
                .offset(x: 70, y: -70)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(bottomGlowColor)
                .frame(width: 220, height: 220)
                .blur(radius: 36)
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

    init(profile: AthleteProfile, onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Profile")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("Tune HRmax once so strain, recovery, and workout guidance stay fast and local.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text("HRmax source")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            onboardingSourcePicker

                            HStack(spacing: 12) {
                                onboardingStepperCard(title: "Age",
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
                        }
                        .padding(18)
                        .atriaCard(cornerRadius: 22, emphasis: .soft)

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Active HRmax")
                                    .font(.headline.weight(.semibold))
                                Spacer()
                                Text("\(draft.maxHR)")
                                    .font(.title3.weight(.bold).monospacedDigit())
                            }

                            Text("Atria uses HR reserve from learned resting HR up to this HRmax. You can change it later from the Vitals tab.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                onboardingMetricPill(label: "Source", value: draft.maxHRSource.label, tint: .cyan)
                                onboardingMetricPill(label: "Age", value: "\(draft.age)", tint: .green)
                                onboardingMetricPill(label: "Measured", value: "\(draft.measuredMaxHR)", tint: .orange)
                            }
                        }
                        .padding(18)
                        .atriaCard(cornerRadius: 22, emphasis: .soft)
                    }

                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 124)
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    Button("Use this profile") {
                        onComplete(draft)
                    }
                    .buttonStyle(ProfileOnboardingPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var onboardingSourcePicker: some View {
        HStack(spacing: 8) {
            ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        draft.maxHRSource = source
                    }
                } label: {
                    Text(source.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(ProfileOnboardingSourceButtonStyle(selected: draft.maxHRSource == source))
            }
        }
        .padding(8)
        .atriaCard(cornerRadius: 22, emphasis: .soft)
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
                .buttonStyle(ProfileOnboardingStepperButtonStyle())

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ProfileOnboardingStepperButtonStyle())
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
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
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
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.28), lineWidth: 1)
                    }
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct ProfileOnboardingStepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.88 : 1))
            .padding(.vertical, 10)
            .atriaCard(cornerRadius: 22, emphasis: .soft)
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
    ContentView(ble: WhoopBLEManager(), store: SessionStore())
}
