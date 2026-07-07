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
    @State private var draggingSection: AtriaTodaySection?
    // User-arranged order of the big sections below the ring (2026-07-07
    // user feedback: "let people drag drop and arrange entire big sections").
    @AtriaDefault("atria.today.sectionOrder") private var todaySectionOrderCSV: String = ""
    @State private var showWeeklyReport = false
    @State private var showBreathworkSession = false
    @State private var ringShareImage: UIImage?
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
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    /// Optional display name set elsewhere in the app. Empty -- the default
    /// -- means no greeting is shown; never a fabricated name.
    @AtriaDefault("atria.user.nickname") private var nickname: String = ""
    // Glance layout: false = 2-up box grid (default), true = one full-width
    // horizontal bar per metric. The "boxes vs bars" user choice.
    @AtriaDefault("atria.overview.glanceLayoutBars") private var glanceLayoutBars: Bool = false

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
            AtriaMetricDetailSheet(metric: detail,
                                   rollups: highlightRollups,
                                   confirmedWorkouts: debugMetricDetailWorkouts ?? store.confirmedWorkouts,
                                   baseline: AtriaBaselineTargetSnapshot(store.baseline),
                                   sleepHistory: store.sleepHistorySnapshot,
                                   guidance: displayHero.guidance,
                                   recoveryEstimate: displayHero.recoveryEstimate,
                                   sleepGoalHours: sleepGoalHours,
                                   sleepBaseNeedHours: sleepBaseNeedHours,
                                   hrZoneMinutes: displayHero.hrZoneMinutes,
                                   maxHeartRate: store.profile.maxHR,
                                   vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                                   skinTemperatureDeviation: store.imuAuditSummary.skinTemperatureDeviation)
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

    /// Route audit (visibilitySpec §3, 2026-07-05): every glance tile used to
    /// dead-end on tap except Stress -- and even that was broken (see below),
    /// so in practice ALL of them dead-ended. Maps each metric to the detail
    /// kind it should open; tiles with no honest detail yet (load, workouts,
    /// steps, calories, trend, insights) are intentionally left out rather
    /// than routed to a placeholder.
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
    /// else). Everything else that has a real or honest-partial detail opens
    /// `metricDetail`; anything without one renders as a plain, non-tappable
    /// tile rather than a fake affordance.
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

    private var orderedTodaySections: [AtriaTodaySection] {
        let stored = todaySectionOrderCSV
            .split(separator: ",")
            .compactMap { AtriaTodaySection(rawValue: String($0)) }
        var order = stored.filter { AtriaTodaySection.defaultOrder.contains($0) }
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
            sectionKicker("Plan & tools")

            if layoutConfig.showPlan {
                AtriaTodayPlanCard(title: planTitle,
                                   detail: planDetail,
                                   target: planTargetText,
                                   tint: displayHero.guidance.color)
            }
        case .shortcuts:
            AtriaTodayShortcutStrip(journalValue: journalValue,
                                    onOpenJournal: onOpenJournal,
                                    onOpenShare: onOpenShare,
                                    onStartWorkout: onStartWorkout)
        case .weeklyPlan:
            if layoutConfig.showPlan {
                AtriaTodayWeeklyPlanCard(plan: weeklyPlan) {
                    showWeeklyReport = true
                }
            }
        case .glance:
            sectionKicker("At a glance")

            if glanceLayoutBars {
                // Bars layout: one full-width horizontal bar per metric.
                VStack(spacing: 10) {
                    ForEach(glanceItems) { item in
                        glanceTile(for: item, isBar: true)
                            .contextMenu {
                                Button(action: onCustomizeToday) {
                                    Label("Customize Today", systemImage: "slider.horizontal.3")
                                }
                            }
                    }
                }
            } else {
                LazyVGrid(columns: glanceColumns, spacing: 10) {
                    ForEach(glanceItems) { item in
                        glanceTile(for: item)
                            .gridCellColumns(glanceColumnSpan(for: item))
                            .contextMenu {
                                Button(action: onCustomizeToday) {
                                    Label("Customize Today", systemImage: "slider.horizontal.3")
                                }
                            }
                    }
                }
            }
        case .coach:
            if layoutConfig.showAICoach && effectiveAICoachSettings.mode != .off {
                AtriaAICoachCard(context: coachContext,
                                 preparedPayload: coachPayload,
                                 settings: effectiveAICoachSettings,
                                 hasAPIKey: aiCoachHasAPIKey,
                                 onSettingsChange: onAICoachSettingsChange,
                                 onSaveAPIKey: onSaveAICoachAPIKey,
                                 onDeleteAPIKey: onDeleteAICoachAPIKey)
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
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private var topActionMenu: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ringShareToolbarButton
            Menu {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        glanceLayoutBars.toggle()
                    }
                } label: {
                    Label(glanceLayoutBars ? "Show as grid" : "Show as bars",
                          systemImage: glanceLayoutBars ? "square.grid.2x2" : "rectangle.grid.1x2")
                }
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
                    .frame(width: 44, height: 44)
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
            // Perf pass (2026-07-06): `AtriaTodayHeroShrink` now OWNS the
            // scroll-shrink `progress` @State and the `.onScrollGeometryChange`
            // observation. Previously the progress lived on AtriaTodayScreen
            // and was read here, so every quantized scroll write re-evaluated
            // this whole property (ring construction + slot/metric plumbing)
            // AND the rest of the parent body. Now the per-step churn is fully
            // contained in the small child view -- the parent no longer reads
            // any scroll state, so it stops re-evaluating on scroll entirely.
            AtriaTodayHeroShrink(minScale: Self.heroMinScale) {
                AtriaTriRing(slots: ringSlots.map { AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0)) },
                             centerValue: centerValue,
                             centerState: centerState,
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
                    .frame(width: 44, height: 44)
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
                    .frame(width: 44, height: 44)
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

    /// Perf (docs/26 follow-up): `AtriaHighlights.topTwo` internally full-sorts
    /// the up-to-400-entry rollup history twice, and the body invoked it up to
    /// 4x per pass on every ~700ms live tick / scroll. Memoized behind
    /// `store.dailyRollupHistoryRevision` like every neighboring rollup
    /// derivation, so it recomputes at most once per rollup change.
    /// Behavior-preserving.
    private var highlights: [AtriaHighlight] {
        let revision = store.dailyRollupHistoryRevision
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
        if let latestSleep {
            return store.sleepHistorySnapshot.sleepPerformancePercent(for: latestSleep, baseNeedHours: sleepBaseNeedHours)
        }
        return latestRollup?.sleepPerformance
    }

    private var sleepMetric: AtriaTriRingMetric {
        let performance = sleepPerformancePercent
        // Hours-first, always: falls back to the rollup's stored duration
        // before ever falling back to a bare percent as the primary number.
        let value = latestSleep?.durationText
            ?? latestRollup?.sleepSeconds.map { AtriaMetricFormat.sleepDuration(seconds: $0) }
            ?? "Learning"   // canonical not-ready word (was "Building"); consistent across tabs
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
        // Time-to-detect (2026-07-05): recovery calibrates over ~4 nights. Instead
        // of a bare "Learning", show how far into that window the user is (matches
        // the overview surface's "Day X of 4"), so they know when a score arrives.
        return ("Learning", "Day \(recoveryCalibratingDay) of 4", nil)
    }

    /// Which day of the ~4-night recovery calibration the user is on. Shared by the
    /// ring center (`centerValue`) and the recovery legend chip (`displayRecovery`)
    /// so the two never disagree — the center used to hardcode "Day 1" while the
    /// legend showed the real day, which read as a bug on-device.
    private var recoveryCalibratingDay: Int {
        let samples = max(store.baseline.freshHRVSampleCount(),
                          store.baseline.freshRestingSampleCount())
        return min(max(samples + 1, 1), 4)
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
                                  // Honest value: `current` is the 60 math-fallback (always > 0),
                                  // so the old `current > 0 ? "\(current)"` always showed a
                                  // fabricated 60. restingHeartRateText is "Learning" until there
                                  // is a real reading, matching the RHR glance tile and Vitals row.
                                  value: displayHero.restingHeartRateText,
                                  detail: legendDetail("bpm"),
                                  systemImage: "heart.fill",
                                  tint: .pink,
                                  fill: fill)
    }

    private var latestRollup: DailyRollupStoreEntry? {
        dayDescendingRollups.first
    }

    /// The current week's plan. `WeeklyPlanStore().currentPlan` does
    /// synchronous disk I/O (read + generate + atomic write on a cache miss),
    /// so it must never run from a body-level computed property on the scroll
    /// path -- memoize it behind the rollup revision (measured-perf pass,
    /// 2026-07-06). The plan only depends on the rollups, so this recomputes
    /// at most once per actual rollup change, not on every scroll/live eval.
    private var weeklyPlan: WeeklyPlan {
        let revision = store.dailyRollupHistoryRevision
        if glanceMemo.weeklyPlanRevision == revision, let cached = glanceMemo.weeklyPlanValue {
            return cached
        }
        let plan = WeeklyPlanStore().currentPlan(rollups: highlightRollups)
        glanceMemo.weeklyPlanRevision = revision
        glanceMemo.weeklyPlanValue = plan
        return plan
    }

    private var weeklyReport: WeeklyReport {
        WeeklyReport(rollups: highlightRollups)
    }

    private var centerValue: String {
        switch layoutConfig.ringCenterMetric {
        case .recovery:
            return displayRecovery.percent != nil ? displayRecovery.value : "Day \(recoveryCalibratingDay)"
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
            // "Learning" (not "Building") to match the recovery legend chip's word
            // for the same calibrating state.
            return displayRecovery.percent.map(recoveryState) ?? "Learning"
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
        displayHero.recoveryEstimate.percent.map { "\($0)% recovery" } ?? "Learning"
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
        guard let target = displayHero.guidance.target else { return "Target building" }
        let remaining = target - displayHero.strain
        if remaining > 0.05 {
            return String(format: "Target %.1f \u{00b7} %.1f to go", target, remaining)
        }
        return String(format: "Target %.1f \u{00b7} met", target)
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

    /// The AI-coach narrative payload. Building it sorts and ISO/weekday-
    /// formats the last-7 rollups, so -- like `weeklyPlan` -- it must not run
    /// from a body computed property on the scroll/live path. Memoized behind
    /// the rollup revision (measured-perf pass, 2026-07-06): the payload is
    /// rollup-driven (the live `coachContext` is only a cold-start fallback
    /// for the narrative, which changes slowly), so a once-per-rollup-change
    /// refresh is correct and keeps the coaching copy stable between updates.
    private var coachPayload: AtriaCoachPayload {
        let revision = store.dailyRollupHistoryRevision
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
                                        detail: legendDetail(isPendingHeroValue(displayHero.hrvValue)
                                                             ? baselineNightsProgress(store.baseline.freshHRVSampleCount())
                                                             : displayHero.hrvDetail),
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
        case .sleepPerformance:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        // Same source the sleep ring uses (computed from the latest
                                        // sleep, falling back to the rollup) so the tile and ring can't
                                        // show two different sleep-performance percentages.
                                        value: sleepPerformancePercent.map { "\($0)%" } ?? "Learning",
                                        detail: legendDetail("of need"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricSleep,
                                        layoutSize: layoutSize(for: metric))
        case .rhr:
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: displayHero.restingHeartRateText,
                                        // RHR is measured nightly and is shown from night 1, so unlike
                                        // HRV it has no multi-night "calibrating" value state — its text
                                        // is always numeric. Keep the plain unit; a nights-progress
                                        // caption here would mislabel a ready reading as pending.
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
            // Consistency + detection fix (2026-07-05): the Today deck hard-coded
            // "Building" while the overview surface (AtriaOverviewReadinessSection)
            // already shows the real strap-movement step estimate. Mirror it exactly:
            // this strap has no validated pedometer, only an experimental IMU step
            // count, so show it when present and say so honestly when it isn't.
            let stepSensor = store.imuAuditSummary
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: stepSensor.strapStepText,
                                        detail: legendDetail(stepSensor.strapStepCount > 0 ? "Strap movement" : "Not available on this strap"),
                                        systemImage: metric.systemImage,
                                        tint: stepSensor.strapStepCount > 0 ? .green : .secondary,
                                        layoutSize: layoutSize(for: metric))
        case .calories:
            // Detection fix (2026-07-05): the card hard-coded "Building" and never
            // showed a number, though the live active-calorie estimate is already
            // computed and surfaced elsewhere (AtriaHomeView/live workout). Wire the
            // real value; fall back to an honest "Profile needed" when the estimate
            // can't be produced (missing athlete profile), never a fake placeholder.
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: liveStore.state.liveActiveCaloriesText,
                                        detail: legendDetail(liveStore.state.liveActiveCalories == nil ? "Needs profile" : "Estimate"),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricStrain,
                                        layoutSize: layoutSize(for: metric))
        case .vo2max:
            // Time-to-detect (2026-07-05): when the estimate isn't ready yet, show
            // the summary's specific calibration progress ("12/14 RHR", "Need HRmax")
            // instead of a generic "Estimate", so users see how far off a reading is.
            let vo2 = profileMetricsStore.state.vo2MaxEstimate
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: vo2.valueText,
                                        detail: legendDetail(vo2.value == nil ? vo2.detail : "Estimate"),
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
                                        detail: legendDetail(bioAge.isReady ? "Estimate" : bioAge.narrative),
                                        systemImage: metric.systemImage,
                                        tint: Metrics.electricGreen,
                                        layoutSize: layoutSize(for: metric))
        case .bloodOxygen:
            // Honest permanent state (2026-07-05): this strap's hardware has no
            // validated SpO2 path -- "Building"/"Signal" implied a percentage was
            // coming. It never is, so this is a stable, non-promissory state
            // (mirrors the steps honesty pattern), not a "still learning" one.
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: "\u{2014}",
                                        detail: legendDetail("Not available on this strap"),
                                        systemImage: metric.systemImage,
                                        tint: .secondary,
                                        layoutSize: layoutSize(for: metric))
        case .bodyTemp:
            // Detection fix (2026-07-05): the card hard-coded "Building" while the
            // real relative skin-temperature deviation is already computed and shown
            // on the Vitals tab (AtriaHealthScreen). Surface the same value/detail so
            // the primary deck stops hiding data the app already has. valueText is
            // "--" until the sleep baseline matures, so this stays honest.
            let skinTemp = store.imuAuditSummary.skinTemperatureDeviation
            return AtriaTodayGlanceItem(title: metric.label,
                                        metricKey: metric.rawValue,
                                        value: skinTemp.valueText,
                                        detail: legendDetail(skinTemp.detailText),
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
                                        value: "\(highlights.count)",
                                        detail: legendDetail("Highlights"),
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

    /// Pending-value set matching the app-wide convention (see AtriaHomeView's
    /// pending check): a metric that has no reading yet, so its tile can show
    /// time-to-detect progress instead of the bare placeholder.
    private func isPendingHeroValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed == "--" || trimmed == "\u{2014}"
            || trimmed == "Learning" || trimmed == "Building" || trimmed == "Preparing"
    }

    /// Honest "N of 14 nights" progress for the 14-night personal baselines
    /// (HRV/RHR), so a pending tile says how far along detection is.
    private func baselineNightsProgress(_ samples: Int) -> String {
        "\(min(samples, PersonalBaseline.trustedMinimumSamples)) of \(PersonalBaseline.trustedMinimumSamples) nights"
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
    var highlightsRevision: Int?
    var highlightsValue: [AtriaHighlight]?
    // Perf pass (2026-07-06 scroll-hang fix): the weekly plan card ran
    // `WeeklyPlanStore().currentPlan` -- synchronous disk read (+ generate +
    // atomic write on a cache miss) -- and the AI coach payload sorted and
    // ISO-formatted the last-7 rollups, both from computed properties read
    // directly in `body`. That put file I/O and a sort on the scroll path:
    // `body` re-evaluates on every quantized hero-shrink step and every
    // ~750ms live tick, so on a device with a real rollup file these were
    // the dominant cause of the reported scroll "hang"/lag (invisible in the
    // simulator, which has no saved plan file and no scroll-under-load).
    // Cache both behind `store.dailyRollupHistoryRevision` so they run at
    // most once per actual rollup change, never on the scroll/live path.
    var weeklyPlanRevision: Int?
    var weeklyPlanValue: WeeklyPlan?
    var coachPayloadRevision: Int?
    var coachPayloadValue: AtriaCoachPayload?
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
            // Apple-Fitness-style scroll shrink -- scales/fades toward the
            // top edge only (never sideways) so the rings visually recede as
            // the user scrolls further content up over them. Reduce Motion
            // pins both to their resting values.
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
                               value: pulse.heartRateZone?.shortLabel ?? "Learning",
                               systemImage: "waveform.path.ecg",
                               tint: pulse.heartRateZone?.tint ?? .secondary)
            AtriaTodayLivePill(title: "Battery",
                               value: batteryPillText,
                               systemImage: live.batterySymbol,
                               tint: batteryPillTint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live status. \(pulse.heartRate > 0 ? "\(pulse.heartRate) beats per minute" : live.status.rawValue). Zone \(pulse.heartRateZone?.shortLabel ?? "building"). \(live.batteryAccessibilityText)")
    }

    /// Charging is visible on the home strip (user feedback 2026-07-07) and
    /// composes with Live -- the strap can be Live and Charging at once.
    /// States are mutually honest: Charging only with real charging evidence
    /// (batteryShowsPowered), Low only when NOT charging, plain % otherwise.
    private var batteryPillText: String {
        guard live.batteryLevel >= 0 else { return "Pending" }
        if live.batteryShowsPowered { return "\(live.batteryText) \u{00b7} Charging" }
        if live.batteryLevel <= 20 { return "\(live.batteryText) \u{00b7} Low" }
        return live.batteryText
    }

    private var batteryPillTint: Color {
        guard live.batteryLevel >= 0 else { return .secondary }
        if live.batteryShowsPowered { return .green }
        if live.batteryLevel <= 20 { return .orange }
        return .blue
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
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
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
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12),
                            in: Capsule())
        }
        .padding(12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
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
                }
                Text("Your daily target unlocks after a few nights of recovery data — higher when you're well recovered, lower when you need rest.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        // Prominent full-width card: subtle Liquid Glass + the shared `tile` radius,
        // matching the weekly-plan card so the big cards read as one intentional tier
        // (dense glance tiles stay flat for scroll perf). Verified legible on-sim in
        // light and dark before applying to the sibling prominent cards.
        .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.tile)
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
            // Prominent full-width card: subtle Liquid Glass + the shared `tile`
            // radius, matching the strain-target card so the big cards read as one
            // intentional tier (dense glance tiles stay flat for scroll perf).
            .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.tile)
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
                Text(item.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                .font(.headline.weight(.bold).monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                .stroke(item.tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title). \(item.value). \(item.detail).")
    }

    private var tileBody: some View {
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
                .minimumScaleFactor(0.75)
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
        // Consistency (2026-07-05): route the glance tile's corner radius through the
        // shared chip token instead of a hardcoded 8, so the deck's dominant card
        // shares one radius scale (chip < tile < card).
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
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
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
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
                .minimumScaleFactor(0.75)
                .layoutPriority(1)

            Text(highlight.sentence)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(2)

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
                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
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
        withAnimation(.snappy(duration: 0.25)) {
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
