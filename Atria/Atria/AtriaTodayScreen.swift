import SwiftUI
import UIKit

struct AtriaTodayScreen: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let layoutConfig: AtriaHomeLayoutConfig
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let hapticSettings: AtriaHapticAlertSettings
    let horizontalSizeClass: UserInterfaceSizeClass?
    let connectionContext: AtriaConnectionGuideContext
    let debugShowsSegmentContent: Bool
    let suppressSleepSyncPrompt: Bool
    let initialSegment: AtriaLegacyOverviewDestination
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onOpenJournal: () -> Void
    let onOpenShare: () -> Void
    let onStartWorkout: () -> Void
    let onCustomizeToday: () -> Void
    @State private var metricDetail: AtriaMetricDetailKind?
    @State private var showWeeklyReport = false
    @State private var showBreathworkSession = false
    @State private var ringShareImage: UIImage?
    /// Apple-Fitness-style scroll shrink: 0 at rest (full size), 1 once the
    /// user has scrolled up past `Self.heroShrinkDistance`. Reduce Motion
    /// keeps this pinned to full size (see `heroScale`/`heroOpacity`)
    /// regardless of this value -- the hero simply never shrinks.
    @State private var heroShrinkProgress: CGFloat = 0
    /// Read-through cache for glance-tile derivations that are expensive to
    /// recompute (filters/sorts over rollup or workout history) but only
    /// change when the underlying aggregate actually changes -- see
    /// `AtriaTodayGlanceMemo` (measured-perf pass, 2026-07-05). Held in
    /// `@State` (not a plain `let`) so the reference -- and therefore the
    /// cache inside it -- survives AtriaTodayScreen being value-recreated by
    /// AtriaHomeView on every live-pulse tick.
    @State private var glanceMemo = AtriaTodayGlanceMemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    /// Optional display name set elsewhere in the app. Empty -- the default
    /// -- means no greeting is shown; never a fabricated name.
    @AtriaDefault("atria.user.nickname") private var nickname: String = ""

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayScreen")
        VStack(spacing: 16) {
            if debugShowsAICoachOnly {
                AtriaAICoachCard(context: coachContext,
                                 preparedPayload: coachPayload,
                                 settings: effectiveAICoachSettings,
                                 hasAPIKey: aiCoachHasAPIKey,
                                 onSettingsChange: onAICoachSettingsChange,
                                 onSaveAPIKey: onSaveAICoachAPIKey,
                                 onDeleteAPIKey: onDeleteAICoachAPIKey)
            } else if AtriaOverviewBehaviorJournalSection.debugShowsImpactOnlyFixture {
                AtriaOverviewBehaviorJournalSection(store: store)
            } else {
            // The tri-ring hero (IA-6.1, static-check gated) is the one and
            // only glance-first summary on this screen. A fixed 3-tile
            // "glance strip" used to sit above it showing the same
            // sleep/recovery/strain numbers a second time -- pure
            // duplication -- and was removed; the ring hero plus its legend
            // chips are now the single source of truth for those values.
            if let greetingText {
                HStack {
                    Text(greetingText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            topActionMenu
            triRingHero
            if layoutConfig.showLiveStrip {
                AtriaTodayLiveStatusStrip(live: liveStore.state,
                                          pulse: pulseStore.state)
            }

            let highlights = AtriaHighlights.topTwo(rollups: highlightRollups)
            if layoutConfig.showHighlights && !highlights.isEmpty {
                AtriaTodayHighlightsStrip(highlights: highlights)
            }

            if layoutConfig.showPlan {
                AtriaTodayPlanCard(title: planTitle,
                                   detail: planDetail,
                                   target: planTargetText,
                                   tint: displayHero.guidance.color)
            }

            AtriaTodayShortcutStrip(journalValue: journalValue,
                                    onOpenJournal: onOpenJournal,
                                    onOpenShare: onOpenShare,
                                    onStartWorkout: onStartWorkout)

            if layoutConfig.showPlan {
                AtriaTodayWeeklyPlanCard(plan: weeklyPlan) {
                    showWeeklyReport = true
                }
            }

            LazyVGrid(columns: glanceColumns, spacing: 10) {
                ForEach(glanceItems) { item in
                    if item.id == "Stress" {
                        Button {
                            showBreathworkSession = true
                        } label: {
                            AtriaTodayGlanceTile(item: item)
                        }
                        .buttonStyle(.plain)
                        .gridCellColumns(glanceColumnSpan(for: item))
                        .contextMenu {
                            Button(action: onCustomizeToday) {
                                Label("Customize Today", systemImage: "slider.horizontal.3")
                            }
                        }
                    } else {
                        AtriaTodayGlanceTile(item: item)
                            .gridCellColumns(glanceColumnSpan(for: item))
                            .contextMenu {
                                Button(action: onCustomizeToday) {
                                    Label("Customize Today", systemImage: "slider.horizontal.3")
                                }
                            }
                    }
                }
            }

            if layoutConfig.showAICoach && effectiveAICoachSettings.mode != .off {
                AtriaAICoachCard(context: coachContext,
                                 preparedPayload: coachPayload,
                                 settings: effectiveAICoachSettings,
                                 hasAPIKey: aiCoachHasAPIKey,
                                 onSettingsChange: onAICoachSettingsChange,
                                 onSaveAPIKey: onSaveAICoachAPIKey,
                                 onDeleteAPIKey: onDeleteAICoachAPIKey)
            }

            AtriaTodayInfoRow(title: "Journal",
                              value: journalValue,
                              systemImage: "checklist",
                              tint: .teal)
            }
        }
        .sheet(item: $metricDetail) { detail in
            AtriaMetricDetailSheet(metric: detail,
                                   rollups: highlightRollups,
                                   confirmedWorkouts: debugMetricDetailWorkouts ?? store.confirmedWorkouts,
                                   baseline: AtriaBaselineTargetSnapshot(store.baseline),
                                   sleepHistory: store.sleepHistorySnapshot,
                                   guidance: displayHero.guidance,
                                   recoveryEstimate: displayHero.recoveryEstimate,
                                   sleepGoalHours: sleepGoalHours,
                                   sleepBaseNeedHours: sleepBaseNeedHours)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWeeklyReport) {
            AtriaWeeklyReportSheet(report: weeklyReport)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showBreathworkSession) {
            AtriaBreathworkSession(currentHeartRate: pulseStore.state.heartRate,
                                   currentRRSamples: pulseStore.state.recentRRSamples,
                                   onSave: { session in
                                       store.add(session)
                                   }) {
                showBreathworkSession = false
            }
        }
        .onAppear {
            #if DEBUG
            if metricDetail == nil,
               let debugDetail = Self.debugInitialMetricDetail(arguments: ProcessInfo.processInfo.arguments) {
                metricDetail = debugDetail
            }
            if Self.debugShowsWeeklyReport(arguments: ProcessInfo.processInfo.arguments) {
                showWeeklyReport = true
            }
            if Self.debugShowsBreathwork(arguments: ProcessInfo.processInfo.arguments) {
                showBreathworkSession = true
            }
            #endif
        }
        // Apple-Fitness-style hero shrink: reads the *ancestor* ScrollView's
        // (owned by the Overview/Home screen this is embedded in) live
        // content offset without any prop-drilling, and drives
        // `heroShrinkProgress` from it. Reduce Motion is honored in
        // `heroScale`/`heroOpacity` themselves, not by skipping this update,
        // so the state stays consistent if the setting changes mid-scroll.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            let clamped = min(max(newValue, 0), Self.heroShrinkDistance)
            // Quantized to 5% steps: a raw per-frame write re-evaluates the
            // whole screen ~60x/s during scroll — the "hanging" the user felt.
            let quantized = (clamped / Self.heroShrinkDistance * 20).rounded() / 20
            if quantized != heroShrinkProgress {
                heroShrinkProgress = quantized
            }
        }
    }

    /// Scroll distance (points) over which the hero fully shrinks/fades.
    private static let heroShrinkDistance: CGFloat = 140
    private static let heroMinScale: CGFloat = 0.6

    /// Time-of-day-aware "Good morning/afternoon/evening, <name>" line shown
    /// above the ring hero -- nil (and simply omitted) whenever no nickname
    /// has been set, never a placeholder greeting.
    private var greetingText: String? {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        default: timeOfDay = "evening"
        }
        return "Good \(timeOfDay), \(trimmed)"
    }

    private var glanceColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
    }

    private var glanceColumnCount: Int {
        horizontalSizeClass == .regular ? 3 : 2
    }

    private func glanceColumnSpan(for item: AtriaTodayGlanceItem) -> Int {
        min(item.layoutSize.columnSpan, glanceColumnCount)
    }

    private var topActionMenu: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ringShareToolbarButton
            Menu {
                Button(action: onCustomizeToday) {
                    Label("Customize Today", systemImage: "slider.horizontal.3")
                }
                Button(action: onOpenShare) {
                    Label("Share Today", systemImage: "square.and.arrow.up")
                }
                Menu {
                    ForEach(Array(ringSlots.enumerated()), id: \.offset) { position, current in
                        Menu(Self.ringPositionLabels[position]) {
                            ForEach(AtriaTriRingSlot.allCases, id: \.self) { slot in
                                Button {
                                    assignRingSlot(slot, toPosition: position)
                                } label: {
                                    if slot == current {
                                        Label(slot.label, systemImage: "checkmark")
                                    } else {
                                        Text(slot.label)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Ring Metrics", systemImage: "circle.grid.3x3")
                }
                Button(action: rotateRingOrder) {
                    Label("Rotate Ring Order", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Today actions")
        }
    }

    private var triRingHero: some View {
        VStack(spacing: 10) {
            // Ring-metric-picker migration: each ring position resolves
            // through `ringSlots`/`metric(for:)` to whichever of the five
            // supported metrics (sleep/recovery/strain/hrv/rhr) the user
            // assigned it, via AtriaTriRing's new slots array API
            // (coordinated with the IA-6.1 static-check pin update in
            // test_handoff_static_checks.py -- see that file for the note
            // citing this migration).
            //
            // Perf pass (2026-07-05): the scroll-driven scale/opacity used to
            // be applied here, directly inside AtriaTodayScreen's own body --
            // every `heroShrinkProgress` write (quantized, but still ~20
            // steps over a full scroll) forced this whole property (ring
            // construction + all its slot/metric plumbing) to be rebuilt.
            // `AtriaTodayHeroShrink` isolates the scale/opacity consumer in
            // its own `View` so the per-step churn during scroll shows up on
            // its own probe line instead of amplifying `AtriaTodayScreen`'s.
            AtriaTodayHeroShrink(progress: heroShrinkProgress, minScale: Self.heroMinScale) {
                AtriaTriRing(slots: ringSlots.map { AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0)) },
                             centerValue: centerValue,
                             centerState: centerState,
                             centerDelta: centerDeltaText,
                             accessibilitySummary: accessibilitySummary,
                             actions: ringActions)
            }

            AtriaStrainTargetCard(currentStrain: displayHero.strain,
                                  target: displayHero.guidance.target,
                                  tint: Metrics.electricStrain)
        }
    }

    /// Resolves whichever metric a ring slot currently carries. Reused by
    /// the hero, the share-as-picture render, and the accessibility
    /// summary so all three always agree.
    private func metric(for slot: AtriaTriRingSlot) -> AtriaTriRingMetric {
        switch slot {
        case .sleep: return sleepMetric
        case .recovery: return recoveryMetric
        case .strain: return strainMetric
        case .hrv: return hrvMetric
        case .rhr: return restingHeartRateMetric
        }
    }

    /// Tap routing for every possible ring slot -- whichever three are
    /// actually on screen tap through to the matching metric detail sheet;
    /// unused entries are simply never invoked.
    private var ringActions: [AtriaTriRingSlot: () -> Void] {
        [.sleep: { metricDetail = .sleep },
         .recovery: { metricDetail = .recovery },
         .strain: { metricDetail = .strain },
         .hrv: { metricDetail = .hrv },
         .rhr: { metricDetail = .restingHeartRate }]
    }

    /// Compact "share as picture" icon button hosted top-right of the ring
    /// hero card, alongside the ⋯ menu -- same idea as the Face-Off
    /// story-image share button, just an icon-only affordance here instead
    /// of a labeled pill under the hero.
    @ViewBuilder
    private var ringShareToolbarButton: some View {
        // Rendered on demand: rasterizing the 1080x1350 card is main-thread
        // work, so it happens once per tap, never per live metric tick.
        if let ringShareImage {
            ShareLink(item: Image(uiImage: ringShareImage),
                      preview: SharePreview("Atria \(ringShareContent.dateText)",
                                            image: Image(uiImage: ringShareImage))) {
                Image(systemName: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Share ring as picture")
        } else {
            Button {
                ringShareImage = AtriaRingShare.renderImage(ringShareContent)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Share ring as picture")
            .onChange(of: ringShareSignature) { _, _ in
                ringShareImage = nil
            }
        }
    }

    private var ringShareContent: AtriaRingShare.Content {
        AtriaRingShare.Content(slots: ringSlots.map { AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0)) },
                               centerValue: centerValue,
                               centerState: centerState,
                               dateText: Self.ringShareDateFormatter.string(from: Date()))
    }

    private var ringShareSignature: String {
        (ringSlots.map { slot in "\(slot.rawValue):\(metric(for: slot).value)" } + [centerValue, centerState])
            .joined(separator: "|")
    }

    private static let ringShareDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    /// Legacy key: originally just an *order* of the fixed sleep/recovery/
    /// strain trio (pre-ring-metric-picker). Its CSV format (slot raw
    /// values) is identical to the new `ringMetricsRaw` key below, so it
    /// only ever serves as a one-time migration seed now.
    @AtriaDefault("atria.today.ringOrder") private var ringOrderRaw: String = "sleep,recovery,strain"

    /// Which of the five supported metrics (sleep/recovery/strain/hrv/rhr)
    /// each ring position (outer -> inner) shows -- the ring-metric-picker
    /// generalization of the old fixed-trio `ringOrder`. Persisted the same
    /// way other single-value layout prefs are (an `@AtriaDefault`-backed
    /// comma-joined string), independent of the separate
    /// `AtriaHomeLayoutConfig` JSON blob so this stays inside this screen's
    /// own file. Empty means "never explicitly set on this device", in
    /// which case the legacy `ringOrderRaw` value (itself defaulting to
    /// sleep/recovery/strain) is adopted as the seed.
    @AtriaDefault("atria.today.ringMetrics") private var ringMetricsRaw: String = ""

    private var ringSlots: [AtriaTriRingSlot] {
        let raw = ringMetricsRaw.isEmpty ? ringOrderRaw : ringMetricsRaw
        var seen = Set<AtriaTriRingSlot>()
        var result = raw
            .split(separator: ",")
            .compactMap { AtriaTriRingSlot(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        for slot in AtriaTriRingSlot.defaultOrder where !result.contains(slot) {
            result.append(slot)
        }
        return Array(result.prefix(3))
    }

    private func persistRingSlots(_ slots: [AtriaTriRingSlot]) {
        ringMetricsRaw = slots.map(\.rawValue).joined(separator: ",")
    }

    private func rotateRingOrder() {
        var order = ringSlots
        guard order.count == 3 else {
            persistRingSlots(AtriaTriRingSlot.defaultOrder)
            return
        }
        order.append(order.removeFirst())
        persistRingSlots(order)
    }

    private static let ringPositionLabels = ["Outer Ring", "Middle Ring", "Inner Ring"]

    /// Ring-metric-picker: assigns `slot` to ring position `position`
    /// (0 = outer ... 2 = inner). If `slot` already occupies a different
    /// position, the two positions swap rather than leaving a duplicate
    /// metric on two rings.
    private func assignRingSlot(_ slot: AtriaTriRingSlot, toPosition position: Int) {
        var slots = ringSlots
        guard slots.indices.contains(position) else { return }
        if let existing = slots.firstIndex(of: slot), existing != position {
            slots.swapAt(existing, position)
        } else {
            slots[position] = slot
        }
        persistRingSlots(slots)
    }

    private var highlightRollups: [DailyRollupStoreEntry] {
        #if DEBUG
        if Self.debugShowsNorthStarHighlights(arguments: ProcessInfo.processInfo.arguments)
            || Self.debugShowsWeeklyReport(arguments: ProcessInfo.processInfo.arguments)
            || Self.debugShowsAICoachLocalFixture(arguments: ProcessInfo.processInfo.arguments)
            || Self.debugShowsNutritionRecoveryDetail(arguments: ProcessInfo.processInfo.arguments) {
            return Self.debugHighlightRollups(includeNutrition: Self.debugShowsNutritionRecoveryDetail(arguments: ProcessInfo.processInfo.arguments))
        }
        #endif
        return store.dailyRollupHistory
    }

    #if DEBUG
    private static func debugShowsNorthStarHighlights(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "north-star-highlights"
    }

    private static func debugShowsWeeklyReport(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "weekly-report"
    }

    private static func debugShowsBreathwork(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && ["breathwork-session", "breathwork-result-rr"].contains(arguments[valueIndex])
    }

    private static func debugShowsNutritionRecoveryDetail(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "recovery-detail-nutrition"
    }

    private static func debugHighlightRollups(includeNutrition: Bool = false) -> [DailyRollupStoreEntry] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        var rollups: [DailyRollupStoreEntry] = []
        for offset in 0..<8 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let recovery = 72 - offset
            let rmssdSource = Double(58 - min(offset, 6))
            let restingHeartRate = offset == 0 ? 52 : 58 + (offset % 2)
            let sleepSeconds: TimeInterval = 8 * 60 * 60
            let sleepPerformance = offset < 3 ? 104 : 92
            let bedtimeMinutes = 22 * 60 + 20
            let strain = 10 + Double(offset) * 0.4
            rollups.append(DailyRollupStoreEntry(day: day,
                                                 recovery: recovery,
                                                 lnRMSSD: log(rmssdSource),
                                                 rhr: restingHeartRate,
                                                 sleepSeconds: sleepSeconds,
                                                 sleepPerformance: sleepPerformance,
                                                 bedtimeMinutes: bedtimeMinutes,
                                                 strain: strain,
                                                 calendar: calendar))
        }
        if includeNutrition, !rollups.isEmpty {
            rollups[0].nutrition = AtriaNutritionSummary(kcal: 2140,
                                                         proteinG: 132,
                                                         carbsG: 210,
                                                         fatG: 71,
                                                         waterMl: 2300,
                                                         caffeineMg: 180,
                                                         lastCaffeineHour: 16,
                                                         alcoholDrinks: 2)
        }
        return rollups
    }

    private static func debugInitialMetricDetail(arguments: [String]) -> AtriaMetricDetailKind? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        switch arguments[valueIndex] {
        case "strain-detail": return .strain
        case "recovery-detail", "recovery-detail-nutrition": return .recovery
        case "hrv-detail": return .hrv
        case "rhr-detail": return .restingHeartRate
        case "respiratory-detail": return .respiratoryRate
        case "sleep-detail": return .sleep
        default: return nil
        }
    }

    private var debugMetricDetailWorkouts: [UserConfirmedWorkout]? {
        guard Self.debugInitialMetricDetail(arguments: ProcessInfo.processInfo.arguments) == .strain else {
            return nil
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstStart = calendar.date(byAdding: .hour, value: 7, to: today) ?? today
        let secondStart = calendar.date(byAdding: .hour, value: 17, to: today) ?? today
        return [
            UserConfirmedWorkout(id: "debug-today-strain-strength",
                                 createdAt: today,
                                 start: firstStart,
                                 end: firstStart.addingTimeInterval(46 * 60),
                                 label: "Push strength",
                                 source: "debug_fixture",
                                 confidence: "fixture",
                                 sessions: 1,
                                 samples: 2_420,
                                 avgHR: 136,
                                 peakHR: 164,
                                 p95HR: 158,
                                 p99HR: 162,
                                 thresholdHR: 126,
                                 streamCoveragePercent: 92,
                                 observedDuration: 46 * 60,
                                 reason: "debug strain detail workout",
                                 activityType: "Strength",
                                 activitySubtype: "Push",
                                 exerciseNames: ["Bench press", "Cable row"],
                                 reviewSource: "debug_fixture",
                                 strain: 8.8,
                                 activeEnergyKilocalories: 420,
                                 activeEnergyConfidence: "fixture",
                                 zoneSeconds: ["warmup": 540, "fatBurn": 760, "aerobic": 980, "anaerobic": 420, "max": 60]),
            UserConfirmedWorkout(id: "debug-today-strain-cardio",
                                 createdAt: today,
                                 start: secondStart,
                                 end: secondStart.addingTimeInterval(28 * 60),
                                 label: "Tempo run",
                                 source: "debug_fixture",
                                 confidence: "fixture",
                                 sessions: 1,
                                 samples: 1_540,
                                 avgHR: 148,
                                 peakHR: 176,
                                 p95HR: 169,
                                 p99HR: 174,
                                 thresholdHR: 126,
                                 streamCoveragePercent: 95,
                                 observedDuration: 28 * 60,
                                 reason: "debug strain detail workout",
                                 activityType: "Cardio",
                                 activitySubtype: "Tempo",
                                 exerciseNames: nil,
                                 reviewSource: "debug_fixture",
                                 strain: 7.1,
                                 activeEnergyKilocalories: 310,
                                 activeEnergyConfidence: "fixture",
                                 zoneSeconds: ["warmup": 180, "fatBurn": 420, "aerobic": 600, "anaerobic": 420, "max": 60])
        ]
    }
    #else
    private var debugMetricDetailWorkouts: [UserConfirmedWorkout]? { nil }
    #endif

    private var hero: AtriaHomeModel.HeroSnapshot {
        heroStore.state
    }

    private var displayHero: AtriaHomeModel.HeroSnapshot {
        #if DEBUG
        if let fixture = Self.debugHeroSnapshot(arguments: ProcessInfo.processInfo.arguments) {
            return fixture
        }
        #endif
        return hero
    }

    #if DEBUG
    private static func debugHeroSnapshot(arguments: [String]) -> AtriaHomeModel.HeroSnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }

        let strain: Double
        switch arguments[valueIndex] {
        case "strain-target-under":
            strain = 8.0
        case "strain-target-at":
            strain = 12.0
        case "strain-target-over":
            strain = 15.2
        case "recovery-after-nap":
            strain = 4.0
        default:
            return nil
        }

        let recoveryPercent = arguments[valueIndex] == "recovery-after-nap" ? 68 : 50
        let recovery = Metrics.RecoveryEstimate(percent: recoveryPercent,
                                                confidence: .personalBaseline,
                                                usesHRV: true,
                                                detail: arguments[valueIndex] == "recovery-after-nap" ? "debug_after_nap" : "debug_strain_target",
                                                contributors: [])
        let guidance = Coach.guide(recovery: recovery, strain: strain, load: .learning)
        return AtriaHomeModel.HeroSnapshot(recoveryEstimate: recovery,
                                           recoveryIsProvisional: false,
                                           recoveryLiftedAfterNap: arguments[valueIndex] == "recovery-after-nap",
                                           strain: strain,
                                           strainConfidence: "local",
                                           guidance: guidance,
                                           hrvValue: "58",
                                           hrvDetail: "personal baseline",
                                           hrvNarrative: "Debug fixture: strain target state is fixed for visual proof.",
                                           stressValue: "1/3",
                                           stressDetail: "steady",
                                           stressNarrative: "Debug fixture stress stays neutral while strain target state changes.",
                                           rrPackageText: "Personal",
                                           nextAction: guidance.detail,
                                           headline: guidance.headline,
                                           sessionsCount: PersonalBaseline.trustedMinimumSamples,
                                           baselineSamples: PersonalBaseline.trustedMinimumSamples,
                                           backupValue: "Ready",
                                           backupDetail: "debug fixture",
                                           restingHeartRate: 56,
                                           restingHeartRateText: "56",
                                           strainNarrative: String(format: "Debug fixture strain %.1f against live target %.1f.", strain, guidance.target ?? 0),
                                           loadRatioText: "Learning",
                                           loadTargetText: "Learning",
                                           loadConfidence: "learning",
                                           loadReadinessText: "Learning",
                                           loadACWRSignalText: "Learning",
                                           loadMonotonyText: "Learning",
                                           loadMonotonySignalText: "Learning",
                                           loadACWRDetailText: TrainingLoadSummary.learning.acwrDetailText,
                                           loadMonotonyDetailText: TrainingLoadSummary.learning.monotonyDetailText,
                                           loadSignalSummaryText: "Learning",
                                           loadNarrative: "Training load appears after local strain history builds.",
                                           hrZoneMinutes: .empty)
    }
    #endif

    private var latestSleep: SleepHistorySnapshot.Night? {
        store.sleepHistorySnapshot.latest
    }

    /// Real nightly need in hours, computed the same way the sleep-history
    /// screen's "Slept X of Y needed" line is (`sleepNeedHours`, which
    /// factors in yesterday's strain and any running sleep debt) -- only
    /// reachable when there's an actual `Night` on record. Nil otherwise, so
    /// callers fall back to the plainer stored `sleepPerformance` percent.
    private var sleepNeedHoursValue: Double? {
        guard let latestSleep else { return nil }
        return store.sleepHistorySnapshot.sleepNeedHours(for: latestSleep, baseNeedHours: sleepBaseNeedHours)
    }

    /// Legend-chip-style "of 8h 58m need" detail. Sleep is always shown
    /// hours-first (never a bare percent as the primary number) -- this is
    /// only ever the small secondary caption. Falls back to the plainer
    /// "X% need" whenever a real hours need can't be computed (no `Night`
    /// on record yet), and to "Sleep" when there's no data at all.
    private func sleepNeedDetailText(performance: Int?) -> String {
        if let needHours = sleepNeedHoursValue {
            return "of \(AtriaMetricFormat.sleepHours(needHours)) need"
        }
        if let performance {
            return "\(performance)% need"
        }
        return "Sleep"
    }

    private var sleepMetric: AtriaTriRingMetric {
        let performance = latestRollup?.sleepPerformance
        // Hours-first, always: falls back to the rollup's stored duration
        // before ever falling back to a bare percent as the primary number.
        let value = latestSleep?.durationText
            ?? latestRollup?.sleepSeconds.map { AtriaMetricFormat.sleepDuration(seconds: $0) }
            ?? "Building"
        return AtriaTriRingMetric(title: "Sleep",
                                  value: value,
                                  detail: sleepNeedDetailText(performance: performance),
                                  systemImage: "moon.fill",
                                  // Color-coherence pass (2026-07-05): identity hue always sleep
                                  // violet -- zone state moved to `stateTint` (the legend dot).
                                  tint: Metrics.electricSleep,
                                  fill: performance.map { min(max(Double($0) / 100.0, 0), 1) },
                                  stateTint: performance.map { AtriaTriRing.zoneTint(.sleep, percent: Double($0)) },
                                  // A marker at 1.0 (ring closure) exactly when there's a real,
                                  // computed nightly need to close against -- never a fabricated
                                  // target when `sleepNeedHoursValue` can't be computed yet.
                                  targetFraction: sleepNeedHoursValue != nil ? 1.0 : nil)
    }

    /// WHOOP-like DISPLAY carry: between midnight and today's first stored
    /// morning reading (and during reconnect learning flickers) the hero keeps
    /// showing the last stored daily recovery, labeled "yesterday", instead of
    /// a live provisional recompute that jumps around pre-sleep. Once today's
    /// rollup carries a recovery value, the live estimate takes over again.
    /// Rollups sorted day-descending, memoized behind
    /// `store.dailyRollupHistoryRevision` (measured-perf pass, 2026-07-05):
    /// `displayRecovery`, `latestRollup`, and `previousRollup` all used to
    /// independently re-sort `highlightRollups` on every one of the many
    /// live-pulse body evals in between actual rollup changes -- now the sort
    /// runs at most once per revision and every consumer shares it.
    private var dayDescendingRollups: [DailyRollupStoreEntry] {
        let revision = store.dailyRollupHistoryRevision
        if glanceMemo.dayDescendingRevision == revision, let cached = glanceMemo.dayDescendingRollups {
            return cached
        }
        let sorted = highlightRollups.sorted { $0.day > $1.day }
        glanceMemo.dayDescendingRevision = revision
        glanceMemo.dayDescendingRollups = sorted
        return sorted
    }

    private var displayRecovery: (value: String, detail: String, percent: Int?) {
        let estimate = displayHero.recoveryEstimate
        let newestStored = dayDescendingRollups
            .first(where: { $0.recovery != nil })
        let todayHasReading = newestStored.map {
            Calendar.current.isDateInToday($0.day)
        } ?? false
        // Post-midnight before the new morning reading: yesterday's score.
        if !todayHasReading, let carried = newestStored?.recovery {
            return ("\(carried)%", "yesterday", carried)
        }
        if let percent = estimate.percent {
            let detail = displayHero.recoveryLiftedAfterNap ? "↑ after nap" : displayHero.recoveryDetail
            return ("\(percent)%", detail, percent)
        }
        // Live estimate momentarily unavailable (reconnect warm-up): the
        // stored morning reading is still today's truth — never flash
        // "Learning" over a number the user already has.
        if let stored = newestStored?.recovery {
            return ("\(stored)%", todayHasReading ? "this morning" : "yesterday", stored)
        }
        return ("Learning", "Recovery", nil)
    }

    private var recoveryMetric: AtriaTriRingMetric {
        let display = displayRecovery
        return AtriaTriRingMetric(title: "Recovery",
                                  value: display.value,
                                  detail: display.detail,
                                  systemImage: "arrow.clockwise.heart.fill",
                                  // EXCEPTION to the identity-hue rule (color-coherence pass,
                                  // 2026-07-05): recovery's hue IS its value (WHOOP red/yellow/
                                  // green over 0-100), so `tint` itself stays zone-graded. Falls
                                  // back to identity heart-green, never `.secondary` gray, while
                                  // learning. `stateTint` stays nil -- the dot would be redundant.
                                  tint: display.percent.map { AtriaTriRing.zoneTint(.recovery, percent: Double($0)) } ?? Metrics.electricGreen,
                                  fill: display.percent.map { Double($0) / 100.0 })
                                  // No target marker: recovery has no separate "target" of its
                                  // own -- its value is already the 0-100 scale it's graded on.
    }

    /// Real, user-set absolute strain target if one is ever wired up in
    /// AtriaMetricTargets -- currently there is none (only the green/yellow
    /// *band widths* around the coach's own target are user-editable there,
    /// via AtriaSettingsView's strainGreenBand/strainYellowBand), so this is
    /// nil today and the ring marker/absolute-strain semantics below fall
    /// through to the coach's recovery-derived recommendation. Kept as its
    /// own hook so a future real per-user strain target slots in here
    /// without touching the ring math again.
    private var userSetStrainTarget: Double? { nil }

    private var strainMetric: AtriaTriRingMetric {
        // Strain-ring-semantics pass (2026-07-05): the ring FILL is
        // absolute strain against a clean 0-20 scale (never target-relative
        // -- a 12 strain always fills the same 60% of the ring no matter
        // today's target), so the ring reads as "how much strain today",
        // while the TARGET MARKER below is the separate "recommended by
        // ATRIA based on recovery" cue the strain-relative math used to be
        // folded into. Zone tinting (under/optimal/over) still compares
        // strain against the target, unchanged, but is routed to
        // `stateTint` only -- color-coherence pass (2026-07-05): the fill/
        // track hue always stays strain's one cool electric blue, matching
        // the glance tile below it.
        let target = userSetStrainTarget ?? displayHero.guidance.target
        let percentOfTarget = target.map { displayHero.strain / $0 * 100 }
        return AtriaTriRingMetric(title: "Strain",
                                  value: displayHero.strainValue,
                                  detail: target.map { String(format: "of %.1f", $0) } ?? "Strain",
                                  systemImage: "flame.fill",
                                  tint: Metrics.strainColor(displayHero.strain),
                                  fill: min(max(displayHero.strain / 20.0, 0), 1),
                                  stateTint: percentOfTarget.map { AtriaTriRing.zoneTint(.strain, percent: $0) },
                                  // Honest: no marker unless there's a real target (a real
                                  // user-set value, or the coach's recovery-based recommendation).
                                  targetFraction: target.map { min(max($0 / 20.0, 0), 1) })
    }

    /// HRV ring metric. Fill is nil (learning placeholder cap) unless the
    /// current reading parses AND the personal HRV baseline is trusted --
    /// never a fabricated ratio against an unproven baseline. Higher HRV is
    /// better, so fill climbs toward/above the trusted baseline.
    private var hrvMetric: AtriaTriRingMetric {
        let baseline = AtriaBaselineTargetSnapshot(store.baseline)
        let current = Int(displayHero.hrvValue)
        let fill: Double?
        if let current, let base = baseline.hrvBaseline, baseline.hrvTrusted, base > 0 {
            fill = min(max(Double(current) / (Double(base) * 1.15), 0), 1.15)
        } else {
            fill = nil
        }
        return AtriaTriRingMetric(title: "HRV",
                                  value: current.map { "\($0)" } ?? displayHero.hrvValue,
                                  detail: legendDetail(displayHero.hrvDetail),
                                  systemImage: "waveform.path.ecg",
                                  tint: .pink,
                                  fill: fill)
    }

    /// Resting heart rate ring metric. Fill is nil (learning placeholder
    /// cap) unless the personal resting-HR baseline is trusted. Lower RHR
    /// is better, so the fill is baseline/current -- a reading at or below
    /// baseline reads as full+ -- never a raw ratio that would reward a
    /// higher bpm.
    private var restingHeartRateMetric: AtriaTriRingMetric {
        let baseline = AtriaBaselineTargetSnapshot(store.baseline)
        let current = displayHero.restingHeartRate
        let fill: Double?
        if current > 0, let base = baseline.restingBaseline, baseline.restingTrusted, base > 0 {
            fill = min(max(Double(base) / Double(current), 0), 1.15)
        } else {
            fill = nil
        }
        return AtriaTriRingMetric(title: "RHR",
                                  value: current > 0 ? "\(current)" : displayHero.restingHeartRateText,
                                  detail: legendDetail("bpm"),
                                  systemImage: "heart.fill",
                                  tint: .pink,
                                  fill: fill)
    }

    private var latestRollup: DailyRollupStoreEntry? {
        dayDescendingRollups.first
    }

    private var weeklyPlan: WeeklyPlan {
        WeeklyPlanStore().currentPlan(rollups: highlightRollups)
    }

    private var weeklyReport: WeeklyReport {
        WeeklyReport(rollups: highlightRollups)
    }

    private var centerValue: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            return displayRecovery.percent != nil ? displayRecovery.value : "Day 1"
        case .sleep:
            // Hours-first: never the bare "82%" this used to show -- the
            // percent moves to `centerState` as a small "82% of need"
            // caption instead. `sleepMetric.value` already resolves to
            // duration text with a non-percent "Building" fallback.
            return sleepMetric.value
        case .strain:
            return strainMetric.value
        }
    }

    private var centerState: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            if displayRecovery.detail == "yesterday" { return "yesterday" }
            return displayRecovery.percent.map(recoveryState) ?? "Building"
        case .sleep:
            return latestRollup?.sleepPerformance.map { "\($0)% of need" } ?? sleepMetric.detail
        case .strain:
            return strainMetric.detail
        }
    }

    /// Prior day's rollup, used only for the ring hero's tiny center delta.
    /// Nil whenever there isn't a distinct prior day on record -- the delta
    /// is omitted rather than fabricated in that case.
    private var previousRollup: DailyRollupStoreEntry? {
        let sorted = dayDescendingRollups
        guard sorted.count > 1 else { return nil }
        return sorted[1]
    }

    /// Tiny "+4% vs yesterday" style read under the ring hero's center
    /// numeral. Only ever built from two real, already-stored values; when
    /// either side is missing (still learning, first day, etc.) this is
    /// nil and the hero simply omits the line -- no placeholder guess.
    private var centerDeltaText: String? {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            guard let current = displayHero.recoveryEstimate.percent,
                  let previous = previousRollup?.recovery else { return nil }
            return Self.deltaText(current - previous, unit: "%")
        case .sleep:
            guard let current = latestRollup?.sleepPerformance,
                  let previous = previousRollup?.sleepPerformance else { return nil }
            return Self.deltaText(current - previous, unit: "%")
        case .strain:
            guard let previous = previousRollup?.strain else { return nil }
            let delta = displayHero.strain - previous
            guard abs(delta) >= 0.05 else { return "Flat vs yesterday" }
            return String(format: "%@%.1f vs yesterday", delta > 0 ? "+" : "-", abs(delta))
        }
    }

    private static func deltaText(_ delta: Int, unit: String) -> String {
        guard delta != 0 else { return "Flat vs yesterday" }
        return "\(delta > 0 ? "+" : "-")\(abs(delta))\(unit) vs yesterday"
    }

    /// Describes whichever three metrics are actually configured on the ring
    /// hero right now (ring-metric-picker), not a hard-coded sleep/recovery/
    /// strain trio.
    private var accessibilitySummary: String {
        let parts = ringSlots.map { slot -> String in
            let m = metric(for: slot)
            return m.detail.isEmpty ? "\(m.title) \(m.value)" : "\(m.title) \(m.value) \(m.detail)"
        }
        return parts.joined(separator: ", ") + "."
    }

    private var healthValue: String {
        displayHero.recoveryEstimate.percent.map { "\($0)% recovery" } ?? "Building"
    }

    private var strapValue: String {
        switch liveStore.state.status {
        case .connected:
            return "Live"
        case .connecting, .scanning:
            return "Finding"
        case .disconnected, .poweredOff:
            return "Off"
        }
    }

    private var planTitle: String {
        displayHero.guidance.headline
    }

    private var planDetail: String {
        displayHero.guidance.detail
    }

    private var planTargetText: String {
        displayHero.guidance.target.map { String(format: "Target %.1f", $0) } ?? "Target building"
    }

    private var journalValue: String {
        store.behaviorJournalEntries.isEmpty ? "Ready" : "\(store.behaviorJournalEntries.count) tags"
    }

    private var coachContext: AtriaCoachContext {
        AtriaCoachContext(guidance: displayHero.guidance,
                          strain: displayHero.strain,
                          recoveryText: displayHero.recoveryValue,
                          hrvText: displayHero.hrvValue,
                          stressText: displayHero.stressValue,
                          baselineSamples: displayHero.baselineSamples,
                          sessionsCount: displayHero.sessionsCount)
    }

    private var coachPayload: AtriaCoachPayload {
        AtriaCoachPayload.fromRollups(rollups: Array(highlightRollups.prefix(7)),
                                      fallback: coachContext,
                                      baselines: coachBaselines)
    }

    private var coachBaselines: [String: AtriaCoachPayload.VitalRange] {
        [
            "recovery": .init(low: 0, high: 100),
            "strain": .init(low: 0, high: displayHero.guidance.target ?? 20),
            "hrv": .init(low: nil, high: nil),
            "rhr": .init(low: nil, high: nil)
        ]
    }

    private var effectiveAICoachSettings: AtriaAICoachSettings {
        #if DEBUG
        if debugShowsAICoachOnly {
            var settings = aiCoachSettings
            settings.mode = .local
            return settings
        }
        #endif
        return aiCoachSettings
    }

    private var debugShowsAICoachOnly: Bool {
        #if DEBUG
        return Self.debugShowsAICoachLocalFixture(arguments: ProcessInfo.processInfo.arguments)
        #else
        return false
        #endif
    }

    private var glanceItems: [AtriaTodayGlanceItem] {
        layoutConfig.validated().glanceMetrics
            .compactMap(AtriaTodayMetric.init(rawValue:))
            .compactMap(glanceItem(for:))
    }

    private func glanceItem(for metric: AtriaTodayMetric) -> AtriaTodayGlanceItem? {
        switch metric {
        case .sleep:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: sleepMetric.value,
                                        detail: legendDetail(sleepMetric.detail),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .recovery:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: recoveryMetric.value,
                                        detail: legendDetail(recoveryMetric.detail),
                                        systemImage: metric.systemImage,
                                        tint: recoveryMetric.tint,
                                        layoutSize: layoutSize(for: metric))
        case .strain:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: strainMetric.value,
                                        detail: legendDetail(strainMetric.detail),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .load:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.loadRatioText,
                                        detail: legendDetail(displayHero.loadReadinessText),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .hrZones:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.hrZoneMinutes.valueText,
                                        detail: legendDetail(displayHero.hrZoneMinutes.detailText),
                                        systemImage: metric.systemImage,
                                        tint: .orange,
                                        layoutSize: layoutSize(for: metric))
        case .workouts:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "\(thisWeekConfirmedWorkoutsCount)",
                                        detail: legendDetail(latestConfirmedWorkoutOneLiner),
                                        systemImage: metric.systemImage,
                                        tint: .mint,
                                        layoutSize: layoutSize(for: metric))
        case .strainCompare:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.strainValue,
                                        detail: legendDetail(strainCompareDetailText),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .hrv:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.hrvValue,
                                        detail: legendDetail(displayHero.hrvDetail),
                                        systemImage: metric.systemImage,
                                        tint: .pink,
                                        layoutSize: layoutSize(for: metric))
        case .stress:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.stressValue,
                                        detail: legendDetail(displayHero.stressDetail),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .sleepHistory:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: store.sleepHistorySnapshot.sleepConsistencyText,
                                        detail: legendDetail("Routine"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .sleepEfficiency:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: latestSleep?.sleepEfficiencyText ?? "--",
                                        detail: legendDetail("Sleep"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .rhr:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.restingHeartRateText,
                                        detail: legendDetail("bpm"),
                                        systemImage: metric.systemImage,
                                        tint: .pink,
                                        layoutSize: layoutSize(for: metric))
        case .respiratoryRate:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: latestRollup?.respiratoryRate.map { String(format: "%.1f", $0) } ?? "--",
                                        detail: legendDetail("/min"),
                                        systemImage: metric.systemImage,
                                        tint: .teal,
                                        layoutSize: layoutSize(for: metric))
        case .steps:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "Building",
                                        detail: legendDetail(strapValue),
                                        systemImage: metric.systemImage,
                                        tint: liveStore.state.status == .connected ? .green : .secondary,
                                        layoutSize: layoutSize(for: metric))
        case .calories:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "Building",
                                        detail: legendDetail("Active"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .vo2max:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: profileMetricsStore.state.vo2MaxEstimate.valueText,
                                        detail: legendDetail("Estimate"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricGreen,
                                        layoutSize: layoutSize(for: metric))
        case .bioAge:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: profileMetricsStore.state.biologicalAgeSummary.valueText,
                                        detail: legendDetail("Estimate"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricGreen,
                                        layoutSize: layoutSize(for: metric))
        case .bloodOxygen:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "Building",
                                        detail: legendDetail("Signal"),
                                        systemImage: metric.systemImage,
                                        tint: .pink,
                                        layoutSize: layoutSize(for: metric))
        case .bodyTemp:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "Building",
                                        detail: legendDetail("Sleep"),
                                        systemImage: metric.systemImage,
                                        tint: .orange,
                                        layoutSize: layoutSize(for: metric))
        case .trend:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.loadSignalSummaryText,
                                        detail: legendDetail("Trend"),
                                        systemImage: metric.systemImage,
                                        tint: layoutConfig.accent.color,
                                        layoutSize: layoutSize(for: metric))
        case .insights:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "\(AtriaHighlights.topTwo(rollups: highlightRollups).count)",
                                        detail: legendDetail("Highlights"),
                                        systemImage: metric.systemImage,
                                        tint: layoutConfig.accent.color,
                                        layoutSize: layoutSize(for: metric))
        }
    }

    private func layoutSize(for metric: AtriaTodayMetric) -> AtriaTodayGlanceItem.LayoutSize {
        AtriaTodayGlanceItem.LayoutSize(rawValue: layoutConfig.sizeOverrides[metric.rawValue] ?? "compact") ?? .compact
    }

    /// Measured-perf pass (2026-07-05): `store.confirmedWorkouts` is already
    /// stored start-descending (see `readConfirmedWorkouts`/
    /// `saveConfirmedWorkouts`, Sessions.swift) and this and
    /// `latestConfirmedWorkoutOneLiner` are read on every glance-tile body
    /// eval, including every live-pulse re-render -- so both are memoized
    /// together behind `store.confirmedWorkoutsRevision`, and the "this
    /// week" scan stops as soon as it walks off the front of the window
    /// instead of filtering the whole (unbounded, all-time) array.
    private var thisWeekConfirmedWorkoutsCount: Int {
        refreshWorkoutsGlanceCacheIfNeeded()
        return glanceMemo.workoutsWeekCount ?? 0
    }

    private static let workoutDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private var latestConfirmedWorkoutOneLiner: String {
        refreshWorkoutsGlanceCacheIfNeeded()
        return glanceMemo.workoutsOneLiner ?? "No workouts yet"
    }

    private func refreshWorkoutsGlanceCacheIfNeeded() {
        let revision = store.confirmedWorkoutsRevision
        guard glanceMemo.workoutsRevision != revision else { return }
        let workouts = store.confirmedWorkouts
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        // Sorted start-descending, so everything still "this week" is a
        // contiguous run at the front -- no need to walk the rest of a
        // years-long workout history every eval.
        glanceMemo.workoutsWeekCount = workouts.prefix(while: { $0.start >= weekStart }).count
        if let latest = workouts.first {
            let title = latest.activitySubtype ?? latest.activityType ?? "Workout"
            let strainText = latest.strain.map { String(format: "%.1f strain", $0) }
            let dayText = Self.workoutDayFormatter.string(from: latest.start)
            glanceMemo.workoutsOneLiner = [title, strainText, dayText].compactMap { $0 }.joined(separator: " · ")
        } else {
            glanceMemo.workoutsOneLiner = "No workouts yet"
        }
        glanceMemo.workoutsRevision = revision
    }

    /// Strict 14-calendar-day window (excluding today, which is still live/incomplete).
    /// `highlightRollups` is already day-descending (store.dailyRollupHistory
    /// invariant; DEBUG fixture path matches it too), so this walks off the
    /// front instead of filtering the full (up to 400-entry) history.
    private var strainCompareWindowStrains: [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let cutoff = calendar.date(byAdding: .day, value: -14, to: today) else { return [] }
        return highlightRollups
            .drop { $0.day >= today }
            .prefix { $0.day >= cutoff }
            .compactMap { $0.strain }
    }

    /// Measured-perf pass (2026-07-05): memoized behind
    /// `store.dailyRollupHistoryRevision` so the filter+sort above only
    /// actually runs when the rollups change (at most a few times a day),
    /// not on every one of the many live-pulse body evals in between.
    private var strainCompareMedian: Double? {
        let revision = store.dailyRollupHistoryRevision
        if glanceMemo.strainMedianRevision == revision {
            return glanceMemo.strainMedianValue
        }
        let strains = strainCompareWindowStrains
        let median: Double?
        if strains.count >= 7 {
            let sorted = strains.sorted()
            let mid = sorted.count / 2
            median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        } else {
            median = nil
        }
        glanceMemo.strainMedianRevision = revision
        glanceMemo.strainMedianValue = median
        return median
    }

    private func metricIsPending(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var strainCompareDetailText: String {
        guard let median = strainCompareMedian else { return "Building baseline" }
        let medianText = String(format: "%.1f", median)
        guard !metricIsPending(displayHero.strainValue) else {
            return "14-day median \(medianText)"
        }
        let delta = displayHero.strain - median
        let comparison: String
        if abs(delta) < 0.5 {
            comparison = "in line"
        } else if delta < 0 {
            comparison = "below typical"
        } else {
            comparison = "above typical"
        }
        return "14-day median \(medianText) · \(comparison)"
    }

    private func legendDetail(_ detail: String) -> String {
        layoutConfig.legendStatStyle == .value ? "" : detail
    }

    private func recoveryState(percent: Int) -> String {
        switch percent {
        case 67...:
            return "Good"
        case 34..<67:
            return "Fair"
        default:
            return "Low"
        }
    }

    #if DEBUG
    private static func debugShowsAICoachLocalFixture(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && ["ai-coach-local", "ai-coach-flagged", "ai-coach-audit"].contains(arguments[valueIndex])
    }
    #endif
}

/// Read-through memo for the glance-tile derivations that are expensive to
/// recompute but only change when their source aggregate does (measured-perf
/// pass, 2026-07-05). A plain class (not `ObservableObject`/`@Published`)
/// held behind a single `@State` on `AtriaTodayScreen`: mutating its fields
/// during body evaluation is safe -- it isn't an observed property wrapper,
/// so it neither triggers nor implies a re-render, it's a pure cache. Each
/// cache entry is only valid when its paired revision still matches the
/// store's current one (`dailyRollupHistoryRevision` / `confirmedWorkoutsRevision`,
/// Sessions.swift), so a stale value is never served after the underlying
/// data actually changes.
private final class AtriaTodayGlanceMemo {
    var strainMedianRevision: Int?
    var strainMedianValue: Double?
    var workoutsRevision: Int?
    var workoutsWeekCount: Int?
    var workoutsOneLiner: String?
    var dayDescendingRevision: Int?
    var dayDescendingRollups: [DailyRollupStoreEntry]?
}

/// Isolates the Apple-Fitness-style hero scroll-shrink consumer (scale +
/// opacity applied to the ring hero content) in its own `View` so that
/// scroll-driven `heroShrinkProgress` writes only force *this* small view's
/// body to re-evaluate, instead of amplifying the churn back up into
/// `AtriaTodayScreen`'s body, which builds the whole rest of the screen
/// (glance grid, plan card, AI coach card, etc.) on every eval. `progress` is
/// still owned and driven by the parent's `.onScrollGeometryChange` (measured-
/// perf pass, 2026-07-05) -- this view is a pure pass-through consumer of it.
private struct AtriaTodayHeroShrink<Content: View>: View {
    let progress: CGFloat
    let minScale: CGFloat
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        return 1.0 - (1.0 - minScale) * progress
    }

    private var opacity: CGFloat {
        guard !reduceMotion else { return 1.0 }
        return 1.0 - 0.35 * progress
    }

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayHeroShrink")
        content()
            // Apple-Fitness-style scroll shrink -- scales/fades toward the
            // top edge only (never sideways) so the rings visually recede as
            // the user scrolls further content up over them. Reduce Motion
            // pins both to their resting values.
            .scaleEffect(scale, anchor: .top)
            .opacity(opacity)
    }
}

private struct AtriaTodayGlanceItem: Identifiable, Equatable {
    enum LayoutSize: String, Equatable {
        case compact
        case wide
        case wideShort

        var columnSpan: Int {
            switch self {
            case .compact: return 1
            case .wide, .wideShort: return 2
            }
        }

        var minHeight: CGFloat {
            switch self {
            case .wide: return 94
            case .compact, .wideShort: return 74
            }
        }
    }

    let title: String
    let metricKey: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let layoutSize: LayoutSize

    var id: String { metricKey }
}

private struct AtriaTodayLiveStatusStrip: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let pulse: AtriaHomeModel.HeroPulseState

    var body: some View {
        HStack(spacing: 10) {
            AtriaTodayLivePill(title: "Live",
                               value: liveStatusText,
                               systemImage: pulse.heartRate > 0 ? "heart.fill" : "dot.radiowaves.left.and.right",
                               tint: pulse.heartRate > 0 ? .green : .secondary)
            AtriaTodayLivePill(title: "Zone",
                               value: pulse.heartRateZone?.shortLabel ?? "Building",
                               systemImage: "waveform.path.ecg",
                               tint: pulse.heartRateZone?.tint ?? .secondary)
            AtriaTodayLivePill(title: "Battery",
                               value: live.batteryText,
                               systemImage: live.batterySymbol,
                               tint: live.batteryLevel >= 0 ? .blue : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live status. \(pulse.heartRate > 0 ? "\(pulse.heartRate) beats per minute" : live.status.rawValue). Zone \(pulse.heartRateZone?.shortLabel ?? "building"). Battery \(live.batteryText).")
    }

    private var liveStatusText: String {
        if pulse.heartRate > 0 { return "\(pulse.heartRate) bpm" }
        switch live.status {
        case .connected: return "Live"
        case .connecting, .scanning: return "Finding"
        case .disconnected: return "Off"
        case .poweredOff: return "BT off"
        }
    }
}

private struct AtriaTodayLivePill: View, Equatable {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaTodayLivePill, rhs: AtriaTodayLivePill) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.systemImage == rhs.systemImage
            && lhs.tint == rhs.tint
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AtriaTodayPlanCard: View, Equatable {
    let title: String
    let detail: String
    let target: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

            VStack(alignment: .leading, spacing: 3) {
                Text("Today's Plan")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // Sentence policy (perf/crop pass, 2026-07-05): this is a
                    // full guidance sentence ("Your strain matches what
                    // today's recovery can handle.") -- `lineLimit(1)` used
                    // to hard-truncate it mid-word ("...matches what tod…").
                    // `fixedSize` lets it wrap and grow the card instead of
                    // ever being clipped.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(target)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 104, alignment: .trailing)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12),
                            in: Capsule())
        }
        .padding(12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today's Plan. \(title). \(detail). \(target).")
    }
}

/// Compact strain-target progress card hosted directly under the ring hero.
/// The target itself is never computed here -- it is `Coach.guide`'s
/// existing recovery -> strain-target number (`displayHero.guidance.target`,
/// the same value already driving `strainMetric`'s ring fill, the ring's
/// legend chip, and the AI Coach narrative) passed straight through, so
/// there is exactly one strain-target formula in the app.
private struct AtriaStrainTargetCard: View, Equatable {
    let currentStrain: Double
    let target: Double?
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaStrainTargetCard, rhs: AtriaStrainTargetCard) -> Bool {
        lhs.currentStrain == rhs.currentStrain
            && lhs.target == rhs.target
            && lhs.tint == rhs.tint
    }

    private var progress: Double {
        guard let target, target > 0 else { return 0 }
        return min(max(currentStrain / target, 0), 1.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Strain Target", systemImage: "flame.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let target {
                    Text(String(format: "%.1f / %.1f", currentStrain, target))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .foregroundStyle(tint)
                }
            }

            if let target {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(tint.opacity(0.15))
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 8)

                Text(progress >= 1
                     ? "Target reached for today."
                     : String(format: "%.1f to go.", max(target - currentStrain, 0)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                // Honest learning state: recovery isn't trusted yet, so
                // there is no real target to show progress against --
                // never a fabricated placeholder bar.
                Text("Target appears once recovery is trusted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            // Same secondary-surface + tint-stroke chrome as the glance
            // tiles and weekly-plan card it sits beside, instead of the
            // flatter tertiary card the info rows use -- this is a live
            // metric widget, not a passive row.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(target.map { "Strain target. \(String(format: "%.1f of %.1f", currentStrain, $0))." }
                             ?? "Strain target. Target appears once recovery is trusted.")
    }
}

private struct AtriaTodayWeeklyPlanCard: View, Equatable {
    let plan: WeeklyPlan
    let onOpenReport: () -> Void

    static func == (lhs: AtriaTodayWeeklyPlanCard, rhs: AtriaTodayWeeklyPlanCard) -> Bool {
        lhs.plan == rhs.plan
    }

    var body: some View {
        Button(action: onOpenReport) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("This week")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("W\(plan.isoWeek)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 10) {
                    ForEach(Array(plan.targets.prefix(3))) { target in
                        AtriaTodayWeeklyPlanTargetRow(target: target)
                    }
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Metrics.electricStrain.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the weekly report.")
    }

    private var accessibilityText: String {
        let targets = plan.targets.prefix(3).map { "\($0.title), \($0.progressText)" }.joined(separator: ". ")
        return "This week. \(targets)"
    }
}

private struct AtriaTodayWeeklyPlanTargetRow: View, Equatable {
    let target: WeeklyPlanTarget

    private var tint: Color {
        switch target.kind {
        case .bedtimeConsistency: return Metrics.electricSleep
        case .workoutCount: return Metrics.electricStrain
        case .rhrInRange: return .pink
        }
    }

    private var icon: String {
        switch target.kind {
        case .bedtimeConsistency: return "moon.zzz.fill"
        case .workoutCount: return "figure.run"
        case .rhrInRange: return "heart.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: tint))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(target.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6)
                    Text(target.progressText)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }

                Gauge(value: target.progress) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
                .accessibilityHidden(true)

                Text(target.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.title). \(target.progressText). \(target.detail).")
    }
}

private struct AtriaTodayGlanceTile: View, Equatable {
    let item: AtriaTodayGlanceItem

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaTodayGlanceTile, rhs: AtriaTodayGlanceTile) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayGlanceTile")
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: item.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(item.tint)
                .frame(width: 24, height: 24)
            Text(item.value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(item.title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !item.detail.isEmpty && item.layoutSize != .wideShort {
                Text(item.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, minHeight: item.layoutSize.minHeight, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title). \(item.value). \(item.detail).")
    }
}

private struct AtriaTodayInfoRow: View, Equatable {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: tint))
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct AtriaTodayShortcutStrip: View, Equatable {
    let journalValue: String
    let onOpenJournal: () -> Void
    let onOpenShare: () -> Void
    let onStartWorkout: () -> Void

    static func == (lhs: AtriaTodayShortcutStrip, rhs: AtriaTodayShortcutStrip) -> Bool {
        lhs.journalValue == rhs.journalValue
    }

    var body: some View {
        HStack(spacing: 8) {
            AtriaTodayActionRow(title: "Journal",
                                value: journalValue,
                                systemImage: "square.and.pencil",
                                tint: .teal,
                                compact: true,
                                action: onOpenJournal)
            AtriaTodayActionRow(title: "Start",
                                value: "Activity",
                                systemImage: "plus",
                                tint: .blue,
                                compact: true,
                                action: onStartWorkout)
            AtriaTodayActionRow(title: "Share",
                                value: "Story",
                                systemImage: "square.and.arrow.up",
                                tint: .purple,
                                compact: true,
                                action: onOpenShare)
        }
    }
}

private struct AtriaTodayHighlightsStrip: View, Equatable {
    let highlights: [AtriaHighlight]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(highlights) { highlight in
                HStack(spacing: 10) {
                    Image(systemName: highlight.systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(highlight.tint)
                        .frame(width: 24, height: 24)

                    Text(highlight.valuePhrase)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(highlight.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)

                    Text(highlight.sentence)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(2)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(highlight.valuePhrase) \(highlight.sentence)")
            }
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AtriaTodayActionRow: View, Equatable {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    var compact = false
    let action: () -> Void

    static func == (lhs: AtriaTodayActionRow, rhs: AtriaTodayActionRow) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.systemImage == rhs.systemImage
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 50 : 54, alignment: .leading)
            .padding(.horizontal, compact ? 10 : 12)
            .background(Color(uiColor: .tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
