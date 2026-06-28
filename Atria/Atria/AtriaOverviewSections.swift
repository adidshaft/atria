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

fileprivate struct AtriaGlanceGridSize: Equatable {
    let rows: Int
    let columns: Int

    static let compact = AtriaGlanceGridSize(rows: 1, columns: 1)
    static let wide = AtriaGlanceGridSize(rows: 1, columns: 2)

    var isWide: Bool { columns == 2 }

    var isValidGlanceShape: Bool {
        rows == 1 && (columns == 1 || columns == 2)
    }

    var storageValue: String {
        isWide ? "wide" : "compact"
    }

    static func storageSize(from raw: String) -> AtriaGlanceGridSize? {
        switch raw {
        case "compact": return .compact
        case "wide": return .wide
        default: return nil
        }
    }
}

struct AtriaOverviewTabContent: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let hapticSettings: AtriaHapticAlertSettings
    let horizontalSizeClass: UserInterfaceSizeClass?
    let connectionContext: AtriaConnectionGuideContext
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onStartWorkout: () -> Void

    @State private var segment: AtriaTodaySegment = .today

    private func openTrendsSegment() {
        guard hasUnlockedSecondarySections else { return }
        withAnimation(.snappy(duration: 0.22)) { segment = .trends }
    }

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
                                                 profileMetricsStore: profileMetricsStore,
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
                                             profileMetricsStore: profileMetricsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             segment: .today,
                                             hasUnlockedSecondarySections: false,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             hapticSettings: hapticSettings,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection,
                                             onOpenInsights: openTrendsSegment,
                                             onStartWorkout: onStartWorkout)
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
                                                     profileMetricsStore: profileMetricsStore,
                                                     snapshotStore: snapshotStore,
                                                     store: store,
                                                     segment: segment,
                                                     hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                     aiCoachSettings: aiCoachSettings,
                                                     aiCoachHasAPIKey: aiCoachHasAPIKey,
                                                     hapticSettings: hapticSettings,
                                                     onAICoachSettingsChange: onAICoachSettingsChange,
                                                     onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                                     onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                                     onOpenVitals: onOpenVitals,
                                                     onOpenCollection: onOpenCollection,
                                                     onOpenInsights: openTrendsSegment,
                                                     onStartWorkout: onStartWorkout)
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
                                             profileMetricsStore: profileMetricsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             segment: segment,
                                             hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             hapticSettings: hapticSettings,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection,
                                             onOpenInsights: openTrendsSegment,
                                             onStartWorkout: onStartWorkout)
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
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
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
                                                 profileMetricsStore: profileMetricsStore,
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
        if context.officialAppInstalled && context.officialAppCoexistenceRisk == .suspected {
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
            return "Keep strap nearby."
        case .connected:
            return "Reconnects automatically."
        }
    }

    private var setupItems: [String] {
        if context.officialAppInstalled {
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
        return [
            "Keep Bluetooth on",
            "Keep strap nearby",
            "Let Atria scan"
        ]
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
                AtriaInlineQuickStat(label: "Saved days", value: "\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)")
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
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let segment: AtriaTodaySegment
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let hapticSettings: AtriaHapticAlertSettings
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onOpenInsights: () -> Void
    let onStartWorkout: () -> Void

    var body: some View {
        AtriaOverviewLeadingSection(liveStore: liveStore,
                                   heroStore: heroStore,
                                   homeStatsStore: homeStatsStore,
                                   profileMetricsStore: profileMetricsStore,
                                   snapshotStore: snapshotStore,
                                   store: store,
                                   segment: segment,
                                   hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                   aiCoachSettings: aiCoachSettings,
                                   aiCoachHasAPIKey: aiCoachHasAPIKey,
                                   hapticSettings: hapticSettings,
                                   onAICoachSettingsChange: onAICoachSettingsChange,
                                   onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                   onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                   onOpenVitals: onOpenVitals,
                                   onOpenCollection: onOpenCollection,
                                   onOpenInsights: onOpenInsights,
                                   onStartWorkout: onStartWorkout)
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
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let segment: AtriaTodaySegment
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let hapticSettings: AtriaHapticAlertSettings
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onOpenInsights: () -> Void
    let onStartWorkout: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if segment == .today {
                AtriaOverviewReadinessSectionHost(liveStore: liveStore,
                                                 heroStore: heroStore,
                                                 profileMetricsStore: profileMetricsStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 hapticSettings: hapticSettings,
                                                 subtitle: "",
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection,
                                                 onOpenInsights: onOpenInsights,
                                                 onStartWorkout: onStartWorkout)

                // Simple one-line "what to do today" guidance. No AI coach, no
                // setup checklist, no strain-target maths — kept direct.
                AtriaOverviewGuidanceSectionHost(heroStore: heroStore)

                AtriaOverviewMorningJournalHost(snapshotStore: snapshotStore,
                                                store: store)
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
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore
    var hapticSettings: AtriaHapticAlertSettings = AtriaHapticAlertSettings()
    let subtitle: String
    var onOpenVitals: () -> Void = {}
    var onOpenCollection: () -> Void = {}
    var onOpenInsights: () -> Void = {}
    var onStartWorkout: () -> Void = {}

    @AppStorage(AtriaTodayMetric.storageKey) private var hiddenCSV: String = ""
    @AppStorage(AtriaTodayMetric.orderStorageKey) private var orderCSV: String = ""
    @AppStorage(AtriaTodayMetric.sizeStorageKey) private var sizeCSV: String = ""
    @AppStorage("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AppStorage("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AppStorage("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AppStorage("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AppStorage("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AppStorage("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AppStorage("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AppStorage("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AppStorage("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AppStorage("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AppStorage("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AppStorage("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AppStorage("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AppStorage("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AppStorage("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AppStorage("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AppStorage("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AppStorage("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AppStorage("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AppStorage("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AppStorage("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AppStorage("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AppStorage("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AppStorage("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AppStorage("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AppStorage("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AppStorage("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AppStorage("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    var body: some View {
        AtriaOverviewReadinessSection(hero: heroStore.state,
                                     live: liveStore.state,
                                     vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                                     biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary,
                                     snapshot: snapshotStore.state,
                                     trendValues: store.restingTrend14,   // Phase-0 cache (no per-render sort)
                                     sensorSummary: store.imuAuditSummary,
                                     hapticSettings: hapticSettings,
                                     sleepHistory: store.sleepHistorySnapshot,
                                     historicalArchiveStatus: store.historicalArchiveStatus,
                                     insights: store.behaviorInsights,
                                     taggedDays: store.behaviorJournalEntries.count,
                                     subtitle: subtitle,
                                     recoveryTarget: AtriaMetricTarget.recovery(greenLower: recoveryGreenLower,
                                                                                yellowLower: recoveryYellowLower),
                                     strainGreenBand: strainGreenBand,
                                     strainYellowBand: strainYellowBand,
                                     loadACWRWatchLow: loadACWRWatchLow,
                                     loadACWRWatchHigh: loadACWRWatchHigh,
                                     loadACWRBadLow: loadACWRBadLow,
                                     loadACWRBadHigh: loadACWRBadHigh,
                                     loadMonotonyWatch: loadMonotonyWatch,
                                     loadMonotonyBad: loadMonotonyBad,
                                     hrvBaseline: store.baseline.hrvInt,
                                     hrvBaselineSamples: store.baseline.freshHRVSampleCount(),
                                     hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline(),
                                     baselineTarget: AtriaBaselineTargetSnapshot(store.baseline),
                                     hrvGreenRatio: hrvGreenRatio,
                                     hrvYellowRatio: hrvYellowRatio,
                                     restingBaseline: store.baseline.restingInt,
                                     restingBaselineSamples: store.baseline.freshRestingSampleCount(),
                                     restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline(),
                                     restingGreenDelta: restingGreenDelta,
                                     restingYellowDelta: restingYellowDelta,
                                     respiratoryGreenDelta: respiratoryGreenDelta,
                                     respiratoryYellowDelta: respiratoryYellowDelta,
                                     skinTemperatureGreenDelta: skinTemperatureGreenDelta,
                                     skinTemperatureYellowDelta: skinTemperatureYellowDelta,
                                     bloodOxygenCandidateGoal: bloodOxygenCandidateGoal,
                                     biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta,
                                     biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta,
                                     vo2GreenDelta: vo2GreenDelta,
                                     vo2RedDelta: vo2RedDelta,
                                     stepsGoal: stepsGoal,
                                     caloriesGoal: caloriesGoal,
                                     sleepGoalHours: sleepGoalHours,
                                     sleepEfficiencyGreenLower: sleepEfficiencyGreenLower,
                                     sleepEfficiencyYellowLower: sleepEfficiencyYellowLower,
                                     visibleMetrics: AtriaTodayMetric.visibleOrdered(orderCSV: orderCSV,
                                                                                    hiddenCSV: hiddenCSV),
                                     hiddenMetrics: AtriaTodayMetric.hiddenOrdered(orderCSV: orderCSV,
                                                                                  hiddenCSV: hiddenCSV),
                                     sizeOverridesCSV: sizeCSV,
                                     onMoveMetric: moveMetric,
                                     onShiftMetric: shiftMetric,
                                     onHideMetric: hideMetric,
                                     onShowMetric: showMetric,
                                     onToggleMetricSize: toggleMetricSize,
                                     onResetMetrics: resetMetrics,
                                     onOpenVitals: onOpenVitals,
                                     onOpenCollection: onOpenCollection,
                                     onOpenInsights: onOpenInsights,
                                     onAddManualSleep: addManualSleep,
                                     onStartWorkout: onStartWorkout)
            .equatable()
            .sensoryFeedback(.selection, trigger: orderCSV)
            .sensoryFeedback(.selection, trigger: sizeCSV)
    }

    private func moveMetric(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric) {
        orderCSV = AtriaTodayMetric.moving(dragged,
                                           before: target,
                                           in: orderCSV,
                                           hiddenCSV: hiddenCSV)
    }

    private func shiftMetric(_ metric: AtriaTodayMetric, direction: Int) {
        orderCSV = AtriaTodayMetric.moving(metric,
                                           direction: direction,
                                           in: orderCSV,
                                           hiddenCSV: hiddenCSV)
    }

    private func hideMetric(_ metric: AtriaTodayMetric) {
        var hidden = AtriaTodayMetric.hidden(from: hiddenCSV)
        hidden.insert(metric.rawValue)
        hiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)
    }

    private func showMetric(_ metric: AtriaTodayMetric) {
        var hidden = AtriaTodayMetric.hidden(from: hiddenCSV)
        hidden.remove(metric.rawValue)
        hiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)
    }

    private func resetMetrics() {
        orderCSV = AtriaTodayMetric.defaultGlanceOrder.map(\.rawValue).joined(separator: ",")
        hiddenCSV = ""
        sizeCSV = ""
    }

    private func toggleMetricSize(_ metric: AtriaTodayMetric) {
        let current = metric.glanceGridSize(sizeOverridesCSV: sizeCSV)
        let next: AtriaGlanceGridSize = current.isWide ? .compact : .wide
        sizeCSV = AtriaTodayMetric.sizeStorageValue(updating: metric, to: next, in: sizeCSV)
    }

    private func addManualSleep(start: Date, end: Date, isNap: Bool) {
        _ = store.addManualSleep(start: start,
                                 end: end,
                                 isNap: isNap,
                                 rest: store.baseline.restingInt ?? 60,
                                 source: "manual_today_glance")
    }

}

/// Metrics the user can show/hide on the Today glance (Settings → Today screen).
enum AtriaTodayMetric: String, CaseIterable, Identifiable {
    case recovery, strain, load, workout, backfill, hapticAlerts, hrv, stress, sleep, sleepHistory, sleepEfficiency, rhr, respiratoryRate, steps, strapSteps, calories, vo2max, bioAge, bloodOxygen, bodyTemp, trend, insights
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .load: return "Load"
        case .workout: return "Workout"
        case .backfill: return "Backfill"
        case .hapticAlerts: return "Alerts"
        case .hrv: return "HRV"
        case .stress: return "Stress"
        case .sleep: return "Sleep"
        case .sleepHistory: return "Sleep history"
        case .sleepEfficiency: return "Sleep eff"
        case .rhr: return "Resting HR"
        case .respiratoryRate: return "Resp rate"
        case .steps: return "Steps"
        case .strapSteps: return "Strap steps"
        case .calories: return "Calories"
        case .vo2max: return "VO2max"
        case .bioAge: return "Body age"
        case .bloodOxygen: return "Blood oxygen"
        case .bodyTemp: return "Body temp"
        case .trend: return "Resting trend"
        case .insights: return "Insights"
        }
    }
    var systemImage: String {
        switch self {
        case .recovery: return "gauge.with.dots.needle.67percent"
        case .strain: return "figure.run"
        case .load: return "chart.bar.xaxis"
        case .workout: return "stopwatch.fill"
        case .backfill: return "arrow.triangle.2.circlepath"
        case .hapticAlerts: return "iphone.radiowaves.left.and.right"
        case .hrv: return "waveform.path.ecg"
        case .stress: return "bolt.heart.fill"
        case .sleep: return "bed.double.fill"
        case .sleepHistory: return "moon.zzz.fill"
        case .sleepEfficiency: return "percent"
        case .rhr: return "heart.fill"
        case .respiratoryRate: return "lungs"
        case .steps: return "shoeprints.fill"
        case .strapSteps: return "figure.walk.motion"
        case .calories: return "flame.fill"
        case .vo2max: return "lungs.fill"
        case .bioAge: return "figure.stand.line.dotted.figure.stand"
        case .bloodOxygen: return "drop.degreesign"
        case .bodyTemp: return "thermometer.variable"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .insights: return "sparkles"
        }
    }

    fileprivate var defaultGlanceGridSize: AtriaGlanceGridSize {
        switch self {
        case .sleepHistory, .load, .trend, .insights:
            return .wide
        default:
            return .compact
        }
    }

    fileprivate func glanceGridSize(sizeOverridesCSV: String) -> AtriaGlanceGridSize {
        AtriaTodayMetric.sizeOverrides(from: sizeOverridesCSV)[rawValue] ?? defaultGlanceGridSize
    }

    fileprivate func glanceGridSize(sizeOverrides: [String: AtriaGlanceGridSize]) -> AtriaGlanceGridSize {
        sizeOverrides[rawValue] ?? defaultGlanceGridSize
    }

    func glanceColumnSpan(sizeOverridesCSV: String) -> Int {
        glanceGridSize(sizeOverridesCSV: sizeOverridesCSV).columns
    }

    fileprivate func glanceColumnSpan(sizeOverrides: [String: AtriaGlanceGridSize]) -> Int {
        glanceGridSize(sizeOverrides: sizeOverrides).columns
    }

    fileprivate func isWideGlanceCard(sizeOverridesCSV: String) -> Bool {
        glanceGridSize(sizeOverridesCSV: sizeOverridesCSV).isWide
    }

    fileprivate func isWideGlanceCard(sizeOverrides: [String: AtriaGlanceGridSize]) -> Bool {
        glanceGridSize(sizeOverrides: sizeOverrides).isWide
    }

    /// Persisted as a comma-separated list of HIDDEN raw values. Empty storage is
    /// the product default, which keeps research-only probes off the main Today
    /// surface until the user explicitly enables them.
    static let storageKey = "atriaTodayHiddenMetrics"
    static let orderStorageKey = "atria.overview.glanceOrderCSV"
    static let sizeStorageKey = "atria.overview.glanceSizeCSV"
    static let noHiddenMetricsSentinel = "__atria_all_today_cards_visible__"
    private static let dragPayloadPrefix = "atria.today.metric:"

    static var defaultHiddenMetrics: Set<String> {
        let metrics: [AtriaTodayMetric] = [.respiratoryRate, .strapSteps, .bloodOxygen, .bodyTemp]
        return Set(metrics.map(\.rawValue))
    }

    static var defaultGlanceOrder: [AtriaTodayMetric] {
        [.recovery, .strain, .workout, .backfill, .load, .hapticAlerts, .hrv, .stress, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp, .trend, .insights]
    }

    static func hidden(from csv: String) -> Set<String> {
        let trimmed = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultHiddenMetrics }
        if trimmed == noHiddenMetricsSentinel { return [] }
        return Set(trimmed.split(separator: ",").map(String.init))
    }

    static func hiddenStorageValue(for hidden: Set<String>) -> String {
        hidden.isEmpty ? noHiddenMetricsSentinel : hidden.sorted().joined(separator: ",")
    }

    fileprivate static func sizeOverrides(from csv: String) -> [String: AtriaGlanceGridSize] {
        var result: [String: AtriaGlanceGridSize] = [:]
        for token in csv.split(separator: ",").map(String.init) {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  defaultGlanceOrder.contains(where: { $0.rawValue == parts[0] }),
                  let size = AtriaGlanceGridSize.storageSize(from: parts[1]) else { continue }
            result[parts[0]] = size
        }
        return result
    }

    fileprivate static func sizeStorageValue(updating metric: AtriaTodayMetric,
                                             to size: AtriaGlanceGridSize,
                                             in csv: String) -> String {
        var overrides = sizeOverrides(from: csv)
        if size == metric.defaultGlanceGridSize {
            overrides.removeValue(forKey: metric.rawValue)
        } else {
            overrides[metric.rawValue] = size
        }
        return defaultGlanceOrder.compactMap { item in
            overrides[item.rawValue].map { "\(item.rawValue)=\($0.storageValue)" }
        }
        .joined(separator: ",")
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

    static func hiddenOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric] {
        let hidden = hidden(from: hiddenCSV)
        return ordered(from: orderCSV).filter { hidden.contains($0.rawValue) }
    }

    var dragPayload: String {
        Self.dragPayloadPrefix + rawValue
    }

    fileprivate var supportsGlanceTargetEditing: Bool {
        switch self {
        case .recovery, .strain, .load, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp:
            return true
        default:
            return false
        }
    }

    static func draggedMetric(from payload: String) -> AtriaTodayMetric? {
        guard payload.hasPrefix(dragPayloadPrefix) else { return nil }
        let raw = String(payload.dropFirst(dragPayloadPrefix.count))
        return AtriaTodayMetric(rawValue: raw)
    }

    static func moving(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric, in csv: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        var order = ordered(from: csv).filter { $0 != dragged }
        let insertIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: insertIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ dragged: AtriaTodayMetric,
                       before target: AtriaTodayMetric,
                       in csv: String,
                       hiddenCSV: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        let hidden = hidden(from: hiddenCSV)
        let currentOrder = ordered(from: csv)
        let currentVisible = currentOrder.filter { !hidden.contains($0.rawValue) }
        guard currentVisible.contains(dragged), currentVisible.contains(target) else {
            return moving(dragged, before: target, in: csv)
        }
        var nextVisible = currentVisible.filter { $0 != dragged }
        let insertIndex = nextVisible.firstIndex(of: target) ?? nextVisible.endIndex
        nextVisible.insert(dragged, at: insertIndex)
        return mergedOrder(replacingVisibleSlotsIn: currentOrder,
                           hidden: hidden,
                           with: nextVisible)
    }

    static func moving(_ metric: AtriaTodayMetric, direction: Int, in csv: String) -> String {
        var order = ordered(from: csv)
        guard let index = order.firstIndex(of: metric) else { return order.map(\.rawValue).joined(separator: ",") }
        let next = max(0, min(order.count - 1, index + direction))
        guard next != index else { return order.map(\.rawValue).joined(separator: ",") }
        order.swapAt(index, next)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ metric: AtriaTodayMetric,
                       direction: Int,
                       in csv: String,
                       hiddenCSV: String) -> String {
        let hidden = hidden(from: hiddenCSV)
        let currentOrder = ordered(from: csv)
        var visible = currentOrder.filter { !hidden.contains($0.rawValue) }
        guard let index = visible.firstIndex(of: metric) else {
            return moving(metric, direction: direction, in: csv)
        }
        let next = max(0, min(visible.count - 1, index + direction))
        guard next != index else { return currentOrder.map(\.rawValue).joined(separator: ",") }
        visible.swapAt(index, next)
        return mergedOrder(replacingVisibleSlotsIn: currentOrder,
                           hidden: hidden,
                           with: visible)
    }

    private static func mergedOrder(replacingVisibleSlotsIn order: [AtriaTodayMetric],
                                    hidden: Set<String>,
                                    with visible: [AtriaTodayMetric]) -> String {
        var visibleIterator = visible.makeIterator()
        let merged = order.map { metric in
            hidden.contains(metric.rawValue) ? metric : (visibleIterator.next() ?? metric)
        }
        return merged.map(\.rawValue).joined(separator: ",")
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
    let vo2MaxEstimate: VO2MaxEstimateSummary
    let biologicalAgeSummary: BiologicalAgeSummary
    let snapshot: AtriaHomeModel.Snapshot
    let trendValues: [Int]
    let sensorSummary: IMUAuditSummary
    let hapticSettings: AtriaHapticAlertSettings
    let sleepHistory: SleepHistorySnapshot
    let historicalArchiveStatus: SessionStore.HistoricalArchiveStatus
    let insights: [AtriaInsight]
    let taggedDays: Int
    let subtitle: String
    let recoveryTarget: AtriaMetricTarget
    let strainGreenBand: Double
    let strainYellowBand: Double
    let loadACWRWatchLow: Double
    let loadACWRWatchHigh: Double
    let loadACWRBadLow: Double
    let loadACWRBadHigh: Double
    let loadMonotonyWatch: Double
    let loadMonotonyBad: Double
    let hrvBaseline: Int?
    let hrvBaselineSamples: Int
    let hrvBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let hrvGreenRatio: Double
    let hrvYellowRatio: Double
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let restingGreenDelta: Int
    let restingYellowDelta: Int
    let respiratoryGreenDelta: Double
    let respiratoryYellowDelta: Double
    let skinTemperatureGreenDelta: Double
    let skinTemperatureYellowDelta: Double
    let bloodOxygenCandidateGoal: Int
    let biologicalAgeGreenOlderDelta: Int
    let biologicalAgeYellowOlderDelta: Int
    let vo2GreenDelta: Double
    let vo2RedDelta: Double
    let stepsGoal: Int
    let caloriesGoal: Int
    let sleepGoalHours: Double
    let sleepEfficiencyGreenLower: Double
    let sleepEfficiencyYellowLower: Double
    let visibleMetrics: [AtriaTodayMetric]
    let hiddenMetrics: [AtriaTodayMetric]
    let sizeOverridesCSV: String
    let onMoveMetric: (AtriaTodayMetric, AtriaTodayMetric) -> Void
    let onShiftMetric: (AtriaTodayMetric, Int) -> Void
    let onHideMetric: (AtriaTodayMetric) -> Void
    let onShowMetric: (AtriaTodayMetric) -> Void
    let onToggleMetricSize: (AtriaTodayMetric) -> Void
    let onResetMetrics: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onOpenInsights: () -> Void
    let onAddManualSleep: (Date, Date, Bool) -> Void
    let onStartWorkout: () -> Void
    @State private var isEditingGlance = false
    @State private var showWidgetManager = false
    @State private var showManualSleepSheet = false
    @State private var targetEditorMetric: AtriaTodayMetric?

    // Compare ONLY the values this card actually displays. The full `live` state
    // ticks on every battery/sample update; without this the glance (2 rings + 5
    // tiles + sparkline) rebuilt on every BLE tick. Now it rebuilds only when a
    // shown number changes — the main connected-state scroll-lag fix.
    static func == (lhs: AtriaOverviewReadinessSection, rhs: AtriaOverviewReadinessSection) -> Bool {
        lhs.subtitle == rhs.subtitle
            && lhs.trendValues == rhs.trendValues
            && lhs.hero.recoveryEstimate.percent == rhs.hero.recoveryEstimate.percent
            && lhs.hero.recoveryEstimate.confidence == rhs.hero.recoveryEstimate.confidence
            && lhs.hero.recoveryEstimate.detail == rhs.hero.recoveryEstimate.detail
            && lhs.hero.recoveryValue == rhs.hero.recoveryValue
            && lhs.hero.strain == rhs.hero.strain
            && lhs.hero.strainValue == rhs.hero.strainValue
            && lhs.hero.guidance.target == rhs.hero.guidance.target
            && lhs.hero.hrvValue == rhs.hero.hrvValue
            && lhs.hero.hrvDetail == rhs.hero.hrvDetail
            && lhs.hero.stressValue == rhs.hero.stressValue
            && lhs.hero.stressDetail == rhs.hero.stressDetail
            && lhs.hero.stressNarrative == rhs.hero.stressNarrative
            && lhs.hero.restingHeartRateText == rhs.hero.restingHeartRateText
            && lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.live.status == rhs.live.status
            && lhs.live.sessionSampleCount == rhs.live.sessionSampleCount
            && lhs.live.phoneStepsText == rhs.live.phoneStepsText
            && lhs.live.phoneMotionDetailText == rhs.live.phoneMotionDetailText
            && lhs.live.liveActiveCaloriesText == rhs.live.liveActiveCaloriesText
            && lhs.live.liveActiveCalories == rhs.live.liveActiveCalories
            && lhs.biologicalAgeSummary == rhs.biologicalAgeSummary
            && lhs.vo2MaxEstimate == rhs.vo2MaxEstimate
            && lhs.sensorSummary == rhs.sensorSummary
            && lhs.hapticSettings == rhs.hapticSettings
            && lhs.sleepHistory == rhs.sleepHistory
            && lhs.historicalArchiveStatus == rhs.historicalArchiveStatus
            && lhs.insights == rhs.insights
            && lhs.taggedDays == rhs.taggedDays
            && lhs.recoveryTarget == rhs.recoveryTarget
            && lhs.strainGreenBand == rhs.strainGreenBand
            && lhs.strainYellowBand == rhs.strainYellowBand
            && lhs.loadACWRWatchLow == rhs.loadACWRWatchLow
            && lhs.loadACWRWatchHigh == rhs.loadACWRWatchHigh
            && lhs.loadACWRBadLow == rhs.loadACWRBadLow
            && lhs.loadACWRBadHigh == rhs.loadACWRBadHigh
            && lhs.loadMonotonyWatch == rhs.loadMonotonyWatch
            && lhs.loadMonotonyBad == rhs.loadMonotonyBad
            && lhs.hrvBaseline == rhs.hrvBaseline
            && lhs.hrvBaselineSamples == rhs.hrvBaselineSamples
            && lhs.hrvBaselineTrusted == rhs.hrvBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.hrvGreenRatio == rhs.hrvGreenRatio
            && lhs.hrvYellowRatio == rhs.hrvYellowRatio
            && lhs.restingBaseline == rhs.restingBaseline
            && lhs.restingBaselineSamples == rhs.restingBaselineSamples
            && lhs.restingBaselineTrusted == rhs.restingBaselineTrusted
            && lhs.restingGreenDelta == rhs.restingGreenDelta
            && lhs.restingYellowDelta == rhs.restingYellowDelta
            && lhs.respiratoryGreenDelta == rhs.respiratoryGreenDelta
            && lhs.respiratoryYellowDelta == rhs.respiratoryYellowDelta
            && lhs.skinTemperatureGreenDelta == rhs.skinTemperatureGreenDelta
            && lhs.skinTemperatureYellowDelta == rhs.skinTemperatureYellowDelta
            && lhs.bloodOxygenCandidateGoal == rhs.bloodOxygenCandidateGoal
            && lhs.biologicalAgeGreenOlderDelta == rhs.biologicalAgeGreenOlderDelta
            && lhs.biologicalAgeYellowOlderDelta == rhs.biologicalAgeYellowOlderDelta
            && lhs.vo2GreenDelta == rhs.vo2GreenDelta
            && lhs.vo2RedDelta == rhs.vo2RedDelta
            && lhs.stepsGoal == rhs.stepsGoal
            && lhs.caloriesGoal == rhs.caloriesGoal
            && lhs.sleepGoalHours == rhs.sleepGoalHours
            && lhs.sleepEfficiencyGreenLower == rhs.sleepEfficiencyGreenLower
            && lhs.sleepEfficiencyYellowLower == rhs.sleepEfficiencyYellowLower
            && lhs.visibleMetrics == rhs.visibleMetrics
            && lhs.hiddenMetrics == rhs.hiddenMetrics
            && lhs.sizeOverridesCSV == rhs.sizeOverridesCSV
    }

    var body: some View {
        let glanceSizeOverrides = AtriaTodayMetric.sizeOverrides(from: sizeOverridesCSV)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Today at a glance", subtitle: subtitle)

                Spacer(minLength: 0)

                addWidgetMenu
            }

            if visibleMetrics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a widget to rebuild this view.")
                        .font(.footnote.weight(.semibold))
                    Text("Use the plus button to bring back recovery, strain, sleep, HRV, steps, and research cards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .atriaInsetCard(tint: .secondary)
            } else {
                if isEditingGlance {
                    HStack(spacing: 8) {
                        Label("Editing widgets", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                isEditingGlance = false
                            }
                        } label: {
                            Text("Done")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(AtriaCardActionButtonStyle(prominent: false, tint: .secondary))
                    }
                    .padding(.horizontal, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack(alignment: .leading, spacing: Self.glanceGridSpacing) {
                    VStack(spacing: Self.glanceGridSpacing) {
                        ForEach(glanceRows(sizeOverrides: glanceSizeOverrides), id: \.glanceRowID) { row in
                            HStack(spacing: Self.glanceGridSpacing) {
                                glanceRowContent(row, sizeOverrides: glanceSizeOverrides)
                            }
                            .frame(maxWidth: .infinity,
                                   minHeight: Self.glanceRowHeight,
                                   maxHeight: Self.glanceRowHeight,
                                   alignment: .topLeading)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .onLongPressGesture(minimumDuration: 0.45) {
                    withAnimation(.snappy(duration: 0.2)) {
                        isEditingGlance = true
                    }
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .strong)
        .sheet(isPresented: $showManualSleepSheet) {
            AtriaManualSleepSheet { start, end, isNap in
                onAddManualSleep(start, end, isNap)
                showManualSleepSheet = false
            }
        }
        .sheet(item: $targetEditorMetric) { metric in
            AtriaGlanceTargetEditorSheet(metric: metric)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWidgetManager) {
            AtriaGlanceWidgetManagerSheet(hiddenMetrics: hiddenMetrics,
                                          onEditWidgets: {
                                              withAnimation(.snappy(duration: 0.2)) {
                                                  isEditingGlance = true
                                              }
                                          },
                                          onShowMetric: { metric in
                                              withAnimation(.snappy(duration: 0.2)) {
                                                  onShowMetric(metric)
                                              }
                                          })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var addWidgetMenu: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                if isEditingGlance {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isEditingGlance = false
                        }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 18)
                    }
                    .atriaGlassIconAction(tint: .green, size: 38)
                    .accessibilityLabel("Finish editing widgets")
                    .transition(.scale.combined(with: .opacity))
                }

                Button {
                    showWidgetManager = true
                } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(width: 20, height: 20)
                }
                .atriaGlassIconAction(tint: .secondary, size: 38)
                .accessibilityLabel("Add Today widget")
                .accessibilityHint("Opens hidden Today widgets you can add. Long press a card to remove or resize it.")
            }
        }
    }

    private static let glanceGridSpacing: CGFloat = 10
    private static let glanceGridColumnCount = 2
    private static let glanceRowHeight = AtriaGlanceMetricCard.cardHeight

    private func glanceRows(sizeOverrides: [String: AtriaGlanceGridSize]) -> [[AtriaTodayMetric]] {
        var rows: [[AtriaTodayMetric]] = []
        var pending: [AtriaTodayMetric] = []
        for metric in visibleMetrics {
            guard metric.glanceGridSize(sizeOverrides: sizeOverrides).isValidGlanceShape else { continue }
            if metric.isWideGlanceCard(sizeOverrides: sizeOverrides) {
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
        return rows.filter { rowFitsGlanceGrid($0, sizeOverrides: sizeOverrides) }
    }

    private func rowFitsGlanceGrid(_ row: [AtriaTodayMetric], sizeOverrides: [String: AtriaGlanceGridSize]) -> Bool {
        var span = 0
        for metric in row {
            span += metric.glanceColumnSpan(sizeOverrides: sizeOverrides)
        }
        return span <= Self.glanceGridColumnCount
    }

    @ViewBuilder
    private func glanceRowContent(_ row: [AtriaTodayMetric], sizeOverrides: [String: AtriaGlanceGridSize]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: Self.glanceGridSpacing) {
                ForEach(row) { metric in
                    glanceCardCell(metric,
                                   width: glanceCardWidth(for: metric,
                                                          containerWidth: proxy.size.width,
                                                          sizeOverrides: sizeOverrides),
                                   sizeOverrides: sizeOverrides)
                }

                if row.count == 1, row.first?.isWideGlanceCard(sizeOverrides: sizeOverrides) == false {
                    AtriaGlanceMetricCard.placeholder
                        .frame(width: glanceCardWidth(for: .recovery,
                                                      containerWidth: proxy.size.width,
                                                      sizeOverrides: sizeOverrides),
                               height: Self.glanceRowHeight)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func glanceCardCell(_ metric: AtriaTodayMetric,
                                width: CGFloat,
                                sizeOverrides: [String: AtriaGlanceGridSize]) -> some View {
        let upLabel = Text("Move \(metric.label) up")
        let downLabel = Text("Move \(metric.label) down")

        return glanceCard(metric)
            .frame(width: width,
                   height: Self.glanceRowHeight,
                   alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .overlay(glanceEditingBorder(for: metric))
            .overlay(alignment: .topTrailing) {
                if isEditingGlance {
                    glanceRemoveControl(for: metric)
                        .padding(6)
                        .zIndex(3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditingGlance {
                    glanceResizeControl(for: metric, sizeOverrides: sizeOverrides)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isEditingGlance, metric.supportsGlanceTargetEditing {
                    glanceTargetControl(for: metric)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.2)) {
                            isEditingGlance = true
                        }
                    }
            )
            .onTapGesture {
                guard isEditingGlance, metric.supportsGlanceTargetEditing else { return }
                targetEditorMetric = metric
            }
            .contextMenu {
                if metric.supportsGlanceTargetEditing {
                    Button {
                        targetEditorMetric = metric
                    } label: {
                        Label("Edit target", systemImage: "target")
                    }
                }

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        onToggleMetricSize(metric)
                    }
                } label: {
                    Label(metric.isWideGlanceCard(sizeOverrides: sizeOverrides) ? "Make compact" : "Make wide",
                          systemImage: metric.isWideGlanceCard(sizeOverrides: sizeOverrides)
                          ? "rectangle.compress.horizontal"
                          : "rectangle.expand.horizontal")
                }

                Button(role: .destructive) {
                    withAnimation(.snappy(duration: 0.2)) {
                        onHideMetric(metric)
                        if visibleMetrics.count <= 1 {
                            isEditingGlance = false
                        }
                    }
                } label: {
                    Label("Remove widget", systemImage: "xmark")
                }
            }
            .layoutPriority(metric.isWideGlanceCard(sizeOverrides: sizeOverrides) ? 2 : 1)
            .modifier(AtriaConditionalStringDraggable(isEnabled: true,
                                                       payload: metric.dragPayload))
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let dragged = AtriaTodayMetric.draggedMetric(from: raw) else { return false }
                withAnimation(.snappy(duration: 0.2)) {
                    isEditingGlance = true
                    onMoveMetric(dragged, metric)
                }
                return true
            }
            .accessibilityAction(named: upLabel) {
                onShiftMetric(metric, -1)
            }
            .accessibilityAction(named: downLabel) {
                onShiftMetric(metric, 1)
            }
            .accessibilityAction(named: Text("Edit \(metric.label) widget")) {
                isEditingGlance = true
            }
            .accessibilityAction(named: Text("Edit \(metric.label) target")) {
                if metric.supportsGlanceTargetEditing {
                    targetEditorMetric = metric
                }
            }
            .accessibilityAction(named: Text(metric.isWideGlanceCard(sizeOverrides: sizeOverrides)
                                            ? "Make \(metric.label) compact"
                                            : "Make \(metric.label) wide")) {
                onToggleMetricSize(metric)
            }
            .accessibilityAction(named: Text("Remove \(metric.label) widget")) {
                onHideMetric(metric)
                if visibleMetrics.count <= 1 {
                    isEditingGlance = false
                }
            }
            .accessibilityHint("Drag to reorder, or long press to edit with target, resize, and remove controls.")
    }

    @ViewBuilder
    private func glanceEditingBorder(for metric: AtriaTodayMetric) -> some View {
        if isEditingGlance {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(metric.targetEditorTint.opacity(0.32), lineWidth: 1.2)
                .allowsHitTesting(false)
        }
    }

    private func glanceCardWidth(for metric: AtriaTodayMetric,
                                 containerWidth: CGFloat,
                                 sizeOverrides: [String: AtriaGlanceGridSize]) -> CGFloat {
        let columnWidth = (containerWidth - Self.glanceGridSpacing) / CGFloat(Self.glanceGridColumnCount)
        if metric.isWideGlanceCard(sizeOverrides: sizeOverrides) {
            return (columnWidth * CGFloat(Self.glanceGridColumnCount)) + Self.glanceGridSpacing
        }
        return columnWidth
    }

    private func glanceTargetControl(for metric: AtriaTodayMetric) -> some View {
        Button {
            targetEditorMetric = metric
        } label: {
            Image(systemName: "target")
                .font(.callout.weight(.bold))
        }
        .atriaGlassIconAction(tint: metric.targetEditorTint, size: 36)
        .accessibilityLabel("Edit \(metric.label) target")
        .accessibilityHint("Opens the target zone controls for this Today widget.")
    }

    private func glanceRemoveControl(for metric: AtriaTodayMetric) -> some View {
        Button(role: .destructive) {
            withAnimation(.snappy(duration: 0.2)) {
                onHideMetric(metric)
                if visibleMetrics.count <= 1 {
                    isEditingGlance = false
                }
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.callout.weight(.black))
        }
        .atriaGlassIconAction(tint: .red, size: 36)
        .contentShape(Circle())
        .accessibilityLabel("Remove \(metric.label) widget")
        .accessibilityHint("Removes this card from Today at a glance. Use the plus button to add it back.")
    }

    private func glanceResizeControl(for metric: AtriaTodayMetric,
                                     sizeOverrides: [String: AtriaGlanceGridSize]) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                onToggleMetricSize(metric)
            }
        } label: {
            Image(systemName: metric.isWideGlanceCard(sizeOverrides: sizeOverrides)
                  ? "rectangle.compress.horizontal"
                  : "rectangle.expand.horizontal")
                .font(.callout.weight(.bold))
        }
        .atriaGlassIconAction(tint: .secondary, size: 36)
        .accessibilityLabel(metric.isWideGlanceCard(sizeOverrides: sizeOverrides)
                            ? "Make \(metric.label) compact"
                            : "Make \(metric.label) wide")
    }

    @ViewBuilder
    private func glanceCard(_ metric: AtriaTodayMetric) -> some View {
        switch metric {
        case .recovery:
            AtriaGlanceMetricCard(title: "Recovery",
                                  value: hero.recoveryEstimate.percent == nil ? "--" : hero.recoveryValue,
                                  detail: recoveryDetailText,
                                  systemImage: metric.systemImage,
                                  tint: recoveryZone?.tint ?? recoveryColor(hero.recoveryEstimate.percent),
                                  ringFraction: hero.recoveryEstimate.percent.map { Double($0) / 100 },
                                  zone: recoveryZone)
        case .strain:
            AtriaGlanceMetricCard(title: "Strain",
                                  value: metricDisplayValue(hero.strainValue),
                                  detail: "Day load",
                                  systemImage: metric.systemImage,
                                  tint: strainZone?.tint ?? .orange,
                                  ringFraction: metricIsPending(hero.strainValue) ? nil : min(max(hero.strain / 21, 0), 1),
                                  zone: strainZone)
        case .load:
            AtriaGlanceMetricCard(title: "Training load",
                                  value: hero.loadReadinessText,
                                  detail: hero.loadConfidence == "learning" ? "Learning" : hero.loadSignalSummaryText,
                                  systemImage: metric.systemImage,
                                  tint: loadReadinessZone?.tint ?? loadReadinessTint,
                                  ringFraction: loadReadinessFraction,
                                  zone: loadReadinessZone)
                .accessibilityLabel("Training load readiness \(hero.loadReadinessText). \(hero.loadSignalSummaryText). \(hero.loadNarrative)")
        case .workout:
            workoutCard(metric)
        case .backfill:
            backfillCard(metric)
        case .hapticAlerts:
            AtriaGlanceMetricCard(title: "Alerts",
                                  value: hapticSettings.glanceValueText,
                                  detail: hapticSettings.glanceDetailText,
                                  systemImage: metric.systemImage,
                                  tint: hapticSettings.enabledCount == 0 ? .secondary : .purple)
                .accessibilityLabel("Phone haptic alerts \(hapticSettings.glanceValueText), \(hapticSettings.glanceDetailText). Configure alerts in Data or Settings.")
        case .hrv:
            AtriaGlanceMetricCard(title: "HRV",
                                  value: metricDisplayValue(hero.hrvValue),
                                  detail: hrvDetailText,
                                  systemImage: metric.systemImage,
                                  tint: hrvZone?.tint ?? .pink,
                                  zone: hrvZone)
        case .stress:
            AtriaGlanceMetricCard(title: "Stress",
                                  value: hero.stressValue,
                                  detail: hero.stressDetail,
                                  systemImage: metric.systemImage,
                                  tint: stressTint,
                                  accessibilityDetail: hero.stressNarrative)
        case .sleep:
            AtriaGlanceMetricCard(title: "Sleep",
                                  value: sleepGlanceValueText,
                                  detail: sleepGlanceDetailText,
                                  systemImage: metric.systemImage,
                                  tint: sleepDurationZone?.tint ?? sleepGlanceTint,
                                  zone: sleepDurationZone)
        case .sleepHistory:
            sleepHistoryCard
        case .sleepEfficiency:
            AtriaGlanceMetricCard(title: "Sleep eff",
                                  value: sleepHistory.latest?.sleepEfficiencyText ?? "--",
                                  detail: sleepHistory.latest?.sleepEfficiency == nil ? "Building" : "Duration-based",
                                  systemImage: metric.systemImage,
                                  tint: sleepEfficiencyZone?.tint ?? (sleepHistory.latest?.sleepEfficiency == nil ? .orange : .cyan),
                                  zone: sleepEfficiencyZone,
                                  accessibilityDetail: sleepHistory.latest?.sleepEfficiency == nil
                                    ? "Sleep efficiency is building from saved sleep duration."
                                    : "Sleep efficiency duration-based estimate \(sleepHistory.latest?.sleepEfficiencyText ?? "--").")
        case .rhr:
            AtriaGlanceMetricCard(title: "RHR",
                                  value: metricDisplayValue(hero.restingHeartRateText),
                                  detail: "Baseline",
                                  systemImage: metric.systemImage,
                                  tint: restingHeartRateZone?.tint ?? .red,
                                  zone: restingHeartRateZone)
        case .respiratoryRate:
            AtriaGlanceMetricCard(title: "Resp rate",
                                  value: sleepHistory.latest?.respiratoryRateText ?? "--",
                                  detail: sleepHistory.latest?.respiratoryRate == nil ? "Sleep research" : "Research",
                                  systemImage: metric.systemImage,
                                  tint: respiratoryRateZone?.tint ?? (sleepHistory.latest?.respiratoryRate == nil ? .orange : .teal),
                                  zone: respiratoryRateZone,
                                  accessibilityDetail: sleepHistory.latest?.respiratoryRate == nil
                                    ? "Respiratory rate is building from sleep-only evidence."
                                    : "Respiratory rate research sleep-only estimate \(sleepHistory.latest?.respiratoryRateText ?? "--") breaths per minute.")
        case .steps:
            AtriaGlanceMetricCard(title: "Steps",
                                  value: live.phoneStepsText,
                                  detail: live.phoneMotionDetailText,
                                  systemImage: metric.systemImage,
                                  tint: stepsZone?.tint ?? .green,
                                  zone: stepsZone,
                                  accessibilityDetail: "Steps counted by iPhone motion \(live.phoneStepsText), \(live.phoneMotionDetailText).")
        case .strapSteps:
            AtriaGlanceMetricCard(title: "Strap steps",
                                  value: sensorSummary.strapStepText,
                                  detail: sensorSummary.strapStepCount > 0 ? sensorSummary.agreementText : "Research",
                                  systemImage: metric.systemImage,
                                  tint: strapStepsZone?.tint ?? (sensorSummary.strapStepCount > 0 ? .green : .orange),
                                  zone: strapStepsZone,
                                  accessibilityDetail: sensorSummary.strapStepCount > 0
                                    ? "Strap step research \(sensorSummary.strapStepText), agreement \(sensorSummary.agreementText), goal \(stepsGoal) steps."
                                    : "Strap step research is waiting for validated motion evidence.")
        case .calories:
            AtriaGlanceMetricCard(title: "Calories",
                                  value: live.liveActiveCaloriesText,
                                  detail: live.liveActiveCalories == nil ? "Needs profile" : "Estimate",
                                  systemImage: metric.systemImage,
                                  tint: activeCaloriesZone?.tint ?? .orange,
                                  zone: activeCaloriesZone,
                                  accessibilityDetail: "Active calories estimate \(live.liveActiveCaloriesText).")
        case .vo2max:
            AtriaGlanceMetricCard(title: "VO2max",
                                  value: vo2MaxEstimate.value.map { String(format: "%.1f", $0) } ?? "--",
                                  detail: vo2MaxEstimate.value == nil ? "Building" : vo2MaxDetailText,
                                  systemImage: metric.systemImage,
                                  tint: vo2TrendZone?.tint ?? (vo2MaxEstimate.value == nil ? .orange : .blue),
                                  zone: vo2TrendZone,
                                  accessibilityDetail: vo2MaxEstimate.value == nil
                                    ? "VO2max building from resting baseline and measured HR max."
                                    : "VO2max \(vo2MaxEstimate.confidence) \(vo2MaxEstimate.valueText), trend \(vo2MaxEstimate.trendText), \(vo2MaxEstimate.trendDetail).")
        case .bioAge:
            AtriaGlanceMetricCard(title: "Body age",
                                  value: biologicalAgeSummary.valueText,
                                  detail: biologicalAgeSummary.isReady ? biologicalAgeSummary.detailText : "Building baseline",
                                  systemImage: metric.systemImage,
                                  tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? (biologicalAgeSummary.ageDelta ?? 0 <= 0 ? .green : .orange) : .orange),
                                  zone: biologicalAgeZone,
                                  accessibilityDetail: biologicalAgeSummary.isReady
                                    ? "Biological age estimate \(biologicalAgeSummary.valueText), \(biologicalAgeSummary.detailText). \(biologicalAgeSummary.footnote)"
                                    : "Building your body-age baseline. \(biologicalAgeSummary.blockerText). \(biologicalAgeSummary.footnote)")
        case .bloodOxygen:
            AtriaGlanceMetricCard(title: "Blood oxygen",
                                  value: sensorSummary.spo2CandidateFrames > 0 ? "Research" : "--",
                                  detail: sensorSummary.spo2CandidateFrames > 0 ? "\(sensorSummary.spo2CandidateFrames) candidate frames" : "Sleep research",
                                  systemImage: metric.systemImage,
                                  tint: bloodOxygenResearchZone?.tint ?? (sensorSummary.spo2CandidateFrames > 0 ? .blue : .orange),
                                  zone: bloodOxygenResearchZone,
                                  accessibilityDetail: sensorSummary.spo2CandidateFrames > 0
                                    ? "Blood oxygen research has \(sensorSummary.spo2CandidateFrames) candidate frames, not an SpO2 reading."
                                    : "Blood oxygen research is building and does not show an SpO2 percentage.")
        case .bodyTemp:
            AtriaGlanceMetricCard(title: "Body temp",
                                  value: sensorSummary.skinTemperatureDeviation.isReady ? sensorSummary.skinTemperatureDeviation.valueText : "--",
                                  detail: sensorSummary.skinTemperatureDeviation.detailText,
                                  systemImage: metric.systemImage,
                                  tint: skinTemperatureDeviationZone?.tint ?? (sensorSummary.skinTemperatureDeviation.isReady ? .teal : .orange),
                                  zone: skinTemperatureDeviationZone,
                                  accessibilityDetail: sensorSummary.skinTemperatureDeviation.isReady
                                    ? "Body temperature research relative deviation \(sensorSummary.skinTemperatureDeviation.valueText) delta C from baseline, \(sensorSummary.skinTemperatureDeviation.footnoteText)."
                                    : "Body temperature research is building a sleep baseline and does not show an absolute temperature.")
        case .trend:
            trendCard
        case .insights:
            insightsCard
        }
    }

    private func workoutCard(_ metric: AtriaTodayMetric) -> some View {
        Button(action: onStartWorkout) {
            AtriaGlanceMetricCard(title: "Workout",
                                  value: live.status == .connected ? "Start" : "Connect",
                                  detail: live.sessionSampleCount > 0 ? "\(live.sessionSampleCount) readings" : "Live mode",
                                  systemImage: metric.systemImage,
                                  tint: live.status == .connected ? .green : .orange)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(live.status == .connected
                            ? "Start live workout"
                            : "Connect strap before starting live workout")
    }

    private func backfillCard(_ metric: AtriaTodayMetric) -> some View {
        Button(action: onOpenCollection) {
            AtriaGlanceMetricCard(title: "Backfill",
                                  value: historicalArchiveStatus.valueText,
                                  detail: historicalArchiveStatus.detailText,
                                  systemImage: metric.systemImage,
                                  tint: backfillTint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Data. Backfill \(historicalArchiveStatus.valueText). \(historicalArchiveStatus.userFootnoteText) \(historicalArchiveStatus.actionText)")
    }

    private var backfillTint: Color {
        if historicalArchiveStatus.metricReady { return .green }
        if historicalArchiveStatus.hasArchiveRows { return .cyan }
        if !historicalArchiveStatus.parseOK { return .red }
        return .orange
    }

    private var sleepHistoryCard: some View {
        AtriaSleepHistoryGlanceCard(snapshot: sleepHistory,
                                    sleepGoalHours: sleepGoalHours,
                                    onOpenVitals: onOpenVitals,
                                    onAddManualSleep: {
                                        showManualSleepSheet = true
                                    })
        .accessibilityLabel(sleepHistory.nights.isEmpty
                            ? "Open Vitals. Sleep history is building. Wear the strap overnight or during a nap."
                            : "Open Vitals. Sleep history average \(sleepHistory.averageDurationText). \(sleepHistory.averageFootnoteText)")
    }

    private var sleepGlanceValueText: String {
        if let latest = sleepHistory.latest {
            return latest.durationText
        }
        if sleepHistory.candidateCount > 0 {
            return "\(sleepHistory.candidateCount)"
        }
        if !metricIsPending(snapshot.sleepValue) { return snapshot.sleepValue }
        return "--"
    }

    private var sleepGlanceDetailText: String {
        if let latest = sleepHistory.latest {
            if latest.confirmed {
                return latest.isNapEvidence ? "Last nap" : "Last"
            }
            return "Review"
        }
        if sleepHistory.candidateCount > 0 { return "Review" }
        if !metricIsPending(snapshot.sleepValue) { return snapshot.sleepValue == "Maybe" ? "Review" : "Last" }
        return "Learning"
    }

    private var sleepGlanceTint: Color {
        sleepHistory.candidateCount > 0 ? .cyan : .orange
    }

    private var trendCard: some View {
        AtriaGlanceMetricCard(title: "Resting trend",
                              value: trendValues.count > 1 ? "\(trendValues.last ?? 0)" : "--",
                              detail: trendValues.count > 1 ? "14 sessions" : "Building",
                              systemImage: AtriaTodayMetric.trend.systemImage,
                              tint: .red,
                              sparklineValues: trendValues.count > 1 ? trendValues : [0, 0])
    }

    private var insightsCard: some View {
        let topInsight = insights.first
        return Button(action: onOpenInsights) {
            AtriaGlanceMetricCard(title: "Insights",
                                  value: insights.isEmpty ? "--" : "\(insights.count)",
                                  detail: topInsight?.tagLabel ?? (taggedDays > 0 ? "Learning patterns" : "Tag today"),
                                  systemImage: AtriaTodayMetric.insights.systemImage,
                                  tint: topInsight?.isPositive == false ? .red : .purple)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(insights.isEmpty
                            ? "Open Trends. Insights building from \(taggedDays) tagged days"
                            : "Open Trends. \(insights.count) local insights ready")
    }

    private var stressTint: Color {
        if hero.stressValue == "Learning" { return .orange }
        if hero.stressValue.hasPrefix("0") { return .green }
        if hero.stressValue.hasPrefix("1") { return .mint }
        if hero.stressValue.hasPrefix("2") { return .orange }
        return .red
    }

    private var hrvDetailText: String {
        let detail = hero.hrvDetail.lowercased()
        if detail.contains("validated") { return "Validated" }
        if detail.contains("personal baseline") || detail.contains("% kept") { return "Personal baseline" }
        return "Building"
    }

    private var vo2MaxDetailText: String {
        let confidence = vo2MaxEstimate.confidence.capitalized
        guard vo2MaxEstimate.trendText != "Learning" else { return confidence }
        return "\(confidence) · \(vo2MaxEstimate.trendText)"
    }

    private var recoveryDetailText: String {
        switch hero.recoveryEstimate.confidence {
        case .validated:
            return "Validated"
        case .personalBaseline:
            return "Personal baseline"
        case .unverified:
            return "Unverified"
        case .learning:
            if hero.recoveryEstimate.detail.localizedCaseInsensitiveContains("HRV baseline") {
                return "Building baseline"
            }
            return "Building"
        }
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

    private var recoveryZone: AtriaMetricZone? {
        Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)
    }

    private var strainZone: AtriaMetricZone? {
        Metrics.strainZone(strain: hero.strain,
                           target: hero.guidance.target,
                           greenBand: strainGreenBand,
                           yellowBand: strainYellowBand)
    }

    private var loadReadinessTint: Color {
        switch hero.loadReadinessText.lowercased() {
        case "balanced", "primed":
            return .green
        case "strained":
            return .orange
        case "rundown":
            return .red
        default:
            return .secondary
        }
    }

    private var loadReadinessFraction: Double? {
        switch hero.loadReadinessText.lowercased() {
        case "primed":
            return 0.88
        case "balanced":
            return 0.72
        case "strained":
            return 0.46
        case "rundown":
            return 0.22
        default:
            return nil
        }
    }

    private var loadReadinessZone: AtriaMetricZone? {
        let readiness = hero.loadReadinessText.lowercased()
        guard readiness != "learning",
              let level = loadReadinessZoneLevel else { return nil }

        let recommendation: String
        switch level {
        case .green:
            recommendation = readiness == "primed"
                ? "Recent load is below your base. Add training gradually if recovery and schedule support it."
                : "Training load is aligned with your longer baseline. Keep alternating hard and easy days."
        case .yellow:
            recommendation = "ACWR or monotony is near your watch band. Favor recovery, vary intensity, or keep the next session lighter."
        case .red:
            recommendation = "Training load is outside your edited red band. Keep the next session easy and rebuild gradually."
        }

        return AtriaMetricZone(level: level,
                               title: "Training load readiness",
                               current: hero.loadNarrative,
                               targetSummary: loadTargetSummary,
                               recommendation: recommendation,
                               disclaimer: AtriaMetricZone.nonMedicalDisclaimer)
    }

    private var loadReadinessZoneLevel: AtriaMetricZoneLevel? {
        let ratio = parseDouble(hero.loadRatioText)
        let monotony = parseDouble(hero.loadMonotonyText)
        guard ratio != nil || monotony != nil else { return nil }

        if let ratio,
           ratio < loadACWRBadLow || ratio >= loadACWRBadHigh {
            return .red
        }
        if let monotony, monotony >= loadMonotonyBad {
            return .red
        }
        if let ratio,
           ratio < loadACWRWatchLow || ratio > loadACWRWatchHigh {
            return .yellow
        }
        if let monotony, monotony >= loadMonotonyWatch {
            return .yellow
        }
        return .green
    }

    private var loadTargetSummary: String {
        let target = String(format: "Editable target · ACWR green %.2f-%.2f, red <%.2f or >=%.2f; monotony watch %.1f, red %.1f.",
                            loadACWRWatchLow,
                            loadACWRWatchHigh,
                            loadACWRBadLow,
                            loadACWRBadHigh,
                            loadMonotonyWatch,
                            loadMonotonyBad)
        return "\(target) Current: ACWR \(hero.loadRatioText) \(hero.loadACWRSignalText); monotony \(hero.loadMonotonyText) \(hero.loadMonotonySignalText)."
    }

    private func parseDouble(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isNumber || $0 == "." || $0 == "-" })
    }

    private var hrvZone: AtriaMetricZone? {
        Metrics.hrvZone(parseInt(hero.hrvValue),
                        baseline: hrvBaseline,
                        baselineSamples: hrvBaselineSamples,
                        baselineTrusted: hrvBaselineTrusted,
                        baselineTarget: baselineTarget,
                        greenRatio: hrvGreenRatio,
                        yellowRatio: hrvYellowRatio)
    }

    private var restingHeartRateZone: AtriaMetricZone? {
        Metrics.restingHeartRateZone(hero.restingHeartRate,
                                     baseline: restingBaseline,
                                     baselineSamples: restingBaselineSamples,
                                     baselineTrusted: restingBaselineTrusted,
                                     baselineTarget: baselineTarget,
                                     greenDelta: restingGreenDelta,
                                     yellowDelta: restingYellowDelta)
    }

    private var sleepEfficiencyZone: AtriaMetricZone? {
        Metrics.sleepEfficiencyZone(sleepHistory.latest?.sleepEfficiency,
                                    greenLower: sleepEfficiencyGreenLower,
                                    yellowLower: sleepEfficiencyYellowLower)
    }

    private var sleepDurationZone: AtriaMetricZone? {
        Metrics.sleepDurationZone(sleepHistory.latest?.durationHours, goalHours: sleepGoalHours)
    }

    private var stepsZone: AtriaMetricZone? {
        Metrics.stepsZone(live.phoneStepsToday > 0 ? live.phoneStepsToday : nil,
                          goal: stepsGoal)
    }

    private var strapStepsZone: AtriaMetricZone? {
        guard sensorSummary.strapStepCount > 0 else { return nil }
        let zone = Metrics.stepsZone(sensorSummary.strapStepCount, goal: stepsGoal)
        return zone.map {
            AtriaMetricZone(level: $0.level,
                            title: "Strap step research goal",
                            current: "\($0.current) Strap-step agreement: \(sensorSummary.agreementText).",
                            targetSummary: $0.targetSummary,
                            recommendation: "\($0.recommendation) Strap steps remain research-tier until motion agreement is validated.",
                            disclaimer: "Research strap-step estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
        }
    }

    private var activeCaloriesZone: AtriaMetricZone? {
        Metrics.activeCaloriesZone(live.liveActiveCalories,
                                   goal: caloriesGoal)
    }

    private var vo2TrendZone: AtriaMetricZone? {
        Metrics.vo2TrendZone(vo2MaxEstimate,
                             greenDelta: vo2GreenDelta,
                             redDelta: vo2RedDelta)
    }

    private var biologicalAgeZone: AtriaMetricZone? {
        Metrics.biologicalAgeZone(biologicalAgeSummary,
                                  greenOlderDelta: biologicalAgeGreenOlderDelta,
                                  yellowOlderDelta: biologicalAgeYellowOlderDelta)
    }

    private var respiratoryRateZone: AtriaMetricZone? {
        return Metrics.respiratoryRateZone(sleepHistory.latest?.respiratoryRate,
                                           baseline: sleepHistory.respiratoryBaselineMean,
                                           baselineSamples: sleepHistory.respiratoryBaselineCount,
                                           greenDelta: respiratoryGreenDelta,
                                           yellowDelta: respiratoryYellowDelta)
    }

    private var skinTemperatureDeviationZone: AtriaMetricZone? {
        Metrics.skinTemperatureDeviationZone(sensorSummary.skinTemperatureDeviation,
                                             greenDelta: skinTemperatureGreenDelta,
                                             yellowDelta: skinTemperatureYellowDelta)
    }

    private var bloodOxygenResearchZone: AtriaMetricZone? {
        Metrics.bloodOxygenResearchZone(candidateFrames: sensorSummary.spo2CandidateFrames,
                                        goalFrames: bloodOxygenCandidateGoal)
    }

    private func parseInt(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isNumber })
    }

}

private struct AtriaConditionalStringDraggable: ViewModifier {
    let isEnabled: Bool
    let payload: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(payload)
        } else {
            content
        }
    }
}

private struct AtriaGlanceWidgetManagerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let hiddenMetrics: [AtriaTodayMetric]
    let onEditWidgets: () -> Void
    let onShowMetric: (AtriaTodayMetric) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    managerSection(title: "Add widget",
                                   subtitle: hiddenMetrics.isEmpty ? "All glance widgets are already visible." : "Bring hidden cards back to Today at a glance.") {
                        if hiddenMetrics.isEmpty {
                            Label("All widgets added", systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .atriaInsetCard(tint: .secondary)
                        } else {
                            ForEach(hiddenMetrics) { metric in
                                managerRow(metric: metric,
                                           actionTitle: "Add",
                                           actionImage: "plus.circle.fill",
                                           tint: metric.targetEditorTint,
                                           role: nil) {
                                    onShowMetric(metric)
                                }
                            }
                        }
                    }

                    Button {
                        onEditWidgets()
                        dismiss()
                    } label: {
                        Label("Edit on cards", systemImage: "square.grid.2x2")
                            .font(.footnote.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AtriaCardActionButtonStyle(tint: .secondary))
                    .accessibilityHint("Shows the remove, resize, and target controls directly on Today widgets.")
                }
                .padding(16)
            }
            .navigationTitle("Add widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func managerSection<Content: View>(title: String,
                                               subtitle: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                content()
            }
        }
    }

    private func managerRow(metric: AtriaTodayMetric,
                            actionTitle: String,
                            actionImage: String,
                            tint: Color,
                            role: ButtonRole?,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: metric.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

            Text(metric.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button(role: role) {
                action()
            } label: {
                Label(actionTitle, systemImage: actionImage)
                    .font(.caption.weight(.bold))
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 96)
            }
            .buttonStyle(AtriaCardActionButtonStyle(tint: tint))
        }
        .padding(12)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("\(actionTitle) \(metric.label) widget")) {
            action()
        }
    }
}

private struct AtriaGlanceMetricCard: View, Equatable {
    static let cardHeight: CGFloat = 152
    private static let headerHeight: CGFloat = 44
    private static let valueHeight: CGFloat = 38
    private static let footerHeight: CGFloat = 30

    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    var ringFraction: Double? = nil
    var sparklineValues: [Int]? = nil
    var zone: AtriaMetricZone? = nil
    var accessibilityDetail: String? = nil
    @State private var showingZoneInfo = false

    static func == (lhs: AtriaGlanceMetricCard, rhs: AtriaGlanceMetricCard) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.systemImage == rhs.systemImage
            && lhs.tint == rhs.tint
            && lhs.ringFraction == rhs.ringFraction
            && lhs.sparklineValues == rhs.sparklineValues
            && lhs.zone == rhs.zone
            && lhs.accessibilityDetail == rhs.accessibilityDetail
    }

    static var placeholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight)
    }

    private var hasProgressSignal: Bool {
        ringFraction != nil
    }

    private var clampedRingFraction: Double? {
        guard hasProgressSignal, let ringFraction else { return nil }
        return min(max(ringFraction, 0), 1)
    }

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : value
    }

    private var accessibilityText: String {
        var parts = ["\(title) \(displayValue)", detail]
        if let accessibilityDetail,
           !accessibilityDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(accessibilityDetail)
        }
        if let zone, zone.showsWarning {
            parts.append(zone.level.label)
            parts.append(zone.targetSummary)
            parts.append("Tap info for guidance.")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                AtriaGlanceMetricMarker(systemImage: systemImage,
                                        tint: tint,
                                        progressFraction: clampedRingFraction)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .allowsTightening(true)

                    Text(detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .allowsTightening(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let zone, zone.showsWarning {
                    AtriaMetricZoneInfoButton(zone: zone) {
                        showingZoneInfo = true
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .frame(height: Self.headerHeight, alignment: .center)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayValue)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Spacer(minLength: 0)
            }
            .frame(height: Self.valueHeight, alignment: .bottom)

            footer
        }
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
        .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .sheet(isPresented: $showingZoneInfo) {
            if let zone {
                AtriaMetricZoneInfoSheet(zone: zone)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let sparklineValues {
            Sparkline(values: sparklineValues)
                .frame(height: Self.footerHeight)
                .opacity(sparklineValues.count > 1 ? 1 : 0.28)
                .accessibilityLabel("\(title) sparkline")
        } else if hasProgressSignal, let ringFraction {
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
}

struct AtriaGlanceTargetEditorSheet: View {
    let metric: AtriaTodayMetric
    @Environment(\.dismiss) private var dismiss
    @AppStorage("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AppStorage("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AppStorage("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AppStorage("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AppStorage("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AppStorage("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AppStorage("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AppStorage("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AppStorage("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AppStorage("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AppStorage("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AppStorage("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AppStorage("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AppStorage("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AppStorage("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AppStorage("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AppStorage("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AppStorage("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AppStorage("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AppStorage("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AppStorage("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AppStorage("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AppStorage("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AppStorage("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AppStorage("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AppStorage("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AppStorage("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AppStorage("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    var body: some View {
        let summary = metric.targetEditorSummary
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: metric.systemImage)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(metric.targetEditorTint)
                        .frame(width: 42, height: 42)
                        .background(AtriaIconTileBackground(cornerRadius: 14, tint: metric.targetEditorTint))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(metric.label) target")
                            .font(.headline.weight(.semibold))
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                editorContent
                    .padding(14)
                    .atriaInsetCard(tint: metric.targetEditorTint)

                Text("Guidance is general wellness information, not medical advice. Changes update Today cards immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .onChange(of: targetEditorSignature) { _, _ in normalizeAllTargets() }
    }

    private var targetEditorSignature: String {
        [
            recoveryGreenLower,
            recoveryYellowLower,
            strainGreenBand,
            strainYellowBand,
            loadACWRWatchLow,
            loadACWRWatchHigh,
            loadACWRBadLow,
            loadACWRBadHigh,
            loadMonotonyWatch,
            loadMonotonyBad,
            Double(stepsGoal),
            Double(caloriesGoal),
            sleepGoalHours,
            sleepEfficiencyGreenLower,
            sleepEfficiencyYellowLower,
            hrvGreenRatio,
            hrvYellowRatio,
            Double(restingGreenDelta),
            Double(restingYellowDelta),
            respiratoryGreenDelta,
            respiratoryYellowDelta,
            skinTemperatureGreenDelta,
            skinTemperatureYellowDelta,
            Double(bloodOxygenCandidateGoal),
            Double(biologicalAgeGreenOlderDelta),
            Double(biologicalAgeYellowOlderDelta),
            vo2GreenDelta,
            vo2RedDelta,
        ]
        .map { String(format: "%.3f", $0) }
        .joined(separator: "|")
    }

    private func normalizeAllTargets() {
        normalizeRecoveryTargets()
        normalizeStrainTargets()
        normalizeTrainingLoadTargets()
        normalizeStepsGoal()
        normalizeCaloriesGoal()
        normalizeSleepGoal()
        normalizeSleepEfficiencyTargets()
        normalizeHRVTargets()
        normalizeRestingTargets()
        normalizeRespiratoryTargets()
        normalizeSkinTemperatureTargets()
        normalizeBloodOxygenTargets()
        normalizeBiologicalAgeTargets()
        normalizeVO2Targets()
    }

    @ViewBuilder
    private var editorContent: some View {
        switch metric {
        case .recovery:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $recoveryGreenLower, in: 40...95, step: 1) {
                    LabeledContent("Green starts") {
                        Text("\(Int(recoveryGreenLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $recoveryYellowLower, in: 5...66, step: 1) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int(recoveryYellowLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Button {
                    recoveryGreenLower = 67
                    recoveryYellowLower = 34
                } label: {
                    Label("Reset recovery target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .green))
            }
        case .strain:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $strainGreenBand, in: 0.5...5.0, step: 0.5) {
                    LabeledContent("Green band") {
                        Text(String(format: "+/-%.1f", strainGreenBand))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $strainYellowBand, in: 1.0...8.0, step: 0.5) {
                    LabeledContent("Yellow band") {
                        Text(String(format: "+/-%.1f", strainYellowBand))
                            .monospacedDigit()
                    }
                }
                Button {
                    strainGreenBand = 1.5
                    strainYellowBand = 3.0
                } label: {
                    Label("Reset strain band", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .orange))
            }
        case .load:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $loadACWRWatchLow, in: 0.50...1.00, step: 0.05) {
                    LabeledContent("ACWR low watch") {
                        Text(String(format: "%.2f", loadACWRWatchLow))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRWatchHigh, in: 1.00...1.60, step: 0.05) {
                    LabeledContent("ACWR high watch") {
                        Text(String(format: "%.2f", loadACWRWatchHigh))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRBadLow, in: 0.30...0.95, step: 0.05) {
                    LabeledContent("ACWR low red") {
                        Text(String(format: "%.2f", loadACWRBadLow))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRBadHigh, in: 1.10...2.20, step: 0.05) {
                    LabeledContent("ACWR high red") {
                        Text(String(format: "%.2f", loadACWRBadHigh))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadMonotonyWatch, in: 1.0...4.0, step: 0.1) {
                    LabeledContent("Monotony watch") {
                        Text(String(format: "%.1f", loadMonotonyWatch))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadMonotonyBad, in: 1.2...5.0, step: 0.1) {
                    LabeledContent("Monotony red") {
                        Text(String(format: "%.1f", loadMonotonyBad))
                            .monospacedDigit()
                    }
                }
                Button {
                    loadACWRWatchLow = 0.80
                    loadACWRWatchHigh = 1.30
                    loadACWRBadLow = 0.60
                    loadACWRBadHigh = 1.50
                    loadMonotonyWatch = 2.0
                    loadMonotonyBad = 2.5
                } label: {
                    Label("Reset training-load target", systemImage: "chart.bar.xaxis")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .orange))
                Text("ACWR compares 7-day strain with 28-day strain; monotony flags repetitive load. This tunes guidance colors only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .sleep, .sleepHistory:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                    LabeledContent("Sleep goal") {
                        Text(String(format: "%.2g h", sleepGoalHours))
                            .monospacedDigit()
                    }
                }
                Button {
                    sleepGoalHours = 8.0
                } label: {
                    Label("Reset sleep goal", systemImage: "bed.double.fill")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .cyan))
            }
        case .hrv:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $hrvGreenRatio, in: 0.70...1.10, step: 0.01) {
                    LabeledContent("Green starts") {
                        Text("\(Int((hrvGreenRatio * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $hrvYellowRatio, in: 0.50...0.98, step: 0.01) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int((hrvYellowRatio * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }
                Button {
                    hrvGreenRatio = 0.95
                    hrvYellowRatio = 0.85
                } label: {
                    Label("Reset HRV target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .pink))
            }
        case .rhr:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $restingGreenDelta, in: 0...12, step: 1) {
                    LabeledContent("Green within") {
                        Text("+\(restingGreenDelta) bpm")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $restingYellowDelta, in: 1...20, step: 1) {
                    LabeledContent("Yellow within") {
                        Text("+\(restingYellowDelta) bpm")
                            .monospacedDigit()
                    }
                }
                Button {
                    restingGreenDelta = 3
                    restingYellowDelta = 7
                } label: {
                    Label("Reset RHR target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .red))
            }
        case .respiratoryRate:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $respiratoryGreenDelta, in: 0.5...4.0, step: 0.5) {
                    LabeledContent("Green within") {
                        Text(String(format: "+/-%.1f/min", respiratoryGreenDelta))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $respiratoryYellowDelta, in: 1.0...8.0, step: 0.5) {
                    LabeledContent("Yellow within") {
                        Text(String(format: "+/-%.1f/min", respiratoryYellowDelta))
                            .monospacedDigit()
                    }
                }
                Button {
                    respiratoryGreenDelta = 1.5
                    respiratoryYellowDelta = 3.0
                } label: {
                    Label("Reset resp-rate target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .teal))
            }
        case .bloodOxygen:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $bloodOxygenCandidateGoal, in: 2...120, step: 1) {
                    LabeledContent("Green evidence") {
                        Text("\(bloodOxygenCandidateGoal) frames")
                            .monospacedDigit()
                    }
                }
                Button {
                    bloodOxygenCandidateGoal = 8
                } label: {
                    Label("Reset oxygen research target", systemImage: "drop.degreesign")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .blue))
                Text("This tunes candidate-frame evidence only. Atria still does not show an SpO2 percentage until the protocol is validated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .bodyTemp:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $skinTemperatureGreenDelta, in: 0.2...2.0, step: 0.1) {
                    LabeledContent("Green within") {
                        Text(String(format: "+/-%.1f C", skinTemperatureGreenDelta))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $skinTemperatureYellowDelta, in: 0.3...4.0, step: 0.1) {
                    LabeledContent("Yellow within") {
                        Text(String(format: "+/-%.1f C", skinTemperatureYellowDelta))
                            .monospacedDigit()
                    }
                }
                Button {
                    skinTemperatureGreenDelta = 0.5
                    skinTemperatureYellowDelta = 1.0
                } label: {
                    Label("Reset temp target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .teal))
            }
        case .bioAge:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $biologicalAgeGreenOlderDelta, in: -10...10, step: 1) {
                    LabeledContent("Green up to") {
                        Text("\(biologicalAgeGreenOlderDelta > 0 ? "+" : "")\(biologicalAgeGreenOlderDelta)y")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $biologicalAgeYellowOlderDelta, in: -9...20, step: 1) {
                    LabeledContent("Yellow up to") {
                        Text("\(biologicalAgeYellowOlderDelta > 0 ? "+" : "")\(biologicalAgeYellowOlderDelta)y")
                            .monospacedDigit()
                    }
                }
                Button {
                    biologicalAgeGreenOlderDelta = 0
                    biologicalAgeYellowOlderDelta = 3
                } label: {
                    Label("Reset body-age target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .purple))
            }
        case .vo2max:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $vo2GreenDelta, in: 0.0...2.0, step: 0.1) {
                    LabeledContent("Green gain") {
                        Text(String(format: "+%.1f", vo2GreenDelta))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $vo2RedDelta, in: -2.0 ... -0.05, step: 0.1) {
                    LabeledContent("Red decline") {
                        Text(String(format: "%.1f", vo2RedDelta))
                            .monospacedDigit()
                    }
                }
                Button {
                    vo2GreenDelta = 0.2
                    vo2RedDelta = -0.2
                } label: {
                    Label("Reset VO2 trend target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .blue))
            }
        case .steps, .strapSteps:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                    LabeledContent("Steps goal") {
                        Text("\(stepsGoal)")
                            .monospacedDigit()
                    }
                }
                Button {
                    stepsGoal = 8_000
                } label: {
                    Label("Reset steps goal", systemImage: "figure.walk")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .green))
            }
        case .calories:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $caloriesGoal, in: 100...3_000, step: 50) {
                    LabeledContent("Active calories goal") {
                        Text("\(caloriesGoal) kcal")
                            .monospacedDigit()
                    }
                }
                Button {
                    caloriesGoal = 500
                } label: {
                    Label("Reset calories goal", systemImage: "flame.fill")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .orange))
            }
        case .sleepEfficiency:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $sleepEfficiencyGreenLower, in: 60...99, step: 1) {
                    LabeledContent("Green starts") {
                        Text("\(Int(sleepEfficiencyGreenLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $sleepEfficiencyYellowLower, in: 50...95, step: 1) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int(sleepEfficiencyYellowLower.rounded()))%")
                            .monospacedDigit()
                    }
                }
                Button {
                    sleepEfficiencyGreenLower = 90
                    sleepEfficiencyYellowLower = 80
                } label: {
                    Label("Reset efficiency target", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .cyan))
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label("No target controls", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                Text("This Today card is an action or trend shortcut, so it uses its source state instead of a personal target zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func normalizeRecoveryTargets() {
        recoveryYellowLower = min(max(recoveryYellowLower, 5), 66)
        recoveryGreenLower = min(max(recoveryGreenLower, recoveryYellowLower + 1), 95)
    }

    private func normalizeStrainTargets() {
        strainGreenBand = min(max(strainGreenBand, 0.5), 5.0)
        strainYellowBand = min(max(strainYellowBand, strainGreenBand + 0.5), 8.0)
    }

    private func normalizeTrainingLoadTargets() {
        loadACWRBadLow = min(max(loadACWRBadLow, 0.30), 0.95)
        loadACWRWatchLow = min(max(loadACWRWatchLow, loadACWRBadLow + 0.05), 1.00)
        loadACWRWatchHigh = min(max(loadACWRWatchHigh, 1.00), 1.60)
        loadACWRBadHigh = min(max(loadACWRBadHigh, loadACWRWatchHigh + 0.05), 2.20)
        loadMonotonyWatch = min(max(loadMonotonyWatch, 1.0), 4.0)
        loadMonotonyBad = min(max(loadMonotonyBad, loadMonotonyWatch + 0.1), 5.0)
    }

    private func normalizeStepsGoal() {
        stepsGoal = min(max(stepsGoal, 1_000), 30_000)
    }

    private func normalizeCaloriesGoal() {
        caloriesGoal = min(max(caloriesGoal, 100), 3_000)
    }

    private func normalizeSleepGoal() {
        sleepGoalHours = min(max(sleepGoalHours, 4.0), 12.0)
    }

    private func normalizeSleepEfficiencyTargets() {
        sleepEfficiencyYellowLower = min(max(sleepEfficiencyYellowLower, 50), 95)
        sleepEfficiencyGreenLower = min(max(sleepEfficiencyGreenLower, sleepEfficiencyYellowLower + 1), 99)
    }

    private func normalizeHRVTargets() {
        hrvYellowRatio = min(max(hrvYellowRatio, 0.50), 0.98)
        hrvGreenRatio = min(max(hrvGreenRatio, hrvYellowRatio + 0.01), 1.20)
    }

    private func normalizeRestingTargets() {
        restingGreenDelta = min(max(restingGreenDelta, 0), 12)
        restingYellowDelta = min(max(restingYellowDelta, restingGreenDelta + 1), 20)
    }

    private func normalizeRespiratoryTargets() {
        respiratoryGreenDelta = min(max(respiratoryGreenDelta, 0.5), 4.0)
        respiratoryYellowDelta = min(max(respiratoryYellowDelta, respiratoryGreenDelta + 0.5), 8.0)
    }

    private func normalizeSkinTemperatureTargets() {
        skinTemperatureGreenDelta = min(max(skinTemperatureGreenDelta, 0.2), 2.0)
        skinTemperatureYellowDelta = min(max(skinTemperatureYellowDelta, skinTemperatureGreenDelta + 0.1), 4.0)
    }

    private func normalizeBloodOxygenTargets() {
        bloodOxygenCandidateGoal = min(max(bloodOxygenCandidateGoal, 2), 120)
    }

    private func normalizeBiologicalAgeTargets() {
        biologicalAgeGreenOlderDelta = min(max(biologicalAgeGreenOlderDelta, -10), 10)
        biologicalAgeYellowOlderDelta = min(max(biologicalAgeYellowOlderDelta, biologicalAgeGreenOlderDelta + 1), 20)
    }

    private func normalizeVO2Targets() {
        vo2GreenDelta = min(max(vo2GreenDelta, 0.0), 2.0)
        vo2RedDelta = max(min(vo2RedDelta, -0.05), -2.0)
    }
}

private extension AtriaTodayMetric {
    var targetEditorTint: Color {
        switch self {
        case .recovery, .steps, .strapSteps: return .green
        case .strain, .load, .calories: return .orange
        case .hrv, .stress: return .pink
        case .rhr: return .red
        case .bioAge: return .purple
        case .vo2max: return .blue
        case .respiratoryRate, .bodyTemp: return .teal
        case .bloodOxygen: return .blue
        case .sleep, .sleepHistory, .sleepEfficiency: return .cyan
        default: return .blue
        }
    }

    var targetEditorSummary: String {
        switch self {
        case .recovery:
            return "Adjust the green/yellow recovery thresholds used by target zones."
        case .strain:
            return "Adjust how tightly Strain should track today's recovery-scaled target."
        case .load:
            return "Adjust ACWR and monotony bands used by training-load readiness colors."
        case .sleep:
            return "Adjust the sleep duration goal used by sleep target zones."
        case .sleepHistory:
            return "Adjust the sleep goal used by sleep history, debt, and consistency."
        case .hrv:
            return "Adjust how close HRV should stay to your personal baseline."
        case .rhr:
            return "Adjust the resting-HR rise allowed above your personal baseline."
        case .respiratoryRate:
            return "Adjust the sleep respiratory-rate deviation allowed around your baseline."
        case .bodyTemp:
            return "Adjust the relative sleep skin-temperature deviation allowed around baseline."
        case .bloodOxygen:
            return "Adjust the research evidence threshold for candidate frames. This is not an SpO2 percentage target."
        case .bioAge:
            return "Adjust the younger/older delta bands for the body-age estimate."
        case .vo2max:
            return "Adjust the VO2max trend gain or decline needed for target colors."
        case .steps:
            return "Adjust the daily step goal used by the steps card."
        case .strapSteps:
            return "Adjust the daily step goal used by strap-step research while validation remains separate."
        case .calories:
            return "Adjust the estimated active-calorie goal used by the calories card."
        case .sleepEfficiency:
            return "Adjust the sleep-efficiency green/yellow target bands."
        default:
            return "Action and trend shortcuts do not use personal target zones."
        }
    }
}

private struct AtriaGlanceMetricMarker: View, Equatable {
    private static let size: CGFloat = 38
    private static let iconCircleSize: CGFloat = 26
    private static let iconSize: CGFloat = 14
    private static let ringLineWidth: CGFloat = 3

    let systemImage: String
    let tint: Color
    let progressFraction: Double?

    private var clampedProgress: Double {
        min(max(progressFraction ?? 0, 0), 1)
    }

    private var ringEnd: Double {
        progressFraction == nil ? 1 : clampedProgress
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.10))

            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: Self.ringLineWidth)

            markerRing

            Circle()
                .fill(Color(.systemBackground).opacity(0.78))
                .frame(width: Self.iconCircleSize, height: Self.iconCircleSize)
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.26), lineWidth: 1)
                }

            Image(systemName: systemImage)
                .font(.system(size: Self.iconSize, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: Self.iconCircleSize, height: Self.iconCircleSize)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var markerRing: some View {
        if progressFraction == nil {
            Circle()
                .stroke(Color.secondary.opacity(0.34),
                        style: StrokeStyle(lineWidth: Self.ringLineWidth,
                                           lineCap: .round,
                                           dash: [2.4, 6.2]))
        } else {
            Circle()
                .trim(from: 0, to: ringEnd)
                .stroke(tint,
                        style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct AtriaSleepHistoryGlanceCard: View, Equatable {
    let snapshot: SleepHistorySnapshot
    let sleepGoalHours: Double
    let onOpenVitals: () -> Void
    let onAddManualSleep: () -> Void

    static func == (lhs: AtriaSleepHistoryGlanceCard, rhs: AtriaSleepHistoryGlanceCard) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.sleepGoalHours == rhs.sleepGoalHours
    }

    private var latest: SleepHistorySnapshot.Night? {
        snapshot.latest
    }

    private var tint: Color {
        latest == nil ? .orange : .cyan
    }

    private var valueText: String {
        guard !snapshot.nights.isEmpty else {
            return snapshot.candidateCount > 0 ? "\(snapshot.candidateCount)" : "--"
        }
        return snapshot.averageDurationText
    }

    private var detailText: String {
        guard let latest else {
            if snapshot.candidateCount > 0 {
                return snapshot.candidateCount == 1 ? "Sleep/nap candidate" : "Sleep/nap candidates"
            }
            return "Wear strap overnight or nap"
        }
        return "\(latest.evidenceLabel) · debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                AtriaGlanceMetricMarker(systemImage: AtriaTodayMetric.sleepHistory.systemImage,
                                        tint: tint,
                                        progressFraction: nil)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep history")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(detailText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    onAddManualSleep()
                } label: {
                    Image(systemName: "moon.zzz.badge.plus")
                        .font(.caption.weight(.bold))
                }
                .atriaGlassIconAction(tint: .cyan, size: 32)
                .accessibilityLabel("Add sleep manually")
            }
            .frame(height: 42, alignment: .center)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(valueText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                Spacer(minLength: 0)
            }
            .frame(height: 32, alignment: .bottom)

            stageLegend

            stageStrip
        }
        .frame(maxWidth: .infinity,
               minHeight: AtriaGlanceMetricCard.cardHeight,
               maxHeight: AtriaGlanceMetricCard.cardHeight,
               alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
        .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .onTapGesture(perform: onOpenVitals)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var stageLegend: some View {
        if let latest, !latest.displayStageSegments.isEmpty {
            HStack(spacing: 5) {
                ForEach(SleepStageKind.allCases) { stage in
                    HStack(spacing: 3) {
                        Image(systemName: AtriaSleepStageGlyph.symbol(for: stage))
                            .font(.system(size: 8, weight: .bold))
                        Text(stage.shortLabel)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .allowsTightening(true)
                    }
                    .foregroundStyle(AtriaSleepStageGlyph.color(for: stage))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("\(stage.label) \(latest.stageText(stage))")
                }
            }
            .frame(height: 14, alignment: .center)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 8) {
                Text("Consistency \(snapshot.sleepConsistencyText)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
                Text("Debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(height: 14, alignment: .center)
        }
    }

    @ViewBuilder
    private var stageStrip: some View {
        if let latest, !latest.displayStageSegments.isEmpty {
            AtriaSleepMiniHypnogram(segments: latest.displayStageSegments,
                                    duration: latest.duration)
            .frame(height: 18, alignment: .center)
        } else {
            HStack(spacing: 4) {
                Text("Stages building")
                Spacer(minLength: 0)
                Text("AWAKE")
                Text("LIGHT")
                Text("REM")
                Text("SWS")
                Text("DEEP")
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.58)
            .frame(height: 18, alignment: .center)
        }
    }

    private var accessibilityText: String {
        guard let latest else {
            if snapshot.candidateCount > 0 {
                return "Sleep history has \(snapshot.candidateCount) sleep or nap candidate\(snapshot.candidateCount == 1 ? "" : "s") ready to review."
            }
            return "Sleep history building. Wear the strap overnight or during a nap."
        }
        guard !latest.displayStageSegments.isEmpty else {
            return "Sleep history \(valueText). \(latest.evidenceLabel). Consistency \(snapshot.sleepConsistencyText). Sleep debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours)). Stages building: Awake, Light, REM, SWS, and Deep are not ready yet."
        }
        return "Sleep history \(valueText). \(latest.evidenceLabel). Consistency \(snapshot.sleepConsistencyText). Sleep debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours)). Awake \(latest.stageText(.awake)), Light \(latest.stageText(.light)), REM \(latest.stageText(.rem)), SWS \(latest.stageText(.sws)), Deep \(latest.stageText(.deep))."
    }
}

private struct AtriaSleepMiniHypnogram: View, Equatable {
    let segments: [SleepStageSegment]
    let duration: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard duration > 0, !segments.isEmpty else { return }
            let laneHeight = max(4, size.height / 6)
            var elapsed: TimeInterval = 0
            for segment in segments {
                let width = max(1, size.width * segment.duration / duration)
                let x = size.width * elapsed / duration
                let y = stageY(segment.stage, height: size.height) - laneHeight / 2
                let rect = CGRect(x: x,
                                  y: y,
                                  width: min(width, max(0, size.width - x)),
                                  height: laneHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: laneHeight / 2),
                             with: .color(AtriaSleepStageGlyph.color(for: segment.stage)))
                elapsed += segment.duration
            }
        }
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func stageY(_ stage: SleepStageKind, height: CGFloat) -> CGFloat {
        switch stage {
        case .awake: return height * 0.14
        case .light: return height * 0.34
        case .rem: return height * 0.52
        case .sws: return height * 0.70
        case .deep: return height * 0.88
        }
    }
}

enum AtriaSleepStageGlyph {
    static func symbol(for stage: SleepStageKind) -> String {
        switch stage {
        case .awake: return "sun.max.fill"
        case .light: return "moon.fill"
        case .rem: return "sparkles"
        case .sws: return "waveform.path"
        case .deep: return "moon.stars.fill"
        }
    }

    static func color(for stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan
        case .rem: return .indigo
        case .sws: return .blue
        case .deep: return .purple
        }
    }
}

private extension SleepStageKind {
    var shortLabel: String {
        switch self {
        case .awake: return "AWAKE"
        case .light: return "LIGHT"
        case .rem: return "REM"
        case .sws: return "SWS"
        case .deep: return "DEEP"
        }
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
                                     value: "\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
                                     detail: stats.baselineSamples >= PersonalBaseline.trustedMinimumSamples ? "Trusted personal baseline is ready." : "Wear overnight to build a trusted recovery baseline.",
                                     systemImage: "waveform.path.ecg",
                                     tint: stats.baselineSamples >= PersonalBaseline.trustedMinimumSamples ? .green : .pink,
                                     isComplete: stats.baselineSamples >= PersonalBaseline.trustedMinimumSamples,
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
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore

    var body: some View {
        AtriaOverviewMorningJournalCard(snapshot: snapshotStore.state,
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
    let snapshot: AtriaHomeModel.Snapshot
    let sleepHistory: SleepHistorySnapshot
    let todayEntry: BehaviorJournalEntry
    let taggedDays: Int
    let onToggleTag: (BehaviorJournalEntry.Tag) -> Void
    let onConfirmSleep: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaOverviewMorningJournalCard, rhs: AtriaOverviewMorningJournalCard) -> Bool {
        lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.snapshot.sleepDetail == rhs.snapshot.sleepDetail
            && lhs.sleepHistory == rhs.sleepHistory
            && lhs.todayEntry == rhs.todayEntry
            && lhs.taggedDays == rhs.taggedDays
    }

    private var latestNight: SleepHistorySnapshot.Night? {
        sleepHistory.latest
    }

    private var shouldShowConfirmSleep: Bool {
        guard sleepHistory.candidateCount > 0 else { return false }
        return latestNight?.confirmed != true
    }

    private var sleepReviewTitle: String {
        latestNight?.evidenceLabel ?? "Sleep review"
    }

    private var sleepReviewValue: String {
        latestNight?.durationText ?? metricDisplayValue(snapshot.sleepValue)
    }

    private var sleepReviewState: AtriaMetricState {
        latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning)
    }

    private var sleepStatusText: String {
        guard let latestNight else {
            return snapshot.sleepDetail
        }

        var parts = [latestNight.durationText]
        if latestNight.sleepEfficiencyText != "--" {
            parts.append("Eff \(latestNight.sleepEfficiencyText)")
        }
        if latestNight.hrvText != "--" {
            parts.append("HRV \(latestNight.hrvText)")
        }
        if latestNight.respiratoryRateText != "--" {
            parts.append("Resp \(latestNight.respiratoryRateText)")
        }
        parts.append(latestNight.confidenceText)
        parts.append(latestNight.confirmationText)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Morning journal", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning))
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: latestNight?.isNapEvidence == true ? "bed.double.fill" : "moon.zzz.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.cyan)
                    .frame(width: 34, height: 34)
                    .background(Color.cyan.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(sleepReviewTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(sleepStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(sleepReviewValue)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    AtriaStateBadge(state: sleepReviewState)
                }
            }
            .padding(12)
            .atriaInsetCard(tint: .cyan)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(sleepReviewTitle) \(sleepReviewValue). \(sleepStatusText)")

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
                        Label(latestNight?.isNapEvidence == true ? "Confirm nap" : "Confirm sleep",
                              systemImage: "checkmark.circle")
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
/// validated local metrics. Recovery correlations stay hidden until Recovery is
/// built from real baseline-gated inputs. Local, never medical.
struct AtriaInsightsCard: View, Equatable {
    let insights: [AtriaInsight]
    let taggedDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Insights", subtitle: "What moves your HRV")

            if insights.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                    Text(taggedDays == 0
                         ? "Tag your days (sleep, alcohol, training…) and Atria learns what moves your HRV."
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
                AtriaInlineQuickStat(label: "Battery",
                                     value: live.batteryStatusSummaryText,
                                     detail: live.batteryDetailText)
                AtriaInlineQuickStat(label: "Charge",
                                     value: live.batteryChargeText,
                                     detail: live.batteryChargeStatus == .levelOnly
                                        ? "Strap battery level is live; charger state pending"
                                        : "Current strap charger status")
                AtriaInlineQuickStat(label: "Baseline", value: "\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)")
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
                        value: "\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
                        state: stats.baselineSamples >= PersonalBaseline.trustedMinimumSamples ? .validated : .learning,
                        tint: .pink)
    }
}
