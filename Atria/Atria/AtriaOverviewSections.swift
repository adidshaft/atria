import SwiftUI

/// Top-level segments for the Today tab so the home screen is selectable views
/// instead of one long scroll.
enum AtriaTodaySegment: String, CaseIterable, Identifiable {
    case today
    case trends
    case data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .trends: return "Trends"
        case .data: return "Data"
        }
    }
}

struct AtriaOverviewTabContent: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let horizontalSizeClass: UserInterfaceSizeClass?
    let connectionContext: AtriaConnectionGuideContext
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    @State private var segment: AtriaTodaySegment = .today

    private var segmentPicker: some View {
        HStack(spacing: 6) {
            ForEach(AtriaTodaySegment.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { segment = item }
                } label: {
                    Text(item.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .atriaGlassSelectable(selected: segment == item)
            }
        }
    }

    var body: some View {
        Group {
            if statusStore.state.status != .connected {
                if hasUnlockedSecondarySections {
                    AtriaDisconnectedOverviewHost(statusStore: statusStore,
                                                 liveStore: liveStore,
                                                 heroStore: heroStore,
                                                 homeStatsStore: homeStatsStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 context: connectionContext,
                                                 onShowConnectionGuide: onShowConnectionGuide,
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection)
                }
            } else if !hasUnlockedSecondarySections {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(liveStore: liveStore,
                                             heroStore: heroStore,
                                             homeStatsStore: homeStatsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             segment: .today,
                                             hasUnlockedSecondarySections: false,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection)
                    AtriaLoadingPanel(title: "Preparing saved insights",
                                      subtitle: "Trends, backup, and data summaries join after the first live dashboard settles.")
                }
            } else if horizontalSizeClass == .regular {
                VStack(spacing: 18) {
                    segmentPicker
                    HStack(alignment: .top, spacing: 18) {
                        LazyVStack(spacing: 18) {
                            AtriaOverviewLeadingHost(liveStore: liveStore,
                                                     heroStore: heroStore,
                                                     homeStatsStore: homeStatsStore,
                                                     snapshotStore: snapshotStore,
                                                     store: store,
                                                     segment: segment,
                                                     hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                     aiCoachSettings: aiCoachSettings,
                                                     aiCoachHasAPIKey: aiCoachHasAPIKey,
                                                     onAICoachSettingsChange: onAICoachSettingsChange,
                                                     onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                                     onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                                     onOpenVitals: onOpenVitals,
                                                     onOpenCollection: onOpenCollection)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        LazyVStack(spacing: 18) {
                            AtriaOverviewTrailingHost(liveStore: liveStore,
                                                      homeStatsStore: homeStatsStore,
                                                      snapshotStore: snapshotStore,
                                                      segment: segment,
                                                      hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                      onOpenCollection: onOpenCollection)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            } else {
                LazyVStack(spacing: 18) {
                    segmentPicker
                    AtriaOverviewLeadingHost(liveStore: liveStore,
                                             heroStore: heroStore,
                                             homeStatsStore: homeStatsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             segment: segment,
                                             hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection)
                    AtriaOverviewTrailingHost(liveStore: liveStore,
                                              homeStatsStore: homeStatsStore,
                                              snapshotStore: snapshotStore,
                                              segment: segment,
                                              hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                              onOpenCollection: onOpenCollection)
                }
            }
        }
    }
}

private struct AtriaDisconnectedOverviewHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    private var hasTrendHistory: Bool {
        store.overviewTrendPoints.count >= 2
    }

    /// Returning users have saved sessions on device. Gate on real saved data —
    /// not `hasEverConnected`, which resets each launch and would wrongly show
    /// the first-setup panel to a returning user who reopens the app while away.
    private var hasSavedData: Bool {
        !store.sessions.isEmpty
    }

    var body: some View {
        VStack(spacing: 18) {
            if !hasSavedData {
                // Brand-new: the user has no saved data yet, so lead with the
                // one-time setup guidance.
                AtriaDisconnectedOverviewPanel(status: statusStore.state.status,
                                               stats: homeStatsStore.state,
                                               snapshot: snapshotStore.state,
                                               context: context,
                                               onShowConnectionGuide: onShowConnectionGuide,
                                               onOpenVitals: onOpenVitals,
                                               onOpenCollection: onOpenCollection)
                    .equatable()
            } else {
                // Returning user: their saved rings are the content. Reconnect
                // status is already the toolbar chip + the slim banner above, so
                // no second "Waiting for your strap" panel here.
                AtriaOverviewReadinessSectionHost(liveStore: liveStore,
                                                 heroStore: heroStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 subtitle: "Last saved readiness")

                // Trends are local history — show them even while the strap is away.
                if hasTrendHistory {
                    AtriaOverviewTrendChartHost(store: store)
                }
            }
        }
    }
}

private struct AtriaDisconnectedOverviewPanel: View, Equatable {
    let status: AtriaBLEManager.Status
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaDisconnectedOverviewPanel, rhs: AtriaDisconnectedOverviewPanel) -> Bool {
        lhs.status == rhs.status
            && lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
            && lhs.context == rhs.context
    }

    private var tint: Color {
        switch status {
        case .connecting, .scanning:
            return .orange
        case .poweredOff:
            return .red
        case .disconnected:
            return .blue
        case .connected:
            return .green
        }
    }

    private var systemImage: String {
        switch status {
        case .connecting:
            return "bolt.horizontal.fill"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .poweredOff:
            return "bolt.slash.fill"
        case .disconnected:
            return "bolt.horizontal.circle"
        case .connected:
            return "bolt.heart.fill"
        }
    }

    private var title: String {
        switch status {
        case .connecting:
            return "Connecting to your strap"
        case .scanning:
            return "Looking for your strap"
        case .poweredOff:
            return "Bluetooth is off"
        case .disconnected:
            return "Waiting for your strap"
        case .connected:
            return "Live data is flowing"
        }
    }

    private var detail: String {
        switch status {
        case .connecting:
            return "Linking with strap."
        case .scanning:
            return "Searching nearby."
        case .poweredOff:
            return "Turn Bluetooth on."
        case .disconnected:
            return "Keep strap nearby."
        case .connected:
            return "Saved insights prepare after the live connection settles."
        }
    }

    private var setupDetail: String {
        if context.officialAppCoexistenceRisk == .suspected {
            return "Remove the official strap app first."
        }
        switch status {
        case .connecting:
            return "Keep phone nearby."
        case .scanning:
            return "Scanning automatically."
        case .poweredOff:
            return "Bluetooth required."
        case .disconnected:
            return "Free strap from the official app."
        case .connected:
            return "Reconnects automatically."
        }
    }

    private var setupItems: [String] {
        var items = [
            "Remove the official strap app",
            "Keep strap nearby",
            "Let Atria scan"
        ]
        if context.officialAppCoexistenceRisk == .suspected {
            items[2] = "Reconnect in Atria"
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Overview", subtitle: title)

                Spacer(minLength: 0)
            }

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Single adaptive grid renders the tiles once, avoiding duplicate
            // layout measurement during scroll.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                AtriaInlineQuickStat(label: "Personal baseline", value: snapshot.referenceText)
                AtriaInlineQuickStat(label: "Saved days", value: "\(stats.baselineSamples)/7")
                AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                AtriaDisconnectedOverviewAutomaticCard(status: status,
                                                       tint: tint,
                                                       setupDetail: setupDetail,
                                                       context: context,
                                                       onShowConnectionGuide: onShowConnectionGuide)

                AtriaDisconnectedOverviewChecklistCard(title: context.isFirstHandoff ? "Do once before Atria takes over" : "Only if another app grabs the strap again",
                                                       items: setupItems,
                                                       tint: .orange)

                AtriaDisconnectedOverviewSavedStateCard(stats: stats,
                                                        snapshot: snapshot,
                                                        tint: tint)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaOverviewLeadingHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let segment: AtriaTodaySegment
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewLeadingSection(liveStore: liveStore,
                                   heroStore: heroStore,
                                   homeStatsStore: homeStatsStore,
                                   snapshotStore: snapshotStore,
                                   store: store,
                                   segment: segment,
                                   hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                   aiCoachSettings: aiCoachSettings,
                                   aiCoachHasAPIKey: aiCoachHasAPIKey,
                                   onAICoachSettingsChange: onAICoachSettingsChange,
                                   onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                   onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                   onOpenVitals: onOpenVitals,
                                   onOpenCollection: onOpenCollection)
    }
}

private struct AtriaOverviewTrailingHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let segment: AtriaTodaySegment
    let hasUnlockedSecondarySections: Bool
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewTrailingSection(liveStore: liveStore,
                                     homeStatsStore: homeStatsStore,
                                     snapshotStore: snapshotStore,
                                     segment: segment,
                                     hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                     onOpenCollection: onOpenCollection)
    }
}

struct AtriaOverviewLeadingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let segment: AtriaTodaySegment
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    @AppStorage(AtriaTodayMetric.storageKey) private var hiddenCSV: String = ""

    var body: some View {
        VStack(spacing: 16) {
            if segment == .today {
                AtriaOverviewReadinessSectionHost(liveStore: liveStore,
                                                 heroStore: heroStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 subtitle: "")

                // Simple one-line "what to do today" guidance. No AI coach, no
                // setup checklist, no strain-target maths — kept direct.
                AtriaOverviewGuidanceSectionHost(heroStore: heroStore)

                AtriaOverviewMorningJournalHost(heroStore: heroStore,
                                                snapshotStore: snapshotStore,
                                                store: store)

                if !AtriaTodayMetric.hidden(from: hiddenCSV).contains(AtriaTodayMetric.insights.rawValue) {
                    AtriaInsightsCardHost(store: store)
                }
            }

            if segment == .trends && hasUnlockedSecondarySections {
                if snapshotStore.diagnosticsReady {
                    AtriaOverviewTrendChartHost(store: store)
                } else {
                    AtriaLoadingPanel(title: "Preparing trends",
                                      subtitle: "Saved trends stay off the launch path and load after the first screen is stable.")
                }

                AtriaOverviewBehaviorJournalSection(store: store)
            }
        }
    }
}

struct AtriaOverviewReadinessSectionHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore
    let subtitle: String

    @AppStorage(AtriaTodayMetric.storageKey) private var hiddenCSV: String = ""
    @AppStorage(AtriaTodayMetric.orderStorageKey) private var orderCSV: String = ""

    var body: some View {
        AtriaOverviewReadinessSection(hero: heroStore.state,
                                     live: liveStore.state,
                                     snapshot: snapshotStore.state,
                                     trendValues: store.restingTrend14,   // Phase-0 cache (no per-render sort)
                                     subtitle: subtitle,
                                     visibleMetrics: AtriaTodayMetric.visibleOrdered(orderCSV: orderCSV,
                                                                                    hiddenCSV: hiddenCSV),
                                     onMoveMetric: moveMetric)
            .equatable()
    }

    private func moveMetric(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric) {
        orderCSV = AtriaTodayMetric.moving(dragged, before: target, in: orderCSV)
    }

}

/// Metrics the user can show/hide on the Today glance (Settings → Today screen).
enum AtriaTodayMetric: String, CaseIterable, Identifiable {
    case recovery, strain, hrv, sleep, rhr, steps, calories, trend, insights
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .hrv: return "HRV"
        case .sleep: return "Sleep"
        case .rhr: return "Resting HR"
        case .steps: return "Steps"
        case .calories: return "Calories"
        case .trend: return "Resting trend"
        case .insights: return "Insights"
        }
    }
    var systemImage: String {
        switch self {
        case .recovery: return "heart.fill"
        case .strain: return "bolt.heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleep: return "moon.zzz.fill"
        case .rhr: return "heart.text.square.fill"
        case .steps: return "shoeprints.fill"
        case .calories: return "flame.fill"
        case .trend: return "chart.xyaxis.line"
        case .insights: return "chart.line.uptrend.xyaxis"
        }
    }

    var glanceColumnSpan: Int {
        switch self {
        case .trend:
            return 2
        default:
            return 1
        }
    }
    /// Persisted as a comma-separated list of HIDDEN raw values, so the default
    /// (empty) shows everything.
    static let storageKey = "atriaTodayHiddenMetrics"
    static let orderStorageKey = "atria.overview.glanceOrderCSV"

    static var defaultGlanceOrder: [AtriaTodayMetric] {
        [.recovery, .strain, .hrv, .sleep, .rhr, .steps, .calories, .trend]
    }

    static func hidden(from csv: String) -> Set<String> {
        Set(csv.split(separator: ",").map(String.init))
    }

    static func ordered(from csv: String) -> [AtriaTodayMetric] {
        let decoded = csv.split(separator: ",").compactMap { AtriaTodayMetric(rawValue: String($0)) }
        var result: [AtriaTodayMetric] = []
        var seen = Set<AtriaTodayMetric>()
        for metric in decoded + defaultGlanceOrder {
            guard defaultGlanceOrder.contains(metric), !seen.contains(metric) else { continue }
            result.append(metric)
            seen.insert(metric)
        }
        return result
    }

    static func visibleOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric] {
        let hidden = hidden(from: hiddenCSV)
        return ordered(from: orderCSV).filter { !hidden.contains($0.rawValue) }
    }

    static func moving(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric, in csv: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        var order = ordered(from: csv).filter { $0 != dragged }
        let insertIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: insertIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ metric: AtriaTodayMetric, direction: Int, in csv: String) -> String {
        var order = ordered(from: csv)
        guard let index = order.firstIndex(of: metric) else { return order.map(\.rawValue).joined(separator: ",") }
        let next = max(0, min(order.count - 1, index + direction))
        guard next != index else { return order.map(\.rawValue).joined(separator: ",") }
        order.swapAt(index, next)
        return order.map(\.rawValue).joined(separator: ",")
    }
}

private extension Array where Element == AtriaTodayMetric {
    var glanceRowID: String {
        map(\.rawValue).joined(separator: "-")
    }
}

struct AtriaOverviewReadinessSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let live: AtriaHomeModel.CoreLiveState
    let snapshot: AtriaHomeModel.Snapshot
    let trendValues: [Int]
    let subtitle: String
    let visibleMetrics: [AtriaTodayMetric]
    let onMoveMetric: (AtriaTodayMetric, AtriaTodayMetric) -> Void

    // Compare ONLY the values this card actually displays. The full `live` state
    // ticks on every battery/sample update; without this the glance (2 rings + 5
    // tiles + sparkline) rebuilt on every BLE tick. Now it rebuilds only when a
    // shown number changes — the main connected-state scroll-lag fix.
    static func == (lhs: AtriaOverviewReadinessSection, rhs: AtriaOverviewReadinessSection) -> Bool {
        lhs.subtitle == rhs.subtitle
            && lhs.trendValues == rhs.trendValues
            && lhs.hero.recoveryEstimate.percent == rhs.hero.recoveryEstimate.percent
            && lhs.hero.recoveryValue == rhs.hero.recoveryValue
            && lhs.hero.strainValue == rhs.hero.strainValue
            && lhs.hero.hrvValue == rhs.hero.hrvValue
            && lhs.hero.hrvDetail == rhs.hero.hrvDetail
            && lhs.hero.restingHeartRateText == rhs.hero.restingHeartRateText
            && lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.live.phoneStepsText == rhs.live.phoneStepsText
            && lhs.live.liveActiveCaloriesText == rhs.live.liveActiveCaloriesText
            && lhs.visibleMetrics == rhs.visibleMetrics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AtriaPanelSectionHeader(title: "Today at a glance", subtitle: subtitle)

            if visibleMetrics.isEmpty {
                Text("Choose Today cards in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .atriaInsetCard(tint: .secondary)
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(glanceRows, id: \.glanceRowID) { row in
                        GridRow {
                            ForEach(row) { metric in
                                glanceCard(metric)
                                    .gridCellColumns(metric.glanceColumnSpan)
                                    .draggable(metric.rawValue)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let raw = items.first,
                                              let dragged = AtriaTodayMetric(rawValue: raw) else { return false }
                                        onMoveMetric(dragged, metric)
                                        return true
                                    }
                            }

                            if row.count == 1, row.first?.glanceColumnSpan == 1 {
                                Color.clear
                                    .frame(maxWidth: .infinity, minHeight: AtriaGlanceMetricCard.cardHeight)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .strong)
        // Flatten this heavy card (card + rings + tiles + sparkline) into one
        // cached GPU texture. It's Equatable so it rarely rebuilds, so the texture
        // stays valid and scrolling just blits it instead of recompositing ~20
        // layers per frame.
        .drawingGroup()
    }

    private var glanceRows: [[AtriaTodayMetric]] {
        var rows: [[AtriaTodayMetric]] = []
        var pending: [AtriaTodayMetric] = []
        for metric in visibleMetrics {
            if metric.glanceColumnSpan == 2 {
                if !pending.isEmpty {
                    rows.append(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                rows.append([metric])
            } else {
                pending.append(metric)
                if pending.count == 2 {
                    rows.append(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        if !pending.isEmpty {
            rows.append(pending)
        }
        return rows
    }

    @ViewBuilder
    private func glanceCard(_ metric: AtriaTodayMetric) -> some View {
        switch metric {
        case .recovery:
            AtriaGlanceMetricCard(title: "Recovery",
                                  value: hero.recoveryEstimate.percent == nil ? "--" : hero.recoveryValue,
                                  detail: "Today",
                                  systemImage: metric.systemImage,
                                  tint: recoveryColor(hero.recoveryEstimate.percent),
                                  ringFraction: hero.recoveryEstimate.percent.map { Double($0) / 100 })
        case .strain:
            AtriaGlanceMetricCard(title: "Strain",
                                  value: metricDisplayValue(hero.strainValue),
                                  detail: "Day load",
                                  systemImage: metric.systemImage,
                                  tint: .orange,
                                  ringFraction: metricIsPending(hero.strainValue) ? nil : min(max(hero.strain / 21, 0), 1))
        case .hrv:
            AtriaGlanceMetricCard(title: "HRV",
                                  value: metricDisplayValue(hero.hrvValue),
                                  detail: hrvLearningState == .learning ? "Building" : "Baseline",
                                  systemImage: metric.systemImage,
                                  tint: .pink)
        case .sleep:
            AtriaGlanceMetricCard(title: "Sleep",
                                  value: metricDisplayValue(snapshot.sleepValue),
                                  detail: metricIsPending(snapshot.sleepValue) ? "Learning" : "Last sleep",
                                  systemImage: metric.systemImage,
                                  tint: .cyan)
        case .rhr:
            AtriaGlanceMetricCard(title: "RHR",
                                  value: metricDisplayValue(hero.restingHeartRateText),
                                  detail: "Baseline",
                                  systemImage: metric.systemImage,
                                  tint: .red)
        case .steps:
            AtriaGlanceMetricCard(title: "Steps",
                                  value: live.phoneStepsText,
                                  detail: live.phoneStepsToday > 0 ? "iPhone motion" : "Building",
                                  systemImage: metric.systemImage,
                                  tint: .green)
                .accessibilityLabel("Steps counted by iPhone motion \(live.phoneStepsText)")
        case .calories:
            AtriaGlanceMetricCard(title: "Calories",
                                  value: live.liveActiveCaloriesText,
                                  detail: live.liveActiveCalories == nil ? "Needs profile" : "Estimate",
                                  systemImage: metric.systemImage,
                                  tint: .orange)
                .accessibilityLabel("Active calories estimate \(live.liveActiveCaloriesText)")
        case .trend:
            trendCard
        case .insights:
            EmptyView()
        }
    }

    private var trendCard: some View {
        AtriaGlanceMetricCard(title: "Resting trend",
                              value: trendValues.count > 1 ? "\(trendValues.last ?? 0)" : "--",
                              detail: trendValues.count > 1 ? "14 sessions" : "Building",
                              systemImage: AtriaTodayMetric.trend.systemImage,
                              tint: .red,
                              sparklineValues: trendValues.count > 1 ? trendValues : [0, 0])
    }

    private var hrvLearningState: AtriaMetricState {
        hero.hrvDetail.localizedCaseInsensitiveContains("personal") ? .personalBaseline : .learning
    }

    private func metricDisplayValue(_ value: String) -> String {
        metricIsPending(value) ? "--" : value
    }

    private func metricIsPending(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func recoveryColor(_ percent: Int?) -> Color {
        guard let percent else { return .secondary }
        if percent >= 67 { return .green }
        if percent >= 34 { return .yellow }
        return .red
    }

}

private struct AtriaGlanceMetricCard: View, Equatable {
    static let cardHeight: CGFloat = 154
    private static let markerSize: CGFloat = 42
    private static let footerHeight: CGFloat = 34

    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    var ringFraction: Double? = nil
    var sparklineValues: [Int]? = nil

    private var usesProgressRing: Bool {
        title == "Recovery" || title == "Strain"
    }

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                marker

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayValue)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Spacer(minLength: 0)
            }

            footer
        }
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .leading)
        .padding(13)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value), \(detail)")
    }

    @ViewBuilder
    private var footer: some View {
        if let sparklineValues {
            Sparkline(values: sparklineValues)
                .frame(height: Self.footerHeight)
                .opacity(sparklineValues.count > 1 ? 1 : 0.28)
                .accessibilityLabel("\(title) sparkline")
        } else if usesProgressRing, let ringFraction {
            HStack(spacing: 6) {
                ProgressView(value: min(max(ringFraction, 0), 1))
                    .tint(tint)
                    .controlSize(.mini)
                Text("\(Int((min(max(ringFraction, 0), 1) * 100).rounded()))%")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.9))
            }
            .frame(height: Self.footerHeight, alignment: .center)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                Text(detail)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(tint.opacity(0.72))
            .frame(height: Self.footerHeight, alignment: .center)
            .accessibilityHidden(true)
        }
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                }

            if usesProgressRing {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 4)

                if let ringFraction {
                    Circle()
                        .trim(from: 0, to: min(max(ringFraction, 0), 1))
                        .stroke(tint.gradient,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [3, 6]))
                }
            }

            Image(systemName: systemImage)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: Self.markerSize, height: Self.markerSize)
        .accessibilityHidden(true)
    }
}

struct AtriaOverviewLaunchChecklistHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewLaunchChecklist(live: liveStore.state,
                                     stats: homeStatsStore.state,
                                     snapshot: snapshotStore.state,
                                     onOpenVitals: onOpenVitals,
                                     onOpenCollection: onOpenCollection)
            .equatable()
    }
}

struct AtriaOverviewLaunchChecklist: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaOverviewLaunchChecklist, rhs: AtriaOverviewLaunchChecklist) -> Bool {
        lhs.live == rhs.live
            && lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
    }

    private var completeCount: Int {
        checklistItems.filter(\.isComplete).count
    }

    private var checklistItems: [AtriaLaunchChecklistItem] {
        [
            // Connection status lives in the toolbar chip; not repeated here.
            AtriaLaunchChecklistItem(id: "baseline",
                                     title: "HRV baseline",
                                     value: "\(stats.baselineSamples)/7",
                                     detail: stats.baselineSamples >= 7 ? "Personal baseline is ready." : "Wear overnight to improve recovery confidence.",
                                     systemImage: "waveform.path.ecg",
                                     tint: stats.baselineSamples >= 7 ? .green : .pink,
                                     isComplete: stats.baselineSamples >= 7,
                                     actionTitle: nil,
                                     action: nil),
            AtriaLaunchChecklistItem(id: "capture",
                                     title: "Live recording",
                                     value: snapshot.loggingText,
                                     detail: snapshot.loggingText.localizedCaseInsensitiveContains("samples") ? "Atria is saving your readings." : stats.nextAction,
                                     systemImage: "waveform.badge.plus",
                                     tint: snapshot.loggingText.localizedCaseInsensitiveContains("samples") ? .green : .orange,
                                     isComplete: snapshot.loggingText.localizedCaseInsensitiveContains("samples"),
                                     actionTitle: "Data",
                                     action: onOpenCollection)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Getting set up", subtitle: "")

                Spacer(minLength: 0)

                readinessDots
            }

            VStack(spacing: 8) {
                ForEach(checklistItems) { item in
                    AtriaLaunchChecklistRow(item: item)
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var readinessDots: some View {
        HStack(spacing: 5) {
            ForEach(checklistItems.indices, id: \.self) { index in
                Circle()
                    .fill(index < completeCount ? Color.green : Color.secondary.opacity(0.22))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .atriaInsetCard(tint: completeCount == checklistItems.count ? .green : .orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completeCount) of \(checklistItems.count) setup steps ready")
    }
}

private struct AtriaLaunchChecklistItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let isComplete: Bool
    let actionTitle: String?
    let action: (() -> Void)?
}

private struct AtriaLaunchChecklistRow: View {
    let item: AtriaLaunchChecklistItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.isComplete ? "checkmark.circle.fill" : item.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(item.tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: item.tint))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Text(item.value)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let actionTitle = item.actionTitle, let action = item.action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                }
                .atriaCardAction(prominent: false, tint: item.tint)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: item.tint)
    }
}

struct AtriaOverviewGuidanceSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaOverviewGuidanceSection(hero: heroStore.state)
            .equatable()
    }
}

struct AtriaOverviewGuidanceSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot

    var body: some View {
        // One direct line: a colour dot + what today's signal suggests.
        HStack(spacing: 12) {
            Circle()
                .fill(hero.guidance.color)
                .frame(width: 11, height: 11)
            Text(hero.guidance.headline)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Guidance. \(hero.guidance.headline)")
    }

    static func == (lhs: AtriaOverviewGuidanceSection, rhs: AtriaOverviewGuidanceSection) -> Bool {
        lhs.hero == rhs.hero
    }
}

struct AtriaOverviewMorningJournalHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore

    var body: some View {
        AtriaOverviewMorningJournalCard(hero: heroStore.state,
                                        snapshot: snapshotStore.state,
                                        sleepHistory: store.sleepHistorySnapshot,
                                        todayEntry: store.behaviorJournalEntry(),
                                        taggedDays: store.behaviorJournalEntries.count,
                                        onToggleTag: { tag in
                                            store.toggleBehaviorTag(tag)
                                        },
                                        onConfirmSleep: {
                                            _ = store.confirmBestSleepCandidateForUI(rest: store.baseline.restingInt ?? 60,
                                                                                    source: "morning_journal")
                                        })
            .equatable()
    }
}

struct AtriaOverviewMorningJournalCard: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let snapshot: AtriaHomeModel.Snapshot
    let sleepHistory: SleepHistorySnapshot
    let todayEntry: BehaviorJournalEntry
    let taggedDays: Int
    let onToggleTag: (BehaviorJournalEntry.Tag) -> Void
    let onConfirmSleep: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaOverviewMorningJournalCard, rhs: AtriaOverviewMorningJournalCard) -> Bool {
        lhs.hero.recoveryValue == rhs.hero.recoveryValue
            && lhs.hero.hrvValue == rhs.hero.hrvValue
            && lhs.hero.hrvDetail == rhs.hero.hrvDetail
            && lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.snapshot.sleepDetail == rhs.snapshot.sleepDetail
            && lhs.sleepHistory == rhs.sleepHistory
            && lhs.todayEntry == rhs.todayEntry
            && lhs.taggedDays == rhs.taggedDays
    }

    private var latestNight: SleepHistorySnapshot.Night? {
        sleepHistory.latest
    }

    private var shouldShowConfirmSleep: Bool {
        guard let latestNight else { return false }
        return !latestNight.confirmed && sleepHistory.candidateCount > 0
    }

    private var sleepStatusText: String {
        if let latestNight {
            return "\(latestNight.durationText) · \(latestNight.confidenceText)"
        }
        return snapshot.sleepDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Morning journal", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning))
            }

            LazyVGrid(columns: Self.metricColumns, spacing: 10) {
                AtriaMetricTile(label: "Sleep",
                                value: latestNight?.durationText ?? metricDisplayValue(snapshot.sleepValue),
                                state: latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning),
                                tint: .cyan,
                                footnote: sleepStatusText)
                AtriaMetricTile(label: "Sleep eff",
                                value: latestNight?.sleepEfficiencyText ?? "--",
                                state: latestNight?.sleepEfficiency == nil ? .learning : .research,
                                tint: .cyan,
                                footnote: "Duration vs span")
                AtriaMetricTile(label: "Recovery",
                                value: hero.recoveryEstimate.percent.map { "\($0)" } ?? "--",
                                unit: hero.recoveryEstimate.percent == nil ? nil : "%",
                                state: hero.recoveryEstimate.percent == nil ? .learning : .validated,
                                tint: hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .orange)
                AtriaMetricTile(label: "HRV",
                                value: metricDisplayValue(hero.hrvValue),
                                state: hero.hrvDetail.localizedCaseInsensitiveContains("validated") ? .validated : .learning,
                                tint: .pink)
            }

            LazyVGrid(columns: Self.tagColumns, spacing: 8) {
                ForEach(BehaviorJournalEntry.Tag.allCases) { tag in
                    Button {
                        if reduceMotion {
                            onToggleTag(tag)
                        } else {
                            withAnimation(.snappy(duration: 0.2)) {
                                onToggleTag(tag)
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: todayEntry.tags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(todayEntry.tags.contains(tag) ? .purple : .secondary)
                            Text(tag.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .atriaGlassSelectable(selected: todayEntry.tags.contains(tag))
                }
            }

            HStack(spacing: 10) {
                if shouldShowConfirmSleep {
                    Button(action: onConfirmSleep) {
                        Label("Confirm sleep", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .cyan)
                }

                Text(taggedDays > 0
                     ? "\(taggedDays) journal days saved locally"
                     : "Tags stay on device and power local insights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private static let metricColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]
    private static let tagColumns = [GridItem(.adaptive(minimum: 118), spacing: 8)]

    private func metricDisplayValue(_ value: String) -> String {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "--"
            : value
    }
}

struct AtriaInsightsCardHost: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        AtriaInsightsCard(insights: store.behaviorInsights,
                          taggedDays: store.behaviorJournalEntries.count)
            .equatable()
    }
}

/// Smart insights: actionable, effect-size-ranked findings from behavior tags vs
/// recovery/HRV (e.g. "Alcohol · Recovery 12% lower"). Local, never medical.
struct AtriaInsightsCard: View, Equatable {
    let insights: [AtriaInsight]
    let taggedDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Insights", subtitle: "What moves your recovery")

            if insights.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                    Text(taggedDays == 0
                         ? "Tag your days (sleep, alcohol, training…) and Atria learns what moves your recovery."
                         : "Keep tagging — clear patterns appear after a few matched days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(insights.prefix(3)) { insight in
                    insightRow(insight)
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private func insightRow(_ i: AtriaInsight) -> some View {
        let tint: Color = i.isPositive ? .green : .red
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.tagLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(i.headline) · \(i.detail.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Image(systemName: i.isPositive ? "arrow.up.right" : "arrow.down.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .padding(8)
                .background(tint.opacity(0.14), in: Circle())
        }
        .padding(12)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(i.tagLabel). \(i.headline). \(i.detail).")
    }
}

struct AtriaOverviewTrendSectionHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewTrendSection(snapshot: snapshotStore.state)
            .equatable()
    }
}

struct AtriaOverviewTrendSection: View, Equatable {
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Trend", subtitle: "Local 90-day coverage")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.trendCoverageText)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(snapshot.trendDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                AtriaStatusChip(text: snapshot.trendConfidence,
                                systemImage: "chart.line.uptrend.xyaxis",
                                tint: snapshot.trendConfidence == "high" ? .green : .orange)
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

struct AtriaOverviewBehaviorJournalSection: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var todayEntry: BehaviorJournalEntry {
        store.behaviorJournalEntry()
    }

    private var summaries: [BehaviorCorrelationSummary] {
        // Read the O(1) cache — never recompute the correlation in body (it used
        // to run the heavy rollup on every render/checkpoint tick).
        store.behaviorCorrelationSummariesCache
            .filter { $0.days > 0 }
            .sorted { lhs, rhs in
                if lhs.days != rhs.days { return lhs.days > rhs.days }
                return lhs.tag.rawValue < rhs.tag.rawValue
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Journal", subtitle: "Tag today and learn local patterns")

                Spacer(minLength: 0)

                AtriaStatusChip(text: todayEntry.tags.isEmpty ? "empty" : "\(todayEntry.tags.count) tags",
                                systemImage: "tag.fill",
                                tint: todayEntry.tags.isEmpty ? .gray : .purple)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(BehaviorJournalEntry.Tag.allCases) { tag in
                    Button {
                        if reduceMotion {
                            store.toggleBehaviorTag(tag)
                        } else {
                            withAnimation(.snappy(duration: 0.2)) {
                                store.toggleBehaviorTag(tag)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: todayEntry.tags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(todayEntry.tags.contains(tag) ? .purple : .secondary)
                            Text(tag.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .atriaGlassSelectable(selected: todayEntry.tags.contains(tag))
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                correlationTiles
            }

            Text("Correlations are computed only on this device and stay in learning mode until a tag has at least three matching days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var correlationTiles: some View {
        let visible = Array(summaries.prefix(2))
        if visible.isEmpty {
            AtriaInlineQuickStat(label: "Tagged days", value: "\(store.behaviorJournalEntries.count)")
            AtriaInlineQuickStat(label: "Pattern", value: "Learning")
        } else {
            ForEach(visible, id: \.tag) { summary in
                AtriaInlineQuickStat(label: summary.tag.label,
                                     value: summary.recoveryText,
                                     detail: summary.detail)
            }
        }
    }
}

struct AtriaOverviewTrailingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let segment: AtriaTodaySegment
    let hasUnlockedSecondarySections: Bool
    let onOpenCollection: () -> Void

    var body: some View {
        Group {
            // Today's trailing column is intentionally empty: live battery is in
            // the bottom bar, connection status in the top pill, and the device
            // name / signal detail were dev-facing. Saved collection + backup
            // live under Data.
            if segment == .data {
                if hasUnlockedSecondarySections && snapshotStore.diagnosticsReady {
                    VStack(spacing: 16) {
                        AtriaOverviewCollectionSectionHost(homeStatsStore: homeStatsStore,
                                                           snapshotStore: snapshotStore,
                                                           onOpenCollection: onOpenCollection)

                        AtriaOverviewBackupSectionHost(homeStatsStore: homeStatsStore,
                                                       snapshotStore: snapshotStore)
                    }
                } else {
                    AtriaLoadingPanel(title: "Preparing saved insights",
                                      subtitle: "Backup state and saved data are settling in the background.")
                }
            }
        }
    }
}

struct AtriaOverviewLiveStrapSectionHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore

    var body: some View {
        AtriaOverviewLiveStrapSection(live: liveStore.state,
                                     stats: homeStatsStore.state)
            .equatable()
    }
}

struct AtriaOverviewLiveStrapSection: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let stats: AtriaHomeModel.HomeStatsState

    private var statusTint: Color {
        switch live.status {
        case .connected:
            return .green
        case .connecting, .scanning:
            return .orange
        case .poweredOff:
            return .red
        case .disconnected:
            return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Live strap", subtitle: "Battery and signal")

                Spacer(minLength: 0)

                AtriaStatusChip(text: live.status.rawValue,
                                systemImage: "bolt.heart.fill",
                                tint: statusTint)
            }

            Text(live.deviceName)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                AtriaInlineQuickStat(label: "Battery", value: live.batteryText)
                AtriaInlineQuickStat(label: "Baseline", value: "\(stats.baselineSamples)/7")
                AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

struct AtriaOverviewCollectionSectionHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewCollectionSection(stats: homeStatsStore.state,
                                      snapshot: snapshotStore.state,
                                      onOpenCollection: onOpenCollection)
            .equatable()
    }
}

struct AtriaOverviewCollectionSection: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaOverviewCollectionSection, rhs: AtriaOverviewCollectionSection) -> Bool {
        lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "internaldrive.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(AtriaIconTileBackground(cornerRadius: 12, tint: .blue))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Local backup")
                        .font(.headline.weight(.semibold))
                    Text(backupDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                AtriaInlineQuickStat(label: "HRV window", value: stats.rrPackageText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onOpenCollection) {
                    Label("Data", systemImage: "arrow.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 88)
                }
                .atriaCardAction(tint: .blue)
                .accessibilityLabel("Open Data")
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var backupDetail: String {
        if snapshot.loggingText.localizedCaseInsensitiveContains("samples") {
            return "Saving readings locally. Open Data when you want exports or saved sessions."
        }
        if stats.backupValue.localizedCaseInsensitiveContains("ready") {
            return "Saved sessions are on device. Open Data when you want exports."
        }
        return "Atria is preparing local backup while your baseline settles."
    }
}

private struct AtriaOverviewActionStrip: View {
    let title: String
    let primaryTitle: String
    let primarySystemImage: String
    let primaryAction: () -> Void
    let secondaryTitle: String
    let secondarySystemImage: String
    let secondaryAction: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if horizontalSizeClass == .compact {
                VStack(spacing: 8) {
                    actionButtons
                }
            } else {
                HStack(spacing: 8) {
                    actionButtons
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .white)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: primaryAction) {
            Label(primaryTitle, systemImage: primarySystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: .blue)

        Button(action: secondaryAction) {
            Label(secondaryTitle, systemImage: secondarySystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)
    }
}

struct AtriaOverviewBackupSectionHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewBackupSection(stats: homeStatsStore.state,
                                  snapshot: snapshotStore.state)
            .equatable()
    }
}

struct AtriaOverviewBackupSection: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Backup", subtitle: "On-device safety net")

            HStack(spacing: 12) {
                AtriaInlineQuickStat(label: "State", value: stats.backupValue)
                AtriaInlineQuickStat(label: "Confirmed",
                                    value: "\(snapshot.confirmedWorkouts + snapshot.confirmedSleeps)")
            }

            Text(stats.backupDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(snapshot.confirmedWorkouts) workouts and \(snapshot.confirmedSleeps) sleeps are already confirmed on device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewAutomaticCard: View, Equatable {
    let status: AtriaBLEManager.Status
    let tint: Color
    let setupDetail: String
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void

    static func == (lhs: AtriaDisconnectedOverviewAutomaticCard, rhs: AtriaDisconnectedOverviewAutomaticCard) -> Bool {
        lhs.status == rhs.status
            && lhs.setupDetail == rhs.setupDetail
            && lhs.context == rhs.context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.isFirstHandoff ? "Automatic setup" : "Automatic reconnect")
                        .font(.subheadline.weight(.semibold))
                    Text(context.flowLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text(setupDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(context.isFirstHandoff ? "Review setup steps" : "Review reconnect steps", action: onShowConnectionGuide)
                .frame(maxWidth: .infinity)
                .atriaCardAction(tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewCoexistenceCard: View, Equatable {
    let context: AtriaConnectionGuideContext

    private var tint: Color {
        context.officialAppCoexistenceRisk == .suspected ? .red : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.coexistenceTitle)
                    .font(.subheadline.weight(.semibold))
                Text(context.coexistenceDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewChecklistCard: View, Equatable {
    let title: String
    let items: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "list.number")
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline.weight(.semibold))
            }

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(AtriaChecklistBadgeBackground(tint: tint))
                        .overlay {
                            Circle()
                                .stroke(tint.opacity(0.22), lineWidth: 1)
                        }

                    Text(item)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewSavedStateCard: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved data stays ready")
                        .font(.subheadline.weight(.semibold))
                    Text("Local backup ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Saved metrics and backup remain available while the strap reconnects.")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                savedStateTiles
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var savedStateTiles: some View {
        AtriaMetricTile(label: "Baseline",
                        value: snapshot.referenceText,
                        state: .personalBaseline,
                        tint: .blue)
        AtriaMetricTile(label: "Backup",
                        value: stats.backupValue,
                        state: .local,
                        tint: tint)
        AtriaMetricTile(label: "Saved HRV",
                        value: "\(stats.baselineSamples)/7",
                        state: stats.baselineSamples >= 7 ? .validated : .learning,
                        tint: .pink)
    }
}
