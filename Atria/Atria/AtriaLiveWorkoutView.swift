import SwiftUI
import UIKit

/// Identifiable wrapper so a live workout can drive `.fullScreenCover(item:)`.
struct AtriaWorkoutSession: Identifiable {
    let id = UUID()
    let start: Date
    /// User-picked pre-workout target (gap spec c, workout intensity picker,
    /// 2026-07-05). Additive and optional so existing call sites
    /// (`AtriaWorkoutSession(start:)`) keep compiling unchanged. The screens
    /// that present this session (AtriaHomeView/AtriaTodayScreen) are outside
    /// this feature's file ownership, so these fields are the forward-
    /// compatible persistence surface the spec calls for; the live view
    /// itself resolves its own in-session override via `userTargetChoice`
    /// below, independent of whether a caller ever threads these through.
    var targetStrain: Double? = nil
    var targetZone: Int? = nil

    /// The user's target choice re-derived from the persisted fields, if any.
    var targetChoice: AtriaWorkoutTargetChoice? {
        if let targetStrain { return .strain(targetStrain) }
        if let targetZone { return .zone(targetZone) }
        return nil
    }
}

/// A user's workout target override: either a heart-rate zone (mapped to its
/// equivalent strain band, see `AtriaWorkoutTargetMath`) or a direct numeric
/// strain goal. `nil` anywhere this type is optional means "follow the auto
/// guidance" -- never a fabricated default.
enum AtriaWorkoutTargetChoice: Equatable {
    case zone(Int)
    case strain(Double)
}

/// Pure math for the workout target picker: zone -> strain band mapping and
/// the ease/hold/build cue, both unit-testable without instantiating the
/// live SwiftUI view (which needs live, connected ObservableObject stores).
enum AtriaWorkoutTargetMath {
    /// Top of the 0...21 Whoop-like strain scale already used throughout the
    /// live workout HUD (see `strainTargetProgress`'s auto-guidance fallback).
    static let strainCeiling: Double = 21.0

    /// The strain band a heart-rate zone maps to, built from the same
    /// `lowerFraction` boundaries the zone bar/target lane already render --
    /// so a picked zone and the live zone bar always agree on where each zone
    /// starts and ends.
    static func strainBand(for zone: HRZone) -> ClosedRange<Double> {
        let lower = zone.lowerFraction * strainCeiling
        let upperFraction = HRZone(rawValue: zone.rawValue + 1)?.lowerFraction ?? 1.0
        let upper = max(lower, upperFraction * strainCeiling)
        return lower...upper
    }

    /// A single representative strain target for a zone: the midpoint of its band.
    static func strainTarget(for zone: HRZone) -> Double {
        let band = strainBand(for: zone)
        return ((band.lowerBound + band.upperBound) / 2 * 10).rounded() / 10
    }

    /// Resolves the live strain target: a user override wins, otherwise the
    /// auto guidance -- so leaving the picker untouched is always identical
    /// to this feature not existing.
    static func effectiveTarget(choice: AtriaWorkoutTargetChoice?, guidanceTarget: Double?) -> Double? {
        switch choice {
        case .zone(let rawZone):
            guard let zone = HRZone(rawValue: rawZone) else { return guidanceTarget }
            return strainTarget(for: zone)
        case .strain(let value):
            return value
        case nil:
            return guidanceTarget
        }
    }

    /// Same ease/hold/build thresholds the strain-target card has always
    /// used, extracted into a pure function so it can be driven directly in
    /// tests without a live view.
    static func cue(strain: Double, target: Double?) -> String {
        guard let target else { return "building" }
        if strain >= target + 1.0 { return "ease" }
        if strain >= target { return "hold" }
        return "build"
    }
}

/// Live workout HUD: a full-screen, glanceable real-time view shown while a
/// workout is active — big live HR + zone, a zone bar, live strain building
/// toward a target, active calories, and elapsed time. All values come from the
/// existing live stores (no new pipeline); the strap is already recording.
struct AtriaLiveWorkoutView: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    let maxHR: Int
    let strainTarget: Double?
    let startDate: Date
    let strengthHistorySessions: [SavedSession]
    @Binding var loggedSets: [LoggedSet]
    @Binding var excludedIntervals: [ExcludedInterval]
    @Binding var heartRateBroadcastEnabled: Bool
    let broadcastPersistsAfterWorkout: Bool
    let onMinimize: () -> Void
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSetLogger = false
    @State private var showTargetPicker = false
    @State private var userTargetChoice: AtriaWorkoutTargetChoice?
    @State private var selectedExercise = "Barbell bench press"
    @State private var loggerWeightKg = 60.0
    @State private var loggerReps = 8
    @State private var loggerRestSeconds: TimeInterval = 120
    @State private var restTimerEndsAt: Date?
    @State private var editingSetID: UUID?
    @State private var pauseStartedAt: Date?
    @State private var latestPRSetID: UUID?

    private var heartRate: Int { pulseStore.state.heartRate }
    private var strain: Double { heroStore.state.strain }

    var body: some View {
        // Resolve the zone ONCE per render and pass it down (was recomputed in
        // body + every subview). The elapsed clock is isolated in a TimelineView
        // so the per-second tick no longer re-renders the whole HUD.
        let zone = HRZone.zone(for: heartRate, maxHR: maxHR)
        return ZStack {
            LinearGradient(colors: [zone.color.opacity(0.45), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: zone)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        header
                        heartBlock(zone)
                            .padding(.top, 2)
                        // Design handoff stat row (2026-07-07): strain-so-far +
                        // live calories as first-class tiles under the HR hero
                        // (duration stays in the header's isolated clock).
                        statsRow
                        // Decongested 2026-07-06 (10 cards -> 5): zone was drawn
                        // 4x and strain-vs-target 3x. Now one coach cue, one zone
                        // module (zoneBar absorbs the old zoneFocus samples), one
                        // strain/target module (strainTargetCard absorbs the old
                        // targetLane picker), strength log, and one controls card
                        // (pauseResumeCard absorbs the broadcast toggle). The old
                        // workoutSourceStrip / workoutTargetLane / zoneFocusCard /
                        // broadcastHeartRateCard were pure duplication.
                        workoutCoachCueCard(zone)
                        zoneBar(zone)
                        strainTargetCard
                        strengthLoggerCard
                        pauseResumeCard
                    }
                    .padding(22)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                stopButton
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
        }
        .safeAreaPadding(.top)
        .safeAreaPadding(.bottom)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSetLogger) {
            setLoggerSheet
                .presentationDetents([.height(390), .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showTargetPicker) {
            AtriaWorkoutTargetPicker(currentZone: zone,
                                     guidanceTarget: strainTarget,
                                     choice: $userTargetChoice)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            #if DEBUG
            applyDebugWorkoutFixtureIfNeeded(arguments: ProcessInfo.processInfo.arguments)
            if ProcessInfo.processInfo.arguments.contains("--atria-open-set-logger") {
                primeLoggerFromLastSet()
                showSetLogger = true
            }
            #endif
        }
    }

    private var header: some View {
        HStack {
            Button {
                onMinimize()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Minimize workout")

            Label("Live workout", systemImage: "figure.run")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            TimelineView(.periodic(from: startDate, by: 1)) { context in
                Text(elapsedText(context.date))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }

    private func heartBlock(_ zone: HRZone) -> some View {
        VStack(spacing: 2) {
            pulsingHeartIcon
            Text(heartRate > 0 ? "\(heartRate)" : "--")
                .font(.system(size: 72, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("\(zone.name.uppercased()) · bpm")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(zone.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heart rate \(heartRate), \(zone.name) zone")
    }

    @ViewBuilder
    private var pulsingHeartIcon: some View {
        let icon = Image(systemName: "heart.fill")
            .font(.title2)
            .foregroundStyle(.red)
        if reduceMotion {
            icon
        } else {
            icon.symbolEffect(.pulse, options: .repeating)
        }
    }

    private var strengthLoggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Strength log", systemImage: "dumbbell.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                if let restTimerEndsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(restTimerText(now: context.date, end: restTimerEndsAt))
                            .font(.caption.weight(.black).monospacedDigit())
                            .foregroundStyle(.mint)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.mint.opacity(0.16), in: Capsule())
                    }
                }
            }

            if loggedSets.isEmpty {
                Text("Log sets without leaving the workout.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))
            } else {
                VStack(spacing: 7) {
                    ForEach(loggedSets.suffix(4)) { set in
                        loggedSetRow(set)
                    }
                }
            }

            Button {
                primeLoggerFromLastSet()
                showSetLogger = true
            } label: {
                Label("Log set", systemImage: "plus.circle.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.glassProminent)
            .tint(.mint)
        }
        .padding(12)
        .atriaWorkoutGlassSurface(cornerRadius: 22, tint: .mint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strength log. \(loggedSets.count) sets logged.")
    }

    private func loggedSetRow(_ set: LoggedSet) -> some View {
        HStack(spacing: 10) {
            Button {
                editLoggedSet(set)
            } label: {
                HStack(spacing: 10) {
                    Text(set.exercise)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(setSummary(set))
                        .font(.caption.weight(.black).monospacedDigit())
                        .foregroundStyle(.mint)
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                deleteLoggedSet(set)
            } label: {
                // Destructive control next to the edit row: full 44pt hit
                // area so a miss never deletes (UX audit 2026-07-07).
                Image(systemName: "trash.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.red.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete set")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var pauseResumeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(isPaused ? "Workout paused" : "Pause workout",
                      systemImage: isPaused ? "pause.circle.fill" : "pause.circle")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                if let pauseStartedAt {
                    TimelineView(.periodic(from: pauseStartedAt, by: 1)) { context in
                        Text(pauseElapsedText(context.date))
                            .font(.caption.weight(.black).monospacedDigit())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }
                }
            }

            Text(isPaused ? "HR keeps recording. This span is excluded when saved." : "Use for rest, setup, or interruptions.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(2)

            Button {
                toggleWorkoutPause()
            } label: {
                Label(isPaused ? "Resume workout" : "Pause workout",
                      systemImage: isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.glassProminent)
            .tint(isPaused ? .green : .orange)

            // Absorbed from the old broadcastHeartRateCard: a secondary control,
            // now a compact toggle in the same session-controls card.
            Divider().overlay(.white.opacity(0.12))

            Toggle(isOn: $heartRateBroadcastEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Broadcast heart rate", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                    Text(broadcastPersistsAfterWorkout
                         ? "Stays on after this workout. Extra battery while active."
                         : "Ends with this workout. Extra battery while active.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.cyan)
        }
        .padding(12)
        .atriaWorkoutGlassSurface(cornerRadius: 22, tint: isPaused ? .orange : .white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPaused ? "Workout paused. Resume workout." : "Pause workout.")
    }

    private var setLoggerSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(editingSetID == nil ? "Log set" : "Edit set", systemImage: "dumbbell.fill")
                        .font(.headline.weight(.black))
                    Spacer()
                    Button("Done") { showSetLogger = false }
                        .font(.subheadline.weight(.bold))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(loggerExerciseOptions, id: \.self) { exercise in
                            Button {
                                selectedExercise = exercise
                                primeLoggerFromLastSet(exercise: exercise)
                                loggerRestSeconds = AtriaStrengthLog.restSeconds(for: exercise)
                            } label: {
                                Text(exercise)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(selectedExercise == exercise ? Color.mint.opacity(0.26) : Color.white.opacity(0.08),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                loggerStepperRow(title: "Weight",
                                 value: "\(Int(loggerWeightKg.rounded())) kg",
                                 decrement: { loggerWeightKg = max(0, loggerWeightKg - 2.5) },
                                 increment: { loggerWeightKg += 2.5 })
                loggerStepperRow(title: "Reps",
                                 value: "\(loggerReps)",
                                 decrement: { loggerReps = max(1, loggerReps - 1) },
                                 increment: { loggerReps = min(99, loggerReps + 1) })
                loggerStepperRow(title: "Rest",
                                 value: restOverrideText(loggerRestSeconds),
                                 decrement: { updateRestOverride(max(30, loggerRestSeconds - 15)) },
                                 increment: { updateRestOverride(min(600, loggerRestSeconds + 15)) })

                exerciseHistoryPanel

                Button {
                    saveLoggedSet()
                } label: {
                    Label(editingSetID == nil ? "Save set" : "Update set", systemImage: "checkmark.circle.fill")
                        .font(.headline.weight(.black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
                .tint(.mint)
            }
            .padding(18)
        }
    }

    private func loggerStepperRow(title: String,
                                  value: String,
                                  decrement: @escaping () -> Void,
                                  increment: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.bold))
            Spacer()
            Button(action: decrement) {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Text(value)
                .font(.title3.weight(.black).monospacedDigit())
                .frame(minWidth: 86)
            Button(action: increment) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func workoutCoachCueCard(_ zone: HRZone) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(coachCueTint.opacity(0.18))
                Image(systemName: coachCueSymbol)
                    .font(.title3.weight(.black))
                    .foregroundStyle(coachCueTint)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(coachCueTitle)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    // Zone chip removed (dedup audit): the zone bar's chip
                    // and the hero caption already state the current zone.
                }

                Text(coachCueDetail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaWorkoutGlassSurface(cornerRadius: 24, tint: coachCueTint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout cue. \(coachCueTitle). \(coachCueDetail). Current zone \(zone.rawValue), \(zone.name).")
    }

    private func zoneBar(_ zone: HRZone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart-rate zones")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer(minLength: 8)
                Text(zone.name)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(zone.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(zone.color.opacity(0.16), in: Capsule())
            }

            HStack(spacing: 4) {
                ForEach(HRZone.allCases, id: \.self) { z in
                    VStack(spacing: 5) {
                        Capsule()
                            .fill(z == zone ? z.color : z.color.opacity(0.22))
                            .frame(height: z == zone ? 12 : 7)
                            .animation(.snappy(duration: 0.25), value: zone)
                        Text("Z\(z.rawValue)")
                            .font(.system(size: 9, weight: z == zone ? .black : .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(z == zone ? z.color : .white.opacity(0.42))
                    }
                }
            }

            // Absorbed from the old zoneFocusCard: where inside the current band
            // the live HR sits, plus the evidence readout.
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let progress = heartRateProgress
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(zone.color.opacity(0.78))
                        .frame(width: max(10, width * progress))
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(width * progress - 6, 0), max(width - 12, 0)))
                }
            }
            .frame(height: 14)

            HStack(spacing: 8) {
                focusPill(title: "Band", value: zoneBandText(zone))
                focusPill(title: "Samples", value: "\(liveStore.state.sessionSampleCount)")
                focusPill(title: "Evidence", value: liveStore.state.sessionSampleCount >= 900 ? "steady" : "building")
            }
        }
        .padding(12)
        .atriaWorkoutGlassSurface(cornerRadius: 20, tint: zone.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart-rate zones. Current zone \(zone.rawValue), \(zone.name), \(zoneBandText(zone)), \(liveStore.state.sessionSampleCount) samples.")
    }

    private var strainTargetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Target strain", systemImage: "target")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                // Absorbed from the old workoutTargetLane: edit whether the target
                // follows auto guidance or a user pick.
                Button {
                    showTargetPicker = true
                } label: {
                    Label(targetSourceLabel, systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.80))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set workout target. Currently \(targetSourceLabel).")
                // Header value capsule removed (dedup audit 2026-07-07): the
                // labeled Target pill below is the single copy.
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(Metrics.electricStrain.opacity(0.78))
                        .frame(width: max(10, width * strainTargetProgress))
                    if effectiveStrainTarget != nil {
                        Rectangle()
                            .fill(.white.opacity(0.92))
                            .frame(width: 3, height: 18)
                            .clipShape(Capsule(style: .continuous))
                            .offset(x: min(max(width - 3, 0), width))
                    }
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                // "Now" pill removed (dedup audit): the stats row's Strain
                // tile is the single live-strain readout; the progress bar
                // here shows position vs target.
                focusPill(title: "Target", value: strainTargetValueText)
                focusPill(title: "Cue", value: strainTargetCue)
            }
        }
        .padding(12)
        .atriaWorkoutGlassSurface(cornerRadius: 20, tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Target strain. Current \(String(format: "%.1f", strain)), target \(strainTargetValueText), \(strainTargetCue).")
    }

    private var strainTargetValueText: String {
        guard let strainTarget = effectiveStrainTarget else { return "Learning" }
        return String(format: "%.1f", strainTarget)
    }

    private var strainTargetProgress: Double {
        guard let strainTarget = effectiveStrainTarget, strainTarget > 0 else { return min(max(strain / 21.0, 0), 1) }
        return min(max(strain / strainTarget, 0), 1)
    }

    private var strainTargetCue: String {
        AtriaWorkoutTargetMath.cue(strain: strain, target: effectiveStrainTarget)
    }

    /// Short label for the target-lane edit affordance: shows whether the
    /// live target is following auto guidance or a user pick, and which.
    private var targetSourceLabel: String {
        switch userTargetChoice {
        case .zone(let rawZone):
            return "Z\(rawZone) goal"
        case .strain:
            return "Your goal"
        case nil:
            return "Auto"
        }
    }

    private var coachCueTitle: String {
        switch strainTargetCue {
        case "ease": return "Ease down"
        case "hold": return "Hold here"
        default: return "Build gently"
        }
    }

    private var coachCueDetail: String {
        switch strainTargetCue {
        case "ease": return "Above target. Let HR settle."
        case "hold": return "Target matched. Keep this effort."
        default: return "Below target. Add effort when ready."
        }
    }

    private var coachCueSymbol: String {
        switch strainTargetCue {
        case "ease": return "arrow.down.heart.fill"
        case "hold": return "equal.circle.fill"
        default: return "arrow.up.heart.fill"
        }
    }

    private var coachCueTint: Color {
        switch strainTargetCue {
        case "ease": return .orange
        case "hold": return .mint
        default: return Metrics.electricStrain
        }
    }

    private var effectiveStrainTarget: Double? {
        #if DEBUG
        if let debugTarget = debugStrainTarget {
            return debugTarget
        }
        #endif
        return AtriaWorkoutTargetMath.effectiveTarget(choice: userTargetChoice, guidanceTarget: strainTarget)
    }

    #if DEBUG
    private var debugStrainTarget: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("live-workout-target-build") {
            return max(0.1, strain + 3.0)
        }
        if arguments.contains("live-workout-target-hold") {
            return max(0.1, strain)
        }
        if arguments.contains("live-workout-target-ease") {
            return max(0.1, strain - 2.0)
        }
        return nil
    }
    #endif

    private var heartRateProgress: Double {
        guard maxHR > 0, heartRate > 0 else { return 0 }
        return min(max(Double(heartRate) / Double(maxHR), 0), 1)
    }

    private var loggerExerciseOptions: [String] {
        let recents = loggedSets.reversed().map(\.exercise)
        let suggested = AtriaWorkoutExerciseCatalog.suggestedExercises(for: AtriaWorkoutActivityType.strength.rawValue)
        let fallback = Array(AtriaWorkoutExerciseCatalog.groups.flatMap(\.exercises).prefix(8))
        let options = (recents + suggested).reduce(into: [String]()) { result, exercise in
            guard !result.contains(where: { $0.localizedCaseInsensitiveCompare(exercise) == .orderedSame }) else { return }
            result.append(exercise)
        }
        return Array((options.isEmpty ? fallback : options).prefix(12))
    }

    private func primeLoggerFromLastSet() {
        editingSetID = nil
        primeLoggerFromLastSet(exercise: selectedExercise)
    }

    #if DEBUG
    private func applyDebugWorkoutFixtureIfNeeded(arguments: [String]) {
        guard let fixture = Self.debugLaunchFixtureValue(arguments: arguments) else { return }
        if fixture == "live-workout-set-saved" {
            selectedExercise = "Barbell bench press"
            loggerWeightKg = 85
            loggerReps = 5
            loggerRestSeconds = AtriaStrengthLog.restSeconds(for: selectedExercise)
            latestPRSetID = loggedSets.last?.id
            restTimerEndsAt = Date().addingTimeInterval(91)
        } else if fixture == "live-workout-paused" {
            pauseStartedAt = Date().addingTimeInterval(-74)
        }
    }

    private static func debugLaunchFixtureValue(arguments: [String]) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"],
           !environmentValue.isEmpty {
            return environmentValue
        }
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
    #endif

    private func primeLoggerFromLastSet(exercise: String) {
        loggerRestSeconds = AtriaStrengthLog.restSeconds(for: exercise)
        guard let last = loggedSets.last(where: { $0.exercise.localizedCaseInsensitiveCompare(exercise) == .orderedSame }) else {
            selectedExercise = exercise
            return
        }
        selectedExercise = exercise
        loggerWeightKg = last.weightKg ?? loggerWeightKg
        loggerReps = last.reps ?? loggerReps
    }

    private func saveLoggedSet() {
        let set = LoggedSet(exercise: selectedExercise,
                            weightKg: loggerWeightKg > 0 ? loggerWeightKg : nil,
                            reps: loggerReps,
                            rpe: nil,
                            t: Date())
        let isNewPR = AtriaStrengthLog.isPR(set, against: personalRecordsIncludingCurrentWorkout(for: selectedExercise))
        if let editingSetID,
           let index = loggedSets.firstIndex(where: { $0.id == editingSetID }) {
            loggedSets[index] = set
            self.editingSetID = nil
        } else {
            loggedSets.append(set)
        }
        latestPRSetID = isNewPR ? set.id : nil
        restTimerEndsAt = Date().addingTimeInterval(restSeconds(for: selectedExercise))
        mirrorLoggedSetsToActiveJournal()
        UIImpactFeedbackGenerator(style: isNewPR ? .heavy : .light).impactOccurred()
    }

    private func editLoggedSet(_ set: LoggedSet) {
        editingSetID = set.id
        selectedExercise = set.exercise
        loggerRestSeconds = AtriaStrengthLog.restSeconds(for: set.exercise)
        loggerWeightKg = set.weightKg ?? loggerWeightKg
        loggerReps = set.reps ?? loggerReps
        showSetLogger = true
    }

    private func deleteLoggedSet(_ set: LoggedSet) {
        loggedSets.removeAll { $0.id == set.id }
        mirrorLoggedSetsToActiveJournal()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func mirrorLoggedSetsToActiveJournal() {
        try? ActiveSessionJournal.mirrorStrengthState(strengthSets: loggedSets,
                                                      excludedIntervals: effectiveExcludedIntervals)
    }

    private var isPaused: Bool {
        pauseStartedAt != nil
    }

    private var effectiveExcludedIntervals: [ExcludedInterval] {
        guard let pauseStartedAt else { return excludedIntervals }
        return excludedIntervals + [ExcludedInterval(start: pauseStartedAt, end: Date())]
    }

    private func toggleWorkoutPause() {
        if isPaused {
            finalizePauseIfNeeded()
        } else {
            pauseStartedAt = Date()
            mirrorLoggedSetsToActiveJournal()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finalizePauseIfNeeded(now: Date = Date()) {
        guard let started = pauseStartedAt else { return }
        let end = max(now, started)
        excludedIntervals.append(ExcludedInterval(start: started, end: end))
        pauseStartedAt = nil
        mirrorLoggedSetsToActiveJournal()
    }

    private func pauseElapsedText(_ date: Date) -> String {
        guard let pauseStartedAt else { return "00:00" }
        let total = max(0, Int(date.timeIntervalSince(pauseStartedAt)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func restSeconds(for exercise: String) -> TimeInterval {
        AtriaStrengthLog.restSeconds(for: exercise)
    }

    private func updateRestOverride(_ seconds: TimeInterval) {
        loggerRestSeconds = seconds
        AtriaStrengthLog.setRestSeconds(seconds, for: selectedExercise)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func restOverrideText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func restTimerText(now: Date, end: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func setSummary(_ set: LoggedSet) -> String {
        let weight = set.weightKg.map { "\(Int($0.rounded())) kg" } ?? "--"
        let reps = set.reps.map { "\($0)" } ?? "--"
        let base = "\(weight) x \(reps)"
        return isPersonalRecord(set) ? "\(base) · PR" : base
    }

    private var exerciseHistoryPanel: some View {
        let records = personalRecords(for: selectedExercise)
        let history = AtriaStrengthLog.history(for: selectedExercise, in: strengthHistorySessions)
        let best = history.last?.best
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("History", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.black))
                Spacer()
                Text(history.isEmpty ? "No sets yet" : "\(history.count) days")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                historyMetric("Best", value: best.map(setSummaryPlain) ?? "--")
                historyMetric("e1RM", value: records.maxE1RM.map { "\(Int($0.rounded())) kg" } ?? "--")
                historyMetric("Max", value: records.maxWeightKg.map { "\(Int($0.rounded())) kg" } ?? "--")
            }

            if let latestPRSetID,
               loggedSets.contains(where: { $0.id == latestPRSetID }) {
                Label("New PR", systemImage: "sparkles")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func historyMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.black).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func personalRecords(for exercise: String) -> StrengthPersonalRecords {
        AtriaStrengthLog.personalRecords(for: exercise, in: strengthHistorySessions)
    }

    private func personalRecordsIncludingCurrentWorkout(for exercise: String) -> StrengthPersonalRecords {
        AtriaStrengthLog.personalRecords(for: exercise, in: strengthHistorySessions + currentStrengthSession)
    }

    private func isPersonalRecord(_ set: LoggedSet) -> Bool {
        latestPRSetID == set.id || AtriaStrengthLog.isPR(set, against: personalRecords(for: set.exercise))
    }

    private var currentStrengthSession: [SavedSession] {
        guard !loggedSets.isEmpty else { return [] }
        return [SavedSession(id: UUID(),
                             start: startDate,
                             end: Date(),
                             label: "Live workout",
                             points: [],
                             strengthSets: loggedSets)]
    }

    private func setSummaryPlain(_ set: LoggedSet) -> String {
        let weight = set.weightKg.map { "\(Int($0.rounded())) kg" } ?? "--"
        let reps = set.reps.map { "\($0)" } ?? "--"
        return "\(weight) x \(reps)"
    }

    private func zoneBandText(_ zone: HRZone) -> String {
        let lower = Int((Double(maxHR) * zone.lowerFraction).rounded())
        let next = HRZone(rawValue: zone.rawValue + 1)
        if let upperZone = next {
            let upper = max(lower, Int((Double(maxHR) * upperZone.lowerFraction).rounded()) - 1)
            return "\(lower)-\(upper)"
        }
        return "\(lower)+"
    }

    private func focusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.60))
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // Rendered under the HR hero since 2026-07-07 (design-handoff stat row);
    // previously pinned-but-uncalled scaffolding.
    private var statsRow: some View {
        HStack(spacing: 14) {
            statTile(title: "Strain",
                     value: String(format: "%.1f", strain),
                     tint: .orange)
            statTile(title: "Calories",
                     value: liveStore.state.liveActiveCaloriesText,
                     tint: .pink)
        }
    }

    private func statTile(title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .atriaWorkoutGlassSurface(cornerRadius: 18, tint: tint)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            finalizePauseIfNeeded()
            onStop()
            dismiss()
        } label: {
            Label("End workout", systemImage: "stop.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .atriaCardAction(tint: .red)
    }

    private func elapsedText(_ date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(startDate)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

/// Pre-workout (or mid-workout) target picker: zone focus or a direct strain
/// goal, styled to match the live HUD's dark glass surfaces (gap spec c).
/// Presented from the target lane's edit affordance; commits into
/// `userTargetChoice` on Done, or clears it back to "Auto" (the existing
/// guidance default) -- never changes anything until the user confirms.
private struct AtriaWorkoutTargetPicker: View {
    let currentZone: HRZone
    let guidanceTarget: Double?
    @Binding var choice: AtriaWorkoutTargetChoice?
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case zone = "Zone"
        case strain = "Strain goal"
        var id: String { rawValue }
    }

    @State private var mode: Mode
    @State private var selectedZone: HRZone
    @State private var strainGoal: Double

    init(currentZone: HRZone, guidanceTarget: Double?, choice: Binding<AtriaWorkoutTargetChoice?>) {
        self.currentZone = currentZone
        self.guidanceTarget = guidanceTarget
        self._choice = choice
        let fallbackGoal = guidanceTarget ?? AtriaWorkoutTargetMath.strainTarget(for: currentZone)
        switch choice.wrappedValue {
        case .zone(let rawZone):
            _mode = State(initialValue: .zone)
            _selectedZone = State(initialValue: HRZone(rawValue: rawZone) ?? currentZone)
            _strainGoal = State(initialValue: fallbackGoal)
        case .strain(let value):
            _mode = State(initialValue: .strain)
            _selectedZone = State(initialValue: currentZone)
            _strainGoal = State(initialValue: value)
        case nil:
            _mode = State(initialValue: .auto)
            _selectedZone = State(initialValue: currentZone)
            _strainGoal = State(initialValue: fallbackGoal)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Workout target", systemImage: "target")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Done") { commitAndDismiss() }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Metrics.electricStrain)
                }

                modePicker

                Group {
                    switch mode {
                    case .auto: autoContent
                    case .zone: zoneContent
                    case .strain: strainContent
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { candidate in
                Button {
                    withAnimation(.snappy) { mode = candidate }
                } label: {
                    Text(candidate.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(mode == candidate ? Metrics.electricStrain.opacity(0.24) : Color.white.opacity(0.08),
                                    in: Capsule())
                        .overlay {
                            if mode == candidate {
                                Capsule().stroke(Metrics.electricStrain.opacity(0.6), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var autoContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follows Atria's live strain guidance.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(guidanceTarget.map { String(format: "Currently %.1f", $0) } ?? "Learning your guidance target.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(14)
        .atriaWorkoutGlassSurface(cornerRadius: 18, tint: .white)
    }

    private var zoneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a zone to hold. Atria maps it to a strain band.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))

            VStack(spacing: 8) {
                ForEach(HRZone.allCases, id: \.self) { zoneOption in
                    zoneRow(zoneOption)
                }
            }
        }
    }

    private func zoneRow(_ zoneOption: HRZone) -> some View {
        let band = AtriaWorkoutTargetMath.strainBand(for: zoneOption)
        let isSelected = selectedZone == zoneOption
        return Button {
            selectedZone = zoneOption
        } label: {
            HStack(spacing: 10) {
                Capsule()
                    .fill(zoneOption.color.opacity(isSelected ? 0.92 : 0.32))
                    .frame(width: 8, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Z\(zoneOption.rawValue) \u{00B7} \(zoneOption.name)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text(String(format: "%.1f\u{2013}%.1f strain", band.lowerBound, band.upperBound))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(zoneOption.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .atriaWorkoutGlassSurface(cornerRadius: 16, tint: isSelected ? zoneOption.color : .white)
        .accessibilityLabel("Zone \(zoneOption.rawValue), \(zoneOption.name), \(String(format: "%.1f to %.1f strain", band.lowerBound, band.upperBound))\(isSelected ? ", selected" : "").")
    }

    private var strainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set a direct strain number to aim for.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 16) {
                Button {
                    strainGoal = max(1.0, strainGoal - 0.5)
                } label: {
                    Image(systemName: "minus.circle.fill").font(.title2)
                }
                Text(String(format: "%.1f", strainGoal))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 90)
                Button {
                    strainGoal = min(AtriaWorkoutTargetMath.strainCeiling, strainGoal + 0.5)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Strain goal \(String(format: "%.1f", strainGoal))")
        }
        .padding(14)
        .atriaWorkoutGlassSurface(cornerRadius: 18, tint: Metrics.electricStrain)
    }

    private func commitAndDismiss() {
        switch mode {
        case .auto:
            choice = nil
        case .zone:
            choice = .zone(selectedZone.rawValue)
        case .strain:
            choice = .strain((strainGoal * 10).rounded() / 10)
        }
        dismiss()
    }
}

private struct AtriaWorkoutGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay {
                shape
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            }
            .glassEffect(.regular.tint(tint.opacity(0.12)), in: shape)
    }
}

private extension View {
    func atriaWorkoutGlassSurface(cornerRadius: CGFloat, tint: Color) -> some View {
        modifier(AtriaWorkoutGlassSurfaceModifier(cornerRadius: cornerRadius, tint: tint))
    }
}
