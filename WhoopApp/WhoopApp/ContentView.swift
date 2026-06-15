import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var ble: WhoopBLEManager
    @EnvironmentObject var store: SessionStore
    @State private var showOnboarding = false
    @State private var lastStrainLogKey = ""
    @State private var lastGuidanceLogKey = ""
    @State private var lastLocalStatusLogKey = ""
    @State private var lastLocalStatusCriticalKey = ""
    @State private var lastLocalStatusLogAt: Date?
    @State private var lastGateReadinessLogKey = ""
    @State private var lastHRVDisplayLogKey = ""
    @State private var lastStrainValidationLogKey = ""
    @State private var lastHRReferenceUILogKey = ""
    @State private var lastHRMaxCalibrationLogKey = ""
    @State private var lastStrainLogAt: Date?
    @State private var lastStrainLoggedValue: Double?
    @State private var diagnosticsWarm = false
    @State private var hrReferenceShareURL: URL?
    @State private var rrReferenceShareURL: URL?
    @State private var showHRReferenceImporter = false
    @State private var showRRReferenceImporter = false
    @State private var hrReferenceImportStatus = ""
    @State private var rrReferenceImportStatus = ""
    @State private var lastTodaySettledLogKey = ""
    @State private var lastTodayGateETrainingLogKey = ""
    @State private var manualCheckpointStatus = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    todayUsabilityCard
                    DailyEvidenceCard(restFallback: restForStrain)
                    CollectionReliabilityCard()
                    if diagnosticsWarm {
                        localStatusCard
                        trendPreviewCard
                    } else {
                        diagnosticsWarmupCard
                    }
                    HStack(spacing: 12) {
                        RecoveryRing(percent: recoveryEstimate.percent,
                                     detail: recoveryEstimate.detail,
                                     confidence: recoveryEstimate.confidence)
                        StrainGauge(strain: strainEstimate.strain,
                                    detail: strainEstimate.detail,
                                    confidence: strainEstimate.confidence)
                    }
                    DailyGuidanceCard(recovery: recoveryEstimate, strain: strainEstimate.strain)
                    if diagnosticsWarm {
                        strainValidationCard
                    }
                    heartRateCard
                    hrvCard
                    BaselineCard(baseline: store.baseline, currentResting: ble.restingHR)
                    profileCard
                    metricsRow
                    captureCard
                    framesCard
                }
                .padding()
            }
            .navigationTitle("Atria")
            .background(Color(.systemGroupedBackground))
            .onAppear { logRecoveryEstimate(recoveryEstimate) }
            .onAppear { logStrainEstimate(strainEstimate) }
            .onAppear { logGuidanceDecision(recovery: recoveryEstimate, strain: strainEstimate) }
            .onAppear { logHRMaxCalibrationUI() }
            .onAppear { scheduleDiagnosticsWarmup() }
            .onAppear { syncProfileToBLE() }
            .onAppear {
                let debugCompletesOnboarding = ProcessInfo.processInfo.arguments.contains("--whoop-complete-onboarding")
                showOnboarding = !store.profile.hasCompletedOnboarding && !debugCompletesOnboarding
            }
            .onChange(of: recoveryEstimate) { _, newValue in
                logRecoveryEstimate(newValue)
                logGuidanceDecision(recovery: newValue, strain: strainEstimate)
            }
            .onChange(of: strainEstimate) { _, newValue in
                logStrainEstimate(newValue)
                logGuidanceDecision(recovery: recoveryEstimate, strain: newValue)
                logLocalStatusIfWarm()
            }
            .onReceive(store.$sessions) { _ in
                logLocalStatusIfWarm()
            }
            .onChange(of: store.profile) { _, _ in
                syncProfileToBLE()
                logHRMaxCalibrationUI()
                logLocalStatusIfWarm()
            }
            .onReceive(ble.$session) { _ in
                logHRMaxCalibrationUI()
            }
            .onChange(of: ble.sleepMotionHintCount) { _, _ in
                logLocalStatusIfWarm()
            }
            .sheet(isPresented: $showOnboarding) {
                ProfileOnboardingView(profile: store.profile) { profile in
                    store.completeOnboarding(with: profile)
                    showOnboarding = false
                }
                .interactiveDismissDisabled()
            }
            .fileImporter(isPresented: $showHRReferenceImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                handleHRReferenceImport(result)
            }
            .fileImporter(isPresented: $showRRReferenceImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                handleRRReferenceImport(result)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
        }
    }

    // MARK: Headline metric inputs

    /// Resting HR used for strain (baseline preferred, else live/last session).
    private var restForStrain: Int {
        store.baseline.restingInt ?? ble.restingHR ?? store.sessions.first?.restingStable ?? 60
    }

    private struct StrainEstimate: Equatable {
        let strain: Double
        let totalTRIMP: Double
        let savedTRIMP: Double
        let liveTRIMP: Double
        let restHR: Int
        let maxHR: Int
        let liveSamples: Int
        let savedSessionsToday: Int
        let zoneSummary: Metrics.StrainZoneSummary
        let confidence: String
        let detail: String
    }

    private struct LocalStatus: Equatable {
        let sleepDays: Int
        let sleepCandidateDays: Int
        let workoutDays: Int
        let confirmedWorkoutDays: Int
        let liveWorkout: LiveWorkoutStatus
        let savedWorkout: SavedWorkoutAttemptStatus
        let validatedHRVSessions: Int
        let hrvBaselineSamples: Int
        let trendCoveragePercent: Int
        let sleepState: String
        let sleepBlocker: String
        let workoutState: String
        let hrvState: String
        let recoveryState: String
        let trendState: String
        let motionSource: String
        let motionHintCount: Int
        let motionHintKinds: String
        let radioMode: String
        let longWearMode: Bool
        let historicalGapRepair: HistoricalGapRepairSummary
        let checkpointArmed: Bool
        let checkpointInterval: Int
        let checkpointSource: String
        let checkpointLastStatus: String
        let checkpointLastSamples: Int
        let checkpointLastDuration: Int
    }

    private struct LiveWorkoutStatus: Equatable {
        let samples: Int
        let duration: TimeInterval
        let observedDuration: TimeInterval
        let droppedGapSeconds: TimeInterval
        let maxSampleGap: TimeInterval
        let gapCount: Int
        let avgHR: Int
        let peakHR: Int
        let thresholdHR: Int
        let elevatedSeconds: TimeInterval
        let requiredElevatedSeconds: TimeInterval
        let longestBout: TimeInterval
        let requiredBout: TimeInterval
        let streamCoveragePercent: Int
        let primaryBlocker: String
        let ready: Bool
        let reason: String

        var state: String { ready ? "ready" : "learning" }
    }

    private struct GateReadiness: Identifiable, Equatable {
        let gate: String
        let title: String
        let status: String
        let blocker: String

        var id: String { gate }
        var isReady: Bool { status == "ready" }
    }

    private struct HRReferenceUIStatus: Equatable {
        let state: String
        let reason: String
        let totalHealthKitHRSamples: Int
        let atriaHRSamples: Int
        let independentHRSamples: Int
        let independentSources: String
        let pairs: Int
        let meanDelta: Double?
        let maxDelta: Double?
        let csvStatus: String
        let csvReason: String
        let csvPairs: Int
        let csvReferenceSamples: Int
        let csvMeanDelta: Double?
        let csvMedianDelta: Double?
        let csvMaxDelta: Double?
        let csvWithinTolerancePercent: Int
        let csvValidated: Bool
        let healthKitValidated: Bool
        let savedWorkout: SavedWorkoutAttemptStatus

        var isReady: Bool { csvValidated || healthKitValidated }
    }

    /// Day strain = strain(today's saved TRIMP + the live session's TRIMP).
    private var strainEstimate: StrainEstimate {
        let rest = restForStrain, max = store.profile.maxHR
        let savedSessionsToday = store.sessions.filter { Calendar.current.isDateInToday($0.start) }.count
        let todaySessions = store.sessions.filter { Calendar.current.isDateInToday($0.start) }
        let saved = todaySessions.reduce(0) { $0 + $1.trimp(rest: rest, max: max) }
        let savedZones = todaySessions.reduce(Metrics.StrainZoneSummary.empty) { partial, session in
            partial + Metrics.strainZoneSummary(session.points.map { (t: $0.t, bpm: $0.bpm) },
                                                rest: rest,
                                                max: max)
        }
        let liveSeries = ble.session.first.map { first in
            ble.session.map { (t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm) }
        } ?? []
        let live = liveSeries.isEmpty ? 0 : Metrics.trimp(liveSeries, rest: rest, max: max)
        let liveZones = Metrics.strainZoneSummary(liveSeries, rest: rest, max: max)
        let zones = savedZones + liveZones
        let total = saved + live
        let strain = Metrics.strain(fromTRIMP: total)
        let confidence: String
        if max <= rest {
            confidence = "learning"
        } else if savedSessionsToday > 0 || ble.session.count >= 60 {
            confidence = "local"
        } else {
            confidence = "learning"
        }
        let detail = String(format: "TRIMP %.1f (saved %.1f + live %.1f) · RHR %d · HRmax %d",
                            total, saved, live, rest, max)
        return StrainEstimate(strain: strain,
                              totalTRIMP: total,
                              savedTRIMP: saved,
                              liveTRIMP: live,
                              restHR: rest,
                              maxHR: max,
                              liveSamples: ble.session.count,
                              savedSessionsToday: savedSessionsToday,
                              zoneSummary: zones,
                              confidence: confidence,
                              detail: detail)
    }

    /// Recovery v2: lnRMSSD z-score when a validated HRV baseline exists;
    /// otherwise an explicitly labeled resting-HR fallback/learning state.
    private var recoveryEstimate: Metrics.RecoveryEstimate {
        Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                           fallbackRMSSD: store.latestReferenceValidatedHRV,
                           restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                           baseline: store.baseline)
    }

    private var dashboardTrends: [TrendSummary] {
        store.trendSummaries(rest: store.baseline.restingInt ?? restForStrain,
                             maxHR: store.profile.maxHR)
    }

    private var localStatus: LocalStatus {
        let rest = store.baseline.restingInt ?? restForStrain
        let rollups = store.dailyRollups(rest: rest, maxHR: store.profile.maxHR)
        let sleepDays = rollups.filter { $0.sleepReady > 0 }.count
        let sleepCandidateDays = rollups.filter { $0.sleepCandidates > 0 }.count
        let sleepEvidence = store.sleepEvidenceStatus(rest: rest, sleepDays: sleepDays)
        let workoutDays = rollups.filter { $0.workouts > 0 }.count
        let confirmedWorkoutDays = rollups.filter { $0.confirmedWorkouts > 0 }.count
        let liveWorkout = liveWorkoutStatus(rest: rest, maxHR: store.profile.maxHR)
        let savedWorkout = store.savedWorkoutAttemptStatus(rest: rest, maxHR: store.profile.maxHR)
        let historicalGapRepair = store.historicalGapRepairStatus(rest: rest, maxHR: store.profile.maxHR)
        let validatedHRV = store.sessions.compactMap(\.referenceValidatedHRV).filter { $0 > 0 }.count
        let trend90 = store.trendSummaries(rest: rest, maxHR: store.profile.maxHR).first { $0.days == 90 }
        let hrvState = validatedHRV > 0 ? "reference partial" : "reference pending"
        let recoveryState = recoveryEstimate.confidence == .high ? "ready" : recoveryEstimate.confidence.rawValue
        let savedMotionHintCount = store.sessions.reduce(0) { $0 + $1.motionHintCountValue }
        let totalMotionHintCount = savedMotionHintCount + ble.sleepMotionHintCount
        let motionHintKinds = combinedMotionHintKinds(saved: store.sessions.map(\.motionHintKindsValue),
                                                      live: ble.sleepMotionHintKinds)
        let motionSource = sleepEvidence.motionSource != "unavailable"
            ? sleepEvidence.motionSource
            : (totalMotionHintCount > 0 ? "diagnostic_observe_only" : "unavailable")
        let checkpointArmed = UserDefaults.standard.bool(forKey: WhoopBLEManager.CheckpointDefaults.armed)
        let checkpointInterval = Int(UserDefaults.standard.double(forKey: WhoopBLEManager.CheckpointDefaults.interval))
        let checkpointSource = UserDefaults.standard.string(forKey: WhoopBLEManager.CheckpointDefaults.source) ?? "none"
        let checkpointLastStatus = UserDefaults.standard.string(forKey: WhoopBLEManager.CheckpointDefaults.lastStatus) ?? "none"
        return LocalStatus(sleepDays: sleepDays,
                           sleepCandidateDays: sleepCandidateDays,
                           workoutDays: workoutDays,
                           confirmedWorkoutDays: confirmedWorkoutDays,
                           liveWorkout: liveWorkout,
                           savedWorkout: savedWorkout,
                           validatedHRVSessions: validatedHRV,
                           hrvBaselineSamples: store.baseline.hrvSampleCount,
                           trendCoveragePercent: trend90?.coveragePercent ?? 0,
                           sleepState: sleepEvidence.state.replacingOccurrences(of: "_", with: "-"),
                           sleepBlocker: sleepEvidence.blocker,
                           workoutState: workoutDays > 0 ? "ready" : (confirmedWorkoutDays > 0 ? "manual confirmed" : (savedWorkout.strengthCandidate ? "strength candidate" : (savedWorkout.nearMiss ? "near miss" : liveWorkout.state))),
                           hrvState: hrvState,
                           recoveryState: recoveryState,
                           trendState: trend90?.confidence ?? "learning",
                           motionSource: motionSource,
                           motionHintCount: totalMotionHintCount,
                           motionHintKinds: motionHintKinds,
                           radioMode: ble.standardHROnlyEnabled ? "standard_hr_only" : "full_protocol",
                           longWearMode: ble.longWearModeEnabled,
                           historicalGapRepair: historicalGapRepair,
                           checkpointArmed: checkpointArmed,
                           checkpointInterval: checkpointInterval,
                           checkpointSource: checkpointSource,
                           checkpointLastStatus: checkpointLastStatus,
                           checkpointLastSamples: UserDefaults.standard.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastSamples),
                           checkpointLastDuration: UserDefaults.standard.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastDuration))
    }

    private func combinedMotionHintKinds(saved: [String], live: String) -> String {
        var counts: [String: Int] = [:]
        func ingest(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "none" else { return }
            for part in trimmed.split(separator: ",") {
                let fields = part.split(separator: ":", maxSplits: 1).map(String.init)
                let kind = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kind.isEmpty, kind != "none" else { continue }
                let count = fields.count > 1 ? (Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) : 1
                counts[kind, default: 0] += max(count, 1)
            }
        }
        saved.forEach(ingest)
        ingest(live)
        if counts.isEmpty { return "none" }
        return counts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .map { "\($0.key):\($0.value)" }
        .joined(separator: ",")
    }

    private func liveWorkoutStatus(rest: Int, maxHR: Int) -> LiveWorkoutStatus {
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        guard ble.session.count >= 2,
              let first = ble.session.first,
              let last = ble.session.last else {
            return LiveWorkoutStatus(samples: ble.session.count,
                                     duration: 0,
                                     observedDuration: 0,
                                     droppedGapSeconds: 0,
                                     maxSampleGap: 0,
                                     gapCount: 0,
                                     avgHR: ble.heartRate,
                                     peakHR: ble.heartRate,
                                     thresholdHR: threshold,
                                     elevatedSeconds: 0,
                                     requiredElevatedSeconds: 300,
                                     longestBout: 0,
                                     requiredBout: 180,
                                     streamCoveragePercent: 0,
                                     primaryBlocker: "insufficient_samples",
                                     ready: false,
                                     reason: "insufficient_samples")
        }

        let points = ble.session.map { sample in
            SavedSession.Point(t: sample.t.timeIntervalSince(first.t), bpm: sample.bpm)
        }
        let snapshot = SavedSession(id: UUID(),
                                    start: first.t,
                                    end: last.t,
                                    label: "Live workout",
                                    points: points,
                                    hrv: nil,
                                    hrvReferenceValidated: false)
        let readiness = snapshot.workoutReadiness(rest: rest, maxHR: maxHR)
        return LiveWorkoutStatus(samples: snapshot.points.count,
                                 duration: readiness.duration,
                                 observedDuration: readiness.observedDuration,
                                 droppedGapSeconds: readiness.droppedGapSeconds,
                                 maxSampleGap: readiness.maxSampleGap,
                                 gapCount: readiness.gapCount,
                                 avgHR: readiness.avgHR,
                                 peakHR: readiness.peakHR,
                                 thresholdHR: readiness.thresholdHR,
                                 elevatedSeconds: readiness.elevatedSeconds,
                                 requiredElevatedSeconds: readiness.requiredElevatedSeconds,
                                 longestBout: readiness.longestElevatedBout,
                                 requiredBout: readiness.requiredElevatedBout,
                                 streamCoveragePercent: readiness.streamCoveragePercent,
                                 primaryBlocker: readiness.primaryBlocker,
                                 ready: readiness.ready,
                                 reason: readiness.reason)
    }

    private func logRecoveryEstimate(_ estimate: Metrics.RecoveryEstimate) {
        NSLog("WHOOPDBG recovery_v2 percent=%d confidence=%@ uses_hrv=%d detail=%@",
              estimate.percent ?? -1,
              estimate.confidence.rawValue,
              estimate.usesHRV ? 1 : 0,
              estimate.detail)
    }

    private func logStrainEstimate(_ estimate: StrainEstimate) {
        let zone = estimate.zoneSummary
        let now = Date()
        let logKey = String(format: "%.1f|%.1f|%.1f|%d|%d|%@|%d|%.0f|%.0f|%.0f|%.0f|%.0f",
                            estimate.totalTRIMP,
                            estimate.savedTRIMP,
                            estimate.liveTRIMP,
                            estimate.restHR,
                            estimate.maxHR,
                            estimate.confidence,
                            estimate.savedSessionsToday,
                            zone.secondsZ0,
                            zone.secondsZ1,
                            zone.secondsZ2,
                            zone.secondsZ3,
                            zone.secondsZ4)
        guard logKey != lastStrainLogKey else { return }
        if let lastStrainLogAt {
            let elapsed = now.timeIntervalSince(lastStrainLogAt)
            let lastValue = lastStrainLoggedValue ?? estimate.strain
            let materialChange = abs(estimate.strain - lastValue) >= 0.10
            guard elapsed >= 60 || (materialChange && elapsed >= 15) else { return }
        }
        lastStrainLogKey = logKey
        lastStrainLogAt = now
        lastStrainLoggedValue = estimate.strain
        NSLog("WHOOPDBG strain_explain strain=%.2f confidence=%@ trimp_total=%.2f trimp_saved=%.2f trimp_live=%.2f rest_hr=%d max_hr=%d live_samples=%d saved_sessions_today=%d detail=%@",
              estimate.strain,
              estimate.confidence,
              estimate.totalTRIMP,
              estimate.savedTRIMP,
              estimate.liveTRIMP,
              estimate.restHR,
              estimate.maxHR,
              estimate.liveSamples,
              estimate.savedSessionsToday,
              estimate.detail)
        NSLog("WHOOPDBG strain_zone_summary source=saved_plus_live rest_hr=%d max_hr=%d samples=%d seconds_total=%.0f z0_lt30=%.0f z1_30_50=%.0f z2_50_70=%.0f z3_70_85=%.0f z4_85_100=%.0f dropped_gap_s=%.0f min_hrr=%.2f max_hrr=%.2f trimp_total=%.2f strain=%.2f confidence=%@",
              estimate.restHR,
              estimate.maxHR,
              zone.samples,
              zone.totalSeconds,
              zone.secondsZ0,
              zone.secondsZ1,
              zone.secondsZ2,
              zone.secondsZ3,
              zone.secondsZ4,
              zone.droppedGapSeconds,
              zone.minHRReserve,
              zone.maxHRReserve,
              estimate.totalTRIMP,
              estimate.strain,
              estimate.confidence)
        if diagnosticsWarm {
            logStrainValidationUI(strainValidationStatus)
        }
    }

    private var strainValidationStatus: StrainValidationSummary {
        store.strainValidationStatus(rest: restForStrain, maxHR: store.profile.maxHR)
    }

    private func logStrainValidationUI(_ summary: StrainValidationSummary) {
        let key = "\(summary.ready)|\(summary.restToMaxReady)|\(summary.primaryBlocker)|\(Int(summary.totalSeconds))|\(summary.streamCoveragePercent)|\(Int(summary.highZoneSeconds))|\(Int((summary.maxHRReserve * 100).rounded()))"
        guard key != lastStrainValidationLogKey else { return }
        lastStrainValidationLogKey = key
        NSLog("WHOOPDBG strain_validation_ui ready=%d rest_to_max_ready=%d blocker=%@ total_s=%.0f stream_coverage_percent=%d z0_s=%.0f high_z3_z4_s=%.0f max_hrr_percent=%d external_hr_reference_validated=%d strain=%.2f source=dashboard",
              summary.ready ? 1 : 0,
              summary.restToMaxReady ? 1 : 0,
              summary.primaryBlocker,
              summary.totalSeconds,
              summary.streamCoveragePercent,
              summary.secondsZ0,
              summary.highZoneSeconds,
              Int((summary.maxHRReserve * 100).rounded()),
              summary.externalHRReferenceValidated ? 1 : 0,
              summary.strain)
    }

    private func logGuidanceDecision(recovery: Metrics.RecoveryEstimate, strain: StrainEstimate) {
        let guide = Coach.guide(recovery: recovery, strain: strain.strain)
        let recoveryText = (recovery.confidence == .high ? recovery.percent : nil).map(String.init) ?? "learning"
        let targetText = guide.target.map { String(format: "%.1f", $0) } ?? "learning"
        let logKey = String(format: "%@|%@|%.1f|%@",
                            recoveryText,
                            targetText,
                            strain.strain,
                            guide.reason)
        guard logKey != lastGuidanceLogKey else { return }
        lastGuidanceLogKey = logKey
        NSLog("WHOOPDBG guidance_decision recovery=%@ recovery_confidence=%@ target=%@ strain=%.2f state=%@ reason=%@ recovery_detail=%@",
              recoveryText,
              recovery.confidence.rawValue,
              targetText,
              strain.strain,
              guide.state,
              guide.reason,
              Self.guidanceEvidenceToken(recovery.detail))
    }

    private struct HRMaxCalibrationSummary: Equatable {
        let savedPeak: Int
        let livePeak: Int
        let observedPeak: Int
        let measuredMax: Int
        let activeMax: Int
        let source: AthleteProfile.HRMaxSource
        let canRaiseMeasured: Bool
        let suggestion: String
    }

    private struct TodayMetricItem: Identifiable {
        let title: String
        let value: String
        let detail: String
        let system: String
        let color: Color
        let ready: Bool

        var id: String { title }
    }

    private var hrMaxCalibrationSummary: HRMaxCalibrationSummary {
        let savedPeak = store.sessions.lazy
            .flatMap { $0.points.map(\.bpm) }
            .max() ?? 0
        let livePeak = ble.session.map(\.bpm).max() ?? 0
        let observedPeak = max(savedPeak, livePeak)
        let measured = store.profile.measuredMaxHR
        let canRaise = observedPeak > measured
        let suggestion: String
        if observedPeak <= 0 {
            suggestion = "collect_hr"
        } else if canRaise {
            suggestion = "user_confirm_raise_measured_hrmax"
        } else {
            suggestion = "keep_profile_no_auto_lower"
        }
        return HRMaxCalibrationSummary(savedPeak: savedPeak,
                                       livePeak: livePeak,
                                       observedPeak: observedPeak,
                                       measuredMax: measured,
                                       activeMax: store.profile.maxHR,
                                       source: store.profile.maxHRSource,
                                       canRaiseMeasured: canRaise,
                                       suggestion: suggestion)
    }

    private func logHRMaxCalibrationUI(action: String = "display") {
        let summary = hrMaxCalibrationSummary
        let key = "\(summary.savedPeak)|\(summary.livePeak)|\(summary.observedPeak)|\(summary.measuredMax)|\(summary.activeMax)|\(summary.source.rawValue)|\(summary.suggestion)|\(action)"
        guard key != lastHRMaxCalibrationLogKey else { return }
        lastHRMaxCalibrationLogKey = key
        NSLog("WHOOPDBG hrmax_calibration_ui action=%@ observed_peak=%d saved_peak=%d live_peak=%d measured_max_hr=%d active_max_hr=%d source=%@ can_raise_measured=%d suggestion=%@ auto_change=0 user_confirmation_required=1 strain_policy=hr_reserve_trimp",
              action,
              summary.observedPeak,
              summary.savedPeak,
              summary.livePeak,
              summary.measuredMax,
              summary.activeMax,
              summary.source.rawValue,
              summary.canRaiseMeasured ? 1 : 0,
              summary.suggestion)
    }

    private func applyObservedPeakAsMeasuredHRMax() {
        let summary = hrMaxCalibrationSummary
        guard summary.canRaiseMeasured else {
            logHRMaxCalibrationUI(action: "confirm_skipped")
            return
        }
        store.updateProfile {
            $0.measuredMaxHR = summary.observedPeak
            $0.maxHRSource = .measured
        }
        logHRMaxCalibrationUI(action: "confirm_raise_measured")
    }

    private static func guidanceEvidenceToken(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "none" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private func logLocalStatus(_ status: LocalStatus) {
        let live = status.liveWorkout
        let saved = status.savedWorkout
        let repair = status.historicalGapRepair
        let archive = HistoricalArchive.diagnostics()
        let linkEvidence = WhoopBLEManager.linkEvidence()
        let sampleEvidence = WhoopBLEManager.sampleGapEvidence()
        let watchdogEvidence = WhoopBLEManager.watchdogRecoveryEvidence()
        let protocolEvidence = WhoopBLEManager.protocolEvidence()
        let journalEvidence = WhoopBLEManager.activeSessionJournalEvidence()
        let journalStableEvidence = WhoopBLEManager.activeSessionJournalEvidence(includeAge: false)
        let now = Date()
        let criticalKey = "\(status.sleepDays)|\(status.sleepCandidateDays)|\(status.sleepState)|\(status.sleepBlocker)|\(status.workoutDays)|\(status.confirmedWorkoutDays)|\(status.workoutState)|\(status.hrvState)|\(status.recoveryState)|\(status.trendState)|\(status.radioMode)|\(status.longWearMode)|\(saved.ready)|\(saved.captureDiagnosis)|\(saved.strengthCandidate)|\(live.ready)|\(live.reason)|\(status.checkpointLastStatus)|\(repair.status)|\(repair.reason)"
        let logKey = "\(status.sleepDays)|\(status.sleepCandidateDays)|\(status.sleepBlocker)|\(status.workoutDays)|\(status.confirmedWorkoutDays)|\(status.validatedHRVSessions)|\(status.hrvBaselineSamples)|\(status.trendCoveragePercent)|\(status.recoveryState)|\(status.motionSource)|\(status.motionHintCount)|\(status.motionHintKinds)|\(status.radioMode)|\(status.longWearMode)|\(repair.status)|\(repair.reason)|\(repair.overlapSeconds)|\(repair.separationSeconds)|\(repair.archiveCurrentUsableRows)|\(repair.metricUsable)|\(status.checkpointArmed)|\(status.checkpointInterval)|\(status.checkpointSource)|\(status.checkpointLastStatus)|\(status.checkpointLastSamples)|\(status.checkpointLastDuration)|\(live.samples)|\(Int(live.duration))|\(Int(live.observedDuration))|\(Int(live.droppedGapSeconds))|\(Int(live.elevatedSeconds))|\(Int(live.longestBout))|\(live.streamCoveragePercent)|\(live.primaryBlocker)|\(live.reason)|\(saved.source)|\(saved.chunks)|\(saved.nearMiss)|\(saved.strengthCandidate)|\(saved.strengthCandidateReason)|\(saved.primaryBlocker)|\(saved.streamCoveragePercent)|\(Int(saved.maxSampleGap))|\(saved.gapCount)|\(saved.captureDiagnosis)|\(saved.captureAction)|\(saved.thresholdGapBPM)|\(Int(saved.elevatedSeconds))|\(Int(saved.longestBout))|\(saved.borderlineThresholdHR)|\(Int(saved.borderlineElevatedSeconds))|\(Int(saved.borderlineLongestBout))|\(linkEvidence)|\(sampleEvidence)|\(watchdogEvidence)|\(protocolEvidence)|\(journalStableEvidence)"
        logGateReadinessUI(status)
        logHRVDisplayStatus(status)
        guard logKey != lastLocalStatusLogKey else { return }
        let criticalChanged = criticalKey != lastLocalStatusCriticalKey
        if !criticalChanged, let lastLocalStatusLogAt, now.timeIntervalSince(lastLocalStatusLogAt) < 60 {
            return
        }
        lastLocalStatusCriticalKey = criticalKey
        lastLocalStatusLogKey = logKey
        lastLocalStatusLogAt = now
        NSLog("WHOOPDBG local_status sleep_days=%d sleep_candidate_days=%d sleep_state=%@ sleep_blocker=%@ workout_days=%d confirmed_workout_days=%d workout_state=%@ saved_workout_source=%@ saved_workout_chunks=%d saved_workout_label=%@ saved_workout_near_miss=%d saved_workout_near_miss_reason=%@ saved_workout_strength_candidate=%d saved_workout_strength_candidate_reason=%@ saved_workout_strength_diagnostic_only=1 saved_workout_blocker=%@ saved_workout_capture_diagnosis=%@ saved_workout_capture_action=%@ saved_workout_stream_coverage_percent=%d saved_workout_duration_s=%.0f saved_workout_observed_s=%.0f saved_workout_dropped_gap_s=%.0f saved_workout_max_gap_s=%.1f saved_workout_gap_count=%d saved_workout_peak_hr=%d saved_workout_threshold_hr=%d saved_workout_threshold_gap_bpm=%d saved_workout_elevated_s=%.0f saved_workout_required_elevated_s=%.0f saved_workout_longest_bout_s=%.0f saved_workout_required_bout_s=%.0f saved_workout_borderline_threshold_hr=%d saved_workout_borderline_elevated_s=%.0f saved_workout_borderline_longest_bout_s=%.0f saved_workout_borderline_diagnostic_only=1 saved_workout_ready=%d historical_gap_repair_status=%@ historical_gap_repair_reason=%@ historical_gap_repair_overlap_s=%d historical_gap_repair_separation_s=%d historical_gap_repair_current_usable_rows=%d historical_gap_repair_metric_usable=%d historical_gap_repair_diagnostic_only=1 historical_archive_rows=%d historical_archive_gravity_rows=%d historical_archive_gravity_validated_rows=%d historical_archive_corrected_unix_first=%d historical_archive_corrected_unix_last=%d historical_archive_metric_usable=%d historical_archive_current_usable=%d historical_archive_diagnostic_only=1 live_workout_reason=%@ live_workout_blocker=%@ live_workout_stream_coverage_percent=%d live_workout_samples=%d live_workout_duration_s=%.0f live_workout_observed_duration_s=%.0f live_workout_dropped_gap_s=%.0f live_workout_max_gap_s=%.1f live_workout_gap_count=%d live_workout_avg_hr=%d live_workout_peak_hr=%d live_workout_threshold_hr=%d live_workout_elevated_s=%.0f live_workout_required_elevated_s=%.0f live_workout_longest_bout_s=%.0f live_workout_required_bout_s=%.0f live_workout_ready=%d hrv_state=%@ hrv_validated_sessions=%d hrv_baseline_samples=%d recovery_state=%@ trend90_coverage_percent=%d trend_state=%@ motion_source=%@ radio_mode=%@ long_wear=%d motion_validated=0 motion_hint_count=%d motion_hint_kinds=%@ external_rr_reference=%@ checkpoint_armed=%d checkpoint_interval_s=%d checkpoint_source=%@ checkpoint_last_status=%@ checkpoint_last_samples=%d checkpoint_last_duration_s=%d %@ %@ %@ %@ %@",
              status.sleepDays,
              status.sleepCandidateDays,
              status.sleepState,
              status.sleepBlocker,
              status.workoutDays,
              status.confirmedWorkoutDays,
              status.workoutState,
              saved.source,
              saved.chunks,
              saved.label,
              saved.nearMiss ? 1 : 0,
              saved.nearMissReason,
              saved.strengthCandidate ? 1 : 0,
              saved.strengthCandidateReason,
              saved.primaryBlocker,
              saved.captureDiagnosis,
              saved.captureAction,
              saved.streamCoveragePercent,
              saved.duration,
              saved.observedDuration,
              saved.droppedGapSeconds,
              saved.maxSampleGap,
              saved.gapCount,
              saved.peakHR,
              saved.thresholdHR,
              saved.thresholdGapBPM,
              saved.elevatedSeconds,
              saved.requiredElevatedSeconds,
              saved.longestBout,
              saved.requiredBout,
              saved.borderlineThresholdHR,
              saved.borderlineElevatedSeconds,
              saved.borderlineLongestBout,
              saved.ready ? 1 : 0,
              repair.status,
              repair.reason,
              repair.overlapSeconds,
              repair.separationSeconds,
              repair.archiveCurrentUsableRows,
              repair.metricUsable ? 1 : 0,
              archive.rows,
              archive.gravityRows,
              archive.gravityValidatedRows,
              Int(archive.correctedUnixFirst ?? 0),
              Int(archive.correctedUnixLast ?? 0),
              archive.metricUsableRows,
              archive.currentSessionUsableRows,
              live.reason,
              live.primaryBlocker,
              live.streamCoveragePercent,
              live.samples,
              live.duration,
              live.observedDuration,
              live.droppedGapSeconds,
              live.maxSampleGap,
              live.gapCount,
              live.avgHR,
              live.peakHR,
              live.thresholdHR,
              live.elevatedSeconds,
              live.requiredElevatedSeconds,
              live.longestBout,
              live.requiredBout,
              live.ready ? 1 : 0,
              status.hrvState.replacingOccurrences(of: " ", with: "_"),
              status.validatedHRVSessions,
              status.hrvBaselineSamples,
              status.recoveryState,
              status.trendCoveragePercent,
              status.trendState,
              status.motionSource,
              status.radioMode,
              status.longWearMode ? 1 : 0,
              status.motionHintCount,
              status.motionHintKinds,
              status.validatedHRVSessions > 0 ? "present" : "missing",
              status.checkpointArmed ? 1 : 0,
              status.checkpointInterval,
              status.checkpointSource,
              status.checkpointLastStatus,
              status.checkpointLastSamples,
              status.checkpointLastDuration,
              linkEvidence,
              sampleEvidence,
              watchdogEvidence,
              protocolEvidence,
              journalEvidence)
        logHRVDisplayStatus(status)
        logHRReferenceUI(hrReferenceUIStatus(for: status))
    }

    private func logHRVDisplayStatus(_ status: LocalStatus) {
        let validatedRMSSD = store.latestReferenceValidatedHRV
        let liveReady = ble.hrvSnapshot?.isReady == true
        let rrPackage = store.rrPackageStatusFast()
        let readyForReference = liveReady || rrPackage.ready
        let displayState = validatedRMSSD != nil
            ? "validated"
            : (readyForReference ? "measured_reference_pending" : "learning")
        let displayRMSSD = todayHRVValue(ble.hrvSnapshot, rrPackage: rrPackage)
        let key = "\(displayState)|\(validatedRMSSD ?? 0)|\(liveReady ? 1 : 0)|\(rrPackage.ready ? 1 : 0)|\(status.validatedHRVSessions)|\(ble.hrvSnapshot?.kept ?? 0)|\(ble.hrvSnapshot?.raw ?? 0)|\(rrPackage.kept)|\(rrPackage.raw)"
        guard key != lastHRVDisplayLogKey else { return }
        lastHRVDisplayLogKey = key
        NSLog("WHOOPDBG hrv_display state=%@ main_rmssd=%@ validated_sessions=%d live_ready=%d unreferenced_visible=%d live_kept=%d live_raw=%d rr_package_ready=%d rr_package_reason=%@ rr_package_raw=%d rr_package_kept=%d rr_package_conf=%d rr_package_gap_s=%.1f rr_package_rmssd=%@ reason=%@ metric_promotions=0",
              displayState,
              displayRMSSD,
              status.validatedHRVSessions,
              liveReady ? 1 : 0,
              readyForReference && validatedRMSSD == nil ? 1 : 0,
              ble.hrvSnapshot?.kept ?? 0,
              ble.hrvSnapshot?.raw ?? 0,
              rrPackage.ready ? 1 : 0,
              rrPackage.reason,
              rrPackage.raw,
              rrPackage.kept,
              rrPackage.confidencePercent,
              rrPackage.maxGapSeconds,
              rrPackage.rmssd.map { String(format: "%.1f", $0) } ?? "none",
              validatedRMSSD == nil ? "external_rr_reference_required" : "external_rr_reference_validated")
    }

    private func logGateReadinessUI(_ status: LocalStatus) {
        let rows = gateReadinessRows(for: status)
        let joined = rows.map { "\($0.gate):\($0.status):\($0.blocker)" }.joined(separator: "|")
        guard joined != lastGateReadinessLogKey else { return }
        lastGateReadinessLogKey = joined
        let readyCount = rows.filter(\.isReady).count
        let evidence = rows.map { "\($0.gate)=\($0.status)[\($0.blocker)]" }.joined(separator: ";")
        NSLog("WHOOPDBG gate_readiness_ui gates=%d ready=%d evidence=%@",
              rows.count,
              readyCount,
              evidence)
    }

    private func logHRReferenceUI(_ reference: HRReferenceUIStatus) {
        let key = "\(reference.state)|\(reference.reason)|\(reference.independentHRSamples)|\(reference.pairs)|\(reference.csvStatus)|\(reference.csvReason)|\(reference.csvPairs)|\(reference.savedWorkout.p95HR)|\(reference.savedWorkout.p99HR)|\(reference.savedWorkout.samplesAboveThreshold)|\(reference.savedWorkout.elevatedSeconds)|\(reference.savedWorkout.hrComparisonNeed)|\(reference.savedWorkout.currentProfileMinusP99RequiredBPM)"
        guard key != lastHRReferenceUILogKey else { return }
        lastHRReferenceUILogKey = key
        NSLog("WHOOPDBG hr_reference_ui state=%@ reason=%@ csv_validated=%d healthkit_validated=%d healthkit_total_hr_samples=%d healthkit_atria_hr_samples=%d healthkit_independent_hr_samples=%d healthkit_independent_sources=%@ pairs=%d mean_delta_bpm=%@ max_delta_bpm=%@ csv_status=%@ csv_reason=%@ csv_pairs=%d csv_reference_samples=%d csv_mean_delta_bpm=%@ csv_median_delta_bpm=%@ csv_max_delta_bpm=%@ csv_within_tolerance_percent=%d workout_source=%@ workout_p95_hr=%d workout_p99_hr=%d workout_p99_hrr_percent=%d workout_threshold_hr=%d workout_samples_above_threshold=%d workout_samples_above_borderline=%d workout_elevated_s=%.0f workout_required_elevated_s=%.0f workout_profile_max_hr=%d required_profile_max_hr_for_p99_hrr50=%d current_profile_minus_p99_required_bpm=%d hr_comparison_need=%@ hr_comparison_action=%@ action=%@ fail_closed=1",
              reference.state,
              reference.reason,
              reference.csvValidated ? 1 : 0,
              reference.healthKitValidated ? 1 : 0,
              reference.totalHealthKitHRSamples,
              reference.atriaHRSamples,
              reference.independentHRSamples,
              reference.independentSources,
              reference.pairs,
              reference.meanDelta.map { String(format: "%.2f", $0) } ?? "none",
              reference.maxDelta.map { String(format: "%.2f", $0) } ?? "none",
              reference.csvStatus,
              reference.csvReason,
              reference.csvPairs,
              reference.csvReferenceSamples,
              reference.csvMeanDelta.map { String(format: "%.2f", $0) } ?? "none",
              reference.csvMedianDelta.map { String(format: "%.2f", $0) } ?? "none",
              reference.csvMaxDelta.map { String(format: "%.2f", $0) } ?? "none",
              reference.csvWithinTolerancePercent,
              reference.savedWorkout.source,
              reference.savedWorkout.p95HR,
              reference.savedWorkout.p99HR,
              reference.savedWorkout.p99HRRPercent,
              reference.savedWorkout.thresholdHR,
              reference.savedWorkout.samplesAboveThreshold,
              reference.savedWorkout.samplesAboveBorderline,
              reference.savedWorkout.elevatedSeconds,
              reference.savedWorkout.requiredElevatedSeconds,
              reference.savedWorkout.profileMaxHR,
              reference.savedWorkout.requiredProfileMaxHRForP99AtHRR50,
              reference.savedWorkout.currentProfileMinusP99RequiredBPM,
              reference.savedWorkout.hrComparisonNeed,
              reference.savedWorkout.hrComparisonAction,
              reference.isReady ? "rerun_strain_and_workout_validation" : "provide_independent_hr_reference")
    }

    private func scheduleDiagnosticsWarmup() {
        guard !diagnosticsWarm else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !diagnosticsWarm else { return }
            diagnosticsWarm = true
            logLocalStatus(localStatus)
            logStrainValidationUI(strainValidationStatus)
        }
    }

    private func logLocalStatusIfWarm() {
        guard diagnosticsWarm else { return }
        logLocalStatus(localStatus)
    }

    private func handleHRReferenceImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                hrReferenceImportStatus = "No file selected"
                NSLog("WHOOPDBG hr_reference_import_ui status=cancelled reason=no_file")
                return
            }
            let passed = store.importHRReferenceCSVForUI(from: url)
            hrReferenceImportStatus = passed ? "Reference validated" : "Reference still missing"
            NSLog("WHOOPDBG hr_reference_import_ui status=%@ filename=%@ source=dashboard",
                  passed ? "validated" : "learning",
                  url.lastPathComponent)
            logLocalStatusIfWarm()
        case .failure(let error):
            hrReferenceImportStatus = "Import failed"
            NSLog("WHOOPDBG hr_reference_import_ui status=error error=%@", String(describing: error))
        }
    }

    private func handleRRReferenceImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                rrReferenceImportStatus = "No file selected"
                NSLog("WHOOPDBG rr_reference_import_ui status=cancelled reason=no_file")
                return
            }
            let passed = store.importRRReferenceCSVForUI(from: url)
            rrReferenceImportStatus = passed ? "RR reference validated" : "RR reference pending"
            NSLog("WHOOPDBG rr_reference_import_ui status=%@ filename=%@ source=dashboard",
                  passed ? "validated" : "learning",
                  url.lastPathComponent)
            logLocalStatusIfWarm()
        case .failure(let error):
            rrReferenceImportStatus = "RR import failed"
            NSLog("WHOOPDBG rr_reference_import_ui status=error error=%@", String(describing: error))
        }
    }

    private func syncProfileToBLE() {
        if ble.maxHRSetting != store.profile.maxHR {
            ble.maxHRSetting = store.profile.maxHR
        }
        NSLog("WHOOPDBG strain_profile age=%d source=%@ max_hr=%d measured_max_hr=%d rest_hr=%d",
              store.profile.age,
              store.profile.maxHRSource.rawValue,
              store.profile.maxHR,
              store.profile.measuredMaxHR,
              restForStrain)
    }

    private var connectionStatusText: String {
        if ble.status == .connected {
            return ble.status.rawValue
        }
        let rrPackage = store.rrPackageStatusFast()
        if rrPackage.ready {
            return "\(ble.status.rawValue) · data saved"
        }
        let collection = store.currentCollectionStatus()
        if collection.ready {
            return "\(ble.status.rawValue) · saved tail"
        }
        return ble.status.rawValue
    }

    private var statusCard: some View {
        HStack {
            Circle()
                .fill(ble.status == .connected ? .green : .orange)
                .frame(width: 10, height: 10)
            Text(connectionStatusText).font(.subheadline.weight(.medium))
            Spacer()
            Text(ble.deviceName).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var todayUsabilityCard: some View {
        let strain = strainEstimate
        let recovery = recoveryEstimate
        let hrv = ble.hrvSnapshot
        let validatedRMSSD = store.latestReferenceValidatedHRV
        let hrvReady = validatedRMSSD != nil
        let rrReady = hrv?.isReady == true
        let liveHR = ble.heartRate > 0 ? "\(ble.heartRate)" : "--"
        let savedWorkout = store.savedWorkoutAttemptStatusFast(rest: restForStrain, maxHR: store.profile.maxHR)
        let liveWorkout = liveWorkoutStatus(rest: restForStrain, maxHR: store.profile.maxHR)
        let gateETraining = store.gateETrainingSummary(rest: restForStrain, maxHR: store.profile.maxHR)
        let rrPackage = store.rrPackageStatusFast()
        let rrReadyForReference = rrReady || rrPackage.ready
        let sleep = store.sleepEvidenceStatus(rest: store.baseline.restingInt ?? restForStrain)
        let health = HealthKitExporter.diagnostics(for: store.sessions,
                                                   rest: store.baseline.restingInt ?? restForStrain,
                                                   maxHR: store.profile.maxHR,
                                                   confirmedWorkouts: store.confirmedWorkouts,
                                                   confirmedSleeps: store.confirmedSleeps)
        let backup = store.sessionBackupStatus()
        let collection = store.currentCollectionStatus()
        let checkpointArmed = UserDefaults.standard.bool(forKey: WhoopBLEManager.CheckpointDefaults.armed)
        let checkpointLastStatus = UserDefaults.standard.string(forKey: WhoopBLEManager.CheckpointDefaults.lastStatus) ?? "none"
        let checkpointLastSamples = UserDefaults.standard.integer(forKey: WhoopBLEManager.CheckpointDefaults.lastSamples)
        let loggingReady = checkpointArmed || ble.longWearModeEnabled
        let sessionCount = store.sessions.count
        let metricRows: [[TodayMetricItem]] = [
            [
                TodayMetricItem(title: "Strain", value: String(format: "%.1f", strain.strain), detail: strain.confidence, system: "bolt.heart.fill", color: .orange, ready: true),
                TodayMetricItem(title: "Recovery", value: recovery.percent.map { "\($0)%" } ?? "learning", detail: recovery.confidence.rawValue, system: "gauge.with.dots.needle.bottom.50percent", color: .green, ready: recovery.percent != nil),
                TodayMetricItem(title: "HRV", value: todayHRVValue(hrv, rrPackage: rrPackage), detail: hrvDetail(hrv, rrPackage: rrPackage), system: "waveform.path.ecg", color: .purple, ready: hrvReady || rrReadyForReference)
            ],
            [
                TodayMetricItem(title: "Workout", value: todayWorkoutValue(saved: savedWorkout, live: liveWorkout), detail: todayWorkoutDetail(saved: savedWorkout, live: liveWorkout), system: "figure.run", color: .red, ready: savedWorkout.ready || liveWorkout.ready),
                TodayMetricItem(title: "Sleep", value: todaySleepValue(sleep), detail: todaySleepDetail(sleep), system: "bed.double.fill", color: .cyan, ready: sleep.ready),
                TodayMetricItem(title: "Log", value: loggingReady ? "on" : "off", detail: todayCollectionDetail(collection, fallback: todayLoggingDetail(armed: checkpointArmed, lastStatus: checkpointLastStatus, lastSamples: checkpointLastSamples)), system: "record.circle.fill", color: .teal, ready: loggingReady && collection.ready)
            ],
            [
                TodayMetricItem(title: "Battery", value: ble.batteryLevel >= 0 ? "\(ble.batteryLevel)%" : "--", detail: ble.batteryLevel >= 0 ? "strap" : "waiting", system: "battery.100", color: .green, ready: ble.batteryLevel >= 0),
                TodayMetricItem(title: "RR package", value: todayRRPackageValue(rrPackage), detail: todayRRPackageDetail(rrPackage), system: "waveform.path.ecg", color: .purple, ready: rrPackage.ready),
                TodayMetricItem(title: "Baseline", value: "\(store.baseline.hrvSampleCount)/7", detail: recovery.confidence.rawValue, system: "calendar.badge.clock", color: .indigo, ready: recovery.confidence == .high)
            ],
            [
                TodayMetricItem(title: "Backup", value: todayBackupValue(backup), detail: todayBackupDetail(backup), system: "externaldrive.fill.badge.checkmark", color: .blue, ready: backup.current),
                TodayMetricItem(title: "Health", value: todayHealthValue(health), detail: todayHealthDetail(health), system: "heart.text.square.fill", color: .pink, ready: health.readback.dataAppears),
                TodayMetricItem(title: "Reference", value: todayReferenceValue(health), detail: todayReferenceDetail(health), system: "checkmark.seal.fill", color: .green, ready: health.referenceAudit.externalReferenceReady)
            ]
        ]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Today")
                        .font(.title3.weight(.semibold))
                    Text(todayHeadline(recovery: recovery, hrvReady: hrvReady, rrReady: rrReadyForReference))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(liveHR)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(metricRows.indices, id: \.self) { rowIndex in
                HStack(spacing: 8) {
                    ForEach(metricRows[rowIndex]) { item in
                        todayMetric(item)
                    }
                }
            }

            if sleep.fallbackAvailable || sleep.ready {
                todaySleepProof(sleep)
            }

            if savedWorkout.source != "none" || liveWorkout.samples > 1 {
                todayWorkoutProof(saved: savedWorkout, live: liveWorkout)
            }

            if gateETraining.hasConfirmedEvidence {
                todayGateETrainingProof(gateETraining)
            }

            HStack(spacing: 8) {
                Label(todayNextAction(recovery: recovery,
                                      hrvReady: hrvReady,
                                      rrReady: rrReadyForReference,
                                      loggingReady: loggingReady,
                                      savedWorkout: savedWorkout,
                                      gateETraining: gateETraining),
                      systemImage: "arrow.forward.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            logTodayGateETraining(gateETraining)
            NSLog("WHOOPDBG hrv_display state=%@ main_rmssd=%@ validated_sessions=%d rr_ready=%d rr_package_ready=%d rr_package_reason=%@ rr_package_raw=%d rr_package_kept=%d rr_package_conf=%d rr_package_gap_s=%.1f rr_package_rmssd=%@ reason=%@ metric_promotions=0 surface=today",
                  hrvReady ? "validated" : (rrReadyForReference ? "measured_reference_pending" : "learning"),
                  todayHRVValue(hrv, rrPackage: rrPackage),
                  store.sessions.compactMap(\.referenceValidatedHRV).filter { $0 > 0 }.count,
                  rrReadyForReference ? 1 : 0,
                  rrPackage.ready ? 1 : 0,
                  rrPackage.reason,
                  rrPackage.raw,
                  rrPackage.kept,
                  rrPackage.confidencePercent,
                  rrPackage.maxGapSeconds,
                  rrPackage.rmssd.map { String(format: "%.1f", $0) } ?? "learning",
                  hrvReady ? "external_rr_reference_validated" : (rrReadyForReference ? "external_rr_reference_required" : "insufficient_rr"))
            NSLog("WHOOPDBG today_usability connected=%d hr=%d strain=%.2f strain_confidence=%@ recovery=%@ recovery_confidence=%@ hrv_state=%@ rr_ready=%d sessions=%d checkpoint_armed=%d checkpoint_last_status=%@ checkpoint_last_samples=%d logging_ready=%d collection_ready=%d collection_source=%@ collection_blocker=%@ collection_samples=%d collection_rr_values=%d collection_age_s=%d collection_duration_s=%d collection_metric_promotions=0 battery_level=%d rr_package_ready=%d rr_package_reason=%@ rr_package_sessions=%d rr_package_samples=%d rr_package_raw=%d rr_package_kept=%d rr_package_conf=%d rr_package_gap_s=%.1f rr_package_rmssd=%@ sleep_value=%@ sleep_ready=%d sleep_state=%@ sleep_blocker=%@ sleep_candidates=%d sleep_fallback=%d sleep_fallback_source=%@ sleep_fallback_duration_s=%d sleep_fallback_span_s=%d sleep_motion_source=%@ sleep_motion_validated=%d backup_available=%d backup_current=%d backup_sessions=%d backup_rr_samples=%d backup_reason=%@ health_readback=%@ health_data_appears=%d health_atria_hr_samples=%d health_expected_hr_samples=%d reference_ready=%d reference_reason=%@ workout_value=%@ workout_source=%@ workout_ready=%d workout_strength_candidate=%d workout_near_miss=%d workout_blocker=%@ workout_peak_hr=%d workout_threshold_hr=%d workout_stream_coverage_percent=%d workout_duration_s=%d next_action=%@",
                  ble.status == .connected ? 1 : 0,
                  ble.heartRate,
                  strain.strain,
                  strain.confidence,
                  recovery.percent.map(String.init) ?? "learning",
                  recovery.confidence.rawValue,
                  hrvReady ? "validated" : (rrReadyForReference ? "measured_reference_pending" : "learning"),
                  rrReadyForReference ? 1 : 0,
                  sessionCount,
                  checkpointArmed ? 1 : 0,
                  checkpointLastStatus,
                  checkpointLastSamples,
                  loggingReady ? 1 : 0,
                  collection.ready ? 1 : 0,
                  collection.source,
                  collection.blocker,
                  collection.samples,
                  collection.rrValues,
                  collection.ageSeconds,
                  collection.durationSeconds,
                  ble.batteryLevel,
                  rrPackage.ready ? 1 : 0,
                  rrPackage.reason,
                  rrPackage.sessionsWithRR,
                  rrPackage.rrSamples,
                  rrPackage.raw,
                  rrPackage.kept,
                  rrPackage.confidencePercent,
                  rrPackage.maxGapSeconds,
                  rrPackage.rmssd.map { String(format: "%.1f", $0) } ?? "learning",
                  todaySleepValue(sleep),
                  sleep.ready ? 1 : 0,
                  sleep.state,
                  sleep.blocker,
                  sleep.candidates,
                  sleep.fallbackAvailable ? 1 : 0,
                  sleep.fallbackSource,
                  Int(sleep.fallbackDuration.rounded()),
                  Int(sleep.fallbackSpan.rounded()),
                  sleep.motionSource,
                  sleep.motionValidated ? 1 : 0,
                  backup.available ? 1 : 0,
                  backup.current ? 1 : 0,
                  backup.sessions,
                  backup.rrSamples,
                  backup.reason,
                  health.readback.status,
                  health.readback.dataAppears ? 1 : 0,
                  health.readback.readbackAtriaHRSamples,
                  health.readback.expectedTotalAtriaHRSamples,
                  health.referenceAudit.externalReferenceReady ? 1 : 0,
                  health.referenceAudit.validationReason,
                  todayWorkoutValue(saved: savedWorkout, live: liveWorkout),
                  savedWorkout.source,
                  savedWorkout.ready ? 1 : 0,
                  savedWorkout.strengthCandidate ? 1 : 0,
                  savedWorkout.nearMiss ? 1 : 0,
                  savedWorkout.primaryBlocker,
                  savedWorkout.peakHR,
                  savedWorkout.thresholdHR,
                  savedWorkout.streamCoveragePercent,
                  Int(savedWorkout.duration),
                  todayNextAction(recovery: recovery,
                                  hrvReady: hrvReady,
                                  rrReady: rrReadyForReference,
                                  loggingReady: loggingReady,
                                  savedWorkout: savedWorkout,
                                  gateETraining: gateETraining))
        }
        .onChange(of: ble.batteryLevel) { _, level in
            guard level >= 0 else { return }
            NSLog("WHOOPDBG today_usability_update reason=battery battery_level=%d rr_package_ready=%d rr_package_samples=%d rr_package_kept=%d rr_package_conf=%d rr_package_gap_s=%.1f rr_package_rmssd=%@",
                  level,
                  rrPackage.ready ? 1 : 0,
                  rrPackage.rrSamples,
                  rrPackage.kept,
                  rrPackage.confidencePercent,
                  rrPackage.maxGapSeconds,
                  rrPackage.rmssd.map { String(format: "%.1f", $0) } ?? "learning")
        }
        .onChange(of: ble.status) { _, status in
            guard status == .connected else { return }
            logTodaySettled(reason: "connected",
                            recovery: recovery,
                            hrvReady: hrvReady,
                            rrReady: rrReadyForReference,
                            loggingReady: loggingReady,
                            sleep: sleep,
                            savedWorkout: savedWorkout,
                            gateETraining: gateETraining,
                            backup: backup,
                            health: health)
        }
        .onChange(of: ble.heartRate) { oldValue, newValue in
            guard oldValue <= 0, newValue > 0 else { return }
            logTodaySettled(reason: "live_hr",
                            recovery: recovery,
                            hrvReady: hrvReady,
                            rrReady: rrReadyForReference,
                            loggingReady: loggingReady,
                            sleep: sleep,
                            savedWorkout: savedWorkout,
                            gateETraining: gateETraining,
                            backup: backup,
                            health: health)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                guard ble.status != .connected else { return }
                logTodaySettled(reason: "connection_waiting",
                                recovery: recovery,
                                hrvReady: hrvReady,
                                rrReady: rrReadyForReference,
                                loggingReady: loggingReady,
                                sleep: sleep,
                                savedWorkout: savedWorkout,
                                gateETraining: gateETraining,
                                backup: backup,
                                health: health)
            }
        }
    }

    private func logTodaySettled(reason: String,
                                 recovery: Metrics.RecoveryEstimate,
                                 hrvReady: Bool,
                                 rrReady: Bool,
                                 loggingReady: Bool,
                                 sleep: SleepEvidenceStatus,
                                 savedWorkout: SavedWorkoutAttemptStatus,
                                 gateETraining: GateETrainingSummary,
                                 backup: SessionBackupStatus,
                                 health: HealthKitExporter.Diagnostics) {
        let key = [
            reason,
            "\(ble.status == .connected ? 1 : 0)",
            "\(ble.heartRate)",
            todaySleepValue(sleep),
            "\(sleep.ready ? 1 : 0)",
            "\(savedWorkout.ready ? 1 : 0)",
            "\(backup.current ? 1 : 0)",
            "\(health.readback.dataAppears ? 1 : 0)"
        ].joined(separator: "|")
        guard key != lastTodaySettledLogKey else { return }
        lastTodaySettledLogKey = key
        let collection = store.currentCollectionStatus()
        NSLog("WHOOPDBG today_usability_update reason=%@ connected=%d hr=%d sleep_value=%@ sleep_ready=%d sleep_blocker=%@ workout_value=%@ workout_ready=%d collection_ready=%d collection_source=%@ collection_blocker=%@ collection_samples=%d collection_rr_values=%d collection_age_s=%d collection_duration_s=%d collection_metric_promotions=0 backup_current=%d health_data_appears=%d reference_ready=%d next_action=%@",
              reason,
              ble.status == .connected ? 1 : 0,
              ble.heartRate,
              todaySleepValue(sleep),
              sleep.ready ? 1 : 0,
              sleep.blocker,
              todayWorkoutValue(saved: savedWorkout, live: liveWorkoutStatus(rest: restForStrain, maxHR: store.profile.maxHR)),
              savedWorkout.ready ? 1 : 0,
              collection.ready ? 1 : 0,
              collection.source,
              collection.blocker,
              collection.samples,
              collection.rrValues,
              collection.ageSeconds,
              collection.durationSeconds,
              backup.current ? 1 : 0,
              health.readback.dataAppears ? 1 : 0,
              health.referenceAudit.externalReferenceReady ? 1 : 0,
              todayNextAction(recovery: recovery,
                              hrvReady: hrvReady,
                              rrReady: rrReady,
                              loggingReady: loggingReady,
                              savedWorkout: savedWorkout,
                              gateETraining: gateETraining))
    }

    private func todayMetric(_ title: String,
                             _ value: String,
                             _ detail: String,
                             _ system: String,
                             _ color: Color,
                             _ ready: Bool) -> some View {
        todayMetric(TodayMetricItem(title: title,
                                    value: value,
                                    detail: detail,
                                    system: system,
                                    color: color,
                                    ready: ready))
    }

    private func todayMetric(_ item: TodayMetricItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: item.system)
                    .foregroundStyle(item.ready ? item.color : .secondary)
                    .frame(width: 14)
                Text(item.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(item.value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(item.detail.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hrvDetail(_ snapshot: HRVSnapshot?, rrPackage: RRPackageStatus) -> String {
        if store.latestReferenceValidatedHRV != nil {
            if let snapshot {
                return "\(snapshot.confidencePercent)% kept"
            }
            if rrPackage.ready {
                return "\(rrPackage.confidencePercent)% kept"
            }
            return "validated"
        }
        if rrPackage.ready {
            return "not ref checked"
        }
        guard let snapshot else { return ble.hrvQuality }
        if snapshot.isReady {
            return "not ref checked"
        }
        return snapshot.readinessMessage
    }

    private func todayHRVValue(_ snapshot: HRVSnapshot?, rrPackage: RRPackageStatus) -> String {
        if let validated = store.latestReferenceValidatedHRV {
            return "\(validated)"
        }
        if rrPackage.ready, let measured = rrPackage.rmssd {
            return "\(Int(measured.rounded()))"
        }
        if let snapshot, snapshot.isReady {
            return "\(Int(snapshot.rmssd.rounded()))"
        }
        return "learning"
    }

    private func todayRRPackageValue(_ status: RRPackageStatus) -> String {
        if store.latestReferenceValidatedHRV != nil { return "validated" }
        if status.ready { return "ready" }
        if status.rrSamples > 0 { return "\(status.rrSamples)" }
        return "learning"
    }

    private func todayRRPackageDetail(_ status: RRPackageStatus) -> String {
        if store.latestReferenceValidatedHRV != nil { return "HRV unlocked" }
        if status.ready {
            return "\(status.confidencePercent)% kept"
        }
        if status.rrSamples > 0 {
            return status.reason.replacingOccurrences(of: "_", with: " ")
        }
        return "no RR saved"
    }

    private func todaySleepValue(_ status: SleepEvidenceStatus) -> String {
        if status.ready { return "ready" }
        if status.fallbackAvailable { return "candidate" }
        if status.candidates > 0 { return "\(status.candidates)" }
        return "learning"
    }

    private func todaySleepDetail(_ status: SleepEvidenceStatus) -> String {
        if status.ready {
            return status.confidence
        }
        if status.fallbackAvailable {
            return "\(formatMinutes(status.fallbackDuration)) saved"
        }
        if status.candidates > 0 {
            return status.blocker.replacingOccurrences(of: "_", with: " ")
        }
        return "no window"
    }

    private func todayCollectionDetail(_ status: CurrentCollectionStatus, fallback: String) -> String {
        guard status.ready else { return fallback }
        let source = status.source == "saved_session_tail" ? "saved" : "live"
        return "\(source) \(status.samples) · \(status.ageSeconds)s"
    }

    private func todaySleepProof(_ status: SleepEvidenceStatus) -> some View {
        let color: Color = status.ready ? .green : .orange
        let title = status.ready ? "Sleep detected" : "Sleep candidate saved"
        let motion = status.motionValidated
            ? status.motionSource.replacingOccurrences(of: "_", with: " ")
            : "motion not validated"
        let duration = formatMinutes(status.fallbackDuration)
        let span = formatMinutes(status.fallbackSpan)
        let detail = status.ready
            ? "\(status.confidence) · \(motion)"
            : "\(duration) over \(span) · \(motion) · \(status.blocker.replacingOccurrences(of: "_", with: " "))"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.ready ? "checkmark.circle.fill" : "moon.zzz.fill")
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes >= 60 {
            return "\(minutes / 60)h\(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    private func todayBackupValue(_ status: SessionBackupStatus) -> String {
        if status.current { return "ready" }
        if status.available { return "stale" }
        return "missing"
    }

    private func todayBackupDetail(_ status: SessionBackupStatus) -> String {
        if status.current {
            return "\(status.sessions) sessions"
        }
        if status.available {
            return status.reason.replacingOccurrences(of: "_", with: " ")
        }
        return "not saved"
    }

    private func todayHealthValue(_ status: HealthKitExporter.Diagnostics) -> String {
        if status.readback.dataAppears { return "synced" }
        if status.planned.hrSamples > 0 { return "\(status.planned.hrSamples)" }
        return "learning"
    }

    private func todayHealthDetail(_ status: HealthKitExporter.Diagnostics) -> String {
        if status.readback.dataAppears {
            return "\(status.readback.readbackAtriaHRSamples) HR"
        }
        if !status.entitlementPresent { return "entitlement" }
        if !status.healthDataAvailable { return "unavailable" }
        if status.planned.hrSamples > 0 { return "not read back" }
        return "no HR yet"
    }

    private func todayReferenceValue(_ status: HealthKitExporter.Diagnostics) -> String {
        if status.referenceAudit.externalReferenceReady { return "ready" }
        if status.referenceAudit.independentHRSamples > 0 {
            return "\(status.referenceAudit.independentHRSamples)"
        }
        return "missing"
    }

    private func todayReferenceDetail(_ status: HealthKitExporter.Diagnostics) -> String {
        if status.referenceAudit.externalReferenceReady {
            return "\(status.referenceAudit.validationPairs) pairs"
        }
        if status.referenceAudit.status == "ok" {
            return status.referenceAudit.validationReason.replacingOccurrences(of: "_", with: " ")
        }
        return status.referenceAudit.status.replacingOccurrences(of: "_", with: " ")
    }

    private func todayLoggingDetail(armed: Bool, lastStatus: String, lastSamples: Int) -> String {
        if lastStatus == "saved" {
            return "\(lastSamples) samples"
        }
        if armed {
            return "checkpoints"
        }
        return ble.longWearModeEnabled ? "long wear" : "manual"
    }

    private func todayHeadline(recovery: Metrics.RecoveryEstimate,
                               hrvReady: Bool,
                               rrReady: Bool) -> String {
        if recovery.percent != nil {
            return "Recovery is validated; strain and logging are active."
        }
        if hrvReady {
            return "HRV is validated; recovery baseline is still maturing."
        }
        if rrReady {
            return ble.status == .connected
                ? "Clean RR is saved; HRV needs an external reference."
                : "Reconnecting; clean RR is saved and marked unreferenced."
        }
        if ble.status != .connected {
            return "Reconnecting to strap; saved data stays on device."
        }
        return "Live HR and strain are usable; recovery and HRV stay learning."
    }

    private func todayWorkoutValue(saved: SavedWorkoutAttemptStatus,
                                   live: LiveWorkoutStatus) -> String {
        if saved.ready || live.ready { return "ready" }
        if saved.strengthCandidate { return "strength" }
        if saved.nearMiss { return "near miss" }
        if saved.source != "none" { return "\(saved.peakHR)" }
        if live.samples > 1 { return "\(live.peakHR)" }
        return "learning"
    }

    private func todayWorkoutDetail(saved: SavedWorkoutAttemptStatus,
                                    live: LiveWorkoutStatus) -> String {
        if saved.ready || live.ready { return "detected" }
        if saved.strengthCandidate { return "not counted" }
        if saved.nearMiss { return "close" }
        if saved.source != "none" {
            return saved.captureDiagnosis.replacingOccurrences(of: "_", with: " ")
        }
        if live.samples > 1 {
            return "\(live.streamCoveragePercent)% stream"
        }
        return "waiting"
    }

    private func todayWorkoutProof(saved: SavedWorkoutAttemptStatus,
                                   live: LiveWorkoutStatus) -> some View {
        let showingSaved = saved.source != "none"
        let title = showingSaved ? savedWorkoutStateTitle(saved) : "Live workout"
        let detail = showingSaved
            ? savedWorkoutCompactDetail(saved)
            : "Live \(Int(live.duration / 60))m · HR \(live.avgHR)/\(live.peakHR) · >=\(live.thresholdHR) \(Int(live.elevatedSeconds))/\(Int(live.requiredElevatedSeconds))s"
        let color: Color = (saved.ready || live.ready) ? .green : (saved.strengthCandidate || saved.nearMiss ? .orange : .secondary)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: (saved.ready || live.ready) ? "checkmark.circle.fill" : "scope")
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func todayGateETrainingProof(_ summary: GateETrainingSummary) -> some View {
        let workout = summary.workout
        let sleep = summary.sleep
        let workoutDetail = workout.present
            ? "workout \(summary.compactWorkoutBlocker.replacingOccurrences(of: "_", with: " ")) · \(summary.workoutProofStatus.replacingOccurrences(of: "_", with: " "))"
            : "workout not confirmed"
        let sleepDetail = sleep.present
            ? "sleep \(summary.compactSleepBlocker.replacingOccurrences(of: "_", with: " ")) · \(summary.sleepProofStatus.replacingOccurrences(of: "_", with: " "))"
            : "sleep not confirmed"
        let color: Color = summary.autoReady ? .green : .orange
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: summary.autoReady ? "checkmark.seal.fill" : "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.autoReady ? "Confirmed examples auto-ready" : "Confirmed examples are training")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text("\(workoutDetail) · \(sleepDetail)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                if workout.present && !workout.autoReady {
                    VStack(alignment: .leading, spacing: 2) {
                        workoutProofRow("Coverage", value: "\(workout.streamCoveragePercent)/\(summary.workoutCoverageTargetPercent)%", ready: workout.streamCoveragePercent >= summary.workoutCoverageTargetPercent)
                        workoutProofRow("Observed", value: "\(formatProofSeconds(summary.workoutObservedSeconds))/\(formatProofSeconds(summary.workoutObservedTargetSeconds))", ready: summary.workoutObservedMissingSeconds == 0)
                        workoutProofRow("Elevated", value: "\(formatProofSeconds(summary.workoutElevatedSeconds))/\(formatProofSeconds(summary.workoutElevatedTargetSeconds))", ready: summary.workoutElevatedMissingSeconds == 0)
                        workoutProofRow("Bout", value: "\(formatProofSeconds(summary.workoutBoutSeconds))/\(formatProofSeconds(summary.workoutBoutTargetSeconds))", ready: summary.workoutBoutMissingSeconds == 0)
                        workoutProofRow("Peak", value: summary.workoutThresholdProgress, ready: workout.thresholdGapBPM == 0)
                        workoutProofRow("P95", value: "\(workout.p95HR)/\(workout.thresholdHR)bpm", ready: summary.workoutP95GapBPM == 0)
                    }
                    .padding(.top, 2)
                    Text(summary.workoutIntensityProof.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text(summary.workoutProfileSensitivityProof.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                    Text(summary.workoutProofNextStep.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func workoutProofRow(_ label: String, value: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(ready ? .green : .secondary)
                .frame(width: 12)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(ready ? .primary : .secondary)
            Spacer(minLength: 0)
        }
    }

    private func formatProofSeconds(_ seconds: Int) -> String {
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m\(remainder)s"
        }
        return "\(seconds)s"
    }

    private func logTodayGateETraining(_ summary: GateETrainingSummary) {
        let key = "\(summary.workout.present)|\(summary.workout.autoReady)|\(summary.compactWorkoutBlocker)|\(summary.workoutProofNeeded)|\(summary.workoutProofStatus)|\(summary.workoutIntensityProof)|\(summary.workoutProfileSensitivityProof)|\(summary.workoutProofProgress)|\(summary.workoutProofNextStep)|\(summary.workoutCoverageMissingPercent)|\(summary.workoutObservedMissingSeconds)|\(summary.workoutP95GapBPM)|\(summary.workoutPeakGapBPM)|\(summary.workoutElevatedMissingSeconds)|\(summary.workoutBoutMissingSeconds)|\(summary.sleep.present)|\(summary.sleep.autoReady)|\(summary.compactSleepBlocker)|\(summary.sleepProofNeeded)|\(summary.sleepProofStatus)|\(summary.sleep.fallbackAccepted)|\(summary.sleep.motionValidated)|\(summary.nextProof)"
        guard key != lastTodayGateETrainingLogKey else { return }
        lastTodayGateETrainingLogKey = key
        NSLog("WHOOPDBG today_gate_e_training confirmed_workout=%d workout_auto_ready=%d workout_blocker=%@ workout_proof=%@ workout_proof_status=%@ workout_intensity_proof=%@ workout_profile_proof=%@ workout_progress=%@ workout_next_step=%@ workout_stream_coverage_percent=%d workout_required_coverage_percent=%d workout_missing_coverage_percent=%d workout_observed_s=%d workout_required_observed_s=%d workout_missing_observed_s=%d workout_peak_hr=%d workout_p95_hr=%d workout_p99_hr=%d workout_p95_gap_bpm=%d workout_peak_gap_bpm=%d workout_threshold_hr=%d workout_profile_max_hr=%d workout_required_profile_max_hr_for_p95_hrr50=%d workout_profile_max_lowering_for_p95_bpm=%d workout_elevated_s=%d workout_required_elevated_s=%d workout_missing_elevated_s=%d workout_bout_s=%d workout_required_bout_s=%d workout_missing_bout_s=%d workout_ready_if=%@ confirmed_sleep=%d sleep_auto_ready=%d sleep_blocker=%@ sleep_proof=%@ sleep_proof_status=%@ sleep_fallback_accepted=%d sleep_fallback_policy=%@ sleep_motion_validated=%d auto_detection_required=%d blocker=%@ next_proof=%@",
              summary.workout.present ? 1 : 0,
              summary.workout.autoReady ? 1 : 0,
              summary.compactWorkoutBlocker,
              summary.workoutProofNeeded,
              summary.workoutProofStatus,
              summary.workoutIntensityProof,
              summary.workoutProfileSensitivityProof,
              summary.workoutProofProgress,
              summary.workoutProofNextStep,
              summary.workout.streamCoveragePercent,
              summary.workoutCoverageTargetPercent,
              summary.workoutCoverageMissingPercent,
              summary.workoutObservedSeconds,
              summary.workoutObservedTargetSeconds,
              summary.workoutObservedMissingSeconds,
              summary.workout.peakHR,
              summary.workout.p95HR,
              summary.workout.p99HR,
              summary.workoutP95GapBPM,
              summary.workoutPeakGapBPM,
              summary.workout.thresholdHR,
              summary.workout.profileMaxHR,
              summary.workout.requiredProfileMaxHRForP95AtHRR50,
              summary.workoutProfileMaxLoweringForP95BPM,
              summary.workoutElevatedSeconds,
              summary.workoutElevatedTargetSeconds,
              summary.workoutElevatedMissingSeconds,
              summary.workoutBoutSeconds,
              summary.workoutBoutTargetSeconds,
              summary.workoutBoutMissingSeconds,
              summary.workoutProofReadyIf,
              summary.sleep.present ? 1 : 0,
              summary.sleep.autoReady ? 1 : 0,
              summary.compactSleepBlocker,
              summary.sleepProofNeeded,
              summary.sleepProofStatus,
              summary.sleep.fallbackAccepted ? 1 : 0,
              summary.sleep.fallbackPolicy,
              summary.sleep.motionValidated ? 1 : 0,
              summary.autoReady ? 0 : 1,
              summary.primaryBlocker,
              summary.nextProof)
    }

    private func savedWorkoutStateTitle(_ workout: SavedWorkoutAttemptStatus) -> String {
        if workout.ready { return "Saved workout detected" }
        if workout.strengthCandidate { return "Strength-like signal saved" }
        if workout.nearMiss { return "Workout near miss saved" }
        return "Saved activity reviewed"
    }

    private func savedWorkoutCompactDetail(_ workout: SavedWorkoutAttemptStatus) -> String {
        let minutes = Int(workout.duration / 60)
        let elevated = Int(workout.elevatedSeconds)
        let needed = Int(workout.requiredElevatedSeconds)
        let stream = workout.streamCoveragePercent
        let reason = workout.captureDiagnosis.replacingOccurrences(of: "_", with: " ")
        return "\(minutes)m · HR p95/p99 \(workout.p95HR)/\(workout.p99HR) peak \(workout.peakHR) · >=\(workout.thresholdHR) \(elevated)/\(needed)s · stream \(stream)% · \(reason)"
    }

    private func todayNextAction(recovery: Metrics.RecoveryEstimate,
                                 hrvReady: Bool,
                                 rrReady: Bool,
                                 loggingReady: Bool,
                                 savedWorkout: SavedWorkoutAttemptStatus,
                                 gateETraining: GateETrainingSummary) -> String {
        if gateETraining.workout.present
            && !gateETraining.workout.autoReady
            && gateETraining.workoutProofNeeded == "capture_clean_hrr50_or_validate_received_hr" {
            return "Keep phone near strap and validate received HR intensity before counting workouts."
        }
        if ble.status != .connected {
            return "Keep the phone near the strap until Atria reconnects."
        }
        if savedWorkout.strengthCandidate {
            return "Strength signal saved; Atria will not count it as workout until HR evidence is stronger."
        }
        if savedWorkout.nearMiss {
            return "Workout evidence is close; keep collecting clean high-HR sessions."
        }
        if recovery.percent == nil && rrReady && !hrvReady {
            return "Add independent RR reference to unlock validated HRV."
        }
        if !loggingReady {
            return "Keep Atria open so local checkpoints can arm."
        }
        return "Keep wearing; Atria is logging locally."
    }

    private var diagnosticsWarmupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Diagnostics", systemImage: "bolt.heart")
                    .font(.headline)
                Spacer()
                Text("warming")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("Saved replay pending")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var localStatusCard: some View {
        let status = localStatus
        let sleepReady = status.sleepState == "ready" || status.sleepState == "validated"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Local status", systemImage: "checklist.checked")
                    .font(.headline)
                Spacer()
                Text("\(store.sessions.count) sessions")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                statusTile(title: "Sleep",
                           value: status.sleepDays > 0 ? "\(status.sleepDays)d" : (status.sleepCandidateDays > 0 ? "candidate" : "learning"),
                           detail: status.sleepState,
                           system: "bed.double.fill",
                           isReady: sleepReady)
                statusTile(title: "Workout",
                           value: status.workoutDays > 0 ? "\(status.workoutDays)d" : (status.confirmedWorkoutDays > 0 ? "confirmed" : "learning"),
                           detail: status.workoutState,
                           system: "figure.run",
                           isReady: status.workoutDays > 0 || status.confirmedWorkoutDays > 0)
                statusTile(title: "HRV",
                           value: status.validatedHRVSessions > 0 ? "\(status.validatedHRVSessions)" : "pending",
                           detail: status.hrvState,
                           system: "waveform.path.ecg",
                           isReady: status.validatedHRVSessions > 0)
                statusTile(title: "Trends",
                           value: "\(status.trendCoveragePercent)%",
                           detail: status.trendState,
                           system: "chart.line.uptrend.xyaxis",
                           isReady: status.trendState == "ready" || status.trendState == "partial")
                statusTile(title: "Logging",
                           value: status.checkpointArmed ? "armed" : "learning",
                           detail: checkpointDetail(status),
                           system: "externaldrive.fill.badge.checkmark",
                           isReady: status.checkpointArmed && status.checkpointLastStatus == "saved")
            }
            Text("Recovery \(status.recoveryState) · HRV baseline \(status.hrvBaselineSamples)/7 · motion \(status.motionSource.replacingOccurrences(of: "_", with: " "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(workoutAttemptDetail(status.liveWorkout))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(status.liveWorkout.ready ? .green : .secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(savedWorkoutAttemptDetail(status.savedWorkout))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(status.savedWorkout.ready ? .green : (status.savedWorkout.nearMiss ? .orange : .secondary))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            hrReferenceProofCard(status)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Gate readiness")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(gateReadinessRows(for: status)) { row in
                    gateReadinessRow(row)
                }
            }
            Toggle(isOn: Binding(get: {
                ble.standardHROnlyEnabled
            }, set: { enabled in
                ble.setStandardHROnlyEnabled(enabled)
                logLocalStatusIfWarm()
            })) {
                Label("Low radio HR", systemImage: "dot.radiowaves.left.and.right")
            }
            .font(.caption)
            .tint(.green)
            Toggle(isOn: Binding(get: {
                ble.longWearModeEnabled
            }, set: { enabled in
                ble.setLongWearModeEnabled(enabled,
                                           rest: store.baseline.restingInt ?? restForStrain,
                                           maxHR: store.profile.maxHR)
                logLocalStatusIfWarm()
            })) {
                Label("Long wear", systemImage: "record.circle")
            }
            .font(.caption)
            .tint(.blue)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var trendPreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Trends", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Text("7/30/90")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            TrendSummaryView(summaries: dashboardTrends)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var strainValidationCard: some View {
        let summary = strainValidationStatus
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Strain validation", systemImage: "figure.run.circle")
                    .font(.headline)
                Spacer()
                Text(summary.ready ? "ready" : "learning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.ready ? .green : .orange)
            }
            HStack(spacing: 10) {
                strainValidationMetric("Strain", String(format: "%.1f", summary.strain))
                strainValidationMetric("TRIMP", String(format: "%.1f", summary.trimp))
                strainValidationMetric("Max HRR", "\(Int((summary.maxHRReserve * 100).rounded()))%")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                strainCriterion("duration \(Int(summary.totalSeconds))/600s", good: summary.totalSeconds >= 600)
                strainCriterion("stream \(summary.streamCoveragePercent)%", good: summary.streamCoveragePercent >= 75)
                strainCriterion("rest z0 \(Int(summary.secondsZ0))/60s", good: summary.secondsZ0 >= 60)
                strainCriterion("high \(Int(summary.highZoneSeconds))/60s", good: summary.highZoneSeconds >= 60)
                strainCriterion("max HRR \(Int((summary.maxHRReserve * 100).rounded()))/85%", good: summary.maxHRReserve >= 0.85)
                strainCriterion("external HR", good: summary.externalHRReferenceValidated)
            }
            Text(summary.primaryBlocker.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func strainValidationMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func strainCriterion(_ text: String, good: Bool) -> some View {
        Label(text, systemImage: good ? "checkmark.circle.fill" : "clock")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(good ? .green : .orange)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private func workoutAttemptDetail(_ workout: LiveWorkoutStatus) -> String {
        let duration = Int(workout.duration)
        let observed = Int(workout.observedDuration)
        let gaps = workout.gapCount > 0 ? " · gap \(Int(workout.droppedGapSeconds))s/\(String(format: "%.0f", workout.maxSampleGap))s" : ""
        return "Workout \(workout.reason) · \(duration/60)m\(duration%60)s obs \(observed)s\(gaps) · HR \(workout.avgHR)/\(workout.peakHR) · >=\(workout.thresholdHR) \(Int(workout.elevatedSeconds))/\(Int(workout.requiredElevatedSeconds))s · bout \(Int(workout.longestBout))/\(Int(workout.requiredBout))s"
    }

    private func savedWorkoutAttemptDetail(_ workout: SavedWorkoutAttemptStatus) -> String {
        if workout.source == "none" {
            return "Saved workout learning · no saved attempt"
        }
        let duration = Int(workout.duration)
        let observed = Int(workout.observedDuration)
        let state = workout.ready ? "ready" : (workout.strengthCandidate ? "strength candidate" : (workout.nearMiss ? "near miss" : "learning"))
        let gaps = workout.gapCount > 0 ? " · gap \(Int(workout.droppedGapSeconds))s/\(String(format: "%.0f", workout.maxSampleGap))s x\(workout.gapCount)" : ""
        let distribution = workout.hrDistributionBelowWorkoutBand ? " · HR distribution below band" : ""
        return "Saved workout \(state) · \(workout.captureAction) · \(workout.captureDiagnosis)\(distribution) · \(workout.source) \(workout.chunks)x · \(duration/60)m obs \(observed)s\(gaps) · HR p95/p99 \(workout.p95HR)/\(workout.p99HR) peak \(workout.peakHR) >=\(workout.thresholdHR) \(workout.samplesAboveThreshold)x · \(Int(workout.elevatedSeconds))/\(Int(workout.requiredElevatedSeconds))s bout \(Int(workout.longestBout))/\(Int(workout.requiredBout))s · >=\(workout.borderlineThresholdHR) \(workout.samplesAboveBorderline)x"
    }

    private func hrReferenceUIStatus(for status: LocalStatus) -> HRReferenceUIStatus {
        let health = HealthKitExporter.diagnostics(for: store.sessions,
                                                   rest: store.baseline.restingInt ?? restForStrain,
                                                   maxHR: store.profile.maxHR,
                                                   confirmedWorkouts: store.confirmedWorkouts,
                                                   confirmedSleeps: store.confirmedSleeps)
        let audit = health.referenceAudit
        let csv = store.csvHRReferenceDiagnostics
        let csvReady = store.externalHRReferenceValidated
        let healthReady = audit.externalReferenceReady
        let state: String
        if csvReady {
            state = "csv_ready"
        } else if healthReady {
            state = "healthkit_ready"
        } else if audit.independentHRSamples > 0 {
            state = "independent_hr_not_validated"
        } else if audit.atriaHRSamples > 0 {
            state = "missing_independent_hr"
        } else {
            state = "not_run"
        }
        return HRReferenceUIStatus(state: state,
                                   reason: audit.validationReason,
                                   totalHealthKitHRSamples: audit.totalHRSamples,
                                   atriaHRSamples: audit.atriaHRSamples,
                                   independentHRSamples: audit.independentHRSamples,
                                   independentSources: audit.independentSources,
                                   pairs: audit.validationPairs,
                                   meanDelta: audit.validationMeanDelta,
                                   maxDelta: audit.validationMaxDelta,
                                   csvStatus: csv.status,
                                   csvReason: csv.reason,
                                   csvPairs: csv.pairs,
                                   csvReferenceSamples: csv.referenceSamples,
                                   csvMeanDelta: csv.meanDelta,
                                   csvMedianDelta: csv.medianDelta,
                                   csvMaxDelta: csv.maxDelta,
                                   csvWithinTolerancePercent: csv.withinTolerancePercent,
                                   csvValidated: csvReady,
                                   healthKitValidated: healthReady,
                                   savedWorkout: status.savedWorkout)
    }

    private func hrReferenceProofCard(_ status: LocalStatus) -> some View {
        let reference = hrReferenceUIStatus(for: status)
        let workout = reference.savedWorkout
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("HR reference", systemImage: reference.isReady ? "checkmark.seal.fill" : "cross.case")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reference.isReady ? .green : .orange)
                Spacer()
                Text(reference.state.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(reference.isReady ? .green : .orange)
            }
            HStack(spacing: 8) {
                referenceMetric("Atria", "\(reference.atriaHRSamples)")
                referenceMetric("External", "\(reference.independentHRSamples)")
                referenceMetric("Pairs", "\(reference.pairs)")
            }
            Text("Workout p95/p99 \(workout.p95HR)/\(workout.p99HR) · threshold \(workout.thresholdHR) · >=threshold \(workout.samplesAboveThreshold)x · elevated \(Int(workout.elevatedSeconds))/\(Int(workout.requiredElevatedSeconds))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text("Compare: \(workout.hrComparisonNeed.replacingOccurrences(of: "_", with: " ")) · p99 \(workout.p99HRRPercent)% HRR · p99 maxHR need \(workout.requiredProfileMaxHRForP99AtHRR50) · gap \(workout.currentProfileMinusP99RequiredBPM)bpm")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
            Text(reference.reason.replacingOccurrences(of: "_", with: " "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(spacing: 8) {
                Button {
                    hrReferenceShareURL = store.exportHRReferencePackageForUI()
                    hrReferenceImportStatus = hrReferenceShareURL == nil ? "Export unavailable" : "Export ready"
                    logLocalStatusIfWarm()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showHRReferenceImporter = true
                } label: {
                    Label("Import", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(reference.isReady ? .green : .orange)
            }
            if let url = hrReferenceShareURL {
                ShareLink(item: url) {
                    Label("Share HR package", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if !hrReferenceImportStatus.isEmpty {
                Text(hrReferenceImportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func referenceMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkpointDetail(_ status: LocalStatus) -> String {
        if status.checkpointLastStatus == "saved" {
            return "\(status.checkpointLastSamples) samples / \(status.checkpointLastDuration)s"
        }
        if status.checkpointArmed {
            return "\(status.checkpointInterval)s \(status.checkpointSource)"
        }
        return "not armed"
    }

    private func gateReadinessRows(for status: LocalStatus) -> [GateReadiness] {
        let health = HealthKitExporter.diagnostics(for: store.sessions,
                                                   rest: store.baseline.restingInt ?? restForStrain,
                                                   maxHR: store.profile.maxHR,
                                                   confirmedWorkouts: store.confirmedWorkouts,
                                                   confirmedSleeps: store.confirmedSleeps)
        let widget = WidgetSnapshotPublisher.diagnostics
        let archive = HistoricalArchive.diagnostics()
        let healthHRVReady = status.validatedHRVSessions > 0 && health.planned.hrvSamples > 0
        let healthWorkoutReady = health.planned.workouts > 0
        let gateGPlatformBlockers = [
            health.entitlementPresent ? nil : "healthkit_entitlement",
            health.healthDataAvailable ? nil : "healthkit_unavailable",
            health.planned.hrSamples > 0 ? nil : "healthkit_hr_missing",
            health.readback.dataAppears ? nil : "healthkit_hr_readback_missing",
            widget.widgetTargetPresent ? nil : "widget_target",
            widget.appGroupEnabled ? nil : "app_group",
            widget.complicationTargetPresent ? nil : "complication_target"
        ].compactMap { $0 }
        let gateGMetricBlockers = [
            health.readback.overfilledTotalAtriaHRSamples > 0 ? "healthkit_hr_overfilled:\(health.readback.overfilledTotalAtriaHRSamples)" : nil,
            health.readback.expectedTotalAtriaHRSamples <= 0 || health.readback.expectedTotalCovered ? nil : "healthkit_hr_backfill_pending:\(health.readback.missingTotalAtriaHRSamples)",
            healthHRVReady ? nil : (status.validatedHRVSessions > 0 ? "healthkit_hrv_missing" : "healthkit_hrv_reference_pending"),
            healthWorkoutReady ? nil : "healthkit_workout_learning"
        ].compactMap { $0 }
        let gateGPlatformReady = gateGPlatformBlockers.isEmpty
        let gateGStatus = gateGPlatformReady
            ? (gateGMetricBlockers.isEmpty ? "ready" : "metric_gated")
            : "partial"
        let gateGBlocker = gateGStatus == "ready"
            ? "none"
            : (gateGPlatformReady
            ? "platform_ready_metric_blockers:\(gateGMetricBlockers.joined(separator: "+"))"
            : "platform_blockers:\(gateGPlatformBlockers.joined(separator: "+"))")
        let healthReference = health.referenceAudit
        let strainSummary = store.strainValidationStatus(rest: store.baseline.restingInt ?? restForStrain,
                                                         maxHR: store.profile.maxHR)
        let externalHRReferenceReady = healthReference.externalReferenceReady || store.externalHRReferenceValidated
        let gateDBlocker = strainSummary.ready
            ? "none"
            : (externalHRReferenceReady
            ? strainSummary.primaryBlocker
            : (healthReference.status == "ok" ? healthReference.validationReason : "healthkit_reference_\(healthReference.status)")
            )
        let gateETraining = store.gateETrainingSummary(rest: store.baseline.restingInt ?? restForStrain,
                                                       maxHR: store.profile.maxHR)
        let sleepEvidenceReady = status.sleepState == "ready" || status.sleepState == "validated"
        let strictGateEReady = sleepEvidenceReady && status.savedWorkout.ready
        let gateEReady = gateETraining.hasConfirmedEvidence ? gateETraining.autoReady : strictGateEReady
        let gateEStatus: String
        let gateEBlocker: String
        if gateEReady {
            gateEStatus = "ready"
            gateEBlocker = "none"
        } else if gateETraining.hasConfirmedEvidence {
            gateEStatus = "user_confirmed"
            gateEBlocker = "auto_detection_required:\(gateETraining.nextProof)"
        } else if !sleepEvidenceReady && !status.savedWorkout.ready {
            gateEStatus = "partial"
            let sleepBlocker = status.sleepCandidateDays > 0 ? status.sleepBlocker : "sleep_learning"
            if status.savedWorkout.nearMiss {
                gateEBlocker = "\(sleepBlocker)+near_miss_\(status.savedWorkout.primaryBlocker)"
            } else {
                gateEBlocker = "\(sleepBlocker)+\(status.liveWorkout.primaryBlocker)"
            }
        } else if !sleepEvidenceReady {
            gateEStatus = "partial"
            gateEBlocker = status.sleepCandidateDays > 0 ? status.sleepBlocker : "sleep_learning"
        } else if status.savedWorkout.nearMiss {
            gateEStatus = "partial"
            gateEBlocker = "near_miss_\(status.savedWorkout.primaryBlocker)"
        } else {
            gateEStatus = "partial"
            gateEBlocker = status.liveWorkout.primaryBlocker
        }
        let gateHProtocolReady = archive.exists
            && archive.parseOK
            && archive.rows > 0
            && archive.rawPayloadRows > 0
            && archive.undecodableRows == 0
        let gateHMetricReady = gateHProtocolReady
            && archive.metricUsableRows > 0
            && archive.currentSessionUsableRows > 0
        let gateHBlocker: String
        if gateHMetricReady {
            gateHBlocker = "protocol_and_metrics_ready"
        } else if gateHProtocolReady {
            gateHBlocker = "protocol_ready_metrics_fail_closed_current_usable_\(archive.currentSessionUsableRows)_metric_usable_\(archive.metricUsableRows)"
        } else if archive.exists && archive.parseOK && archive.rows > 0 {
            gateHBlocker = "archive_fail_closed_current_usable_\(archive.currentSessionUsableRows)_metric_usable_\(archive.metricUsableRows)"
        } else {
            gateHBlocker = archive.reason
        }

        return [
            GateReadiness(gate: "A", title: "Realtime", status: "runtime", blocker: "verify_live_ble_each_launch"),
            GateReadiness(gate: "B", title: "HRV", status: status.validatedHRVSessions > 0 ? "reference_partial" : "reference_pending", blocker: "external_rr_reference"),
            GateReadiness(gate: "C", title: "Recovery", status: status.recoveryState == "ready" ? "ready" : "learning", blocker: "validated_hrv_baseline_\(status.hrvBaselineSamples)_of_7"),
            GateReadiness(gate: "D", title: "Strain", status: strainSummary.ready ? "ready" : "partial", blocker: gateDBlocker),
            GateReadiness(gate: "E", title: "Sleep/workout", status: gateEStatus, blocker: gateEBlocker),
            GateReadiness(gate: "F", title: "Trends", status: status.trendState, blocker: "coverage_\(status.trendCoveragePercent)pct_hrv_gated"),
            GateReadiness(gate: "G", title: "Platform", status: gateGStatus, blocker: gateGBlocker),
            GateReadiness(gate: "H", title: "Protocol", status: gateHProtocolReady ? "ready" : "partial", blocker: gateHBlocker)
        ]
    }

    private func gateReadinessRow(_ row: GateReadiness) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.gate)
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(row.isReady ? Color.green : Color.orange, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                    Text(row.status.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(row.isReady ? .green : .orange)
                }
                Text(row.blocker.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusTile(title: String, value: String, detail: String, system: String, isReady: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system)
                .foregroundStyle(isReady ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 58)
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private var heartRateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: ble.heartRate > 0)
            Text(ble.heartRate > 0 ? "\(ble.heartRate)" : "—")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(ble.status == .connected && !ble.hasContact && ble.heartRate == 0
                 ? "no skin contact" : "BPM")
                .font(.caption).foregroundStyle(ble.hasContact || ble.heartRate > 0 ? Color.secondary : Color.orange)

            ZoneBar(current: HRZone.zone(for: ble.heartRate, maxHR: store.profile.maxHR)).padding(.top, 6)

            if ble.session.count > 1 {
                HRChart(samples: ble.session, maxHR: store.profile.maxHR).padding(.top, 4)
            } else {
                Sparkline(values: ble.lastHeartRates).frame(height: 44).padding(.top, 4)
            }

            HStack(spacing: 0) {
                hrStat("Resting", ble.restingHR)
                hrStat("Average", ble.avgHR)
                hrStat("Peak", ble.peakHR)
            }
            .padding(.top, 8)

            if ble.session.count > 1 {
                VStack(spacing: 8) {
                    Button {
                        saveManualCheckpoint()
                    } label: {
                        Label("Save checkpoint", systemImage: "tray.and.arrow.down.fill")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if let s = ble.finishSession(label: ble.captureLabel) {
                            if store.add(s) {
                                ble.clearFinishedSessionJournal(after: s, reason: "manual_finish")
                                ble.captureLabel = ""
                                manualCheckpointStatus = ""
                            }
                        }
                    } label: {
                        Label("Finish & save session", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if !manualCheckpointStatus.isEmpty {
                        Text(manualCheckpointStatus)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func saveManualCheckpoint() {
        let label = ble.captureLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Manual checkpoint"
            : ble.captureLabel
        guard let saved = ble.snapshotSession(label: label) else {
            manualCheckpointStatus = "checkpoint skipped"
            NSLog("WHOOPDBG manual_checkpoint status=skipped reason=snapshot_failed samples=%d label=%@",
                  ble.session.count,
                  label)
            return
        }
        let persisted = store.checkpoint(saved)
        ble.flushActiveSessionJournal(reason: "manual_checkpoint")
        let status = persisted ? "saved" : "store_failed"
        UserDefaults.standard.set(status, forKey: WhoopBLEManager.CheckpointDefaults.lastStatus)
        UserDefaults.standard.set(saved.points.count, forKey: WhoopBLEManager.CheckpointDefaults.lastSamples)
        UserDefaults.standard.set(Int(saved.duration.rounded()), forKey: WhoopBLEManager.CheckpointDefaults.lastDuration)
        manualCheckpointStatus = persisted
            ? "saved \(saved.points.count) samples / \(Int(saved.duration.rounded()))s"
            : "checkpoint failed"
        NSLog("WHOOPDBG manual_checkpoint status=%@ samples=%d rr_samples=%d duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ mode=upsert reset_live_session=0",
              status,
              saved.points.count,
              saved.rrSampleCount,
              saved.duration,
              saved.avg,
              saved.peak,
              saved.restingStable,
              saved.hrv.map(String.init) ?? "learning",
              label)
        logLocalStatusIfWarm()
    }

    private func hrStat(_ title: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "—")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var hrvCard: some View {
        let validatedRMSSD = store.latestReferenceValidatedHRV
        let liveSnapshot = ble.hrvSnapshot
        let rrPackage = store.rrPackageStatusFast()
        let liveReadyButReferencePending = validatedRMSSD == nil && (liveSnapshot?.isReady == true || rrPackage.ready)
        return VStack(spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path").foregroundStyle(.purple)
                        Text("HRV").font(.headline)
                    }
                    Text("5-min corrected RR window")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(validatedRMSSD.map(String.init) ?? (liveReadyButReferencePending ? "pending" : "learning"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    if let h = liveSnapshot {
                        Text(validatedRMSSD != nil
                             ? "validated RMSSD ms · \(h.confidencePercent)% · \(h.kept)/\(h.raw) RR"
                             : (liveReadyButReferencePending ? "reference pending · \(rrPackage.ready ? rrPackage.confidencePercent : h.confidencePercent)% · \(rrPackage.ready ? rrPackage.kept : h.kept)/\(rrPackage.ready ? rrPackage.raw : h.raw) RR" : "learning · \(h.confidencePercent)% · \(h.kept)/\(h.raw) RR"))
                            .font(.caption2)
                            .foregroundStyle(validatedRMSSD != nil ? .green : .orange)
                        Text(validatedRMSSD != nil ? String(format: "SDNN %.1f · pNN50 %.1f%% · ln %.2f", h.sdnn, h.pnn50, h.lnRMSSD) : "SDNN · pNN50 · ln reference pending")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(validatedRMSSD != nil ? (h.respiratoryRate.map { String(format: "Resp %.1f/min", $0) } ?? "Resp learning") : "Resp reference pending")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(rrPackage.ready
                             ? "reference pending · \(rrPackage.confidencePercent)% · \(rrPackage.kept)/\(rrPackage.raw) RR"
                             : ble.hrvQuality)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if rrPackage.ready {
                            Text(String(format: "RMSSD %.1f · gap %.1fs", rrPackage.rmssd ?? 0, rrPackage.maxGapSeconds))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(ble.rrContinuityDetail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ble.rrContinuityState == "ready" ? .green : .orange)
                }
            }
            HStack(spacing: 8) {
                Button {
                    rrReferenceShareURL = store.exportRRReferencePackageForUI()
                    rrReferenceImportStatus = rrReferenceShareURL == nil ? "RR export unavailable" : "RR export ready"
                    logLocalStatusIfWarm()
                } label: {
                    Label("Export RR", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showRRReferenceImporter = true
                } label: {
                    Label("Import RR", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(validatedRMSSD == nil ? .orange : .green)
            }
            if let url = rrReferenceShareURL {
                ShareLink(item: url) {
                    Label("Share RR package", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if !rrReferenceImportStatus.isEmpty {
                Text(rrReferenceImportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .center) {
            if !ble.tachogram.isEmpty {
                VStack {
                    Spacer()
                    TachogramChart(samples: ble.tachogram.suffix(80).map { $0 })
                        .padding(.top, 72)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            Text("cmd:\(ble.dbgCmdSends) \(ble.dbgWriteMode):\(ble.dbgWrite) prop:\(ble.dbgPropFrames) rt:\(ble.dbgRealtimeFrames) · \(ble.dbgLast)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.orange)
                .lineLimit(2).minimumScaleFactor(0.5)
                .padding(.bottom, 2)
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            metric(title: "Battery",
                   value: ble.batteryLevel >= 0 ? "\(ble.batteryLevel)%" : "—",
                   system: "battery.100")
            metric(title: "Max HR",
                   value: "\(store.profile.maxHR)",
                   system: "figure.run")
        }
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Profile", systemImage: "person.crop.circle")
                    .font(.headline)
                Spacer()
                Text("\(store.profile.maxHR) max")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("HRmax source", selection: Binding(
                get: { store.profile.maxHRSource },
                set: { source in store.updateProfile { $0.maxHRSource = source } }
            )) {
                ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Stepper("Age \(store.profile.age)", value: Binding(
                get: { store.profile.age },
                set: { age in store.updateProfile { $0.age = age } }
            ), in: 13...100)

            Stepper("Measured max \(store.profile.measuredMaxHR)", value: Binding(
                get: { store.profile.measuredMaxHR },
                set: { maxHR in store.updateProfile { $0.measuredMaxHR = maxHR } }
            ), in: 120...220)

            let calibration = hrMaxCalibrationSummary
            HStack(alignment: .center, spacing: 10) {
                Label(calibration.observedPeak > 0 ? "Observed peak \(calibration.observedPeak)" : "Observed peak learning",
                      systemImage: "waveform.path.ecg.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(calibration.canRaiseMeasured ? .orange : .secondary)
                Spacer(minLength: 8)
                if calibration.canRaiseMeasured {
                    Button("Use peak") {
                        applyObservedPeakAsMeasuredHRMax()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }

            Text(calibration.canRaiseMeasured
                 ? "Raises measured HRmax only after you confirm; Atria never lowers HRmax from a submax session."
                 : "Atria never lowers HRmax from observed data; use the stepper after a true max test.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Text("Strain uses \(store.profile.sourceLabel) HRmax and learned RHR \(restForStrain).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(title: String, value: String, system: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: system).foregroundStyle(.secondary)
            Text(value).font(.headline)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Capture").font(.headline)
                Spacer()
                if ble.isRecording {
                    Text("\(ble.capturedRows) rows")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if ble.isRecording {
                captureReadiness
            } else if ble.capturedRows > 0 {
                captureSummary
            }
            TextField("Label (e.g. still, walking, deep breath)", text: $ble.captureLabel)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
            HStack(spacing: 12) {
                Button {
                    ble.toggleRecording()
                } label: {
                    Label(ble.isRecording ? "Stop" : "Record",
                          systemImage: ble.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ble.isRecording ? .red : .accentColor)

                if !ble.isRecording, ble.capturedRows > 0, let url = ble.exportCSV() {
                    ShareLink(item: url) {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var captureReadiness: some View {
        let snapshot = ble.hrvSnapshot
        let ready = snapshot?.isReady == true
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ready ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(snapshot?.readinessMessage ?? "Recording clean RR window")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let h = snapshot {
                    Text("\(h.confidencePercent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ready ? .green : .orange)
                }
            }
            if let h = snapshot {
                Text("Rec \(Int(ble.captureElapsedSeconds))s · HRV \(Int(h.windowSeconds))s/300s · RR \(h.kept)/\(h.raw) · RMSSD \(h.isReady ? String(format: "%.1f", h.rmssd) : "learning") · SDNN \(h.isReady ? String(format: "%.1f", h.sdnn) : "learning")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                captureReadinessChecklist(h)
            } else {
                Text("Rec \(Int(ble.captureElapsedSeconds))s · \(ble.hrvQuality).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("RR quality · \(ble.rrContinuityDetail)")
                .font(.caption2)
                .foregroundStyle(ble.rrContinuityState == "ready" ? .green : .orange)
                .monospacedDigit()
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func captureReadinessChecklist(_ h: HRVSnapshot) -> some View {
        let artifacts = h.rejectedOutOfRange + h.rejectedDeltaOver20Percent
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
            readinessPill("contact", isGood: ble.hasContact && h.windowSeconds > 0)
            readinessPill("window \(min(Int(h.windowSeconds), 300))/300", isGood: h.windowSeconds >= 300)
            readinessPill("gap \(String(format: "%.1f", h.maxRRGapSeconds))s", isGood: h.maxRRGapSeconds <= HRVSnapshot.maxReadyRRGapSeconds)
            readinessPill("beats \(h.kept)/240", isGood: h.kept >= 240)
            readinessPill("conf \(h.confidencePercent)%", isGood: h.confidence >= 0.75)
            readinessPill("artifacts \(artifacts)", isGood: artifacts == 0)
            readinessPill("dropped \(artifacts)", isGood: h.confidence >= 0.75)
            readinessPill(h.isReady ? "ready" : "learning", isGood: h.isReady)
        }
        .font(.caption2.monospacedDigit())
    }

    private func readinessPill(_ text: String, isGood: Bool) -> some View {
        Label(text, systemImage: isGood ? "checkmark.circle.fill" : "clock")
            .foregroundStyle(isGood ? .green : .orange)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var captureSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ble.captureWasValidationReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ble.captureWasValidationReady ? .green : .orange)
            Text(ble.captureSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var framesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Proprietary stream").font(.headline)
                Spacer()
                Text("\(ble.frames.count)").font(.caption).foregroundStyle(.secondary)
            }
            if ble.frames.isEmpty {
                Text("No frames yet — wear the strap to wake the sensors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ble.frames.prefix(40)) { f in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%02X", f.opcode))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(f.source) · len \(f.declaredLen) · sum \(f.checksumHex)\(f.wellFormed ? "" : " ⚠︎")")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(f.hex)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
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
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
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
                    Text("Not counted as workout until HR/reference evidence is stronger.")
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
        NSLog("WHOOPDBG daily_evidence_ui reason=%@ sessions_today=%d saved_minutes=%d rr_saved=%d detections=%d workouts=%d rest_candidates=%d sleep_candidates=%d activity_candidates=%d confirmed_workouts=%d confirmed_sleeps=%d sleep_signal=%d sleep_state=%@ sleep_motion_validated=%d workout_signal=%d workout_diagnosis=%@ top_kind=%@ top_confidence=%@ top_duration_s=%d top_avg_hr=%d top_peak_hr=%d top_reason=%@ rest_diagnostic_only=1 diagnostic_only=%d",
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
            if !rrPresent && savedRRPresent { return "Current segment is HR-only; saved RR package stays ready." }
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
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
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
        NSLog("WHOOPDBG collection_reliability_ui reason=%@ protected=%d connected=%d hr=%d long_wear=%d checkpoint_armed=%d checkpoint_interval_s=%d checkpoint_source=%@ checkpoint_last_status=%@ checkpoint_last_samples=%d checkpoint_last_duration_s=%d journal_present=%d journal_fresh=%d journal_samples=%d journal_rr_values=%d journal_duration_s=%d journal_rr_max_gap_s=%.1f journal_rr_coverage_3s_percent=%d rr_present=%d rr_presence_status=%@ rr_presence_action=%@ rr_presence_rr_gap_s=%.1f rr_presence_accepted_gap_s=%.1f rr_presence_samples=%d rr_presence_values=%d rr_presence_age_s=%d sample_status=%@ sample_reason=%@ accepted_samples=%d accepted_gaps=%d max_accepted_gap_s=%.1f watchdog_recoveries=%d watchdog_last_status=%@ watchdog_last_source=%@ watchdog_last_action=%@ watchdog_last_age_s=%d fail_closed=1",
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

struct ProfileOnboardingView: View {
    @State private var draft: AthleteProfile
    let onComplete: (AthleteProfile) -> Void

    init(profile: AthleteProfile, onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("HRmax source", selection: $draft.maxHRSource) {
                        ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Age \(draft.age)", value: $draft.age, in: 13...100)
                    Stepper("Measured max \(draft.measuredMaxHR)", value: $draft.measuredMaxHR, in: 120...220)
                }
                Section {
                    HStack {
                        Text("Active HRmax")
                        Spacer()
                        Text("\(draft.maxHR)")
                            .font(.headline.monospacedDigit())
                    }
                    Text("Strain uses HR reserve from learned resting HR to this HRmax.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onComplete(draft)
                    }
                }
            }
        }
    }
}

/// Minimal heart-rate sparkline.
struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let lo = Double(values.min() ?? 0)
                let hi = Double(values.max() ?? 1)
                let span = max(hi - lo, 1)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * Double(i) / Double(values.count - 1)
                        let y = geo.size.height * (1 - (Double(v) - lo) / span)
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }
                .stroke(.red.gradient, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WhoopBLEManager())
        .environmentObject(SessionStore())
}
