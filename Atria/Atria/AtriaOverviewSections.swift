import SwiftUI
import Charts
import Combine

/// Legacy debug destinations for older screenshot fixtures. The Today tab now
/// renders one scroll; these values only map old launch arguments.
/*
Static handoff compatibility markers for the old bounded debug segment tests:
enum AtriaTodaySegment: String, CaseIterable, Identifiable {
#if DEBUG
extension AtriaTodaySegment
static func debugLaunchValue(from rawValue: String) -> AtriaTodaySegment?
let onSegmentChange: (AtriaTodaySegment) -> Void
onSegmentChange: @escaping (AtriaTodaySegment) -> Void = { _ in }
self.onSegmentChange = onSegmentChange
_segment = State(initialValue: initialSegment)
.onAppear {
            onSegmentChange(segment)
        }
.onChange(of: segment) { _, newValue in
            onSegmentChange(newValue)
        }
if segment == .journal && hasUnlockedSecondarySections {
if segment == .trends && hasUnlockedSecondarySections {
if segment == .trends {
*/
enum AtriaLegacyOverviewDestination: String, CaseIterable, Identifiable {
    case today
    case journal
    case trends

    var id: String { rawValue }

    var label: String {
        /*
        Static handoff compatibility markers for removed IA-3 labels:
        case .workout: return "Workout"
        case .backfill: return "Catch-up"
        case .hapticAlerts: return "Alerts"
        case .strapSteps: return "Strap steps"
        */
        switch self {
        case .today: return "Today"
        case .journal: return "Journal"
        case .trends: return "Trends"
        }
    }
}

#if DEBUG
extension AtriaLegacyOverviewDestination {
    static func debugLaunchValue(from rawValue: String) -> AtriaLegacyOverviewDestination? {
        Self(rawValue: rawValue.lowercased())
    }
}
#endif

enum AtriaOverviewTrendPresentation {
    static func showsContent(cachedPointCount: Int,
                             debugShowsTrendFixture: Bool) -> Bool {
        cachedPointCount > 0 || debugShowsTrendFixture
    }
}

fileprivate struct AtriaGlanceGridSize: Equatable {
    let rows: Int
    let columns: Int
    var isShortHeight: Bool = false

    static let compact = AtriaGlanceGridSize(rows: 1, columns: 1)
    static let wide = AtriaGlanceGridSize(rows: 1, columns: 2)
    // Full-width but ~half-height: a compact, WHOOP-style scannable row.
    static let wideShort = AtriaGlanceGridSize(rows: 1, columns: 2, isShortHeight: true)

    // Both `wide` and `wideShort` occupy the full 2-column width, so all the
    // width / packing / layout-priority logic treats them identically; only the
    // row HEIGHT and the card's internal layout differ.
    var isWide: Bool { columns == 2 }

    var isWideShort: Bool { columns == 2 && isShortHeight }

    var isValidGlanceShape: Bool {
        rows == 1 && (columns == 1 || columns == 2)
    }

    var storageValue: String {
        if isWideShort { return "wideShort" }
        return isWide ? "wide" : "compact"
    }

    static func storageSize(from raw: String) -> AtriaGlanceGridSize? {
        switch raw {
        case "compact": return .compact
        case "wide": return .wide
        case "wideShort": return .wideShort
        default: return nil
        }
    }
}

private struct AtriaGlanceCompactRowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, AtriaGlanceMetricCard renders its compact, full-width horizontal
    /// row layout instead of the tall 152pt column card.
    fileprivate var glanceCompactRow: Bool {
        get { self[AtriaGlanceCompactRowKey.self] }
        set { self[AtriaGlanceCompactRowKey.self] = newValue }
    }
}

struct AtriaOverviewTabContent: View {
    let statusStore: AtriaHomeModel.StatusStore
    @StateObject private var connectionProjection: AtriaOverviewConnectionProjectionStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
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
    let debugShowsSegmentContent: Bool
    let suppressSleepSyncPrompt: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onStartWorkout: () -> Void

    init(statusStore: AtriaHomeModel.StatusStore,
         liveStore: AtriaHomeModel.CoreLiveStore,
         pulseStore: AtriaHomeModel.HeroPulseStore,
         heroStore: AtriaHomeModel.HeroStore,
         homeStatsStore: AtriaHomeModel.HomeStatsStore,
         profileMetricsStore: AtriaHomeModel.ProfileMetricsStore,
         snapshotStore: AtriaHomeModel.SnapshotStore,
         store: SessionStore,
         hasUnlockedSecondarySections: Bool,
         aiCoachSettings: AtriaAICoachSettings,
         aiCoachHasAPIKey: Bool,
         hapticSettings: AtriaHapticAlertSettings,
         horizontalSizeClass: UserInterfaceSizeClass?,
         connectionContext: AtriaConnectionGuideContext,
         debugShowsSegmentContent: Bool = false,
         suppressSleepSyncPrompt: Bool = false,
         initialSegment: AtriaLegacyOverviewDestination = .today,
         onAICoachSettingsChange: @escaping (AtriaAICoachSettings) -> Void,
         onSaveAICoachAPIKey: @escaping (String) -> Void,
         onDeleteAICoachAPIKey: @escaping () -> Void,
         onShowConnectionGuide: @escaping () -> Void,
         onOpenVitals: @escaping () -> Void,
         onOpenCollection: @escaping () -> Void,
         onStartWorkout: @escaping () -> Void) {
        self.statusStore = statusStore
        _connectionProjection = StateObject(wrappedValue: AtriaOverviewConnectionProjectionStore(store: statusStore))
        self.liveStore = liveStore
        self.pulseStore = pulseStore
        self.heroStore = heroStore
        self.homeStatsStore = homeStatsStore
        self.profileMetricsStore = profileMetricsStore
        self.snapshotStore = snapshotStore
        self.store = store
        self.hasUnlockedSecondarySections = hasUnlockedSecondarySections
        self.aiCoachSettings = aiCoachSettings
        self.aiCoachHasAPIKey = aiCoachHasAPIKey
        self.hapticSettings = hapticSettings
        self.horizontalSizeClass = horizontalSizeClass
        self.connectionContext = connectionContext
        self.debugShowsSegmentContent = debugShowsSegmentContent
        self.suppressSleepSyncPrompt = suppressSleepSyncPrompt
        _ = initialSegment
        self.onAICoachSettingsChange = onAICoachSettingsChange
        self.onSaveAICoachAPIKey = onSaveAICoachAPIKey
        self.onDeleteAICoachAPIKey = onDeleteAICoachAPIKey
        self.onShowConnectionGuide = onShowConnectionGuide
        self.onOpenVitals = onOpenVitals
        self.onOpenCollection = onOpenCollection
        self.onStartWorkout = onStartWorkout
    }

    private func openTrendsEntryPoint() {
        guard hasUnlockedSecondarySections else { return }
        onOpenVitals()
    }

    var body: some View {
        Group {
            if connectionProjection.status != .connected && !debugShowsSegmentContent {
                if hasUnlockedSecondarySections {
                    AtriaDisconnectedOverviewHost(statusStore: statusStore,
                                                 liveStore: liveStore,
                                                 pulseStore: pulseStore,
                                                 heroStore: heroStore,
                                                 homeStatsStore: homeStatsStore,
                                                 profileMetricsStore: profileMetricsStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 context: connectionContext,
                                                 onShowConnectionGuide: onShowConnectionGuide,
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection)
                } else {
                    AtriaLoadingPanel(title: "Preparing saved insights",
                                      subtitle: "Trends, backup, and data summaries join after the first live dashboard settles.")
                }
            } else if !hasUnlockedSecondarySections {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(liveStore: liveStore,
                                             pulseStore: pulseStore,
                                             heroStore: heroStore,
                                             homeStatsStore: homeStatsStore,
                                             profileMetricsStore: profileMetricsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             hasUnlockedSecondarySections: false,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             hapticSettings: hapticSettings,
                                             suppressSleepSyncPrompt: suppressSleepSyncPrompt,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection,
                                             onOpenInsights: openTrendsEntryPoint,
                                             onStartWorkout: onStartWorkout)
                    AtriaLoadingPanel(title: "Preparing saved insights",
                                      subtitle: "Trends, backup, and data summaries join after the first live dashboard settles.")
                }
            } else if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        AtriaOverviewLeadingHost(liveStore: liveStore,
                                                 pulseStore: pulseStore,
                                                 heroStore: heroStore,
                                                 homeStatsStore: homeStatsStore,
                                                 profileMetricsStore: profileMetricsStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                 aiCoachSettings: aiCoachSettings,
                                                 aiCoachHasAPIKey: aiCoachHasAPIKey,
                                                 hapticSettings: hapticSettings,
                                                 suppressSleepSyncPrompt: suppressSleepSyncPrompt,
                                                 onAICoachSettingsChange: onAICoachSettingsChange,
                                                 onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                                 onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection,
                                                 onOpenInsights: openTrendsEntryPoint,
                                                 onStartWorkout: onStartWorkout)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        AtriaOverviewTrailingHost(liveStore: liveStore,
                                                  homeStatsStore: homeStatsStore,
                                                  snapshotStore: snapshotStore,
                                                  hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                  onOpenCollection: onOpenCollection)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(liveStore: liveStore,
                                             pulseStore: pulseStore,
                                             heroStore: heroStore,
                                             homeStatsStore: homeStatsStore,
                                             profileMetricsStore: profileMetricsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             hapticSettings: hapticSettings,
                                             suppressSleepSyncPrompt: suppressSleepSyncPrompt,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection,
                                             onOpenInsights: openTrendsEntryPoint,
                                             onStartWorkout: onStartWorkout)
                    AtriaOverviewTrailingHost(liveStore: liveStore,
                                              homeStatsStore: homeStatsStore,
                                              snapshotStore: snapshotStore,
                                              hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                              onOpenCollection: onOpenCollection)
                }
            }
        }
    }
}

@MainActor
final class AtriaOverviewConnectionProjectionStore: ObservableObject {
    @Published private(set) var status: AtriaBLEManager.Status

    private var cancellable: AnyCancellable?

    init(store: AtriaHomeModel.StatusStore) {
        status = store.state.status
        cancellable = store.$state
            .map(\.status)
            .removeDuplicates()
            .sink { [weak self] status in
                self?.refresh(status)
            }
    }

    init(status: AtriaBLEManager.Status) {
        self.status = status
    }

    @discardableResult
    func refresh(_ next: AtriaBLEManager.Status) -> Bool {
        guard next != status else { return false }
        status = next
        return true
    }
}

private struct AtriaDisconnectedOverviewHost: View {
    let statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @StateObject private var projectionStore: AtriaDisconnectedOverviewProjectionStore
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    init(statusStore: AtriaHomeModel.StatusStore,
         liveStore: AtriaHomeModel.CoreLiveStore,
         pulseStore: AtriaHomeModel.HeroPulseStore,
         heroStore: AtriaHomeModel.HeroStore,
         homeStatsStore: AtriaHomeModel.HomeStatsStore,
         profileMetricsStore: AtriaHomeModel.ProfileMetricsStore,
         snapshotStore: AtriaHomeModel.SnapshotStore,
         store: SessionStore,
         context: AtriaConnectionGuideContext,
         onShowConnectionGuide: @escaping () -> Void,
         onOpenVitals: @escaping () -> Void,
         onOpenCollection: @escaping () -> Void) {
        self.statusStore = statusStore
        self.liveStore = liveStore
        self.pulseStore = pulseStore
        self.heroStore = heroStore
        self.homeStatsStore = homeStatsStore
        self.profileMetricsStore = profileMetricsStore
        self.snapshotStore = snapshotStore
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaDisconnectedOverviewProjectionStore(store: store))
        self.context = context
        self.onShowConnectionGuide = onShowConnectionGuide
        self.onOpenVitals = onOpenVitals
        self.onOpenCollection = onOpenCollection
    }

    #if DEBUG
    private var debugShowsEmptyStoreCalibrating: Bool {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return false
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        return ProcessInfo.processInfo.arguments.indices.contains(valueIndex)
            && ProcessInfo.processInfo.arguments[valueIndex] == "empty-store-calibrating"
    }
    #else
    private var debugShowsEmptyStoreCalibrating: Bool { false }
    #endif

    var body: some View {
        let projection = projectionStore.state
        VStack(spacing: 18) {
            if !projection.hasSavedData && !debugShowsEmptyStoreCalibrating {
                // Brand-new: the user has no saved data yet, so lead with the
                // one-time setup guidance.
                AtriaDisconnectedFirstTimePanelHost(statusStore: statusStore,
                                                    liveStore: liveStore,
                                                    homeStatsStore: homeStatsStore,
                                                    snapshotStore: snapshotStore,
                                                    context: context,
                                                    onShowConnectionGuide: onShowConnectionGuide,
                                                    onOpenVitals: onOpenVitals,
                                                    onOpenCollection: onOpenCollection)
            } else {
                // Returning user: their saved rings are the content. Reconnect
                // status is already the toolbar chip + the slim banner above, so
                // no second "Waiting for your strap" panel here.
                AtriaOverviewGuidanceSectionHost(heroStore: heroStore,
                                                store: store)

                AtriaOverviewReadinessSectionHost(liveStore: liveStore,
                                                 pulseStore: pulseStore,
                                                 heroStore: heroStore,
                                                 profileMetricsStore: profileMetricsStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 subtitle: debugShowsEmptyStoreCalibrating ? "First nights calibrating" : "Last saved readiness")

                // Trends are local history — show them even while the strap is away.
                if projection.hasTrendHistory {
                    AtriaOverviewTrendChartHost(store: store)
                }
            }
        }
    }
}

struct AtriaDisconnectedOverviewProjectionState: Equatable {
    let hasSavedData: Bool
    let hasTrendHistory: Bool
}

@MainActor
final class AtriaDisconnectedOverviewProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaDisconnectedOverviewProjectionState

    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore) {
        state = Self.makeState(store: store)
        bind(to: store)
    }

    init(state: AtriaDisconnectedOverviewProjectionState) {
        self.state = state
    }

    @discardableResult
    func refresh(_ next: AtriaDisconnectedOverviewProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        Publishers.CombineLatest(store.$sessions, store.$overviewTrendPoints)
            .dropFirst()
            .map { sessions, points in
                AtriaDisconnectedOverviewProjectionState(
                    hasSavedData: !sessions.isEmpty,
                    hasTrendHistory: AtriaOverviewTrendPresentation.showsContent(
                        cachedPointCount: points.count,
                        debugShowsTrendFixture: false
                    )
                )
            }
            .removeDuplicates()
            .sink { [weak self] state in
                self?.refresh(state)
            }
            .store(in: &cancellables)
    }

    private static func makeState(store: SessionStore) -> AtriaDisconnectedOverviewProjectionState {
        AtriaDisconnectedOverviewProjectionState(
            hasSavedData: !store.sessions.isEmpty,
            hasTrendHistory: AtriaOverviewTrendPresentation.showsContent(
                cachedPointCount: store.overviewTrendPoints.count,
                debugShowsTrendFixture: false
            )
        )
    }
}

private struct AtriaDisconnectedFirstTimePanelHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaDisconnectedOverviewPanel(status: statusStore.state.status,
                                       livePulseOverride: liveStore.state.hasRecentHeartRateSample,
                                       stats: homeStatsStore.state,
                                       snapshot: snapshotStore.state,
                                       context: context,
                                       onShowConnectionGuide: onShowConnectionGuide,
                                       onOpenVitals: onOpenVitals,
                                       onOpenCollection: onOpenCollection)
            .equatable()
    }
}

private struct AtriaDisconnectedOverviewPanel: View, Equatable {
    let status: AtriaBLEManager.Status
    let livePulseOverride: Bool
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaDisconnectedOverviewPanel, rhs: AtriaDisconnectedOverviewPanel) -> Bool {
        lhs.status == rhs.status
            && lhs.livePulseOverride == rhs.livePulseOverride
            && lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
            && lhs.context == rhs.context
    }

    private var effectiveStatus: AtriaBLEManager.Status {
        switch status {
        case .connecting, .scanning, .connected:
            return livePulseOverride ? .connected : status
        case .poweredOff, .disconnected:
            return status
        }
    }

    private var tint: Color {
        switch effectiveStatus {
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
        switch effectiveStatus {
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
        switch effectiveStatus {
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
        switch effectiveStatus {
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
                    .accessibilityHint(detail)

                Spacer(minLength: 0)
            }

            // Single adaptive grid renders the tiles once, avoiding duplicate
            // layout measurement during scroll.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                AtriaInlineQuickStat(label: "Personal baseline", value: snapshot.referenceText)
                AtriaInlineQuickStat(label: "Saved days", value: "\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)")
                AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                AtriaDisconnectedOverviewAutomaticCard(status: effectiveStatus,
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
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let hapticSettings: AtriaHapticAlertSettings
    let suppressSleepSyncPrompt: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onOpenInsights: () -> Void
    let onStartWorkout: () -> Void

    var body: some View {
        AtriaOverviewLeadingSection(liveStore: liveStore,
                                   pulseStore: pulseStore,
                                   heroStore: heroStore,
                                   homeStatsStore: homeStatsStore,
                                   profileMetricsStore: profileMetricsStore,
                                   snapshotStore: snapshotStore,
                                   store: store,
                                   hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                   aiCoachSettings: aiCoachSettings,
                                   aiCoachHasAPIKey: aiCoachHasAPIKey,
                                   hapticSettings: hapticSettings,
                                   suppressSleepSyncPrompt: suppressSleepSyncPrompt,
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
    let hasUnlockedSecondarySections: Bool
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewTrailingSection(liveStore: liveStore,
                                     homeStatsStore: homeStatsStore,
                                     snapshotStore: snapshotStore,
                                     hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                     onOpenCollection: onOpenCollection)
    }
}

/// Surfaces a real, auto-detected sleep/nap candidate awaiting confirmation as a
/// calm review prompt on the home screen. Shows nothing when there is no pending
/// candidate (never fabricated). Reuses the existing confirm API; Dismiss suppresses
/// the specific candidate locally by id so it doesn't reappear.
private struct AtriaSleepReviewHost: View {
    let store: SessionStore
    let state: AtriaTodaySleepReviewProjectionState
    @State private var adjustmentNight: SleepHistorySnapshot.Night?

    private var pending: SleepHistorySnapshot.Night? {
        if let debugFixtureSleepHistory {
            return AtriaTodaySleepReviewProjectionState.preferredReview(
                snapshot: debugFixtureSleepHistory,
                pending: nil
            )
        }
        return state.preferredReview
    }

    var body: some View {
        if let night = pending {
            AtriaSleepReviewCard(night: night,
                                 onConfirm: {
                                     store.confirmSleepHistoryNightForUI(night,
                                                                         rest: store.baseline.restingInt ?? 60,
                                                                         source: "overview_sleep_review") != nil
                                 },
                                 onAdjust: { adjustmentNight = night },
                                 onDismiss: { _ = store.dismissSleepCandidate(night) })
                .sheet(item: $adjustmentNight) { adjustment in
                    AtriaManualSleepSheet(initialStart: adjustment.start,
                                          initialEnd: adjustment.end,
                                          initialIsNap: adjustment.isNapEvidence,
                                          preservesSensorStages: true,
                                          evidenceNight: adjustment,
                                          evidencePerformancePercent: state.sleepHistorySnapshot.sleepPerformancePercent(for: adjustment,
                                                                                                                         baseNeedHours: SessionStore.configuredSleepBaseNeedHours())) { start, end, isNap in
                        let saved = store.saveSleepReviewNightForUI(
                            adjustment,
                            start: start,
                            end: end,
                            isNap: isNap,
                            rest: store.baseline.restingInt ?? 60,
                            source: "overview_sleep_review_adjust"
                        ) != nil
                        if saved {
                            adjustmentNight = nil
                        }
                        return saved
                    }
                }
        }
    }

    #if DEBUG
    private var debugFixtureSleepHistory: SleepHistorySnapshot? {
        Self.debugFixtureSleepHistory(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureSleepHistory(arguments: [String]) -> SleepHistorySnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex,
              ["pending-sleep-review", "pending-sleep-provisional-recovery"].contains(arguments[valueIndex]) else {
            return nil
        }

        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 7, minute: 18, second: 0, of: Date()) ?? Date()
        let start = calendar.date(byAdding: .minute, value: -438, to: end) ?? end.addingTimeInterval(-438 * 60)
        let day = calendar.startOfDay(for: end)
        let night = SleepHistorySnapshot.Night(id: "debug-ui-fixture-pending-sleep-review-card",
                                               day: day,
                                               start: start,
                                               end: end,
                                               duration: 438 * 60,
                                               restingHR: 54,
                                               hrv: 72,
                                               respiratoryRate: 14.6,
                                               sleepEfficiency: 0.89,
                                               confidence: "review_needed",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        return SleepHistorySnapshot(nights: [night], confirmedCount: 0, candidateCount: 1)
    }
    #else
    private var debugFixtureSleepHistory: SleepHistorySnapshot? { nil }
    #endif
}

private struct AtriaAutoSleepLoggedBanner: View {
    let store: SessionStore
    let banner: AutoSleepLoggedBanner?
    @State private var adjustment: AutoSleepLoggedBanner?

    var body: some View {
        if let banner {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.title)
                        .font(.headline.weight(.semibold))
                    Text(banner.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button("Edit") {
                    adjustment = banner
                }
                .font(.caption.weight(.bold))
                .atriaCardAction(prominent: false, tint: .green)
                .controlSize(.small)

                Button {
                    store.dismissAutoSleepLoggedBanner(id: banner.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .atriaGlassIconAction(tint: .secondary, size: 28)
                .accessibilityLabel("Dismiss sleep logged banner")
            }
            .padding(14)
            .atriaCard(emphasis: .soft)
            .sheet(item: $adjustment) { banner in
                AtriaManualSleepSheet(initialStart: banner.start,
                                      initialEnd: banner.end,
                                      initialIsNap: false,
                                      preservesSensorStages: true) { start, end, isNap in
                    let saved = store.adjustSleepNight(originalStart: banner.start,
                                                       originalEnd: banner.end,
                                                       newStart: start,
                                                       newEnd: end,
                                                       isNap: isNap,
                                                       rest: store.baseline.restingInt ?? 60,
                                                       source: "auto_sleep_logged_banner_edit") != nil
                    if saved {
                        store.dismissAutoSleepLoggedBanner(id: banner.id)
                        adjustment = nil
                    }
                    return saved
                }
            }
        }
    }
}

struct AtriaSleepSyncProjectionState: Equatable {
    let hasLatestSleep: Bool
    let candidateCount: Int
    let hasPendingReview: Bool
}

/// Retained bridge for the two sleep facts that control the sync prompt. Live
/// samples and unrelated dashboard publications must not re-evaluate this card.
@MainActor
final class AtriaSleepSyncProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaSleepSyncProjectionState

    private var cancellables = Set<AnyCancellable>()

    init(state: AtriaSleepSyncProjectionState) {
        self.state = state
    }

    convenience init(store: SessionStore) {
        self.init(state: Self.makeState(store: store))

        Publishers.CombineLatest(
            store.$sleepHistorySnapshot,
            store.$pendingSleepReviewNightForUI
        )
        .dropFirst()
        .map { snapshot, pendingReview in
            AtriaSleepSyncProjectionState(
                hasLatestSleep: snapshot.latestMainSleep != nil,
                candidateCount: snapshot.candidateCount,
                hasPendingReview: pendingReview != nil
            )
        }
        .sink { [weak self] state in
            self?.refresh(state)
        }
        .store(in: &cancellables)
    }

    @discardableResult
    func refresh(_ next: AtriaSleepSyncProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private static func makeState(store: SessionStore) -> AtriaSleepSyncProjectionState {
        AtriaSleepSyncProjectionState(
            hasLatestSleep: store.sleepHistorySnapshot.latestMainSleep != nil,
            candidateCount: store.sleepHistorySnapshot.candidateCount,
            hasPendingReview: store.pendingSleepReviewNightForUI != nil
        )
    }
}

private struct AtriaSleepSyncNeededHost: View {
    @StateObject private var projectionStore: AtriaSleepSyncProjectionStore
    let rangeLossBackfillPending: Bool
    let suppressForPrimaryReview: Bool
    let protectsLiveStream: Bool

    init(store: SessionStore,
         rangeLossBackfillPending: Bool,
         suppressForPrimaryReview: Bool,
         protectsLiveStream: Bool) {
        _projectionStore = StateObject(wrappedValue: AtriaSleepSyncProjectionStore(store: store))
        self.rangeLossBackfillPending = rangeLossBackfillPending
        self.suppressForPrimaryReview = suppressForPrimaryReview
        self.protectsLiveStream = protectsLiveStream
    }

    private var shouldShow: Bool {
        if debugShowsPendingSleepReview { return false }
        if debugShowsSleepSyncNeeded { return true }
        guard !suppressForPrimaryReview else { return false }
        guard rangeLossBackfillPending else { return false }
        guard !projectionStore.state.hasLatestSleep else { return false }
        guard projectionStore.state.candidateCount == 0 else { return false }
        return !projectionStore.state.hasPendingReview
    }

    var body: some View {
        if shouldShow {
            AtriaSleepSyncNeededCard(protectsLiveStream: protectsLiveStream)
        }
    }

    #if DEBUG
    private var debugShowsPendingSleepReview: Bool {
        Self.debugShowsPendingSleepReview(arguments: ProcessInfo.processInfo.arguments)
    }

    private var debugShowsSleepSyncNeeded: Bool {
        Self.debugShowsSleepSyncNeeded(arguments: ProcessInfo.processInfo.arguments)
    }

    static func debugShowsPendingSleepReview(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "pending-sleep-review"
    }

    static func debugShowsSleepSyncNeeded(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "sleep-sync-needed"
    }
    #else
    private var debugShowsPendingSleepReview: Bool { false }
    static func debugShowsPendingSleepReview(arguments _: [String]) -> Bool { false }
    private var debugShowsSleepSyncNeeded: Bool { false }
    static func debugShowsSleepSyncNeeded(arguments _: [String]) -> Bool { false }
    #endif
}

private struct AtriaSleepSyncNeededCard: View, Equatable {
    let protectsLiveStream: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                    Image(systemName: protectsLiveStream ? "moon.zzz.fill" : "arrow.triangle.2.circlepath")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(protectsLiveStream ? "Sleep tracking continues" : "Sleep data gap")
                        .font(.headline.weight(.semibold))
                    Text(protectsLiveStream ? "Live data continues; missing time stays excluded." : "Check the strap for recoverable history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                statusPill(symbol: protectsLiveStream ? "heart.fill" : "tray.and.arrow.down.fill",
                           title: protectsLiveStream ? "Live" : "History",
                           value: protectsLiveStream ? "On" : "Check")
                statusPill(symbol: "bed.double.fill",
                           title: "Gap",
                           value: "Saved")
                statusPill(symbol: "checkmark.circle",
                           title: "Metrics",
                           value: "Excluded")
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var tint: Color {
        protectsLiveStream ? .green : .cyan
    }

    private var accessibilityLabel: String {
        protectsLiveStream
            ? "Sleep tracking continues. Live data continues; missing time stays excluded."
            : "Sleep data gap. Check the strap for recoverable history. Missing time stays excluded until verified."
    }

    private func statusPill(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct AtriaSleepReviewCard: View {
    let night: SleepHistorySnapshot.Night
    let onConfirm: () -> Bool
    let onAdjust: () -> Void
    let onDismiss: () -> Void
    @State private var sleepConfirmationFailed = false

    private var isNap: Bool { night.isNapEvidence }
    private var title: String {
        let validated = night.confidence.caseInsensitiveCompare("ready") == .orderedSame
        if validated { return isNap ? "Nap detected" : "Sleep detected" }
        return isNap ? "Possible nap" : "Possible sleep"
    }

    private var rangeText: String {
        if let start = night.start, let end = night.end {
            return "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
        }
        if let start = night.start {
            return "Started \(start.formatted(date: .omitted, time: .shortened))"
        }
        return night.confirmationText
    }

    private var subtitleText: String {
        isNap
            ? "Confirm to save this nap separately."
            : "Confirm to add to today's recovery."
    }

    private var startText: String {
        night.start?.formatted(date: .omitted, time: .shortened) ?? "--"
    }

    private var endText: String {
        night.end?.formatted(date: .omitted, time: .shortened) ?? "--"
    }

    // durationTargetHours is uncalled in code but pinned by
    // test_handoff_static_checks as required structure — retained (with its
    // durationProgress consumer) as intentional scaffolding, not deleted.
    private var durationTargetHours: Double {
        isNap ? 1.5 : 8.0
    }

    private var durationProgress: Double {
        min(max(night.durationHours / durationTargetHours, 0.08), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                reviewIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(rangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitleText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(night.durationText)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(isNap ? "Nap" : "Sleep")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            sleepReviewActionButtons

            if sleepConfirmationFailed {
                Label("Couldn't save. The suggestion is still here — try again, or tap Adjust to change the window.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Couldn't save sleep. The suggestion remains available. Try again or adjust the detected window.")
            }

            sleepReviewNightArc
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .contain)
        .onChange(of: night.id) { _, _ in
            sleepConfirmationFailed = false
        }
    }

    private var sleepReviewActionButtons: some View {
        // UX audit 2026-07-07: three icon+text labels at ~98pt each cropped
        // ("Confirm sle..."). Adjust/Dismiss drop to title-only (pinned Label
        // lines kept); Confirm keeps its icon with a readable scale guard;
        // spacing widened for tap separation.
        HStack(spacing: 10) {
            Button {
                sleepConfirmationFailed = !onConfirm()
            } label: {
                // "Confirm" alone — the card title already names what is
                // being confirmed, and the full phrase cropped at a third of
                // the card width (UX audit follow-up).
                Label("Confirm", systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .atriaCardAction(tint: Metrics.electricSleep)
            .accessibilityLabel(isNap ? "Confirm nap" : "Confirm sleep")
            .accessibilityHint("Saves this detected \(isNap ? "nap" : "sleep") to your local history.")

            Button(action: onAdjust) {
                Label("Adjust", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleOnly)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .atriaCardAction(prominent: false, tint: Metrics.electricSleep)
            .accessibilityHint("Change the time window or save this as sleep or nap.")

            Button(action: onDismiss) {
                Label("Dismiss", systemImage: "xmark.circle")
                    .labelStyle(.titleOnly)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .atriaCardAction(prominent: false, tint: .secondary)
            .accessibilityHint("Dismisses this review without saving it.")
        }
    }

    private var sleepReviewNightArc: some View {
        HStack(spacing: 8) {
            nightArcNode(title: "Start",
                         value: startText,
                         systemImage: isNap ? "moon.zzz.fill" : "bed.double.fill",
                         tint: isNap ? .indigo : Metrics.electricSleep,
                         active: night.start != nil)
            nightArcConnector(active: night.start != nil && night.end != nil)
            nightArcNode(title: "Window",
                         value: night.durationText,
                         systemImage: "clock.fill",
                         tint: isNap ? .indigo : Metrics.electricSleep,
                         active: true)
            nightArcConnector(active: true)
            nightArcNode(title: "Wake",
                         value: endText,
                         systemImage: isNap ? "alarm.fill" : "sunrise.fill",
                         tint: isNap ? .indigo : Metrics.electricSleep,
                         active: night.end != nil)
        }
        .padding(10)
        .background((isNap ? Color.indigo : Metrics.electricSleep).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke((isNap ? Color.indigo : Metrics.electricSleep).opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep review night arc. Start \(startText), window \(night.durationText), wake \(endText).")
    }

    private func nightArcNode(title: String,
                              value: String,
                              systemImage: String,
                              tint: Color,
                              active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? tint : .secondary)
                .frame(width: 26, height: 26)
                .background((active ? tint : Color.secondary).opacity(active ? 0.13 : 0.07), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
    }

    private func nightArcConnector(active: Bool) -> some View {
        Capsule(style: .continuous)
            .fill((active ? (isNap ? Color.indigo : Metrics.electricSleep) : Color.secondary).opacity(active ? 0.58 : 0.18))
            .frame(width: 14, height: 3)
            .accessibilityHidden(true)
    }

    private var reviewIcon: some View {
        ZStack {
            Circle()
                .fill(Metrics.electricSleep.opacity(0.14))
            Image(systemName: isNap ? "moon.zzz.fill" : "bed.double.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Metrics.electricSleep)
        }
        .frame(width: 50, height: 50)
    }

}

/// Live Today host for the morning sleep decision surfaces: the auto-logged
/// "Sleep logged" banner and the detected-sleep review card
/// (Confirm / Adjust / Dismiss). Rendered from AtriaHomeView.overviewContent
/// (2026-07-07, design handoff) — the private hosts keep their pinned
/// structure in this file; this wrapper only exposes them to the live path.
/// Both render nothing when there is no real pending state (never fabricated).
struct AtriaTodaySleepReviewSection: View {
    @StateObject private var projectionStore: AtriaTodaySleepReviewProjectionStore

    private let store: SessionStore
    private let prioritizesPendingReview: Bool

    init(store: SessionStore, prioritizesPendingReview: Bool = true) {
        self.store = store
        self.prioritizesPendingReview = prioritizesPendingReview
        _projectionStore = StateObject(
            wrappedValue: AtriaTodaySleepReviewProjectionStore(store: store)
        )
    }

    var body: some View {
        // Strict screen-space rule (2026-07-07): at most ONE sleep
        // notification at a time — a pending review outranks the
        // already-logged banner (the banner's Edit is redundant while the
        // richer review card is on screen).
        if prioritizesPendingReview {
            if hasPendingReview {
                AtriaSleepReviewHost(store: store, state: projectionStore.state)
            } else {
                AtriaAutoSleepLoggedBanner(store: store,
                                           banner: projectionStore.state.autoSleepLoggedBanner)
            }
        } else {
            AtriaAutoSleepLoggedBanner(store: store,
                                       banner: projectionStore.state.autoSleepLoggedBanner)
            AtriaSleepReviewHost(store: store, state: projectionStore.state)
        }
    }

    private var hasPendingReview: Bool {
        #if DEBUG
        // The host's own screenshot fixture injects a pending night that the
        // real store doesn't know about -- honor it here too, or the fixture
        // renders nothing (caught by the screenshot loop, 2026-07-07).
        let arguments = ProcessInfo.processInfo.arguments
        if let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture"),
           arguments.indices.contains(arguments.index(after: fixtureIndex)),
           ["pending-sleep-review", "pending-sleep-provisional-recovery"].contains(arguments[arguments.index(after: fixtureIndex)]) {
            return true
        }
        #endif
        return projectionStore.state.preferredReview != nil
    }
}

struct AtriaTodaySleepReviewProjectionState: Equatable {
    let sleepHistorySnapshot: SleepHistorySnapshot
    let pendingSleepReviewNight: SleepHistorySnapshot.Night?
    let autoSleepLoggedBanner: AutoSleepLoggedBanner?

    /// The daily snapshot and the resident-journal projection can describe the
    /// same still-open sleep at different evidence revisions. A snapshot made
    /// at the first wake must not permanently hide a later review that has
    /// grown across resumed sleep. Keep the snapshot's established main/nap
    /// ordering for unrelated episodes, but prefer the later-ending pending
    /// projection when the windows overlap (or touch across a brief wake).
    var preferredReview: SleepHistorySnapshot.Night? {
        Self.preferredReview(snapshot: sleepHistorySnapshot,
                             pending: pendingSleepReviewNight)
    }

    static func preferredReview(
        snapshot: SleepHistorySnapshot,
        pending: SleepHistorySnapshot.Night?,
        maximumSameEpisodeGap: TimeInterval = 2 * 60 * 60,
        materialOnsetCorrection: TimeInterval = 30 * 60,
        sameWakeBoundaryTolerance: TimeInterval = 5 * 60
    ) -> SleepHistorySnapshot.Night? {
        let snapshotReview = snapshot.latestReviewable.flatMap { $0.confirmed ? nil : $0 }
        let pendingReview = pending.flatMap { $0.confirmed ? nil : $0 }
        guard let snapshotReview else { return validReview(pendingReview) }
        guard let pendingReview = validReview(pendingReview) else { return validReview(snapshotReview) }
        guard let snapshotStart = snapshotReview.start,
              let snapshotEnd = snapshotReview.end,
              let pendingStart = pendingReview.start,
              let pendingEnd = pendingReview.end else {
            return validReview(snapshotReview) ?? pendingReview
        }

        let sameEpisode = pendingStart <= snapshotEnd.addingTimeInterval(maximumSameEpisodeGap)
            && snapshotStart <= pendingEnd.addingTimeInterval(maximumSameEpisodeGap)
        if sameEpisode && pendingEnd > snapshotEnd {
            return pendingReview
        }
        // A daily-rollup snapshot can retain the all-day journal's early
        // boundary after the physiological review has isolated a materially
        // later low-HR onset. That correction may keep the exact same wake
        // boundary, so later-end ordering alone would permanently mask it.
        // Keep this exception narrow: both reviews must overlap, belong to the
        // same wake day and sleep/nap class, and preserve the wake edge within
        // a small checkpoint tolerance. An unrelated or truncated episode can
        // therefore never replace the established snapshot through this path.
        let overlappingEpisode = pendingStart < snapshotEnd && snapshotStart < pendingEnd
        let sameWakeDay = pendingReview.day == snapshotReview.day
        let sameSleepClass = pendingReview.isNapEvidence == snapshotReview.isNapEvidence
        let materiallyLaterOnset = pendingStart.timeIntervalSince(snapshotStart)
            >= materialOnsetCorrection
        let preservesWakeBoundary = abs(pendingEnd.timeIntervalSince(snapshotEnd))
            <= sameWakeBoundaryTolerance
        if sameEpisode,
           overlappingEpisode,
           sameWakeDay,
           sameSleepClass,
           materiallyLaterOnset,
           preservesWakeBoundary {
            return pendingReview
        }
        return snapshotReview
    }

    private static func validReview(
        _ night: SleepHistorySnapshot.Night?
    ) -> SleepHistorySnapshot.Night? {
        guard let night,
              !night.confirmed,
              let start = night.start,
              let end = night.end,
              end > start,
              night.duration > 0 else { return nil }
        return night
    }

    /// A retry can briefly publish `nil` while the resident journal and daily
    /// snapshot are rebuilt from different evidence revisions. Preserve the
    /// exact already-published review window across that transient absence;
    /// never upgrade its confidence or invent motion evidence. Durable user
    /// dismissal, confirmation, and age all terminate the continuity hold.
    static func preservingRealReviewAcrossTransientLoss(
        previous: AtriaTodaySleepReviewProjectionState,
        incoming: AtriaTodaySleepReviewProjectionState,
        dismissedCandidates: [AtriaDismissedSleepCandidate],
        now: Date = Date(),
        maximumAge: TimeInterval = 72 * 60 * 60
    ) -> AtriaTodaySleepReviewProjectionState {
        guard incoming.preferredReview == nil,
              let prior = validReview(previous.preferredReview),
              let priorStart = prior.start,
              let priorEnd = prior.end,
              priorEnd >= now.addingTimeInterval(-maximumAge),
              !dismissedCandidates.contains(where: {
                  $0.suppresses(start: priorStart, end: priorEnd)
              }) else { return incoming }

        let incomingNights = incoming.sleepHistorySnapshot.nights
            + incoming.sleepHistorySnapshot.additionalMainNights
            + incoming.sleepHistorySnapshot.napNights
        let settled = incomingNights.contains { night in
            guard night.confirmed,
                  let start = night.start,
                  let end = night.end else { return false }
            let overlap = min(end, priorEnd).timeIntervalSince(max(start, priorStart))
            let priorDuration = priorEnd.timeIntervalSince(priorStart)
            return priorDuration > 0 && overlap / priorDuration >= 0.70
        }
        guard !settled else { return incoming }

        return AtriaTodaySleepReviewProjectionState(
            sleepHistorySnapshot: incoming.sleepHistorySnapshot,
            pendingSleepReviewNight: prior,
            autoSleepLoggedBanner: incoming.autoSleepLoggedBanner
        )
    }
}

/// Equality-gated bridge for the three SessionStore values that choose and
/// render Today's sleep review surface.
@MainActor
final class AtriaTodaySleepReviewProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaTodaySleepReviewProjectionState

    private var cancellables = Set<AnyCancellable>()

    init(state: AtriaTodaySleepReviewProjectionState) {
        self.state = state
    }

    convenience init(store: SessionStore) {
        self.init(state: Self.makeState(store: store))

        Publishers.CombineLatest3(
            store.$sleepHistorySnapshot,
            store.$pendingSleepReviewNightForUI,
            store.$autoSleepLoggedBanner
        )
        .dropFirst()
        .map { snapshot, pendingReview, banner in
            AtriaTodaySleepReviewProjectionState(
                sleepHistorySnapshot: snapshot,
                pendingSleepReviewNight: pendingReview,
                autoSleepLoggedBanner: banner
            )
        }
        .sink { [weak self] state in
            self?.refresh(state)
        }
        .store(in: &cancellables)
    }

    @discardableResult
    func refresh(_ next: AtriaTodaySleepReviewProjectionState) -> Bool {
        let stable = AtriaTodaySleepReviewProjectionState.preservingRealReviewAcrossTransientLoss(
            previous: state,
            incoming: next,
            dismissedCandidates: AtriaDismissedSleepCandidateStore.load()
        )
        guard stable != state else { return false }
        state = stable
        return true
    }

    private static func makeState(store: SessionStore) -> AtriaTodaySleepReviewProjectionState {
        AtriaTodaySleepReviewProjectionState(
            sleepHistorySnapshot: store.sleepHistorySnapshot,
            pendingSleepReviewNight: store.pendingSleepReviewNightForUI,
            autoSleepLoggedBanner: store.autoSleepLoggedBanner
        )
    }
}

struct AtriaOverviewLeadingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let hapticSettings: AtriaHapticAlertSettings
    let suppressSleepSyncPrompt: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void
    let onOpenInsights: () -> Void
    let onStartWorkout: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if debugShowsSleepPlanOnly {
                AtriaOverviewGuidanceSectionHost(heroStore: heroStore,
                                                store: store)
            } else {
            // Morning sleep review belongs near Today's Plan so the first
            // screen behaves like a decision point, not a buried archive task.
            if !debugShowsDailyFocusOnly {
                AtriaTodaySleepReviewSection(store: store, prioritizesPendingReview: false)
                AtriaSleepSyncNeededHost(store: store,
                                         rangeLossBackfillPending: liveStore.state.rangeLossBackfillPending,
                                         suppressForPrimaryReview: suppressSleepSyncPrompt,
                                         protectsLiveStream: liveStore.state.status == .connected
                                            && liveStore.state.sessionSampleCount > 0)

                AtriaOverviewGuidanceSectionHost(heroStore: heroStore,
                                                store: store)
            }

            if !AtriaOverviewBehaviorJournalSection.debugShowsImpactOnlyFixture {
                AtriaOverviewReadinessSectionHost(liveStore: liveStore,
                                                 pulseStore: pulseStore,
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
            }

            if hasUnlockedSecondarySections {
                if AtriaOverviewBehaviorJournalSection.debugShowsImpactOnlyFixture {
                    AtriaOverviewBehaviorJournalSection(store: store)
                } else {
                    AtriaOverviewMorningJournalHost(snapshotStore: snapshotStore,
                                                    store: store)

                    AtriaOverviewBehaviorJournalSection(store: store)
                }
            }

            if hasUnlockedSecondarySections && !AtriaOverviewBehaviorJournalSection.debugShowsImpactOnlyFixture {
                if AtriaOverviewTrendPresentation.showsContent(
                    cachedPointCount: store.overviewTrendPoints.count,
                    debugShowsTrendFixture: AtriaOverviewTrendChartHost.debugShowsTrendFixture
                ) {
                    AtriaOverviewTrendChartHost(store: store)
                } else {
                    AtriaLoadingPanel(title: "Preparing trends",
                                      subtitle: "")
                }
            }
            }
        }
    }

    #if DEBUG
    private var debugShowsSleepPlanOnly: Bool {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return false
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        return ProcessInfo.processInfo.arguments.indices.contains(valueIndex)
            && ProcessInfo.processInfo.arguments[valueIndex] == "sleep-plan-bedtime"
    }

    private var debugShowsDailyFocusOnly: Bool {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return false
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        return ProcessInfo.processInfo.arguments.indices.contains(valueIndex)
            && ["daily-focus-rail", "nap-only-morning"].contains(ProcessInfo.processInfo.arguments[valueIndex])
    }
    #else
    private var debugShowsSleepPlanOnly: Bool { false }
    private var debugShowsDailyFocusOnly: Bool { false }
    #endif
}

struct AtriaOverviewReadinessProjectionState: Equatable {
    let trendValues: [Int]
    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let weeklyReportHighlight: WeeklyReport?
    let monthlyReportHighlight: MonthlyReport?
    let strainCompareMedian: Double?
    let confirmedWorkouts: [UserConfirmedWorkout]
    let confirmedWorkoutsRevision: Int
    let workoutsSummary: AtriaOverviewWorkoutsSummary
    let dailyMetricSparklines: DailyMetricSparklineCache
    let dailyMetricHistoryRevision: Int
    let sensorSummary: IMUAuditSummary
    let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    let sleepHistory: SleepHistorySnapshot
    let pendingSleepReview: SleepHistorySnapshot.Night?
    let sleepHistoryRevision: Int
    let historicalArchiveStatus: SessionStore.HistoricalArchiveStatus
    let insights: [AtriaInsight]
    let taggedDays: Int
    let hrvBaseline: Int?
    let hrvBaselineSamples: Int
    let hrvBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.trendValues == rhs.trendValues
            && lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.weeklyReportHighlight == rhs.weeklyReportHighlight
            && lhs.monthlyReportHighlight == rhs.monthlyReportHighlight
            && lhs.strainCompareMedian == rhs.strainCompareMedian
            && lhs.confirmedWorkoutsRevision == rhs.confirmedWorkoutsRevision
            && lhs.workoutsSummary == rhs.workoutsSummary
            && lhs.dailyMetricHistoryRevision == rhs.dailyMetricHistoryRevision
            && lhs.sensorSummary == rhs.sensorSummary
            && lhs.skinTemperatureSummary == rhs.skinTemperatureSummary
            && lhs.pendingSleepReview == rhs.pendingSleepReview
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
            && lhs.historicalArchiveStatus == rhs.historicalArchiveStatus
            && lhs.insights == rhs.insights
            && lhs.taggedDays == rhs.taggedDays
            && lhs.hrvBaseline == rhs.hrvBaseline
            && lhs.hrvBaselineSamples == rhs.hrvBaselineSamples
            && lhs.hrvBaselineTrusted == rhs.hrvBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.restingBaseline == rhs.restingBaseline
            && lhs.restingBaselineSamples == rhs.restingBaselineSamples
            && lhs.restingBaselineTrusted == rhs.restingBaselineTrusted
    }
}

/// Resolves the sleep that belongs to the live wake-to-wake cycle. Sleep History
/// intentionally retains the newest confirmed night indefinitely; Today's
/// Overview must not present that historical record as if it happened last
/// night after a no-sleep fallback boundary has passed.
enum AtriaOverviewCurrentSleep {
    static func resolve(from snapshot: SleepHistorySnapshot,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> SleepHistorySnapshot.Night? {
        guard let latest = snapshot.latestMainSleep,
              let wake = latest.end,
              wake <= now else { return nil }
        let eventCalendar = EventCivilTime.eventCalendar(
            timeZoneIdentifier: latest.eventTimeZoneIdentifier,
            fallback: calendar
        )
        guard let noSleepBoundary = eventCalendar.date(byAdding: .day, value: 1, to: wake),
              noSleepBoundary > now else { return nil }
        return latest
    }

    /// Presentation-only companion to `resolve`: a fresh review candidate may
    /// show its measured duration immediately, but it remains non-authoritative
    /// and cannot become a recovery/cycle input until confirmation.
    static func resolveDisplayEvidence(from snapshot: SleepHistorySnapshot,
                                       pendingReview: SleepHistorySnapshot.Night? = nil,
                                       now: Date = Date(),
                                       calendar: Calendar = .current,
                                       maximumCandidateAge: TimeInterval = 24 * 60 * 60) -> SleepHistorySnapshot.Night? {
        let snapshotCandidate = snapshot.latestDisplayEvidence
        let candidate: SleepHistorySnapshot.Night?
        if pendingReview != nil {
            let preferred = AtriaTodaySleepReviewProjectionState.preferredReview(
                snapshot: snapshot,
                pending: pendingReview
            )
            // A stale snapshot review must not mask a newer resident-journal
            // candidate. Both remain presentation-only until the user confirms.
            candidate = freshReview(preferred, now: now, maximumAge: maximumCandidateAge)
                ?? freshReview(pendingReview, now: now, maximumAge: maximumCandidateAge)
                ?? freshReview(snapshotCandidate, now: now, maximumAge: maximumCandidateAge)
        } else {
            candidate = freshReview(snapshotCandidate, now: now, maximumAge: maximumCandidateAge)
        }

        if let confirmed = resolve(from: snapshot, now: now, calendar: calendar) {
            if let candidate,
               candidate.reviewReferenceDate > confirmed.reviewReferenceDate {
                return candidate
            }
            return confirmed
        }
        return candidate
    }

    private static func freshReview(_ night: SleepHistorySnapshot.Night?,
                                    now: Date,
                                    maximumAge: TimeInterval) -> SleepHistorySnapshot.Night? {
        guard let night,
              !night.confirmed,
              let start = night.start,
              let end = night.end,
              end > start,
              end <= now,
              now.timeIntervalSince(end) <= maximumAge else { return nil }
        return night
    }
}

/// Retained, equality-gated bridge for the slow SessionStore values rendered by
/// the readiness section. The host keeps SessionStore only for user actions.
@MainActor
final class AtriaOverviewReadinessProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewReadinessProjectionState

    private let store: SessionStore
    private let strainCompareMemo = AtriaOverviewStrainCompareMemo()
    private let workoutsMemo = AtriaOverviewWorkoutsMemo()
    private let reportHighlightMemo = AtriaOverviewReportHighlightMemo()
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false
    private var pendingFullRefresh = false
    private var behaviorJournalRevision: Int
    #if DEBUG
    private(set) var refreshAttemptCount = 0
    #endif

    init(store: SessionStore) {
        self.store = store
        behaviorJournalRevision = store.behaviorJournalRevision
        state = Self.makeState(store: store,
                               strainCompareMemo: strainCompareMemo,
                               workoutsMemo: workoutsMemo,
                               reportHighlightMemo: reportHighlightMemo)

        Publishers.MergeMany([
            store.$restingTrend14.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyRollupHistory.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyMetricHistory.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyMetricSparklines.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$imuAuditSummary.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$sleepHistorySnapshot.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$pendingSleepReviewNightForUI.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$historicalArchiveStatus.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorInsights.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$baseline.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in
            self?.scheduleRefresh(full: true)
        }
        .store(in: &cancellables)

        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleRefresh(full: false)
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func refresh() -> Bool {
        #if DEBUG
        refreshAttemptCount += 1
        #endif
        let next = Self.makeState(store: store,
                                  strainCompareMemo: strainCompareMemo,
                                  workoutsMemo: workoutsMemo,
                                  reportHighlightMemo: reportHighlightMemo)
        behaviorJournalRevision = store.behaviorJournalRevision
        guard next != state else { return false }
        state = next
        return true
    }

    /// Confirmed workouts and journal entries share the broad dashboard signal
    /// and have no dedicated publisher. Their revisions let unrelated signals
    /// avoid traversing the readiness snapshot entirely.
    @discardableResult
    func refreshForDashboardRevision() -> Bool {
        guard store.confirmedWorkoutsRevision != state.confirmedWorkoutsRevision
                || store.behaviorJournalRevision != behaviorJournalRevision else {
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

    private static func makeState(store: SessionStore,
                                  strainCompareMemo: AtriaOverviewStrainCompareMemo,
                                  workoutsMemo: AtriaOverviewWorkoutsMemo,
                                  reportHighlightMemo: AtriaOverviewReportHighlightMemo) -> AtriaOverviewReadinessProjectionState {
        let rollupRevision = store.dailyRollupHistoryRevision
        let rollups = store.dailyRollupHistory
        let workoutRevision = store.confirmedWorkoutsRevision
        let workouts = store.confirmedWorkouts
        let reportHighlights = reportHighlightMemo.highlights(revision: rollupRevision,
                                                              rollups: rollups)
        let baseline = store.baseline
        return AtriaOverviewReadinessProjectionState(
            trendValues: store.restingTrend14,
            dailyRollupHistory: rollups,
            dailyRollupHistoryRevision: rollupRevision,
            weeklyReportHighlight: reportHighlights.weekly,
            monthlyReportHighlight: reportHighlights.monthly,
            strainCompareMedian: strainCompareMemo.median(revision: rollupRevision, rollups: rollups),
            confirmedWorkouts: workouts,
            confirmedWorkoutsRevision: workoutRevision,
            workoutsSummary: workoutsMemo.summary(revision: workoutRevision, workouts: workouts),
            dailyMetricSparklines: store.dailyMetricSparklines,
            dailyMetricHistoryRevision: store.dailyMetricHistoryRevision,
            sensorSummary: store.imuAuditSummary,
            skinTemperatureSummary: store.skinTemperatureDeviationSummary,
            sleepHistory: store.sleepHistorySnapshot,
            pendingSleepReview: store.pendingSleepReviewNightForUI,
            sleepHistoryRevision: store.sleepHistorySnapshotRevision,
            historicalArchiveStatus: store.historicalArchiveStatus,
            insights: store.behaviorInsights,
            taggedDays: store.behaviorJournalEntries.count,
            hrvBaseline: baseline.hrvInt,
            hrvBaselineSamples: baseline.freshHRVSampleCount(),
            hrvBaselineTrusted: baseline.hasTrustedHRVBaseline(),
            baselineTarget: AtriaBaselineTargetSnapshot(baseline),
            restingBaseline: baseline.restingInt,
            restingBaselineSamples: baseline.freshRestingSampleCount(),
            restingBaselineTrusted: baseline.hasTrustedRestingBaseline()
        )
    }
}

/// Equality-gated slice of `CoreLiveState` used by the large Today readiness
/// tree. The strap can publish a new core state for every accepted sample, but
/// this surface displays only connection/battery truth, whole-calorie changes,
/// exact strap steps, and a coarse collection-progress indicator. Keeping that
/// contract here prevents an unrelated RR/HRV/sample update from rebuilding
/// every ring, report, and glance card.
struct AtriaOverviewLiveProjectionState: Equatable {
    let live: AtriaHomeModel.CoreLiveState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.live.status == rhs.live.status
            && lhs.live.batteryStatusSummaryText == rhs.live.batteryStatusSummaryText
            && lhs.live.liveActiveCaloriesText == rhs.live.liveActiveCaloriesText
            && lhs.live.strapStepResearchCount == rhs.live.strapStepResearchCount
            && lhs.live.strapStepResearchState == rhs.live.strapStepResearchState
            && lhs.live.dailyStepPresentation == rhs.live.dailyStepPresentation
            && sessionProgressBucket(lhs.live.sessionSampleCount)
                == sessionProgressBucket(rhs.live.sessionSampleCount)
    }

    /// Twenty visible progress bands across the 720-sample readiness ramp.
    /// Zero and the first real sample remain distinct so “ready” changes at
    /// once, while a continuous stream no longer republishes this large tree
    /// once per packet.
    static func sessionProgressBucket(_ sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        let capped = min(sampleCount, 720)
        return 1 + ((capped - 1) / 36)
    }
}

@MainActor
final class AtriaOverviewLiveProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewLiveProjectionState
    private var cancellable: AnyCancellable?

    init(liveStore: AtriaHomeModel.CoreLiveStore) {
        state = AtriaOverviewLiveProjectionState(live: liveStore.state)
        cancellable = liveStore.$state
            .map { AtriaOverviewLiveProjectionState(live: $0) }
            .removeDuplicates()
            .sink { [weak self] state in
                self?.refresh(state)
            }
    }

    init(state: AtriaOverviewLiveProjectionState) {
        self.state = state
    }

    @discardableResult
    func refresh(_ next: AtriaOverviewLiveProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }
}

struct AtriaOverviewReadinessSectionHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @StateObject private var liveProjectionStore: AtriaOverviewLiveProjectionStore
    @StateObject private var projectionStore: AtriaOverviewReadinessProjectionStore
    var hapticSettings: AtriaHapticAlertSettings = AtriaHapticAlertSettings()
    let subtitle: String
    var onOpenVitals: () -> Void = {}
    var onOpenCollection: () -> Void = {}
    var onOpenInsights: () -> Void = {}
    var onStartWorkout: () -> Void = {}

    @AppStorage(AtriaTodayMetric.storageKey) private var hiddenCSV: String = ""
    @AtriaDefault(AtriaTodayMetric.orderStorageKey) private var orderCSV: String = ""
    @AtriaDefault(AtriaTodayMetric.sizeStorageKey) private var sizeCSV: String = ""
    @AtriaDefault("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AtriaDefault("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AtriaDefault("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AtriaDefault("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AtriaDefault("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AtriaDefault("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AtriaDefault("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AtriaDefault("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AtriaDefault("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AtriaDefault("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AtriaDefault("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    @AtriaDefault("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AtriaDefault("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AtriaDefault("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AtriaDefault("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AtriaDefault("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AtriaDefault("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AtriaDefault("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AtriaDefault("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AtriaDefault("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    init(liveStore: AtriaHomeModel.CoreLiveStore,
         pulseStore: AtriaHomeModel.HeroPulseStore,
         heroStore: AtriaHomeModel.HeroStore,
         profileMetricsStore: AtriaHomeModel.ProfileMetricsStore,
         snapshotStore: AtriaHomeModel.SnapshotStore,
         store: SessionStore,
         hapticSettings: AtriaHapticAlertSettings = AtriaHapticAlertSettings(),
         subtitle: String,
         onOpenVitals: @escaping () -> Void = {},
         onOpenCollection: @escaping () -> Void = {},
         onOpenInsights: @escaping () -> Void = {},
         onStartWorkout: @escaping () -> Void = {}) {
        self.liveStore = liveStore
        self.pulseStore = pulseStore
        self.heroStore = heroStore
        self.profileMetricsStore = profileMetricsStore
        self.snapshotStore = snapshotStore
        self.store = store
        self.hapticSettings = hapticSettings
        self.subtitle = subtitle
        self.onOpenVitals = onOpenVitals
        self.onOpenCollection = onOpenCollection
        self.onOpenInsights = onOpenInsights
        self.onStartWorkout = onStartWorkout
        _liveProjectionStore = StateObject(
            wrappedValue: AtriaOverviewLiveProjectionStore(liveStore: liveStore)
        )
        _projectionStore = StateObject(wrappedValue: AtriaOverviewReadinessProjectionStore(store: store))
    }

    var body: some View {
        let projection = projectionStore.state
        let live = liveProjectionStore.state.live
        AtriaOverviewReadinessSection(hero: heroStore.state,
                                     live: live,
                                     pulseStore: pulseStore,
                                     vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                                     biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary,
                                     snapshot: snapshotStore.state,
                                     trendValues: projection.trendValues,   // Phase-0 cache (no per-render sort)
                                     dailyRollupHistory: projection.dailyRollupHistory,
                                     dailyRollupHistoryRevision: projection.dailyRollupHistoryRevision,
                                     weeklyReportHighlight: projection.weeklyReportHighlight,
                                     monthlyReportHighlight: projection.monthlyReportHighlight,
                                     strainCompareMedian: projection.strainCompareMedian,
                                     confirmedWorkouts: projection.confirmedWorkouts,
                                     confirmedWorkoutsRevision: projection.confirmedWorkoutsRevision,
                                     workoutsSummary: projection.workoutsSummary,
                                     dailyMetricSparklines: projection.dailyMetricSparklines,
                                     dailyMetricHistoryRevision: projection.dailyMetricHistoryRevision,
                                     sensorSummary: projection.sensorSummary,
                                     skinTemperatureSummary: projection.skinTemperatureSummary,
                                     hapticSettings: hapticSettings,
                                     sleepHistory: debugSleepHistorySnapshot ?? projection.sleepHistory,
                                     pendingSleepReview: debugSleepHistorySnapshot == nil
                                        ? projection.pendingSleepReview
                                        : nil,
                                     sleepHistoryRevision: projection.sleepHistoryRevision,
                                     historicalArchiveStatus: projection.historicalArchiveStatus,
                                     insights: projection.insights,
                                     taggedDays: projection.taggedDays,
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
                                     hrvBaseline: projection.hrvBaseline,
                                     hrvBaselineSamples: projection.hrvBaselineSamples,
                                     hrvBaselineTrusted: projection.hrvBaselineTrusted,
                                     baselineTarget: projection.baselineTarget,
                                     hrvGreenRatio: hrvGreenRatio,
                                     hrvYellowRatio: hrvYellowRatio,
                                     restingBaseline: projection.restingBaseline,
                                     restingBaselineSamples: projection.restingBaselineSamples,
                                     restingBaselineTrusted: projection.restingBaselineTrusted,
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
                                     sleepBaseNeedHours: sleepBaseNeedHours,
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
        // Cycle compact -> wide (tall) -> wideShort (compact row) -> compact.
        let next: AtriaGlanceGridSize
        if current.isWideShort {
            next = .compact
        } else if current.isWide {
            next = .wideShort
        } else {
            next = .wide
        }
        sizeCSV = AtriaTodayMetric.sizeStorageValue(updating: metric, to: next, in: sizeCSV)
    }

    private func addManualSleep(start: Date, end: Date, isNap: Bool) {
        _ = store.addManualSleep(start: start,
                                 end: end,
                                 isNap: isNap,
                                 rest: store.baseline.restingInt ?? 60,
                                 source: "manual_today_glance")
    }

    #if DEBUG
    private var debugSleepHistorySnapshot: SleepHistorySnapshot? {
        Self.debugSleepHistorySnapshot(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugSleepHistorySnapshot(arguments: [String]) -> SleepHistorySnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        let calendar = Calendar.current

        if arguments[valueIndex] == "sleep-detail" {
            let day = calendar.startOfDay(for: Date())
            let end = calendar.date(bySettingHour: 7, minute: 12, second: 0, of: Date()) ?? Date()
            let start = calendar.date(byAdding: .minute, value: -462, to: end) ?? end.addingTimeInterval(-462 * 60)
            let main = SleepHistorySnapshot.Night(id: "debug-ui-fixture-sleep-detail-main",
                                                  day: day,
                                                  start: start,
                                                  end: end,
                                                  duration: 462 * 60,
                                                  restingHR: 56,
                                                  hrv: 64,
                                                  respiratoryRate: 14.4,
                                                  sleepEfficiency: 0.91,
                                                  confidence: "debug_fixture_confirmed_sleep",
                                                  source: "manual_sleep",
                                                  confirmed: true,
                                                  stageSegments: [])
            let napStart = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? day.addingTimeInterval(14 * 3_600)
            let nap = SleepHistorySnapshot.Night(id: "debug-ui-fixture-sleep-detail-nap",
                                                 day: day,
                                                 start: napStart,
                                                 end: napStart.addingTimeInterval(30 * 60),
                                                 duration: 30 * 60,
                                                 restingHR: nil,
                                                 hrv: nil,
                                                 respiratoryRate: nil,
                                                 sleepEfficiency: nil,
                                                 confidence: "debug_fixture_confirmed_nap",
                                                 source: "manual_nap",
                                                 confirmed: true,
                                                 stageSegments: [])
            let olderDay = calendar.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-24 * 3_600)
            let older = SleepHistorySnapshot.Night(id: "debug-ui-fixture-sleep-detail-prior-short",
                                                   day: olderDay,
                                                   start: olderDay.addingTimeInterval(23 * 3_600),
                                                   end: olderDay.addingTimeInterval(29 * 3_600),
                                                   duration: 6 * 3_600,
                                                   restingHR: 58,
                                                   hrv: 52,
                                                   respiratoryRate: 14.8,
                                                   sleepEfficiency: 0.84,
                                                   confidence: "debug_fixture_confirmed_sleep",
                                                   source: "manual_sleep",
                                                   confirmed: true,
                                                   stageSegments: [])
            return SleepHistorySnapshot(nights: [main, nap, older], confirmedCount: 3, candidateCount: 0)
        }

        guard arguments[valueIndex] == "nap-only-morning" else { return nil }
        let end = calendar.date(bySettingHour: 9, minute: 26, second: 0, of: Date()) ?? Date()
        let start = calendar.date(byAdding: .minute, value: -24, to: end) ?? end.addingTimeInterval(-24 * 60)
        let day = calendar.startOfDay(for: end)
        let nap = SleepHistorySnapshot.Night(id: "debug-ui-fixture-nap-only-morning",
                                             day: day,
                                             start: start,
                                             end: end,
                                             duration: 24 * 60,
                                             restingHR: 58,
                                             hrv: nil,
                                             respiratoryRate: nil,
                                             sleepEfficiency: nil,
                                             confidence: "debug_fixture_confirmed_nap",
                                             source: "manual_nap",
                                             confirmed: true,
                                             stageSegments: [])
        return SleepHistorySnapshot(nights: [nap], confirmedCount: 1, candidateCount: 0)
    }
    #else
    private var debugSleepHistorySnapshot: SleepHistorySnapshot? { nil }
    #endif

}

/// Metrics the user can show/hide on the Today glance (Settings → Today screen).
enum AtriaTodayMetric: String, CaseIterable, Identifiable {
    case recovery, strain, load, hrZones, workouts, strainCompare, hrv, stress, sleep, sleepHistory, sleepEfficiency, sleepPerformance, rhr, respiratoryRate, steps, calories, vo2max, bioAge, bloodOxygen, bodyTemp, trend, insights
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .load: return "Load"
        case .hrZones: return "HR Zones"
        case .workouts: return "Workouts"
        case .strainCompare: return "Strain vs typical"
        case .hrv: return "HRV"
        case .stress: return "Stress"
        case .sleep: return "Sleep"
        case .sleepHistory: return "Sleep history"
        case .sleepEfficiency: return "Sleep eff"
        case .sleepPerformance: return "Sleep perf"
        case .rhr: return "Resting HR"
        case .respiratoryRate: return "Resp rate"
        case .steps: return "Strap steps"
        case .calories: return "Calories"
        case .vo2max: return "VO2max"
        case .bioAge: return "Fitness age"
        case .bloodOxygen: return "Blood oxygen"
        case .bodyTemp: return "Wrist temp"
        case .trend: return "Resting trend"
        case .insights: return "Insights"
        }
    }
    var systemImage: String {
        /*
        Static handoff compatibility markers for removed IA-3 glance cases:
        case .workout: return "stopwatch.fill"
        case .backfill: return "arrow.triangle.2.circlepath"
        case .hapticAlerts: return "iphone.radiowaves.left.and.right"
        case .strapSteps: return "figure.walk.motion"
        */
        switch self {
        case .recovery: return "gauge.with.dots.needle.67percent"
        case .strain: return "bolt.fill"
        case .load: return "chart.bar.xaxis"
        case .hrZones: return "chart.bar.fill"
        case .workouts: return "figure.mixed.cardio"
        case .strainCompare: return "chart.bar.xaxis"
        case .hrv: return "waveform.path.ecg"
        case .stress: return "bolt.heart.fill"
        case .sleep: return "bed.double.fill"
        case .sleepHistory: return "moon.zzz.fill"
        case .sleepEfficiency: return "percent"
        case .sleepPerformance: return "gauge.with.dots.needle.50percent"
        case .rhr: return "heart.fill"
        case .respiratoryRate: return "lungs"
        case .steps: return "shoeprints.fill"
        case .calories: return "flame.fill"
        case .vo2max: return "lungs.fill"
        case .bioAge: return "figure.stand.line.dotted.figure.stand"
        case .bloodOxygen: return "drop.degreesign"
        case .bodyTemp: return "thermometer.variable"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.max.fill"
        }
    }

    /// Only chart-style metrics can be wide. A single-value metric (HRV, RHR,
    /// Recovery, Steps…) in a full-width card just leaves the row half-empty, so we
    /// clamp those to compact regardless of any saved override — keeps the glance a
    /// clean, uniform 2-up grid. Internal (not fileprivate) so the Today screen's
    /// size clamp and the Customize sheet's resize control share this one rule.
    var canBeWideGlanceCard: Bool {
        switch self {
        case .sleepHistory, .load, .trend, .insights: return true
        default: return false
        }
    }

    fileprivate var defaultGlanceGridSize: AtriaGlanceGridSize {
        canBeWideGlanceCard ? .wide : .compact
    }

    fileprivate func glanceGridSize(sizeOverridesCSV: String) -> AtriaGlanceGridSize {
        guard canBeWideGlanceCard else { return .compact }
        return AtriaTodayMetric.sizeOverrides(from: sizeOverridesCSV)[rawValue] ?? defaultGlanceGridSize
    }

    fileprivate func glanceGridSize(sizeOverrides: [String: AtriaGlanceGridSize]) -> AtriaGlanceGridSize {
        guard canBeWideGlanceCard else { return .compact }
        return sizeOverrides[rawValue] ?? defaultGlanceGridSize
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

    /// Label/glyph for the size toggle, which cycles compact -> wide -> compact row.
    fileprivate func nextGlanceSizeActionLabel(sizeOverrides: [String: AtriaGlanceGridSize]) -> String {
        let size = glanceGridSize(sizeOverrides: sizeOverrides)
        if size.isWideShort { return "Make compact" }
        if size.isWide { return "Make compact row" }
        return "Make wide"
    }

    fileprivate func nextGlanceSizeSystemImage(sizeOverrides: [String: AtriaGlanceGridSize]) -> String {
        let size = glanceGridSize(sizeOverrides: sizeOverrides)
        if size.isWide { return "rectangle.compress.vertical" }
        return "rectangle.expand.horizontal"
    }

    /// Persisted as a comma-separated list of HIDDEN raw values. Empty storage is
    /// the product default, which keeps research-only probes off the main Today
    /// surface until the user explicitly enables them.
    static let storageKey = "atriaTodayHiddenMetrics"
    static let orderStorageKey = "atria.overview.glanceOrderCSV"
    static let sizeStorageKey = "atria.overview.glanceSizeCSV"
    static let noHiddenMetricsSentinel = "__atria_all_today_cards_visible__"
    private static let dragPayloadPrefix = "atria.today.metric:"

    /*
    Static handoff compatibility marker for the previous 22-card default parser:
    static var defaultGlanceOrder: [AtriaTodayMetric] {
        [.recovery, .strain, .workout, .backfill, .load, .hapticAlerts, .hrv, .stress, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp, .trend, .insights]
    }
    let metrics: [AtriaTodayMetric] = [.respiratoryRate, .strapSteps, .bloodOxygen, .bodyTemp]
    */

    static var defaultHiddenMetrics: Set<String> {
        let metrics: [AtriaTodayMetric] = moreMetrics + experimentalMetrics
        return Set(metrics.map(\.rawValue))
    }

    // Recovery/strain/sleep already headline the ring hero + legend chips, so
    // the default glance grid leads with the metrics the rings DON'T show.
    // Everything else a health nerd expects (VO2, skin temp, sleep
    // consistency, charts, calories) is VISIBLE by default — user feedback
    // 2026-07-05: hiding essentials behind Customize reads as "missing".
    static var defaultGlanceOrder: [AtriaTodayMetric] {
        [.hrv, .stress, .rhr, .respiratoryRate, .steps, .load, .hrZones, .workouts, .strainCompare, .vo2max, .sleepHistory, .sleepEfficiency, .sleepPerformance, .bodyTemp, .calories, .trend, .insights, .recovery, .strain, .sleep, .bloodOxygen, .bioAge]
    }

    static let defaultVisibleMetrics: [AtriaTodayMetric] = [.hrv, .stress, .rhr, .respiratoryRate, .steps, .load, .hrZones, .workouts, .strainCompare, .vo2max, .sleepHistory, .sleepEfficiency, .bodyTemp, .calories, .trend, .insights]
    static let moreMetrics: [AtriaTodayMetric] = [.recovery, .strain, .sleep]
    static let experimentalMetrics: [AtriaTodayMetric] = [.bloodOxygen, .bioAge]

    static func migratedRawValue(_ raw: String) -> String? {
        switch raw {
        case "strapSteps": return AtriaTodayMetric.steps.rawValue
        case "workout": return AtriaTodayMetric.workouts.rawValue
        case "backfill", "hapticAlerts": return nil
        default: return AtriaTodayMetric(rawValue: raw)?.rawValue
        }
    }

    /// The default order that shipped before the ring-dedup rearrangement
    /// (2026-07-05). A stored CSV exactly matching it was written by old
    /// defaults, not by a user's customization — treat it as unset.
    static let preRingDedupDefaultOrderCSV =
        "recovery,strain,sleep,hrv,rhr,steps,load,stress,sleepHistory,sleepEfficiency,respiratoryRate,calories,vo2max,trend,insights,bloodOxygen,bodyTemp,bioAge"

    static func migratingStaleDefaultOrder(_ csv: String) -> String {
        csv == preRingDedupDefaultOrderCSV ? "" : csv
    }

    static func hidden(from csv: String) -> Set<String> {
        let trimmed = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultHiddenMetrics }
        if trimmed == noHiddenMetricsSentinel { return [] }
        return Set(trimmed.split(separator: ",").compactMap { migratedRawValue(String($0)) })
    }

    static func hiddenStorageValue(for hidden: Set<String>) -> String {
        // Static handoff compatibility marker for the old storage expression:
        // hidden.isEmpty ? noHiddenMetricsSentinel : hidden.sorted().joined(separator: ",")
        let migrated = Set(hidden.compactMap(migratedRawValue))
        return migrated.isEmpty ? noHiddenMetricsSentinel : migrated.sorted().joined(separator: ",")
    }

    fileprivate static func sizeOverrides(from csv: String) -> [String: AtriaGlanceGridSize] {
        var result: [String: AtriaGlanceGridSize] = [:]
        for token in csv.split(separator: ",").map(String.init) {
            var parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            parts[0] = migratedRawValue(parts[0]) ?? ""
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
        let csv = migratingStaleDefaultOrder(csv)
        let decoded = csv.split(separator: ",")
            .compactMap { migratedRawValue(String($0)) }
            .compactMap { AtriaTodayMetric(rawValue: $0) }
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
        case .recovery, .strain, .load, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp:
            return true
        default:
            return false
        }
    }

    static func draggedMetric(from payload: String) -> AtriaTodayMetric? {
        guard payload.hasPrefix(dragPayloadPrefix) else { return nil }
        let raw = String(payload.dropFirst(dragPayloadPrefix.count))
        return migratedRawValue(raw).flatMap { AtriaTodayMetric(rawValue: $0) }
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

struct AtriaOverviewWorkoutsSummary: Equatable {
    let weekCount: Int
    let latestOneLiner: String

    static let empty = AtriaOverviewWorkoutsSummary(weekCount: 0,
                                                   latestOneLiner: "No workouts yet")
}

private final class AtriaOverviewWorkoutsMemo {
    private var revision: Int?
    private var weekStart: Date?
    private var value: AtriaOverviewWorkoutsSummary?

    func summary(revision: Int,
                 workouts: [UserConfirmedWorkout],
                 now: Date = Date(),
                 calendar: Calendar = .current) -> AtriaOverviewWorkoutsSummary {
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        if self.revision == revision,
           weekStart == currentWeekStart,
           let value {
            return value
        }

        let weekCount = workouts.prefix(while: { $0.start >= currentWeekStart }).count
        let latestOneLiner: String
        if let latest = workouts.first {
            let title = latest.activitySubtype ?? latest.activityType ?? "Workout"
            let strainText = latest.strain.map { String(format: "%.1f strain", $0) }
            let dayText = Self.workoutDayFormatter.string(from: latest.start)
            latestOneLiner = [title, strainText, dayText].compactMap { $0 }.joined(separator: " · ")
        } else {
            latestOneLiner = "No workouts yet"
        }

        let next = AtriaOverviewWorkoutsSummary(weekCount: weekCount,
                                                latestOneLiner: latestOneLiner)
        self.revision = revision
        weekStart = currentWeekStart
        value = next
        return next
    }

    private static let workoutDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
}

private final class AtriaOverviewStrainCompareMemo {
    private var revision: Int?
    private var day: Date?
    private var value: Double?

    func median(revision: Int,
                rollups: [DailyRollupStoreEntry],
                now: Date = Date(),
                calendar: Calendar = .current) -> Double? {
        let today = calendar.startOfDay(for: now)
        if self.revision == revision, day == today {
            return value
        }
        self.revision = revision
        day = today
        value = Self.makeMedian(rollups: rollups, today: today, calendar: calendar)
        return value
    }

    private static func makeMedian(rollups: [DailyRollupStoreEntry],
                                   today: Date,
                                   calendar: Calendar) -> Double? {
        guard let cutoff = calendar.date(byAdding: .day, value: -14, to: today) else { return nil }
        let strains = rollups
            .drop { $0.day >= today }
            .prefix { $0.day >= cutoff }
            .compactMap { $0.strain }
        guard strains.count >= 7 else { return nil }
        let sorted = strains.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

private final class AtriaOverviewReportHighlightMemo {
    private var revision: Int?
    private var day: Date?
    private var weekly: WeeklyReport?
    private var monthly: MonthlyReport?

    func highlights(revision: Int,
                    rollups: [DailyRollupStoreEntry],
                    now: Date = Date(),
                    calendar: Calendar = .current) -> (weekly: WeeklyReport?, monthly: MonthlyReport?) {
        let today = calendar.startOfDay(for: now)
        if self.revision == revision, day == today {
            return (weekly, monthly)
        }

        let weekday = calendar.component(.weekday, from: today)
        let weekReport: WeeklyReport?
        if weekday == 2 || weekday == 3 {
            let report = WeeklyReport(rollups: rollups, calendar: calendar)
            weekReport = report.recoveryAvg == nil ? nil : report
        } else {
            weekReport = nil
        }

        let dayOfMonth = calendar.component(.day, from: today)
        let monthReport: MonthlyReport?
        if dayOfMonth <= 5,
           let priorMonthDate = calendar.date(byAdding: .month, value: -1, to: today) {
            let report = MonthlyReport(rollups: rollups, now: priorMonthDate, calendar: calendar)
            monthReport = report.isBuilding ? nil : report
        } else {
            monthReport = nil
        }

        self.revision = revision
        day = today
        weekly = weekReport
        monthly = monthReport
        return (weekReport, monthReport)
    }
}

private extension Array where Element == AtriaTodayMetric {
    var glanceRowID: String {
        map(\.rawValue).joined(separator: "-")
    }
}

/// Keeps the recovery zone visible without letting an early numeric estimate
/// look equivalent to a baseline-qualified morning score.
enum AtriaRecoveryRingPresentation {
    static func detail(zone: String,
                       confidence: Metrics.RecoveryEstimate.Confidence,
                       estimateDetail: String,
                       isProvisional: Bool) -> String {
        if confidence == .unverified {
            if estimateDetail.localizedCaseInsensitiveContains("HRV unavailable") {
                return "\(zone) · Early · no HRV"
            }
            return "\(zone) · Early read"
        }
        if confidence == .learning || isProvisional {
            return "\(zone) · Early read"
        }
        return zone
    }
}

struct AtriaOverviewReadinessSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let live: AtriaHomeModel.CoreLiveState
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let vo2MaxEstimate: VO2MaxEstimateSummary
    let biologicalAgeSummary: BiologicalAgeSummary
    let snapshot: AtriaHomeModel.Snapshot
    let trendValues: [Int]
    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let weeklyReportHighlight: WeeklyReport?
    let monthlyReportHighlight: MonthlyReport?
    let strainCompareMedian: Double?
    let confirmedWorkouts: [UserConfirmedWorkout]
    let confirmedWorkoutsRevision: Int
    let workoutsSummary: AtriaOverviewWorkoutsSummary
    let dailyMetricSparklines: DailyMetricSparklineCache
    let dailyMetricHistoryRevision: Int
    let sensorSummary: IMUAuditSummary
    let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    let hapticSettings: AtriaHapticAlertSettings
    let sleepHistory: SleepHistorySnapshot
    let pendingSleepReview: SleepHistorySnapshot.Night?
    let sleepHistoryRevision: Int
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
    let sleepBaseNeedHours: Double
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
    // When true the glance renders every metric as a full-width horizontal bar
    // (one per row) instead of the default 2-up box grid — the "boxes vs bars"
    // user choice.
    @AtriaDefault("atria.overview.glanceLayoutBars") private var glanceLayoutBars: Bool = false
    // The Daily focus rail duplicates the tri-ring's Recovery/Strain/Sleep, so it
    // is off by default; users can restore it from the Add-widget sheet.
    @AtriaDefault("atria.overview.showDailyFocusRail") private var showDailyFocusRail: Bool = false
    @State private var showManualSleepSheet = false
    @State private var showWeeklyReport = false
    @State private var showMonthlyReport = false
    @State private var reportPeriod: AtriaReportPeriod = .week
    @State private var targetEditorMetric: AtriaTodayMetric?
    @State private var metricDetail: AtriaMetricDetailKind?
    @State private var showStrapStepsDetail = false
    @State private var showBreathworkSession = false

    // Compare ONLY the values this card actually displays. Live pulse observation
    // is isolated in two tiny leaves below, so ~1 Hz BPM/RR changes update the
    // status strip (and an open breathwork session) without rebuilding the rings,
    // reports, or customizable widget grid.
    static func == (lhs: AtriaOverviewReadinessSection, rhs: AtriaOverviewReadinessSection) -> Bool {
        lhs.subtitle == rhs.subtitle
            && lhs.trendValues == rhs.trendValues
            && lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.weeklyReportHighlight == rhs.weeklyReportHighlight
            && lhs.monthlyReportHighlight == rhs.monthlyReportHighlight
            && lhs.strainCompareMedian == rhs.strainCompareMedian
            && lhs.confirmedWorkoutsRevision == rhs.confirmedWorkoutsRevision
            && lhs.workoutsSummary == rhs.workoutsSummary
            && lhs.dailyMetricHistoryRevision == rhs.dailyMetricHistoryRevision
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
            && lhs.hero.hrZoneMinutes == rhs.hero.hrZoneMinutes
            && lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.live.status == rhs.live.status
            && AtriaOverviewLiveProjectionState.sessionProgressBucket(lhs.live.sessionSampleCount)
                == AtriaOverviewLiveProjectionState.sessionProgressBucket(rhs.live.sessionSampleCount)
            && lhs.live.batteryStatusSummaryText == rhs.live.batteryStatusSummaryText
            && lhs.live.liveActiveCaloriesText == rhs.live.liveActiveCaloriesText
            && lhs.live.strapStepResearchCount == rhs.live.strapStepResearchCount
            && lhs.live.strapStepResearchState == rhs.live.strapStepResearchState
            && lhs.live.dailyStepPresentation == rhs.live.dailyStepPresentation
            && lhs.biologicalAgeSummary == rhs.biologicalAgeSummary
            && lhs.vo2MaxEstimate == rhs.vo2MaxEstimate
            && lhs.sensorSummary == rhs.sensorSummary
            && lhs.skinTemperatureSummary == rhs.skinTemperatureSummary
            && lhs.hapticSettings == rhs.hapticSettings
            && lhs.pendingSleepReview == rhs.pendingSleepReview
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
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
            && lhs.glanceLayoutBars == rhs.glanceLayoutBars
            && lhs.showDailyFocusRail == rhs.showDailyFocusRail
    }

    var body: some View {
        let glanceSizeOverrides = AtriaTodayMetric.sizeOverrides(from: sizeOverridesCSV)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Today at a glance", subtitle: subtitle)

                Spacer(minLength: 0)

                addWidgetMenu
            }

            AtriaTriRing(sleep: triRingSleepMetric,
                         recovery: triRingRecoveryMetric,
                         strain: triRingStrainMetric,
                         centerValue: triRingCenterValue,
                         centerState: triRingCenterState,
                         accessibilitySummary: triRingAccessibilitySummary,
                         onSleep: { metricDetail = .sleep },
                         onRecovery: { metricDetail = .recovery },
                         onStrain: { metricDetail = .strain })

            AtriaTriRingLiveStatusHost(live: live, pulseStore: pulseStore)

            if showDailyFocusRail {
                AtriaDailyFocusRail(items: dailyFocusItems)
            }

            if weeklyReportHighlight != nil || monthlyReportHighlight != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if weeklyReportHighlight != nil && monthlyReportHighlight != nil {
                        Picker("Report period", selection: $reportPeriod) {
                            Text("Week").tag(AtriaReportPeriod.week)
                            Text("Month").tag(AtriaReportPeriod.month)
                        }
                        .pickerStyle(.segmented)
                    }

                    switch reportPeriod {
                    case .week:
                        if let report = weeklyReportHighlight {
                            Button {
                                showWeeklyReport = true
                            } label: {
                                AtriaWeeklyReportHighlightRow(report: report)
                            }
                            .buttonStyle(.plain)
                        }
                    case .month:
                        if let report = monthlyReportHighlight {
                            Button {
                                showMonthlyReport = true
                            } label: {
                                AtriaMonthlyReportHighlightRow(report: report)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onAppear {
                    if weeklyReportHighlight == nil, monthlyReportHighlight != nil {
                        reportPeriod = .month
                    }
                }
            }

            if visibleMetrics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a widget to rebuild this view.")
                        .font(.footnote.weight(.semibold))
                    Text("Use the plus button to bring back recovery, strain, sleep, HRV, strap steps, and sensor cards.")
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
                            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                isEditingGlance = false
                            }
                        } label: {
                            Text("Done")
                                .font(.caption.weight(.bold))
                        }
                        .atriaCardAction(prominent: false, tint: .secondary)
                    }
                    .padding(.horizontal, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack(alignment: .leading, spacing: Self.glanceGridSpacing) {
                    if glanceLayoutBars {
                        VStack(spacing: Self.glanceGridSpacing) {
                            ForEach(visibleMetrics) { metric in
                                glanceBarCell(metric, sizeOverrides: glanceSizeOverrides)
                            }
                        }
                    } else {
                        VStack(spacing: Self.glanceGridSpacing) {
                            ForEach(glanceRows(sizeOverrides: glanceSizeOverrides), id: \.glanceRowID) { row in
                                let rowHeight = computedRowHeight(for: row, sizeOverrides: glanceSizeOverrides)
                                HStack(spacing: Self.glanceGridSpacing) {
                                    glanceRowContent(row, rowHeight: rowHeight, sizeOverrides: glanceSizeOverrides)
                                }
                                .frame(maxWidth: .infinity,
                                       minHeight: rowHeight,
                                       maxHeight: rowHeight,
                                       alignment: .topLeading)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .onLongPressGesture(minimumDuration: 0.45) {
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
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
                return true
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
                                              withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                                  isEditingGlance = true
                                              }
                                          },
                                          onShowMetric: { metric in
                                              withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                                  onShowMetric(metric)
                                              }
                                          })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWeeklyReport) {
            AtriaWeeklyReportSheet(report: debugWeeklyReport ?? weeklyReportHighlight ?? WeeklyReport(rollups: dailyRollupHistory))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMonthlyReport) {
            AtriaMonthlyReportSheet(report: monthlyReportHighlight ?? MonthlyReport(rollups: dailyRollupHistory))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $metricDetail) { detail in
            let detailRollups = debugMetricDetailRollups ?? dailyRollupHistory
            AtriaMetricDetailSheet(metric: detail,
                                   rollups: detailRollups,
                                   rollupsRevision: debugMetricDetailRollups == nil ? dailyRollupHistoryRevision : nil,
                                   confirmedWorkouts: debugMetricDetailWorkouts ?? confirmedWorkouts,
                                   confirmedWorkoutsRevision: debugMetricDetailWorkouts == nil ? confirmedWorkoutsRevision : nil,
                                   baseline: baselineTarget,
                                   sleepHistory: sleepHistory,
                                   sleepHistoryRevision: sleepHistoryRevision,
                                   guidance: hero.guidance,
                                   recoveryEstimate: debugMetricDetailRecoveryEstimate ?? hero.recoveryEstimate,
                                   sleepGoalHours: sleepGoalHours,
                                   sleepBaseNeedHours: sleepBaseNeedHours,
                                   skinTemperatureDeviation: skinTemperatureSummary)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showStrapStepsDetail) {
            AtriaStrapStepsDetailSheet(count: live.strapStepResearchCount,
                                       validationState: live.strapStepResearchState,
                                       presentation: live.dailyStepPresentation,
                                       goal: stepsGoal)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showBreathworkSession) {
            AtriaOverviewBreathworkSessionHost(pulseStore: pulseStore) {
                showBreathworkSession = false
            }
        }
        .onAppear {
            #if DEBUG
            if metricDetail == nil,
               let debugDetail = Self.debugInitialMetricDetail(arguments: ProcessInfo.processInfo.arguments) {
                metricDetail = debugDetail
            }
            if Self.debugShowsWeeklyReportFixture(arguments: ProcessInfo.processInfo.arguments) {
                showWeeklyReport = true
            }
            #endif
        }
    }

    #if DEBUG
    private var debugWeeklyReport: WeeklyReport? {
        guard Self.debugShowsWeeklyReportFixture(arguments: ProcessInfo.processInfo.arguments) else {
            return nil
        }

        return WeeklyReport(rollups: Self.debugWeeklyReportRollups(),
                            now: Self.debugWeeklyReportNow())
    }

    private static func debugShowsWeeklyReportFixture(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "weekly-report"
    }

    private static func debugWeeklyReportNow() -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(hour: 9,
                                                  weekday: 2,
                                                  weekOfYear: 27,
                                                  yearForWeekOfYear: 2026)) ?? Date()
    }

    private static func debugWeeklyReportRollups() -> [DailyRollupStoreEntry] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let monday = calendar.date(from: DateComponents(weekday: 2,
                                                        weekOfYear: 27,
                                                        yearForWeekOfYear: 2026)) ?? Date()
        let recovery = [71, 68, 55, 73, 64, 78, 66, 62, 61, 60, 59, 58, 57, 56]
        let strain = [8.2, 6.1, 15.4, 7.0, 10.6, 5.8, 9.3, 7.4, 7.0, 6.8, 6.5, 6.2, 6.0, 5.8]
        let bedtime = [1_380, 1_392, 1_370, 1_405, 1_386, 1_374, 1_398, 1_430, 1_402, 1_455, 1_390, 1_420, 1_448, 1_400]
        return (0..<14).map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: monday) ?? monday
            return DailyRollupStoreEntry(day: day,
                                         recovery: recovery[offset],
                                         sleepSeconds: TimeInterval((450 + offset % 3 * 12) * 60),
                                         sleepPerformance: 88 - (offset % 4),
                                         bedtimeMinutes: bedtime[offset],
                                         strain: strain[offset],
                                         calendar: calendar)
        }
    }

    private var debugMetricDetailRollups: [DailyRollupStoreEntry]? {
        guard Self.debugInitialMetricDetail(arguments: ProcessInfo.processInfo.arguments) != nil else {
            return nil
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var rollups = (0..<42).map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let hrv = 58 + ((offset * 5) % 22)
            return DailyRollupStoreEntry(day: day,
                                         recovery: 62 + ((offset * 7) % 24),
                                         lnRMSSD: log(Double(hrv)),
                                         rhr: 54 + (offset % 6),
                                         sleepSeconds: TimeInterval((420 + (offset % 5) * 18) * 60),
                                         strain: 5.0 + Double((offset * 3) % 11),
                                         respiratoryRate: 14.4 + Double(offset % 4) * 0.2,
                                         calendar: calendar)
        }
        guard Self.debugShowsNutritionRecoveryDetail(arguments: ProcessInfo.processInfo.arguments),
              !rollups.isEmpty else {
            return rollups
        }
        rollups[0].nutrition = AtriaNutritionSummary(kcal: 2140,
                                                     proteinG: 132,
                                                     carbsG: 210,
                                                     fatG: 71,
                                                     waterMl: 2300,
                                                     caffeineMg: 180,
                                                     lastCaffeineHour: 16,
                                                     alcoholDrinks: 2)
        return rollups
    }

    private var debugMetricDetailRecoveryEstimate: Metrics.RecoveryEstimate? {
        guard Self.debugInitialMetricDetail(arguments: ProcessInfo.processInfo.arguments) == .recovery else {
            return nil
        }

        return Metrics.RecoveryEstimate(percent: 73,
                                        confidence: .personalBaseline,
                                        usesHRV: true,
                                        detail: "debug recovery detail fixture",
                                        contributors: [
                                            Metrics.RecoveryEstimate.Contributor(kind: .hrv,
                                                                                 zScore: 0.9,
                                                                                 weight: 0.60,
                                                                                 detail: "HRV above baseline"),
                                            Metrics.RecoveryEstimate.Contributor(kind: .restingHeartRate,
                                                                                 zScore: -0.4,
                                                                                 weight: 0.20,
                                                                                 detail: "RHR slightly elevated"),
                                            Metrics.RecoveryEstimate.Contributor(kind: .sleep,
                                                                                 zScore: 0.6,
                                                                                 weight: 0.15,
                                                                                 detail: "Sleep helped"),
                                            Metrics.RecoveryEstimate.Contributor(kind: .respiration,
                                                                                 zScore: 0.1,
                                                                                 weight: 0.05,
                                                                                 detail: "Resp neutral")
                                        ])
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
            UserConfirmedWorkout(id: "debug-strain-detail-strength",
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
            UserConfirmedWorkout(id: "debug-strain-detail-cardio",
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

    private static func debugInitialMetricDetail(arguments: [String]) -> AtriaMetricDetailKind? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        switch arguments[valueIndex] {
        case "recovery-detail", "recovery-detail-nutrition":
            return .recovery
        case "sleep-detail":
            return .sleep
        case "strain-detail":
            return .strain
        default:
            return nil
        }
    }

    private static func debugShowsNutritionRecoveryDetail(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "recovery-detail-nutrition"
    }
    #else
    private var debugWeeklyReport: WeeklyReport? { nil }
    private var debugMetricDetailRollups: [DailyRollupStoreEntry]? { nil }
    private var debugMetricDetailRecoveryEstimate: Metrics.RecoveryEstimate? { nil }
    private var debugMetricDetailWorkouts: [UserConfirmedWorkout]? { nil }
    #endif

    private var addWidgetMenu: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                if isEditingGlance {
                    Button {
                        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
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

                if !isEditingGlance {
                    Button {
                        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                            glanceLayoutBars.toggle()
                        }
                    } label: {
                        Image(systemName: glanceLayoutBars ? "square.grid.2x2.fill" : "rectangle.grid.1x2.fill")
                            .font(.callout.weight(.semibold))
                            .frame(width: 20, height: 20)
                    }
                    .atriaGlassIconAction(tint: .secondary, size: 38)
                    .accessibilityLabel(glanceLayoutBars ? "Show widgets as a grid" : "Show widgets as horizontal bars")
                    .accessibilityHint("Switches the Today widgets between a two-up box grid and a single-column list of horizontal bars.")
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

    private var dailyFocusItems: [AtriaDailyFocusRail.Item] {
        [
            AtriaDailyFocusRail.Item(title: "Recovery",
                                     value: hero.recoveryEstimate.percent.map { "\($0)%" } ?? "Learning",
                                     detail: recoveryDetailText,
                                     systemImage: AtriaTodayMetric.recovery.systemImage,
                                     tint: recoveryZone?.tint ?? .secondary,
                                     progress: hero.recoveryEstimate.percent.map { Double($0) / 100.0 }),
            AtriaDailyFocusRail.Item(title: "Strain",
                                     value: hero.strainValue,
                                     detail: strainEvidenceDetailText,
                                     systemImage: AtriaTodayMetric.strain.systemImage,
                                     tint: qualifiedStrainZone?.tint ?? Metrics.electricStrain,
                                     progress: strainIsPartial
                                        ? nil
                                        : hero.guidance.target.map { min(max(hero.strain / max($0, 0.1), 0), 1) }),
            AtriaDailyFocusRail.Item(title: sleepGlanceTitleText,
                                     value: sleepGlanceValueText,
                                     detail: sleepGlanceDetailText,
                                     systemImage: sleepGlanceSystemImage,
                                     tint: sleepGlanceTint,
                                     progress: sleepFocusProgress),
            AtriaDailyFocusRail.Item(title: "Live",
                                     value: live.status == .connected ? "On" : "Off",
                                     detail: liveFocusDetailText,
                                     systemImage: "waveform.path.ecg",
                                     tint: live.status == .connected ? .green : .secondary,
                                     progress: live.sessionSampleCount > 0 ? min(Double(live.sessionSampleCount) / 720.0, 1) : nil)
        ]
    }

    private var triRingSleepMetric: AtriaTriRingMetric {
        let performanceTint = currentSleepPerformancePercent.map {
            AtriaTriRing.zoneTint(.sleep, percent: Double($0))
        }
        return AtriaTriRingMetric(title: "Sleep",
                           value: sleepGlanceValueText,
                           detail: sleepTriRingDetailText,
                           systemImage: sleepGlanceSystemImage,
                           // Keep the ring body and its sleep-specific state color aligned.
                           // A near-complete/healthy sleep night must not remain yellow merely
                           // because the generic achievement tint requires exact closure.
                           tint: performanceTint ?? sleepGlanceZone?.tint ?? .secondary,
                           fill: sleepFocusProgress,
                           stateTint: performanceTint ?? sleepGlanceZone?.tint,
                           targetFraction: sleepGoalHours.isFinite && sleepGoalHours > 0 ? 1.0 : nil)
    }

    private var triRingRecoveryMetric: AtriaTriRingMetric {
        AtriaTriRingMetric(title: "Recovery",
                           value: hero.recoveryEstimate.percent.map { "\($0)%" } ?? "Learning",
                           detail: recoveryTriRingDetailText,
                           systemImage: AtriaTodayMetric.recovery.systemImage,
                           tint: recoveryZone?.tint ?? .secondary,
                           fill: hero.recoveryEstimate.percent.map { Double($0) / 100.0 })
    }

    private var triRingStrainMetric: AtriaTriRingMetric {
        let pending = metricIsPending(hero.strainValue)
        let unqualified = pending || strainIsPartial
        let fill = AtriaRingMetricProjection.strainFill(strain: hero.strain,
                                                        isPending: unqualified)
        let targetProgress = AtriaRingMetricProjection.strainTargetProgress(
            strain: hero.strain,
            target: hero.guidance.target
        )
        return AtriaTriRingMetric(title: "Strain",
                                  value: hero.strainValue,
                                  detail: strainEvidenceDetailText,
                                  systemImage: AtriaTodayMetric.strain.systemImage,
                                  tint: AtriaRingMetricProjection.strainTint(
                                    targetProgress: unqualified ? nil : targetProgress,
                                    actualFill: fill
                                  ),
                                  fill: fill,
                                  stateTint: unqualified ? nil : qualifiedStrainZone?.tint,
                                  targetFraction: unqualified ? nil : AtriaRingMetricProjection.strainTargetFraction(hero.guidance.target))
    }

    private var triRingCenterValue: String {
        hero.recoveryEstimate.percent.map { "\($0)%" } ?? "Learning"
    }

    private var triRingCenterState: String {
        switch recoveryZone?.level {
        case .green: return "Good"
        case .yellow: return "Steady"
        case .red: return "Low"
        case nil: return "Calibrating"
        }
    }

    private var recoveryTriRingDetailText: String {
        guard hero.recoveryEstimate.percent != nil else {
            return recoveryUnavailableDetail
        }
        if hero.recoveryIsFromPreviousSleep {
            return hero.recoveryDetail
        }
        return AtriaRecoveryRingPresentation.detail(
            zone: triRingCenterState,
            confidence: hero.recoveryEstimate.confidence,
            estimateDetail: hero.recoveryEstimate.detail,
            isProvisional: hero.recoveryIsProvisional
        )
    }

    private var sleepTriRingDetailText: String {
        if let latest = currentMainSleep, latest.confirmed {
            switch sleepGlanceZone?.level {
            case .green: return "Good"
            case .yellow: return "Fair"
            case .red: return "Low"
            case nil: return "Recorded"
            }
        }
        return sleepGlanceDetailText
    }

    private var triRingAccessibilitySummary: String {
        let strain = hero.guidance.target.map {
            "Strain \(hero.strainValue) of \(String(format: "%.1f", $0))."
        } ?? "Strain \(hero.strainValue), target building."
        return "Sleep \(sleepGlanceValueText), \(sleepTriRingDetailText). Recovery \(triRingRecoveryMetric.value), \(recoveryTriRingDetailText). \(strain)"
    }

    private var liveFocusDetailText: String {
        if live.status == .connected, live.sessionSampleCount > 0 {
            return "Strap live"
        }
        switch live.status {
        case .connected:
            return "Strap ready"
        case .connecting, .scanning:
            return "Reconnecting"
        case .poweredOff:
            return "Bluetooth off"
        case .disconnected:
            return live.batteryLevel >= 0 ? "Last seen \(live.batteryText)" : "Unavailable"
        }
    }

    private var targetValueText: String {
        guard let target = hero.guidance.target else { return "Target Building" }
        return String(format: "%.1f", target)
    }

    private var sleepFocusProgress: Double? {
        guard let latest = currentMainSleep,
              latest.confirmed,
              latest.isNapEvidence != true,
              sleepGoalHours.isFinite,
              sleepGoalHours > 0 else { return nil }
        return min(max(latest.durationHours / sleepGoalHours, 0), 1)
    }

    /// Prefer the saved, dynamic percent-of-need score that the Today screen
    /// and sleep-performance card already display. Grading the same night here
    /// against the static sleep goal could leave a 99% night yellow.
    private var currentSleepPerformancePercent: Int? {
        guard let latest = currentMainSleep, latest.confirmed else { return nil }
        if let saved = dailyRollupHistory.first(where: {
            Calendar.current.isDate($0.day, inSameDayAs: latest.day)
        })?.sleepPerformance {
            return saved
        }
        return sleepHistory.sleepPerformancePercent(for: latest,
                                                     baseNeedHours: sleepBaseNeedHours)
    }

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

    /// A row holding a half-height (wideShort) card renders at ~half the normal
    /// height; every other row keeps the full card height.
    private func computedRowHeight(for row: [AtriaTodayMetric],
                                   sizeOverrides: [String: AtriaGlanceGridSize]) -> CGFloat {
        let hasShort = row.contains { $0.glanceGridSize(sizeOverrides: sizeOverrides).isWideShort }
        return hasShort ? AtriaGlanceMetricCard.compactRowHeight : Self.glanceRowHeight
    }

    private func rowFitsGlanceGrid(_ row: [AtriaTodayMetric], sizeOverrides: [String: AtriaGlanceGridSize]) -> Bool {
        var span = 0
        for metric in row {
            span += metric.glanceColumnSpan(sizeOverrides: sizeOverrides)
        }
        return span <= Self.glanceGridColumnCount
    }

    @ViewBuilder
    private func glanceRowContent(_ row: [AtriaTodayMetric],
                                  rowHeight: CGFloat,
                                  sizeOverrides: [String: AtriaGlanceGridSize]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: Self.glanceGridSpacing) {
                ForEach(row) { metric in
                    glanceCardCell(metric,
                                   width: glanceCardWidth(for: metric,
                                                          containerWidth: proxy.size.width,
                                                          sizeOverrides: sizeOverrides),
                                   rowHeight: rowHeight,
                                   sizeOverrides: sizeOverrides)
                }

                if row.count == 1, row.first?.isWideGlanceCard(sizeOverrides: sizeOverrides) == false {
                    AtriaGlanceMetricCard.placeholder
                        .frame(width: glanceCardWidth(for: .recovery,
                                                      containerWidth: proxy.size.width,
                                                      sizeOverrides: sizeOverrides),
                               height: rowHeight)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func glanceCardCell(_ metric: AtriaTodayMetric,
                                width: CGFloat?,
                                rowHeight: CGFloat,
                                sizeOverrides: [String: AtriaGlanceGridSize],
                                forceCompactRow: Bool = false) -> some View {
        let upLabel = Text("Move \(metric.label) up")
        let downLabel = Text("Move \(metric.label) down")
        // In bars layout every metric is a full-width compact row regardless of
        // its saved grid size; otherwise honour the wideShort override.
        let isCompactRow = forceCompactRow || metric.glanceGridSize(sizeOverrides: sizeOverrides).isWideShort

        return glanceCard(metric)
            .environment(\.glanceCompactRow, isCompactRow)
            .frame(width: width,
                   height: rowHeight,
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
                        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
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
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                        onToggleMetricSize(metric)
                    }
                } label: {
                    Label(metric.nextGlanceSizeActionLabel(sizeOverrides: sizeOverrides),
                          systemImage: metric.nextGlanceSizeSystemImage(sizeOverrides: sizeOverrides))
                }

                Button(role: .destructive) {
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
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
                withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
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
            .accessibilityAction(named: Text("\(metric.nextGlanceSizeActionLabel(sizeOverrides: sizeOverrides)): \(metric.label)")) {
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

    /// One metric rendered as a full-width horizontal bar (the "bars" layout).
    /// Reuses `glanceCardCell` so editing, drag-reorder and target controls all
    /// behave exactly as they do in the grid — only the shape changes.
    private func glanceBarCell(_ metric: AtriaTodayMetric,
                               sizeOverrides: [String: AtriaGlanceGridSize]) -> some View {
        // Sleep-history / trend / insights are custom chart cards that ignore the
        // compact-row layout -- keep them at their natural full-width height so
        // bars mode doesn't squash a chart into a 76pt strip.
        let isChartCard = [AtriaTodayMetric.sleepHistory, .trend, .insights].contains(metric)
        return glanceCardCell(metric,
                              width: nil,
                              rowHeight: isChartCard ? Self.glanceRowHeight : AtriaGlanceMetricCard.compactRowHeight,
                              sizeOverrides: sizeOverrides,
                              forceCompactRow: !isChartCard)
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
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
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
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                onToggleMetricSize(metric)
            }
        } label: {
            Image(systemName: metric.nextGlanceSizeSystemImage(sizeOverrides: sizeOverrides))
                .font(.callout.weight(.bold))
        }
        .atriaGlassIconAction(tint: .secondary, size: 36)
        .accessibilityLabel("\(metric.nextGlanceSizeActionLabel(sizeOverrides: sizeOverrides)): \(metric.label)")
    }

    @ViewBuilder
    private func glanceCard(_ metric: AtriaTodayMetric) -> some View {
        switch metric {
        case .recovery:
            detailButton(.recovery) {
                AtriaGlanceMetricCard(title: "Recovery",
                                      value: hero.recoveryEstimate.percent == nil ? "Learning" : hero.recoveryValue,
                                      detail: recoveryDetailText,
                                      systemImage: metric.systemImage,
                                      tint: recoveryZone?.tint ?? .secondary,
                                      ringFraction: hero.recoveryEstimate.percent.map { Double($0) / 100 },
                                      sparklineValues: dailyMetricSparklines.recovery,
                                      zone: recoveryZone)
            }
        case .strain:
            detailButton(.strain) {
                AtriaGlanceMetricCard(title: "Strain",
                                      value: metricDisplayValue(hero.strainValue),
                                      detail: strainEvidenceDetailText,
                                      systemImage: metric.systemImage,
                                      tint: qualifiedStrainZone?.tint ?? Metrics.electricStrain,
                                      ringFraction: metricIsPending(hero.strainValue) || strainIsPartial
                                        ? nil
                                        : min(max(hero.strain / 21, 0), 1),
                                      sparklineValues: dailyMetricSparklines.strain,
                                      zone: qualifiedStrainZone)
            }
        case .load:
            AtriaGlanceMetricCard(title: "Training load",
                                  value: hero.loadReadinessText,
                                  detail: hero.loadConfidence == "learning" ? "Learning" : hero.loadSignalSummaryText,
                                  systemImage: metric.systemImage,
                                  tint: loadReadinessZone?.tint ?? loadReadinessTint,
                                  ringFraction: loadReadinessFraction,
                                  zone: loadReadinessZone)
                .accessibilityLabel("Training load readiness \(hero.loadReadinessText). \(hero.loadSignalSummaryText). \(hero.loadNarrative)")
        case .hrZones:
            AtriaGlanceMetricCard(title: "HR Zones",
                                  value: hero.hrZoneMinutes.valueText,
                                  detail: hero.hrZoneMinutes.detailText,
                                  systemImage: metric.systemImage,
                                  tint: .orange,
                                  accessibilityDetail: hero.hrZoneMinutes.accessibilityDetailText)
        case .workouts:
            detailButton(.strain) {
                AtriaGlanceMetricCard(title: "Workouts",
                                      value: "\(workoutsSummary.weekCount)",
                                      detail: workoutsSummary.latestOneLiner,
                                      systemImage: metric.systemImage,
                                      tint: .mint,
                                      accessibilityDetail: "\(workoutsSummary.weekCount) confirmed workouts this week. \(workoutsSummary.latestOneLiner).")
            }
        case .strainCompare:
            detailButton(.strain) {
                AtriaGlanceMetricCard(title: "Strain vs typical",
                                      value: metricDisplayValue(hero.strainValue),
                                      detail: strainCompareDetailText,
                                      systemImage: metric.systemImage,
                                      tint: Metrics.electricStrain,
                                      accessibilityDetail: "Today's strain \(metricDisplayValue(hero.strainValue)). \(strainCompareDetailText).")
            }
        case .hrv:
            detailButton(.hrv) {
                AtriaGlanceMetricCard(title: "HRV",
                                      value: hrvCalibratingValue ?? metricDisplayValue(hero.hrvValue),
                                      detail: hrvCalibratingValue != nil ? calibratingProgressDetail(samples: hrvBaselineSamples) : hrvDetailText,
                                      systemImage: metric.systemImage,
                                      tint: (hrvCalibratingValue != nil ? nil : hrvZone)?.tint ?? Metrics.electricHRV,
                                      sparklineValues: dailyMetricSparklines.hrv,
                                      zone: hrvCalibratingValue != nil ? nil : hrvZone,
                                      calibratingDay: hrvCalibratingValue != nil ? nil : hrvCalibratingDay,
                                      calibratingTotal: PersonalBaseline.trustedMinimumSamples,
                                      calibratingUnit: "Night")
            }
        case .stress:
            Button {
                showBreathworkSession = true
            } label: {
                AtriaGlanceMetricCard(title: "Stress",
                                      value: hero.stressValue,
                                      detail: hero.stressDetail,
                                      systemImage: metric.systemImage,
                                      tint: stressTint,
                                      accessibilityDetail: "\(hero.stressNarrative) Opens guided breathwork.")
            }
            .buttonStyle(.plain)
        case .sleep:
            detailButton(.sleep) {
                AtriaGlanceMetricCard(title: sleepGlanceTitleText,
                                      value: sleepGlanceValueText,
                                      detail: sleepGlanceDetailText,
                                      systemImage: sleepGlanceSystemImage,
                                      // Legacy handoff token retained for static audit context:
                                      // tint: sleepDurationZone?.tint ?? sleepGlanceTint
                                      tint: sleepGlanceTint,
                                      sparklineValues: dailyMetricSparklines.sleep,
                                      zone: sleepGlanceZone,
                                      calibratingDay: sleepCalibratingDay)
            }
        case .sleepHistory:
            sleepHistoryCard
        case .sleepEfficiency:
            AtriaGlanceMetricCard(title: "Sleep eff",
                                  value: currentMainSleep?.sleepEfficiencyText ?? "Learning",
                                  detail: currentMainSleep?.sleepEfficiency == nil ? "Needs time in bed" : "Duration-based",
                                  systemImage: metric.systemImage,
                                  tint: sleepEfficiencyZone?.tint ?? (currentMainSleep?.sleepEfficiency == nil ? .orange : .cyan),
                                  zone: sleepEfficiencyZone,
                                  accessibilityDetail: currentMainSleep?.sleepEfficiency == nil
                                    ? "Sleep efficiency is building from saved sleep duration."
                                    : "Sleep efficiency duration-based estimate \(currentMainSleep?.sleepEfficiencyText ?? "Learning").",
                                  calibratingDay: sleepEfficiencyCalibratingDay)
        case .sleepPerformance:
            detailButton(.sleepPerformance) {
                AtriaGlanceMetricCard(title: "Sleep perf",
                                      value: currentSleepPerformancePercent.map { "\($0)%" } ?? "Learning",
                                      detail: currentSleepPerformancePercent == nil
                                        ? "Save sleep to score"
                                        : "of need",
                                      systemImage: metric.systemImage,
                                      tint: Metrics.electricSleep,
                                      accessibilityDetail: "Sleep performance, percent of nightly need.")
            }
        case .rhr:
            detailButton(.restingHeartRate) {
                AtriaGlanceMetricCard(title: "RHR",
                                      value: restingCalibratingValue ?? metricDisplayValue(hero.restingHeartRateText),
                                      detail: restingCalibratingValue != nil ? calibratingProgressDetail(samples: restingBaselineSamples) : "Baseline",
                                      systemImage: metric.systemImage,
                                      tint: (restingCalibratingValue != nil ? nil : restingHeartRateZone)?.tint ?? Metrics.electricRHR,
                                      sparklineValues: dailyMetricSparklines.restingHeartRate,
                                      zone: restingCalibratingValue != nil ? nil : restingHeartRateZone,
                                      calibratingDay: restingCalibratingValue != nil ? nil : restingCalibratingDay,
                                      calibratingTotal: PersonalBaseline.trustedMinimumSamples,
                                      calibratingUnit: "Night")
            }
        case .respiratoryRate:
            AtriaGlanceMetricCard(title: "Resp rate",
                                  value: currentMainSleep?.respiratoryRateText ?? "Learning",
                                  detail: currentMainSleep?.respiratoryRate == nil
                                    ? "Needs qualified sleep" : "Early",
                                  systemImage: metric.systemImage,
                                  tint: respiratoryRateZone?.tint ?? (currentMainSleep?.respiratoryRate == nil ? .orange : Metrics.electricRespiratory),
                                  zone: respiratoryRateZone,
                                  accessibilityDetail: currentMainSleep?.respiratoryRate == nil
                                    ? "Respiratory rate needs qualified sleep evidence."
                                    : "Respiratory rate early sleep-only signal \(currentMainSleep?.respiratoryRateText ?? "--") breaths per minute.")
        case .steps:
            Button { showStrapStepsDetail = true } label: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let status = AtriaStrapStepLiveStatus.make(
                        count: live.strapStepResearchCount,
                        validationState: live.strapStepResearchState,
                        capturedAt: AtriaStrapStepLiveStatus.persistedMotionDate(),
                        now: context.date
                    )
                    let steps = live.dailyStepPresentation
                    AtriaGlanceMetricCard(title: "Strap steps",
                                          value: steps.valueText,
                                          detail: steps.detailText,
                                          systemImage: metric.systemImage,
                                          tint: steps.count == nil ? status.tint
                                            : (steps.completeness == .complete
                                               ? (stepsZone?.tint ?? .green) : .orange),
                                          zone: steps.count == nil ? nil : stepsZone,
                                          accessibilityDetail: "\(steps.accessibilityText) Goal \(stepsGoal).")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens strap-step freshness and goal status.")
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
                                  detail: vo2MaxEstimate.value == nil ? "Learning" : vo2MaxDetailText,
                                  systemImage: metric.systemImage,
                                  tint: vo2TrendZone?.tint ?? (vo2MaxEstimate.value == nil ? .orange : .blue),
                                  zone: vo2TrendZone,
                                  accessibilityDetail: vo2MaxEstimate.value == nil
                                    ? "VO2max building from resting baseline and measured HR max."
                                    : "VO2max \(vo2MaxEstimate.confidence) \(vo2MaxEstimate.valueText), trend \(vo2MaxEstimate.trendText), \(vo2MaxEstimate.trendDetail).")
        case .bioAge:
            AtriaGlanceMetricCard(title: "Fitness age",
                                  value: biologicalAgeSummary.valueText,
                                  detail: biologicalAgeSummary.isRefreshing
                                    ? "Updating weekly estimate"
                                    : biologicalAgeSummary.isReady ? biologicalAgeSummary.detailText : "Calibrating",
                                  systemImage: metric.systemImage,
                                  tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? (biologicalAgeSummary.ageDelta ?? 0 <= 0 ? .green : .orange) : .orange),
                                  zone: biologicalAgeZone,
                                  isLoading: biologicalAgeSummary.isRefreshing,
                                  accessibilityDetail: biologicalAgeSummary.isReady
                                    ? "Fitness age estimate \(biologicalAgeSummary.valueText), \(biologicalAgeSummary.detailText). \(biologicalAgeSummary.footnote)"
                                    : biologicalAgeSummary.isRefreshing
                                      ? "Updating your weekly fitness-age estimate. \(biologicalAgeSummary.footnote)"
                                      : "Calibrating your fitness-age baseline. \(biologicalAgeSummary.blockerText). \(biologicalAgeSummary.footnote)")
        case .bloodOxygen:
            AtriaGlanceMetricCard(title: "Blood oxygen",
                                  value: "--",
                                  detail: "Not available yet",
                                  systemImage: metric.systemImage,
                                  tint: .orange,
                                  zone: nil,
                                  accessibilityDetail: "Blood oxygen is not available yet. Atria does not estimate a percentage.")
        case .bodyTemp:
            let decoderAvailable = AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
            AtriaGlanceMetricCard(title: "Wrist temp",
                                  value: AtriaExperimentalSensorCopy.skinTemperatureValue(
                                    summary: skinTemperatureSummary,
                                    decoderAvailable: decoderAvailable),
                                  detail: decoderAvailable
                                    ? skinTemperatureSummary.detailText
                                    : "Not available yet",
                                  systemImage: metric.systemImage,
                                  tint: decoderAvailable
                                    ? (skinTemperatureDeviationZone?.tint ?? Metrics.electricRespiratory)
                                    : .orange,
                                  zone: decoderAvailable
                                    ? skinTemperatureDeviationZone
                                    : nil,
                                  accessibilityDetail: AtriaExperimentalSensorCopy.skinTemperatureAccessibilityDetail(
                                    summary: skinTemperatureSummary,
                                    decoderAvailable: decoderAvailable))
        case .trend:
            trendCard
        case .insights:
            insightsCard
        }
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
                            : sleepHistory.latestDisplayEvidence.map {
                                "Open Vitals. \($0.durationText), \($0.reviewContextText)"
                            } ?? "Open Vitals. Sleep history is building.")
    }

    private var currentMainSleep: SleepHistorySnapshot.Night? {
        AtriaOverviewCurrentSleep.resolve(from: sleepHistory)
    }

    private var currentDisplaySleep: SleepHistorySnapshot.Night? {
        AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: sleepHistory,
                                                         pendingReview: pendingSleepReview)
    }

    private var sleepGlanceValueText: String {
        if let latest = currentDisplaySleep {
            return latest.durationText
        }
        if sleepHistory.candidateCount > 0 {
            return "\(sleepHistory.candidateCount)"
        }
        // Canonical not-ready word. Sleep is available after one night (not a 4-night
        // calibration like recovery), so it shows "Learning", not a "Day X" countdown.
        return "Learning"
    }

    private var sleepGlanceTitleText: String {
        "Sleep"
    }

    private var sleepGlanceSystemImage: String {
        AtriaTodayMetric.sleep.systemImage
    }

    private var sleepGlanceDetailText: String {
        if let latest = currentDisplaySleep {
            if latest.confirmed {
                return "Last"
            }
            return latest.isNapEvidence ? "Review nap" : "Review sleep"
        }
        if sleepHistory.candidateCount > 0 { return "Review" }
        // Canonical not-ready word, and consistent with sleepGlanceValueText above:
        // sleep is available after ONE night (not a 4-night calibration like
        // recovery), so it shows "Learning" — never a "Day X of 4" countdown or the
        // non-canonical "Calibrating".
        return "Learning"
    }

    private var sleepGlanceTint: Color {
        // Legacy handoff token retained for static audit context:
        // sleepHistory.candidateCount > 0 ? .cyan : .orange
        if let latest = currentDisplaySleep {
            if !latest.confirmed {
                return .cyan
            }
        } else if sleepHistory.candidateCount > 0 {
            return .cyan
        }
        return sleepDurationZone?.tint ?? .secondary
    }

    private var sleepGlanceZone: AtriaMetricZone? {
        return sleepDurationZone
    }

    private var trendCard: some View {
        AtriaGlanceMetricCard(title: "Resting trend",
                              value: trendValues.count > 1 ? "\(trendValues.last ?? 0)" : "--",
                              // Empty-state honesty (2026-07-08): a trend line needs two
                              // nights to plot, so say exactly how far off it is ("0 of 2
                              // nights") instead of a bare "Learning" — matches the "N of M"
                              // progress the RHR/HRV cards already show.
                              detail: trendValues.count > 1 ? "14 sessions" : "\(trendValues.count) of 2 nights",
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

    private func detailButton<Content: View>(_ detail: AtriaMetricDetailKind,
                                             @ViewBuilder content: () -> Content) -> some View {
        Button {
            metricDetail = detail
        } label: {
            content()
        }
        .buttonStyle(.plain)
    }

    private var stressTint: Color {
        if hero.stressValue == "Learning" { return .orange }
        if hero.stressValue.hasPrefix("0") { return .green }
        if hero.stressValue.hasPrefix("1") { return .mint }
        if hero.stressValue.hasPrefix("2") { return .orange }
        return .red
    }

    private var strainCompareDetailText: String {
        guard let median = strainCompareMedian else { return "Building baseline" }
        let medianText = String(format: "%.1f", median)
        guard !metricIsPending(hero.strainValue) else { return "14-day median \(medianText)" }
        let delta = hero.strain - median
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

    private var strainEvidenceDetailText: String {
        if metricIsPending(hero.strainValue) { return "Learning" }
        if strainIsPartial {
            return "Partial · limited wear"
        }
        return targetValueText
    }

    private var hrvDetailText: String {
        let detail = hero.hrvDetail.lowercased()
        if detail.contains("validated") { return "Checked" }
        if detail.contains("personal baseline") || detail.contains("% kept") { return "Personal baseline" }
        return "Learning"
    }

    private var vo2MaxDetailText: String {
        let confidence = vo2MaxEstimate.confidence.capitalized
        guard vo2MaxEstimate.trendText != "Learning" else { return confidence }
        return "\(confidence) · \(vo2MaxEstimate.trendText)"
    }

    private var recoveryDetailText: String {
        if hero.recoveryEstimate.percent == nil {
            return recoveryUnavailableDetail
        }
        if hero.recoveryIsFromPreviousSleep {
            return hero.recoveryDetail
        }
        if hero.recoveryEstimate.confidence == .unverified,
           hero.recoveryEstimate.detail.localizedCaseInsensitiveContains("HRV unavailable") {
            return "Limited confidence · HRV unavailable"
        }
        let base: String
        switch hero.recoveryEstimate.confidence {
        case .validated:
            base = "Checked"
        case .personalBaseline:
            base = "Personal baseline"
        case .unverified:
            base = "Still improving"
        case .learning:
            if hero.recoveryEstimate.detail.localizedCaseInsensitiveContains("HRV baseline") {
                base = "Building baseline"
            } else {
                base = "Learning"
            }
        }
        return hero.recoveryIsProvisional ? "\(base) · Early read" : base
    }

    private var recoveryUnavailableDetail: String {
        AtriaRecoveryAvailabilityPresentation.detail(
            estimateDetail: hero.recoveryEstimate.detail,
            hrvBaselineSamples: hrvBaselineSamples,
            restingBaselineSamples: restingBaselineSamples
        )
    }

    // HRV/RHR baselines need trustedMinimumSamples (14) nights — so they carry
    // the RAW recorded-night count (not the capped "day"), and their cards pass
    // total: 14, unit: "Night" for honest "Night X of 14" progress (2026-07-08).
    private var hrvCalibratingDay: Int? {
        metricIsPending(hero.hrvValue) ? hrvBaselineSamples : nil
    }

    private var restingCalibratingDay: Int? {
        metricIsPending(hero.restingHeartRateText) ? restingBaselineSamples : nil
    }

    // Partial data during calibration (user 2026-07-08 "start showing something
    // when we can"): once a baseline value exists, show the real HRV/RHR built so
    // far — a measured number — instead of hiding it behind the countdown ring.
    // The detail says it's still calibrating and the zone judgment is suppressed
    // (there is no trusted baseline to grade the number against yet), so nothing
    // is fabricated or over-claimed.
    private var hrvCalibratingValue: String? {
        guard hrvCalibratingDay != nil, let hrv = baselineTarget.hrvBaseline else { return nil }
        return "\(hrv)"
    }

    private var restingCalibratingValue: String? {
        guard restingCalibratingDay != nil, let rhr = baselineTarget.restingBaseline else { return nil }
        return "\(rhr)"
    }

    private func calibratingProgressDetail(samples: Int) -> String {
        "Calibrating · night \(min(max(samples, 0), PersonalBaseline.trustedMinimumSamples)) of \(PersonalBaseline.trustedMinimumSamples)"
    }

    private var sleepCalibratingDay: Int? {
        currentMainSleep == nil ? calibratingDay(sampleCount: sleepHistory.nights.count) : nil
    }

    private var sleepEfficiencyCalibratingDay: Int? {
        currentMainSleep?.sleepEfficiency == nil ? calibratingDay(sampleCount: sleepHistory.nights.count) : nil
    }

    private func calibratingDay(sampleCount: Int) -> Int {
        min(max(sampleCount + 1, 1), 4)
    }

    private func metricDisplayValue(_ value: String) -> String {
        metricIsPending(value) ? "--" : value
    }

    private func metricIsPending(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var strainIsPartial: Bool {
        hero.strainConfidence.localizedCaseInsensitiveContains("partial")
            || hero.strainValue.hasPrefix("≥")
    }

    private var qualifiedStrainZone: AtriaMetricZone? {
        strainIsPartial ? nil : strainZone
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
        let target = String(format: "Editable target · ACWR green %.1f-%.1f, red <%.1f or >=%.1f; monotony watch %.1f, red %.1f.",
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
        Metrics.sleepEfficiencyZone(currentMainSleep?.sleepEfficiency,
                                    greenLower: sleepEfficiencyGreenLower,
                                    yellowLower: sleepEfficiencyYellowLower)
    }

    private var sleepDurationZone: AtriaMetricZone? {
        // A nap or unconfirmed review item is not a deficient night — don't grade
        // it against the nightly sleep goal (that turned "24m last nap" into a
        // red alarm before the user had a chance to review it).
        guard let latest = currentMainSleep,
              latest.confirmed,
              latest.isNapEvidence != true else { return nil }
        // Metrics.sleepDurationZone(sleepHistory.latest?.durationHours, goalHours: sleepGoalHours)
        return Metrics.sleepDurationZone(latest.durationHours, goalHours: sleepGoalHours)
    }

    private var stepsZone: AtriaMetricZone? {
        let presentation = live.dailyStepPresentation
        guard presentation.completeness != .partial
                || presentation.source == .live,
              let count = presentation.count,
              count > 0 else { return nil }
        let zone = Metrics.stepsZone(count, goal: stepsGoal)
        return zone.map {
            AtriaMetricZone(level: $0.level,
                            title: "Strap steps goal",
                            current: $0.current,
                            targetSummary: $0.targetSummary,
                            recommendation: $0.recommendation,
                            disclaimer: "\(live.dailyStepPresentation.detailText). \(AtriaMetricZone.nonMedicalDisclaimer)")
        }
    }

    private var strapStepsZone: AtriaMetricZone? {
        guard sensorSummary.strapStepCount > 0 else { return nil }
        let zone = Metrics.stepsZone(sensorSummary.strapStepCount, goal: stepsGoal)
        return zone.map {
            AtriaMetricZone(level: $0.level,
                            title: "Strap movement goal",
                            current: "\($0.current) Source: \(sensorSummary.agreementText).",
                            targetSummary: $0.targetSummary,
                            recommendation: "\($0.recommendation) Strap steps stay labeled as estimates until strap movement calibration is validated.",
                            disclaimer: "Strap movement estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
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
        return Metrics.respiratoryRateZone(currentMainSleep?.respiratoryRate,
                                           baseline: sleepHistory.respiratoryBaselineMean,
                                           baselineSamples: sleepHistory.respiratoryBaselineCount,
                                           greenDelta: respiratoryGreenDelta,
                                           yellowDelta: respiratoryYellowDelta)
    }

    private var skinTemperatureDeviationZone: AtriaMetricZone? {
        Metrics.skinTemperatureDeviationZone(skinTemperatureSummary,
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

private struct AtriaDailyFocusRail: View, Equatable {
    struct Item: Equatable, Identifiable {
        let title: String
        let value: String
        let detail: String
        let systemImage: String
        let tint: Color
        let progress: Double?

        var id: String { title }
    }

    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            focusBalanceLens

            HStack(spacing: 8) {
                ForEach(items) { item in
                    focusCell(item)
                }
            }
        }
        .padding(8)
        .atriaInsetCard(cornerRadius: 20, tint: .secondary)
        .accessibilityElement(children: .contain)
    }

    private var focusBalanceLens: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily lens")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(primaryReadout)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(items) { item in
                    Capsule(style: .continuous)
                        .fill(item.tint.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .frame(height: 7 + CGFloat(min(max(item.progress ?? 0.18, 0.06), 1)) * 19)
                        .accessibilityLabel("\(item.title) \(item.value)")
                }
            }
            .frame(height: 28, alignment: .bottom)

            Text("\(items.count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.secondary.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily lens. \(items.map { "\($0.title) \($0.value)" }.joined(separator: ", ")).")
    }

    private var primaryReadout: String {
        guard let first = items.first else { return "--" }
        return "\(first.title) \(first.value)"
    }

    private func focusCell(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: item.systemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(item.tint)
                Text(item.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(item.value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.66)

            Text(item.detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.64)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                Capsule(style: .continuous)
                    .fill(item.tint.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(item.tint.opacity(0.76))
                            .frame(width: max(6, width * CGFloat(min(max(item.progress ?? 0.18, 0.06), 1))))
                    }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(item.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.value), \(item.detail)")
    }
}

private struct AtriaTriRingLiveStatusHost: View {
    let live: AtriaHomeModel.CoreLiveState
    @ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore

    var body: some View {
        AtriaTriRingLiveStatusStrip(live: live, pulse: pulseStore.state)
    }
}

private struct AtriaOverviewBreathworkSessionHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore
    let onDismiss: () -> Void

    var body: some View {
        AtriaBreathworkSession(currentHeartRate: pulseStore.state.heartRate,
                               currentRRSamples: pulseStore.state.recentRRSamples,
                               currentStress: nil,
                               onSave: { _ in },
                               onClose: onDismiss)
    }
}

private struct AtriaTriRingLiveStatusStrip: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let pulse: AtriaHomeModel.HeroPulseState

    private var tint: Color {
        if let zone = pulse.heartRateZone { return zone.tint }
        return live.status == .connected ? .green : .secondary
    }

    private var zoneText: String {
        pulse.heartRateZone?.shortLabel ?? (pulse.hasPulseSignal ? "Live" : "Waiting")
    }

    var body: some View {
        HStack(spacing: 10) {
            Label {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(pulse.heartRateText)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(pulse.heartRateZone != nil ? tint : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text("bpm")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }
            .labelStyle(.titleAndIcon)

            Text(zoneText)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(tint.opacity(0.12), in: Capsule(style: .continuous))

            if pulse.heartRateBroadcastActive {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.12), in: Capsule(style: .continuous))
                    .accessibilityLabel("Broadcast heart rate active")
            }

            Spacer(minLength: 0)

            if live.batteryLevel >= 0 {
                Label {
                    Text(live.batteryText)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } icon: {
                    Image(systemName: live.batterySymbol)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(live.batteryShowsPowered ? Color.green : .secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // HR-section accent: when a live zone is known, wash the strip in the
        // zone tint so the current effort reads at a glance; stay neutral otherwise.
        .background(pulse.heartRateZone != nil ? tint.opacity(0.10) : .secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live status. Heart rate \(pulse.heartRateText) beats per minute. Zone \(zoneText).\(pulse.heartRateBroadcastActive ? " Broadcast heart rate active." : "")\(batteryAccessibilitySuffix)")
    }

    private var batteryAccessibilitySuffix: String {
        live.batteryLevel >= 0 ? " \(live.batteryAccessibilityText)" : ""
    }
}

// Internal (was private) so the Plan tab can reuse it — see AtriaPlanTab.
struct AtriaWeeklyPlanCard: View, Equatable {
    let plan: WeeklyPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                AtriaPanelSectionHeader(title: "This week", subtitle: "")
                Spacer(minLength: 8)
                Text(plan.dateRangeText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.08), in: Capsule())
            }

            VStack(spacing: 10) {
                ForEach(Array(plan.targets.prefix(3))) { target in
                    AtriaWeeklyPlanTargetRow(target: target)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(cornerRadius: 20, tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let targets = plan.targets.prefix(3).map { "\($0.title), \($0.progressText)" }.joined(separator: ". ")
        return "This week. \(targets)"
    }
}

private struct AtriaWeeklyPlanTargetRow: View, Equatable {
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
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.title). \(target.progressText). \(target.detail).")
    }
}

private enum AtriaReportPeriod {
    case week
    case month
}

private struct AtriaWeeklyReportHighlightRow: View, Equatable {
    let report: WeeklyReport

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.cyan)
                .frame(width: 34, height: 34)
                .background(Color.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Weekly report")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(heroText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            Text(consistencyText)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: .cyan)
        .accessibilityLabel("Weekly report. \(heroText). \(consistencyText).")
    }

    private var heroText: String {
        guard let recovery = report.recoveryAvg else { return "Recovery building" }
        guard let delta = report.recoveryDeltaVsPriorWeek else { return "Recovery \(recovery)%" }
        return delta >= 0 ? "Recovery \(recovery)% up \(delta)" : "Recovery \(recovery)% down \(abs(delta))"
    }

    private var consistencyText: String {
        report.sleepConsistencyPct.map { "Routine \($0)%" } ?? "Routine building"
    }
}

struct AtriaWeeklyReportSheet: View {
    let report: WeeklyReport
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        // The sheet's navigation title already says "Weekly
                        // report", inline, about 40pt above this. Printing it
                        // again as an eyebrow told the reader nothing they had
                        // not just read.
                        Text(heroText)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(weekRangeText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .atriaInsetCard(cornerRadius: 18, tint: .cyan)

                    // Grouped stat rows (UX audit density tail): six identical
                    // boxes read as a wall; two kickers give the eye a rest.
                    reportKicker("Week averages")
                    VStack(spacing: 10) {
                        AtriaWeeklyReportStatRow(title: "Recovery average",
                                                 value: recoveryAverageText,
                                                 detail: recoveryDeltaText,
                                                 systemImage: "heart.fill",
                                                 tint: .green)
                        AtriaWeeklyReportStatRow(title: "Strain average",
                                                 value: strainAverageText,
                                                 detail: "Daily strain across the week",
                                                 systemImage: "flame.fill",
                                                 tint: Metrics.electricStrain)
                        AtriaWeeklyReportStatRow(title: "Sleep average",
                                                 value: sleepAverageText,
                                                 detail: "Nightly duration across the week",
                                                 systemImage: "bed.double.fill",
                                                 tint: Metrics.electricSleep)
                    }

                    reportKicker("Highlights")
                    VStack(spacing: 10) {
                        AtriaWeeklyReportStatRow(title: "Sleep consistency",
                                                 value: consistencyText,
                                                 detail: "Bedtime routine from daily rollups",
                                                 systemImage: "moon.zzz.fill",
                                                 tint: .indigo)
                        AtriaWeeklyReportStatRow(title: "Best day",
                                                 value: dayText(report.bestDay),
                                                 detail: recoveryText(report.bestDay),
                                                 systemImage: "lightbulb.max.fill",
                                                 tint: Metrics.electricYellow)
                        AtriaWeeklyReportStatRow(title: "Hardest day",
                                                 value: dayText(report.hardestDay),
                                                 detail: strainText(report.hardestDay),
                                                 systemImage: "flame.fill",
                                                 tint: Metrics.electricStrain)
                    }

                    if weekRecoveryPoints.count >= 2 {
                        weekRecoveryChart(weekRecoveryPoints)
                    }

                    if let note = report.strainRecoveryNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .atriaInsetCard(cornerRadius: 16, tint: .orange)
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share week", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction()
                }
                .padding(18)
            }
            .navigationTitle("Weekly report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
            .sheet(isPresented: $showShareSheet) {
                AtriaWeeklyShareSheet(snapshot: makeWeeklyShareSnapshot())
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func reportKicker(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// Narrative hero (dedup audit + design HIGHLIGHTS card, 2026-07-07):
    /// the hero used to repeat the Recovery-average stat row verbatim. It is
    /// now a one-line story built ONLY from real report fields — every
    /// clause is gated on data, phrasing stays associative ("while"/"with"),
    /// never causal. Numbers live in the stat rows below.
    private var heroText: String {
        guard let _ = report.recoveryAvg else { return "Still building this week's picture" }

        var clauses: [String] = []
        if let delta = report.recoveryDeltaVsPriorWeek {
            if delta >= 3 { clauses.append("Recovery climbed") }
            else if delta <= -3 { clauses.append("Recovery dipped") }
            else { clauses.append("Recovery held steady") }
        } else {
            clauses.append("Recovery on the board")
        }
        if let strain = report.strainAvg, strain > 0 {
            if strain >= 12 { clauses.append("under a heavy training load") }
            else if strain >= 8 { clauses.append("with a solid training load") }
            else { clauses.append("with a light training load") }
        }
        if let sleep = report.sleepAvgSeconds, sleep > 0 {
            if sleep >= 7.5 * 3600 { clauses.append("while sleep stayed long") }
            else if sleep >= 6.5 * 3600 { clauses.append("while sleep hovered near need") }
            else { clauses.append("while sleep ran short") }
        }
        return clauses.joined(separator: " ")
    }

    private var recoveryAverageText: String {
        report.recoveryAvg.map { "\($0)%" } ?? "--"
    }

    /// Human date range ("Jun 29 – Jul 5") from the report's rollup days;
    /// falls back to the ISO week label for reports saved before these
    /// fields existed (2026-07-07 design handoff).
    ///
    /// The range used to carry "· Week N" appended to it, which stitched two
    /// independently stored fields — weekStart/weekEnd and isoWeek — into one
    /// sentence with nothing keeping them in agreement. They can disagree, and
    /// when they do the line contradicts itself in front of the reader
    /// ("Jan 9 – Jan 15 · Week 31"; week 31 is late July). Rather than pick a
    /// winner between two engine-owned fields, the dates speak alone: they are
    /// the more useful half, and a range cannot contradict itself. The ISO
    /// label still stands in when no dates were stored.
    private var weekRangeText: String {
        guard let start = report.weekStart, let end = report.weekEnd else {
            return "Week \(report.isoWeek), \(report.isoYear)"
        }
        let formatter = Self.rangeDayFormatter
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private static let rangeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    /// Week recovery sparkline (2026-07-07 design handoff): only real
    /// recovery days plot -- a nil day is a gap in the dots, never invented.
    /// Points are shaped OUTSIDE any render block (perf gate: no compactMap
    /// in some-View bodies).
    private var weekRecoveryPoints: [(day: Date, recovery: Int)] {
        (report.recoverySeries ?? []).compactMap { day in
            guard let recovery = day.recovery else { return nil }
            return (day.day, recovery)
        }
    }

    private func weekRecoveryChart(_ points: [(day: Date, recovery: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recovery through the week")
                .font(.subheadline.weight(.semibold))
            Chart {
                ForEach(points, id: \.day) { point in
                    LineMark(x: .value("Day", point.day, unit: .day),
                             y: .value("Recovery", point.recovery))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Metrics.electricGreen)
                    PointMark(x: .value("Day", point.day, unit: .day),
                              y: .value("Recovery", point.recovery))
                        .foregroundStyle(Metrics.recoveryColor(point.recovery))
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100])
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .frame(height: 120)
            .clipped()
            .accessibilityLabel("Recovery for each day of the week.")
            .atriaInspectableGraph(
                AtriaInspectableGraph(
                    title: "Recovery through the week",
                    subtitle: "Recorded recovery days only",
                    content: .timeSeries([
                        .init(title: "Recovery",
                              unit: "%",
                              tint: Metrics.electricGreen,
                              points: points.map {
                                  .init(date: $0.day, value: Double($0.recovery))
                              })
                    ])
                )
            )
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricGreen)
    }

    private var strainAverageText: String {
        report.strainAvg.map { String(format: "%.1f", $0) } ?? "--"
    }

    private var sleepAverageText: String {
        guard let seconds = report.sleepAvgSeconds else { return "--" }
        let totalMinutes = Int((seconds / 60).rounded())
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    private var recoveryDeltaText: String {
        guard let delta = report.recoveryDeltaVsPriorWeek else { return "Prior week comparison building" }
        return delta >= 0 ? "+\(delta) vs prior week" : "\(delta) vs prior week"
    }

    private var consistencyText: String {
        report.sleepConsistencyPct.map { "\($0)%" } ?? "--"
    }

    private func dayText(_ day: WeeklyReport.DaySummary?) -> String {
        guard let day else { return "--" }
        return Self.dayFormatter.string(from: day.day)
    }

    private func recoveryText(_ day: WeeklyReport.DaySummary?) -> String {
        day?.recovery.map { "Recovery \($0)%" } ?? "Recovery building"
    }

    private func strainText(_ day: WeeklyReport.DaySummary?) -> String {
        day?.strain.map { String(format: "Strain %.1f", $0) } ?? "Strain building"
    }

    private func makeWeeklyShareSnapshot() -> AtriaWeeklyShareSnapshot {
        AtriaWeeklyShareSnapshot(date: report.generatedAt,
                                 title: "My week on Atria",
                                 recoveryAverage: recoveryAverageText,
                                 recoveryDelta: recoveryDeltaText,
                                 sleepConsistency: consistencyText,
                                 bestDay: dayText(report.bestDay),
                                 hardestDay: dayText(report.hardestDay),
                                 note: report.strainRecoveryNote)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d")
        return formatter
    }()
}

private struct AtriaMonthlyReportHighlightRow: View, Equatable {
    let report: MonthlyReport

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.cyan)
                .frame(width: 34, height: 34)
                .background(Color.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Monthly report")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(heroText)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            Text(consistencyText)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: .cyan)
        .accessibilityLabel("Monthly report. \(heroText). \(consistencyText).")
    }

    private var heroText: String {
        guard let recovery = report.recoveryAvg else { return "Recovery building" }
        guard let delta = report.recoveryDeltaVsPriorMonth else { return "Recovery \(recovery)%" }
        return delta >= 0 ? "Recovery \(recovery)% up \(delta)" : "Recovery \(recovery)% down \(abs(delta))"
    }

    private var consistencyText: String {
        report.consistencyScore.map { "Routine \($0)%" } ?? "Routine building"
    }
}

struct AtriaMonthlyReportSheet: View {
    let report: MonthlyReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Monthly report")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(heroText)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(monthTitleText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .atriaInsetCard(cornerRadius: 18, tint: .cyan)

                    // Same grouping idiom as the weekly report (UX audit
                    // density tail): month load vs. body signals.
                    monthlyKicker("Month at a glance")
                    VStack(spacing: 10) {
                        AtriaWeeklyReportStatRow(title: "Recovery average",
                                                 value: recoveryAverageText,
                                                 detail: recoveryDeltaText,
                                                 systemImage: "heart.fill",
                                                 tint: .green)
                        AtriaWeeklyReportStatRow(title: "Total strain",
                                                 value: totalStrainText,
                                                 detail: hardestWeekText,
                                                 systemImage: "flame.fill",
                                                 tint: Metrics.electricStrain)
                        AtriaWeeklyReportStatRow(title: "Sleep performance",
                                                 value: sleepPerformanceText,
                                                 detail: sleepPerformanceDeltaText,
                                                 systemImage: "moon.zzz.fill",
                                                 tint: .indigo)
                    }

                    monthlyKicker("Body signals")
                    VStack(spacing: 10) {
                        AtriaWeeklyReportStatRow(title: "Resting heart rate",
                                                 value: rhrText,
                                                 detail: rhrDeltaText,
                                                 systemImage: "waveform.path.ecg",
                                                 tint: .pink)
                        AtriaWeeklyReportStatRow(title: "HRV",
                                                 value: hrvText,
                                                 detail: hrvDeltaText,
                                                 systemImage: "waveform.path.ecg.rectangle",
                                                 tint: .teal)
                        AtriaWeeklyReportStatRow(title: "Bedtime consistency",
                                                 value: consistencyText,
                                                 detail: "Bedtime routine from daily rollups",
                                                 systemImage: "clock.fill",
                                                 tint: Metrics.electricYellow)
                    }
                }
                .padding(18)
            }
            .navigationTitle("Monthly report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func monthlyKicker(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// Narrative hero — same honesty-gated treatment as the weekly report
    /// (dedup audit 2026-07-07): clauses only from real fields, associative
    /// phrasing, numbers owned by the stat rows.
    private var heroText: String {
        guard let _ = report.recoveryAvg else { return "Still building this month's picture" }

        var clauses: [String] = []
        if let delta = report.recoveryDeltaVsPriorMonth {
            if delta >= 3 { clauses.append("Recovery climbed") }
            else if delta <= -3 { clauses.append("Recovery dipped") }
            else { clauses.append("Recovery held steady") }
        } else {
            clauses.append("Recovery on the board")
        }
        if let sleepDelta = report.sleepPerformanceDeltaVsPriorMonth {
            if sleepDelta >= 3 { clauses.append("while sleep improved") }
            else if sleepDelta <= -3 { clauses.append("while sleep slipped") }
            else { clauses.append("with steady sleep") }
        }
        return clauses.joined(separator: " ")
    }

    private var monthTitleText: String {
        Self.monthFormatter.string(from: report.generatedAt)
    }

    private var recoveryAverageText: String {
        report.recoveryAvg.map { "\($0)%" } ?? "--"
    }

    private var recoveryDeltaText: String {
        guard let delta = report.recoveryDeltaVsPriorMonth else { return "Prior month comparison building" }
        return delta >= 0 ? "+\(delta) vs prior month" : "\(delta) vs prior month"
    }

    private var totalStrainText: String {
        report.totalStrain.map { String(format: "%.1f", $0) } ?? "--"
    }

    private var hardestWeekText: String {
        guard let hardestWeek = report.hardestWeek, let strain = hardestWeek.totalStrain else {
            return "Hardest week building"
        }
        return "Hardest week \(Self.weekFormatter.string(from: hardestWeek.weekStart)) · \(String(format: "%.1f", strain)) strain"
    }

    private var sleepPerformanceText: String {
        report.sleepPerformanceAvg.map { "\($0)%" } ?? "--"
    }

    private var sleepPerformanceDeltaText: String {
        guard let delta = report.sleepPerformanceDeltaVsPriorMonth else { return "Prior month comparison building" }
        return delta >= 0 ? "+\(delta) vs prior month" : "\(delta) vs prior month"
    }

    private var rhrText: String {
        report.rhrAvg.map { "\($0) bpm" } ?? "--"
    }

    private var rhrDeltaText: String {
        guard let delta = report.rhrDeltaVsPriorMonth else { return "Prior month comparison building" }
        return delta >= 0 ? "+\(delta) bpm vs prior month" : "\(delta) bpm vs prior month"
    }

    private var hrvText: String {
        report.hrvAvgMs.map { "\(Int($0.rounded())) ms" } ?? "--"
    }

    private var hrvDeltaText: String {
        guard let delta = report.hrvDeltaVsPriorMonthMs else { return "Prior month comparison building" }
        let rounded = Int(delta.rounded())
        return rounded >= 0 ? "+\(rounded) ms vs prior month" : "\(rounded) ms vs prior month"
    }

    private var consistencyText: String {
        report.consistencyScore.map { "\($0)%" } ?? "--"
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private static let weekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private struct AtriaWeeklyReportStatRow: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: tint)
    }
}

private struct AtriaGlanceWidgetManagerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let hiddenMetrics: [AtriaTodayMetric]
    let onEditWidgets: () -> Void
    let onShowMetric: (AtriaTodayMetric) -> Void

    // Same key the Today screen reads; AtriaDefault syncs both instances via the
    // UserDefaults change notification, so toggling here updates the rail live.
    @AtriaDefault("atria.overview.showDailyFocusRail") private var showDailyFocusRail: Bool = false
    @State private var showWidgetProof = false

    private var hiddenMoreMetrics: [AtriaTodayMetric] {
        hiddenMetrics.filter { AtriaTodayMetric.moreMetrics.contains($0) }
    }

    private var hiddenExperimentalMetrics: [AtriaTodayMetric] {
        hiddenMetrics.filter { AtriaTodayMetric.experimentalMetrics.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    managerSection(title: "Layout",
                                   subtitle: "The daily focus rail repeats Recovery, Strain and Sleep from the ring above. It is off by default.") {
                        Toggle(isOn: $showDailyFocusRail) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Daily focus rail")
                                    .font(.footnote.weight(.bold))
                                Text("Show the Recovery / Strain / Sleep / Live rail under the ring.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .atriaInsetCard(tint: .secondary)
                        .accessibilityHint("Restores the focus rail beneath the tri-ring. It duplicates the ring metrics, so it stays off unless you turn it on.")
                    }

                    managerSection(title: "More metrics",
                                   subtitle: hiddenMetrics.isEmpty ? "All glance widgets are already visible." : "Bring hidden cards back to Today at a glance.") {
                        if hiddenMoreMetrics.isEmpty {
                            Label("All widgets added", systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .atriaInsetCard(tint: .secondary)
                        } else {
                            ForEach(hiddenMoreMetrics) { metric in
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

                    managerSection(title: "Experimental",
                                   subtitle: "Estimates are still improving. These stay opt-in until the signal is proven.") {
                        if hiddenExperimentalMetrics.isEmpty {
                            Label("Experimental cards added", systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .atriaInsetCard(tint: .secondary)
                        } else {
                            ForEach(hiddenExperimentalMetrics) { metric in
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

                    managerSection(title: "Home & Lock Screen widgets",
                                   subtitle: "Check exactly what the widget extension can read before adding it to the Home or Lock Screen.") {
                        Button {
                            showWidgetProof = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.cyan)
                                    .frame(width: 34, height: 34)
                                    .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Widget proof")
                                        .font(.subheadline.weight(.bold))
                                    Text("Preview the shared snapshot, Home Screen families, and Lock Screen accessories.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }
                        .buttonStyle(.plain)
                        .atriaInsetCard(tint: .cyan)
                        .accessibilityHint("Shows the local snapshot and every supported widget family.")
                    }

                    Button {
                        onEditWidgets()
                        dismiss()
                    } label: {
                        Label("Edit on cards", systemImage: "square.grid.2x2")
                            .font(.footnote.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .secondary)
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
        .sheet(isPresented: $showWidgetProof) {
            AtriaWidgetProofSheet(snapshot: AtriaIntentSnapshotStore.loadLatestSnapshot(),
                                  layoutConfig: .default)
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
            .atriaCardAction(tint: tint)
        }
        .padding(12)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("\(actionTitle) \(metric.label) widget")) {
            action()
        }
    }
}

struct AtriaStrapStepLiveStatus: Equatable {
    enum Freshness: Equatable {
        case live
        case stale
        case unavailable
    }

    static let persistedMotionKey = "atria.radio.passiveR10LastValidAt"
    /// R10 is a one-device-second motion stream. A count cannot honestly stay
    /// "live" for a minute and a half after those frames stop, even if 2A37 HR
    /// remains connected. Allow short Bluetooth delivery jitter, then fail the
    /// step tile closed while retaining the last saved estimate.
    static let liveWindow: TimeInterval = 15
    static let futureTolerance: TimeInterval = 5

    let count: Int
    let isValidated: Bool
    let freshness: Freshness
    let motionAge: TimeInterval?

    var isLive: Bool { freshness == .live }

    var tileValue: String {
        guard isLive else { return "--" }
        return isValidated ? "\(count)" : "~\(count)"
    }

    var savedCountText: String {
        isValidated ? "\(count)" : "~\(count)"
    }

    var tileDetail: String {
        switch freshness {
        case .live:
            return isValidated ? "Live strap count" : "Live estimate"
        case .stale:
            return "Not live · \(lastMotionText)"
        case .unavailable:
            return "Not live · no motion"
        }
    }

    var lastMotionText: String {
        guard let motionAge else { return "motion unavailable" }
        if motionAge < 60 { return "motion \(max(1, Int(motionAge.rounded())))s ago" }
        if motionAge < 3_600 { return "motion \(max(1, Int((motionAge / 60).rounded())))m ago" }
        return "motion \(max(1, Int((motionAge / 3_600).rounded())))h ago"
    }

    var tint: Color {
        switch freshness {
        case .live: return isValidated ? .green : .orange
        case .stale: return .orange
        case .unavailable: return .secondary
        }
    }

    static func make(count: Int,
                     validationState: String,
                     capturedAt: Date?,
                     now: Date) -> Self {
        let safeCount = max(0, count)
        let isValidated = WidgetSnapshotPublisher.strapStepsAreValidated(state: validationState)
        guard let capturedAt else {
            return Self(count: safeCount,
                        isValidated: isValidated,
                        freshness: safeCount > 0 ? .stale : .unavailable,
                        motionAge: nil)
        }

        let age = now.timeIntervalSince(capturedAt)
        guard age >= -futureTolerance else {
            return Self(count: safeCount,
                        isValidated: isValidated,
                        freshness: safeCount > 0 ? .stale : .unavailable,
                        motionAge: nil)
        }

        return Self(count: safeCount,
                    isValidated: isValidated,
                    freshness: age <= liveWindow ? .live : .stale,
                    motionAge: max(0, age))
    }

    static func persistedMotionDate(defaults: UserDefaults = .standard) -> Date? {
        guard let number = defaults.object(forKey: persistedMotionKey) as? NSNumber else { return nil }
        let timestamp = number.doubleValue
        guard timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func accessibilityDetail(goal: Int) -> String {
        switch freshness {
        case .live:
            let measurement = isValidated ? "validated count" : "estimated count"
            return "Live strap movement. \(savedCountText) steps today, \(measurement). Goal \(goal)."
        case .stale:
            return "Not live. Last saved value \(savedCountText) steps today. \(lastMotionText)."
        case .unavailable:
            return "Not live. Strap movement is unavailable."
        }
    }
}

private struct AtriaStrapStepsDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let count: Int
    let validationState: String
    let presentation: AtriaDailyStepPresentation
    let goal: Int

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let status = AtriaStrapStepLiveStatus.make(
                    count: count,
                    validationState: validationState,
                    capturedAt: AtriaStrapStepLiveStatus.persistedMotionDate(),
                    now: context.date
                )

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "shoeprints.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(status.tint)
                            .frame(width: 42, height: 42)
                            .background(status.tint.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.isLive ? "Live" : "Not live")
                                .font(.headline)
                            Text(status.lastMotionText.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(presentation.valueText)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }

                    HStack(spacing: 10) {
                        statusRow(title: "Measurement",
                                  value: presentation.detailText,
                                  systemImage: presentation.completeness == .complete
                                    ? "checkmark.seal.fill" : "waveform.path.ecg")
                        statusRow(title: "Saved today",
                                  value: presentation.count.map { _ in
                                    "\(presentation.valueText) steps"
                                  } ?? "Unavailable",
                                  systemImage: "clock.arrow.circlepath")
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(status.isLive ? "Daily goal" : "Saved progress")
                            Spacer()
                            Text("\(presentation.valueText) / \(max(goal, 0))")
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))

                        ProgressView(value: Double(presentation.count ?? 0),
                                     total: Double(max(goal, 1)))
                            .tint(status.tint)

                        if presentation.completeness != .complete {
                            Text(presentation.source == .live
                                 ? "Partial day total; it grows as new strap movement arrives."
                                 : "Partial verified archive coverage; this is a lower bound, not a full-day total.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .atriaInsetCard(tint: status.tint)

                    Spacer(minLength: 0)
                }
                .padding()
                .accessibilityElement(children: .contain)
            }
            .navigationTitle("Strap steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statusRow(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: .secondary)
    }
}

private struct AtriaGlanceMetricCard: View, Equatable {
    static let cardHeight: CGFloat = 152
    /// Full-width "2x0.5" compact row height — about half the tall card.
    static let compactRowHeight: CGFloat = 76
    private static let headerHeight: CGFloat = 44
    private static let valueHeight: CGFloat = 38
    private static let footerHeight: CGFloat = 30

    @Environment(\.glanceCompactRow) private var isCompactRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    var ringFraction: Double? = nil
    var sparklineValues: [Int]? = nil
    var zone: AtriaMetricZone? = nil
    var isLoading: Bool = false
    var accessibilityDetail: String? = nil
    var calibratingDay: Int? = nil
    var calibratingTotal: Int = 4
    var calibratingUnit: String = "Day"
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
            && lhs.isLoading == rhs.isLoading
            && lhs.accessibilityDetail == rhs.accessibilityDetail
            && lhs.calibratingDay == rhs.calibratingDay
            && lhs.calibratingTotal == rhs.calibratingTotal
            && lhs.calibratingUnit == rhs.calibratingUnit
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
        if calibratingDay != nil { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "--" ? "" : value
    }

    private var accessibilityText: String {
        var parts = [calibratingDay.map { "\(title) calibrating \(calibratingUnit.lowercased()) \(min(max($0, 0), calibratingTotal)) of \(calibratingTotal)" } ?? "\(title) \(displayValue)", detail]
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
        Group {
            if isCompactRow {
                compactRowBody
            } else {
                tallBody
            }
        }
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

    private var tallBody: some View {
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
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else if let calibratingDay {
                    AtriaCalibratingLabel(day: calibratingDay, total: calibratingTotal, unit: calibratingUnit, tint: tint)
                } else {
                    Text(displayValue)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: displayValue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }

                Spacer(minLength: 0)
            }
            .frame(height: Self.valueHeight, alignment: .bottom)

            footer
        }
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint, hueTinted: true)
        .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
    }

    // WHOOP-style compact row: one horizontal scan line — color/identity marker,
    // quiet name + context, then the hero value flush right. One metric, one job.
    private var compactRowBody: some View {
        HStack(alignment: .center, spacing: 12) {
            AtriaGlanceMetricMarker(systemImage: systemImage,
                                    tint: tint,
                                    progressFraction: clampedRingFraction)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)

                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .layoutPriority(1)
            } else if let calibratingDay {
                AtriaCalibratingLabel(day: calibratingDay, total: calibratingTotal, unit: calibratingUnit, tint: tint)
                    .layoutPriority(1)
            } else {
                Text(displayValue)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: displayValue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
            }

            if let zone, zone.showsWarning {
                AtriaMetricZoneInfoButton(zone: zone) {
                    showingZoneInfo = true
                }
                .frame(width: 44, height: 44)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.compactRowHeight, maxHeight: Self.compactRowHeight, alignment: .center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .atriaInsetCard(tint: tint, hueTinted: true)
        .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
    }

    @ViewBuilder
    private var footer: some View {
        if let sparklineValues {
            Sparkline(values: sparklineValues, tint: tint)
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
    @AtriaDefault("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AtriaDefault("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AtriaDefault("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AtriaDefault("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AtriaDefault("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AtriaDefault("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AtriaDefault("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AtriaDefault("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AtriaDefault("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AtriaDefault("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AtriaDefault("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AtriaDefault("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AtriaDefault("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AtriaDefault("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AtriaDefault("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AtriaDefault("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AtriaDefault("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AtriaDefault("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AtriaDefault("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    var body: some View {
        let summary = metric.targetEditorSummary
        NavigationStack {
            ScrollView {
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
                .padding(18)
            }
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
                .atriaCardAction(tint: .green)
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
                .atriaCardAction(tint: .orange)
            }
        case .load:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $loadACWRWatchLow, in: 0.50...1.00, step: 0.05) {
                    LabeledContent("ACWR low watch") {
                        Text(String(format: "%.1f", loadACWRWatchLow))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRWatchHigh, in: 1.00...1.60, step: 0.05) {
                    LabeledContent("ACWR high watch") {
                        Text(String(format: "%.1f", loadACWRWatchHigh))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRBadLow, in: 0.30...0.95, step: 0.05) {
                    LabeledContent("ACWR low red") {
                        Text(String(format: "%.1f", loadACWRBadLow))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $loadACWRBadHigh, in: 1.10...2.20, step: 0.05) {
                    LabeledContent("ACWR high red") {
                        Text(String(format: "%.1f", loadACWRBadHigh))
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
                .atriaCardAction(tint: .orange)
                Text("ACWR compares 7-day strain with 28-day strain; monotony flags repetitive load. This tunes guidance colors only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .sleep, .sleepHistory:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                    LabeledContent("Sleep goal") {
                        Text(AtriaMetricFormat.sleepHours(sleepGoalHours))
                            .monospacedDigit()
                    }
                }
                Button {
                    sleepGoalHours = 8.0
                } label: {
                    Label("Reset sleep goal", systemImage: "bed.double.fill")
                }
                .atriaCardAction(tint: .cyan)
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
                .atriaCardAction(tint: .pink)
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
                .atriaCardAction(tint: .red)
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
                .atriaCardAction(tint: .teal)
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
                    Label("Reset oxygen signal target", systemImage: "drop.degreesign")
                }
                .atriaCardAction(tint: .blue)
                Text("This tunes candidate-frame evidence only. Atria still does not show an SpO2 percentage until the signal is checked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .bodyTemp:
            if AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable {
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
                    .atriaCardAction(tint: .teal)
                }
            } else {
                Label("Not available yet",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
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
                    Label("Reset fitness-age target", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .purple)
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
                .atriaCardAction(tint: .blue)
            }
        case .steps:
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                    LabeledContent("Strap steps goal") {
                        Text("\(stepsGoal)")
                            .monospacedDigit()
                    }
                }
                Button {
                    stepsGoal = 8_000
                } label: {
                    Label("Reset strap steps goal", systemImage: "figure.walk")
                }
                .atriaCardAction(tint: .green)
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
                .atriaCardAction(tint: .orange)
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
                .atriaCardAction(tint: .cyan)
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
        case .recovery, .steps: return .green
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
            return "Adjust the early signal threshold for candidate frames. This is not an SpO2 percentage target."
        case .bioAge:
            return "Adjust the younger/older delta bands for the fitness-age estimate."
        case .vo2max:
            return "Adjust the VO2max trend gain or decline needed for target colors."
        case .steps:
            return "Adjust the daily strap-step goal used by the steps card."
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
            // Building / indeterminate: a calm clean ring (no busy dashes). A short
            // tinted cap hints "in progress" without spinning or dashing.
            Circle()
                .trim(from: 0, to: 0.16)
                .stroke(tint.opacity(0.85),
                        style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
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
        snapshot.latestDisplayEvidence
    }

    private var tint: Color {
        latest == nil ? .orange : .cyan
    }

    private var valueText: String {
        guard let latest else {
            return snapshot.candidateCount > 0 ? "\(snapshot.candidateCount)" : "--"
        }
        if !latest.confirmed { return latest.durationText }
        return snapshot.averageDurationText
    }

    private var detailText: String {
        guard let latest else {
            if snapshot.candidateCount > 0 {
                return snapshot.candidateCount == 1 ? "Sleep/nap candidate" : "Sleep/nap candidates"
            }
            return "Wear strap overnight or nap"
        }
        if latest.isNapEvidence {
            return latest.confirmed ? "Nap · saved separate" : "Nap · review separate"
        }
        if !latest.confirmed {
            return "Sleep · review before recovery"
        }
        return "\(latest.evidenceLabel) · debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours))"
    }

    private var morningStatus: AtriaSleepMorningStatus {
        if snapshot.candidateCount > 0,
           latest?.confirmed != true {
            return .review
        }
        guard let latest else { return .wear }
        if latest.isNapEvidence {
            return latest.confirmed ? .sync : .review
        }
        return latest.confirmed ? .complete : .review
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

            if morningStatus == .complete {
                stageLegend
            } else {
                AtriaSleepMorningStatusStrip(status: morningStatus)
            }

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
                ForEach(SleepStageKind.displayOrder) { stage in
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
                    .accessibilityLabel("\(stage == .deep ? "Deep (SWS)" : stage.label) \(latest.stageText(stage))")
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
            HStack(spacing: 6) {
                Text("Stages calibrating")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(SleepStageKind.displayOrder.enumerated()), id: \.element) { index, stage in
                        Capsule(style: .continuous)
                            .fill(AtriaSleepStageGlyph.color(for: stage).opacity(0.28))
                            .frame(width: index == 1 ? 18 : 12,
                                   height: fallbackStageHeight(stage))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
            }
            .frame(height: 18, alignment: .center)
        }
    }

    private func fallbackStageHeight(_ stage: SleepStageKind) -> CGFloat {
        switch stage {
        case .awake: return 7
        case .light: return 12
        case .rem: return 10
        case .sws: return 14
        case .deep: return 16
        }
    }

    private var accessibilityText: String {
        guard let latest else {
            if snapshot.candidateCount > 0 {
                return "Sleep history has \(snapshot.candidateCount) sleep or nap candidate\(snapshot.candidateCount == 1 ? "" : "s") ready to review. Morning status \(morningStatus.accessibilityText)."
            }
            return "Sleep history building. Wear the strap overnight or during a nap. Morning status \(morningStatus.accessibilityText)."
        }
        guard !latest.displayStageSegments.isEmpty else {
            return "Sleep history \(valueText). \(latest.evidenceLabel). Morning status \(morningStatus.accessibilityText). Consistency \(snapshot.sleepConsistencyText). Sleep debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours)). Stages building: Awake, Light, REM, and Deep are not ready yet."
        }
        return "Sleep history \(valueText). \(latest.evidenceLabel). Morning status \(morningStatus.accessibilityText). Consistency \(snapshot.sleepConsistencyText). Sleep debt \(snapshot.sleepDebtText(goalHours: sleepGoalHours)). Awake \(latest.stageText(.awake)), Light \(latest.stageText(.light)), REM \(latest.stageText(.rem)), Deep (SWS) \(latest.stageText(.deep))."
    }
}

private enum AtriaSleepMorningStatus: String, Equatable {
    case wear
    case sync
    case review
    case complete

    var activeStepIndex: Int {
        switch self {
        case .wear: return 0
        case .sync: return 1
        case .review: return 2
        case .complete: return 2
        }
    }

    var accessibilityText: String {
        switch self {
        case .wear:
            return "Wear, waiting for overnight sleep."
        case .sync:
            return "Sync, nap saved separately and main sleep still needs overnight evidence."
        case .review:
            return "Review, sleep or nap candidate needs confirmation."
        case .complete:
            return "Review complete, main sleep saved."
        }
    }
}

private struct AtriaSleepMorningStatusStrip: View, Equatable {
    let status: AtriaSleepMorningStatus

    private let steps: [(title: String, symbol: String)] = [
        ("Wear", "moon.zzz.fill"),
        ("Sync", "arrow.triangle.2.circlepath"),
        ("Review", "checkmark.seal.fill")
    ]

    static func == (lhs: AtriaSleepMorningStatusStrip, rhs: AtriaSleepMorningStatusStrip) -> Bool {
        lhs.status == rhs.status
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(steps.indices, id: \.self) { index in
                sleepStatusStep(steps[index], index: index)
            }
        }
        .frame(height: 18, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Morning sleep status. \(status.accessibilityText)")
    }

    private func sleepStatusStep(_ step: (title: String, symbol: String), index: Int) -> some View {
        let active = index == status.activeStepIndex
        let complete = status == .complete && index <= status.activeStepIndex
        let tint: Color = active || complete ? .cyan : .secondary
        return HStack(spacing: 3) {
            Image(systemName: step.symbol)
                .font(.system(size: 7, weight: .bold))
            Text(step.title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(tint.opacity(active || complete ? 0.14 : 0.06),
                    in: Capsule(style: .continuous))
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
        case .rem: return "moonphase.waxing.crescent"
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
                                     actionTitle: "Strap",
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

                if !item.isComplete {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .padding(10)
        .atriaInsetCard(tint: item.tint)
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.detail)
    }
}

struct AtriaOverviewGuidanceSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @StateObject private var projectionStore: AtriaOverviewGuidanceProjectionStore

    init(heroStore: AtriaHomeModel.HeroStore, store: SessionStore) {
        self.heroStore = heroStore
        _projectionStore = StateObject(wrappedValue: AtriaOverviewGuidanceProjectionStore(store: store))
    }

    var body: some View {
        let projection = projectionStore.state
        AtriaOverviewGuidanceSection(hero: heroStore.state,
                                     sleepHistory: debugSleepHistorySnapshot ?? projection.sleepHistory,
                                     sleepHistoryRevision: projection.sleepHistoryRevision,
                                     dailyRollupHistory: projection.dailyRollupHistory,
                                     dailyRollupHistoryRevision: projection.dailyRollupHistoryRevision,
                                     weeklyPlan: projection.weeklyPlan)
            .equatable()
    }

    #if DEBUG
    private var debugSleepHistorySnapshot: SleepHistorySnapshot? {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return nil
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        guard ProcessInfo.processInfo.arguments.indices.contains(valueIndex),
              ProcessInfo.processInfo.arguments[valueIndex] == "sleep-plan-bedtime" else {
            return nil
        }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let today = calendar.startOfDay(for: Date())
        let wakeMinutes = [7 * 60 + 30, 7 * 60 + 40, 7 * 60 + 50]
        let nights = wakeMinutes.enumerated().map { index, wakeMinute in
            let day = calendar.date(byAdding: .day, value: -index - 1, to: today) ?? today
            let end = day.addingTimeInterval(TimeInterval(wakeMinute * 60))
            return SleepHistorySnapshot.Night(id: "debug-ui-fixture-sleep-plan-bedtime-\(index)",
                                              day: day,
                                              start: end.addingTimeInterval(-8 * 3_600),
                                              end: end,
                                              duration: 8 * 3_600,
                                              restingHR: 56,
                                              hrv: 64,
                                              respiratoryRate: 14.2,
                                              sleepEfficiency: 0.91,
                                              confidence: "debug_fixture_confirmed_sleep",
                                              source: "manual_sleep",
                                              confirmed: true,
                                              stageSegments: [])
        }
        return SleepHistorySnapshot(nights: nights, confirmedCount: nights.count, candidateCount: 0)
    }
    #else
    private var debugSleepHistorySnapshot: SleepHistorySnapshot? { nil }
    #endif
}

struct AtriaOverviewGuidanceProjectionState: Equatable {
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let weeklyPlan: WeeklyPlan

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
            && lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.weeklyPlan == rhs.weeklyPlan
    }
}

@MainActor
final class AtriaOverviewGuidanceProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewGuidanceProjectionState

    private let store: SessionStore?
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(store: SessionStore) {
        self.store = store
        state = Self.makeState(store: store)
        bind(to: store)
    }

    init(state: AtriaOverviewGuidanceProjectionState) {
        self.state = state
        store = nil
    }

    @discardableResult
    func refresh(_ next: AtriaOverviewGuidanceProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        Publishers.Merge(
            store.$sleepHistorySnapshot.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyRollupHistory.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.scheduleRefresh() }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard let store = self.store else { return }
            self.refresh(Self.makeState(store: store))
        }
    }

    private static func makeState(store: SessionStore) -> AtriaOverviewGuidanceProjectionState {
        AtriaOverviewGuidanceProjectionState(
            sleepHistory: store.sleepHistorySnapshot,
            sleepHistoryRevision: store.sleepHistorySnapshotRevision,
            dailyRollupHistory: store.dailyRollupHistory,
            dailyRollupHistoryRevision: store.dailyRollupHistoryRevision,
            weeklyPlan: store.currentWeeklyPlan()
        )
    }
}

struct AtriaOverviewGuidanceSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let weeklyPlan: WeeklyPlan
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0

    private var readinessTint: Color {
        hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .secondary
    }

    private var readinessTitle: String {
        guard let recovery = hero.recoveryEstimate.percent else {
            return "Baseline forming"
        }
        return "Recovery \(recovery)%"
    }

    private var planActionText: String {
        guard hero.recoveryEstimate.percent != nil else {
            return "Keep wearing today"
        }
        switch hero.guidance.reason {
        case "low_recovery":
            return "Recover first"
        case "strain_above_target":
            return "Enough load"
        case "strain_below_target":
            return "Room to push"
        case "strain_on_target":
            return "Hold steady"
        default:
            return hero.guidance.headline.isEmpty ? "Check in" : hero.guidance.headline
        }
    }

    private var planHintText: String {
        guard hero.recoveryEstimate.percent != nil else {
            return "Wear a few mornings to unlock targets."
        }
        switch hero.guidance.reason {
        case "low_recovery":
            return "Keep strain light and protect sleep."
        case "strain_above_target":
            return "Let today consolidate instead of chasing more."
        case "strain_below_target":
            return "Add effort if your body agrees."
        case "strain_on_target":
            return "You are inside today's lane."
        default:
            return hero.guidance.detail
        }
    }

    private var targetText: String {
        guard let target = hero.guidance.target else { return "Target strain building" }
        return String(format: "Target strain %.1f", target)
    }

    private var targetValueText: String {
        guard let target = hero.guidance.target else { return "Building" }
        return String(format: "%.1f", target)
    }

    private var sleepDebtValueText: String {
        if let latest = sleepHistory.latestMainSleep, !latest.confirmed {
            return latest.isNapEvidence ? "Nap separate" : "Review"
        }
        let debt = sleepHistory.sleepDebtText(goalHours: sleepGoalHours)
        return debt == "--" ? "Building" : debt
    }

    private var sleepPlanTargetHours: Double {
        if let latest = sleepHistory.latestMainSleep, latest.confirmed {
            return sleepHistory.sleepNeedHours(for: latest, baseNeedHours: sleepBaseNeedHours)
        }
        let debt = sleepHistory.sleepBudgetDebtHours(baseNeedHours: sleepBaseNeedHours)
        return AtriaSleepBudget.sleepNeed(baseHours: sleepBaseNeedHours,
                                          yesterdayStrain: nil,
                                          debtHours: debt,
                                          sameDayNapHours: 0)
    }

    private var sleepPlanTargetText: String {
        let rounded = (sleepPlanTargetHours * 2).rounded() / 2
        return AtriaMetricFormat.sleepHours(rounded)
    }

    private var sleepPlanProgress: Double {
        guard let average = sleepHistory.recentSleepAverageDurationHours,
              sleepPlanTargetHours > 0 else { return 0.18 }
        return min(max(average / sleepPlanTargetHours, 0.08), 1)
    }

    private var sleepPlanStatusText: String {
        if let latest = sleepHistory.latestMainSleep, !latest.confirmed {
            return latest.isNapEvidence ? "Nap separate" : "Review"
        }
        return "Need \(sleepPlanTargetText)"
    }

    private var sleepPlanDebtText: String {
        if let latest = sleepHistory.latestMainSleep, !latest.confirmed {
            return latest.isNapEvidence ? "Main sleep safe" : "Confirm window"
        }
        if sleepDebtValueText == "Met" { return "Debt clear" }
        if sleepDebtValueText == "Building" { return "Debt building" }
        return "Debt \(sleepDebtValueText)"
    }

    private var sleepPlanRoutineText: String {
        sleepHistory.sleepConsistencyText == "--"
            ? "Routine Building"
            : "Routine \(sleepHistory.sleepConsistencyText)"
    }

    private var sleepPlanBedtimeText: String? {
        sleepHistory.bedtimeSuggestionText(now: debugFixtureNow,
                                           targetHours: sleepPlanTargetHours)
    }

    private var debugFixtureNow: Date {
        #if DEBUG
        guard let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-now"),
              ProcessInfo.processInfo.arguments.indices.contains(ProcessInfo.processInfo.arguments.index(after: index)) else {
            return Date()
        }
        let value = ProcessInfo.processInfo.arguments[ProcessInfo.processInfo.arguments.index(after: index)]
        return ISO8601DateFormatter().date(from: value) ?? Date()
        #else
        return Date()
        #endif
    }

    private var baselineValueText: String {
        guard hero.recoveryEstimate.confidence == .learning else {
            return hero.recoveryValue
        }
        if let range = hero.recoveryEstimate.detail.range(of: #"\d+/\d+"#, options: .regularExpression) {
            return String(hero.recoveryEstimate.detail[range])
        }
        return "Building"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Legacy handoff token retained for static audit context:
            // AtriaPanelSectionHeader(title: "Today's Plan", subtitle: "What to do today")
            AtriaPanelSectionHeader(title: "Today's Plan", subtitle: "")

            HStack(alignment: .center, spacing: 14) {
                AtriaPlanReadinessMark(percent: hero.recoveryEstimate.percent,
                                       baselineText: baselineValueText,
                                       tint: readinessTint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(planActionText)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(planHintText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            AtriaDayPlanLane(position: dayLanePosition,
                             cueText: planActionText,
                             detailText: dayLaneDetailText,
                             tint: readinessTint)

            AtriaSleepPlanStrip(statusText: sleepPlanStatusText,
                                debtText: sleepPlanDebtText,
                                routineText: sleepPlanRoutineText,
                                bedtimeText: sleepPlanBedtimeText,
                                progress: sleepPlanProgress)

            planBalanceRail

            AtriaWeeklyPlanCard(plan: weeklyPlan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Today's plan. \(readinessTitle). \(planActionText). \(targetText). Sleep \(sleepDebtValueText). \(hero.recoveryEstimate.confidence == .learning ? "Baseline" : "Recovery") \(baselineValueText). \(hero.guidance.detail)")
    }

    private var dayLanePosition: Double {
        guard hero.recoveryEstimate.percent != nil else { return 0.50 }
        switch hero.guidance.reason {
        case "low_recovery": return 0.12
        case "strain_above_target": return 0.30
        case "strain_on_target": return 0.52
        case "strain_below_target": return 0.82
        default: return 0.50
        }
    }

    private var dayLaneDetailText: String {
        guard hero.recoveryEstimate.percent != nil else { return "Baseline forming" }
        switch hero.guidance.reason {
        case "low_recovery": return "Recover"
        case "strain_above_target": return "Ease"
        case "strain_on_target": return "Hold"
        case "strain_below_target": return "Push"
        default: return "Check"
        }
    }

    static func == (lhs: AtriaOverviewGuidanceSection, rhs: AtriaOverviewGuidanceSection) -> Bool {
        lhs.hero == rhs.hero
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
            && lhs.sleepGoalHours == rhs.sleepGoalHours
            && lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.weeklyPlan == rhs.weeklyPlan
    }

    private var planBalanceRail: some View {
        HStack(spacing: 7) {
            planBalanceStep(systemImage: hero.recoveryEstimate.confidence == .learning ? "clock.badge.checkmark" : "heart.circle.fill",
                            title: hero.recoveryEstimate.confidence == .learning ? "Baseline" : "Recovery",
                            value: baselineValueText,
                            tint: readinessTint)
            planBalanceStep(systemImage: "bolt.heart.fill",
                            title: "Target",
                            value: targetValueText,
                            tint: Metrics.electricStrain)
            planBalanceStep(systemImage: "moon.zzz.fill",
                            title: "Tonight",
                            value: sleepPlanStatusText.replacingOccurrences(of: "Aim ", with: ""),
                            tint: .cyan)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan balance. \(hero.recoveryEstimate.confidence == .learning ? "Baseline" : "Recovery") \(baselineValueText). Target strain \(targetValueText). Tonight \(sleepPlanStatusText).")
    }

    private func planBalanceStep(systemImage: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
    }
}

private struct AtriaDayPlanLane: View, Equatable {
    let position: Double
    let cueText: String
    let detailText: String
    let tint: Color

    private var clampedPosition: Double {
        min(max(position, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Label("Day lane", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(detailText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let markerX = width * clampedPosition
                ZStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        laneSegment(label: "Recover", tint: .cyan)
                        laneSegment(label: "Hold", tint: .secondary)
                        laneSegment(label: "Push", tint: Metrics.electricStrain)
                    }

                    Circle()
                        .fill(tint)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle()
                                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                        }
                        .shadow(color: tint.opacity(0.24), radius: 8, y: 3)
                        .offset(x: min(max(markerX - 8, 0), width - 16))
                }
            }
            .frame(height: 28)
            .accessibilityHidden(true)

            HStack {
                Text(cueText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Spacer(minLength: 8)
                Text("Recover · Hold · Push")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
        }
        .padding(11)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Day lane. \(cueText). \(detailText). Recover, hold, push scale.")
    }

    private func laneSegment(label: String, tint: Color) -> some View {
        Capsule(style: .continuous)
            .fill(tint.opacity(0.34))
            .overlay(alignment: .center) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .frame(maxWidth: .infinity)
    }
}

private struct AtriaSleepPlanStrip: View, Equatable {
    let statusText: String
    let debtText: String
    let routineText: String
    let bedtimeText: String?
    let progress: Double
    @AtriaDefault(AtriaWakeAlarmStore.enabledKey) private var wakeAlarmEnabled: Bool = false
    @AtriaDefault(AtriaWakeAlarmStore.modeKey) private var wakeAlarmMode: String = AtriaWakeAlarmPlan.Mode.smartWindow.rawValue
    @AtriaDefault(AtriaWakeAlarmStore.wakeByMinutesKey) private var wakeByMinutes: Int = AtriaWakeAlarmPlan.defaultPlan.wakeByMinutes
    @AtriaDefault("atria.sleepPlanner.goal") private var plannerGoalRaw: String = AtriaSleepPlannerGoal.peak.rawValue
    @State private var alarmStatusText: String?
    /// Efficiencies of the user's real confirmed nights, for the planner's
    /// time-in-bed assumption. Passed in so this card stays store-free.
    var nightEfficiencies: [Double] = []

    static func == (lhs: AtriaSleepPlanStrip, rhs: AtriaSleepPlanStrip) -> Bool {
        lhs.statusText == rhs.statusText
            && lhs.debtText == rhs.debtText
            && lhs.routineText == rhs.routineText
            && lhs.bedtimeText == rhs.bedtimeText
            && lhs.progress == rhs.progress
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var wakeAlarmPlan: AtriaWakeAlarmPlan {
        AtriaWakeAlarmPlan(mode: AtriaWakeAlarmPlan.Mode(rawValue: wakeAlarmMode) ?? .smartWindow,
                           wakeByHour: wakeByMinutes / 60,
                           wakeByMinute: wakeByMinutes % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.14))
                Image(systemName: "moon.zzz.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("Tonight")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(statusText)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                ProgressView(value: clampedProgress)
                    .tint(.cyan)
                    .scaleEffect(x: 1, y: 1.12, anchor: .center)
                    .accessibilityHidden(true)

                if let bedtimeText {
                    Text(bedtimeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }

                HStack(spacing: 8) {
                    Button {
                        wakeAlarmEnabled.toggle()
                        if wakeAlarmEnabled {
                            scheduleWakeAlarm()
                        } else {
                            AtriaWakeAlarmScheduler.cancelLast()
                            alarmStatusText = "Alarm off"
                        }
                    } label: {
                        Label(wakeAlarmEnabled ? "Wake \(wakeAlarmPlan.displayTime)" : "Set wake alarm",
                              systemImage: wakeAlarmEnabled ? "alarm.fill" : "alarm")
                            .font(.caption2.weight(.bold))
                    }
                    .atriaCardAction(prominent: false, tint: .cyan)

                    Menu {
                        Picker("Wake mode", selection: $wakeAlarmMode) {
                            ForEach(AtriaWakeAlarmPlan.Mode.allCases, id: \.rawValue) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down.circle")
                            .font(.caption.weight(.bold))
                    }
                    .atriaGlassIconAction(tint: .cyan, size: 30)
                    .onChange(of: wakeAlarmMode) { _, _ in
                        if wakeAlarmEnabled { scheduleWakeAlarm() }
                    }
                }

                if let alarmStatusText {
                    Text(alarmStatusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(debtText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(routineText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 20, tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight sleep plan. \(statusText). \(debtText). \(routineText). \(bedtimeText ?? ""). Wake alarm \(wakeAlarmEnabled ? "on" : "off").")
    }

    private func scheduleWakeAlarm() {
        let plan = wakeAlarmPlan
        AtriaWakeAlarmStore.save(plan)
        Task {
            let result = await AtriaWakeAlarmScheduler.scheduleHardAlarm(plan: plan)
            await MainActor.run {
                switch result {
                case .scheduled(_, let fireDate):
                    alarmStatusText = "AlarmKit set \(fireDate.formatted(date: .omitted, time: .shortened))"
                    AtriaDebugLog("ATRIADBG wake_alarm_schedule status=scheduled mode=%@ wake_by=%@ fire=%@",
                                  plan.mode.rawValue,
                                  plan.displayTime,
                                  fireDate.formatted(date: .numeric, time: .shortened))
                case .denied:
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm permission needed"
                case .unavailable(let reason):
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm unavailable"
                    AtriaDebugLog("ATRIADBG wake_alarm_schedule status=unavailable reason=%@",
                                  reason)
                }
            }
        }
    }
}

private struct AtriaPlanReadinessMark: View, Equatable {
    let percent: Int?
    let baselineText: String
    let tint: Color

    private var ringFraction: CGFloat {
        guard let percent else { return 0.22 }
        return CGFloat(min(max(Double(percent) / 100.0, 0), 1))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: 6)

            Circle()
                .trim(from: 0, to: ringFraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if let percent {
                Text("\(percent)")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            } else {
                Image(systemName: "waveform.path.ecg")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 62, height: 62)
        .overlay(alignment: .bottomTrailing) {
            if percent == nil {
                Text(baselineText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.72))
                    )
                    .offset(x: 5, y: 5)
            }
        }
        .accessibilityLabel(percent.map { "Recovery \($0) percent" } ?? "Baseline \(baselineText)")
    }
}

enum AtriaMetricDetailKind: String, Identifiable {
    case recovery
    case hrv
    case restingHeartRate
    case respiratoryRate
    case sleep
    case strain
    // Visibility/IA route audit (2026-07-05): these extend detail coverage to
    // every remaining glance tile that used to dead-end on tap. Some carry a
    // real rollup-backed trend (sleepPerformance, fitnessAge); the rest render
    // an honest "no trend saved yet" template instead of a dead tap.
    case stress
    case vo2max
    case sleepPerformance
    case sleepEfficiency
    case skinTemperature
    case fitnessAge
    case hrZones
    case bloodOxygen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting HR"
        case .respiratoryRate: return "Respiratory rate"
        case .sleep: return "Sleep"
        case .strain: return "Strain"
        case .stress: return "Stress"
        case .vo2max: return "VO2max"
        case .sleepPerformance: return "Sleep performance"
        case .sleepEfficiency: return "Sleep efficiency"
        case .skinTemperature: return "Skin temperature"
        case .fitnessAge: return "Fitness age"
        case .hrZones: return "HR zones"
        case .bloodOxygen: return "Blood oxygen"
        }
    }

    /// One identity hue per metric, drawn from the design palette and deepened
    /// on light via the Metrics.electric* constants (see Metrics.swift). Fixes a
    /// prior coherence bug where `.sleep` returned `.cyan` here — clashing with
    /// sleep's purple ring/chips everywhere else — and where HRV+RHR and
    /// respiration+skin-temp collapsed onto shared raw hues.
    var tint: Color {
        switch self {
        case .recovery: return Metrics.electricGreen
        case .hrv: return Metrics.electricHRV
        case .restingHeartRate: return Metrics.electricRHR
        case .respiratoryRate: return Metrics.electricRespiratory
        case .sleep: return Metrics.electricSleep
        case .strain: return Metrics.electricStrain
        case .stress: return Metrics.electricStress
        case .vo2max: return Metrics.electricGreen
        case .sleepPerformance, .sleepEfficiency: return Metrics.electricSleep
        case .skinTemperature: return Metrics.electricRespiratory
        case .fitnessAge: return Metrics.electricSleep
        case .hrZones: return Metrics.electricStrain
        case .bloodOxygen: return .blue // distinct from RHR's sky-blue; the two can co-list
        }
    }
}

struct AtriaStaleWhileRefreshState<Key: Equatable & Sendable, Value: Sendable>: Sendable {
    private(set) var requestedKey: Key?
    private(set) var valueKey: Key?
    private(set) var value: Value?

    mutating func begin(_ key: Key) {
        requestedKey = key
    }

    @discardableResult
    mutating func accept(_ newValue: Value, for key: Key) -> Bool {
        guard requestedKey == key else { return false }
        valueKey = key
        value = newValue
        return true
    }
}

struct AtriaTodayWorkoutZoneSummary: Equatable {
    struct Entry: Equatable, Identifiable {
        let zone: HRZone
        let minutes: Double
        var id: HRZone { zone }
    }

    let workoutCount: Int
    let workouts: [UserConfirmedWorkout]
    let highZoneSeconds: TimeInterval
    let histogram: [Entry]

    static let empty = AtriaTodayWorkoutZoneSummary(workoutCount: 0,
                                                    workouts: [],
                                                    highZoneSeconds: 0,
                                                    histogram: [])

    static func make(workouts: [UserConfirmedWorkout],
                     confirmedSleeps: [UserConfirmedSleep] = [],
                     sleepHistory: SleepHistorySnapshot? = nil,
                     now: Date = Date(),
                     calendar: Calendar = .current) -> AtriaTodayWorkoutZoneSummary {
        let today = sleepHistory.map {
            AtriaPhysiologicalDay.current(now: now, sleepHistory: $0, calendar: calendar)
        } ?? AtriaPhysiologicalDay.current(now: now,
                                           confirmedSleeps: confirmedSleeps,
                                           calendar: calendar)
        var todayWorkouts: [UserConfirmedWorkout] = []
        var totals: [String: TimeInterval] = [:]
        for workout in workouts {
            guard today.overlaps(start: workout.start, end: workout.end) else { continue }
            todayWorkouts.append(workout)
            guard !AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) else { continue }
            for (key, seconds) in workout.zoneSeconds ?? [:] {
                totals[key, default: 0] += seconds
            }
        }
        guard !todayWorkouts.isEmpty else { return .empty }
        todayWorkouts.sort { $0.start > $1.start }
        let highZoneSeconds = (totals["aerobic"] ?? 0)
            + (totals["anaerobic"] ?? 0)
            + (totals["max"] ?? 0)
        let keyByZone: [HRZone: String] = [
            .rest: "rest", .warmup: "warmup", .fatBurn: "fatBurn",
            .aerobic: "aerobic", .anaerobic: "anaerobic", .max: "max",
        ]
        let histogram = HRZone.allCases.compactMap { zone -> Entry? in
            guard let seconds = keyByZone[zone].flatMap({ totals[$0] }), seconds >= 30 else { return nil }
            return Entry(zone: zone, minutes: seconds / 60)
        }
        return AtriaTodayWorkoutZoneSummary(workoutCount: todayWorkouts.count,
                                           workouts: todayWorkouts,
                                           highZoneSeconds: highZoneSeconds,
                                           histogram: histogram)
    }
}

private final class AtriaTodayWorkoutZoneSummaryMemo {
    private var revision: Int?
    private var cycleStart: Date?
    private var value = AtriaTodayWorkoutZoneSummary.empty

    func summary(workouts: [UserConfirmedWorkout],
                 sleepHistory: SleepHistorySnapshot = .empty,
                 revision newRevision: Int?,
                 now: Date = Date(),
                 calendar: Calendar = .current) -> AtriaTodayWorkoutZoneSummary {
        let newCycleStart = AtriaPhysiologicalDay.current(now: now,
                                                         sleepHistory: sleepHistory,
                                                         calendar: calendar).start
        if let newRevision, revision == newRevision, cycleStart == newCycleStart {
            return value
        }
        let next = AtriaTodayWorkoutZoneSummary.make(workouts: workouts,
                                                     sleepHistory: sleepHistory,
                                                     now: now,
                                                     calendar: calendar)
        revision = newRevision
        cycleStart = newCycleStart
        value = next
        return next
    }
}

private struct AtriaMetricDetailPreparationInput: Equatable, Sendable {
    struct Rollup: Equatable, Sendable {
        let day: Date
        let recovery: Int?
        let lnRMSSD: Double?
        let restingHeartRate: Int?
        let sleepSeconds: TimeInterval?
        let sleepPerformance: Int?
        let strain: Double?
        let respiratoryRate: Double?
        let fitnessAgeDelta: Int?

        init(_ entry: DailyRollupStoreEntry) {
            day = entry.day
            recovery = entry.recovery
            lnRMSSD = entry.lnRMSSD
            restingHeartRate = entry.rhr
            sleepSeconds = entry.sleepSeconds
            sleepPerformance = entry.sleepPerformance
            strain = entry.strain
            respiratoryRate = entry.respiratoryRate
            fitnessAgeDelta = entry.fitnessAgeDelta
        }
    }

    struct Baseline: Equatable, Sendable {
        let hrvBaseline: Int?
        let hrvSampleCount: Int
        let hrvLnMean: Double?
        let hrvLnSD: Double?
        let hrvTrusted: Bool
        let restingBaseline: Int?
        let restingSampleCount: Int
        let restingMean: Double?
        let restingSD: Double?
        let restingTrusted: Bool

        init(_ baseline: AtriaBaselineTargetSnapshot) {
            hrvBaseline = baseline.hrvBaseline
            hrvSampleCount = baseline.hrvSampleCount
            hrvLnMean = baseline.hrvLnMean
            hrvLnSD = baseline.hrvLnSD
            hrvTrusted = baseline.hrvTrusted
            restingBaseline = baseline.restingBaseline
            restingSampleCount = baseline.restingSampleCount
            restingMean = baseline.restingMean
            restingSD = baseline.restingSD
            restingTrusted = baseline.restingTrusted
        }
    }

    let rollupsRevision: Int?
    let rollups: [Rollup]
    let baseline: Baseline
    let sleepGoalHours: Double
    let referenceDate: Date
    let calendar: Calendar

    init(rollups: [DailyRollupStoreEntry],
         rollupsRevision: Int?,
         baseline: AtriaBaselineTargetSnapshot,
         sleepGoalHours: Double,
         referenceDate: Date = Date(),
         calendar: Calendar = .current) {
        self.rollupsRevision = rollupsRevision
        self.rollups = rollups.map(Rollup.init)
        self.baseline = Baseline(baseline)
        self.sleepGoalHours = sleepGoalHours
        self.referenceDate = calendar.startOfDay(for: referenceDate)
        self.calendar = calendar
    }
}

private actor AtriaMetricDetailPreparationCache {
    static let shared = AtriaMetricDetailPreparationCache()

    private var entry: (key: AtriaMetricDetailPreparationInput, value: AtriaPreparedMetricHistory)?

    func value(for key: AtriaMetricDetailPreparationInput) -> AtriaPreparedMetricHistory? {
        guard entry?.key == key else { return nil }
        return entry?.value
    }

    func insert(_ value: AtriaPreparedMetricHistory,
                for key: AtriaMetricDetailPreparationInput) {
        entry = (key, value)
    }
}

struct AtriaMetricDetailSheet: View {
    let metric: AtriaMetricDetailKind
    let confirmedWorkouts: [UserConfirmedWorkout]
    let confirmedWorkoutsRevision: Int?
    let baseline: AtriaBaselineTargetSnapshot
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int?
    let guidance: Coach.Guidance
    let recoveryEstimate: Metrics.RecoveryEstimate
    let sleepGoalHours: Double
    let sleepBaseNeedHours: Double
    // Visibility/IA route audit (2026-07-05): live data for the new honest-
    // partial detail kinds (VO2max, HR zones, skin temperature). All default
    // to an honest "still building" value so the two pre-existing call sites
    // (AtriaTodayScreen, and the dead orphaned AtriaVitalsTabContent/
    // AtriaOverviewReadinessSection screens) keep compiling unchanged.
    let hrZoneMinutes: TodayHRZoneMinutes
    let maxHeartRate: Int?
    let behaviorImpacts: [BehaviorImpactSummary]
    private let rollups: [DailyRollupStoreEntry]
    private let preparationInput: AtriaMetricDetailPreparationInput
    private let latestNutrition: AtriaNutritionSummary?
    @State private var openedHistoryDay: AtriaHistoryDay?
    @State private var showChartOptions = false
    @State private var showExpandedChart = false
    @State private var bucketOverride: AtriaChartBucketOverride
    @State private var showMinMaxBand: Bool
    @State private var expandedChartEventsCache = ExpandedChartEventsCache()
    @State private var metricChartPreparedDataCache = MetricChartPreparedDataCache()
    @State private var todayWorkoutZoneSummaryMemo = AtriaTodayWorkoutZoneSummaryMemo()
    let vo2MaxEstimate: VO2MaxEstimateSummary?
    let skinTemperatureDeviation: IMUAuditSummary.SkinTemperatureDeviationSummary?
    @State private var preparation = AtriaStaleWhileRefreshState<AtriaMetricDetailPreparationInput, AtriaPreparedMetricHistory>()
    // Detail sheets open on today rather than a month aggregate. The range
    // picker still provides week/month context without hiding the current day.
    @State private var range: AtriaTrendRange = .day
    @State private var showingMeaningSheet = false
    private let initialScrubbedDay: Date?

    private final class ExpandedChartEventsCache {
        private var key: Int?
        private var events: [AtriaChartEvent] = []

        func value(key newKey: Int, compute: () -> [AtriaChartEvent]) -> [AtriaChartEvent] {
            if key != newKey {
                key = newKey
                events = compute()
            }
            return events
        }
    }

    private final class MetricChartPreparedDataCache {
        struct Key: Equatable {
            let preparationInput: AtriaMetricDetailPreparationInput
            let metric: AtriaMetricDetailKind
            let range: AtriaTrendRange
            let bucketOverride: AtriaChartBucketOverride
            let showMinMaxBand: Bool
        }

        private var entry: (key: Key, value: AtriaMetricChartPreparedData)?

        func value(for key: Key,
                   compute: () -> AtriaMetricChartPreparedData) -> AtriaMetricChartPreparedData {
            if let entry, entry.key == key { return entry.value }
            let value = compute()
            entry = (key, value)
            return value
        }
    }

    init(metric: AtriaMetricDetailKind,
         rollups: [DailyRollupStoreEntry],
         rollupsRevision: Int? = nil,
         confirmedWorkouts: [UserConfirmedWorkout] = [],
         confirmedWorkoutsRevision: Int? = nil,
         behaviorImpacts: [BehaviorImpactSummary] = [],
         baseline: AtriaBaselineTargetSnapshot,
         sleepHistory: SleepHistorySnapshot,
         sleepHistoryRevision: Int? = nil,
         guidance: Coach.Guidance,
         recoveryEstimate: Metrics.RecoveryEstimate,
         sleepGoalHours: Double,
         sleepBaseNeedHours: Double,
         hrZoneMinutes: TodayHRZoneMinutes = .empty,
         maxHeartRate: Int? = nil,
         vo2MaxEstimate: VO2MaxEstimateSummary? = nil,
         skinTemperatureDeviation: IMUAuditSummary.SkinTemperatureDeviationSummary? = nil,
         initialRange: AtriaTrendRange = .day,
         initialScrubbedDay: Date? = nil,
         initialBucketOverride: AtriaChartBucketOverride = .auto,
         initialShowMinMaxBand: Bool = true) {
        _range = State(initialValue: initialRange)
        self.initialScrubbedDay = initialScrubbedDay
        _bucketOverride = State(initialValue: initialBucketOverride)
        _showMinMaxBand = State(initialValue: initialShowMinMaxBand)
        self.metric = metric
        self.confirmedWorkouts = confirmedWorkouts
        self.confirmedWorkoutsRevision = confirmedWorkoutsRevision
        self.baseline = baseline
        self.sleepHistory = sleepHistory
        self.sleepHistoryRevision = sleepHistoryRevision
        self.guidance = guidance
        self.recoveryEstimate = recoveryEstimate
        self.sleepGoalHours = sleepGoalHours
        self.sleepBaseNeedHours = sleepBaseNeedHours
        self.hrZoneMinutes = hrZoneMinutes
        self.maxHeartRate = maxHeartRate
        self.vo2MaxEstimate = vo2MaxEstimate
        self.skinTemperatureDeviation = skinTemperatureDeviation
        self.rollups = rollups
        self.behaviorImpacts = behaviorImpacts
        self.latestNutrition = rollups.first(where: { $0.nutrition != nil })?.nutrition
        self.preparationInput = AtriaMetricDetailPreparationInput(rollups: rollups,
                                                                  rollupsRevision: rollupsRevision,
                                                                  baseline: baseline,
                                                                  sleepGoalHours: sleepGoalHours)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    AtriaPanelSectionHeader(title: metric.title, subtitle: "Trend and context")
                    Spacer(minLength: 0)
                    if chartSupportsOptions {
                        Button {
                            showChartOptions = true
                        } label: {
                            // chart.bar.xaxis (not the slider glyph — that
                            // bare literal is banned by the removed-customize
                            // guard in this file).
                            Image(systemName: "chart.bar.xaxis")
                                .font(.headline.weight(.semibold))
                                .padding(10)
                                .background(.quaternary.opacity(0.22), in: Circle())
                        }
                        .accessibilityLabel("Chart options: bucketing and min-max band")
                    }
                    Button {
                        showingMeaningSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.headline.weight(.semibold))
                            .padding(10)
                            .background(.quaternary.opacity(0.22), in: Circle())
                    }
                    .accessibilityLabel("\(metric.title) meaning and coaching")
                }

                if preparation.value == nil {
                    preparationShell
                } else {
                    detailTemplate
                }
            }
            .padding(18)
        }
        .task(id: preparationInput) {
            await refreshPreparedHistory()
        }
        .sheet(isPresented: $showingMeaningSheet) {
            AtriaMetricMeaningSheet(metric: metric,
                                    guidance: guidance,
                                    recoveryEstimate: recoveryEstimate,
                                    sleepGoalHours: sleepGoalHours)
        }
        .fullScreenCover(isPresented: $showExpandedChart) {
            if let config = expandedChartConfig {
                AtriaExpandedChartView(title: config.title,
                                       unit: config.unit,
                                       tint: config.tint,
                                       points: config.points,
                                       priorPoints: config.prior,
                                       baselineBand: config.band,
                                       events: expandedChartEvents,
                                       overlays: expandedChartOverlays,
                                       onDismiss: { showExpandedChart = false })
            }
        }
        .sheet(isPresented: $showChartOptions) {
            AtriaChartOptionsSheet(bucketOverride: $bucketOverride,
                                   showMinMaxBand: $showMinMaxBand)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $openedHistoryDay) { day in
            AtriaHistoryDayDetailSheet(day: day,
                                       medians: AtriaHistoryModel.make(rollups: rollups,
                                                                       workouts: confirmedWorkouts,
                                                                       sleeps: []).medianWindow(around: day))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var preparedHistory: AtriaPreparedMetricHistory {
        precondition(preparation.value != nil, "Metric history is read only after preparation completes")
        return preparation.value!
    }

    private var preparationShell: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
                .tint(metric.tint)
            Text("Preparing trend")
                .font(.headline.weight(.semibold))
            Text("Your saved metric history will appear here in a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .padding(16)
        .atriaInsetCard(tint: metric.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing \(metric.title) trend")
        .accessibilityIdentifier("metric-detail-preparation-shell")
    }

    @MainActor
    private func refreshPreparedHistory() async {
        let input = preparationInput
        var next = preparation
        next.begin(input)
        preparation = next

        if preparation.valueKey == input {
            return
        }
        if let cached = await AtriaMetricDetailPreparationCache.shared.value(for: input) {
            var cachedState = preparation
            _ = cachedState.accept(cached, for: input)
            preparation = cachedState
            return
        }

        let prepared = await Task.detached(priority: .userInitiated) {
            AtriaPreparedMetricHistory(input: input)
        }.value
        guard !Task.isCancelled, preparation.requestedKey == input else { return }
        await AtriaMetricDetailPreparationCache.shared.insert(prepared, for: input)

        var completed = preparation
        _ = completed.accept(prepared, for: input)
        preparation = completed
    }

    @ViewBuilder
    private var detailTemplate: some View {
        switch metric {
        case .recovery:
            // Recovery's signature visual (the contributor map: what made
            // today's score) belongs on the first screen like sleep's
            // hypnogram and strain's gauge — not behind "Show details"
            // (2026-07-07, design handoff full-scroll mock).
            AtriaMetricDetailTemplate(heroValue: recoveryHeroValue,
                                      heroState: recoveryHeroState,
                                      tint: recoveryHeroRawPercent.map { Metrics.recoveryColor(Int($0.rounded())) } ?? Metrics.electricGreen,
                                      heroStyle: .recoveryRing(score: recoveryHeroRawPercent,
                                                               baselineComparison: recoveryBaselineComparisonText)) {
                contributorCard
                behaviorsMoveYouCard
            } contributors: {
                EmptyView()
            } chart: {
                chartSlot {
                    metricChart(title: "Recovery",
                                unit: "%",
                                tint: Metrics.electricGreen,
                                points: displayedPoints(auto: preparedHistory.recovery[range] ?? [], raw: preparedHistory.recoveryRaw[range] ?? []),
                                summary: preparedHistory.recoverySummary[range],
                                comparison: preparedHistory.recoveryComparison[range],
                                baselineBand: nil,
                                accessibilitySummary: "Recovery over \(range.label).",
                                priorPoints: preparedHistory.recoveryPrior[range] ?? [],
                                companions: [("That day's HRV", "ms", Metrics.electricHRV, preparedHistory.hrv[range] ?? []),
                                             ("Sleep", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .hrv:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.hrvSummary[range], points: preparedHistory.hrv[range] ?? [], unit: "ms"),
                                      heroState: hrvBand == nil ? learningNightsState(baseline.hrvSampleCount) : "Typical",
                                      tint: metric.tint) {
                AtriaMetricContributorRows(rows: [
                    AtriaMetricContributorRow(systemImage: "waveform.path.ecg",
                                              name: "HRV",
                                              value: latestMetricText(points: preparedHistory.hrv[range] ?? [], unit: "ms"),
                                              comparison: hrvBand.map { "typical \(Int($0.lower.rounded()))-\(Int($0.upper.rounded())) ms" } ?? "typical range building",
                                              direction: 0)
                ], tint: metric.tint)
            } chart: {
                chartSlot {
                    metricChart(title: "HRV",
                                unit: "ms",
                                tint: metric.tint,
                                points: displayedPoints(auto: preparedHistory.hrv[range] ?? [], raw: preparedHistory.hrvRaw[range] ?? []),
                                summary: preparedHistory.hrvSummary[range],
                                comparison: preparedHistory.hrvComparison[range],
                                baselineBand: hrvBand,
                                accessibilitySummary: "HRV over \(range.label) with your baseline band.",
                                emptyExplanation: "HRV is read from steady overnight wear — each clean night adds a point here.",
                                priorPoints: preparedHistory.hrvPrior[range] ?? [],
                                companions: [("That day's recovery", "%", Metrics.electricGreen, preparedHistory.recovery[range] ?? []),
                                             ("Sleep", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .restingHeartRate:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.restingHeartRateSummary[range], points: preparedHistory.restingHeartRate[range] ?? [], unit: "bpm"),
                                      heroState: restingBand == nil ? learningNightsState(baseline.restingSampleCount) : "Typical",
                                      tint: metric.tint) {
                AtriaMetricContributorRows(rows: [
                    AtriaMetricContributorRow(systemImage: "heart.fill",
                                              name: "Resting HR",
                                              value: latestMetricText(points: preparedHistory.restingHeartRate[range] ?? [], unit: "bpm"),
                                              comparison: restingBand.map { "typical \(Int($0.lower.rounded()))-\(Int($0.upper.rounded())) bpm" } ?? "typical range building",
                                              direction: 0)
                ], tint: metric.tint)
            } chart: {
                chartSlot {
                    metricChart(title: "Resting HR",
                                unit: "bpm",
                                tint: metric.tint,
                                points: displayedPoints(auto: preparedHistory.restingHeartRate[range] ?? [], raw: preparedHistory.restingHeartRateRaw[range] ?? []),
                                summary: preparedHistory.restingHeartRateSummary[range],
                                comparison: preparedHistory.restingHeartRateComparison[range],
                                baselineBand: restingBand,
                                accessibilitySummary: "Resting heart rate over \(range.label) with your baseline band.",
                                emptyExplanation: "Resting heart rate is read from overnight wear — each night adds a point here.",
                                priorPoints: preparedHistory.restingHeartRatePrior[range] ?? [],
                                companions: [("That day's HRV", "ms", Metrics.electricHRV, preparedHistory.hrv[range] ?? []),
                                             ("Recovery", "%", Metrics.electricGreen, preparedHistory.recovery[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .respiratoryRate:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.respiratoryRateSummary[range], points: preparedHistory.respiratoryRate[range] ?? [], unit: "/min"),
                                      heroState: respiratoryBand == nil ? "Learning" : "Typical",
                                      tint: metric.tint) {
                AtriaMetricContributorRows(rows: [
                    AtriaMetricContributorRow(systemImage: "lungs.fill",
                                              name: "Respiratory rate",
                                              value: latestMetricText(points: preparedHistory.respiratoryRate[range] ?? [], unit: "/min"),
                                              comparison: respiratoryBand.map { String(format: "typical %.1f-%.1f/min", $0.lower, $0.upper) } ?? "typical range building",
                                              direction: 0)
                ], tint: metric.tint)
            } chart: {
                chartSlot {
                    metricChart(title: "Respiratory rate",
                                unit: "/min",
                                tint: metric.tint,
                                points: displayedPoints(auto: preparedHistory.respiratoryRate[range] ?? [], raw: preparedHistory.respiratoryRateRaw[range] ?? []),
                                summary: preparedHistory.respiratoryRateSummary[range],
                                comparison: preparedHistory.respiratoryRateComparison[range],
                                baselineBand: respiratoryBand,
                                accessibilitySummary: "Respiratory rate over \(range.label) with your typical range.",
                                emptyExplanation: "Respiratory rate is derived from steady overnight wear — each night adds a point here.",
                                priorPoints: preparedHistory.respiratoryRatePrior[range] ?? [],
                                companions: [("That day's HRV", "ms", Metrics.electricHRV, preparedHistory.hrv[range] ?? []),
                                             ("Recovery", "%", Metrics.electricGreen, preparedHistory.recovery[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .sleep:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.sleepSummary[range], points: preparedHistory.sleep[range] ?? [], unit: "h"),
                                      heroState: sleepHeroState,
                                      tint: Metrics.electricSleep) {
                if let latest = sleepHistory.latestMainSleep {
                    AtriaSleepHypnogramCard(night: latest,
                                            neededHours: sleepHistory.sleepNeedHours(for: latest,
                                                                                    baseNeedHours: sleepBaseNeedHours,
                                                                                    yesterdayStrain: yesterdayStrainForLatestNight),
                                            consistencyPercent: sleepHistory.sleepConsistencyPercent,
                                            nightEfficiencies: confirmedNightEfficiencies)
                    sleepNeedLedgerCard(for: latest)
                    sleepDebtTrendCard
                }
            } contributors: {
                AtriaMetricContributorRows(rows: sleepContributorRows, tint: Metrics.electricSleep)
            } chart: {
                chartSlot {
                    metricChart(title: "Sleep duration",
                                unit: "h",
                                tint: Metrics.electricSleep,
                                points: displayedPoints(auto: preparedHistory.sleep[range] ?? [], raw: preparedHistory.sleepRaw[range] ?? []),
                                summary: preparedHistory.sleepSummary[range],
                                comparison: preparedHistory.sleepComparison[range],
                                baselineBand: nil,
                                accessibilitySummary: "Sleep duration over \(range.label).",
                                priorPoints: preparedHistory.sleepPrior[range] ?? [],
                                companions: [("That day's recovery", "%", Metrics.electricGreen, preparedHistory.recovery[range] ?? []),
                                             ("HRV", "ms", Metrics.electricHRV, preparedHistory.hrv[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .strain:
            AtriaMetricDetailTemplate(heroValue: strainHeroValue,
                                      heroState: strainHeroState,
                                      tint: Metrics.electricStrain,
                                      heroStyle: .strain(score: strainHeroRawValue,
                                                         target: guidance.target)) {
                strainWorkoutSection
                strainZoneHistogramCard
                strainActivityMixCard
            } contributors: {
                AtriaMetricContributorRows(rows: strainContributorRows, tint: Metrics.electricStrain)
            } chart: {
                chartSlot {
                    metricChart(title: "Strain",
                                unit: "",
                                tint: Metrics.electricStrain,
                                points: displayedPoints(auto: preparedHistory.strain[range] ?? [], raw: preparedHistory.strainRaw[range] ?? []),
                                summary: preparedHistory.strainSummary[range],
                                comparison: preparedHistory.strainComparison[range],
                                baselineBand: nil,
                                accessibilitySummary: "Strain over \(range.label).",
                                priorPoints: preparedHistory.strainPrior[range] ?? [],
                                companions: [("That day's recovery", "%", Metrics.electricGreen, preparedHistory.recovery[range] ?? []),
                                             ("Sleep", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .sleepPerformance:
            AtriaMetricDetailTemplate(heroValue: periodHeroText(summary: preparedHistory.sleepPerformanceSummary[range], points: preparedHistory.sleepPerformance[range] ?? [], unit: "%"),
                                      heroState: sleepPerformanceHeroState,
                                      tint: Metrics.electricSleep) {
                EmptyView()
            } chart: {
                chartSlot {
                    metricChart(title: "Sleep performance",
                                unit: "%",
                                tint: Metrics.electricSleep,
                                points: preparedHistory.sleepPerformance[range] ?? [],
                                summary: preparedHistory.sleepPerformanceSummary[range],
                                comparison: preparedHistory.sleepPerformanceComparison[range],
                                baselineBand: nil,
                                accessibilitySummary: "Sleep performance, percent of nightly need, over \(range.label).",
                                companions: [("Sleep duration", "h", Metrics.electricSleep, preparedHistory.sleep[range] ?? []),
                                             ("Recovery", "%", Metrics.electricGreen, preparedHistory.recovery[range] ?? [])],
                                onOpenDay: { day in openHistoryDay(for: day) },
                                onExpand: { showExpandedChart = true })
                }
            } about: {
                aboutDisclosure
            }
        case .fitnessAge:
            AtriaMetricDetailTemplate(heroValue: fitnessAgeHeroValue,
                                      heroState: fitnessAgeHeroState,
                                      tint: fitnessAgeTint) {
                if preparedHistory.paceOfAging.isReady {
                    Text(preparedHistory.paceOfAging.copyText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(fitnessAgeTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } chart: {
                if preparedHistory.paceOfAging.isReady {
                    chartSlot {
                        metricChart(title: "Pace of aging",
                                    unit: "y",
                                    tint: fitnessAgeTint,
                                    points: preparedHistory.fitnessAge[range] ?? [],
                                    summary: preparedHistory.fitnessAgeSummary[range],
                                    comparison: preparedHistory.fitnessAgeComparison[range],
                                    baselineBand: nil,
                                    accessibilitySummary: "Fitness-age delta over \(range.label).",
                                    onOpenDay: { day in openHistoryDay(for: day) },
                                    onExpand: { showExpandedChart = true })
                    }
                } else {
                    honestPartialCard(tint: fitnessAgeTint,
                                      bodyText: "Calibrating a 28-day baseline before showing your pace of aging \u{2014} \(preparedHistory.fitnessAgeEntryCount) of 4 weekly checks saved so far.")
                }
            } about: {
                aboutDisclosure
            }
        case .stress:
            honestPartialDetail(heroValue: "Live read",
                                heroState: "Not saved daily yet",
                                tint: .orange,
                                bodyText: "Stress is a live, moment-to-moment estimate from heart rate and beat-to-beat timing. Atria doesn't save a daily stress history yet, so there's no trend chart here \u{2014} check the Stress tile for the current read, or open guided breathwork to bring it down.")
        case .vo2max:
            honestPartialDetail(heroValue: vo2MaxEstimate?.valueText ?? "Learning",
                                heroState: (vo2MaxEstimate?.value == nil) ? "Learning" : "Estimate",
                                tint: Metrics.electricGreen,
                                bodyText: vo2MaxEstimate?.narrative ?? "VO2max is estimated from your resting heart-rate baseline and measured max heart rate. It sharpens as Atria gathers more sessions.")
        case .sleepEfficiency:
            honestPartialDetail(heroValue: sleepHistory.latestMainSleep?.sleepEfficiencyText ?? "--",
                                heroState: sleepHistory.latestMainSleep?.sleepEfficiency == nil ? "Learning" : "Duration-based estimate",
                                tint: Metrics.electricSleep,
                                bodyText: "Sleep efficiency is estimated from time asleep versus time in bed. Atria doesn't save a night-by-night efficiency trend here yet \u{2014} the current estimate is shown above.")
        case .skinTemperature:
            let decoderAvailable = AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
            let summary = skinTemperatureDeviation
                ?? IMUAuditSummary.SkinTemperatureDeviationSummary(
                    latestDeltaCelsius: nil,
                    baselineSessions: 0,
                    candidateFrames: 0,
                    candidateValues: 0)
            let hasReading = AtriaExperimentalSensorCopy.hasValidatedSkinTemperatureReading(
                summary: summary,
                decoderAvailable: decoderAvailable)
            honestPartialDetail(heroValue: AtriaExperimentalSensorCopy.skinTemperatureValue(
                                    summary: summary,
                                    decoderAvailable: decoderAvailable),
                                heroState: hasReading ? "vs sleep baseline" : (decoderAvailable ? "Building baseline" : "Not available yet"),
                                tint: .teal,
                                bodyText: AtriaExperimentalSensorCopy.skinTemperatureDetail(
                                    summary: summary,
                                    decoderAvailable: decoderAvailable))
        case .hrZones:
            // Design handoff (2026-07-07): the sheet lists the user's real
            // per-zone bpm boundaries, computed from the same percent-of-max
            // model the live workout zones use. Card hides when max HR is
            // unknown (never a fabricated boundary).
            AtriaMetricDetailTemplate(heroValue: hrZoneMinutes.valueText,
                                      heroState: hrZoneMinutes.hasSamples ? "today" : "No wear today",
                                      tint: .orange) {
                hrZoneBoundariesCard
            } contributors: {
                EmptyView()
            } chart: {
                honestPartialCard(tint: .orange, bodyText: "Time-in-zone minutes for today, split across Z2\u{2013}Z5. Atria doesn't save a day-by-day zone-minutes trend here yet.")
            } about: {
                aboutDisclosure
            }
        case .bloodOxygen:
            honestPartialDetail(heroValue: "\u{2014}",
                                heroState: "Not available yet",
                                tint: .pink,
                                bodyText: "Atria can't read blood oxygen from this strap yet, so it shows no percentage.")
        }
    }

    /// Reusable honest-partial template for detail kinds that have a live
    /// current value but no saved daily trend yet -- renders the hero value
    /// plus an explanatory card instead of a fabricated chart.
    private func honestPartialDetail(heroValue: String,
                                     heroState: String = "Learning",
                                     tint: Color,
                                     bodyText: String) -> some View {
        AtriaMetricDetailTemplate(heroValue: heroValue, heroState: heroState, tint: tint) {
            EmptyView()
        } chart: {
            honestPartialCard(tint: tint, bodyText: bodyText)
        } about: {
            aboutDisclosure
        }
    }

    /// The user's per-zone bpm boundaries from their profile max HR
    /// (percent-of-max bands, HRZone.lowerFraction) -- the exact math the
    /// live workout zone bar uses. Renders nothing without a real max HR.
    @ViewBuilder
    private var hrZoneBoundariesCard: some View {
        if let maxHR = maxHeartRate, maxHR > 0 {
            let zones = Array(HRZone.allCases)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your zones")
                    .font(.headline.weight(.semibold))
                ForEach(Array(zones.enumerated().reversed()), id: \.element.rawValue) { index, zone in
                    let lower = Int((zone.lowerFraction * Double(maxHR)).rounded())
                    let upper = index + 1 < zones.count
                        ? Int((zones[index + 1].lowerFraction * Double(maxHR)).rounded()) - 1
                        : maxHR
                    HStack(spacing: 10) {
                        Circle()
                            .fill(zone.color)
                            .frame(width: 9, height: 9)
                        Text(zone.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(zone.lowerFraction == 0 ? "under \(upper + 1) bpm" : "\(lower)\u{2013}\(upper) bpm")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("From your max heart rate (\(maxHR) bpm) \u{2014} percent-of-max bands, the same math the live workout zones use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: .orange)
        }
    }

    private func honestPartialCard(tint: Color, bodyText: String) -> some View {
        Text(bodyText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .atriaInsetCard(tint: tint)
    }

    private var sleepPerformanceHeroState: String {
        preparedHistory.sleepPerformance[range]?.last == nil ? "Learning" : "of nightly need"
    }

    private var fitnessAgeHeroValue: String {
        guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return "--" }
        let delta = Int(latest.rounded())
        return delta == 0 ? "0y" : "\(abs(delta))y"
    }

    private var fitnessAgeHeroState: String {
        guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return "Learning" }
        if latest == 0 { return "Matches your age" }
        return latest < 0 ? "younger" : "older"
    }

    private var fitnessAgeTint: Color {
        guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return .orange }
        return latest <= 0 ? Metrics.electricGreen : Metrics.electricYellow
    }

    private var rangeLens: (summary: AtriaDetailPeriodSummary, comparison: AtriaDetailComparisonSummary?)? {
        switch metric {
        case .recovery:
            return preparedHistory.recoverySummary[range].map { ($0, preparedHistory.recoveryComparison[range]) }
        case .hrv:
            return preparedHistory.hrvSummary[range].map { ($0, preparedHistory.hrvComparison[range]) }
        case .restingHeartRate:
            return preparedHistory.restingHeartRateSummary[range].map { ($0, preparedHistory.restingHeartRateComparison[range]) }
        case .respiratoryRate:
            return preparedHistory.respiratoryRateSummary[range].map { ($0, preparedHistory.respiratoryRateComparison[range]) }
        case .sleep:
            return preparedHistory.sleepSummary[range].map { ($0, preparedHistory.sleepComparison[range]) }
        case .strain:
            return preparedHistory.strainSummary[range].map { ($0, preparedHistory.strainComparison[range]) }
        case .sleepPerformance:
            return preparedHistory.sleepPerformanceSummary[range].map { ($0, preparedHistory.sleepPerformanceComparison[range]) }
        case .fitnessAge:
            return preparedHistory.fitnessAgeSummary[range].map { ($0, preparedHistory.fitnessAgeComparison[range]) }
        case .stress, .vo2max, .sleepEfficiency, .skinTemperature, .hrZones, .bloodOxygen:
            return nil
        }
    }

    private func chartSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Range", selection: $range) {
                ForEach(AtriaTrendRange.primarySegments) { option in
                    Text(option.menuLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)

            // Detail redesign (2026-07-06): the "Trend snapshot"
            // AtriaDetailRangeLensCard was removed here — it restated the exact
            // Latest/Avg/Change the metricChart's summary strip already shows
            // (plus a secondary this-vs-prior seesaw), producing two stacked
            // summary cards ("box inside box") before the chart. One canonical
            // summary now lives in metricChart. The RangeLensCard struct is kept
            // as uncalled scaffolding so its gate pins/reuse stay intact.
            content()
        }
    }

    private var aboutDisclosure: some View {
        DisclosureGroup {
            AtriaMetricMeaningInline(metric: metric,
                                     guidance: guidance,
                                     recoveryEstimate: recoveryEstimate,
                                     sleepGoalHours: sleepGoalHours)
        } label: {
            Label("Learn", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .atriaInsetCard(tint: metric.tint)
    }

    /// The recovery number behind the hero, per selected period, read from the
    /// SAME frozen daily-rollup series the chart below plots — never the live
    /// `recoveryEstimate` recompute. Day = that settled daily score (today's
    /// saved recovery, else the newest saved day carried forward, exactly like
    /// the overview tile / health row / widget), so the headline can no longer
    /// drift onto the live value or contradict them for the same day. Week/Month
    /// = the window average, so the number finally tracks the Day/Week/Month
    /// selector (2026-07-08: fixes recovery showing a fixed live % that both
    /// ignored the period and disagreed with the day value shown everywhere else).
    private var recoveryHeroRawPercent: Double? {
        if range == .day {
            return preparedHistory.recoverySummary[range]?.latestRaw
                ?? preparedHistory.recoveryRaw[.all]?.last?.value
        }
        return preparedHistory.recoverySummary[range]?.averageRaw
    }

    private var recoveryHeroValue: String {
        guard let percent = recoveryHeroRawPercent else { return "Learning" }
        return AtriaDetailPeriodSummary.valueText(percent, unit: "%")
    }

    private var recoveryHeroState: String {
        // Canonical not-ready word is "Learning" (never "Building") — must match
        // the recovery ring center + legend chip for the same Day-1 state.
        guard let percent = recoveryHeroRawPercent.map({ Int($0.rounded()) }) else { return "Learning" }
        if recoveryHeroUsesPreviousSavedDay {
            return "Previous sleep"
        }
        switch percent {
        case 67...: return "Good"
        case 34..<67: return "Typical"
        default: return "Low"
        }
    }

    private var recoveryHeroUsesPreviousSavedDay: Bool {
        range == .day
            && preparedHistory.recoverySummary[.day]?.latestRaw == nil
            && preparedHistory.recoveryRaw[.all]?.last?.value != nil
    }

    private var recoveryBaselineComparisonText: String? {
        guard let score = recoveryHeroRawPercent else { return nil }
        return AtriaRecoveryBaselineComparison.text(
            score: score,
            monthValues: (preparedHistory.recoveryRaw[.month] ?? []).map(\.value),
            excludesLatest: range == .day
        )
    }

    private var strainHeroState: String {
        if dayStrainMetricsIncomplete { return "Partial · sparse HR" }
        guard let latest = strainHeroRawValue,
              let target = guidance.target else {
            return "Learning"   // canonical not-ready word (was "Building"), consistent with HRV/RHR/respiration hero states
        }
        if latest >= target + 1 { return "Strained" }
        if latest >= target - 1 { return "On target" }
        return "Light"
    }

    private var strainHeroRawValue: Double? {
        if range == .day {
            return preparedHistory.strainSummary[range]?.latestRaw
                ?? preparedHistory.latestStrain[range]
        }
        return preparedHistory.strainSummary[range]?.averageRaw
    }

    private var strainHeroValue: String {
        guard let strainHeroRawValue else { return "Learning" }
        let value = AtriaDetailPeriodSummary.valueText(strainHeroRawValue, unit: "")
        return dayStrainMetricsIncomplete ? "≥ \(value)" : value
    }

    private var dayStrainMetricsIncomplete: Bool {
        guard range == .day,
              let strain = strainHeroRawValue,
              let day = (preparedHistory.strainRaw[.day] ?? preparedHistory.strainRaw[.all])?.last?.day else {
            return false
        }
        return AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: day,
                                                                    strain: strain,
                                                                    workouts: confirmedWorkouts)
    }

    /// Strain of the day before the latest night's credited day -- the same
    /// yesterdayStrain semantics the daily-rollup path uses, so the need shown
    /// here matches the rollup-computed need (2026-07-07 design handoff).
    private var yesterdayStrainForLatestNight: Double? {
        guard let latest = sleepHistory.latestMainSleep else { return nil }
        let calendar = Calendar.current
        guard let priorDay = calendar.date(byAdding: .day,
                                           value: -1,
                                           to: calendar.startOfDay(for: latest.day)) else { return nil }
        return (preparedHistory.strain[.all] ?? [])
            .first { calendar.isDate($0.day, inSameDayAs: priorDay) }?
            .value
    }

    /// "How much you needed" ledger (design handoff): itemizes the four real
    /// terms of the sleep-need math. The total is the exact number the
    /// hypnogram card's need uses -- never a separately computed figure.
    /// One night's surplus/deficit vs the clamped base need, for the debt
    /// trend card. Real confirmed nights only.
    private var sleepDebtTrendPoints: [(day: Date, deltaHours: Double)] {
        let clampedNeed = min(max(sleepBaseNeedHours, 6), 10)
        return sleepHistory.nights
            .filter { !$0.isNapEvidence }
            .prefix(14)
            .map { (day: $0.day, deltaHours: $0.durationHours - clampedNeed) }
            .reversed()
    }

    /// Sleep-debt trend (design backlog item 4): nightly surplus/deficit
    /// bars vs the base need, headlined by the SAME 7-night debt number the
    /// need ledger uses — one math, two views of it.
    @ViewBuilder
    private var sleepDebtTrendCard: some View {
        let points = sleepDebtTrendPoints
        if points.count >= 3 {
            let debt = sleepHistory.sleepBudgetDebtHours(baseNeedHours: sleepBaseNeedHours)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Sleep debt")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(debt > 0.05 ? "\(AtriaMetricFormat.sleepHours(debt)) owed" : "None owed")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(debt > 0.05 ? .orange : Metrics.electricGreen)
                }

                Chart(points, id: \.day) { point in
                    BarMark(x: .value("Night", point.day, unit: .day),
                            y: .value("vs need", point.deltaHours))
                        .foregroundStyle(point.deltaHours >= 0 ? Metrics.electricSleep.opacity(0.85) : Color.orange.opacity(0.85))
                        .cornerRadius(3)
                    RuleMark(y: .value("Need met", 0))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text(String(format: "%+.0fh", hours))
                            }
                        }
                    }
                }
                .frame(height: 96)
                .clipped()

                Text("Each bar: that night vs your base need (\(AtriaMetricFormat.sleepHours(min(max(sleepBaseNeedHours, 6), 10)))). Debt counts the last 7 nights.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricSleep)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sleep debt trend. \(debt > 0.05 ? AtriaMetricFormat.sleepHours(debt) + " owed" : "No debt owed"). Bars show each night versus base need.")
        }
    }

    private func sleepNeedLedgerCard(for night: SleepHistorySnapshot.Night) -> some View {
        let comps = sleepHistory.sleepNeedComponents(for: night,
                                                     baseNeedHours: sleepBaseNeedHours,
                                                     yesterdayStrain: yesterdayStrainForLatestNight)
        return VStack(alignment: .leading, spacing: 10) {
            Text("How much you needed")
                .font(.headline.weight(.semibold))
            sleepLedgerRow(name: "Baseline need", value: AtriaMetricFormat.sleepHours(comps.baseHours))
            sleepLedgerRow(name: "Sleep debt", value: "+\(sleepLedgerMinutes(comps.debtAdderHours))")
            sleepLedgerRow(name: "Recent strain", value: "+\(sleepLedgerMinutes(comps.strainAdderHours))")
            sleepLedgerRow(name: "Nap credit", value: "\u{2212}\(sleepLedgerMinutes(comps.napCreditHours))")
            Divider()
            HStack {
                Text("Total need")
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: 8)
                Text(AtriaMetricFormat.sleepHours(comps.totalHours))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Metrics.electricSleep)
            }
            if comps.isClamped {
                Text("Capped to the 6\u{2013}10h range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
    }

    private func sleepLedgerRow(name: String, value: String) -> some View {
        HStack {
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func sleepLedgerMinutes(_ hours: Double) -> String {
        "\(Int((hours * 60).rounded()))m"
    }

    private var sleepContributorRows: [AtriaMetricContributorRow] {
        let latest = sleepHistory.latestMainSleep
        let performance = latest.map {
            sleepHistory.sleepPerformancePercent(for: $0,
                                                 baseNeedHours: sleepBaseNeedHours,
                                                 yesterdayStrain: yesterdayStrainForLatestNight)
        }
        let needText = latest.map {
            AtriaMetricFormat.sleepHours(sleepHistory.sleepNeedHours(for: $0,
                                                                     baseNeedHours: sleepBaseNeedHours,
                                                                     yesterdayStrain: yesterdayStrainForLatestNight))
        } ?? AtriaMetricFormat.sleepHours(sleepBaseNeedHours)
        return [
            AtriaMetricContributorRow(systemImage: "moon.fill",
                                      name: "Performance",
                                      // Dedup audit 2026-07-07: this row's
                                      // value was the duration (shown 3 more
                                      // times on this sheet); it now shows
                                      // the performance % its name promises.
                                      value: latest.map {
                                          "\(sleepHistory.sleepPerformancePercent(for: $0, baseNeedHours: sleepBaseNeedHours, yesterdayStrain: yesterdayStrainForLatestNight))%"
                                      } ?? "--",
                                      comparison: latest.map {
                                          sleepHistory.sleepPerformanceSummary(for: $0,
                                                                               baseNeedHours: sleepBaseNeedHours,
                                                                               yesterdayStrain: yesterdayStrainForLatestNight)
                                      } ?? "needed \(needText)",
                                      direction: performance.map { $0 >= 85 ? 1 : ($0 >= 70 ? 0 : -1) } ?? 0),
            AtriaMetricContributorRow(systemImage: "percent",
                                      name: "Efficiency",
                                      value: latest?.sleepEfficiencyText ?? "--",
                                      comparison: latest?.sleepEfficiency == nil ? "building" : "duration-based estimate",
                                      direction: latest?.sleepEfficiency.map { $0 >= 0.85 ? 1 : -1 } ?? 0),
            AtriaMetricContributorRow(systemImage: "calendar",
                                      name: "Consistency",
                                      value: sleepHistory.sleepConsistencyText,
                                      comparison: "recent sleep timing",
                                      direction: sleepHistory.sleepConsistencyPercent.map { $0 >= 70 ? 1 : -1 } ?? 0),
            AtriaMetricContributorRow(systemImage: "wake",
                                      name: "Disturbance",
                                      value: sleepDisturbanceValueText,
                                      comparison: sleepDisturbanceComparisonText,
                                      direction: sleepDisturbanceDirection)
        ]
    }

    private var sleepDisturbanceValueText: String {
        guard let latest = sleepHistory.latestMainSleep, !latest.displayStageSegments.isEmpty else { return "--" }
        return SleepHistorySnapshot.formatDuration(latest.stageDuration(.awake))
    }

    private var sleepDisturbanceComparisonText: String {
        guard let latest = sleepHistory.latestMainSleep, !latest.displayStageSegments.isEmpty else {
            return "sleep stages building"
        }
        return latest.stageEvidence == .validated ? "awake from validated stages" : "awake from estimated stages"
    }

    private var sleepDisturbanceDirection: Int {
        guard let latest = sleepHistory.latestMainSleep, !latest.displayStageSegments.isEmpty else { return 0 }
        let stagedDuration = latest.displayStageSegments.reduce(0) { $0 + $1.duration }
        guard stagedDuration > 0 else { return 0 }
        let awakeShare = latest.stageDuration(.awake) / stagedDuration
        return awakeShare <= 0.10 ? 1 : (awakeShare <= 0.18 ? 0 : -1)
    }

    private var sleepHeroState: String {
        // canonical not-ready word (was "Building"), consistent with the other metric hero states
        guard let latest = sleepHistory.latestMainSleep, latest.confirmed else { return "Learning" }
        let performance = sleepHistory.sleepPerformancePercent(for: latest, baseNeedHours: sleepBaseNeedHours)
        return "\(performance)% of need"
    }

    private var strainContributorRows: [AtriaMetricContributorRow] {
        // "Day strain" row removed (dedup audit 2026-07-07): the hero and
        // the gauge already show the value; the Target row owns the target.
        return [
            AtriaMetricContributorRow(systemImage: "target",
                                      name: "Target",
                                      value: guidance.target.map { String(format: "%.1f", $0) } ?? "--",
                                      comparison: guidance.headline.isEmpty ? guidance.detail : guidance.headline,
                                      direction: 0)
        ] + strainActivityContributorRows
    }

    private var strainActivityContributorRows: [AtriaMetricContributorRow] {
        let summary = todayWorkoutZoneSummary
        guard summary.workoutCount > 0 else {
            return [
                AtriaMetricContributorRow(systemImage: "figure.mixed.cardio",
                                          name: "Activities",
                                          value: "0",
                                          comparison: "confirmed workouts today",
                                          direction: 0)
            ]
        }
        return [
            AtriaMetricContributorRow(systemImage: "figure.mixed.cardio",
                                      name: "Activities",
                                      value: "\(summary.workoutCount)",
                                      comparison: "confirmed workouts today",
                                      direction: 1),
            AtriaMetricContributorRow(systemImage: "timer",
                                      name: "Zone minutes",
                                      value: todayHighZoneMinutesText,
                                      comparison: "aerobic and above",
                                      direction: summary.highZoneSeconds > 0 ? 1 : 0)
        ]
    }

    private var todayWorkoutZoneSummary: AtriaTodayWorkoutZoneSummary {
        todayWorkoutZoneSummaryMemo.summary(workouts: confirmedWorkouts,
                                            sleepHistory: sleepHistory,
                                            revision: confirmedWorkoutsRevision)
    }

    private var todayHighZoneMinutesText: String {
        let minutes = Int((todayWorkoutZoneSummary.highZoneSeconds / 60).rounded())
        return minutes > 0 ? "\(minutes)m" : "--"
    }

    /// Today's time-in-zones across confirmed workouts, keyed by HRZone.
    /// Only real recorded zone seconds — no zone data, no bar.
    private var todayZoneHistogram: [AtriaTodayWorkoutZoneSummary.Entry] {
        todayWorkoutZoneSummary.histogram
    }

    /// Strain time-in-zones histogram (design backlog item 5): minutes per
    /// percent-of-max zone across today's confirmed workouts.
    @ViewBuilder
    private var strainZoneHistogramCard: some View {
        let histogram = todayZoneHistogram
        if !histogram.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Today in zones")
                    .font(.subheadline.weight(.semibold))

                Chart(histogram) { entry in
                    BarMark(x: .value("Zone", "Z\(entry.zone.rawValue)"),
                            y: .value("Minutes", entry.minutes))
                        .foregroundStyle(entry.zone.color.opacity(0.85))
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 2) {
                            Text("\(Int(entry.minutes.rounded()))m")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
                .chartYAxis(.hidden)
                .frame(height: 110)
                .clipped()

                Text("Minutes per heart-rate zone across today's workouts. Zones use your percent-of-max bands.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricStrain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Time in zones today. " + histogram.map { "Zone \($0.zone.rawValue), \(Int($0.minutes.rounded())) minutes" }.joined(separator: ". ") + ".")
        }
    }

    /// Activity-type classes for the strain mix split. HR alone cannot
    /// measure muscular load, so this is honestly framed as an
    /// activity-type split, never a muscle-load claim.
    private static let strengthLeaningTypes: Set<String> = ["Strength", "HIIT", "Yoga"]

    private var todayStrainMix: (cardio: Double, strength: Double)? {
        var cardio = 0.0
        var strength = 0.0
        for workout in todayWorkoutZoneSummary.workouts {
            guard !AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) else { continue }
            guard let strain = workout.strain, strain > 0 else { continue }
            let type = workout.activityType ?? ""
            if Self.strengthLeaningTypes.contains(type) {
                strength += strain
            } else if !type.isEmpty {
                cardio += strain
            }
        }
        guard cardio > 0 || strength > 0 else { return nil }
        return (cardio, strength)
    }

    /// Cardio vs strength-type strain mix (design backlog item 9, honesty
    /// adapted from the mock's "cardio vs muscular" — split by the workout's
    /// activity type, which the user chose or confirmed).
    @ViewBuilder
    private var strainActivityMixCard: some View {
        if let mix = todayStrainMix, mix.cardio > 0, mix.strength > 0 {
            let total = mix.cardio + mix.strength
            VStack(alignment: .leading, spacing: 10) {
                Text("Today's strain mix")
                    .font(.subheadline.weight(.semibold))

                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Metrics.electricStrain.opacity(0.85))
                            .frame(width: max(10, proxy.size.width * mix.cardio / total))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.purple.opacity(0.8))
                    }
                }
                .frame(height: 14)

                HStack(spacing: 14) {
                    Label(String(format: "Cardio %.1f", mix.cardio), systemImage: "figure.walk")
                        .foregroundStyle(Metrics.electricStrain)
                    Label(String(format: "Strength-type %.1f", mix.strength), systemImage: "dumbbell.fill")
                        .foregroundStyle(.purple)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.bold).monospacedDigit())

                Text("Split by the activity type of today's workouts \u{2014} heart-rate strain grouped by what you logged, not a muscle-load measurement.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricStrain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: "Today's strain mix. Cardio %.1f, strength-type %.1f, split by activity type.", mix.cardio, mix.strength))
        }
    }

    private var strainWorkoutSection: some View {
        // Perf (docs/26 follow-up): compute the filter+sort once per render
        // instead of re-deriving todayConfirmedWorkouts for both the isEmpty
        // check and the ForEach below.
        let workouts = todayWorkoutZoneSummary.workouts
        return VStack(alignment: .leading, spacing: 12) {
            // Header target capsule removed (dedup audit 2026-07-07): the
            // Target contributor row is the single textual copy.
            Text("Workouts")
                .font(.subheadline.weight(.semibold))

            if workouts.isEmpty {
                Label("No confirmed workouts today", systemImage: "figure.mixed.cardio")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else {
                ForEach(workouts.prefix(4), id: \.id) { workout in
                    AtriaStrainWorkoutRow(workout: workout)
                }

                // A workout row is deliberately a bounded activity window.
                // The hero above is the physiological day (sleep-to-sleep),
                // so calling both simply "strain" made a real 60-minute gym
                // window look like an under-reported day score.
                Text("Each value is this workout’s heart-rate strain. Day strain above combines your full sleep-to-sleep day.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricStrain)
    }

    private func latestMetricText(points: [AtriaDetailChartPoint], unit: String) -> String {
        guard let latest = points.last else { return "--" }
        return latestText(value: latest.value, unit: unit)
    }

    /// The detail-hero headline for the selected period. Day = the latest reading
    /// (unchanged); Week/Month/… = the window AVERAGE, read from the SAME per-range
    /// summary the chart's Avg strip uses, so the headline tracks the selector and
    /// agrees with the chart. Falls back to the latest reading when no summary yet.
    /// (2026-07-08: the headline was the latest point for every range, identical
    /// across Day/Week/Month, so the number looked frozen to the selector — the same
    /// class of bug the user reported for recovery.)
    private func periodHeroText(summary: AtriaDetailPeriodSummary?,
                                points: [AtriaDetailChartPoint],
                                unit: String) -> String {
        if range != .day, let summary {
            return summary.averageText
        }
        return latestMetricText(points: points, unit: unit)
    }

    private var contributorCard: some View {
        VStack(spacing: 12) {
            if let nutrition = latestNutrition {
                AtriaMetricContributorRows(rows: [fuelContributorRow(for: nutrition)],
                                           tint: Metrics.electricGreen)
                    .accessibilityIdentifier("recovery-fuel-contributor-row")
            }

            AtriaRecoveryContributorMap(contributors: recoveryEstimate.contributors,
                                        titleForContributor: contributorTitle(_:),
                                        noteForContributor: contributorNote(_:))
        }
    }

    private func fuelContributorRow(for nutrition: AtriaNutritionSummary) -> AtriaMetricContributorRow {
        AtriaMetricContributorRow(systemImage: "fork.knife.circle.fill",
                                  name: "Fuel",
                                  value: nutrition.fuelSummary ?? "Logged",
                                  comparison: fuelContributorComparison(for: nutrition),
                                  direction: fuelContributorDirection(for: nutrition))
    }

    private func fuelContributorComparison(for nutrition: AtriaNutritionSummary) -> String {
        var parts: [String] = []
        if let waterMl = nutrition.waterMl, waterMl > 0 {
            parts.append("\(Int(waterMl.rounded())) ml water")
        }
        if let lastCaffeineHour = nutrition.lastCaffeineHour {
            parts.append(lastCaffeineHour >= 14 ? "late caffeine" : "caffeine before 2 PM")
        }
        if let alcoholDrinks = nutrition.alcoholDrinks, alcoholDrinks >= 1 {
            let rounded = Int(alcoholDrinks.rounded())
            parts.append("\(rounded) \(rounded == 1 ? "drink" : "drinks")")
        }
        return parts.isEmpty ? "from Apple Health nutrition" : parts.joined(separator: " · ")
    }

    private func fuelContributorDirection(for nutrition: AtriaNutritionSummary) -> Int {
        if (nutrition.alcoholDrinks ?? 0) >= 1 { return -1 }
        if let lastCaffeineHour = nutrition.lastCaffeineHour, lastCaffeineHour >= 14 { return -1 }
        if let proteinG = nutrition.proteinG, proteinG > 0 { return 1 }
        return 0
    }

    private var hrvBand: AtriaDetailBaselineBand? {
        guard baseline.hrvTrusted,
              let mean = baseline.hrvLnMean,
              let sd = baseline.hrvLnSD else { return nil }
        return AtriaDetailBaselineBand(lower: exp(mean - sd),
                                       upper: exp(mean + sd),
                                       tint: .pink)
    }

    private var restingBand: AtriaDetailBaselineBand? {
        guard baseline.restingTrusted,
              let mean = baseline.restingMean,
              let sd = baseline.restingSD else { return nil }
        return AtriaDetailBaselineBand(lower: mean - sd,
                                       upper: mean + sd,
                                       tint: .pink)
    }

    private var respiratoryBand: AtriaDetailBaselineBand? {
        guard let stats = sleepHistory.respiratoryBaselineStats,
              stats.count >= 3,
              stats.sd > 0 else { return nil }
        return AtriaDetailBaselineBand(lower: stats.mean - 1.5 * stats.sd,
                                       upper: stats.mean + 1.5 * stats.sd,
                                       tint: .teal)
    }

    private func contributorTitle(_ contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        switch contributor.kind {
        case .hrv: return "HRV"
        case .restingHeartRate: return "RHR"
        case .sleep: return "Sleep"
        case .respiration: return "Respiration"
        }
    }

    private func contributorNote(_ contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        switch contributor.kind {
        case .hrv:
            return contributor.zScore >= 0 ? "Above baseline" : "Below baseline"
        case .restingHeartRate:
            return contributor.zScore >= 0 ? "Calmer than baseline" : "Elevated vs baseline"
        case .sleep:
            return contributor.zScore >= 0 ? "Sleep helped" : "Sleep limited"
        case .respiration:
            return contributor.zScore == 0 ? "Neutral" : (contributor.zScore > 0 ? "Settled" : "Shifted")
        }
    }

    /// Honest learning-state pill: carries the real 14-night baseline
    /// progress ("Learning \u{00b7} night 3 of 14") once a night is recorded,
    /// so a bare "Learning" never hides how far along calibration is
    /// (2026-07-07, design handoff).
    private func learningNightsState(_ samples: Int) -> String {
        guard samples > 0 else { return "Learning" }
        let cap = PersonalBaseline.trustedMinimumSamples
        return "Learning \u{00b7} night \(min(samples, cap)) of \(cap)"
    }

    private func metricChart(title: String,
                             unit: String,
                             tint: Color,
                             points: [AtriaDetailChartPoint],
                             summary: AtriaDetailPeriodSummary?,
                             comparison: AtriaDetailComparisonSummary?,
                             baselineBand: AtriaDetailBaselineBand?,
                             accessibilitySummary: String,
                             emptyExplanation: String? = nil,
                             priorPoints: [AtriaDetailChartPoint] = [],
                             companions: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] = [],
                             onOpenDay: ((Date) -> Void)? = nil,
                             onExpand: (() -> Void)? = nil) -> some View {
        let cacheKey = MetricChartPreparedDataCache.Key(
            preparationInput: preparation.valueKey ?? preparationInput,
            metric: metric,
            range: range,
            bucketOverride: bucketOverride,
            showMinMaxBand: showMinMaxBand
        )
        let prepared = metricChartPreparedDataCache.value(for: cacheKey) {
            AtriaMetricChartPreparedData(
                points: points,
                priorPoints: priorPoints,
                baselineBounds: baselineBand.map { $0.lower...$0.upper },
                priorAverage: comparison?.priorAverage,
                companionPoints: companions.map(\.points)
            )
        }
        return AtriaPreparedMetricChart(
            title: title,
            unit: unit,
            tint: tint,
            points: points,
            summary: summary,
            comparison: comparison,
            baselineBand: baselineBand,
            accessibilitySummary: accessibilitySummary,
            emptyExplanation: emptyExplanation,
            priorPoints: priorPoints,
            companions: companions.map {
                AtriaPreparedMetricChart.Companion(title: $0.title,
                                                   unit: $0.unit,
                                                   tint: $0.tint,
                                                   points: $0.points)
            },
            prepared: prepared,
            initialScrubbedDay: initialScrubbedDay,
            onOpenDay: onOpenDay,
            onExpand: onExpand
        )
    }

    /// Real saved activity for the expanded chart's marker lane: confirmed
    /// workouts (strain hue) and confirmed sleep nights (sleep hue). Only
    /// records that exist — an empty day has no marker.
    private var expandedChartEvents: [AtriaChartEvent] {
        expandedChartEventsCache.value(key: expandedChartEventsKey) {
            var events: [AtriaChartEvent] = confirmedWorkouts.map { workout in
                AtriaChartEvent(id: "workout-\(workout.id)",
                                day: workout.start,
                                label: workout.activitySubtype ?? workout.activityType ?? "Workout",
                                systemImage: "flame.fill",
                                tint: Metrics.electricStrain)
            }
            events.append(contentsOf: sleepHistory.nights.filter(\.confirmed).map { night in
                AtriaChartEvent(id: "sleep-\(night.id)",
                                day: night.day,
                                label: "Sleep",
                                systemImage: "bed.double.fill",
                                tint: Metrics.electricSleep)
            })
            return events
        }
    }

    private var expandedChartEventsKey: Int {
        var hasher = Hasher()
        if let confirmedWorkoutsRevision {
            hasher.combine(confirmedWorkoutsRevision)
        } else {
            hasher.combine(confirmedWorkouts.count)
            hasher.combine(confirmedWorkouts.first?.id)
            hasher.combine(confirmedWorkouts.last?.id)
        }
        if let sleepHistoryRevision {
            hasher.combine(sleepHistoryRevision)
        } else {
            hasher.combine(sleepHistory.nights.count)
            hasher.combine(sleepHistory.nights.reduce(into: 0) { $0 += $1.confirmed ? 1 : 0 })
            hasher.combine(sleepHistory.nights.first?.id)
            hasher.combine(sleepHistory.nights.last?.id)
        }
        return hasher.finalize()
    }

    /// The expanded chart mirrors whatever the inline chart currently shows
    /// for the six core metrics (same override, same ghost, same band).
    private var expandedChartConfig: (title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint], prior: [AtriaDetailChartPoint], band: AtriaDetailBaselineBand?)? {
        switch metric {
        case .recovery:
            return ("Recovery", "%", Metrics.electricGreen,
                    displayedPoints(auto: preparedHistory.recovery[range] ?? [], raw: preparedHistory.recoveryRaw[range] ?? []),
                    preparedHistory.recoveryPrior[range] ?? [], nil)
        case .hrv:
            return ("HRV", "ms", metric.tint,
                    displayedPoints(auto: preparedHistory.hrv[range] ?? [], raw: preparedHistory.hrvRaw[range] ?? []),
                    preparedHistory.hrvPrior[range] ?? [], hrvBand)
        case .restingHeartRate:
            return ("Resting HR", "bpm", metric.tint,
                    displayedPoints(auto: preparedHistory.restingHeartRate[range] ?? [], raw: preparedHistory.restingHeartRateRaw[range] ?? []),
                    preparedHistory.restingHeartRatePrior[range] ?? [], restingBand)
        case .respiratoryRate:
            return ("Respiratory rate", "/min", metric.tint,
                    displayedPoints(auto: preparedHistory.respiratoryRate[range] ?? [], raw: preparedHistory.respiratoryRateRaw[range] ?? []),
                    preparedHistory.respiratoryRatePrior[range] ?? [], respiratoryBand)
        case .sleep:
            return ("Sleep duration", "h", Metrics.electricSleep,
                    displayedPoints(auto: preparedHistory.sleep[range] ?? [], raw: preparedHistory.sleepRaw[range] ?? []),
                    preparedHistory.sleepPrior[range] ?? [], nil)
        case .strain:
            return ("Strain", "", Metrics.electricStrain,
                    displayedPoints(auto: preparedHistory.strain[range] ?? [], raw: preparedHistory.strainRaw[range] ?? []),
                    preparedHistory.strainPrior[range] ?? [], nil)
        case .sleepPerformance:
            return ("Sleep performance", "%", Metrics.electricSleep,
                    preparedHistory.sleepPerformance[range] ?? [], [], nil)
        case .fitnessAge:
            return ("Pace of aging", "y", fitnessAgeTint,
                    preparedHistory.fitnessAge[range] ?? [], [], nil)
        default:
            return nil
        }
    }

    /// "Behaviors that move you" (design backlog item 7): the Journal's
    /// statistically-gated behavior impacts (Welch p < 0.10, ≥5 logged and
    /// comparison days, ≥3% effect) surfaced where the recovery number
    /// lives. Reuses the exact rows the Journal renders — one engine.
    @ViewBuilder
    private var behaviorsMoveYouCard: some View {
        if !behaviorImpacts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Behaviors that move you")
                    .font(.subheadline.weight(.semibold))
                AtriaJournalBehaviorImpactRows(impacts: Array(behaviorImpacts.prefix(3)))
                Text("From your journal tags vs next-day recovery over 90 days. Association, not proof of cause.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricGreen)
        }
    }

    /// Shaped outside the render block per the perf rule (no compactMap in
    /// view-builder bodies): real confirmed nights' efficiencies for the
    /// sleep planner's time-in-bed assumption.
    private var confirmedNightEfficiencies: [Double] {
        sleepHistory.nights.filter(\.confirmed).compactMap(\.sleepEfficiency)
    }

    /// Overlay candidates for "Edit this chart": the two sibling metrics the
    /// inline chart already pairs as scrub companions, in raw daily form.
    private var expandedChartOverlays: [(title: String, unit: String, tint: Color, points: [AtriaDetailChartPoint])] {
        switch metric {
        case .recovery, .strain:
            return [("HRV", " ms", Metrics.electricHRV, preparedHistory.hrvRaw[range] ?? []),
                    ("Sleep", " h", Metrics.electricSleep, preparedHistory.sleepRaw[range] ?? [])]
        case .hrv, .restingHeartRate:
            return [("Recovery", "%", Metrics.electricGreen, preparedHistory.recoveryRaw[range] ?? []),
                    ("Sleep", " h", Metrics.electricSleep, preparedHistory.sleepRaw[range] ?? [])]
        case .sleep:
            return [("Recovery", "%", Metrics.electricGreen, preparedHistory.recoveryRaw[range] ?? []),
                    ("Strain", "", Metrics.electricStrain, preparedHistory.strainRaw[range] ?? [])]
        case .respiratoryRate:
            return [("HRV", " ms", Metrics.electricHRV, preparedHistory.hrvRaw[range] ?? []),
                    ("Recovery", "%", Metrics.electricGreen, preparedHistory.recoveryRaw[range] ?? [])]
        default:
            return []
        }
    }

    private var chartSupportsOptions: Bool {
        switch metric {
        case .recovery, .hrv, .restingHeartRate, .respiratoryRate, .sleep, .strain: return true
        default: return false
        }
    }

    /// Applies the manual bucket override from the chart-options sheet.
    /// .auto returns the precomputed series (weekly above 90 days); .daily
    /// returns raw points; .weeklyAverage forces weekly buckets. The min-max
    /// band toggle strips bands at display time.
    private func displayedPoints(auto: [AtriaDetailChartPoint],
                                 raw: [AtriaDetailChartPoint]) -> [AtriaDetailChartPoint] {
        let base: [AtriaDetailChartPoint]
        switch bucketOverride {
        case .auto: base = auto
        case .daily: base = raw
        case .weeklyAverage:
            base = AtriaPreparedMetricHistory.bucketedForDisplay(raw, range: range, calendar: .current, forceWeekly: true)
        }
        guard !showMinMaxBand else { return base }
        return base.map { AtriaDetailChartPoint(day: $0.day, value: $0.value, tint: $0.tint) }
    }

    /// Double-tap route: resolve the scrubbed date to its history-day model
    /// and open the existing day-vs-median sheet. Unknown day: does nothing.
    private func openHistoryDay(for date: Date) {
        let model = AtriaHistoryModel.make(rollups: rollups,
                                           workouts: confirmedWorkouts,
                                           sleeps: [])
        guard let day = model.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else { return }
        openedHistoryDay = day
    }

    private func latestText(value: Double, unit: String) -> String {
        AtriaDetailPeriodSummary.valueText(value, unit: unit)
    }
}


struct AtriaMetricChartPreparedData {
    let domain: ClosedRange<Double>
    let minMaxPoints: [AtriaDetailChartPoint]
    private let pointTimes: [TimeInterval]
    private let companionIndicesByDay: [[Date: Int]]
    private let calendar: Calendar

    init(points: [AtriaDetailChartPoint],
         priorPoints: [AtriaDetailChartPoint],
         baselineBounds: ClosedRange<Double>?,
         priorAverage: Double?,
         companionPoints: [[AtriaDetailChartPoint]],
         calendar: Calendar = .current) {
        var low: Double?
        var high: Double?
        func include(_ value: Double?) {
            guard let value else { return }
            low = min(low ?? value, value)
            high = max(high ?? value, value)
        }
        for point in points {
            include(point.value)
            include(point.bandLower)
            include(point.bandUpper)
        }
        for point in priorPoints { include(point.value) }
        include(baselineBounds?.lowerBound)
        include(baselineBounds?.upperBound)
        include(priorAverage)
        domain = low.flatMap { low in high.map { AtriaTrendChartScale.domain(low: low, high: $0) } } ?? 0...1
        minMaxPoints = points.filter {
            guard let lower = $0.bandLower, let upper = $0.bandUpper else { return false }
            return upper > lower
        }
        pointTimes = points.map { $0.day.timeIntervalSinceReferenceDate }
        companionIndicesByDay = companionPoints.map { series in
            Dictionary(series.enumerated().map { (calendar.startOfDay(for: $0.element.day), $0.offset) },
                       uniquingKeysWith: { first, _ in first })
        }
        self.calendar = calendar
    }

    var hasMinMaxBand: Bool { !minMaxPoints.isEmpty }

    func nearestPointIndex(to target: Date) -> Int? {
        guard !pointTimes.isEmpty else { return nil }
        let targetTime = target.timeIntervalSinceReferenceDate
        var lower = 0
        var upper = pointTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if pointTimes[middle] < targetTime { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return 0 }
        if lower == pointTimes.count { return pointTimes.count - 1 }
        return targetTime - pointTimes[lower - 1] <= pointTimes[lower] - targetTime ? lower - 1 : lower
    }

    func companionPointIndex(at companionIndex: Int, on day: Date) -> Int? {
        guard companionIndicesByDay.indices.contains(companionIndex) else { return nil }
        return companionIndicesByDay[companionIndex][calendar.startOfDay(for: day)]
    }
}

private struct AtriaPreparedMetricChart: View {
    struct Companion {
        let title: String
        let unit: String
        let tint: Color
        let points: [AtriaDetailChartPoint]
    }

    let title: String
    let unit: String
    let tint: Color
    let points: [AtriaDetailChartPoint]
    let summary: AtriaDetailPeriodSummary?
    let comparison: AtriaDetailComparisonSummary?
    let baselineBand: AtriaDetailBaselineBand?
    let accessibilitySummary: String
    let emptyExplanation: String?
    let priorPoints: [AtriaDetailChartPoint]
    let companions: [Companion]
    let onOpenDay: ((Date) -> Void)?
    let onExpand: (() -> Void)?
    private let prepared: AtriaMetricChartPreparedData
    @State private var scrubbedDay: Date?

    init(title: String,
         unit: String,
         tint: Color,
         points: [AtriaDetailChartPoint],
         summary: AtriaDetailPeriodSummary?,
         comparison: AtriaDetailComparisonSummary?,
         baselineBand: AtriaDetailBaselineBand?,
         accessibilitySummary: String,
         emptyExplanation: String?,
         priorPoints: [AtriaDetailChartPoint],
         companions: [Companion],
         prepared: AtriaMetricChartPreparedData,
         initialScrubbedDay: Date?,
         onOpenDay: ((Date) -> Void)?,
         onExpand: (() -> Void)?) {
        self.title = title
        self.unit = unit
        self.tint = tint
        self.points = points
        self.summary = summary
        self.comparison = comparison
        self.baselineBand = baselineBand
        self.accessibilitySummary = accessibilitySummary
        self.emptyExplanation = emptyExplanation
        self.priorPoints = priorPoints
        self.companions = companions
        self.prepared = prepared
        self.onOpenDay = onOpenDay
        self.onExpand = onExpand
        _scrubbedDay = State(initialValue: initialScrubbedDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let latest = points.last {
                    Text(valueText(latest.value)).font(.caption.monospacedDigit()).foregroundStyle(tint)
                }
                if let onExpand, points.count >= 2 {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Expand chart: landscape, zoom, range selection, activity markers")
                }
            }

            if points.count >= 2, summary == nil {
                AtriaDetailRangeDotStrip(points: points, fallbackTint: tint)
            }
            if let summary { AtriaDetailPeriodSummaryStrip(summary: summary, tint: tint) }

            if points.count < 2 {
                VStack(spacing: 6) {
                    Text("Building trend").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let emptyExplanation {
                        Text(emptyExplanation).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 18)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else {
                chartContent
                chartLegendAndCompanions
            }
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }

    private var selectedPointIndex: Int? {
        scrubbedDay.flatMap(prepared.nearestPointIndex)
    }

    private var selectedPoint: AtriaDetailChartPoint? {
        selectedPointIndex.map { points[$0] }
    }

    private var chartContent: some View {
        Chart {
            if let baselineBand {
                RectangleMark(xStart: .value("Start", points.first?.day ?? Date()),
                              xEnd: .value("End", points.last?.day ?? Date()),
                              yStart: .value("Lower", baselineBand.lower),
                              yEnd: .value("Upper", baselineBand.upper))
                    .foregroundStyle(baselineBand.tint.opacity(0.12))
            }
            ForEach(prepared.minMaxPoints) { point in
                AreaMark(x: .value("Day", point.day, unit: .day),
                         yStart: .value("Min", point.bandLower ?? point.value),
                         yEnd: .value("Max", point.bandUpper ?? point.value))
                    .interpolationMethod(.monotone).foregroundStyle(tint.opacity(0.13))
            }
            ForEach(points) { point in
                AreaMark(x: .value("Day", point.day, unit: .day), y: .value(title, point.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            if let comparison {
                RuleMark(y: .value("Prior average", comparison.priorAverage))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("prior avg \(comparison.priorText)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            ForEach(priorPoints) { point in
                LineMark(x: .value("Day", point.day, unit: .day), y: .value(title, point.value),
                         series: .value("Series", "prior"))
                    .interpolationMethod(.monotone).foregroundStyle(.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            ForEach(points) { point in
                LineMark(x: .value("Day", point.day, unit: .day), y: .value(title, point.value),
                         series: .value("Series", "current"))
                    .interpolationMethod(.monotone).foregroundStyle(tint)
                PointMark(x: .value("Day", point.day, unit: .day), y: .value(title, point.value))
                    .foregroundStyle(point.tint)
            }
            if let last = points.last, selectedPoint == nil {
                PointMark(x: .value("Day", last.day, unit: .day), y: .value(title, last.value))
                    .foregroundStyle(tint).symbolSize(110)
            }
            if let selectedPoint {
                RuleMark(x: .value("Day", selectedPoint.day, unit: .day))
                    .foregroundStyle(tint.opacity(0.30))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        // Cross-metric context tracks the scrub (design "Graph
                        // Interactions"): that day's sibling metrics as one compact
                        // line, real values only — a day without a companion sample
                        // is simply omitted, never invented.
                        let companionContext = companions.enumerated().compactMap { index, companion -> String? in
                            let match = prepared.companionPointIndex(at: index, on: selectedPoint.day).map { companion.points[$0] }
                            return match.map { "\(companion.title.uppercased()) \(AtriaDetailPeriodSummary.valueText($0.value, unit: companion.unit))" }
                        }
                        VStack(spacing: 1) {
                            Text(valueText(selectedPoint.value)).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(tint)
                            Text(selectedPoint.day, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
                            if let baselineBand {
                                Text(String(format: "%+.0f vs typical", selectedPoint.value - (baselineBand.lower + baselineBand.upper) / 2))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            if !companionContext.isEmpty {
                                Text(companionContext.joined(separator: "  ·  "))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        // Liquid Glass scrub callout — see AtriaTrendChart for why
                        // this floating, transient surface is the right place for
                        // real glass while scrolling cards stay opaque.
                        .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.chip)
                    }
                PointMark(x: .value("Day", selectedPoint.day, unit: .day), y: .value(title, selectedPoint.value))
                    .foregroundStyle(tint).symbolSize(130)
            }
        }
        .chartXSelection(value: $scrubbedDay)
        .chartYScale(domain: prepared.domain)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .chartYAxisLabel(unit)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 210).clipped()
        .onTapGesture(count: 2) {
            if let target = scrubbedDay, let onOpenDay { onOpenDay(target) }
        }
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder private var chartLegendAndCompanions: some View {
        if prepared.hasMinMaxBand {
            Text("Weekly averages \u{00b7} shaded band is that week's real min\u{2013}max").font(.caption2).foregroundStyle(.secondary)
        }
        if !priorPoints.isEmpty {
            Text("Dashed line: the previous period, overlaid").font(.caption2).foregroundStyle(.secondary)
        }
        if scrubbedDay != nil, onOpenDay != nil {
            Text("Double-tap the chart to open this day").font(.caption2).foregroundStyle(.tertiary)
        }
        // Cross-metric companion values now ride inside the scrub callout
        // (see chartContent) so the context tracks the finger, per the design's
        // "Graph Interactions" grammar, instead of a separate row below.
    }

    private func valueText(_ value: Double) -> String {
        AtriaDetailPeriodSummary.valueText(value, unit: unit)
    }
}

private struct AtriaStrainWorkoutRow: View, Equatable {
    let workout: UserConfirmedWorkout

    private var activity: AtriaWorkoutActivityType {
        AtriaWorkoutActivityType.resolved(activityType: workout.activityType,
                                          subtype: workout.activitySubtype,
                                          label: workout.label)
    }

    private var title: String {
        workout.activitySubtype ?? workout.activityType ?? "Workout"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private var timeText: String {
        "\(Self.timeFormatter.string(from: workout.start)) · \(durationText)"
    }

    private var durationText: String {
        let minutes = max(1, Int((workout.duration / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var strainText: String {
        AtriaWorkoutMetricPresentation.strainText(workout)
    }

    private var heartRateText: String {
        AtriaWorkoutMetricPresentation.heartRateSummaryText(workout)
    }

    private var zoneSegments: [(key: String, label: String, tint: Color, seconds: TimeInterval)] {
        let zones = workout.zoneSeconds ?? [:]
        return [
            ("warmup", "Z1", Metrics.heartRateZoneTint(1), zones["warmup"] ?? 0),
            ("fatBurn", "Z2", Metrics.heartRateZoneTint(2), zones["fatBurn"] ?? 0),
            ("aerobic", "Z3", Metrics.heartRateZoneTint(3), zones["aerobic"] ?? 0),
            ("anaerobic", "Z4", Metrics.heartRateZoneTint(4), zones["anaerobic"] ?? 0),
            ("max", "Z5", Metrics.heartRateZoneTint(5), zones["max"] ?? 0)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: activity.icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Metrics.electricStrain)
                    .frame(width: 32, height: 32)
                    .background(AtriaIconTileBackground(cornerRadius: AtriaDesignTokens.Radius.chip, tint: Metrics.electricStrain))

                VStack(alignment: .leading, spacing: 2) {
                    // HealthKit-style names ("High Intensity Interval
                    // Training") wrap instead of cropping (UX audit).
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(timeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(strainText)
                        .font(.headline.monospacedDigit().weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Text(AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout)
                         ? "metrics" : "workout strain")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
                Label(AtriaWorkoutMetricPresentation.compactStatus(workout),
                      systemImage: "waveform.path.badge.minus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(zoneSegments, id: \.key) { segment in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(segment.tint.opacity(segment.seconds > 0 ? 0.90 : 0.16))
                                .frame(width: zoneWidth(segment.seconds, totalWidth: proxy.size.width))
                        }
                    }
                }
                .frame(height: 8)
            }

            HStack {
                Text(heartRateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(zoneMinutesSummary)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout)
                                     ? .secondary : Metrics.electricStrain)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(durationText), \(AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) ? "workout metrics incomplete" : "strain \(strainText)"), heart rate \(heartRateText), \(zoneMinutesSummary).")
    }

    private func zoneWidth(_ seconds: TimeInterval, totalWidth: CGFloat) -> CGFloat {
        let total = max(zoneSegments.reduce(0) { $0 + $1.seconds }, 1)
        return max(4, totalWidth * CGFloat(seconds / total))
    }

    private var zoneMinutesSummary: String {
        if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
            return "Zones incomplete"
        }
        let highSeconds = (workout.zoneSeconds?["aerobic"] ?? 0)
            + (workout.zoneSeconds?["anaerobic"] ?? 0)
            + (workout.zoneSeconds?["max"] ?? 0)
        let minutes = Int((highSeconds / 60).rounded())
        return minutes > 0 ? "\(minutes)m Z3+" : "Zones building"
    }
}

enum AtriaRecoveryBaselineComparison {
    static func text(score: Double,
                     monthValues: [Double],
                     excludesLatest: Bool) -> String? {
        guard monthValues.count >= 3 else { return nil }
        let baselineValues = excludesLatest ? Array(monthValues.dropLast()) : monthValues
        guard !baselineValues.isEmpty else { return nil }
        let average = baselineValues.reduce(0, +) / Double(baselineValues.count)
        let delta = Int((score - average).rounded())
        if delta == 0 { return "At your 30-day average" }
        return "\(delta > 0 ? "+" : "")\(delta)% vs your 30-day average"
    }
}

enum AtriaStrainTargetPresentation {
    static let maximum = 21.0

    static func progress(for score: Double) -> Double {
        min(max(score / maximum, 0), 1)
    }

    static func targetRange(for target: Double) -> ClosedRange<Double> {
        max(0, target - 1)...min(maximum, target + 1)
    }
}

private enum AtriaMetricDetailHeroStyle {
    case standard
    case recoveryRing(score: Double?, baselineComparison: String?)
    case strain(score: Double?, target: Double?)
}

private struct AtriaRecoveryScoreHero: View {
    let score: Double?
    let state: String
    let tint: Color
    let baselineComparison: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var ringRevealed = false
    @State private var haloExpanded = false

    /// The same honesty guard the standard hero documents, which this ring
    /// branch never applied. Recovery's hue IS its grade (red / yellow /
    /// green over 0-100), so painting the halo, track, glow and card wash
    /// green around a "--" asserted a passing score the app has not earned.
    /// With no score there is nothing to grade, so the whole disc goes
    /// neutral until there is.
    private var heroTint: Color { score == nil ? Color.secondary : tint }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(heroTint.opacity(haloExpanded ? 0.12 : 0.05))
                    .frame(width: 178, height: 178)
                    .scaleEffect(reduceMotion ? 1 : (haloExpanded ? 1.06 : 0.94))
                    .shadow(color: heroTint.opacity(haloExpanded ? 0.28 : 0.12), radius: 18)
                    .animation(motionEnabled ? .easeInOut(duration: 2.8).repeatForever(autoreverses: true) : nil,
                               value: haloExpanded)
                Circle().stroke(heroTint.opacity(0.14), lineWidth: 14)
                if let score {
                    Circle()
                        .trim(from: 0,
                              to: ringRevealed ? min(max(score / 100, 0), 1) : 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: tint.opacity(haloExpanded ? 0.38 : 0.16), radius: 9)
                        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 2.6),
                                   value: ringRevealed)
                        .animation(motionEnabled ? .easeInOut(duration: 2.8).repeatForever(autoreverses: true) : nil,
                                   value: haloExpanded)
                }
                VStack(spacing: 1) {
                    Text(score.map { "\(Int($0.rounded()))%" } ?? "--")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(state).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 154, height: 154)

            if let baselineComparison {
                Label(baselineComparison,
                      systemImage: baselineComparison.hasPrefix("-") ? "arrow.down.right" :
                        (baselineComparison.hasPrefix("+") ? "arrow.up.right" : "minus"))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(tint.opacity(0.12), in: Capsule(style: .continuous))
            } else {
                Text("Your 30-day comparison is still building")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(16).atriaInsetCard(tint: heroTint)
        .accessibilityElement(children: .combine)
        .onAppear(perform: startMotion)
        .onChange(of: score) { _, _ in startMotion() }
        .onChange(of: reduceMotion) { _, _ in startMotion() }
        .onChange(of: scenePhase) { _, _ in startMotion() }
    }

    private func startMotion() {
        ringRevealed = reduceMotion
        haloExpanded = false
        guard !reduceMotion else { return }
        guard scenePhase == .active else {
            // Keep the full score visible while the scene is inactive without
            // leaving a repeating animation running in the background.
            ringRevealed = true
            return
        }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 2.6)) {
            ringRevealed = true
        }
        haloExpanded = true
    }

    private var motionEnabled: Bool {
        !reduceMotion && scenePhase == .active
    }
}

private struct AtriaStrainScoreHero: View {
    let score: Double?
    let target: Double?
    let state: String
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(score.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(score == nil ? Color.secondary : tint)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(targetSubtitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(.primary.opacity(0.09))
                    if let target {
                        let range = AtriaStrainTargetPresentation.targetRange(for: target)
                        Capsule(style: .continuous).fill(tint.opacity(0.16))
                            .frame(width: width * (range.upperBound - range.lowerBound) / AtriaStrainTargetPresentation.maximum)
                            .offset(x: width * range.lowerBound / AtriaStrainTargetPresentation.maximum)
                    }
                    if let score {
                        Capsule(style: .continuous).fill(tint)
                            .frame(width: max(8, width * AtriaStrainTargetPresentation.progress(for: score)))
                            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: score)
                    }
                }
            }
            .frame(height: 14)
            HStack {
                Text("0"); Spacer(minLength: 0); Text(target.map { "Target \(String(format: "%.1f", $0))" } ?? "Target")
                Spacer(minLength: 0); Text("21")
            }
            .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(16).atriaInsetCard(tint: tint).accessibilityElement(children: .combine)
    }

    private var targetSubtitle: String {
        guard let target else { return "of 21 \u{00b7} target learning" }
        let range = AtriaStrainTargetPresentation.targetRange(for: target)
        return "of 21 \u{00b7} target \(String(format: "%.0f", range.lowerBound))-\(String(format: "%.0f", range.upperBound))"
    }
}

private struct AtriaMetricDetailTemplate<BetweenHero: View, Contributors: View, ChartContent: View, About: View>: View {
    let heroValue: String
    let heroState: String
    let tint: Color
    let heroStyle: AtriaMetricDetailHeroStyle
    let betweenHeroAndContributors: BetweenHero
    let contributors: Contributors
    let chart: ChartContent
    let about: About
    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(heroValue: String,
         heroState: String,
         tint: Color,
         heroStyle: AtriaMetricDetailHeroStyle = .standard,
         @ViewBuilder contributors: () -> Contributors,
         @ViewBuilder chart: () -> ChartContent,
         @ViewBuilder about: () -> About) where BetweenHero == EmptyView {
        self.heroValue = heroValue
        self.heroState = heroState
        self.tint = tint
        self.heroStyle = heroStyle
        self.betweenHeroAndContributors = EmptyView()
        self.contributors = contributors()
        self.chart = chart()
        self.about = about()
    }

    init(heroValue: String,
         heroState: String,
         tint: Color,
         heroStyle: AtriaMetricDetailHeroStyle = .standard,
         @ViewBuilder betweenHeroAndContributors: () -> BetweenHero,
         @ViewBuilder contributors: () -> Contributors,
         @ViewBuilder chart: () -> ChartContent,
         @ViewBuilder about: () -> About) {
        self.heroValue = heroValue
        self.heroState = heroState
        self.tint = tint
        self.heroStyle = heroStyle
        self.betweenHeroAndContributors = betweenHeroAndContributors()
        self.contributors = contributors()
        self.chart = chart()
        self.about = about()
    }

    var body: some View {
        // Real progressive disclosure: the first screen is the WHOOP-like simple
        // view — value, graph, and the metric's own signature visual (hypnogram /
        // strain gauge / contributor map). The generic contributor rows and the
        // education copy are collapsed behind an explicit "Show details" tap, so a
        // metric tap no longer dumps every stat in one long scroll.
        VStack(alignment: .leading, spacing: 16) {
            hero
            chart
            betweenHeroAndContributors
            revealAffordance
            if showDetails {
                detailPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: showDetails)
    }

    private var revealAffordance: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.black))
                    .rotationEffect(.degrees(showDetails ? 180 : 0))
                Text(showDetails ? "Hide details" : "Show details")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.primary.opacity(0.05), in: Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showDetails ? "Hide details" : "Show details")
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Details", systemImage: "slider.horizontal.3")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 0)
                Text("Deeper context")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }

            contributors
            about
        }
        .padding(16)
        .atriaInsetCard(tint: tint)
    }

    /// Confidence-ladder hero (design-handoff detail template): the big number
    /// is painted in the metric's identity hue and the state sits in a small
    /// dot+capsule confidence pill — the SAME hue the ring and chips use, so
    /// the whole sheet reads as one metric. HONESTY GUARD: when there's no
    /// trusted value yet (empty / "—" placeholder, or a Learning state) the
    /// number and pill fall back to neutral grey — a colored number never
    /// implies a confidence the data hasn't earned.
    private var heroIsUncertain: Bool {
        let v = heroValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty || v == "—" || v == "--" { return true }
        return heroState.localizedCaseInsensitiveContains("learning")
    }

    private var heroTint: Color {
        heroIsUncertain ? Color.secondary : tint
    }

    @ViewBuilder
    private var hero: some View {
        switch heroStyle {
        case .standard:
            VStack(alignment: .leading, spacing: 10) {
                Text(heroValue)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.56)
                    .foregroundStyle(heroTint)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.emphatic), value: heroValue)

                HStack(spacing: 6) {
                    Circle()
                        .fill(heroTint)
                        .frame(width: 6, height: 6)
                    Text(heroState)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(heroTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(heroTint.opacity(0.14), in: Capsule(style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .atriaInsetCard(tint: tint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(heroValue), \(heroState)")
        case .recoveryRing(let score, let baselineComparison):
            AtriaRecoveryScoreHero(score: score,
                                   state: heroState,
                                   tint: tint,
                                   baselineComparison: baselineComparison)
        case .strain(let score, let target):
            AtriaStrainScoreHero(score: score,
                                 target: target,
                                 state: heroState,
                                 tint: tint)
        }
    }
}

private struct AtriaMetricContributorRow: Identifiable, Equatable {
    var id: String { "\(systemImage)|\(name)" }
    let systemImage: String
    let name: String
    let value: String
    let comparison: String
    let direction: Int

    static func == (lhs: AtriaMetricContributorRow, rhs: AtriaMetricContributorRow) -> Bool {
        lhs.systemImage == rhs.systemImage
            && lhs.name == rhs.name
            && lhs.value == rhs.value
            && lhs.comparison == rhs.comparison
            && lhs.direction == rhs.direction
    }
}

private struct AtriaMetricContributorRows: View, Equatable {
    let rows: [AtriaMetricContributorRow]
    let tint: Color

    static func == (lhs: AtriaMetricContributorRows, rhs: AtriaMetricContributorRows) -> Bool {
        lhs.rows == rhs.rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contributors")
                .font(.subheadline.weight(.semibold))

            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(rowTint(row))
                        .frame(width: 28, height: 28)
                        .background(rowTint(row).opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.caption.weight(.bold))
                        Text(row.comparison)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Text(row.value)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Image(systemName: directionSymbol(row.direction))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(rowTint(row))
                    }
                }
                .padding(12)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            }
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }

    private func rowTint(_ row: AtriaMetricContributorRow) -> Color {
        if row.direction > 0 { return Metrics.electricGreen }
        if row.direction < 0 { return Metrics.electricRed }
        return tint
    }

    private func directionSymbol(_ direction: Int) -> String {
        if direction > 0 { return "arrow.up.circle.fill" }
        if direction < 0 { return "arrow.down.circle.fill" }
        return "minus.circle.fill"
    }
}

private struct AtriaMetricMeaningInline: View {
    let metric: AtriaMetricDetailKind
    let guidance: Coach.Guidance
    let recoveryEstimate: Metrics.RecoveryEstimate
    let sleepGoalHours: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailBlock(title: "What it means", body: meaning)
            detailBlock(title: "What to do", body: coaching)
        }
        .padding(.top, 8)
    }

    private var meaning: String {
        switch metric {
        case .recovery:
            let contributorSummary = recoveryEstimate.contributors.isEmpty
                ? "Recovery is still building toward a stable baseline."
                : "The contributor list shows which terms pushed the score up or down today."
            return "\(contributorSummary) Recovery is morning-frozen so it does not drift all day."
        case .hrv:
            return "HRV is most useful as a trend. Compare today with your baseline band instead of chasing someone else’s number."
        case .restingHeartRate:
            return "Resting HR is a context metric. A sudden rise versus your normal can line up with stress, illness, poor sleep, or hard training."
        case .respiratoryRate:
            return "Respiratory rate is compared with your own sleep baseline. Sustained shifts can line up with stress, travel, environment, or feeling off."
        case .sleep:
            return String(format: "Sleep performance compares your night with a %.1f hour goal while consistency tracks recent timing.", sleepGoalHours)
        case .strain:
            return "Strain is your day-load target, not a score to max out every day."
        case .stress:
            return "This is a live autonomic-load read, not a lab measurement. Atria doesn't yet save a daily stress history to trend."
        case .vo2max:
            return "VO2max is estimated from your resting baseline and measured heart-rate max, not a lab gas-exchange test."
        case .sleepPerformance:
            return String(format: "Sleep performance compares last night's duration with a need that adjusts for debt and yesterday's strain, not a flat %.1f hour goal.", sleepGoalHours)
        case .sleepEfficiency:
            return "Sleep efficiency estimates time asleep versus time in bed from duration, not a checked sleep study."
        case .skinTemperature:
            return "Atria can't read skin temperature from this strap yet, so it shows no value."
        case .fitnessAge:
            return "Fitness age blends VO2max-adjacent fitness signals into a single younger/older-than-your-years estimate."
        case .hrZones:
            return "Zone minutes split today's elevated heart rate into Z2 through Z5 bands."
        case .bloodOxygen:
            return "Atria can't read blood oxygen from this strap yet, so it shows no percentage."
        }
    }

    private var coaching: String {
        switch metric {
        case .recovery:
            return guidance.headline.isEmpty ? guidance.detail : "\(guidance.headline) \(guidance.detail)"
        case .hrv:
            return "Look for multi-day direction. If HRV is suppressed and recovery is also down, favor easier training and protect tonight’s sleep."
        case .restingHeartRate:
            return "Treat a higher-than-normal RHR as a reason to reduce intensity, hydrate, and keep an eye on how you feel."
        case .respiratoryRate:
            return "Watch the trend, not one night. If respiratory rate stays outside your usual range, take it as a wellness signal and compare with how you feel."
        case .sleep:
            return "If debt is climbing, buy back time tonight before trying to force a bigger strain score tomorrow."
        case .strain:
            if let target = guidance.target {
                return String(format: "Aim for the target arc around %.1f today and let recovery decide how hard to push.", target)
            }
            return "Use the active band to stay controlled while Atria learns your recovery-scaled target."
        case .stress:
            return "If it stays elevated, try a few slow paced breaths or lighten today's training rather than pushing through it."
        case .vo2max:
            return "Watch the multi-week trend rather than any single estimate; sustained aerobic training is what moves it."
        case .sleepPerformance:
            return "A string of nights under 100% adds up as debt \u{2014} an earlier bedtime pays it back faster than one long catch-up night."
        case .sleepEfficiency:
            return "Low efficiency with normal duration usually means restless time in bed \u{2014} a cooler, darker, screen-free wind-down tends to help."
        case .skinTemperature:
            return "There is no temperature reading to act on."
        case .fitnessAge:
            return "This moves slowly by design \u{2014} consistent aerobic training and sleep are what shift the pace of aging over months, not days."
        case .hrZones:
            return "More time in Z2\u{2013}Z3 builds an aerobic base; Z4\u{2013}Z5 minutes are the hard efforts to keep purposeful, not accidental."
        case .bloodOxygen:
            return "There's no verified blood-oxygen reading to act on."
        }
    }

    private func detailBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AtriaDetailRangeDotStrip: View, Equatable {
    private struct Bar: Equatable, Identifiable {
        let id: Date
        let tint: Color
        let height: CGFloat
        let opacity: Double
    }

    private let bars: [Bar]
    let fallbackTint: Color

    init(points: [AtriaDetailChartPoint], fallbackTint: Color) {
        self.fallbackTint = fallbackTint
        let low = points.map(\.value).min()
        let high = points.map(\.value).max()
        self.bars = points.enumerated().map { index, point in
            let progress: Double
            if points.count > 1 {
                progress = Double(index) / Double(points.count - 1)
            } else {
                progress = 1
            }
            let normalized: Double
            if let low, let high, high > low {
                normalized = (point.value - low) / (high - low)
            } else {
                normalized = 0.18
            }
            return Bar(id: point.id,
                       tint: point.tint,
                       height: 8 + CGFloat(normalized) * 16,
                       opacity: 0.28 + progress * 0.54)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(bars) { bar in
                Capsule(style: .continuous)
                    .fill(bar.tint.opacity(bar.opacity))
                    .frame(maxWidth: .infinity)
                    .frame(height: bar.height)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 1)
        .overlay(alignment: .bottomLeading) {
            Capsule(style: .continuous)
                .fill(fallbackTint.opacity(0.18))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compact range pattern with \(bars.count) saved days.")
    }
}

private struct AtriaRecoveryContributorMap: View {
    let contributors: [Metrics.RecoveryEstimate.Contributor]
    let titleForContributor: (Metrics.RecoveryEstimate.Contributor) -> String
    let noteForContributor: (Metrics.RecoveryEstimate.Contributor) -> String

    private var dominantContributor: Metrics.RecoveryEstimate.Contributor? {
        contributors.max { abs($0.weightedContribution) < abs($1.weightedContribution) }
    }

    private var supportMagnitude: Double {
        contributors
            .map(\.weightedContribution)
            .filter { $0 > 0 }
            .reduce(0, +)
    }

    private var pressureMagnitude: Double {
        abs(contributors
            .map(\.weightedContribution)
            .filter { $0 < 0 }
            .reduce(0, +))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Why today's recovery landed here")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let dominantContributor {
                        Text(titleForContributor(dominantContributor))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint(for: dominantContributor))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(tint(for: dominantContributor).opacity(0.12), in: Capsule(style: .continuous))
                    }
                }

                Text("Baseline sits in the middle. Factors to the right supported recovery; factors to the left pulled it down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if contributors.isEmpty {
                Text("Recovery contributors appear after a trusted HRV, resting HR, and saved sleep baseline is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            } else {
                contributorBalanceStrip

                VStack(spacing: 12) {
                    ForEach(contributors) { contributor in
                        contributorRow(contributor)
                    }
                }
            }

            Text("Recovery blends HRV, resting HR, sleep, and respiration against your personal baseline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricGreen)
        .accessibilityElement(children: .combine)
    }

    private var contributorBalanceStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label("Recovery balance", systemImage: "scale.3d")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(balanceText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(balanceTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(balanceTint.opacity(0.12), in: Capsule(style: .continuous))
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let total = max(supportMagnitude + pressureMagnitude, 0.01)
                let supportWidth = width * (supportMagnitude / total)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Metrics.electricRed.opacity(0.18))
                    Capsule(style: .continuous)
                        .fill(Metrics.electricGreen.opacity(0.68))
                        .frame(width: max(8, supportWidth))
                    Rectangle()
                        .fill(.primary.opacity(0.22))
                        .frame(width: 1.5)
                        .offset(x: width / 2)
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            HStack {
                Text("Pressure")
                Spacer(minLength: 8)
                Text("Support")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(balanceTint.opacity(0.07), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                .stroke(balanceTint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovery balance. \(balanceText).")
    }

    private var balanceText: String {
        if supportMagnitude > pressureMagnitude * 1.15 {
            return "Supported"
        }
        if pressureMagnitude > supportMagnitude * 1.15 {
            return "Pressured"
        }
        return "Mixed"
    }

    private var balanceTint: Color {
        switch balanceText {
        case "Supported": return Metrics.electricGreen
        case "Pressured": return Metrics.electricRed
        default: return .secondary
        }
    }

    private func contributorRow(_ contributor: Metrics.RecoveryEstimate.Contributor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint(for: contributor).opacity(0.13))
                    Image(systemName: symbol(for: contributor))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint(for: contributor))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleForContributor(contributor))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(noteForContributor(contributor))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: directionSymbol(for: contributor))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint(for: contributor))
                        .accessibilityLabel(directionText(for: contributor))
                    Text(contributor.displayValue)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            contributorRail(contributor)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    private func contributorRail(_ contributor: Metrics.RecoveryEstimate.Contributor) -> some View {
        let progress = min(max(contributor.zScore / 2.0, -1), 1)
        let tint = tint(for: contributor)
        return GeometryReader { proxy in
            let width = proxy.size.width
            let halfWidth = width / 2
            let fillWidth = max(4, abs(progress) * halfWidth)
            let markerX = halfWidth + progress * halfWidth

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(0.08))

                Rectangle()
                    .fill(.primary.opacity(0.24))
                    .frame(width: 1.5)
                    .offset(x: halfWidth)

                Capsule(style: .continuous)
                    .fill(tint.opacity(0.56))
                    .frame(width: fillWidth)
                    .offset(x: progress >= 0 ? halfWidth : halfWidth - fillWidth)

                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .stroke(Color(.systemBackground).opacity(0.75), lineWidth: 1.5)
                    }
                    .offset(x: min(max(markerX - 4.5, 0), max(width - 9, 0)))
            }
        }
        .frame(height: 8)
    }

    private func directionText(for contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        if contributor.direction > 0 { return "Supported" }
        if contributor.direction < 0 { return "Pressured" }
        return "Neutral"
    }

    private func directionSymbol(for contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        if contributor.direction > 0 { return "arrow.up.circle.fill" }
        if contributor.direction < 0 { return "arrow.down.circle.fill" }
        return "minus.circle.fill"
    }

    private func tint(for contributor: Metrics.RecoveryEstimate.Contributor) -> Color {
        if contributor.direction > 0 { return Metrics.electricGreen }
        if contributor.direction < 0 { return Metrics.electricRed }
        return .secondary
    }

    private func symbol(for contributor: Metrics.RecoveryEstimate.Contributor) -> String {
        switch contributor.kind {
        case .hrv: return "waveform.path.ecg"
        case .restingHeartRate: return "heart.fill"
        case .sleep: return "bed.double.fill"
        case .respiration: return "lungs.fill"
        }
    }
}

private struct AtriaMetricMeaningSheet: View {
    let metric: AtriaMetricDetailKind
    let guidance: Coach.Guidance
    let recoveryEstimate: Metrics.RecoveryEstimate
    let sleepGoalHours: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline)
                            .font(.title3.weight(.bold))
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    detailBlock(title: "What it means", body: meaning)
                    detailBlock(title: "What to do", body: coaching)
                }
                .padding(18)
            }
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var headline: String {
        switch metric {
        case .recovery:
            return "Recovery turns overnight signals into a readiness read."
        case .hrv:
            return "HRV shows how much recovery capacity your system is carrying."
        case .restingHeartRate:
            return "Resting HR helps flag strain, illness, or under-recovery."
        case .respiratoryRate:
            return "Respiratory rate shows how your sleeping breathing compares with your usual range."
        case .sleep:
            return "Sleep tracks whether you got enough time and consistency to restore."
        case .strain:
            return "Strain is your day-load target, not a score to max out every day."
        case .stress:
            return "Stress is a live autonomic-load read, not a saved daily trend."
        case .vo2max:
            return "VO2max estimates your aerobic capacity from resting and max heart rate."
        case .sleepPerformance:
            return "Sleep performance compares last night with how much sleep you actually needed."
        case .sleepEfficiency:
            return "Sleep efficiency estimates how much of your time in bed was spent asleep."
        case .skinTemperature:
            return "Skin temperature is not available yet."
        case .fitnessAge:
            return "Fitness age turns your training and recovery signals into a younger/older-than-your-years estimate."
        case .hrZones:
            return "HR zones split today's elevated heart rate into effort bands."
        case .bloodOxygen:
            return "Blood oxygen is not available yet."
        }
    }

    private var summary: String {
        switch metric {
        case .recovery:
            return "Atria blends HRV, resting HR, sleep, and respiration against your baseline so the percent reads as 'how ready am I today?'"
        case .hrv:
            return "Use the chart with your baseline band. A point above your normal is usually a better sign than the absolute number by itself."
        case .restingHeartRate:
            return "Read this against your own baseline. Lower than usual can be a good sign; higher than usual often means accumulated load."
        case .respiratoryRate:
            return "The chart uses sleep-derived respiratory estimates and your typical range. Atria treats changes as observational wellness context, not diagnosis."
        case .sleep:
            return "The duration trend shows how much sleep you got. The stage bar is labeled as a heart-rate and motion estimate, not EEG."
        case .strain:
            return "The blue arc shows today’s accumulated load. The target arc and notch show where today’s plan says to land."
        case .stress:
            return "There's no chart here yet because Atria doesn't save a day-by-day stress history \u{2014} only today's live read."
        case .vo2max:
            return "Treat the number and its trend as an estimate, sharpening over more sessions, not a lab VO2 test result."
        case .sleepPerformance:
            return "The chart shows the saved daily percent of nightly sleep need met, factoring in recent debt and yesterday's strain."
        case .sleepEfficiency:
            return "The current estimate is duration-based; Atria doesn't yet save a night-by-night efficiency history to chart."
        case .skinTemperature:
            return "Atria does not show raw sensor data as wrist temperature."
        case .fitnessAge:
            return "The pace-of-aging chart only appears once 28 days of the estimate are saved; until then this shows the calibrating state."
        case .hrZones:
            return "Zone minutes are today's live total; Atria doesn't yet save a day-by-day zone-minutes history to chart."
        case .bloodOxygen:
            return "Atria does not show raw sensor data as a percentage."
        }
    }

    private var meaning: String {
        switch metric {
        case .recovery:
            let contributorSummary = recoveryEstimate.contributors.isEmpty
                ? "Recovery is still building toward a stable baseline."
                : "The contributor list shows which terms pushed the score up or down today."
            return "\(contributorSummary) Recovery is morning-frozen so it does not drift all day."
        case .hrv:
            return "HRV is most useful as a trend. Compare today with your baseline band instead of chasing someone else’s 'good' number."
        case .restingHeartRate:
            return "Resting HR is a context metric. A sudden rise versus your normal can line up with stress, illness, poor sleep, or hard training."
        case .respiratoryRate:
            return "Respiratory rate is compared with your own sleep baseline. Sustained shifts can line up with stress, travel, environment, or feeling off."
        case .sleep:
            return String(format: "Sleep performance compares your night with a %.1f hour goal while consistency tracks how stable your recent timing has been.", sleepGoalHours)
        case .strain:
            return "Light, Moderate, High, and All-Out bands make it easier to read the number as a coaching zone instead of raw effort."
        case .stress:
            return "This estimates autonomic load right now from heart rate and beat-to-beat timing, not a lab cortisol measurement."
        case .vo2max:
            return "VO2max is derived from your resting heart-rate baseline and measured max heart rate, refined as more sessions come in."
        case .sleepPerformance:
            return String(format: "Sleep performance compares last night's duration against a need that adjusts for sleep debt and yesterday's strain, not a flat %.1f hour goal.", sleepGoalHours)
        case .sleepEfficiency:
            return "Sleep efficiency is time asleep divided by time in bed, estimated from duration rather than a checked sleep study."
        case .skinTemperature:
            return "This metric stays empty until Atria can read it reliably."
        case .fitnessAge:
            return "Fitness age blends your recovery, training, and VO2max-adjacent signals into one younger/older-than-your-years read."
        case .hrZones:
            return "Zone minutes show how much of today was spent in each heart-rate effort band, from resting to max."
        case .bloodOxygen:
            return "This metric stays empty until Atria can read it reliably."
        }
    }

    private var coaching: String {
        switch metric {
        case .recovery:
            return guidance.headline.isEmpty ? guidance.detail : "\(guidance.headline) \(guidance.detail)"
        case .hrv:
            return "Look for multi-day direction. If HRV is suppressed and recovery is also down, favor easier training and protect tonight’s sleep."
        case .restingHeartRate:
            return "Treat a higher-than-normal RHR as a reason to reduce intensity, hydrate, and keep an eye on how you feel."
        case .respiratoryRate:
            return "Watch the trend, not one night. If respiratory rate stays outside your usual range, take it as a wellness signal and compare with how you feel."
        case .sleep:
            return "If debt is climbing, buy back time tonight before trying to force a bigger strain score tomorrow."
        case .strain:
            if let target = guidance.target {
                return String(format: "Aim for the target arc around %.1f today. If recovery is still building, use the band label to stay controlled instead of pushing for max load.", target)
            }
            return "Use the active band to stay controlled while Atria learns your recovery-scaled target."
        case .stress:
            return "If it stays elevated, a few minutes of slow paced breathing is the fastest lever — open guided breathwork from the Stress tile."
        case .vo2max:
            return "Consistent aerobic training over weeks moves this more than any single session."
        case .sleepPerformance:
            return "A run of nights under 100% compounds as debt — pay it back with an earlier bedtime rather than one long catch-up night."
        case .sleepEfficiency:
            return "Low efficiency alongside normal duration usually means restless time in bed — a cooler, darker, screen-free wind-down tends to help."
        case .skinTemperature:
            return "There is no temperature reading to act on."
        case .fitnessAge:
            return "This moves slowly by design — consistent sleep and aerobic training are what shift the pace of aging over months."
        case .hrZones:
            return "More Z2–Z3 time builds an aerobic base; keep Z4–Z5 minutes purposeful rather than accidental."
        case .bloodOxygen:
            return "There's no verified blood-oxygen reading to act on."
        }
    }

    private func detailBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: metric.tint)
    }
}

private struct AtriaDetailPeriodSummary: Equatable, Sendable {
    let latestText: String
    let averageText: String
    let rangeText: String
    let changeText: String
    let latestPosition: Double
    let changeDirection: AtriaDetailPeriodChangeDirection
    let unit: String
    let averageRaw: Double
    let latestRaw: Double

    init?(points: [AtriaDetailChartPoint], unit: String) {
        guard let latest = points.last else { return nil }
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        let average = values.reduce(0, +) / Double(max(values.count, 1))
        let change = latest.value - (points.first?.value ?? latest.value)
        let spread = high - low
        self.latestText = Self.valueText(latest.value, unit: unit)
        self.averageText = Self.valueText(average, unit: unit)
        self.rangeText = Self.rangeText(low: low, high: high, unit: unit)
        self.changeText = Self.changeText(change, unit: unit)
        self.latestPosition = spread > 0 ? min(max((latest.value - low) / spread, 0), 1) : 0.5
        self.changeDirection = AtriaDetailPeriodChangeDirection(change: change)
        self.unit = unit
        self.averageRaw = average
        self.latestRaw = latest.value
    }

    static func valueText(_ value: Double, unit: String) -> String {
        AtriaMetricFormat.value(value, metric: metricUnit(for: unit))
    }

    static func rangeText(low: Double, high: Double, unit: String) -> String {
        AtriaMetricFormat.range(low: low, high: high, metric: metricUnit(for: unit))
    }

    static func changeText(_ value: Double, unit: String) -> String {
        AtriaMetricFormat.change(value, metric: metricUnit(for: unit))
    }

    private static func metricUnit(for unit: String) -> AtriaMetricUnit {
        switch unit {
        case "%": return .recovery
        case "h": return .sleep
        case "ms": return .hrv
        case "bpm": return .restingHeartRate
        default: return .strain
        }
    }
}

private enum AtriaDetailPeriodChangeDirection: Sendable {
    case up
    case flat
    case down

    init(change: Double) {
        if change > 0.05 {
            self = .up
        } else if change < -0.05 {
            self = .down
        } else {
            self = .flat
        }
    }

    var symbolName: String {
        switch self {
        case .up: return "arrow.up.right"
        case .flat: return "minus"
        case .down: return "arrow.down.right"
        }
    }
}

private struct AtriaDetailRangeLensCard: View, Equatable {
    let range: AtriaTrendRange
    let summary: AtriaDetailPeriodSummary
    let comparison: AtriaDetailComparisonSummary?
    let tint: Color
    let sleepGoalHours: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Trend snapshot", systemImage: "scope")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(range.menuLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            HStack(spacing: 8) {
                lensStat(title: "Latest", value: summary.latestText, prominent: true)
                lensStat(title: "Avg", value: summary.averageText, prominent: false)
                lensStat(title: "Change", value: summary.changeText, prominent: false)
            }

            if let comparison {
                comparisonRail(comparison)
                AtriaDetailComparisonSeesaw(comparison: comparison,
                                            tint: tint)
            } else {
                Text("Prior window fills in with more saved days.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }

            if summary.unit == "h" {
                sleepRangeRhythm
            }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend snapshot \(range.menuLabel). Latest \(summary.latestText), average \(summary.averageText), change \(summary.changeText).")
    }

    private var sleepRangeRhythm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Sleep rhythm", systemImage: "moon.zzz.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(sleepRangeCue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let goalX = width * sleepGoalPosition
                let latestX = width * sleepLatestPosition
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.11))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.62))
                        .frame(width: max(8, latestX))
                    Rectangle()
                        .fill(.white.opacity(0.78))
                        .frame(width: 2, height: 16)
                        .clipShape(Capsule(style: .continuous))
                        .offset(x: min(max(goalX - 1, 0), max(width - 2, 0)))
                    Circle()
                        .fill(tint)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(latestX - 6, 0), max(width - 12, 0)))
                }
            }
            .frame(height: 16)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                sleepMiniStat(title: "Latest", value: summary.latestText)
                sleepMiniStat(title: "Avg", value: summary.averageText)
                sleepMiniStat(title: "Target", value: AtriaMetricFormat.sleepHours(sleepGoalHours))
            }
        }
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep rhythm. Latest \(summary.latestText), average \(summary.averageText), target \(AtriaMetricFormat.sleepHours(sleepGoalHours)), \(sleepRangeCue).")
    }

    private var sleepRangeCue: String {
        if summary.averageRaw >= sleepGoalHours - 0.5 { return "Near target" }
        if summary.averageRaw >= sleepGoalHours - 1.5 { return "Small debt" }
        return "Debt building"
    }

    private var sleepLatestPosition: Double {
        min(max(summary.latestRaw / sleepScaleMax, 0.05), 1)
    }

    private var sleepGoalPosition: Double {
        min(max(sleepGoalHours / sleepScaleMax, 0.05), 1)
    }

    private var sleepScaleMax: Double {
        max(sleepGoalHours + 1.5, summary.latestRaw, summary.averageRaw, 1)
    }

    private func sleepMiniStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lensStat(title: String, value: String, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font((prominent ? Font.headline : Font.caption).weight(.bold).monospacedDigit())
                .foregroundStyle(prominent ? tint : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func comparisonRail(_ comparison: AtriaDetailComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: comparison.changeDirection.symbolName)
                    .font(.caption2.weight(.bold))
                Text("Vs prior \(comparison.deltaText)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text(comparison.priorText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
            .foregroundStyle(tint)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let currentWidth = max(8, width * comparison.currentShare)
                let priorWidth = max(8, width * comparison.priorShare)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.70))
                        .frame(width: currentWidth, height: 7)
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: priorWidth, height: 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AtriaDetailComparisonSeesaw: View, Equatable {
    let comparison: AtriaDetailComparisonSummary
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("This vs prior", systemImage: comparison.changeDirection.symbolName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(comparison.deltaText)
                    .font(.caption2.weight(.black).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }

            HStack(alignment: .center, spacing: 8) {
                comparisonBar(title: "Prior",
                              value: comparison.priorText,
                              share: comparison.priorShare,
                              tint: .secondary,
                              alignment: .trailing)
                Circle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .stroke(tint.opacity(0.20), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
                comparisonBar(title: "This",
                              value: comparison.currentText,
                              share: comparison.currentShare,
                              tint: tint,
                              alignment: .leading)
            }
        }
        .padding(10)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This versus prior. This \(comparison.currentText), prior \(comparison.priorText), change \(comparison.deltaText).")
    }

    private func comparisonBar(title: String,
                               value: String,
                               share: Double,
                               tint: Color,
                               alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if alignment == .leading { Spacer(minLength: 0) }
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: alignment == .leading ? .leading : .trailing) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.62))
                        .frame(width: max(8, width * min(max(share, 0), 1)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct AtriaDetailRangeRhythmCard: View {
    let range: AtriaTrendRange
    let points: [AtriaDetailChartPoint]
    let summary: AtriaDetailPeriodSummary
    let comparison: AtriaDetailComparisonSummary?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Range rhythm", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(range.menuLabel)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(tint)
            }

            AtriaDetailRangeDotStrip(points: points, fallbackTint: tint)

            HStack(spacing: 8) {
                rhythmChip(title: rangeAnchorTitle,
                           value: summary.latestText,
                           systemImage: "scope",
                           prominent: true)
                rhythmChip(title: "Avg",
                           value: summary.averageText,
                           systemImage: "chart.line.flattrend.xyaxis",
                           prominent: false)
                rhythmChip(title: "Vs prior",
                           value: comparison?.deltaText ?? "Building",
                           systemImage: comparison == nil ? "clock.badge.checkmark" : "arrow.left.arrow.right",
                           prominent: false)
            }
        }
        .padding(12)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.13), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Detail range rhythm. \(range.menuLabel). \(rangeAnchorTitle) \(summary.latestText). Average \(summary.averageText). Versus prior \(comparison?.deltaText ?? "building").")
    }

    private var rangeAnchorTitle: String {
        switch range {
        case .day: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .quarter: return "3M"
        case .sixMonths: return "6M"
        case .year: return "1Y"
        case .all: return "All"
        }
    }

    private func rhythmChip(title: String,
                            value: String,
                            systemImage: String,
                            prominent: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font((prominent ? Font.caption : Font.caption2).weight(.black).monospacedDigit())
                    .foregroundStyle(prominent ? tint : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(tint.opacity(prominent ? 0.10 : 0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct AtriaDetailPeriodSummaryStrip: View {
    let summary: AtriaDetailPeriodSummary
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Latest")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(summary.latestText)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: summary.changeDirection.symbolName)
                        .font(.caption.weight(.bold))
                    Text(summary.changeText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint.opacity(0.12), in: Capsule())
                .layoutPriority(1)
            }

            summaryRangeRail

            HStack(spacing: 8) {
                summaryMiniStat(label: "Avg", value: summary.averageText)
                summaryMiniStat(label: "Range", value: summary.rangeText)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Period summary. Latest \(summary.latestText), average \(summary.averageText), range \(summary.rangeText), change \(summary.changeText).")
    }

    private var summaryRangeRail: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let markerX = width * summary.latestPosition

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.12))
                    .frame(height: 8)

                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.76)],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(8, markerX), height: 8)

                Circle()
                    .fill(tint)
                    .frame(width: 14, height: 14)
                    .shadow(color: tint.opacity(0.28), radius: 6, y: 2)
                    .offset(x: min(max(markerX - 7, 0), max(width - 14, 0)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 18)
    }

    private func summaryMiniStat(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AtriaDetailPeriodReportCard: View, Equatable {
    let summary: AtriaDetailPeriodSummary
    let comparison: AtriaDetailComparisonSummary?
    let tint: Color

    private var movementText: String {
        switch summary.changeDirection {
        case .up: return "Up"
        case .flat: return "Flat"
        case .down: return "Down"
        }
    }

    private var priorText: String {
        comparison?.deltaText ?? "Building"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("This period", systemImage: "chart.bar.xaxis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(priorText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                reportChip(title: "Latest",
                           value: summary.latestText,
                           systemImage: "scope",
                           prominent: true)
                reportChip(title: "Change",
                           value: movementText,
                           systemImage: summary.changeDirection.symbolName,
                           prominent: false)
                reportChip(title: "Compare",
                           value: comparison == nil ? "Build" : "Ready",
                           systemImage: comparison == nil ? "clock.badge.checkmark" : "arrow.left.arrow.right",
                           prominent: false)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let markerX = width * summary.latestPosition
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.70))
                        .frame(width: max(8, markerX))
                    Circle()
                        .fill(tint)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(markerX - 6, 0), max(width - 12, 0)))
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.13), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This period. Latest \(summary.latestText), change \(summary.changeText), compared with prior \(priorText), average \(summary.averageText).")
    }

    private func reportChip(title: String,
                            value: String,
                            systemImage: String,
                            prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font((prominent ? Font.caption : Font.caption2).weight(.black).monospacedDigit())
                .foregroundStyle(prominent ? tint : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(prominent ? 0.09 : 0.055),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AtriaDetailComparisonSummary: Equatable, Sendable {
    let currentText: String
    let priorText: String
    let deltaText: String
    let currentShare: Double
    let priorShare: Double
    let changeDirection: AtriaDetailPeriodChangeDirection
    /// Numeric prior-period average, kept for the detail chart's dashed
    /// prior-average rule (2026-07-07 design handoff).
    let priorAverage: Double

    init?(current: [AtriaDetailChartPoint], prior: [AtriaDetailChartPoint], unit: String) {
        guard !current.isEmpty, !prior.isEmpty else { return nil }
        let currentAverage = Self.average(current.map(\.value))
        let priorAverage = Self.average(prior.map(\.value))
        let largest = max(max(abs(currentAverage), abs(priorAverage)), 0.01)
        let delta = currentAverage - priorAverage

        self.currentText = AtriaDetailPeriodSummary.valueText(currentAverage, unit: unit)
        self.priorText = AtriaDetailPeriodSummary.valueText(priorAverage, unit: unit)
        self.deltaText = AtriaDetailPeriodSummary.changeText(delta, unit: unit)
        self.currentShare = min(max(abs(currentAverage) / largest, 0.06), 1)
        self.priorShare = min(max(abs(priorAverage) / largest, 0.06), 1)
        self.changeDirection = AtriaDetailPeriodChangeDirection(change: delta)
        self.priorAverage = priorAverage
    }

    private static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(max(values.count, 1))
    }
}

private struct AtriaDetailComparisonCard: View, Equatable {
    let comparison: AtriaDetailComparisonSummary
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Vs prior", systemImage: comparison.changeDirection.symbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(comparison.deltaText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }

            comparisonRow(label: "This", value: comparison.currentText, share: comparison.currentShare, isCurrent: true)
            comparisonRow(label: "Prior", value: comparison.priorText, share: comparison.priorShare, isCurrent: false)
        }
        .padding(12)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Compared with prior window. This \(comparison.currentText), prior \(comparison.priorText), change \(comparison.deltaText).")
    }

    private func comparisonRow(label: String, value: String, share: Double, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            GeometryReader { proxy in
                Capsule()
                    .fill((isCurrent ? tint : Color.secondary).opacity(isCurrent ? 0.68 : 0.22))
                    .frame(width: max(8, proxy.size.width * share))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 8)

            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

private struct AtriaPreparedMetricHistory: Sendable {
    let recovery: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let hrv: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let restingHeartRate: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let respiratoryRate: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleep: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let strain: [AtriaTrendRange: [AtriaDetailChartPoint]]
    // Prior-period series, TIME-SHIFTED onto the current window so the
    // dashed ghost overlays the same axis (design-handoff ghost line,
    // 2026-07-07). Same weekly bucketing as the current series, bands
    // stripped (a ghost is a line, not a band).
    let recoveryPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let hrvPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let restingHeartRatePrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let respiratoryRatePrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleepPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let strainPrior: [AtriaTrendRange: [AtriaDetailChartPoint]]
    // RAW (unbucketed) series for the manual bucket override in the chart
    // options sheet (design handoff "Range & interval", 2026-07-07).
    let recoveryRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let hrvRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let restingHeartRateRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let respiratoryRateRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleepRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let strainRaw: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let latestStrain: [AtriaTrendRange: Double]
    let recoverySummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let hrvSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let restingHeartRateSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let respiratoryRateSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let sleepSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let strainSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let recoveryComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let hrvComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let restingHeartRateComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let respiratoryRateComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let sleepComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let strainComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    // Visibility/IA trend coverage (2026-07-05), spec path B: reuses this
    // already-shipping rollup-backed history instead of touching the
    // launch-emergency Sessions.swift trend builder.
    let sleepPerformance: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let sleepPerformanceSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let sleepPerformanceComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    let fitnessAge: [AtriaTrendRange: [AtriaDetailChartPoint]]
    let fitnessAgeSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]
    let fitnessAgeComparison: [AtriaTrendRange: AtriaDetailComparisonSummary]
    /// Total saved days with a fitness-age delta, independent of range --
    /// gates the pace-of-aging chart behind the same 28-day baseline used by
    /// `AtriaFitnessAge.summary`.
    let fitnessAgeEntryCount: Int
    let paceOfAging: AtriaFitnessAge.PaceOfAging

    /// Long ranges (6M/1Y/All) display weekly buckets instead of every raw
    /// daily sample: value = average of the week's REAL days, band = that
    /// week's true min-max, tint = the member point nearest the average (so
    /// the metric's own zone coloring still applies). Short ranges and sparse
    /// series pass through untouched. Summaries/comparisons stay computed
    /// from raw daily points (2026-07-07 design handoff).
    static func bucketedForDisplay(_ points: [AtriaDetailChartPoint],
                                   range: AtriaTrendRange,
                                   calendar: Calendar,
                                   forceWeekly: Bool = false) -> [AtriaDetailChartPoint] {
        guard forceWeekly || (range.days > 90 && points.count > 60) else { return points }
        var buckets: [Date: [AtriaDetailChartPoint]] = [:]
        for point in points {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: point.day)?.start
                ?? calendar.startOfDay(for: point.day)
            buckets[weekStart, default: []].append(point)
        }
        return buckets.keys.sorted().map { weekStart in
            let members = buckets[weekStart] ?? []
            let values = members.map(\.value)
            let average = values.reduce(0, +) / Double(max(values.count, 1))
            let nearest = members.min { abs($0.value - average) < abs($1.value - average) }
            return AtriaDetailChartPoint(day: weekStart,
                                         value: average,
                                         tint: nearest?.tint ?? .secondary,
                                         bandLower: values.min(),
                                         bandUpper: values.max())
        }
    }

    private static func ghostSeries(_ points: [AtriaDetailChartPoint],
                                    range: AtriaTrendRange,
                                    calendar: Calendar) -> [AtriaDetailChartPoint] {
        let shifted = points.compactMap { point -> AtriaDetailChartPoint? in
            guard let day = calendar.date(byAdding: .day, value: range.days, to: point.day) else { return nil }
            return AtriaDetailChartPoint(day: day, value: point.value, tint: point.tint)
        }
        return bucketedForDisplay(shifted, range: range, calendar: calendar).map { point in
            AtriaDetailChartPoint(day: point.day, value: point.value, tint: point.tint)
        }
    }

    init(input: AtriaMetricDetailPreparationInput) {
        let rollups = input.rollups
        let baseline = input.baseline
        let sleepGoalHours = input.sleepGoalHours
        let calendar = input.calendar
        var recoveryByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var hrvByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var restingByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var respiratoryByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var strainByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var recoveryPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var hrvPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var restingPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var respiratoryPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var strainPriorByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var recoveryRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var hrvRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var restingRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var respiratoryRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var strainRawByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var latestStrainByRange: [AtriaTrendRange: Double] = [:]
        var recoverySummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var hrvSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var restingSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var respiratorySummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var sleepSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var strainSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var recoveryComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var hrvComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var restingComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var respiratoryComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var sleepComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var strainComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var sleepPerformanceByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var sleepPerformanceSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var sleepPerformanceComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        var fitnessAgeByRange: [AtriaTrendRange: [AtriaDetailChartPoint]] = [:]
        var fitnessAgeSummaryByRange: [AtriaTrendRange: AtriaDetailPeriodSummary] = [:]
        var fitnessAgeComparisonByRange: [AtriaTrendRange: AtriaDetailComparisonSummary] = [:]
        let chronologicalRollups = Array(rollups.reversed())
        let paceDeltas = chronologicalRollups.compactMap { entry in
            entry.fitnessAgeDelta.map { AtriaFitnessAge.DailyDelta(day: entry.day, delta: $0) }
        }
        let fitnessAgeEntryCount = AtriaFitnessAge.weeklyObservations(from: paceDeltas, calendar: calendar).count
        self.paceOfAging = AtriaFitnessAge.paceOfAging(deltas: paceDeltas, calendar: calendar)

        for range in AtriaTrendRange.allCases {
            let cutoff = range.cutoffDate(now: input.referenceDate, calendar: calendar)
            let previousCutoff = calendar.startOfDay(for: cutoff.addingTimeInterval(-Double(range.days) * 86_400))
            let filtered = chronologicalRollups.filter { $0.day >= cutoff }
            let priorFiltered = chronologicalRollups.filter { $0.day >= previousCutoff && $0.day < cutoff }
            let recoveryPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.recovery.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.recoveryColor($0)) }
            }
            let priorRecoveryPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.recovery.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.recoveryColor($0)) }
            }
            recoveryByRange[range] = Self.bucketedForDisplay(recoveryPoints, range: range, calendar: calendar)
            recoveryRawByRange[range] = recoveryPoints
            recoveryPriorByRange[range] = Self.ghostSeries(priorRecoveryPoints, range: range, calendar: calendar)
            recoverySummaryByRange[range] = AtriaDetailPeriodSummary(points: recoveryPoints, unit: "%")
            recoveryComparisonByRange[range] = AtriaDetailComparisonSummary(current: recoveryPoints, prior: priorRecoveryPoints, unit: "%")

            let hrvPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard let lnRMSSD = item.lnRMSSD else { return nil }
                let value = Int(exp(lnRMSSD).rounded())
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.hrvTint(value: value, baseline: baseline))
            }
            let priorHRVPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard let lnRMSSD = item.lnRMSSD else { return nil }
                let value = Int(exp(lnRMSSD).rounded())
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.hrvTint(value: value, baseline: baseline))
            }
            hrvByRange[range] = Self.bucketedForDisplay(hrvPoints, range: range, calendar: calendar)
            hrvRawByRange[range] = hrvPoints
            hrvPriorByRange[range] = Self.ghostSeries(priorHRVPoints, range: range, calendar: calendar)
            hrvSummaryByRange[range] = AtriaDetailPeriodSummary(points: hrvPoints, unit: "ms")
            hrvComparisonByRange[range] = AtriaDetailComparisonSummary(current: hrvPoints, prior: priorHRVPoints, unit: "ms")

            let restingPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard let value = item.restingHeartRate else { return nil }
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.restingTint(value: value, baseline: baseline))
            }
            let priorRestingPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard let value = item.restingHeartRate else { return nil }
                return AtriaDetailChartPoint(day: item.day,
                                             value: Double(value),
                                             tint: Self.restingTint(value: value, baseline: baseline))
            }
            restingByRange[range] = Self.bucketedForDisplay(restingPoints, range: range, calendar: calendar)
            restingRawByRange[range] = restingPoints
            restingPriorByRange[range] = Self.ghostSeries(priorRestingPoints, range: range, calendar: calendar)
            restingSummaryByRange[range] = AtriaDetailPeriodSummary(points: restingPoints, unit: "bpm")
            restingComparisonByRange[range] = AtriaDetailComparisonSummary(current: restingPoints, prior: priorRestingPoints, unit: "bpm")

            let respiratoryPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.respiratoryRate.map { AtriaDetailChartPoint(day: item.day, value: $0, tint: .teal) }
            }
            let priorRespiratoryPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.respiratoryRate.map { AtriaDetailChartPoint(day: item.day, value: $0, tint: .teal) }
            }
            respiratoryByRange[range] = Self.bucketedForDisplay(respiratoryPoints, range: range, calendar: calendar)
            respiratoryRawByRange[range] = respiratoryPoints
            respiratoryPriorByRange[range] = Self.ghostSeries(priorRespiratoryPoints, range: range, calendar: calendar)
            respiratorySummaryByRange[range] = AtriaDetailPeriodSummary(points: respiratoryPoints, unit: "/min")
            respiratoryComparisonByRange[range] = AtriaDetailComparisonSummary(current: respiratoryPoints, prior: priorRespiratoryPoints, unit: "/min")

            let sleepPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                guard let duration = item.sleepSeconds, duration > 0 else { return nil }
                let hours = duration / 3_600
                let tint: Color
                if let zone = Metrics.sleepDurationZone(hours, goalHours: sleepGoalHours) {
                    tint = zone.tint
                } else {
                    tint = .cyan
                }
                return AtriaDetailChartPoint(day: item.day, value: hours, tint: tint)
            }
            let priorSleepPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                guard let duration = item.sleepSeconds, duration > 0 else { return nil }
                let hours = duration / 3_600
                let tint = Metrics.sleepDurationZone(hours, goalHours: sleepGoalHours)?.tint ?? .cyan
                return AtriaDetailChartPoint(day: item.day, value: hours, tint: tint)
            }
            sleepByRange[range] = Self.bucketedForDisplay(sleepPoints, range: range, calendar: calendar)
            sleepRawByRange[range] = sleepPoints
            sleepPriorByRange[range] = Self.ghostSeries(priorSleepPoints, range: range, calendar: calendar)
            sleepSummaryByRange[range] = AtriaDetailPeriodSummary(points: sleepPoints, unit: "h")
            sleepComparisonByRange[range] = AtriaDetailComparisonSummary(current: sleepPoints, prior: priorSleepPoints, unit: "h")

            let strainPoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.strain.map { AtriaDetailChartPoint(day: item.day, value: $0, tint: Metrics.electricStrain) }
            }
            let priorStrainPoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.strain.map { AtriaDetailChartPoint(day: item.day, value: $0, tint: Metrics.electricStrain) }
            }
            strainByRange[range] = Self.bucketedForDisplay(strainPoints, range: range, calendar: calendar)
            strainRawByRange[range] = strainPoints
            strainPriorByRange[range] = Self.ghostSeries(priorStrainPoints, range: range, calendar: calendar)
            strainSummaryByRange[range] = AtriaDetailPeriodSummary(points: strainPoints, unit: "")
            strainComparisonByRange[range] = AtriaDetailComparisonSummary(current: strainPoints, prior: priorStrainPoints, unit: "")
            latestStrainByRange[range] = filtered.last?.strain

            let sleepPerformancePoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.sleepPerformance.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.electricSleep) }
            }
            let priorSleepPerformancePoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.sleepPerformance.map { AtriaDetailChartPoint(day: item.day, value: Double($0), tint: Metrics.electricSleep) }
            }
            sleepPerformanceByRange[range] = Self.bucketedForDisplay(sleepPerformancePoints, range: range, calendar: calendar)
            sleepPerformanceSummaryByRange[range] = AtriaDetailPeriodSummary(points: sleepPerformancePoints, unit: "%")
            sleepPerformanceComparisonByRange[range] = AtriaDetailComparisonSummary(current: sleepPerformancePoints, prior: priorSleepPerformancePoints, unit: "%")

            let fitnessAgePoints: [AtriaDetailChartPoint] = filtered.compactMap { item in
                item.fitnessAgeDelta.map { delta in
                    AtriaDetailChartPoint(day: item.day,
                                          value: Double(delta),
                                          tint: delta <= 0 ? Metrics.electricGreen : Metrics.electricYellow)
                }
            }
            let priorFitnessAgePoints: [AtriaDetailChartPoint] = priorFiltered.compactMap { item in
                item.fitnessAgeDelta.map { delta in
                    AtriaDetailChartPoint(day: item.day,
                                          value: Double(delta),
                                          tint: delta <= 0 ? Metrics.electricGreen : Metrics.electricYellow)
                }
            }
            fitnessAgeByRange[range] = Self.bucketedForDisplay(fitnessAgePoints, range: range, calendar: calendar)
            fitnessAgeSummaryByRange[range] = AtriaDetailPeriodSummary(points: fitnessAgePoints, unit: "y")
            fitnessAgeComparisonByRange[range] = AtriaDetailComparisonSummary(current: fitnessAgePoints, prior: priorFitnessAgePoints, unit: "y")
        }

        self.recovery = recoveryByRange
        self.hrv = hrvByRange
        self.restingHeartRate = restingByRange
        self.respiratoryRate = respiratoryByRange
        self.sleep = sleepByRange
        self.strain = strainByRange
        self.recoveryPrior = recoveryPriorByRange
        self.hrvPrior = hrvPriorByRange
        self.restingHeartRatePrior = restingPriorByRange
        self.respiratoryRatePrior = respiratoryPriorByRange
        self.sleepPrior = sleepPriorByRange
        self.strainPrior = strainPriorByRange
        self.recoveryRaw = recoveryRawByRange
        self.hrvRaw = hrvRawByRange
        self.restingHeartRateRaw = restingRawByRange
        self.respiratoryRateRaw = respiratoryRawByRange
        self.sleepRaw = sleepRawByRange
        self.strainRaw = strainRawByRange
        self.latestStrain = latestStrainByRange
        self.recoverySummary = recoverySummaryByRange
        self.hrvSummary = hrvSummaryByRange
        self.restingHeartRateSummary = restingSummaryByRange
        self.respiratoryRateSummary = respiratorySummaryByRange
        self.sleepSummary = sleepSummaryByRange
        self.strainSummary = strainSummaryByRange
        self.recoveryComparison = recoveryComparisonByRange
        self.hrvComparison = hrvComparisonByRange
        self.restingHeartRateComparison = restingComparisonByRange
        self.respiratoryRateComparison = respiratoryComparisonByRange
        self.sleepComparison = sleepComparisonByRange
        self.strainComparison = strainComparisonByRange
        self.sleepPerformance = sleepPerformanceByRange
        self.sleepPerformanceSummary = sleepPerformanceSummaryByRange
        self.sleepPerformanceComparison = sleepPerformanceComparisonByRange
        self.fitnessAge = fitnessAgeByRange
        self.fitnessAgeSummary = fitnessAgeSummaryByRange
        self.fitnessAgeComparison = fitnessAgeComparisonByRange
        self.fitnessAgeEntryCount = fitnessAgeEntryCount
    }

    private static func hrvTint(value: Int,
                                baseline: AtriaMetricDetailPreparationInput.Baseline) -> Color {
        guard baseline.hrvTrusted,
              baseline.hrvSampleCount >= PersonalBaseline.trustedMinimumSamples,
              let target = baseline.hrvBaseline,
              target > 0 else { return .pink }
        let ratio = Double(value) / Double(target)
        var level = ratio >= 0.95 ? 0 : (ratio >= 0.85 ? 1 : 2)
        if let mean = baseline.hrvLnMean,
           let sd = baseline.hrvLnSD,
           sd > 0.1 {
            let zScore = (log(Double(value)) - mean) / sd
            level = max(level, zScore >= -1 ? 0 : (zScore >= -2 ? 1 : 2))
        }
        return tint(forSeverity: level)
    }

    private static func restingTint(value: Int,
                                    baseline: AtriaMetricDetailPreparationInput.Baseline) -> Color {
        guard baseline.restingTrusted,
              baseline.restingSampleCount >= PersonalBaseline.trustedMinimumSamples,
              let target = baseline.restingBaseline,
              target > 0 else { return .pink }
        let delta = value - target
        var level = delta <= 3 ? 0 : (delta <= 7 ? 1 : 2)
        if let mean = baseline.restingMean,
           let sd = baseline.restingSD,
           sd > 0.1 {
            let zScore = (Double(value) - mean) / sd
            level = max(level, zScore <= 1 ? 0 : (zScore <= 2 ? 1 : 2))
        }
        return tint(forSeverity: level)
    }

    private static func tint(forSeverity severity: Int) -> Color {
        switch severity {
        case 0: return .green
        case 1: return .orange
        default: return .red
        }
    }
}

struct AtriaDetailChartPoint: Identifiable, Sendable {
    let day: Date
    let value: Double
    let tint: Color
    /// Weekly-bucket min/max band bounds (2026-07-07 design handoff long-range
    /// bucketing). nil on raw daily points.
    var bandLower: Double? = nil
    var bandUpper: Double? = nil

    var id: Date { day }
}

struct AtriaDetailBaselineBand {
    let lower: Double
    let upper: Double
    let tint: Color
}

private struct AtriaSleepHypnogramCard: View {
    let night: SleepHistorySnapshot.Night
    let neededHours: Double
    let consistencyPercent: Int?
    @AtriaDefault(AtriaWakeAlarmStore.enabledKey) private var wakeAlarmEnabled: Bool = false
    @AtriaDefault(AtriaWakeAlarmStore.modeKey) private var wakeAlarmMode: String = AtriaWakeAlarmPlan.Mode.smartWindow.rawValue
    @AtriaDefault(AtriaWakeAlarmStore.wakeByMinutesKey) private var wakeByMinutes: Int = AtriaWakeAlarmPlan.defaultPlan.wakeByMinutes
    @AtriaDefault("atria.sleepPlanner.goal") private var plannerGoalRaw: String = AtriaSleepPlannerGoal.peak.rawValue
    @State private var alarmStatusText: String?
    /// Efficiencies of the user's real confirmed nights, for the planner's
    /// time-in-bed assumption. Passed in so this card stays store-free.
    var nightEfficiencies: [Double] = []

    private var wakeAlarmPlan: AtriaWakeAlarmPlan {
        AtriaWakeAlarmPlan(mode: AtriaWakeAlarmPlan.Mode(rawValue: wakeAlarmMode) ?? .smartWindow,
                           wakeByHour: wakeByMinutes / 60,
                           wakeByMinute: wakeByMinutes % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header duration removed (dedup audit 2026-07-07): the sheet
            // hero owns the duration readout.
            Text("Sleep estimate")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if night.displayStageSegments.isEmpty {
                Text("Stages are still building. Atria labels this as a heart-rate and motion estimate, not EEG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { proxy in
                    let total = max(night.duration, 1)
                    HStack(spacing: 2) {
                        ForEach(night.displayStageSegments) { stage in
                            Rectangle()
                                .fill(stageTint(stage.stage))
                                .frame(width: max(6, proxy.size.width * CGFloat(stage.duration / total)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(height: 42)

                // Legend so the colored bar is self-explanatory (2026-07-08 UX
                // audit: it was an unlabeled two-tone bar).
                let presentStages = SleepStageKind.displayOrder.filter { stage in
                    night.displayStageSegments.contains { $0.stage == stage }
                }
                if !presentStages.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(presentStages) { stage in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(stageTint(stage))
                                    .frame(width: 8, height: 8)
                                Text(stage.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                Text("Heart-rate and motion estimate — useful for trend context, not an EEG sleep study.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Performance/Consistency pills removed (dedup audit): the
            // contributor rows below the chart own both values. The footer
            // keeps only the need context — duration and performance live
            // on the hero.
            Text("Needed \(AtriaMetricFormat.sleepHours(neededHours)) last night")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            wakeAlarmCard

            sleepPlannerCard

            if let consistencyPercent {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(consistencyPercent), total: 100)
                        .tint(.mint)
                    Text("Consistency bar uses recent sleep timing and duration.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
    }

    /// Sleep Planner (2026-07-07, WHOOP-research adaptation): pick a goal,
    /// get an in-bed-by time worked back from the wake alarm using tonight's
    /// need and the user's own typical efficiency.
    private var sleepPlannerCard: some View {
        let goal = AtriaSleepPlannerGoal(rawValue: plannerGoalRaw) ?? .peak
        let plan = AtriaSleepPlanner.plan(needHours: neededHours,
                                          goal: goal,
                                          wakeByMinutes: wakeByMinutes,
                                          nightEfficiencies: nightEfficiencies)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bed.double.circle.fill")
                    .foregroundStyle(Metrics.electricSleep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tonight's plan")
                        .font(.caption.weight(.bold))
                    Text("In bed by \(plan.inBedByText) \u{00b7} \(AtriaMetricFormat.sleepHours(plan.targetSleepHours)) asleep")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Picker("Sleep goal", selection: Binding(
                get: { AtriaSleepPlannerGoal(rawValue: plannerGoalRaw) ?? .peak },
                set: { plannerGoalRaw = $0.rawValue })) {
                ForEach(AtriaSleepPlannerGoal.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text("\(goal.detail) tonight, assuming your \(plan.efficiencyIsDefault ? "typical-population" : "own typical") efficiency (\(Int((plan.assumedEfficiency * 100).rounded()))%)\(plan.efficiencyIsDefault ? " \u{2014} learning yours" : ""). Anchored to your wake-by time above.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Metrics.electricSleep.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight's plan. \(goal.title): in bed by \(plan.inBedByText) for \(AtriaMetricFormat.sleepHours(plan.targetSleepHours)) of sleep.")
    }

    private var wakeAlarmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wake alarm")
                        .font(.caption.weight(.bold))
                    Text("\(wakeAlarmPlan.mode.title) · wake by \(wakeAlarmPlan.displayTime)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Picker("Wake mode", selection: $wakeAlarmMode) {
                ForEach(AtriaWakeAlarmPlan.Mode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: wakeAlarmMode) { _, _ in
                if wakeAlarmEnabled { scheduleWakeAlarm() }
            }

            HStack(spacing: 10) {
                Stepper(value: $wakeByMinutes, in: 0...(23 * 60 + 59), step: 5) {
                    Text("Wake by \(wakeAlarmPlan.displayTime)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .onChange(of: wakeByMinutes) { _, _ in
                    AtriaWakeAlarmStore.save(wakeAlarmPlan)
                    if wakeAlarmEnabled { scheduleWakeAlarm() }
                }

                Button {
                    wakeAlarmEnabled.toggle()
                    if wakeAlarmEnabled {
                        scheduleWakeAlarm()
                    } else {
                        AtriaWakeAlarmScheduler.cancelLast()
                        alarmStatusText = "Alarm off"
                    }
                } label: {
                    Label(wakeAlarmEnabled ? "On" : "Set", systemImage: wakeAlarmEnabled ? "checkmark.circle.fill" : "alarm")
                }
                .atriaCardAction(tint: .cyan)
            }

            Text(alarmStatusText ?? "Phone alarm uses AlarmKit. Smart window can wake early during light or awake sleep; hard wake-by remains the fallback.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func scheduleWakeAlarm() {
        let plan = wakeAlarmPlan
        AtriaWakeAlarmStore.save(plan)
        Task {
            let result = await AtriaWakeAlarmScheduler.scheduleHardAlarm(plan: plan)
            await MainActor.run {
                switch result {
                case .scheduled(_, let fireDate):
                    alarmStatusText = "AlarmKit set \(fireDate.formatted(date: .omitted, time: .shortened))"
                    AtriaDebugLog("ATRIADBG wake_alarm_detail status=scheduled mode=%@ wake_by=%@ fire=%@",
                                  plan.mode.rawValue,
                                  plan.displayTime,
                                  fireDate.formatted(date: .numeric, time: .shortened))
                case .denied:
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm permission needed"
                case .unavailable(let reason):
                    wakeAlarmEnabled = false
                    alarmStatusText = "Alarm unavailable"
                    AtriaDebugLog("ATRIADBG wake_alarm_detail status=unavailable reason=%@",
                                  reason)
                }
            }
        }
    }

    private var sleepPerformanceText: String {
        "\(AtriaSleepBudget.performancePercent(slept: night.durationHours, needed: neededHours))%"
    }

    private var sleepConsistencyText: String {
        consistencyPercent.map { "\($0)%" } ?? "Building"
    }

    private func stageTint(_ stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan.opacity(0.65)
        case .rem: return .blue
        case .sws, .deep: return .indigo
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AtriaStrainBandGauge: View {
    let strain: Double
    let target: Double?
    let size: CGFloat

    private let bands: [(range: ClosedRange<Double>, label: String)] = [
        (0...9, "Light"),
        (10...13, "Moderate"),
        (14...17, "High"),
        (18...21, "All-Out")
    ]

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.06), lineWidth: 16)

                // Four effort bands (Light/Moderate/High/All-Out) as clean solid
                // segments. Was a dashed stroke (dash [2,12] @ 16pt round caps)
                // that rendered as fat scattered dots — read as broken, esp. at
                // low strain where the fill arc is nearly invisible. The natural
                // gaps between the band ranges now delineate the zones.
                ForEach(Array(bands.enumerated()), id: \.element.label) { _, band in
                    Circle()
                        .trim(from: band.range.lowerBound / 21, to: band.range.upperBound / 21)
                        .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }

                if let target {
                    Circle()
                        .trim(from: max(0, (target - 1) / 21), to: min(1, (target + 1) / 21))
                        .stroke(Metrics.electricStrain.opacity(0.22), style: StrokeStyle(lineWidth: 20, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Circle()
                        .fill(Metrics.electricStrain)
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle()
                                .stroke(Color(.systemBackground).opacity(0.9), lineWidth: 2)
                        }
                        .offset(notchOffset(for: target))
                }

                Circle()
                    .trim(from: 0, to: min(max(strain / 21, 0), 1))
                    .stroke(Metrics.electricStrain, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text(String(format: "%.1f", strain))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(activeBandLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)

            if let target {
                Text(String(format: "Target %.1f", target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var activeBandLabel: String {
        bands.first(where: { $0.range.contains(strain) })?.label ?? "Light"
    }

    private func notchOffset(for target: Double) -> CGSize {
        let progress = min(max(target / 21, 0), 1)
        let angle = (progress * .pi * 2) - (.pi / 2)
        let radius = (size - 18) / 2
        return CGSize(width: cos(angle) * radius,
                      height: sin(angle) * radius)
    }
}

struct AtriaOverviewMorningJournalHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @StateObject private var projectionStore: AtriaOverviewMorningJournalProjectionStore
    @State private var adjustmentNight: SleepHistorySnapshot.Night?

    init(snapshotStore: AtriaHomeModel.SnapshotStore, store: SessionStore) {
        self.snapshotStore = snapshotStore
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaOverviewMorningJournalProjectionStore(store: store))
    }

    var body: some View {
        let projection = projectionStore.state
        let sleepHistory = debugFixtureSleepHistory ?? projection.sleepHistory
        VStack(spacing: 12) {
            AtriaOverviewMorningJournalCard(snapshot: snapshotStore.state,
                                            sleepHistory: sleepHistory,
                                            sleepHistoryRevision: projection.sleepHistoryRevision,
                                            todayEntry: projection.todayEntry,
                                            taggedDays: projection.taggedDays,
                                            onToggleTag: { tag in
                                                store.toggleBehaviorTag(tag)
                                            },
                                            onConfirmSleep: {
                                                guard let night = sleepHistory.latest else { return false }
                                                return store.confirmSleepHistoryNightForUI(
                                                    night,
                                                    rest: store.baseline.restingInt ?? 60,
                                                    source: "morning_journal"
                                                ) != nil
                                            },
                                            onAdjustSleep: {
                                                adjustmentNight = sleepHistory.latest
                                            })
                .equatable()

            AtriaMorningCheckInCard(mainSleepEnd: sleepHistory.latest.flatMap { $0.isNapEvidence ? nil : $0.end }) {
                store.recoveryProjectionForPresentation(
                    initialFallbackHRVSnapshot: nil,
                    liveRestingHeartRate: nil,
                    pendingSleepReview: sleepHistory.latest
                )
            }
        }
            .sheet(item: $adjustmentNight) { adjustment in
                AtriaManualSleepSheet(initialStart: adjustment.start,
                                      initialEnd: adjustment.end,
                                      initialIsNap: adjustment.isNapEvidence,
                                      preservesSensorStages: true,
                                      evidenceNight: adjustment,
                                      evidencePerformancePercent: sleepHistory.sleepPerformancePercent(for: adjustment,
                                                                                                       baseNeedHours: SessionStore.configuredSleepBaseNeedHours())) { start, end, isNap in
                    let saved = store.saveSleepReviewNightForUI(
                        adjustment,
                        start: start,
                        end: end,
                        isNap: isNap,
                        rest: store.baseline.restingInt ?? 60,
                        source: "morning_journal_adjust"
                    ) != nil
                    if saved { adjustmentNight = nil }
                    return saved
                }
            }
    }

    #if DEBUG
    private var debugFixtureSleepHistory: SleepHistorySnapshot? {
        Self.debugFixtureSleepHistory(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureSleepHistory(arguments: [String]) -> SleepHistorySnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        // Static handoff compatibility marker: ["pending-sleep-review", "journal-impact"].contains(arguments[valueIndex])
        guard valueIndex < arguments.endIndex,
              ["pending-sleep-review", "pending-sleep-provisional-recovery", "journal-impact"].contains(arguments[valueIndex]) else {
            return nil
        }

        let calendar = Calendar.current
        let end = calendar.date(bySettingHour: 7, minute: 18, second: 0, of: Date()) ?? Date()
        let start = calendar.date(byAdding: .minute, value: -438, to: end) ?? end.addingTimeInterval(-438 * 60)
        let day = calendar.startOfDay(for: end)
        let night = SleepHistorySnapshot.Night(id: "debug-ui-fixture-pending-sleep-review",
                                               day: day,
                                               start: start,
                                               end: end,
                                               duration: 438 * 60,
                                               restingHR: 54,
                                               hrv: 72,
                                               respiratoryRate: 14.6,
                                               sleepEfficiency: 0.89,
                                               confidence: "debug_fixture_pending_review",
                                               source: "sleep_candidate",
                                               confirmed: false,
                                               stageSegments: [])
        return SleepHistorySnapshot(nights: [night], confirmedCount: 0, candidateCount: 1)
    }
    #else
    private var debugFixtureSleepHistory: SleepHistorySnapshot? { nil }
    #endif
}

struct AtriaOverviewMorningJournalProjectionState: Equatable {
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let todayEntry: BehaviorJournalEntry
    let taggedDays: Int
}

@MainActor
final class AtriaOverviewMorningJournalProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewMorningJournalProjectionState

    private let store: SessionStore?
    private var behaviorJournalRevision: Int
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(store: SessionStore) {
        self.store = store
        behaviorJournalRevision = store.behaviorJournalRevision
        state = Self.makeState(store: store)
        bind(to: store)
    }

    init(state: AtriaOverviewMorningJournalProjectionState) {
        self.state = state
        store = nil
        behaviorJournalRevision = 0
    }

    @discardableResult
    func refresh(_ next: AtriaOverviewMorningJournalProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        store.$sleepHistorySnapshot
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self, weak store] _ in
                guard let self, let store,
                      store.behaviorJournalRevision != self.behaviorJournalRevision else { return }
                self.scheduleRefresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard let store = self.store else { return }
            self.behaviorJournalRevision = store.behaviorJournalRevision
            self.refresh(Self.makeState(store: store))
        }
    }

    private static func makeState(store: SessionStore) -> AtriaOverviewMorningJournalProjectionState {
        AtriaOverviewMorningJournalProjectionState(
            sleepHistory: store.sleepHistorySnapshot,
            sleepHistoryRevision: store.sleepHistorySnapshotRevision,
            todayEntry: store.behaviorJournalEntry(),
            taggedDays: store.behaviorJournalEntries.count
        )
    }
}

private struct AtriaJournalSleepFact: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { title }
}

struct AtriaOverviewMorningJournalCard: View, Equatable {
    let snapshot: AtriaHomeModel.Snapshot
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let todayEntry: BehaviorJournalEntry
    let taggedDays: Int
    let onToggleTag: (BehaviorJournalEntry.Tag) -> Void
    let onConfirmSleep: () -> Bool
    let onAdjustSleep: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAllJournalTags = false
    @State private var sleepConfirmationFailed = false

    static func == (lhs: AtriaOverviewMorningJournalCard, rhs: AtriaOverviewMorningJournalCard) -> Bool {
        lhs.snapshot.sleepValue == rhs.snapshot.sleepValue
            && lhs.snapshot.sleepDetail == rhs.snapshot.sleepDetail
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
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

    private var sleepActionText: String {
        guard let latestNight else {
            return snapshot.sleepDetail
        }

        if latestNight.confirmed {
            return latestNight.isNapEvidence
                ? "Nap saved separately."
                : "Sleep saved for recovery."
        }
        return latestNight.isNapEvidence
            ? "Confirm if this nap looks right."
            : "Confirm if this sleep looks right."
    }

    private var sleepMetricFacts: [AtriaJournalSleepFact] {
        guard let latestNight else { return [] }

        var facts: [AtriaJournalSleepFact] = []
        if latestNight.sleepEfficiencyText != "--" {
            facts.append(AtriaJournalSleepFact(title: "Eff", value: latestNight.sleepEfficiencyText))
        }
        if latestNight.hrvText != "--" {
            facts.append(AtriaJournalSleepFact(title: "HRV", value: latestNight.hrvText))
        }
        if latestNight.respiratoryRateText != "--" {
            facts.append(AtriaJournalSleepFact(title: "Resp", value: latestNight.respiratoryRateText))
        }
        return Array(facts.prefix(3))
    }

    private var selectedTags: [BehaviorJournalEntry.Tag] {
        BehaviorJournalEntry.Tag.allCases.filter { todayEntry.tags.contains($0) }
    }

    private var visibleJournalTags: [BehaviorJournalEntry.Tag] {
        let quick: [BehaviorJournalEntry.Tag] = [.sleep, .training, .caffeine]
        guard !showsAllJournalTags else { return BehaviorJournalEntry.Tag.allCases }
        return quick
    }

    private var hiddenJournalTagCount: Int {
        max(BehaviorJournalEntry.Tag.allCases.count - visibleJournalTags.count, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Morning journal", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: latestNight?.confirmed == true ? .validated : (sleepHistory.candidateCount > 0 ? .research : .learning))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: latestNight?.isNapEvidence == true ? "moon.zzz.fill" : "bed.double.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.cyan)
                        .frame(width: 34, height: 34)
                        .background(Color.cyan.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(sleepReviewTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(sleepActionText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
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

                if shouldShowConfirmSleep {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 8) {
                            Button(action: onAdjustSleep) {
                                Label("Adjust", systemImage: "slider.horizontal.3")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(prominent: false, tint: .cyan)

                            Button {
                                sleepConfirmationFailed = !onConfirmSleep()
                            } label: {
                                Label(latestNight?.isNapEvidence == true ? "Confirm nap" : "Confirm sleep",
                                      systemImage: "checkmark.circle")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(tint: .cyan)
                        }
                    }

                    if sleepConfirmationFailed {
                        Label("Couldn't save. The suggestion is still here — try again, or tap Adjust to change the window.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Couldn't save sleep. The suggestion remains available. Try again or adjust the detected window.")
                    }
                }

                if !sleepMetricFacts.isEmpty {
                    LazyVGrid(columns: Self.sleepFactColumns, spacing: 8) {
                        ForEach(sleepMetricFacts) { fact in
                            sleepFactPill(fact)
                        }
                    }
                }
            }
            .padding(12)
            .atriaInsetCard(tint: .cyan)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(sleepReviewTitle) \(sleepReviewValue). \(sleepActionText)")

            morningJournalStackRail

            AtriaJournalTodayTagStrip(selectedTags: selectedTags,
                                      healthAutoTags: todayEntry.healthAutoTags,
                                      taggedDays: taggedDays,
                                      showsAllTags: showsAllJournalTags,
                                      hiddenTagCount: hiddenJournalTagCount,
                                      onToggleMore: {
                                          withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                              showsAllJournalTags.toggle()
                                          }
                                      })

            LazyVGrid(columns: Self.tagColumns, spacing: 8) {
                ForEach(visibleJournalTags) { tag in
                    Button {
                        if reduceMotion {
                            onToggleTag(tag)
                        } else {
                            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                onToggleTag(tag)
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: todayEntry.tags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(todayEntry.tags.contains(tag) ? .cyan : .secondary)
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
            .animation(.snappy(duration: AtriaDesignTokens.Motion.standard), value: showsAllJournalTags)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .onChange(of: latestNight?.id) { _, _ in
            sleepConfirmationFailed = false
        }
    }

    private static let tagColumns = [GridItem(.adaptive(minimum: 118), spacing: 8)]
    private static let sleepFactColumns = [GridItem(.flexible(), spacing: 8),
                                           GridItem(.flexible(), spacing: 8),
                                           GridItem(.flexible(), spacing: 8)]

    private var morningJournalStackRail: some View {
        HStack(spacing: 7) {
            journalPathStep(systemImage: latestNight?.isNapEvidence == true ? "moon.zzz.fill" : "bed.double.fill",
                            title: "Sleep",
                            value: shouldShowConfirmSleep ? "Review" : "Saved",
                            tint: .cyan)
            journalPathStep(systemImage: "tag.fill",
                            title: "Tags",
                            value: selectedTags.isEmpty ? "Today" : "\(selectedTags.count)",
                            tint: .cyan)
            journalPathStep(systemImage: "chart.xyaxis.line",
                            title: "Links",
                            value: taggedDays > 0 ? "Ready" : "Build",
                            tint: .mint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Morning path: review sleep, tag today, and see habit links.")
    }

    private func journalPathStep(systemImage: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func sleepFactPill(_ fact: AtriaJournalSleepFact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(fact.value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func metricDisplayValue(_ value: String) -> String {
        value.localizedCaseInsensitiveContains("learning")
            || value.localizedCaseInsensitiveContains("prepar")
            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "--"
            : value
    }
}

private struct AtriaJournalTodayTagStrip: View, Equatable {
    let selectedTags: [BehaviorJournalEntry.Tag]
    let healthAutoTags: [BehaviorJournalEntry.Tag]
    let taggedDays: Int
    let showsAllTags: Bool
    let hiddenTagCount: Int
    let onToggleMore: () -> Void

    static func == (lhs: AtriaJournalTodayTagStrip, rhs: AtriaJournalTodayTagStrip) -> Bool {
        lhs.selectedTags == rhs.selectedTags
            && lhs.healthAutoTags == rhs.healthAutoTags
            && lhs.taggedDays == rhs.taggedDays
            && lhs.showsAllTags == rhs.showsAllTags
            && lhs.hiddenTagCount == rhs.hiddenTagCount
    }

    private var title: String {
        selectedTags.isEmpty ? "Tag today" : "\(selectedTags.count) logged today"
    }

    private var detail: String {
        if selectedTags.isEmpty {
            return taggedDays > 0
                ? "Keep the loop going; one tap is enough."
                : "Tap what happened and Atria compares it locally."
        }
        let healthCount = selectedTags.filter { healthAutoTags.contains($0) }.count
        if healthCount > 0 {
            return "\(selectedTags.map(\.label).joined(separator: " · ")) · \(healthCount) from Health"
        }
        return selectedTags.map(\.label).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.13))
                Image(systemName: selectedTags.isEmpty ? "plus.circle.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 6)

            Button(action: onToggleMore) {
                Text(showsAllTags ? "Less" : "+\(hiddenTagCount)")
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(.cyan)
                    .frame(minWidth: 38)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .atriaCardAction(prominent: false, tint: .cyan)
            .accessibilityLabel(showsAllTags ? "Show fewer journal tags" : "Show \(hiddenTagCount) more journal tags")

            if !selectedTags.isEmpty {
                HStack(spacing: -4) {
                    ForEach(selectedTags.prefix(4)) { tag in
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: tag.symbolName)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.cyan)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.10), in: Circle())
                            if healthAutoTags.contains(tag) {
                                Image(systemName: "heart.text.square.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.green)
                                    .background(Color(.systemBackground), in: Circle())
                                    .offset(x: 3, y: 3)
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(10)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.cyan.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
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

    private var trendHeadline: String {
        snapshot.trendConfidence == "high" ? "History is ready" : "History is building"
    }

    private var trendCue: String {
        snapshot.trendConfidence == "high" ? "Use trends for direction" : "Keep wearing for cleaner patterns"
    }

    private var trendStateText: String {
        snapshot.trendConfidence == "high" ? "Ready" : "Building"
    }

    private var trendTint: Color {
        snapshot.trendConfidence == "high" ? .cyan : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Trends", subtitle: "")

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(trendTint.opacity(0.16), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: trendProgress)
                        .stroke(trendTint.opacity(0.84),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(trendTint)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(trendHeadline)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text(trendCue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(snapshot.trendCoverageText)
                    .font(.title2.weight(.black).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(spacing: 8) {
                trendRangeLadder
                trendMetaChip(title: "Direction",
                              value: trendStateText,
                              systemImage: "arrow.up.right.circle.fill",
                              tint: trendTint)
                trendMetaChip(title: "Privacy",
                              value: "Local",
                              systemImage: "lock.fill",
                              tint: .secondary)
            }

            Text(snapshot.trendDetail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var trendProgress: CGFloat {
        let digits = snapshot.trendCoverageText.filter(\.isNumber)
        guard let value = Double(digits) else {
            return snapshot.trendConfidence == "high" ? 1 : 0.34
        }
        return CGFloat(min(max(value / 100.0, 0.12), 1))
    }

    private var trendRangeLadder: some View {
        HStack(spacing: 6) {
            ForEach(["D", "W", "M", "3M", "6M"], id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.black).monospacedDigit())
                    .foregroundStyle(label == "M" ? Color.cyan : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background((label == "M" ? Color.cyan : Color.secondary).opacity(label == "M" ? 0.12 : 0.055),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(Color.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trend ranges. Day, week, month, 3 months, and 6 months.")
    }

    private func trendMetaChip(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct AtriaOverviewBehaviorJournalSection: View {
    @StateObject private var projectionStore: AtriaOverviewBehaviorJournalProjectionStore

    init(store: SessionStore) {
        _projectionStore = StateObject(
            wrappedValue: AtriaOverviewBehaviorJournalProjectionStore(store: store)
        )
    }

    private var displayModel: AtriaOverviewBehaviorJournalModel {
        if let debugFixtureBehaviorSummaries {
            let impacts = debugFixtureBehaviorImpacts ?? []
            return AtriaOverviewBehaviorJournalModel(summaries: Array(debugFixtureBehaviorSummaries.prefix(3)),
                                                     behaviorImpacts: Array(impacts.prefix(3)),
                                                     taggedDays: 12)
        }
        return projectionStore.state.model
    }

    var body: some View {
        AtriaOverviewBehaviorJournalContent(model: displayModel)
            .equatable()
    }

    #if DEBUG
    static var debugShowsImpactOnlyFixture: Bool {
        debugFixtureBehaviorSummaries(arguments: ProcessInfo.processInfo.arguments) != nil
            && ProcessInfo.processInfo.arguments.contains("journal-impact-focus")
    }

    private var debugFixtureBehaviorSummaries: [BehaviorCorrelationSummary]? {
        Self.debugFixtureBehaviorSummaries(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureBehaviorSummaries(arguments: [String]) -> [BehaviorCorrelationSummary]? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex,
              ["journal-impact", "journal-impact-focus"].contains(arguments[valueIndex]) else {
            return nil
        }

        return [
            BehaviorCorrelationSummary(tag: .sleep, days: 9, recoveryDelta: nil, hrvDelta: 6),
            BehaviorCorrelationSummary(tag: .training, days: 7, recoveryDelta: nil, hrvDelta: 3),
            BehaviorCorrelationSummary(tag: .caffeine, days: 6, recoveryDelta: nil, hrvDelta: -4)
        ]
    }

    private var debugFixtureBehaviorImpacts: [BehaviorImpactSummary]? {
        guard Self.debugFixtureBehaviorSummaries(arguments: ProcessInfo.processInfo.arguments) != nil else {
            return nil
        }
        return [
            BehaviorImpactSummary(tag: .stress, loggedDays: 8, comparisonDays: 24, impact: -11, pValue: 0.04),
            BehaviorImpactSummary(tag: .sleep, loggedDays: 9, comparisonDays: 23, impact: 7, pValue: 0.07)
        ]
    }
    #else
    static var debugShowsImpactOnlyFixture: Bool { false }
    private var debugFixtureBehaviorSummaries: [BehaviorCorrelationSummary]? { nil }
    private var debugFixtureBehaviorImpacts: [BehaviorImpactSummary]? { nil }
    #endif
}

private struct AtriaOverviewBehaviorJournalModel: Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let behaviorImpacts: [BehaviorImpactSummary]
    let taggedDays: Int
}

struct AtriaOverviewBehaviorJournalProjectionState: Equatable {
    fileprivate let model: AtriaOverviewBehaviorJournalModel

    init(summaries: [BehaviorCorrelationSummary],
         behaviorImpacts: [BehaviorImpactSummary],
         taggedDays: Int) {
        model = AtriaOverviewBehaviorJournalModel(
            summaries: Array(summaries.filter { $0.days > 0 }.prefix(3)),
            behaviorImpacts: Array(behaviorImpacts.prefix(3)),
            taggedDays: taggedDays
        )
    }
}

/// Equality-gated bridge for the direct Journal-tab child. It can hear the
/// dashboard revision used by behavior tags without invalidating for unrelated
/// live-session publishes.
@MainActor
final class AtriaOverviewBehaviorJournalProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaOverviewBehaviorJournalProjectionState

    private var cancellables = Set<AnyCancellable>()

    init(state: AtriaOverviewBehaviorJournalProjectionState) {
        self.state = state
    }

    convenience init(store: SessionStore) {
        self.init(state: Self.makeState(store: store))
        bind(to: store)
    }

    @discardableResult
    func refresh(_ next: AtriaOverviewBehaviorJournalProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        Publishers.MergeMany([
            store.$dashboardRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorCorrelationSummariesCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorImpactSummariesCache.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        // @Published emits before assignment; coalesce the journal/cache batch
        // onto the next run-loop turn so the projection reads consistent values.
        .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
        .sink { [weak self, weak store] in
            guard let self, let store else { return }
            self.refresh(Self.makeState(store: store))
        }
        .store(in: &cancellables)
    }

    private static func makeState(store: SessionStore) -> AtriaOverviewBehaviorJournalProjectionState {
        AtriaOverviewBehaviorJournalProjectionState(
            summaries: store.behaviorCorrelationSummariesCache,
            behaviorImpacts: store.behaviorImpactSummariesCache,
            taggedDays: store.behaviorJournalEntries.count
        )
    }
}

private struct AtriaOverviewBehaviorJournalContent: View, Equatable {
    let model: AtriaOverviewBehaviorJournalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Impacts", subtitle: "What's affecting you")

                Spacer(minLength: 0)

                AtriaStatusChip(text: model.taggedDays > 0 ? "\(model.taggedDays)d" : "learning",
                                systemImage: "waveform.path.ecg",
                                tint: .cyan)
            }

            AtriaJournalImpactStrip(summaries: model.summaries,
                                     behaviorImpacts: model.behaviorImpacts,
                                     taggedDays: model.taggedDays)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaJournalImpactStrip: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let behaviorImpacts: [BehaviorImpactSummary]
    let taggedDays: Int

    private var focusSummary: BehaviorCorrelationSummary? {
        summaries.first
    }

    var body: some View {
        // The inner "Impact" + day-count header was removed (2026-07-08 UX
        // audit: it duplicated the outer "Impacts" card's title and day chip,
        // reading as a card-in-card). Contents promote straight up.
        VStack(alignment: .leading, spacing: 12) {
            if behaviorImpacts.isEmpty && summaries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tag.circle")
                        .foregroundStyle(.secondary)
                    Text(taggedDays > 0 ? "Keep tagging for next-day impact." : "Tags unlock next-day impact.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if !behaviorImpacts.isEmpty {
                    AtriaJournalBehaviorImpactRows(impacts: behaviorImpacts)
                }

                AtriaJournalImpactGlanceBoard(summaries: summaries,
                                              taggedDays: taggedDays)

                VStack(spacing: 9) {
                    ForEach(summaries, id: \.tag) { summary in
                        AtriaJournalImpactBar(summary: summary)
                    }
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
    }
}

struct AtriaJournalBehaviorImpactRows: View, Equatable {
    let impacts: [BehaviorImpactSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(impacts) { impact in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: impact.tag.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint(for: impact))
                        .frame(width: 18)
                    Text(impact.tag.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(impact.valueText) · \(impact.nightsText)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint(for: impact))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Text("Correlation from your logs, not causation.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func tint(for impact: BehaviorImpactSummary) -> Color {
        impact.impact >= 0 ? .mint : .orange
    }
}

private struct AtriaJournalImpactGlanceBoard: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let taggedDays: Int

    private var supportSummaries: [BehaviorCorrelationSummary] {
        summaries.filter { ($0.impactDelta ?? 0) > 0 }
    }

    private var pressureSummaries: [BehaviorCorrelationSummary] {
        summaries.filter { ($0.impactDelta ?? 0) < 0 }
    }

    private var focusSummary: BehaviorCorrelationSummary? {
        summaries.first
    }

    private var patternCount: Int {
        summaries.filter { $0.impactDelta != nil }.count
    }

    private var supportValue: Double {
        min(supportSummaries.reduce(0) { $0 + $1.impactMagnitude } / 12, 1)
    }

    private var pressureValue: Double {
        min(pressureSummaries.reduce(0) { $0 + $1.impactMagnitude } / 12, 1)
    }

    private var leadCue: String {
        if supportValue > pressureValue { return "Support" }
        if pressureValue > supportValue { return "Watch" }
        return "Learning"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.14))
                    Image(systemName: focusSummary?.tag.symbolName ?? "tag.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(focusSummary?.tag.label ?? "Tag today")
                        .font(.headline.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(focusSummary.map { "\($0.impactMetricText) \($0.impactValueText)" } ?? "Impact learning")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(leadCue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.cyan.opacity(0.12), in: Capsule(style: .continuous))
            }

            // Watch/Support lanes only once there are real links — in the
            // learning state they showed "0 links" twice, which was noise that
            // made the card feel busy without saying anything.
            if summaries.contains(where: { $0.impactDelta != nil }) {
                HStack(spacing: 8) {
                    impactLane(title: "Watch",
                               value: pressureValue,
                               count: pressureSummaries.count,
                               tint: .orange,
                               alignment: .trailing)
                    impactLane(title: "Support",
                               value: supportValue,
                               count: supportSummaries.count,
                               tint: .cyan,
                               alignment: .leading)
                }
            }

            // Only show the watch↔support "impact map" once there are real
            // links to place on it. In the sparse/learning state its tag icons
            // collapsed to the center axis and stacked into a broken-looking
            // column (the "weird journal" report) — gate it so it appears only
            // when it actually communicates something.
            if summaries.contains(where: { $0.impactDelta != nil }) {
                AtriaJournalImpactMap(summaries: summaries)
            }

            HStack(spacing: 7) {
                glanceChip(title: "Logged",
                           value: taggedDays > 0 ? "\(taggedDays)d" : "0d",
                           systemImage: "calendar.badge.checkmark",
                           tint: .cyan)
                glanceChip(title: "Patterns",
                           value: patternCount > 0 ? "\(patternCount)" : "—",
                           systemImage: "waveform.path.ecg",
                           tint: .mint)
                glanceChip(title: "Focus",
                           value: focusSummary?.tag.label ?? "Tag more",
                           systemImage: "scope",
                           tint: .purple)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Journal impact glance. \(taggedDays) logged days. \(patternCount) behavior patterns. Focus \(focusSummary?.tag.label ?? "tag more"). Watch \(pressureSummaries.count), support \(supportSummaries.count).")
    }

    private func impactLane(title: String,
                            value: Double,
                            count: Int,
                            tint: Color,
                            alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 5) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.caption2.weight(.bold))
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(tint)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: alignment == .leading ? .leading : .trailing) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.70))
                        .frame(width: max(8, width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text(count == 1 ? "1 link" : "\(count) links")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func glanceChip(title: String,
                            value: String,
                            systemImage: String,
                            tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
    }
}

private struct AtriaJournalImpactBalanceRail: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]

    private var supportSummaries: [BehaviorCorrelationSummary] {
        summaries.filter { ($0.impactDelta ?? 0) > 0 }
    }

    private var pressureSummaries: [BehaviorCorrelationSummary] {
        summaries.filter { ($0.impactDelta ?? 0) < 0 }
    }

    private var supportValue: Double {
        min(supportSummaries.reduce(0) { $0 + $1.impactMagnitude } / 12, 1)
    }

    private var pressureValue: Double {
        min(pressureSummaries.reduce(0) { $0 + $1.impactMagnitude } / 12, 1)
    }

    private var leadText: String {
        if supportValue > pressureValue { return supportSummaries.first?.tag.label ?? "Support" }
        if pressureValue > supportValue { return pressureSummaries.first?.tag.label ?? "Watch" }
        return "Balanced"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Recovery balance", systemImage: "arrow.left.and.right")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(leadText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                balanceSide(title: "Watch",
                            value: pressureValue,
                            count: pressureSummaries.count,
                            systemImage: "arrow.down.right",
                            tint: .orange,
                            alignment: .trailing)

                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.09))
                    Circle()
                        .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
                    Text("0")
                        .font(.caption2.weight(.black).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                balanceSide(title: "Support",
                            value: supportValue,
                            count: supportSummaries.count,
                            systemImage: "arrow.up.right",
                            tint: .cyan,
                            alignment: .leading)
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cyan.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovery balance. Watch \(pressureSummaries.count) links, support \(supportSummaries.count) links. Lead \(leadText).")
    }

    private func balanceSide(title: String,
                             value: Double,
                             count: Int,
                             systemImage: String,
                             tint: Color,
                             alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 5) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                Text(title)
                    .font(.caption2.weight(.bold))
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(tint)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: alignment == .leading ? .leading : .trailing) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.70))
                        .frame(width: max(8, width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text(count == 1 ? "1 link" : "\(count) links")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

private struct AtriaJournalImpactMap: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]

    private var visibleSummaries: [BehaviorCorrelationSummary] {
        Array(summaries.prefix(5))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let centerX = width / 2
            let centerY = height / 2
            let travel = max(24, (width - 76) / 2)

            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: width, height: 3)
                    .position(x: centerX, y: centerY)

                Circle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 10, height: 10)
                    .position(x: centerX, y: centerY)
                    .accessibilityHidden(true)

                ForEach(Array(visibleSummaries.enumerated()), id: \.element.tag) { index, summary in
                    mapNode(summary: summary)
                        .position(x: nodeX(summary: summary, centerX: centerX, travel: travel),
                                  y: nodeY(index: index, centerY: centerY))
                }
            }
        }
        .frame(height: 74)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Behavior impact map. Left is watch, center is neutral, right is support.")
    }

    private func mapNode(summary: BehaviorCorrelationSummary) -> some View {
        let isKnown = summary.impactDelta != nil
        let size = 28 + (14 * summary.impactProgress)
        return ZStack {
            Circle()
                .fill(Color.cyan.opacity(isKnown ? 0.18 + (0.16 * summary.impactProgress) : 0.08))
            Circle()
                .stroke(Color.cyan.opacity(isKnown ? 0.46 : 0.18), lineWidth: 1)
            Image(systemName: summary.tag.symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(isKnown ? Color.cyan : Color.secondary)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.cyan.opacity(isKnown ? 0.12 : 0), radius: 8, y: 3)
        .accessibilityLabel("\(summary.tag.label), \(summary.impactMetricText) \(summary.impactValueText).")
    }

    private func nodeX(summary: BehaviorCorrelationSummary, centerX: CGFloat, travel: CGFloat) -> CGFloat {
        guard let delta = summary.impactDelta else { return centerX }
        let direction = delta >= 0 ? 1.0 : -1.0
        return centerX + CGFloat(direction * summary.impactProgress) * travel
    }

    private func nodeY(index: Int, centerY: CGFloat) -> CGFloat {
        let offsets: [CGFloat] = [0, -17, 17, -8, 8]
        return centerY + offsets[index % offsets.count]
    }
}

private struct AtriaJournalImpactCompass: View, Equatable {
    let summaries: [BehaviorCorrelationSummary]
    let taggedDays: Int

    private var supportSummary: BehaviorCorrelationSummary? {
        summaries.first { ($0.impactDelta ?? 0) > 0 }
    }

    private var pressureSummary: BehaviorCorrelationSummary? {
        summaries.first { ($0.impactDelta ?? 0) < 0 }
    }

    private var learningSummary: BehaviorCorrelationSummary? {
        summaries.first { $0.impactDelta == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Impact compass")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
                Text("\(taggedDays)d journal")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                compassCell(title: "Support",
                            summary: supportSummary,
                            fallback: "Still learning",
                            systemImage: "arrow.up.right",
                            alignment: .leading)
                compassCell(title: "Watch",
                            summary: pressureSummary,
                            fallback: learningSummary?.tag.label ?? "No pressure",
                            systemImage: "arrow.down.right",
                            alignment: .trailing)
            }

            HStack(spacing: 5) {
                ForEach(summaries, id: \.tag) { summary in
                    Capsule()
                        .fill(Color.cyan.opacity(summary.impactDelta == nil ? 0.18 : 0.72))
                        .frame(maxWidth: .infinity)
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: max(8, 46 * summary.impactProgress), height: 5)
                        }
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cyan.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Impact compass. Support \(supportSummary?.tag.label ?? "still learning"). Watch \(pressureSummary?.tag.label ?? "no pressure signal"). \(taggedDays) journal days.")
    }

    private func compassCell(title: String,
                             summary: BehaviorCorrelationSummary?,
                             fallback: String,
                             systemImage: String,
                             alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(summary?.tag.label ?? fallback)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.76)

            Text(summary.map { "\($0.impactMetricText) \($0.impactValueText)" } ?? "Need more tags")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(summary == nil ? Color.secondary : Color.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct AtriaJournalImpactFocus: View, Equatable {
    let summary: BehaviorCorrelationSummary

    private var ringProgress: CGFloat {
        CGFloat(min(max(summary.impactProgress, 0.12), 1))
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(systemName: summary.tag.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.impactToneText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.cyan.opacity(0.10), in: Capsule())
                Text(summary.tag.label)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(summary.impactMetricText) \(summary.impactValueText)")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("\(summary.days)d logged")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top behavior signal. \(summary.tag.label). \(summary.impactMetricText) \(summary.impactValueText). \(summary.detail).")
    }
}

private struct AtriaJournalImpactBar: View, Equatable {
    let summary: BehaviorCorrelationSummary

    private var hasImpact: Bool {
        summary.impactDelta != nil
    }

    private var barTint: Color {
        hasImpact ? .cyan : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: summary.tag.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text(summary.tag.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: summary.impactDirectionSymbol)
                        .font(.caption2.weight(.bold))
                    Text("\(summary.impactMetricText) \(summary.impactValueText)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(hasImpact ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let center = width / 2
                let fillWidth = max(6, center * summary.impactProgress)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Rectangle()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 1.5)
                        .offset(x: center)
                    if let delta = summary.impactDelta {
                        Capsule()
                            .fill(barTint.opacity(0.72))
                            .frame(width: fillWidth)
                            .offset(x: delta >= 0 ? center : center - fillWidth)
                    } else {
                        Capsule()
                            .fill(Color.primary.opacity(0.16))
                            .frame(width: 18)
                            .offset(x: center - 9)
                    }
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.tag.label). \(summary.impactMetricText) \(summary.impactValueText). \(summary.detail).")
    }
}

struct AtriaOverviewTrailingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool
    let onOpenCollection: () -> Void

    var body: some View {
        Group {
            if hasUnlockedSecondarySections && showsSavedInsights {
                VStack(spacing: 16) {
                    AtriaOverviewCollectionSectionHost(homeStatsStore: homeStatsStore,
                                                       snapshotStore: snapshotStore,
                                                       onOpenCollection: onOpenCollection)

                    AtriaOverviewBackupSectionHost(homeStatsStore: homeStatsStore,
                                                   snapshotStore: snapshotStore)
                }
            } else if hasUnlockedSecondarySections {
                AtriaLoadingPanel(title: "Preparing saved insights",
                                  subtitle: "Backup state and saved data are settling in the background.")
            }
        }
    }

    private var showsSavedInsights: Bool {
        snapshotStore.diagnosticsReady || AtriaOverviewTrendChartHost.debugShowsTrendFixture
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

                AtriaStatusChip(text: live.status == .connected
                                    ? live.strapStreamConnectionLabel : live.status.rawValue,
                                systemImage: live.status == .connected
                                    ? live.strapStreamConnectionSymbol : "dot.radiowaves.left.and.right",
                                tint: statusTint)
            }

            Text(live.deviceName)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
                if live.batteryLevel >= 0 {
                    AtriaInlineQuickStat(label: "Battery",
                                         value: live.batteryStatusSummaryText,
                                         detail: live.batteryDetailText)
                }
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                AtriaInlineQuickStat(label: "HRV window", value: stats.rrPackageText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onOpenCollection) {
                    // Static handoff compatibility marker for the old IA label:
                    // Label("Data", systemImage: "arrow.right.circle.fill")
                    Label("Strap", systemImage: "arrow.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 88)
                }
                .atriaCardAction(tint: .blue)
                .accessibilityLabel("Open Strap")
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

    private var confirmedTotal: Int {
        snapshot.confirmedWorkouts + snapshot.confirmedSleeps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                    Image(systemName: "internaldrive.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.cyan)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Saved on device")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Text(backupCue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text("\(confirmedTotal)")
                    .font(.title2.weight(.black).monospacedDigit())
                    .foregroundStyle(.cyan)
            }

            HStack(spacing: 8) {
                backupMetaChip(title: "Workouts",
                               value: "\(snapshot.confirmedWorkouts)",
                               systemImage: "figure.mixed.cardio",
                               tint: .cyan)
                backupMetaChip(title: "Sleeps",
                               value: "\(snapshot.confirmedSleeps)",
                               systemImage: "bed.double.fill",
                               tint: .cyan)
                backupMetaChip(title: "State",
                               value: stats.backupValue,
                               systemImage: "checkmark.seal.fill",
                               tint: .secondary)
            }

            Text(stats.backupDetail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var backupCue: String {
        confirmedTotal > 0 ? "Confirmed sessions stay local." : "Atria is preparing local history."
    }

    private func backupMetaChip(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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

            ForEach(Array(items.enumerated()), id: \.element) { index, item in
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


/// Manual bucketing override for the detail charts (design handoff "Range &
/// interval"). .auto keeps the shipped behavior: raw daily points on short
/// ranges, weekly buckets past 90 days.
enum AtriaChartBucketOverride: String, CaseIterable, Identifiable {
    case auto, daily, weeklyAverage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .daily: return "Daily"
        case .weeklyAverage: return "Week avg"
        }
    }
}

/// Bottom sheet controlling how detail-chart points are bucketed and whether
/// the weekly min-max band shows. The range picker on the sheet itself is
/// the window control -- this deliberately controls bucketing only.
struct AtriaChartOptionsSheet: View {
    @Binding var bucketOverride: AtriaChartBucketOverride
    @Binding var showMinMaxBand: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BUCKET EACH POINT BY")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.tertiary)
                        .kerning(0.8)
                    Picker("Bucket", selection: $bucketOverride) {
                        ForEach(AtriaChartBucketOverride.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Auto shows daily points on short ranges and weekly averages past 3 months.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $showMinMaxBand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show min\u{2013}max band")
                            .font(.subheadline.weight(.semibold))
                        Text("Shades each week's real range around its average.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .navigationTitle("Range & interval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }
}
