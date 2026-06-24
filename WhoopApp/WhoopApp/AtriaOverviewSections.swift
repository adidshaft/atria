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
        Picker("Section", selection: $segment) {
            ForEach(AtriaTodaySegment.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
    }

    var body: some View {
        Group {
            if statusStore.state.status != .connected {
                if hasUnlockedSecondarySections {
                    AtriaDisconnectedOverviewHost(statusStore: statusStore,
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
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    private var hasTrendHistory: Bool {
        store.sessions.filter { $0.points.count >= 8 }.count >= 2
    }

    var body: some View {
        VStack(spacing: 18) {
            AtriaDisconnectedOverviewPanel(status: statusStore.state.status,
                                           stats: homeStatsStore.state,
                                           snapshot: snapshotStore.state,
                                           context: context,
                                           onShowConnectionGuide: onShowConnectionGuide,
                                           onOpenVitals: onOpenVitals,
                                           onOpenCollection: onOpenCollection)
                .equatable()

            AtriaOverviewReadinessSectionHost(heroStore: heroStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             subtitle: "Last saved readiness")

            // Trends are local history — show them even while the strap is away.
            if hasTrendHistory {
                AtriaOverviewTrendChartHost(store: store, maxHR: store.profile.maxHR)
            }
        }
    }
}

private struct AtriaDisconnectedOverviewPanel: View, Equatable {
    let status: WhoopBLEManager.Status
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
        if context.officialWhoopCoexistenceRisk == .suspected {
            return "Remove WHOOP first."
        }
        switch status {
        case .connecting:
            return "Keep phone nearby."
        case .scanning:
            return "Scanning automatically."
        case .poweredOff:
            return "Bluetooth required."
        case .disconnected:
            return "Free strap from WHOOP."
        case .connected:
            return "Reconnects automatically."
        }
    }

    private var setupItems: [String] {
        var items = [
            "Remove WHOOP app",
            "Keep strap nearby",
            "Let Atria scan"
        ]
        if context.officialWhoopCoexistenceRisk == .suspected {
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

            // Single adaptive grid (renders the tiles once, still responsive)
            // instead of ViewThatFits, which renders both candidate layouts to
            // measure them — doubling the per-card cost during scroll.
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

                AtriaDisconnectedOverviewChecklistCard(title: context.isFirstHandoff ? "Do once before Atria takes over" : "Only if WHOOP grabs the strap again",
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

    var body: some View {
        VStack(spacing: 16) {
            if segment == .today {
                AtriaOverviewReadinessSectionHost(heroStore: heroStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 subtitle: "")

                AtriaOverviewLaunchChecklistHost(liveStore: liveStore,
                                                 homeStatsStore: homeStatsStore,
                                                 snapshotStore: snapshotStore,
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection)

                AtriaOverviewGuidanceSectionHost(heroStore: heroStore,
                                                 settings: aiCoachSettings,
                                                 hasAPIKey: aiCoachHasAPIKey,
                                                 onSettingsChange: onAICoachSettingsChange,
                                                 onSaveAPIKey: onSaveAICoachAPIKey,
                                                 onDeleteAPIKey: onDeleteAICoachAPIKey)
            }

            if segment == .trends && hasUnlockedSecondarySections {
                if snapshotStore.diagnosticsReady {
                    AtriaOverviewTrendChartHost(store: store, maxHR: store.profile.maxHR)
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
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore
    let subtitle: String

    var body: some View {
        AtriaOverviewReadinessSection(hero: heroStore.state,
                                     snapshot: snapshotStore.state,
                                     trendValues: Self.restingTrendValues(from: store),
                                     subtitle: subtitle)
            .equatable()
    }

    private static func restingTrendValues(from store: SessionStore) -> [Int] {
        let calendar = Calendar.current
        return store.sessions
            .filter { $0.points.count >= 8 && $0.restingStable > 0 }
            .sorted { $0.start < $1.start }
            .reduce(into: [(day: Date, value: Int)]()) { days, session in
                let day = calendar.startOfDay(for: session.start)
                if let index = days.lastIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
                    days[index] = (day, min(days[index].value, session.restingStable))
                } else {
                    days.append((day, session.restingStable))
                }
            }
            .suffix(14)
            .map(\.value)
    }
}

struct AtriaOverviewReadinessSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let snapshot: AtriaHomeModel.Snapshot
    let trendValues: [Int]
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AtriaPanelSectionHeader(title: "Today at a glance", subtitle: subtitle)

            HStack(alignment: .center, spacing: 16) {
                recoveryRing

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    AtriaMetricTile(label: "Strain",
                                    value: hero.strainValue,
                                    state: hero.strainDetail.localizedCaseInsensitiveContains("local") ? .local : .learning,
                                    tint: .orange)
                    AtriaMetricTile(label: "HRV",
                                    value: hero.hrvValue,
                                    state: hero.hrvDetail.localizedCaseInsensitiveContains("validated") ? .validated : hrvLearningState,
                                    tint: .pink)
                    AtriaMetricTile(label: "Sleep",
                                    value: snapshot.sleepValue,
                                    state: snapshot.sleepValue.localizedCaseInsensitiveContains("learning") ? .learning : .local,
                                    tint: .cyan)
                    AtriaMetricTile(label: "Resting",
                                    value: hero.restingHeartRateText,
                                    state: .personalBaseline,
                                    tint: .red)
                }
            }

            restingTrend
        }
        .padding(16)
        .atriaCard(emphasis: .strong)
    }

    private var recoveryRing: some View {
        let percent = hero.recoveryEstimate.percent
        let fraction = percent.map { min(max(Double($0) / 100, 0), 1) } ?? 0
        let stroke = StrokeStyle(lineWidth: 9,
                                 lineCap: .round,
                                 dash: percent == nil ? [5, 7] : [])
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 9)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(recoveryColor(percent),
                        style: stroke)
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(hero.recoveryValue)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Recovery")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                AtriaStateBadge(state: percent == nil ? .learning : .validated)
                    .scaleEffect(0.72)
            }
            .padding(8)
        }
        .frame(width: 104, height: 104)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovery \(hero.recoveryValue)")
    }

    @ViewBuilder
    private var restingTrend: some View {
        if trendValues.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Resting trend", systemImage: "waveform.path.ecg.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                    Text("14 sessions")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Sparkline(values: trendValues)
                    .frame(height: 58)
                    .accessibilityLabel("Resting heart rate trend")
            }
            .padding(12)
            .atriaInsetCard(tint: .red)
        }
    }

    private var hrvLearningState: AtriaMetricState {
        hero.hrvDetail.localizedCaseInsensitiveContains("personal") ? .personalBaseline : .learning
    }

    private func recoveryColor(_ percent: Int?) -> Color {
        guard let percent else { return .secondary }
        if percent >= 67 { return .green }
        if percent >= 34 { return .yellow }
        return .red
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
            AtriaLaunchChecklistItem(id: "connection",
                                     title: "Strap connection",
                                     value: live.status == .connected ? "Connected" : live.status.rawValue,
                                     detail: live.status == .connected ? live.deviceName : "Open Vitals when the strap is nearby.",
                                     systemImage: "bolt.heart.fill",
                                     tint: live.status == .connected ? .green : .orange,
                                     isComplete: live.status == .connected,
                                     actionTitle: live.status == .connected ? nil : "Vitals",
                                     action: live.status == .connected ? nil : onOpenVitals),
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
                .buttonStyle(.glass)
                .tint(item.tint)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: item.tint)
    }
}

struct AtriaOverviewGuidanceSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool
    let onSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAPIKey: (String) -> Void
    let onDeleteAPIKey: () -> Void

    var body: some View {
        AtriaOverviewGuidanceSection(hero: heroStore.state,
                                     settings: settings,
                                     hasAPIKey: hasAPIKey,
                                     onSettingsChange: onSettingsChange,
                                     onSaveAPIKey: onSaveAPIKey,
                                     onDeleteAPIKey: onDeleteAPIKey)
            .equatable()
    }
}

struct AtriaOverviewGuidanceSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool
    let onSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAPIKey: (String) -> Void
    let onDeleteAPIKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Guidance", subtitle: "Daily target from today's signal")
            AtriaGuidanceCard(guidance: hero.guidance, strain: hero.strain)
            AtriaAICoachCard(context: coachContext,
                             settings: settings,
                             hasAPIKey: hasAPIKey,
                             onSettingsChange: onSettingsChange,
                             onSaveAPIKey: onSaveAPIKey,
                             onDeleteAPIKey: onDeleteAPIKey)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    static func == (lhs: AtriaOverviewGuidanceSection, rhs: AtriaOverviewGuidanceSection) -> Bool {
        lhs.hero == rhs.hero
            && lhs.settings == rhs.settings
            && lhs.hasAPIKey == rhs.hasAPIKey
    }

    private var coachContext: AtriaCoachContext {
        AtriaCoachContext(guidance: hero.guidance,
                          strain: hero.strain,
                          recoveryText: hero.recoveryEstimate.percent.map { "\($0)%" } ?? hero.recoveryEstimate.confidence.rawValue,
                          hrvText: hero.hrvValue,
                          stressText: hero.stressValue,
                          baselineSamples: hero.baselineSamples,
                          sessionsCount: hero.sessionsCount)
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
        let rest = store.baseline.restingInt ?? store.sessions.first?.restingStable ?? 60
        return store.behaviorCorrelationSummaries(rest: rest, maxHR: store.profile.maxHR)
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
                    .buttonStyle(AtriaSegmentButtonStyle(selected: todayEntry.tags.contains(tag)))
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
            // Live strap belongs with Today; saved collection + backup live under Data.
            if segment == .today {
                AtriaOverviewLiveStrapSectionHost(liveStore: liveStore,
                                                  homeStatsStore: homeStatsStore)
            } else if segment == .data {
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
        HStack(alignment: .center, spacing: 12) {
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            AtriaInlineQuickStat(label: "HRV window", value: stats.rrPackageText)
                .frame(maxWidth: 118)

            Button(action: onOpenCollection) {
                Label("Data", systemImage: "arrow.right.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .accessibilityLabel("Open Data")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits {
                HStack(spacing: 8) {
                    actionButtons
                }

                VStack(spacing: 8) {
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
        .buttonStyle(.glassProminent)
        .tint(.blue)

        Button(action: secondaryAction) {
            Label(secondaryTitle, systemImage: secondarySystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.gray)
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
    let status: WhoopBLEManager.Status
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                AtriaMetricTile(label: "Flow",
                                value: context.flowLabel,
                                state: .local,
                                tint: tint)
                AtriaMetricTile(label: "Attempts",
                                value: "\(max(context.attempts, 1))",
                                state: status == .connected ? .validated : .learning,
                                tint: tint)
            }

            Button(context.isFirstHandoff ? "Review setup steps" : "Review reconnect steps", action: onShowConnectionGuide)
                .buttonStyle(.glassProminent)
        .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewCoexistenceCard: View, Equatable {
    let context: AtriaConnectionGuideContext

    private var tint: Color {
        context.officialWhoopCoexistenceRisk == .suspected ? .red : .orange
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
                        .lineLimit(1)
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
