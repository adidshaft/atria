import SwiftUI
import UIKit
import Combine

struct AtriaTodaySessionState: Equatable {
    private struct BaselineSampleKey: Equatable {
        let date: Date
        let restingHeartRate: Double
        let rmssd: Double?
        let overnight: Bool?
    }

    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let confirmedWorkouts: [UserConfirmedWorkout]
    let confirmedWorkoutsRevision: Int
    /// Confirmed sleeps for the metric-detail day sheet's history model
    /// (2026-07-31 audit item 11). Change-tracked by
    /// `sleepHistorySnapshotRevision`, which every confirmed-sleep write bumps.
    let confirmedSleeps: [UserConfirmedSleep]
    let behaviorImpactSummaries: [BehaviorImpactSummary]
    let behaviorInsights: [AtriaInsight]
    let baseline: PersonalBaseline
    let sleepHistorySnapshot: SleepHistorySnapshot
    let sleepHistorySnapshotRevision: Int
    let maxHeartRate: Int
    let skinTemperatureDeviationSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    let behaviorJournalEntries: [BehaviorJournalEntry]
    let behaviorJournalRevision: Int
    let journalAnswersRevision: Int
    let todayJournalAnswers: [String: AtriaJournalAnswer]
    let localDay: Date
    let restingTrend14: [Int]
    let weeklyPlan: WeeklyPlan
    private let baselineSamplesKey: [BaselineSampleKey]

    @MainActor
    init(store: SessionStore,
         now: Date = Date(),
         calendar: Calendar = .current) {
        localDay = calendar.startOfDay(for: now)
        dailyRollupHistory = store.dailyRollupHistory
        dailyRollupHistoryRevision = store.dailyRollupHistoryRevision
        confirmedWorkouts = store.confirmedWorkouts
        confirmedWorkoutsRevision = store.confirmedWorkoutsRevision
        confirmedSleeps = store.confirmedSleeps
        behaviorImpactSummaries = store.behaviorImpactSummariesCache
        behaviorInsights = store.behaviorInsights
        baseline = store.baseline
        baselineSamplesKey = store.baseline.samples.map {
            BaselineSampleKey(date: $0.date,
                              restingHeartRate: $0.restingHR,
                              rmssd: $0.rmssd,
                              overnight: $0.overnight)
        }
        sleepHistorySnapshot = store.sleepHistorySnapshot
        sleepHistorySnapshotRevision = store.sleepHistorySnapshotRevision
        maxHeartRate = store.profile.maxHR
        skinTemperatureDeviationSummary = store.skinTemperatureDeviationSummary
        behaviorJournalEntries = store.behaviorJournalEntries
        behaviorJournalRevision = store.behaviorJournalRevision
        journalAnswersRevision = store.journalAnswersRevision
        todayJournalAnswers = store.journalAnswers.answersByQuestion(for: localDay,
                                                                     calendar: calendar)
        restingTrend14 = store.restingTrend14
        weeklyPlan = store.currentWeeklyPlan()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.confirmedWorkoutsRevision == rhs.confirmedWorkoutsRevision
            && lhs.behaviorImpactSummaries == rhs.behaviorImpactSummaries
            && lhs.behaviorInsights == rhs.behaviorInsights
            && lhs.baselineSamplesKey == rhs.baselineSamplesKey
            && lhs.baseline.restingHR == rhs.baseline.restingHR
            && lhs.baseline.hrvEMA == rhs.baseline.hrvEMA
            && lhs.baseline.sessions == rhs.baseline.sessions
            && lhs.baseline.updated == rhs.baseline.updated
            && lhs.sleepHistorySnapshotRevision == rhs.sleepHistorySnapshotRevision
            && lhs.maxHeartRate == rhs.maxHeartRate
            && lhs.skinTemperatureDeviationSummary == rhs.skinTemperatureDeviationSummary
            && lhs.behaviorJournalRevision == rhs.behaviorJournalRevision
            && lhs.journalAnswersRevision == rhs.journalAnswersRevision
            && lhs.localDay == rhs.localDay
            && lhs.restingTrend14 == rhs.restingTrend14
            && lhs.weeklyPlan == rhs.weeklyPlan
    }
}

@MainActor
final class AtriaTodaySessionProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaTodaySessionState

    private let store: SessionStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false
    private var pendingFullRefresh = false

    init(store: SessionStore) {
        self.store = store
        state = AtriaTodaySessionState(store: store)

        Publishers.MergeMany([
            store.$dailyRollupHistory.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$sleepHistorySnapshot.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorImpactSummariesCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorInsights.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$baseline.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$profile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$imuAuditSummary.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$restingTrend14.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$journalAnswersRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .map { _ in () }
                .eraseToAnyPublisher(),
        ])
        .sink { [weak self] in self?.scheduleRefresh(full: true) }
        .store(in: &cancellables)

        // Confirmed workouts and journal entries have no dedicated publisher,
        // so they still arrive through SessionStore's broad dashboard signal.
        // Most dashboard bumps are unrelated to Today (backup state, dismissed
        // candidates, diagnostics). Compare the two authoritative revisions
        // before rebuilding/copying the full projection snapshot.
        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh(full: false) }
            .store(in: &cancellables)
    }

    @discardableResult
    func refresh() -> Bool {
        let next = AtriaTodaySessionState(store: store)
        guard next != state else { return false }
        state = next
        return true
    }

    @discardableResult
    func refreshForDashboardRevision() -> Bool {
        guard store.confirmedWorkoutsRevision != state.confirmedWorkoutsRevision
                || store.behaviorJournalRevision != state.behaviorJournalRevision else {
            return false
        }
        return refresh()
    }

    private func scheduleRefresh(full: Bool) {
        pendingFullRefresh = pendingFullRefresh || full
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldRefreshFully = self.pendingFullRefresh
            self.pendingFullRefresh = false
            self.refreshScheduled = false
            if shouldRefreshFully {
                self.refresh()
            } else {
                self.refreshForDashboardRevision()
            }
        }
    }
}

struct AtriaTodayScreen: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    // Lifetime reference only. Live HeroStore publishes are observed by the
    // narrow AtriaTodayHeroProjectionHost leaves below, so a 1.5-second strain
    // update cannot invalidate this section-order/lazy-container view.
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @ObservedObject var sessionProjectionStore: AtriaTodaySessionProjectionStore
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
    /// The Home owner persists the layout. Today only proposes small, local
    /// presentation changes (add, remove, reorder), so it never subscribes to
    /// the noisy dotted UserDefaults key directly.
    let onLayoutConfigChange: (AtriaHomeLayoutConfig) -> Void
    let onCustomizeToday: () -> Void
    /// The workout/sleep review items, built by AtriaHomeView (which owns
    /// their state) and rendered INSIDE the plan section — the user's strict
    /// rule (2026-07-07): one notifications block, max 3 items (workout,
    /// sleep, plan).
    var systemNotifications: AnyView? = nil
    @State private var metricDetail: AtriaMetricDetailKind?
    @State private var draggingSection: AtriaTodaySection?
    // User-arranged order of the big sections below the ring (2026-07-07
    // user feedback: "let people drag drop and arrange entire big sections").
    @AtriaDefault("atria.today.sectionOrder") private var todaySectionOrderCSV: String = ""
    // Same shared preference Settings > Personal and the Customize sheet
    // write, so the ring layout switches from any of the three surfaces.
    @AtriaDefault(AtriaRingLayoutStyle.defaultsKey) private var ringLayoutRaw: String = "concentric"
    @State private var showWeeklyReport = false
    @State private var showInsights = false
    @State private var showBreathworkSession = false
    // Dedicated sheet for the Strap-steps tile (2026-08-08): the steps tile is
    // rendered by AtriaTodayLiveGlanceTileHost, which had no tap affordance, so
    // tapping it dead-ended and there was no way to view step history. Reuses
    // the existing AtriaStrapStepsDetailSheet — no new AtriaMetricDetailKind
    // case (that enum is switched on ~30 sites). Mirrors showBreathworkSession.
    @State private var showStrapStepsDetail = false
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @State private var isEditingGlance = false
    @State private var showAddGlanceMetrics = false
    @State private var ringShareRoute: AtriaRingShareRoute?
    // Apple-Fitness-style scroll shrink state now lives inside
    // `AtriaTodayHeroShrink` (perf pass, 2026-07-06): it owns its own
    // `progress` @State and the `.onScrollGeometryChange` observation, so
    // per-scroll-step writes invalidate only that small view -- this parent
    // body (ring construction, glance grid, plan/coach cards) no longer reads
    // any scroll-shrink state and so no longer re-evaluates on every scroll
    // quantum. Completes the isolation commit 28797998 started.
    /// Read-through cache for glance-tile derivations that are expensive to
    /// recompute (filters/sorts over rollup or workout history) but only
    /// change when the underlying aggregate actually changes -- see
    /// `AtriaTodayGlanceMemo` (measured-perf pass, 2026-07-05). Held in
    /// `@State` (not a plain `let`) so the reference -- and therefore the
    /// cache inside it -- survives AtriaTodayScreen being value-recreated by
    /// AtriaHomeView on every live-pulse tick.
    @State private var glanceMemo = AtriaTodayGlanceMemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AtriaDefault("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AtriaDefault("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AtriaDefault("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AtriaDefault("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    /// Optional display name set elsewhere in the app. Empty -- the default
    /// -- means no greeting is shown; never a fabricated name.
    @AtriaDefault("atria.user.nickname") private var nickname: String = ""
    @AtriaDefault(AtriaTrackedBehaviors.storageKey) private var trackedBehaviorsRaw: String = ""
    // Glance layout: false = 2-up box grid (default), true = one full-width
    // horizontal bar per metric. The "boxes vs bars" user choice.
    @AtriaDefault("atria.overview.glanceLayoutBars") private var glanceLayoutBars: Bool = false

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayScreen")
        // The dashboard owns a small, bounded set of major sections. Keep this
        // stack eager so the enclosing physical ScrollView receives the final
        // content height up front. A LazyVStack here has repeatedly truncated
        // the reachable device scroll range before the Strap steps card.
        VStack(spacing: 16) {
            if debugShowsAICoachOnly {
                AtriaTodayHeroProjectionHost(heroStore: heroStore) { _ in
                    AtriaAICoachCard(context: coachContext,
                                     preparedPayload: coachPayload,
                                     settings: effectiveAICoachSettings,
                                     hasAPIKey: aiCoachHasAPIKey)
                }
            } else if AtriaOverviewBehaviorJournalSection.debugShowsImpactOnlyFixture {
                AtriaOverviewBehaviorJournalSection(store: store)
            } else {
            // The tri-ring hero (IA-6.1, static-check gated) is the one and
            // only glance-first summary on this screen. A fixed 3-tile
            // "glance strip" used to sit above it showing the same
            // sleep/recovery/strain numbers a second time -- pure
            // duplication -- and was removed; the ring hero plus its legend
            // chips are now the single source of truth for those values.
            todayHeader
            AtriaTodayHeroProjectionHost(heroStore: heroStore) { _ in
                triRingHero
                    .preference(key: AtriaTodayCompactRingPreferenceKey.self,
                                value: compactRingPresentation)
            }
            // Says what the app is doing with last night instead of saying
            // nothing while it settles. Sits under the hero because it is about
            // the night the ring is already showing.
            sleepSettlementRow

            // Shown only when the system route could not deliver this morning's
            // nudge. A notification the user switched off deliberately does NOT
            // reach here -- honouring that toggle is the point of it.
            if !layoutConfig.showPlan {
                journalFallbackPrompt
            }

            if layoutConfig.showLiveStrip {
                AtriaTodayLiveStatusHost(liveStore: liveStore,
                                         pulseStore: pulseStore)
            }

            if layoutConfig.showHighlights && !highlights.isEmpty {
                AtriaTodayHighlightsStrip(highlights: highlights) { metric in
                    metricDetail = metric
                }
            }

            // Cognitive-relief grouping (UX audit 2026-07-07) + user-arranged
            // big sections (user feedback 2026-07-07): the major blocks below
            // the ring render in a persisted order and reorder by
            // long-press-drag. Kickers travel with their sections.
            ForEach(orderedTodaySections) { section in
                todaySection(section)
                    .onDrag {
                        draggingSection = section
                        return NSItemProvider(object: section.rawValue as NSString)
                    }
                    .onDrop(of: [.text],
                            delegate: AtriaTodaySectionDropDelegate(item: section,
                                                                    order: todaySectionOrderBinding,
                                                                    dragging: $draggingSection))
            }

            }
        }
        .sheet(item: $metricDetail) { detail in
            AtriaTodayHeroProjectionHost(heroStore: heroStore) { _ in
                AtriaMetricDetailSheet(metric: detail,
                                       rollups: highlightRollups,
                                       rollupsRevision: sessionProjectionStore.state.dailyRollupHistoryRevision,
                                       confirmedWorkouts: debugMetricDetailWorkouts ?? sessionProjectionStore.state.confirmedWorkouts,
                                       confirmedWorkoutsRevision: debugMetricDetailWorkouts == nil ? sessionProjectionStore.state.confirmedWorkoutsRevision : nil,
                                       confirmedSleeps: sessionProjectionStore.state.confirmedSleeps,
                                       behaviorImpacts: sessionProjectionStore.state.behaviorImpactSummaries,
                                       baseline: AtriaBaselineTargetSnapshot(sessionProjectionStore.state.baseline),
                                       sleepHistory: sessionProjectionStore.state.sleepHistorySnapshot,
                                       sleepHistoryRevision: sessionProjectionStore.state.sleepHistorySnapshotRevision,
                                       guidance: displayHero.guidance,
                                       recoveryEstimate: displayHero.recoveryEstimate,
                                       currentCycleAuthority:
                                        AtriaHealthMetricAuthority.currentCycleProjection(
                                            hero: displayHero,
                                            sleepHistory: sessionProjectionStore.state.sleepHistorySnapshot
                                        ),
                                       sleepGoalHours: sleepGoalHours,
                                       sleepBaseNeedHours: sleepBaseNeedHours,
                                       hrZoneMinutes: displayHero.hrZoneMinutes,
                                       maxHeartRate: sessionProjectionStore.state.maxHeartRate,
                                       vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                                       skinTemperatureDeviation: sessionProjectionStore.state.skinTemperatureDeviationSummary,
                                       provenance: provenance(for: detail))
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showInsights) {
            ScrollView {
                AtriaInsightsCardHost(store: store)
                    .padding(AtriaDesignTokens.Spacing.lg)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showStrapStepsDetail) {
            AtriaStrapStepsDetailSheet(count: liveStore.state.strapStepResearchCount,
                                       validationState: liveStore.state.strapStepResearchState,
                                       presentation: liveStore.state.dailyStepPresentation,
                                       goal: stepsGoal)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWeeklyReport) {
            AtriaWeeklyReportSheet(report: weeklyReport,
                                   rollups: highlightRollups)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddGlanceMetrics) {
            AtriaTodayAddMetricsSheet(selectedKeys: layoutConfig.validated().glanceMetrics,
                                      onToggle: { metric, isSelected in
                var config = layoutConfig
                if isSelected {
                    guard !config.glanceMetrics.contains(metric.rawValue),
                          config.glanceMetrics.count < AtriaHomeLayoutConfig.maxTodayCards else { return }
                    config.glanceMetrics.append(metric.rawValue)
                } else {
                    config.glanceMetrics.removeAll { $0 == metric.rawValue }
                }
                onLayoutConfigChange(config)
            })
        }
        .sheet(item: $ringShareRoute) { route in
            AtriaShareSheet(snapshot: route.snapshot)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showBreathworkSession) {
            AtriaTodayBreathworkSessionHost(pulseStore: pulseStore,
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

    private static let heroMinScale: CGFloat = 0.6

    /// Time-of-day-aware "Good morning/afternoon/evening, <name>" line shown
    /// above the ring hero -- nil (and simply omitted) whenever no nickname
    /// has been set, never a placeholder greeting.
    // Perf (docs/26 follow-up): cached once instead of building a fresh
    // autoupdating Calendar (NSCalendar + locale lookup) on every Today body
    // pass (~700ms live tick + scroll). Coarse morning/afternoon/evening bucket.
    private static let greetingCalendar = Calendar.current

    private var greetingText: String? {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hour = Self.greetingCalendar.component(.hour, from: Date())
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
            return Array(repeating: GridItem(.flexible(), spacing: AtriaDesignTokens.Spacing.md), count: 3)
        }
        return Array(repeating: GridItem(.flexible(), spacing: AtriaDesignTokens.Spacing.md), count: 2)
    }

    private var glanceColumnCount: Int {
        horizontalSizeClass == .regular ? 3 : 2
    }

    private func glanceColumnSpan(for metric: AtriaTodayMetric) -> Int {
        min(layoutSize(for: metric).columnSpan, glanceColumnCount)
    }

    /// Route audit (visibilitySpec §3, 2026-07-05): every glance tile used to
    /// dead-end on tap except Stress -- and even that was broken (see below),
    /// so in practice ALL of them dead-ended. Maps each metric to the detail
    /// kind it should open. Stress, Strap steps, and Insights use the dedicated
    /// routes immediately below; tiles with no honest detail yet (load,
    /// workouts, calories, trend) are intentionally left out rather than routed
    /// to a placeholder.
    private static let glanceDetailRoutes: [AtriaTodayMetric: AtriaMetricDetailKind] = [
        .recovery: .recovery,
        .strain: .strain,
        .strainCompare: .strain,
        .hrv: .hrv,
        .rhr: .restingHeartRate,
        .respiratoryRate: .respiratoryRate,
        .sleep: .sleep,
        .sleepHistory: .sleep,
        .sleepEfficiency: .sleep,
        .sleepPerformance: .sleepPerformance,
        .vo2max: .vo2max,
        .bioAge: .fitnessAge,
        .bodyTemp: .skinTemperature,
        .hrZones: .hrZones,
        .bloodOxygen: .bloodOxygen
    ]

    /// Wraps a glance tile in whatever tap affordance it honestly supports.
    /// Stress keeps its dedicated breathwork shortcut (previously gated on a
    /// broken `item.id == "Stress"` string check -- `AtriaTodayMetric.stress`
    /// raw-values to `"stress"`, never the capitalized literal, so that
    /// branch never actually ran and Stress dead-ended along with everything
    /// else). Insights opens the canonical ranked-insights card. Everything else
    /// that has a real or honest-partial detail opens `metricDetail`; anything
    /// without one renders as a plain, non-tappable tile rather than a fake
    /// affordance.
    @ViewBuilder
    private func glanceTile(for item: AtriaTodayGlanceItem, isBar: Bool = false) -> some View {
        let metric = AtriaTodayMetric(rawValue: item.metricKey)
        if metric == .stress {
            Button {
                showBreathworkSession = true
            } label: {
                AtriaTodayGlanceTile(item: item, isBar: isBar)
            }
            .buttonStyle(.plain)
        } else if metric == .insights {
            Button {
                showInsights = true
            } label: {
                AtriaTodayGlanceTile(item: item, isBar: isBar)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows ranked local insights.")
        } else if let metric, let detail = Self.glanceDetailRoutes[metric] {
            Button {
                metricDetail = detail
            } label: {
                AtriaTodayGlanceTile(item: item, isBar: isBar)
            }
            .buttonStyle(.plain)
        } else {
            AtriaTodayGlanceTile(item: item, isBar: isBar)
        }
    }

    @ViewBuilder
    private func glanceTile(for metric: AtriaTodayMetric, isBar: Bool = false) -> some View {
        switch metric {
        case .steps:
            // Tappable → opens the strap-step detail/history sheet.
            Button {
                showStrapStepsDetail = true
            } label: {
                AtriaTodayLiveGlanceTileHost(metric: metric,
                                             liveStore: liveStore,
                                             layoutSize: layoutSize(for: metric),
                                             showsDetail: layoutConfig.legendStatStyle != .value,
                                             isBar: isBar)
            }
            .buttonStyle(.plain)
        case .calories:
            AtriaTodayLiveGlanceTileHost(metric: metric,
                                         liveStore: liveStore,
                                         layoutSize: layoutSize(for: metric),
                                         showsDetail: layoutConfig.legendStatStyle != .value,
                                         isBar: isBar)
        default:
            if let item = glanceItem(for: metric) {
                glanceTile(for: item, isBar: isBar)
            }
        }
    }

    /// The Today deck is its own editor: the same native long-press that starts
    /// a drag can be held in place to reveal removal controls. There is no
    /// second "Customize Today" destination on this surface.
    private func interactiveGlanceTile(for metric: AtriaTodayMetric,
                                       isBar: Bool = false) -> some View {
        glanceTile(for: metric, isBar: isBar)
            .overlay(alignment: .topTrailing) {
                if isEditingGlance {
                    Button(role: .destructive) {
                        removeGlanceMetric(metric)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3.weight(.bold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                    .padding(8)
                    .accessibilityLabel("Remove \(metric.label)")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip,
                                           style: .continuous))
            .onLongPressGesture(minimumDuration: 0.45) {
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    isEditingGlance = true
                }
            }
            // Drag only while EDITING (2026-08-05): always-on .draggable let a
            // scroll-adjacent touch lift a floating tile preview over the deck
            // (observed live on-device as a stuck hovering card) — reorder is
            // an edit-mode capability, matching the native Home Screen model.
            .draggableIf(isEditingGlance, metric.dragPayload)
            .dropDestination(for: String.self) { payloads, _ in
                guard let payload = payloads.first,
                      let dragged = AtriaTodayMetric.draggedMetric(from: payload),
                      dragged != metric else { return false }
                var config = layoutConfig
                config.moveGlanceMetric(dragged.rawValue, before: metric.rawValue)
                onLayoutConfigChange(config)
                return true
            }
            .accessibilityAction(named: Text("Move \(metric.label) up")) {
                shiftGlanceMetric(metric, direction: -1)
            }
            .accessibilityAction(named: Text("Move \(metric.label) down")) {
                shiftGlanceMetric(metric, direction: 1)
            }
    }

    private var glanceAddMetricControl: some View {
        Button {
            showAddGlanceMetrics = true
        } label: {
            Label("Add metric", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: AtriaDesignTokens.Radius.chip))
        .accessibilityHint("Shows metrics that are not currently on Today at a glance.")
    }

    private func removeGlanceMetric(_ metric: AtriaTodayMetric) {
        var config = layoutConfig
        config.glanceMetrics.removeAll { $0 == metric.rawValue }
        onLayoutConfigChange(config)
        if config.glanceMetrics.isEmpty {
            isEditingGlance = false
        }
    }

    private func shiftGlanceMetric(_ metric: AtriaTodayMetric, direction: Int) {
        var config = layoutConfig
        config.shiftGlanceMetric(metric.rawValue, direction: direction)
        onLayoutConfigChange(config)
    }

    private var orderedTodaySections: [AtriaTodaySection] {
        if glanceMemo.todaySectionOrderCSV == todaySectionOrderCSV,
           let cached = glanceMemo.todaySectionOrderValue {
            return cached
        }
        let value = Self.orderedTodaySections(from: todaySectionOrderCSV)
        glanceMemo.todaySectionOrderCSV = todaySectionOrderCSV
        glanceMemo.todaySectionOrderValue = value
        return value
    }

    static func orderedTodaySections(from csv: String) -> [AtriaTodaySection] {
        let stored = csv
            .split(separator: ",")
            .compactMap { AtriaTodaySection(rawValue: String($0)) }
        var seen = Set<AtriaTodaySection>()
        var order: [AtriaTodaySection] = []
        for section in stored where AtriaTodaySection.defaultOrder.contains(section) && !seen.contains(section) {
            order.append(section)
            seen.insert(section)
        }
        for section in AtriaTodaySection.defaultOrder where !order.contains(section) {
            order.append(section)
        }
        return order
    }

    private var todaySectionOrderBinding: Binding<[AtriaTodaySection]> {
        Binding(get: { orderedTodaySections },
                set: { todaySectionOrderCSV = $0.map(\.rawValue).joined(separator: ",") })
    }

    @ViewBuilder
    private func todaySection(_ section: AtriaTodaySection) -> some View {
        switch section {
        case .plan:
            if let systemNotifications {
                systemNotifications
            }

            if layoutConfig.showPlan {
                AtriaTodayHeroProjectionHost(heroStore: heroStore) { _ in
                    AtriaTodayPlanCard(title: planTitle,
                                       detail: planDetail,
                                       target: planTargetText,
                                       tint: displayHero.guidance.color,
                                       checkIn: journalCheckInProgress,
                                       notificationFallback: morningCheckInNeedsFallback,
                                       onOpenJournal: onOpenJournal)
                }
            }
        case .shortcuts:
            AtriaTodayShortcutStrip(onStartWorkout: onStartWorkout)
        case .weeklyPlan:
            if layoutConfig.showPlan {
                AtriaTodayWeeklyPlanCard(plan: weeklyPlan) {
                    showWeeklyReport = true
                }
            }
        case .glance:
            glanceKicker

            AtriaTodayHeroProjectionHost(heroStore: heroStore) { _ in
                Group {
                    if glanceLayoutBars {
                        // Bars layout: one full-width horizontal bar per metric.
                        VStack(spacing: AtriaDesignTokens.Spacing.md) {
                            ForEach(glanceMetrics) { metric in
                                interactiveGlanceTile(for: metric, isBar: true)
                            }
                            glanceAddMetricControl
                        }
                    } else {
                        LazyVGrid(columns: glanceColumns, spacing: AtriaDesignTokens.Spacing.md) {
                            ForEach(glanceMetrics) { metric in
                                interactiveGlanceTile(for: metric)
                                    .gridCellColumns(glanceColumnSpan(for: metric))
                            }
                            glanceAddMetricControl
                                .gridCellColumns(2)
                        }
                    }
                }
            }
            // This host deliberately ignores its content closure when comparing
            // HeroStore publications. Give layout changes their own identity so
            // an asynchronously restored Today configuration cannot leave the
            // initially empty glance body cached at zero height.
            .id(Self.glanceHostIdentity(
                for: layoutConfig,
                bars: glanceLayoutBars
            ))
        case .coach:
            if layoutConfig.showAICoach && effectiveAICoachSettings.mode != .off {
                AtriaTodayHeroProjectionHost(heroStore: heroStore) { _ in
                    AtriaAICoachCard(context: coachContext,
                                     preparedPayload: coachPayload,
                                     settings: effectiveAICoachSettings,
                                     hasAPIKey: aiCoachHasAPIKey)
                }
            }
        }
    }

    /// Tiny uppercase group kicker: enough structure to breathe, not a
    /// full header card (UX audit 2026-07-07).
    private func sectionKicker(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var glanceKicker: some View {
        HStack(spacing: 8) {
            sectionKicker("At a glance")
            Button {
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                    isEditingGlance.toggle()
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 32)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .accessibilityLabel(isEditingGlance ? "Finish editing At a glance" : "Edit At a glance")
            .accessibilityHint("Lets you drag cards to reorder and remove cards.")
        }
    }

    /// Greeting and actions share one compact header row. Keeping them as two
    /// vertically stacked rows spent 44 points on controls plus another stack
    /// gap before the hero, even though both belong to the same hierarchy.
    private var todayHeader: some View {
        HStack(spacing: 8) {
            if let greetingText {
                Text(greetingText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            topActionMenu
        }
    }

    private var topActionMenu: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ringShareToolbarButton
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .buttonBorderShape(.circle)
                Menu {
                    Button {
                        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                            glanceLayoutBars.toggle()
                        }
                    } label: {
                        Label(glanceLayoutBars ? "Show as grid" : "Show as bars",
                              systemImage: glanceLayoutBars ? "square.grid.2x2" : "rectangle.grid.1x2")
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
                    Picker(selection: $ringLayoutRaw) {
                        ForEach(AtriaRingLayoutStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    } label: {
                        Label("Ring Style", systemImage: "circle.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Today actions")
            }
        }
    }

    private var triRingHero: some View {
        let resolvedSlots = ringSlots.map {
            AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0))
        }
        return VStack(spacing: 10) {
            // Ring-metric-picker migration: each ring position resolves
            // through `ringSlots`/`metric(for:)` to whichever of the five
            // supported metrics (sleep/recovery/strain/hrv/rhr) the user
            // assigned it, via AtriaTriRing's new slots array API
            // (coordinated with the IA-6.1 static-check pin update in
            // test_handoff_static_checks.py -- see that file for the note
            // citing this migration).
            //
            // Perf pass (2026-07-06): `AtriaTodayHeroShrink` now OWNS the
            // scroll-shrink `progress` @State and the `.onScrollGeometryChange`
            // observation. Previously the progress lived on AtriaTodayScreen
            // and was read here, so every quantized scroll write re-evaluated
            // this whole property (ring construction + slot/metric plumbing)
            // AND the rest of the parent body. Now the per-step churn is fully
            // contained in the small child view -- the parent no longer reads
            // any scroll state, so it stops re-evaluating on scroll entirely.
            AtriaTodayHeroShrink(minScale: Self.heroMinScale) {
                AtriaTriRing(slots: resolvedSlots,
                             centerValue: centerValue,
                             centerState: centerState,
                             // Name the center's metric (2026-08-01 ring fix):
                             // the numeral follows the user's configurable
                             // center pick, so "7h 42m / 96% of need" must say
                             // it is Sleep the moment the state line doesn't.
                             centerMetricName: centerMetricName,
                             centerDelta: centerDeltaText,
                             accessibilitySummary: accessibilitySummary,
                             actions: ringActions)
            }
            // Strain Target card removed (user's strict screen-space rule,
            // 2026-07-07): strain appeared four times on one screen. The
            // strain legend chip carries value + target ("3.1 of 10.3") and
            // the plan card carries the guidance + remaining-to-target.
        }
    }

    private var compactRingPresentation: AtriaTodayCompactRingPresentation? {
        AtriaTodayCompactRingPresentation(
            slots: ringSlots.map { AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0)) },
            accessibilitySummary: accessibilitySummary
        )
    }

    /// Resolves whichever metric a ring slot currently carries. Reused by
    /// the hero, the share-as-picture render, and the accessibility
    /// summary so all three always agree.
    private func metric(for slot: AtriaTriRingSlot) -> AtriaTriRingMetric {
        var metric: AtriaTriRingMetric
        switch slot {
        case .sleep: metric = sleepMetric
        case .recovery: metric = recoveryMetric
        case .strain: metric = strainMetric
        case .hrv: metric = hrvMetric
        case .rhr: metric = restingHeartRateMetric
        }
        // Every ring chip keeps its own numeral, even the one whose slot is the
        // ring center. Suppressing the center metric's value left a value-less
        // chip (e.g. recovery showing only "provisional") sitting beside numeric
        // sleep/strain chips, which reads as "recovery has no score" — the exact
        // confusion a user reported. A mild numeral echo between the big ring and
        // its small chip is the lesser evil than an inconsistent, seemingly-empty
        // column. We still drop a word-for-word duplicate CAPTION of the center
        // (exact-match only), so a learning-state caption isn't shown twice.
        if slotMatchesRingCenter(slot), metric.detail == centerState {
            metric.suppressesDetail = true
        }
        return metric
    }

    private func slotMatchesRingCenter(_ slot: AtriaTriRingSlot) -> Bool {
        switch (slot, layoutConfig.ringCenterMetric) {
        case (.sleep, .sleep), (.recovery, .recovery), (.strain, .strain):
            return true
        default:
            return false
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
        // Rendered on demand: rasterizing the 1080x1920 card is main-thread
        // work. The shared composer performs that render after presentation,
        // never per live metric tick.
        Button {
            ringShareRoute = AtriaRingShareRoute(snapshot: ringShareSnapshot)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Share Atria ring")
    }

    private var ringShareSnapshot: AtriaShareSnapshot {
        let target = displayHero.guidance.target
        let strainIncomplete = dayStrainIsIncomplete
        let strainProgress = strainIncomplete ? nil : AtriaRingMetricProjection.strainTargetProgress(
            strain: displayHero.strain,
            target: target
        )
        let strainZone = strainIncomplete ? nil : ringStrainZone(target: target)
        return AtriaShareSnapshot(
            date: Date(),
            recovery: .init(title: "Recovery",
                            value: recoveryMetric.value,
                            detail: recoveryMetric.detail,
                            tintHex: AtriaRingMetricProjection.zoneTintHex(ringRecoveryZone?.level),
                            fill: recoveryMetric.fill),
        sleep: .init(title: "Sleep",
                         value: sleepMetric.value,
                         detail: sleepMetric.detail,
                         // Sleep uses percent-of-need zones rather than the generic
                         // achievement rule (which stays yellow until exact closure).
                         // Persist the same tint as the live ring so a confirmed 99%
                         // night cannot flash or remain yellow after projection reload.
                         tintHex: AtriaRingMetricProjection.sleepStateTintHex(
                            percent: sleepPerformancePercent.map(Double.init)
                         ) ?? AtriaRingMetricProjection.neutralTintHex,
                         fill: sleepMetric.fill,
                         stateTintHex: AtriaRingMetricProjection.sleepStateTintHex(
                            percent: sleepPerformancePercent.map(Double.init)
                         ),
                         targetFraction: sleepMetric.targetFraction),
            strain: .init(title: "Strain",
                          value: strainMetric.value,
                          detail: strainMetric.detail,
                          tintHex: AtriaRingMetricProjection.strainTintHex(
                            targetProgress: strainProgress,
                            actualFill: strainMetric.fill
                          ),
                          fill: strainMetric.fill,
                          stateTintHex: strainZone.map { AtriaRingMetricProjection.zoneTintHex($0.level) },
                          targetFraction: strainMetric.targetFraction),
            stats: [
                .init(id: "hrv", title: "HRV", value: hrvMetric.value, detail: hrvMetric.detail),
                .init(id: "rhr", title: "RHR", value: restingHeartRateMetric.value, detail: restingHeartRateMetric.detail)
            ]
        )
    }

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
        return sessionProjectionStore.state.dailyRollupHistory
    }

    /// Perf (docs/26 follow-up): `AtriaHighlights.topTwo` derives from the
    /// up-to-400-entry rollup history, and the body once invoked it up to 4x per
    /// pass on every ~700ms live tick / scroll. Memoized behind
    /// `store.dailyRollupHistoryRevision` like every neighboring rollup
    /// derivation, so it recomputes at most once per rollup change.
    /// Behavior-preserving.
    private var highlights: [AtriaHighlight] {
        let revision = sessionProjectionStore.state.dailyRollupHistoryRevision
        if glanceMemo.highlightsRevision == revision, let cached = glanceMemo.highlightsValue {
            return cached
        }
        let value = AtriaHighlights.topTwo(rollups: highlightRollups)
        glanceMemo.highlightsRevision = revision
        glanceMemo.highlightsValue = value
        return value
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
        // Keep the fixture anchored to the current week. WeeklyReport's
        // navigation deliberately uses its generated-at date, so fixed future
        // dates made the prior-week control look disabled in physical QA.
        let today = calendar.startOfDay(for: Date())
        let recoveries = [82, 71, 58, 43, 28, 67, 75,
                          74, 60, 48, 31, 69, 79, 56, 36]
        var rollups: [DailyRollupStoreEntry] = []
        for offset in recoveries.indices {
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let recovery = recoveries[offset]
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
        case "hrv-detail", "chart-options": return .hrv
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
        default:
            return nil
        }

        let recoveryPercent = 50
        let recovery = Metrics.RecoveryEstimate(percent: recoveryPercent,
                                                confidence: .personalBaseline,
                                                usesHRV: true,
                                                detail: "debug_strain_target",
                                                contributors: [])
        let guidance = Coach.guide(recovery: recovery, strain: strain, load: .learning)
        return AtriaHomeModel.HeroSnapshot(recoveryEstimate: recovery,
                                           recoveryIsProvisional: false,
                                           recoveryIsFromPreviousSleep: false,
                                           strain: strain,
                                           strainConfidence: "local",
                                           // Debug fixture pins strain-target
                                           // state only; coverage is not part of
                                           // what it proves, so it stays unmeasured.
                                           dayWearCoverageFraction: nil,
                                           guidance: guidance,
                                           hrvValue: "58",
                                           hrvDetail: "personal baseline",
                                           hrvNarrative: "Debug fixture: strain target state is fixed for visual proof.",
                                           stressLevel: .low,
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
        AtriaOverviewCurrentSleep.resolve(
            from: sessionProjectionStore.state.sleepHistorySnapshot
        )
    }

    /// Display-only sleep evidence may be newer than the confirmed night that
    /// owns Recovery and sleep-need math. Keeping the two projections separate
    /// lets a first-night candidate show its measured duration immediately
    /// without silently promoting it into physiological truth.
    /// Inputs for the wake-settlement row. Confirmed projections carry their
    /// durable save timestamp so freshness describes the save, not the wake.
    private var sleepSettlementRow: some View {
        let night = latestDisplaySleep
        let isConfirmed = night?.confirmed == true
        return AtriaTodaySleepSettlementRow(
            confirmedSleepEnd: isConfirmed ? night?.end : nil,
            confirmedSleepSavedAt: isConfirmed ? night?.savedAt : nil,
            candidateEnd: isConfirmed ? nil : night?.end
        )
    }

    /// In-app stand-in for a morning journal nudge that the system could not
    /// deliver. Previously the scheduler returned early on a denied
    /// authorization and nothing happened at all, so a permissions problem and a
    /// broken app looked identical from the outside.
    ///
    /// Deliberately silent unless the durable attempt record says the system
    /// route failed today: this is a fallback, not a second nudge, and it must
    /// never double up with a notification that did go out.
    @ViewBuilder
    private var journalFallbackPrompt: some View {
        if AtriaNotificationAttemptStore.needsInAppFallback(
            kind: LocalNotificationScheduler.morningCheckInKind
        ) {
            Button {
                onOpenJournal()
            } label: {
                HStack(spacing: AtriaDesignTokens.Spacing.md) {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.blue)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Morning check-in")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Notifications are off, so here it is instead.")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: AtriaDesignTokens.Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, AtriaDesignTokens.Spacing.md)
                .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.chip,
                                tint: .blue,
                                hueTinted: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Morning check-in. Notifications are off, so this prompt is shown instead. Opens the journal.")
        }
    }

    private var latestDisplaySleep: SleepHistorySnapshot.Night? {
        AtriaOverviewCurrentSleep.resolveDisplayEvidence(
            from: sessionProjectionStore.state.sleepHistorySnapshot
        )
    }

    /// Today reads the sleep ring, center caption, and sleep-performance tile
    /// several times per body pass. The underlying math scans recent sleep
    /// nights for debt and rollups for yesterday's strain, so cache it behind
    /// the existing source revisions instead of rebuilding it on live ticks.
    private var sleepNeedSnapshot: AtriaTodaySleepNeedSnapshot {
        let sleepHistory = sessionProjectionStore.state.sleepHistorySnapshot
        let latest = latestSleep
        let key = AtriaTodaySleepNeedKey(sleepRevision: sessionProjectionStore.state.sleepHistorySnapshotRevision,
                                         rollupRevision: sessionProjectionStore.state.dailyRollupHistoryRevision,
                                         latestNightID: latest?.id,
                                         displayNightID: latestDisplaySleep?.id,
                                         baseNeedHours: sleepBaseNeedHours)
        if glanceMemo.sleepNeedKey == key, let cached = glanceMemo.sleepNeedValue {
            return cached
        }
        let value: AtriaTodaySleepNeedSnapshot
        if latest == nil, latestDisplaySleep != nil {
            // A reviewable night may be shown as duration evidence, but an old
            // rollup's performance must not be attached to that new candidate.
            value = AtriaTodaySleepNeedSnapshot(needHours: nil,
                                                performancePercent: nil)
        } else {
            value = Self.makeSleepNeedSnapshot(sleepHistory: sleepHistory,
                                               latestSleep: latest,
                                               dayDescendingRollups: dayDescendingRollups,
                                               baseNeedHours: sleepBaseNeedHours)
        }
        glanceMemo.sleepNeedKey = key
        glanceMemo.sleepNeedValue = value
        return value
    }

    /// Real nightly need in hours, computed the same way the sleep-history
    /// screen's "Slept X of Y needed" line is (`sleepNeedHours`, which
    /// factors in yesterday's strain and any running sleep debt) -- only
    /// reachable when there's an actual `Night` on record. Nil otherwise, so
    /// callers fall back to the plainer stored `sleepPerformance` percent.
    private var sleepNeedHoursValue: Double? {
        sleepNeedSnapshot.needHours
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
            return "\(performance)% of need"
        }
        return "Sleep"
    }

    /// Single honest source for "percent of nightly need", wherever sleep
    /// shows a percent -- the ring fill/state-tint AND the ring-center "X% of
    /// need" caption (`centerState`). Computed the same live way as the
    /// hours-first value/detail above (`sleepNeedHoursValue`), from the same
    /// `latestSleep` night, so the percent a user sees can never disagree with
    /// the hours they see.
    ///
    /// Data-coherence fix (2026-07-05): this used to read the *stored*
    /// `latestRollup.sleepPerformance` (written once, against whatever
    /// duration/need was known at that write time) while the hours-first
    /// caption read the *live* `sleepHistorySnapshot` -- the two could
    /// disagree, seen on device as a chip reading "2h 57m of 9h 04m need"
    /// (~33%) alongside a "9% of need" caption. Falls back to the stored
    /// rollup value only when there's no `Night` on record at all yet.
    private var sleepPerformancePercent: Int? {
        sleepNeedSnapshot.performancePercent
    }

    private static func makeSleepNeedSnapshot(sleepHistory: SleepHistorySnapshot,
                                              latestSleep: SleepHistorySnapshot.Night?,
                                              dayDescendingRollups: [DailyRollupStoreEntry],
                                              baseNeedHours: Double,
                                              calendar: Calendar = .current) -> AtriaTodaySleepNeedSnapshot {
        guard let latestSleep else {
            return AtriaTodaySleepNeedSnapshot(needHours: nil,
                                               performancePercent: dayDescendingRollups.first?.sleepPerformance)
        }
        let yesterdayStrain = Self.yesterdayStrain(for: latestSleep,
                                                   dayDescendingRollups: dayDescendingRollups,
                                                   calendar: calendar)
        let need = sleepHistory.sleepNeedHours(for: latestSleep,
                                               baseNeedHours: baseNeedHours,
                                               yesterdayStrain: yesterdayStrain,
                                               calendar: calendar)
        return AtriaTodaySleepNeedSnapshot(needHours: need,
                                           performancePercent: need.map {
                                               AtriaSleepBudget.performancePercent(slept: latestSleep.durationHours,
                                                                                   needed: $0)
                                           })
    }

    private static func yesterdayStrain(for latestSleep: SleepHistorySnapshot.Night,
                                        dayDescendingRollups: [DailyRollupStoreEntry],
                                        calendar: Calendar = .current) -> Double? {
        guard let priorDay = calendar.date(byAdding: .day,
                                           value: -1,
                                           to: calendar.startOfDay(for: latestSleep.day)) else { return nil }
        return dayDescendingRollups
            .first { calendar.isDate($0.day, inSameDayAs: priorDay) }?
            .strain
    }

    private var sleepMetric: AtriaTriRingMetric {
        let performance = sleepPerformancePercent
        // Hours-first, always: falls back to the rollup's stored duration
        // before ever falling back to a bare percent as the primary number.
        let value = latestDisplaySleep?.durationText
            ?? latestRollup?.sleepSeconds.map { AtriaMetricFormat.sleepDuration(seconds: $0) }
            // Deterministic no-value token, matching recovery and strain. With
            // this left as the old word, the ring legend rendered "Sleep /
            // Learning" directly beside "Strain / --" for the same not-ready
            // state -- two vocabularies for one condition, in one row.
            ?? AtriaCompactMetricPresentation.noValue
        let detail: String
        if let evidence = latestDisplaySleep, !evidence.confirmed {
            detail = evidence.isNapEvidence ? "Review nap" : "Review sleep"
        } else {
            detail = sleepNeedDetailText(performance: performance)
        }
        return AtriaTriRingMetric(title: "Sleep",
                                  value: value,
                                  detail: detail,
                                  systemImage: "moon.fill",
                                  // Achievement coloring (2026-07-08, user request): the ring
                                  // warms to green as sleep fills toward need, so a met goal reads
                                  // as a win. The legend dot (stateTint) still carries the zone.
                                  // Sleep is judged against its percent-of-need zone, not the
                                  // generic exact-closure achievement rule. Otherwise a rounded
                                  // 99% night displays a yellow ring while its state dot and
                                  // sleep-performance card correctly say green.
                                  tint: performance.map { AtriaTriRing.zoneTint(.sleep, percent: Double($0)) }
                                      ?? .secondary,
                                  fill: performance.map { min(max(Double($0) / 100.0, 0), 1) },
                                  stateTint: performance.map { AtriaTriRing.zoneTint(.sleep, percent: Double($0)) },
                                  // A marker at 1.0 (ring closure) exactly when there's a real,
                                  // computed nightly need to close against -- never a fabricated
                                  // target when `sleepNeedHoursValue` can't be computed yet.
                                  targetFraction: sleepNeedHoursValue != nil ? 1.0 : nil)
    }

    /// Recovery is owned by the physiological-cycle resolver in `SessionStore`.
    /// Every surface must display that exact estimate: carrying the newest civil-
    /// day rollup here made Overview show yesterday's green score while Vitals
    /// correctly showed the current no-sleep fallback. The canonical hero already
    /// freezes a scored morning and remains stable through reconnects.
    /// Rollups in day-descending order, memoized behind
    /// `store.dailyRollupHistoryRevision` (measured-perf pass, 2026-07-05;
    /// tightened 2026-07-09): `store.dailyRollupHistory` is already newest-
    /// first, and DEBUG highlight fixtures preserve that invariant, so this
    /// avoids a redundant sort while still sharing the ordered slice across
    /// recovery, HRV, RHR, and previous-day consumers.
    private var dayDescendingRollups: [DailyRollupStoreEntry] {
        let revision = sessionProjectionStore.state.dailyRollupHistoryRevision
        if glanceMemo.dayDescendingRevision == revision, let cached = glanceMemo.dayDescendingRollups {
            return cached
        }
        let sorted = highlightRollups
        glanceMemo.dayDescendingRevision = revision
        glanceMemo.dayDescendingRollups = sorted
        return sorted
    }

    private var displayRecovery: (value: String, detail: String, percent: Int?) {
        let estimate = displayHero.recoveryEstimate
        if let percent = estimate.percent {
            return ("\(percent)%", displayHero.recoveryDetail, percent)
        }
        // Same rule as strainValue: the value line carries a numeral or "--",
        // never a status word. Recovery is computable exactly when the estimator
        // produced a percent, so this branch is genuinely no-value rather than a
        // hidden one, and the reason travels in the detail/marker instead.
        return (AtriaCompactMetricPresentation.noValue, AtriaRecoveryAvailabilityPresentation.detail(
            estimateDetail: estimate.detail,
            hrvBaselineSamples: sessionProjectionStore.state.baseline.freshHRVSampleCount(),
            restingBaselineSamples: sessionProjectionStore.state.baseline.freshRestingSampleCount()
        ), nil)
    }

    /// HRV glance carry (mirrors `displayRecovery`): the tile shows the SAME frozen
    /// daily HRV the detail sheet reads — `Int(exp(lnRMSSD).rounded())` over the
    /// newest stored rollup — never the live BLE/fallback reading, which can differ
    /// from that settled number. Labeled "this morning"/"yesterday" so a carried
    /// value is never read as a fresh one. Only when no rollup carries an HRV yet
    /// does it fall back to the live hero value + its detail, preserving the
    /// "N of 14 nights" calibration progress while the value is still pending
    /// (2026-07-08: settle the morning-once tiles so they agree with their detail).
    private var displaySettledHRV: (value: String, detail: String) {
        if let entry = dayDescendingRollups.first(where: { $0.lnRMSSD != nil }),
           let lnRMSSD = entry.lnRMSSD {
            let ms = Int(exp(lnRMSSD).rounded())
            let label = AtriaHealthMetricEvidencePresentation.settledHRVDetail(
                rollup: entry
            )
            return ("\(ms)", label)
        }
        let live = displayHero.hrvValue
        let detail = isPendingHeroValue(live)
            ? baselineProgress(
                sessionProjectionStore.state.baseline.freshHRVSampleCount(),
                unit: "nights"
            )
            : displayHero.hrvDetail
        return (live, detail)
    }

    /// RHR glance carry (mirrors `displaySettledHRV`): pins the tile to the frozen
    /// daily resting HR (`rhr`) the detail sheet reads, not the live value, labeled
    /// "this morning"/"yesterday". Falls back to the live value + "N of 14 days"
    /// progress only when no rollup carries an RHR yet.
    private var displaySettledRHR: (value: String, detail: String) {
        if let entry = dayDescendingRollups.first(where: { $0.rhr != nil }),
           let rhr = entry.rhr {
            let label = AtriaHealthMetricEvidencePresentation.settledRestingHeartRateDetail(
                rollup: entry
            )
            return ("\(rhr)", label)
        }
        let live = displayHero.restingHeartRateText
        let detail = isPendingHeroValue(live)
            ? baselineProgress(
                sessionProjectionStore.state.baseline.freshRestingSampleCount(),
                unit: "days"
            )
            : "bpm"
        return (live, detail)
    }

    /// Resting-HR TREND for the "Resting trend" glance card (2026-07-08). This card
    /// used to render a training-LOAD signal (ACWR/monotony) under a resting-HR
    /// title — a mismatch. It now shows the DIRECTION of resting HR over the last
    /// up-to-14 nights (recent-half average vs earlier-half average); a lower
    /// resting HR is the better direction. Distinct from the "Resting HR" card,
    /// which shows the current value + sparkline. `store.restingTrend14` is the
    /// ascending daily resting-HR series. Needs 6 nights (3 vs 3) before a
    /// direction is honest; before that it reads "Learning · N of 6 nights".
    private var displayRestingTrend: (value: String, detail: String) {
        let trend = sessionProjectionStore.state.restingTrend14
        guard trend.count >= 6 else {
            return ("Learning", "\(trend.count) of 6 nights")
        }
        let mid = trend.count / 2
        let earlierAvg = Double(trend.prefix(mid).reduce(0, +)) / Double(mid)
        let recentAvg = Double(trend.suffix(trend.count - mid).reduce(0, +)) / Double(trend.count - mid)
        let delta = Int((recentAvg - earlierAvg).rounded())
        let nights = trend.count
        if delta <= -1 { return ("\u{2193} \(-delta) bpm", "lower over \(nights) nights") }
        if delta >= 1 { return ("\u{2191} \(delta) bpm", "higher over \(nights) nights") }
        return ("Steady", "flat over \(nights) nights")
    }

    /// Provenance for the metrics whose confidence is actually derived from
    /// measured coverage. Other detail kinds return nil rather than a card full
    /// of "not measured" rows, which would be noise rather than disclosure.
    ///
    /// Built here because this is what holds the hero snapshot; the sheet only
    /// renders what it is handed, so the wording stays owned by the one
    /// canonical presentation model.
    private func provenance(for detail: AtriaMetricDetailKind) -> AtriaMetricProvenance? {
        switch detail {
        case .recovery:
            let presentation = AtriaCompactMetricPresentation.recovery(
                percent: displayHero.recoveryEstimate.percent,
                confidence: displayHero.recoveryEstimate.confidence,
                usesHRV: displayHero.recoveryEstimate.usesHRV,
                isProvisional: displayHero.recoveryIsProvisional,
                isFromPreviousSleep: displayHero.recoveryIsFromPreviousSleep
            )
            return AtriaMetricProvenance(
                displayValue: presentation.displayValue,
                level: presentation.level,
                isLowerBound: presentation.isLowerBound,
                usesHRV: displayHero.recoveryEstimate.usesHRV,
                // Recovery is scored from the night, not from day-long wear, so
                // day coverage is not the provenance for this number.
                hrCoverageFraction: nil,
                sourceLabel: "Strap sleep",
                // The night this score was computed from ended here. That is the
                // real timestamp of the underlying data, not a render time -- it
                // is also what makes a carried-over score legible, since "prev.
                // sleep" plus a stamp from yesterday morning explains itself.
                observedAt: latestDisplaySleep?.end,
                // Recovery's graded zone, from the user's own configured
                // thresholds. Nil while there is no score, so the row stays
                // neutral rather than asserting a standing.
                valueStatusTint: displayHero.recoveryEstimate.percent == nil
                    ? nil
                    : ringRecoveryZone?.tint
            )
        case .strain:
            let presentation = AtriaCompactMetricPresentation.strain(
                strain: displayHero.strain,
                confidence: displayHero.strainConfidence
            )
            return AtriaMetricProvenance(
                displayValue: presentation.displayValue,
                level: presentation.level,
                isLowerBound: presentation.isLowerBound,
                // Strain integrates heart-rate reserve; HRV is not an input, so
                // "HRV contributed" is not a meaningful row here.
                usesHRV: nil,
                hrCoverageFraction: displayHero.dayWearCoverageFraction,
                sourceLabel: "Strap heart rate",
                // Strain accumulates continuously through the day, and no
                // last-accepted-sample time is exposed on the hero. Stamping it
                // with `Date()` would report when the sheet was drawn, not when
                // the data was observed -- a render time dressed as provenance.
                // Absent means not measured, which is the honest claim.
                observedAt: nil,
                // Strain's graded zone needs a real frozen target to grade
                // against, and an incomplete or pending day has no standing to
                // grade at all -- same condition the ring already uses to
                // withhold its own state tint.
                valueStatusTint: (dayStrainIsIncomplete
                                  || isPendingHeroValue(displayHero.strainValue))
                    ? nil
                    : ringStrainZone(target: displayHero.guidance.target)?.tint
            )
        default:
            return nil
        }
    }

    private var recoveryMetric: AtriaTriRingMetric {
        let display = displayRecovery
        return AtriaTriRingMetric(title: "Recovery",
                                  value: display.value,
                                  detail: display.detail,
                                  systemImage: "arrow.clockwise.heart.fill",
                                  // EXCEPTION to the identity-hue rule (color-coherence pass,
                                  // 2026-07-05): recovery's hue IS its value (WHOOP red/yellow/
                                  // green over 0-100), so `tint` itself stays zone-graded. A
                                  // missing score is neutral, and configured thresholds own the
                                  // grade everywhere this ring is projected.
                                  tint: ringRecoveryZone?.tint ?? .secondary,
                                  fill: display.percent.map { Double($0) / 100.0 })
                                  // No target marker: recovery has no separate "target" of its
                                  // own -- its value is already the 0-100 scale it's graded on.
    }

    private var strainMetric: AtriaTriRingMetric {
        // The arc is actual strain on the canonical 0–21 scale. Achievement
        // color and the marker are separate and require a real frozen target.
        let target = displayHero.guidance.target
        let incomplete = dayStrainIsIncomplete
        let pending = isPendingHeroValue(displayHero.strainValue)
        let fill = AtriaRingMetricProjection.strainFill(
            strain: displayHero.strain,
            isPending: incomplete || pending
        )
        let targetProgress = AtriaRingMetricProjection.strainTargetProgress(
            strain: displayHero.strain,
            target: target
        )
        return AtriaTriRingMetric(title: "Strain",
                                  value: incomplete && !displayHero.strainValue.hasPrefix("≥")
                                    ? "≥ \(displayHero.strainValue)"
                                    : displayHero.strainValue,
                                  // Compact fixed-vocabulary markers, not prose.
                                  // "Partial · sparse HR" described the plumbing
                                  // rather than the number's meaning, and was long
                                  // enough to wrap and make one card taller than
                                  // its neighbour. "lower bound" says the same
                                  // thing about the value the user is looking at,
                                  // and matches the "≥" prefix already on it.
                                  detail: pending
                                    ? "HR pending"
                                    : (incomplete ? "lower bound" : (target.map { String(format: "of %.1f", $0) } ?? "Strain")),
                                  systemImage: "flame.fill",
                                  // Without a Recovery-derived target, measured
                                  // strain keeps its identity blue instead of
                                  // looking like absent data.
                                  tint: AtriaRingMetricProjection.strainTint(
                                    targetProgress: incomplete || pending ? nil : targetProgress,
                                    actualFill: fill
                                  ),
                                  fill: fill,
                                  stateTint: incomplete || pending ? nil : ringStrainZone(target: target)?.tint,
                                  targetFraction: incomplete || pending ? nil : AtriaRingMetricProjection.strainTargetFraction(target))
    }

    /// The ring, compact header, accessibility summary and glance grid all ask
    /// for `strainMetric` during one render. Without this cache each request
    /// filtered the complete workout archive and repeated civil-time conversion.
    /// Below 1.0 strain the result depends only on the workout revision and local
    /// day and its confirmed-workout revision.
    private var dayStrainIsIncomplete: Bool {
        if displayHero.strainConfidence.localizedCaseInsensitiveContains("partial")
            || displayHero.strainValue.hasPrefix("≥") {
            return true
        }
        let calendar = Calendar.current
        let now = Date()
        let cycle = AtriaPhysiologicalDay.current(
            now: now,
            sleepHistory: sessionProjectionStore.state.sleepHistorySnapshot,
            calendar: calendar
        )
        let key = AtriaTodayDayStrainIncompleteKey(
            confirmedWorkoutsRevision: sessionProjectionStore.state.confirmedWorkoutsRevision,
            day: cycle.start
        )
        return glanceMemo.dayStrainIncompleteCache.resolve(key: key) {
            AtriaWorkoutMetricPresentation.cycleStrainIsIncomplete(
                start: cycle.start,
                end: now,
                strain: displayHero.strain,
                workouts: sessionProjectionStore.state.confirmedWorkouts
            )
        }
    }

    /// HRV ring metric. Fill is nil (learning placeholder cap) unless the
    /// current reading parses AND the personal HRV baseline is trusted --
    /// never a fabricated ratio against an unproven baseline. Higher HRV is
    /// better, so fill climbs toward/above the trusted baseline.
    private var hrvMetric: AtriaTriRingMetric {
        let baseline = AtriaBaselineTargetSnapshot(sessionProjectionStore.state.baseline)
        let current = Int(displaySettledHRV.value)
        let fill = AtriaRingMetricProjection.higherIsBetterProgress(
            value: current,
            baseline: baseline.hrvBaseline,
            baselineIsTrusted: baseline.hrvTrusted
        )
        return AtriaTriRingMetric(title: "HRV",
                                  // Settled-first (2026-07-09): show the SAME frozen morning HRV the
                                  // glance tile + detail sheet read, not the live BLE/fallback reading,
                                  // so a ring chip can't disagree with the tile for the same metric.
                                  // The settled shown number owns the baseline-ratio arc.
                                  value: displaySettledHRV.value,
                                  detail: legendDetail(displaySettledHRV.detail),
                                  systemImage: "waveform.path.ecg",
                                  tint: Metrics.electricHRV,
                                  fill: fill)
    }

    /// Resting heart rate ring metric. Fill is nil (learning placeholder
    /// cap) unless the personal resting-HR baseline is trusted. Lower RHR
    /// is better, so the fill is baseline/current -- a reading at or below
    /// baseline reads as full+ -- never a raw ratio that would reward a
    /// higher bpm.
    private var restingHeartRateMetric: AtriaTriRingMetric {
        let baseline = AtriaBaselineTargetSnapshot(sessionProjectionStore.state.baseline)
        let current = Int(displaySettledRHR.value) ?? 0
        let fill = AtriaRingMetricProjection.lowerIsBetterProgress(
            value: current,
            baseline: baseline.restingBaseline,
            baselineIsTrusted: baseline.restingTrusted
        )
        return AtriaTriRingMetric(title: "RHR",
                                  // Settled-first (2026-07-09): the SAME frozen morning RHR the glance
                                  // tile + detail sheet read (falls back to restingHeartRateText, which
                                  // is "Learning" until a real reading — never the fabricated 60), so the
                                  // ring chip agrees with the tile and Vitals row, including its arc.
                                  value: displaySettledRHR.value,
                                  detail: legendDetail(displaySettledRHR.detail),
                                  systemImage: "heart.fill",
                                  tint: Metrics.electricRHR,
                                  fill: fill)
    }

    private var latestRollup: DailyRollupStoreEntry? {
        dayDescendingRollups.first
    }

    /// Prepared by the narrow session projection outside SwiftUI body evaluation.
    private var weeklyPlan: WeeklyPlan {
        sessionProjectionStore.state.weeklyPlan
    }

    private static func currentISOWeekStart(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    private var weeklyReport: WeeklyReport {
        let revision = sessionProjectionStore.state.dailyRollupHistoryRevision
        let weekStart = Self.currentISOWeekStart()
        if glanceMemo.weeklyReportRevision == revision,
           glanceMemo.weeklyReportWeekStart == weekStart,
           let cached = glanceMemo.weeklyReportValue {
            return cached
        }
        let report = WeeklyReport(rollups: highlightRollups)
        glanceMemo.weeklyReportRevision = revision
        glanceMemo.weeklyReportWeekStart = weekStart
        glanceMemo.weeklyReportValue = report
        return report
    }

    private var centerValue: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            return displayRecovery.value
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

    /// Which metric the hero's center numeral belongs to. The ring view only
    /// renders it when neither center line already says the name, so a
    /// learning state like "Learning / Save sleep to score" gains "RECOVERY"
    /// while an explicit state line never repeats it (2026-08-01 ring fix).
    private var centerMetricName: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery: return AtriaTriRingSlot.recovery.label
        case .sleep: return AtriaTriRingSlot.sleep.label
        case .strain: return AtriaTriRingSlot.strain.label
        }
    }

    private var centerState: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            if displayRecovery.detail == "yesterday" { return "yesterday" }
            // While learning, the numeral ALREADY reads "Learning" (see
            // displayRecovery), so repeating the word here rendered the hero as
            // "Learning / Learning". Carry the real evidence line instead —
            // "Save sleep to score", "HRV baseline 2 of 14 nights" — which is
            // what the handoff's "Learning · of 4" caption stands for: say how
            // far along calibration is, never restate the state twice.
            return displayRecovery.percent.map(recoveryState) ?? displayRecovery.detail
        case .sleep:
            return sleepPerformancePercent.map { "\($0)% of need" } ?? sleepMetric.detail
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
            // The ring center carries YESTERDAY's score before this morning's reading
            // lands (see displayRecovery), so a "vs yesterday" delta only makes sense
            // once today has its own stored recovery. Computing it from the live
            // estimate regardless produced "+N% vs yesterday" against a numeral that
            // was itself yesterday (2026-07-09 coherence fix). Gate on today actually
            // having a reading, and delta the value actually shown in the center.
            let newestStoredRecoveryIsToday = dayDescendingRollups
                .first(where: { $0.recovery != nil })
                .map { Calendar.current.isDateInToday($0.day) } ?? false
            guard newestStoredRecoveryIsToday,
                  let current = displayRecovery.percent,
                  let previous = previousRollup?.recovery else { return nil }
            return Self.deltaText(current - previous, unit: "%")
        case .sleep:
            guard let current = sleepPerformancePercent,
                  let previous = previousSleepPerformancePercent else { return nil }
            return Self.deltaText(current - previous, unit: "%")
        case .strain:
            guard let previous = previousRollup?.strain else { return nil }
            let delta = displayHero.strain - previous
            guard abs(delta) >= 0.05 else { return "Flat vs yesterday" }
            return String(format: "%@%.1f vs yesterday", delta > 0 ? "+" : "-", abs(delta))
        }
    }

    /// Sleep may update immediately after a resumed segment is confirmed while
    /// the current civil-day rollup is still settling. Compare the fresh
    /// canonical percent with the rollup belonging to the preceding sleep day,
    /// rather than assuming array index 1 is yesterday.
    private var previousSleepPerformancePercent: Int? {
        guard let latestSleep else { return nil }
        return AtriaTodaySleepDeltaAuthority.previousPerformance(
            before: latestSleep.day,
            rollups: dayDescendingRollups
        )
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
        displayHero.recoveryEstimate.percent.map { "\($0)% recovery" } ?? "Learning"
    }

    private var planTitle: String {
        displayHero.guidance.headline
    }

    private var planDetail: String {
        displayHero.guidance.detail
    }

    private var planTargetText: String {
        guard let target = displayHero.guidance.target else { return "Target building" }
        // "N to go" is an arithmetic claim about measured strain. While the
        // strain hero itself shows pending, day strain is unmeasured — the
        // pill asserting "10.2 to go" beside a "--" strain chip contradicted
        // it (2026-08-04 WHOOP-alignment review, rank 1).
        if isPendingHeroValue(displayHero.strainValue) {
            return String(format: "Target %.1f \u{00b7} strain pending", target)
        }
        let remaining = target - displayHero.strain
        if remaining > 0.05 {
            return String(format: "Target %.1f \u{00b7} %.1f to go", target, remaining)
        }
        return String(format: "Target %.1f \u{00b7} met", target)
    }

    private var journalCheckInProgress: AtriaJournalCheckInProgress {
        let calendar = Calendar.current
        let localDay = sessionProjectionStore.state.localDay
        let todayEntry = sessionProjectionStore.state.behaviorJournalEntries.first {
            calendar.isDate($0.day, inSameDayAs: localDay)
        }
        return AtriaJournalCheckInProgress.resolve(
            trackedTags: AtriaTrackedBehaviors.parse(trackedBehaviorsRaw),
            todayEntry: todayEntry,
            answersByQuestion: sessionProjectionStore.state.todayJournalAnswers
        )
    }

    private var morningCheckInNeedsFallback: Bool {
        AtriaNotificationAttemptStore.needsInAppFallback(
            kind: LocalNotificationScheduler.morningCheckInKind
        )
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

    /// The AI-coach narrative payload. Building it sorts and ISO/weekday-
    /// formats the last-7 rollups, so -- like `weeklyPlan` -- it must not run
    /// from a body computed property on the scroll/live path. Memoized behind
    /// the rollup revision (measured-perf pass, 2026-07-06): the payload is
    /// rollup-driven (the live `coachContext` is only a cold-start fallback
    /// for the narrative, which changes slowly), so a once-per-rollup-change
    /// refresh is correct and keeps the coaching copy stable between updates.
    private var coachPayload: AtriaCoachPayload {
        let revision = sessionProjectionStore.state.dailyRollupHistoryRevision
        if glanceMemo.coachPayloadRevision == revision, let cached = glanceMemo.coachPayloadValue {
            return cached
        }
        let payload = AtriaCoachPayload.fromRollups(rollups: Array(highlightRollups.prefix(7)),
                                                    fallback: coachContext,
                                                    baselines: coachBaselines)
        glanceMemo.coachPayloadRevision = revision
        glanceMemo.coachPayloadValue = payload
        return payload
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

    private var glanceMetrics: [AtriaTodayMetric] {
        if glanceMemo.glanceMetricsLayoutConfig == layoutConfig,
           let cached = glanceMemo.glanceMetricsValue {
            return cached
        }
        let value = Self.glanceMetrics(for: layoutConfig)
        glanceMemo.glanceMetricsLayoutConfig = layoutConfig
        glanceMemo.glanceMetricsValue = value
        return value
    }

    static func glanceMetrics(for layoutConfig: AtriaHomeLayoutConfig) -> [AtriaTodayMetric] {
        layoutConfig.validated().glanceMetrics
            .compactMap(AtriaTodayMetric.init(rawValue:))
    }

    static func glanceHostIdentity(
        for layoutConfig: AtriaHomeLayoutConfig,
        bars: Bool
    ) -> String {
        let validated = layoutConfig.validated()
        let sizes = validated.sizeOverrides.keys.sorted().map {
            "\($0)=\(validated.sizeOverrides[$0] ?? "")"
        }.joined(separator: ",")
        return [
            bars ? "bars" : "grid",
            validated.glanceMetrics.joined(separator: ","),
            sizes,
            validated.legendStatStyle.rawValue,
        ].joined(separator: "|")
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
                                        value: strainMetric.value,
                                        detail: legendDetail(strainMetric.value == "Incomplete"
                                                             ? "Sparse HR" : strainCompareDetailText),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .hrv:
            return AtriaTodayGlanceItem(title: "Morning HRV",
                                        metricKey: metric.rawValue,
                                        value: displaySettledHRV.value,
                                        detail: legendDetail(displaySettledHRV.detail),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricHRV,
                                        layoutSize: layoutSize(for: metric))
        case .stress:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.stressValue,
                                        detail: legendDetail(displayHero.stressDetail),
                                        systemImage: metric.systemImage,
                                        // Identity hue (2026-07-09): stress was electricStrain (cool blue),
                                        // reading as strain; electricStress (amber) matches its detail sheet.
                                        tint: Metrics.electricStress,
                                        layoutSize: layoutSize(for: metric))
        case .sleepHistory:
            // Honest learning state (2026-07-09): sleepConsistencyText is "--" until
            // 2+ sleep nights, so surface the threshold instead of a bare category
            // word — mirrors the sibling sleepEfficiency empty state.
            let consistency = sessionProjectionStore.state.sleepHistorySnapshot.sleepConsistencyText
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: consistency,
                                        // Plain-language pass (2026-07-31 device
                                        // review): "Routine" beside a bare
                                        // percentage did not say what the
                                        // number measures.
                                        detail: legendDetail(consistency == "--" ? "Needs 2 nights" : "Routine consistency"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .sleepEfficiency:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: latestSleep?.sleepEfficiencyText ?? "--",
                                        // Empty-state honesty (2026-07-08): efficiency = time asleep /
                                        // time in bed, so until a night has a known in-bed span there is
                                        // genuinely no number. Plain-language pass (2026-07-31 device
                                        // review): say when it appears instead of the cryptic
                                        // "Needs time in bed". HR-only honesty (2026-08-01): a night
                                        // without validated motion shows "--" and says why.
                                        detail: legendDetail(
                                            latestSleep?.displaySleepEfficiency != nil
                                                ? "Sleep"
                                                : (latestSleep?.sleepEfficiency == nil
                                                    ? "After a confirmed sleep"
                                                    : "Needs motion data")),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .sleepPerformance:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        // Same source the sleep ring uses (computed from the latest
                                        // sleep, falling back to the rollup) so the tile and ring can't
                                        // show two different sleep-performance percentages.
                                        value: sleepPerformancePercent.map { "\($0)%" }
                                            ?? AtriaCompactMetricPresentation.noValue,
                                        detail: legendDetail("of need"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .rhr:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displaySettledRHR.value,
                                        detail: legendDetail(displaySettledRHR.detail),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricRHR,
                                        layoutSize: layoutSize(for: metric))
        case .respiratoryRate:
            // Cross-tab consistency (2026-07-09): fall back to the latest recorded
            // night's respiratory rate — like the Vitals Health row — so a real value
            // shows instead of "--" when only a night (no daytime rollup value) exists.
            let respiratory = latestRollup?.respiratoryRate ?? latestSleep?.respiratoryRate
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: respiratory.map { String(format: "%.1f", $0) } ?? "--",
                                        detail: legendDetail(respiratory == nil ? "After a sleep" : "/min"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricRespiratory,
                                        layoutSize: layoutSize(for: metric))
        case .steps:
            return nil
        case .calories:
            return nil
        case .vo2max:
            // Time-to-detect (2026-07-05): when the estimate isn't ready yet, show
            // the summary's specific calibration progress ("12/14 RHR", "Need HRmax")
            // instead of a generic "Estimate", so users see how far off a reading is.
            let vo2 = profileMetricsStore.state.vo2MaxEstimate
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: vo2.valueText,
                                        // Calibration progress (2026-07-31 device
                                        // review): compactStatusText shows
                                        // "Improving · day N of 14" while the
                                        // estimate is preliminary, "Estimate"
                                        // once trusted, and the real blocker
                                        // when there is no value.
                                        detail: legendDetail(vo2.value == nil ? vo2.detail : vo2.compactStatusText),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricGreen,
                                        layoutSize: layoutSize(for: metric))
        case .bioAge:
            // Time-to-detect (2026-07-05): surface the calibration state
            // ("Calibrating 28-day baseline") while the fitness-age baseline is still
            // forming, rather than a generic "Estimate" that implies a ready value.
            let bioAge = profileMetricsStore.state.biologicalAgeSummary
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: bioAge.valueText,
                                        // Calibration progress (2026-07-31
                                        // device review): the blocked state
                                        // names its real blocker ("Building
                                        // resting HR baseline") instead of the
                                        // generic building narrative.
                                        detail: legendDetail(bioAge.isReady ? "Estimate" : bioAge.compactStatusText),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricGreen,
                                        layoutSize: layoutSize(for: metric))
        case .bloodOxygen:
            // Decoder validation and hardware capability are separate facts. Do
            // not blame the strap when Atria has not validated its payload layout.
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        // Last em dash in the app; the glance grid
                                        // around it already speaks "--".
                                        value: AtriaCompactMetricPresentation.noValue,
                                        detail: legendDetail("Decoder unavailable"),
                                        systemImage: metric.systemImage,
                                        tint: .secondary,
                                        layoutSize: layoutSize(for: metric))
        case .bodyTemp:
            let skinTemp = sessionProjectionStore.state.skinTemperatureDeviationSummary
            let decoderAvailable = AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: AtriaExperimentalSensorCopy
                                            .skinTemperatureValue(
                                                summary: skinTemp,
                                                decoderAvailable: decoderAvailable
                                            ),
                                        detail: legendDetail(decoderAvailable
                                            ? skinTemp.detailText
                                            : "Decoder unavailable"),
                                        systemImage: metric.systemImage,
                                        tint: .orange,
                                        layoutSize: layoutSize(for: metric))
        case .trend:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayRestingTrend.value,
                                        detail: legendDetail(displayRestingTrend.detail),
                                        systemImage: metric.systemImage,
                                        tint: layoutConfig.accent.color,
                                        layoutSize: layoutSize(for: metric))
        case .insights:
            let insights = sessionProjectionStore.state.behaviorInsights
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "\(insights.count)",
                                        detail: legendDetail(insights.first?.tagLabel ?? "Keep tagging"),
                                        systemImage: metric.systemImage,
                                        tint: layoutConfig.accent.color,
                                        layoutSize: layoutSize(for: metric))
        }
    }

    private func layoutSize(for metric: AtriaTodayMetric) -> AtriaTodayGlanceItem.LayoutSize {
        // Clamp non-chart metrics to compact regardless of any saved override (a
        // single-value tile stretched full-width leaves the row half-empty). Mirrors
        // the System-B glance clamp so both surfaces agree on which cards can be wide.
        guard metric.canBeWideGlanceCard else { return .compact }
        return AtriaTodayGlanceItem.LayoutSize(rawValue: layoutConfig.sizeOverrides[metric.rawValue] ?? "compact") ?? .compact
    }

    /// Measured-perf pass (2026-07-05): `store.confirmedWorkouts` is already
    /// stored start-descending (see `readConfirmedWorkouts`/
    /// `saveConfirmedWorkouts`, Sessions.swift) and this and
    /// `latestConfirmedWorkoutOneLiner` are read on every glance-tile body
    /// eval, including every live-pulse re-render -- so both are memoized
    /// together behind `store.confirmedWorkoutsRevision` + the current week
    /// boundary, and the "this week" scan stops as soon as it walks off the
    /// front of the window instead of filtering the whole (unbounded, all-time)
    /// array.
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
        let revision = sessionProjectionStore.state.confirmedWorkoutsRevision
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        guard glanceMemo.workoutsRevision != revision || glanceMemo.workoutsWeekStart != weekStart else { return }
        // Presentation gate (2026-07-31): accidental sub-minute live fragments
        // must not become the glance count or the "latest workout" one-liner.
        let workouts = AtriaWorkoutMetricPresentation.presentableWorkouts(
            sessionProjectionStore.state.confirmedWorkouts
        )
        // Sorted start-descending, so everything still "this week" is a
        // contiguous run at the front -- no need to walk the rest of a
        // years-long workout history every eval.
        glanceMemo.workoutsWeekCount = workouts.prefix(while: { $0.start >= weekStart }).count
        if let latest = workouts.first {
            let title = latest.activitySubtype ?? latest.activityType ?? "Workout"
            // A zero strain is noise, not information (strength logs often
            // carry none) — drop it rather than print "0.0 strain"
            // (2026-08-05, seen live).
            let strainText = latest.strain.flatMap {
                $0 > 0 ? String(format: "%.1f strain", $0) : nil
            }
            let dayText = Self.workoutDayFormatter.string(from: latest.start)
            let latestLine = [title, strainText, dayText].compactMap { $0 }.joined(separator: " · ")
            // The big number on this card counts THIS WEEK; when that count
            // is zero the subtitle must not describe an older workout as if
            // it were the counted scope (2026-08-05, seen live: "Strength ·
            // 0.0 strain · Tue" beside a 0).
            glanceMemo.workoutsOneLiner = latest.start >= weekStart
                ? latestLine
                : "None this week · last: \(latestLine)"
        } else {
            glanceMemo.workoutsOneLiner = "No workouts yet"
        }
        glanceMemo.workoutsRevision = revision
        glanceMemo.workoutsWeekStart = weekStart
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
    /// `store.dailyRollupHistoryRevision` + the current local day so the
    /// filter+sort above only actually runs when the rollups or day window
    /// change, not on every one of the many live-pulse body evals in between.
    private var strainCompareMedian: Double? {
        let revision = sessionProjectionStore.state.dailyRollupHistoryRevision
        let today = Calendar.current.startOfDay(for: Date())
        if glanceMemo.strainMedianRevision == revision,
           glanceMemo.strainMedianDay == today {
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
        glanceMemo.strainMedianDay = today
        glanceMemo.strainMedianValue = median
        return median
    }

    private func metricIsPending(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var strainCompareDetailText: String {
        // Plain-language pass (2026-07-31 device review): mirrors
        // AtriaOverviewSections.strainCompareDetailText — "Building baseline"
        // told a first-time user nothing.
        guard let median = strainCompareMedian else { return "Still learning your typical day" }
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

    /// Pending-value set matching the app-wide convention (see AtriaHomeView's
    /// pending check): a metric that has no reading yet, so its tile can show
    /// time-to-detect progress instead of the bare placeholder.
    /// Delegates to `AtriaTodayGlanceItem` so the sentinel set is defined once
    /// and the glance tile's pending styling can never drift from this check.
    private func isPendingHeroValue(_ value: String) -> Bool {
        AtriaTodayGlanceItem.isPendingValue(value)
    }

    /// HRV is qualified from confirmed sleep; resting HR may also learn from a
    /// qualified daytime low-HR window, so their maturity units differ.
    private func baselineProgress(_ samples: Int, unit: String) -> String {
        "\(min(samples, PersonalBaseline.trustedMinimumSamples)) of \(PersonalBaseline.trustedMinimumSamples) \(unit)"
    }

    private func recoveryState(percent: Int) -> String {
        switch Metrics.recoveryZone(percent, target: recoveryTarget)?.level {
        case .green: return "Good"
        case .yellow: return "Fair"
        case .red: return "Low"
        case nil: return "Learning"
        }
    }

    private var recoveryTarget: AtriaMetricTarget {
        .recovery(greenLower: recoveryGreenLower, yellowLower: recoveryYellowLower)
    }

    private var ringRecoveryZone: AtriaMetricZone? {
        Metrics.recoveryZone(displayRecovery.percent, target: recoveryTarget)
    }

    private func ringStrainZone(target: Double?) -> AtriaMetricZone? {
        Metrics.strainZone(strain: displayHero.strain,
                           target: target,
                           greenBand: strainGreenBand,
                           yellowBand: strainYellowBand)
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

struct AtriaTodayDayStrainIncompleteKey: Equatable {
    let confirmedWorkoutsRevision: Int
    let day: Date
}

struct AtriaTodayDayStrainIncompleteCache {
    private(set) var key: AtriaTodayDayStrainIncompleteKey?
    private(set) var value: Bool?

    mutating func resolve(key nextKey: AtriaTodayDayStrainIncompleteKey,
                          compute: () -> Bool) -> Bool {
        if key == nextKey, let value {
            return value
        }
        let nextValue = compute()
        key = nextKey
        value = nextValue
        return nextValue
    }
}

/// Read-through memo for the glance-tile derivations that are expensive to
/// recompute but only change when their source aggregate does (measured-perf
/// pass, 2026-07-05). A plain class (not `ObservableObject`/`@Published`)
/// held behind a single `@State` on `AtriaTodayScreen`: mutating its fields
/// during body evaluation is safe -- it isn't an observed property wrapper,
/// so it neither triggers nor implies a re-render, it's a pure cache. Each
/// cache entry is only valid when its paired revision still matches the
/// store's current one (`dailyRollupHistoryRevision` / `confirmedWorkoutsRevision`,
/// Sessions.swift) and its calendar boundary when applicable, so a stale
/// value is never served after the underlying data or local window changes.
private final class AtriaTodayGlanceMemo {
    var todaySectionOrderCSV: String?
    var todaySectionOrderValue: [AtriaTodaySection]?
    var glanceMetricsLayoutConfig: AtriaHomeLayoutConfig?
    var glanceMetricsValue: [AtriaTodayMetric]?
    var strainMedianRevision: Int?
    var strainMedianDay: Date?
    var strainMedianValue: Double?
    var workoutsRevision: Int?
    var workoutsWeekStart: Date?
    var workoutsWeekCount: Int?
    var workoutsOneLiner: String?
    var dayStrainIncompleteCache = AtriaTodayDayStrainIncompleteCache()
    var dayDescendingRevision: Int?
    var dayDescendingRollups: [DailyRollupStoreEntry]?
    var highlightsRevision: Int?
    var highlightsValue: [AtriaHighlight]?
    // The weekly plan now lives in AtriaTodaySessionProjectionStore so its
    // persisted cache is never touched during body evaluation. These remaining
    // derived values are pure in-memory computations memoized by source window.
    var weeklyReportRevision: Int?
    var weeklyReportWeekStart: Date?
    var weeklyReportValue: WeeklyReport?
    var coachPayloadRevision: Int?
    var coachPayloadValue: AtriaCoachPayload?
    var sleepNeedKey: AtriaTodaySleepNeedKey?
    var sleepNeedValue: AtriaTodaySleepNeedSnapshot?
}

/// Live strain/recovery publications terminate here instead of at the large
/// Today screen. The host's Equatable identity documents that its only durable
/// owner is HeroStore; the observed object still drives this leaf directly,
/// while parent reconciliation remains free to replace the content closure when
/// layout or session inputs actually change.
private struct AtriaTodayHeroProjectionHost<Content: View>: View, Equatable {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ViewBuilder let content: (AtriaHomeModel.HeroSnapshot) -> Content

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.heroStore === rhs.heroStore
    }

    var body: some View {
        content(heroStore.state)
    }
}

/// Breathwork needs every live HR/RR publication, while the rest of Today must
/// remain insulated from pulse-rate invalidations. Observe the pulse store only
/// at the presented session boundary instead of passing a one-time value snapshot.
private struct AtriaTodayBreathworkSessionHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore
    let onSave: (SavedSession) -> Void
    let onClose: () -> Void

    var body: some View {
        AtriaBreathworkSession(currentHeartRate: pulseStore.state.heartRate,
                               currentRRSamples: pulseStore.state.recentRRSamples,
                               currentStress: nil,
                               onSave: onSave,
                               onClose: onClose)
    }
}

private struct AtriaTodaySleepNeedKey: Equatable {
    let sleepRevision: Int
    let rollupRevision: Int
    let latestNightID: String?
    let displayNightID: String?
    let baseNeedHours: Double
}

private struct AtriaTodaySleepNeedSnapshot: Equatable {
    let needHours: Double?
    let performancePercent: Int?
}

enum AtriaTodaySleepDeltaAuthority {
    nonisolated static func previousPerformance(
        before currentSleepDay: Date,
        rollups: [DailyRollupStoreEntry],
        calendar: Calendar = .current
    ) -> Int? {
        guard let priorDay = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: currentSleepDay)
        ) else { return nil }
        return rollups.first {
            calendar.isDate($0.day, inSameDayAs: priorDay)
        }?.sleepPerformance
    }
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
    let minScale: CGFloat
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Perf pass (2026-07-06): this view now OWNS the shrink progress and the
    /// `.onScrollGeometryChange` observation, so per-scroll-step writes
    /// invalidate only this small view -- not the entire AtriaTodayScreen body
    /// (glance grid, plan/coach cards, ring). `.onScrollGeometryChange` reads
    /// the nearest ancestor ScrollView regardless of which descendant it is
    /// attached to, so observing from here is equivalent to observing from the
    /// parent, minus the whole-body invalidation. 0 at rest, 1 once scrolled
    /// past `shrinkDistance`; Reduce Motion pins `scale`/`opacity` regardless.
    @State private var progress: CGFloat = 0

    /// Scroll distance (points) over which the hero fully shrinks/fades.
    private static var shrinkDistance: CGFloat { 140 }

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
            .scaleEffect(scale, anchor: .top)
            .opacity(opacity)
            // Own the ancestor-ScrollView observation here so per-scroll-step
            // writes stay contained in this view. Quantized to 5% steps so a
            // raw per-frame offset can't thrash even this small body.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                let clamped = min(max(newValue, 0), Self.shrinkDistance)
                let quantized = (clamped / Self.shrinkDistance * 20).rounded() / 20
                if quantized != progress { progress = quantized }
            }
    }
}

struct AtriaTodayCompactRingPresentation: Equatable {
    let slots: [AtriaTriRingSlotContent]
    let accessibilitySummary: String
}

struct AtriaTodayCompactRingPreferenceKey: PreferenceKey {
    static let defaultValue: AtriaTodayCompactRingPresentation? = nil

    static func reduce(value: inout AtriaTodayCompactRingPresentation?,
                       nextValue: () -> AtriaTodayCompactRingPresentation?) {
        value = nextValue() ?? value
    }
}

/// The collapsed hero deliberately carries no labels or explanatory copy:
/// icon + value are enough beside the miniature rings, while VoiceOver gets
/// the complete configured-ring summary.
struct AtriaTodayCompactRingRail: View {
    let slots: [AtriaTriRingSlotContent]
    let accessibilitySummary: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 5) {
                ForEach(slots, id: \.metric.title) { slot in
                    HStack(spacing: 5) {
                        Text(slot.slot.compactEmoji)
                            .accessibilityHidden(true)
                        Text(slot.metric.value)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                }
            }

            AtriaTodayCompactTriRing(slots: slots)
                .frame(width: 64, height: 64)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collapsed Today rings. \(accessibilitySummary)")
    }
}

private struct AtriaTodayCompactTriRing: View {
    let slots: [AtriaTriRingSlotContent]

    var body: some View {
        ZStack {
            ForEach(slots, id: \.metric.title) { slot in
                let index = slots.firstIndex(where: { $0.metric.title == slot.metric.title }) ?? 0
                let inset = CGFloat(index) * 8
                Circle()
                    .stroke(slot.metric.tint.opacity(0.18), lineWidth: 5)
                    .padding(inset)
                // `fill == nil` is the deliberate learning sentinel; the full
                // ring renders a dashed band for it. At this compact scale a
                // dashed band is unreadable, so draw no arc at all — a solid
                // sliver implied ~8% of something that was never measured.
                if let fill = slot.metric.fill {
                    Circle()
                        .trim(from: 0, to: min(max(fill, 0.025), 1))
                        .stroke(slot.metric.tint,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(inset)
                }
            }
        }
        .drawingGroup(opaque: false, colorMode: .linear)
        .accessibilityHidden(true)
    }
}

private struct AtriaTodayAddMetricsSheet: View {
    let selectedKeys: [String]
    let onToggle: (AtriaTodayMetric, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AtriaTodayMetric.defaultGlanceOrder) { metric in
                        Toggle(isOn: selectionBinding(for: metric)) {
                            Label(metric.label, systemImage: metric.systemImage)
                        }
                        .disabled(!selectedKeys.contains(metric.rawValue)
                                  && selectedKeys.count >= AtriaHomeLayoutConfig.maxTodayCards)
                    }
                } header: {
                    Text("Add or remove metrics")
                } footer: {
                    Text("Showing \(selectedKeys.count) of \(AtriaHomeLayoutConfig.maxTodayCards) metrics. Changes appear on Today immediately.")
                }
            }
            .navigationTitle("Today metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func selectionBinding(for metric: AtriaTodayMetric) -> Binding<Bool> {
        Binding(get: { selectedKeys.contains(metric.rawValue) },
                set: { onToggle(metric, $0) })
    }
}

/// The wake-settlement row, as its own view so it can own a clock.
///
/// This state is TIME-dependent -- a night crosses from processing to review
/// ready purely by 30 minutes elapsing, with no new data involved. Computing it
/// inline in AtriaTodayScreen was wrong: that body re-evaluates on
/// projection-store publishes, which covers newly accepted heart rate, but the
/// screen does not observe scenePhase, so returning to a foregrounded app with
/// nothing new to report could leave the row asserting "processing" long after
/// the window had actually closed.
///
/// Owning `scenePhase` and the sampled clock HERE, rather than on the parent,
/// follows the same containment the screen already uses for scroll state: only
/// this small subtree re-evaluates when the phase changes, instead of the whole
/// Today deck.
private struct AtriaTodaySleepSettlementRow: View {
    let confirmedSleepEnd: Date?
    let confirmedSleepSavedAt: Date?
    let candidateEnd: Date?

    @Environment(\.scenePhase) private var scenePhase
    /// Sampled rather than read inline, so the state and its freshness stamp are
    /// computed against ONE instant and cannot disagree with each other.
    @State private var now = Date()

    var body: some View {
        let state = AtriaSleepSettlementPresentation.state(
            confirmedSleepEnd: confirmedSleepEnd,
            confirmedSleepSavedAt: confirmedSleepSavedAt,
            candidateEnd: candidateEnd,
            now: now
        )
        let freshness = AtriaSleepSettlementPresentation.freshnessText(for: state, now: now)

        HStack(spacing: AtriaDesignTokens.Spacing.md) {
            Image(systemName: state.isSettling ? "clock.arrow.circlepath" : "moon.zzz.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Metrics.electricSleep)
                .frame(width: 24, height: 24)
            // Status dot, not a recoloured icon: the icon keeps sleep's identity
            // hue while the dot carries where the night actually stands. Same
            // split the provenance rows use, and it does not depend on colour
            // alone being legible.
            if let statusTint = state.statusTint {
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
            }
            Text(state.title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            // Reserved, like the metric card status line: the stamp is absent
            // for waitingForData, and a collapsing trailing label would change
            // the row's height.
            Text(freshness ?? " ")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(freshness == nil)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, AtriaDesignTokens.Spacing.md)
        // Same identity-hue inset card as the glance tiles. A plain grouped
        // background rendered nearly invisible against the light page, so the
        // row read as loose text beside its filled neighbours.
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.chip,
                        tint: Metrics.electricSleep,
                        hueTinted: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freshness.map { "\(state.title), updated \($0)" } ?? state.title)
        .onAppear { now = Date() }
        .onChange(of: scenePhase) { _, phase in
            // Re-sample on return to foreground: elapsed time alone can have
            // advanced the state while the app was away.
            if phase == .active { now = Date() }
        }
        .onChange(of: candidateEnd) { _, _ in now = Date() }
        .onChange(of: confirmedSleepEnd) { _, _ in now = Date() }
        .task(id: candidateEnd) {
            now = Date()
            guard confirmedSleepEnd == nil, let candidateEnd else { return }
            let transitionAt = candidateEnd.addingTimeInterval(
                AtriaSleepSettlementPresentation.settlementDelay
            )
            let delay = transitionAt.timeIntervalSinceNow
            guard delay > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            now = Date()
        }
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

    /// The one definition of "this metric has no reading yet", shared with
    /// `AtriaTodayScreen.isPendingHeroValue`. Kept as a value check rather than
    /// a stored flag so the ~20 `glanceItem(for:)` construction sites stay
    /// untouched and can never forget to set it.
    static func isPendingValue(_ value: String) -> Bool {
        AtriaCompactMetricPresentation.isPendingValue(value)
    }

    var isPending: Bool { Self.isPendingValue(value) }
}

private struct AtriaTodayLiveStatusHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayLiveStatusHost")
        AtriaTodayLiveStatusStrip(live: liveStore.state,
                                  pulse: pulseStore.state)
    }
}

private struct AtriaTodayLiveGlanceTileHost: View {
    let metric: AtriaTodayMetric
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    let layoutSize: AtriaTodayGlanceItem.LayoutSize
    let showsDetail: Bool
    let isBar: Bool

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayLiveGlanceTileHost")
        let live = liveStore.state
        if let item = Self.item(for: metric,
                                live: live,
                                layoutSize: layoutSize,
                                showsDetail: showsDetail) {
            AtriaTodayGlanceTile(item: item, isBar: isBar)
        }
    }

    private static func item(for metric: AtriaTodayMetric,
                             live: AtriaHomeModel.CoreLiveState,
                             layoutSize: AtriaTodayGlanceItem.LayoutSize,
                             showsDetail: Bool) -> AtriaTodayGlanceItem? {
        switch metric {
        case .steps:
            let steps = live.dailyStepPresentation
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: steps.valueText,
                                        detail: legendDetail(steps.detailText,
                                                             showsDetail: showsDetail),
                                        systemImage: metric.systemImage,
                                        tint: steps.count == nil ? .secondary
                                            : (steps.completeness == .complete ? .green : .orange),
                                        layoutSize: layoutSize)
        case .calories:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: live.liveActiveCaloriesText,
                                        detail: legendDetail(live.liveActiveCalories == nil ? "Needs profile" : "Estimate",
                                                             showsDetail: showsDetail),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize)
        default:
            return nil
        }
    }

    private static func legendDetail(_ detail: String, showsDetail: Bool) -> String {
        showsDetail ? detail : ""
    }
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
            // A zone needs a pulse, not calibration. Without a live heart rate
            // this pill could only ever read "Learning" — repeating, less
            // precisely and less actionably, what the Live pill beside it
            // already says ("Bluetooth off", "Disconnected"), and implying a
            // calibration that is not happening. It appears only when there is
            // a zone to show.
            if let heartRateZone = pulse.heartRateZone {
                AtriaTodayLivePill(title: "Zone",
                                   value: heartRateZone.shortLabel,
                                   systemImage: "waveform.path.ecg",
                                   tint: heartRateZone.tint)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live status. \(pulse.heartRate > 0 ? "\(pulse.heartRate) beats per minute" : live.status.rawValue).\(pulse.heartRateZone.map { " Zone \($0.shortLabel)." } ?? "")")
    }

    private var liveStatusText: String {
        if pulse.heartRate > 0 { return "\(pulse.heartRate) bpm" }
        return AtriaLiveSignalTruth.valueText(
            status: live.status,
            streamState: live.strapStreamState,
            hasRecentHeartRate: live.hasRecentHeartRateSample
        )
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
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }
}

private struct AtriaTodayPlanCard: View, Equatable {
    let title: String
    let detail: String
    let target: String
    let tint: Color
    let checkIn: AtriaJournalCheckInProgress
    let notificationFallback: Bool
    let onOpenJournal: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.target == rhs.target
            && lhs.tint == rhs.tint
            && lhs.checkIn == rhs.checkIn
            && lhs.notificationFallback == rhs.notificationFallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dailyBriefHeader

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onOpenJournal) {
                HStack(spacing: 10) {
                    Image(systemName: checkIn.isComplete ? "checkmark.circle.fill" : "square.and.pencil")
                        .font(.subheadline.weight(.bold))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(checkIn.actionLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(notificationFallback
                             ? "In-app reminder · \(checkIn.statusLabel)"
                             : checkIn.statusLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .tint(tint)
            .accessibilityLabel("\(checkIn.actionLabel). \(notificationFallback ? "In-app reminder. " : "")\(checkIn.statusLabel).")
            .accessibilityHint("Opens today's Journal check-in.")
        }
        .padding(14)
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile, emphasis: .soft)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var dailyBriefHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                dailyBriefLabel
                targetLabel
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                dailyBriefLabel
                Spacer(minLength: 8)
                targetLabel
            }
        }
    }

    private var dailyBriefLabel: some View {
        Label("Daily brief", systemImage: "sun.max.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }

    private var targetLabel: some View {
        Text(target)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
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
                // Honest learning state: recovery isn't trusted yet, so there is
                // no *personalized* target to show progress against -- never a
                // fabricated placeholder bar or target number. But the day strain
                // itself IS real, so show it and explain what the target will do
                // and when it unlocks (better than a bare gated message).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", currentStrain))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text("strain today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("Target learning")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        // Static guidance stays on a quiet readable surface. Liquid Glass is
        // reserved for the controls that act on it.
        .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile)
        .overlay {
            // Keep the per-metric tint stroke (its identity) on top of the glass --
            // same tint-stroke chrome as the glance tiles it sits beside.
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(target.map { "Strain target. \(String(format: "%.1f of %.1f", currentStrain, $0))." }
                             ?? "Strain today \(String(format: "%.1f", currentStrain)). Your daily target unlocks after a few nights of recovery data.")
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
                    Text(plan.dateRangeText)
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
            // This is reading content, not a control surface; keep it calm and
            // reserve Liquid Glass for the interactive button itself.
            .atriaCard(cornerRadius: AtriaDesignTokens.Radius.tile)
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
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
        case .workoutCount: return "figure.mixed.cardio"
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

            VStack(alignment: .leading, spacing: 4) {
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
            }
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.title). \(target.progressText). \(target.detail).")
    }
}

private struct AtriaTodayGlanceTile: View, Equatable {
    let item: AtriaTodayGlanceItem
    /// Horizontal "bar" layout (icon + label left, value right) for the
    /// one-per-row bars glance layout; false renders the default 2-up tile.
    var isBar: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaTodayGlanceTile, rhs: AtriaTodayGlanceTile) -> Bool {
        lhs.item == rhs.item && lhs.isBar == rhs.isBar
    }

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaTodayGlanceTile")
        if isBar {
            barBody
        } else {
            tileBody
        }
    }

    private var barBody: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                // Same pending inversion as tileBody -- see the note there. A
                // column of bars all reading "Learning" on the right is the same
                // failure as a grid of tiles doing it, so the name takes over as
                // the primary line until a real reading arrives.
                Text(item.title)
                    .font(item.isPending ? .subheadline.weight(.bold) : .caption.weight(.bold))
                    .foregroundStyle(item.isPending ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            Spacer(minLength: 8)
            Text(item.value)
                .font(item.isPending
                      ? .caption.weight(.semibold)
                      : .headline.weight(.bold).monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText())
                .foregroundStyle(item.isPending ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Identity-forward metric chip (design handoff: one hue per metric, on
        // the SURFACE, not only the icon + hairline). These tiles previously
        // hand-rolled an opaque neutral fill with a hue border only, so a row of
        // sleep/recovery/strain chips read as three grey boxes. Routing them
        // through the shared inset-card token also starts the Today deck's
        // migration onto the token layer it had been bypassing.
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.chip,
                        tint: item.tint,
                        hueTinted: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title). \(item.value). \(item.detail).")
    }

    private var tileBody: some View {
        // Reading order inside a tile is value -> label -> detail, but the type
        // scale used to contradict it: the value was .subheadline (15) against a
        // .caption (12) label, both .bold, so a 2-up grid of eight tiles read as
        // one flat field of text with nothing to scan. The value is the only
        // thing a glance is for, so it now takes .title3 while the label drops to
        // .semibold and recedes. Tile height stays put -- the stack gap tightens
        // from an off-scale 7 to Spacing.xs, paying for the larger number.
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.xs) {
            Image(systemName: item.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(item.tint)
                .frame(width: 24, height: 24)
            // Emphasis follows whichever line actually carries information. Once
            // there is a reading that is the value. Before there is one, every
            // tile's value collapses to the same placeholder word, so a default
            // grid of eight would shout "Learning" eight times while the metric
            // name -- the only thing still differing tile to tile -- hid in the
            // small grey line. Pending tiles therefore lead with the name and let
            // the state recede, so the grid stays scannable while it fills in.
            if item.isPending {
                Text(item.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(item.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(item.value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !item.detail.isEmpty && item.layoutSize != .wideShort {
                Text(item.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, minHeight: item.layoutSize.minHeight, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.md)
        // Consistency (2026-07-05): route the glance tile's corner radius through the
        // shared chip token instead of a hardcoded 8, so the deck's dominant card
        // shares one radius scale (chip < tile < card).
        // Identity hue now also washes the surface — see barBody for why.
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.chip,
                        tint: item.tint,
                        hueTinted: true)
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
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct AtriaTodayShortcutStrip: View, Equatable {
    let onStartWorkout: () -> Void

    static func == (lhs: AtriaTodayShortcutStrip, rhs: AtriaTodayShortcutStrip) -> Bool {
        true
    }

    var body: some View {
        Button(action: onStartWorkout) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Start activity")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: AtriaDesignTokens.Radius.chip))
        .tint(.blue)
        .accessibilityLabel("Start activity")
    }
}

private struct AtriaTodayHighlightsStrip: View, Equatable {
    static func == (lhs: AtriaTodayHighlightsStrip, rhs: AtriaTodayHighlightsStrip) -> Bool {
        lhs.highlights == rhs.highlights
    }

    let highlights: [AtriaHighlight]
    let onOpen: (AtriaMetricDetailKind) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(highlights) { highlight in
                // Rows with a metric route are real buttons; unrouted rows
                // stay plain and chevron-free (no fake affordances -- route
                // audit rule, 2026-07-07 design handoff).
                if let metric = highlight.metric {
                    Button {
                        onOpen(metric)
                    } label: {
                        highlightRow(highlight, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(highlight.valuePhrase) \(highlight.sentence)")
                    .accessibilityHint("Opens the \(metric.title) detail.")
                } else {
                    highlightRow(highlight, showsChevron: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(highlight.valuePhrase) \(highlight.sentence)")
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    private func highlightRow(_ highlight: AtriaHighlight, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: highlight.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(highlight.tint)
                .frame(width: 24, height: 24)

            Text(highlight.valuePhrase)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(highlight.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                // The value phrase (e.g. "3 nights", "↓ RHR") is the row's
                // identity — give it the higher priority so at large Dynamic
                // Type the sentence wraps instead of squeezing the value away.
                .layoutPriority(2)

            Text(highlight.sentence)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
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
            if compact {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity, minHeight: 42)
                .padding(.horizontal, 9)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)

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
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(compact && !value.isEmpty ? "\(title), \(value)" : title)
    }
}


/// The user-arrangeable big sections of the Today screen (everything below
/// the ring/live/highlights cluster). Raw values persist in
/// `atria.today.sectionOrder`; unknown values are dropped and missing ones
/// appended so the set can evolve.
enum AtriaTodaySection: String, CaseIterable, Identifiable {
    case plan, shortcuts, weeklyPlan, glance, coach

    var id: String { rawValue }

    static let defaultOrder: [AtriaTodaySection] = [.plan, .shortcuts, .weeklyPlan, .glance, .coach]
}

/// Classic SwiftUI reorder delegate: sections swap as the drag passes over
/// them; the persisted CSV updates on every move so the arrangement survives
/// even an interrupted drag.
private struct AtriaTodaySectionDropDelegate: DropDelegate {
    let item: AtriaTodaySection
    @Binding var order: [AtriaTodaySection]
    @Binding var dragging: AtriaTodaySection?

    func dropEntered(info: DropInfo) {
        guard let dragging,
              dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        var next = order
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
            order = next
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private extension View {
    /// `.draggable` has no disable switch; conditional composition is the
    /// only way to keep a tile inert outside edit mode.
    @ViewBuilder
    func draggableIf(_ enabled: Bool, _ payload: String) -> some View {
        if enabled {
            draggable(payload)
        } else {
            self
        }
    }
}
