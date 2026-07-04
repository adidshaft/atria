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
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0

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
        HStack {
            Spacer(minLength: 0)
            Menu {
                Button(action: onCustomizeToday) {
                    Label("Customize Today", systemImage: "slider.horizontal.3")
                }
                Button(action: onOpenShare) {
                    Label("Share Today", systemImage: "square.and.arrow.up")
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
            AtriaTriRing(sleep: sleepMetric,
                         recovery: recoveryMetric,
                         strain: strainMetric,
                         centerValue: centerValue,
                         centerState: centerState,
                         centerDelta: centerDeltaText,
                         accessibilitySummary: accessibilitySummary,
                         ringOrder: ringOrder,
                         onSleep: { metricDetail = .sleep },
                         onRecovery: { metricDetail = .recovery },
                         onStrain: { metricDetail = .strain })

            ringShareButton
        }
    }

    /// Small, discoverable "share as picture" affordance hosted right under
    /// the ring hero -- same idea as the Face-Off story-image share button,
    /// just local to this card instead of a separate sheet.
    @ViewBuilder
    private var ringShareButton: some View {
        // Rendered on demand: rasterizing the 1080x1350 card is main-thread
        // work, so it happens once per tap, never per live metric tick.
        if let ringShareImage {
            ShareLink(item: Image(uiImage: ringShareImage),
                      preview: SharePreview("Atria \(ringShareContent.dateText)",
                                            image: Image(uiImage: ringShareImage))) {
                Label("Share as picture", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button {
                ringShareImage = AtriaRingShare.renderImage(ringShareContent)
            } label: {
                Label("Share as picture", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .onChange(of: ringShareSignature) { _, _ in
                ringShareImage = nil
            }
        }
    }

    private var ringShareContent: AtriaRingShare.Content {
        AtriaRingShare.Content(sleep: sleepMetric,
                               recovery: recoveryMetric,
                               strain: strainMetric,
                               centerValue: centerValue,
                               centerState: centerState,
                               ringOrder: ringOrder,
                               dateText: Self.ringShareDateFormatter.string(from: Date()))
    }

    private var ringShareSignature: String {
        [sleepMetric.value, recoveryMetric.value, strainMetric.value,
         centerValue, centerState, ringOrder.map(\.rawValue).joined(separator: ",")]
            .joined(separator: "|")
    }

    private static let ringShareDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    /// Which of the three known ring metrics draws on the outer/middle/inner
    /// band. Persisted the same way other single-value layout prefs are
    /// (an `@AtriaDefault`-backed comma-joined string), independent of the
    /// separate `AtriaHomeLayoutConfig` JSON blob so this stays inside this
    /// screen's own file. Defaults to the original sleep/recovery/strain
    /// (outer to inner) layout.
    @AtriaDefault("atria.today.ringOrder") private var ringOrderRaw: String = "sleep,recovery,strain"

    private var ringOrder: [AtriaTriRingSlot] {
        var seen = Set<AtriaTriRingSlot>()
        var result = ringOrderRaw
            .split(separator: ",")
            .compactMap { AtriaTriRingSlot(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        for slot in AtriaTriRingSlot.defaultOrder where !result.contains(slot) {
            result.append(slot)
        }
        return Array(result.prefix(3))
    }

    private func rotateRingOrder() {
        var order = ringOrder
        guard order.count == 3 else {
            ringOrderRaw = AtriaTriRingSlot.defaultOrder.map(\.rawValue).joined(separator: ",")
            return
        }
        order.append(order.removeFirst())
        ringOrderRaw = order.map(\.rawValue).joined(separator: ",")
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
                                           loadNarrative: "Training load appears after local strain history builds.")
    }
    #endif

    private var latestSleep: SleepHistorySnapshot.Night? {
        store.sleepHistorySnapshot.latest
    }

    private var sleepMetric: AtriaTriRingMetric {
        let performance = latestRollup?.sleepPerformance
        let value = latestSleep?.durationText ?? performance.map { "\($0)%" } ?? "Building"
        let detail = performance.map { "\($0)% need" } ?? "Sleep"
        return AtriaTriRingMetric(title: "Sleep",
                                  value: value,
                                  detail: detail,
                                  systemImage: "moon.fill",
                                  tint: Metrics.electricSleep,
                                  fill: performance.map { min(max(Double($0) / 100.0, 0), 1) })
    }

    private var recoveryMetric: AtriaTriRingMetric {
        let percent = displayHero.recoveryEstimate.percent
        return AtriaTriRingMetric(title: "Recovery",
                                  value: displayHero.recoveryValue,
                                  detail: displayHero.recoveryLiftedAfterNap ? "↑ after nap" : displayHero.recoveryDetail,
                                  systemImage: "arrow.clockwise.heart.fill",
                                  tint: percent.map(Metrics.recoveryColor) ?? .secondary,
                                  fill: percent.map { Double($0) / 100.0 })
    }

    private var strainMetric: AtriaTriRingMetric {
        let target = displayHero.guidance.target ?? 15
        return AtriaTriRingMetric(title: "Strain",
                                  value: displayHero.strainValue,
                                  detail: String(format: "of %.0f", target),
                                  systemImage: "flame.fill",
                                  tint: Metrics.electricStrain,
                                  fill: min(max(displayHero.strain / max(target, 0.1), 0), 1.2))
    }

    private var latestRollup: DailyRollupStoreEntry? {
        highlightRollups.sorted { $0.day > $1.day }.first
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
            return displayHero.recoveryEstimate.percent.map { "\($0)%" } ?? "Day 1"
        case .sleep:
            return latestRollup?.sleepPerformance.map { "\($0)%" } ?? sleepMetric.value
        case .strain:
            return strainMetric.value
        }
    }

    private var centerState: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            return displayHero.recoveryEstimate.percent.map(recoveryState) ?? "Building"
        case .sleep:
            return latestRollup?.sleepPerformance.map { "\($0)% need" } ?? sleepMetric.detail
        case .strain:
            return strainMetric.detail
        }
    }

    /// Prior day's rollup, used only for the ring hero's tiny center delta.
    /// Nil whenever there isn't a distinct prior day on record -- the delta
    /// is omitted rather than fabricated in that case.
    private var previousRollup: DailyRollupStoreEntry? {
        let sorted = highlightRollups.sorted { $0.day > $1.day }
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

    private var accessibilitySummary: String {
        "Sleep \(sleepMetric.value), Recovery \(recoveryMetric.value) \(recoveryMetric.detail), Strain \(strainMetric.value) \(strainMetric.detail)."
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
            "strain": .init(low: 0, high: displayHero.guidance.target ?? 21),
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: item.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(item.tint)
                .frame(width: 24, height: 24)
            Text(item.value)
                .font(.subheadline.weight(.bold))
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
