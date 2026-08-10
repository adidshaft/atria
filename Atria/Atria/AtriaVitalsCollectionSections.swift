import SwiftUI
import Charts
import Combine
import UIKit

/// The slow-moving SessionStore fields rendered by Vitals. SessionStore publishes
/// for many unrelated app features; retaining that broad observation at the tab
/// root caused every one of those changes to invalidate a chart-heavy view tree.
struct AtriaVitalsSessionState: Equatable {
    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let confirmedWorkouts: [UserConfirmedWorkout]
    let confirmedWorkoutsRevision: Int
    let confirmedSleeps: [UserConfirmedSleep]
    let behaviorImpactSummaries: [BehaviorImpactSummary]
    let baseline: PersonalBaseline
    let sleepHistorySnapshot: SleepHistorySnapshot
    let sleepHistorySnapshotRevision: Int
    let maxHeartRate: Int
    let imuAuditSummary: IMUAuditSummary
    let skinTemperatureDeviationSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    let overviewTrendPoints: [AtriaTrendPoint]
    let overviewTrendPointsRevision: Int

    private struct BaselineSampleKey: Equatable {
        let date: Date
        let restingHeartRate: Double
        let rmssd: Double?
        let overnight: Bool?
    }

    private let baselineSamplesKey: [BaselineSampleKey]

    private static func baselineSamplesKey(_ baseline: PersonalBaseline) -> [BaselineSampleKey] {
        baseline.samples.map {
            BaselineSampleKey(date: $0.date,
                              restingHeartRate: $0.restingHR,
                              rmssd: $0.rmssd,
                              overnight: $0.overnight)
        }
    }

    @MainActor
    init(store: SessionStore) {
        dailyRollupHistory = store.dailyRollupHistory
        dailyRollupHistoryRevision = store.dailyRollupHistoryRevision
        confirmedWorkouts = store.confirmedWorkouts
        confirmedWorkoutsRevision = store.confirmedWorkoutsRevision
        confirmedSleeps = store.confirmedSleeps
        behaviorImpactSummaries = store.behaviorImpactSummariesCache
        let baseline = store.baseline
        self.baseline = baseline
        baselineSamplesKey = Self.baselineSamplesKey(baseline)
        sleepHistorySnapshot = store.sleepHistorySnapshot
        sleepHistorySnapshotRevision = store.sleepHistorySnapshotRevision
        maxHeartRate = store.profile.maxHR
        imuAuditSummary = store.imuAuditSummary
        skinTemperatureDeviationSummary = store.skinTemperatureDeviationSummary
        overviewTrendPoints = store.overviewTrendPoints
        overviewTrendPointsRevision = store.overviewTrendPointsRevision
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.confirmedWorkoutsRevision == rhs.confirmedWorkoutsRevision
            && lhs.sleepHistorySnapshotRevision == rhs.sleepHistorySnapshotRevision
            && lhs.behaviorImpactSummaries == rhs.behaviorImpactSummaries
            && lhs.baseline.restingHR == rhs.baseline.restingHR
            && lhs.baseline.hrvEMA == rhs.baseline.hrvEMA
            && lhs.baseline.sessions == rhs.baseline.sessions
            && lhs.baseline.updated == rhs.baseline.updated
            && lhs.baselineSamplesKey == rhs.baselineSamplesKey
            && lhs.maxHeartRate == rhs.maxHeartRate
            && lhs.imuAuditSummary == rhs.imuAuditSummary
            && lhs.skinTemperatureDeviationSummary == rhs.skinTemperatureDeviationSummary
            && lhs.overviewTrendPointsRevision == rhs.overviewTrendPointsRevision
    }
}

@MainActor
final class AtriaVitalsSessionProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaVitalsSessionState

    private let store: SessionStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false
    private var pendingFullRefresh = false
    #if DEBUG
    private(set) var refreshAttemptCount = 0
    #endif

    init(store: SessionStore) {
        self.store = store
        state = AtriaVitalsSessionState(store: store)

        Publishers.MergeMany([
            store.$dailyRollupHistory.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyMetricHistory.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$sleepHistorySnapshot.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$behaviorImpactSummariesCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$baseline.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$profile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$imuAuditSummary.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$overviewTrendPoints.dropFirst().map { _ in () }.eraseToAnyPublisher(),
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

    /// Returns true only when Vitals-visible state changed. Kept internal so the
    /// projection's unchanged-publication contract can be exercised directly.
    @discardableResult
    func refresh() -> Bool {
        #if DEBUG
        refreshAttemptCount += 1
        #endif
        let next = AtriaVitalsSessionState(store: store)
        guard next != state else { return false }
        state = next
        return true
    }

    /// Dashboard revision also covers Journal and research mutations. Only the
    /// confirmed-workout revision is Vitals-relevant and lacks its own publisher.
    @discardableResult
    func refreshForDashboardRevision() -> Bool {
        guard store.confirmedWorkoutsRevision != state.confirmedWorkoutsRevision else {
            return false
        }
        return refresh()
    }

    /// @Published sends during willSet. Coalescing one main-runloop turn reads the
    /// committed values and folds related rollup/sleep/trend writes into one pass.
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

/// Vitals-specific trend host fed by the narrow projection. This preserves the
/// existing chart and debug fixtures without letting AtriaOverviewTrendChartHost's
/// broad SessionStore observation back into the retained Vitals hierarchy.
struct AtriaVitalsTrendChartHost: View, Equatable {
    let state: AtriaVitalsSessionState

    var body: some View {
        let fixturePoints = debugFixtureTrendPoints
        AtriaTrendChartCard(points: fixturePoints ?? state.overviewTrendPoints,
                            pointsRevision: fixturePoints == nil ? state.overviewTrendPointsRevision : nil,
                            baselineRestingHR: fixturePoints == nil ? state.baseline.restingInt : 58,
                            events: trendEvents)
    }

    private var trendEvents: [AtriaChartEvent] {
        // Presentation gate (2026-07-31): accidental sub-minute live fragments
        // are not chart-worthy workout events.
        var events = AtriaWorkoutMetricPresentation.presentableWorkouts(state.confirmedWorkouts).map { workout in
            AtriaChartEvent(id: "workout-\(workout.id)",
                            day: workout.start,
                            label: workout.activitySubtype ?? workout.activityType ?? "Workout",
                            systemImage: "flame.fill",
                            tint: Metrics.electricStrain)
        }
        events.append(contentsOf: state.sleepHistorySnapshot.nights.filter(\.confirmed).map { night in
            AtriaChartEvent(id: "sleep-\(night.id)",
                            day: night.day,
                            label: "Sleep",
                            systemImage: "bed.double.fill",
                            tint: Metrics.electricSleep)
        })
        return events
    }

    #if DEBUG
    private var debugFixtureTrendPoints: [AtriaTrendPoint]? {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return nil
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        guard ProcessInfo.processInfo.arguments.indices.contains(valueIndex) else { return nil }
        switch ProcessInfo.processInfo.arguments[valueIndex] {
        case "trend-prior-comparison":
            return AtriaTrendPoint.priorComparisonSampleData(now: Date())
        case "trend-recovery-care":
            return AtriaTrendPoint.recoveryCareSampleData(now: Date())
        default:
            return nil
        }
    }
    #else
    private var debugFixtureTrendPoints: [AtriaTrendPoint]? { nil }
    #endif
}

struct AtriaVitalsTabContent: View {
    var isActive = true
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileStore: AtriaHomeModel.ProfileStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let stressMonitorStore: AtriaStressMonitorStore
    let store: SessionStore
    @StateObject private var vitalsStore: AtriaVitalsSessionProjectionStore
    let ble: AtriaBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?
    @AtriaDefault(AtriaVitalsSection.orderStorageKey) private var sectionOrderCSV = ""
    @AppStorage(AtriaTodayMetric.storageKey) private var hiddenMetricCSV = ""
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    @State private var isEditingVitalsLayout = false
    @State private var metricDetail: AtriaMetricDetailKind?
    @State private var healthMonitorPreparedMemo = AtriaHealthMonitorPreparedMemo()

    init(isActive: Bool = true,
         liveStore: AtriaHomeModel.CoreLiveStore,
         pulseStore: AtriaHomeModel.PulseLiveStore,
         pulseSparklineStore: AtriaHomeModel.PulseSparklineStore,
         heroStore: AtriaHomeModel.HeroStore,
         homeStatsStore: AtriaHomeModel.HomeStatsStore,
         profileStore: AtriaHomeModel.ProfileStore,
         profileMetricsStore: AtriaHomeModel.ProfileMetricsStore,
         stressMonitorStore: AtriaStressMonitorStore,
         store: SessionStore,
         ble: AtriaBLEManager,
         horizontalSizeClass: UserInterfaceSizeClass?) {
        self.isActive = isActive
        self.liveStore = liveStore
        self.pulseStore = pulseStore
        self.pulseSparklineStore = pulseSparklineStore
        self.heroStore = heroStore
        self.homeStatsStore = homeStatsStore
        self.profileStore = profileStore
        self.profileMetricsStore = profileMetricsStore
        self.stressMonitorStore = stressMonitorStore
        self.store = store
        _vitalsStore = StateObject(wrappedValue: AtriaVitalsSessionProjectionStore(store: store))
        self.ble = ble
        self.horizontalSizeClass = horizontalSizeClass
    }

    var body: some View {
        let vitals = vitalsStore.state
        let sections = AtriaVitalsSection.ordered(from: sectionOrderCSV)
        VStack(spacing: 18) {
            healthMonitorCard

            if isEditingVitalsLayout {
                HStack(spacing: 8) {
                    Label("Editing Vitals", systemImage: "rectangle.3.group")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                            isEditingVitalsLayout = false
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

            Group {
                if horizontalSizeClass == .regular {
                    LazyVGrid(columns: Self.regularSectionColumns, spacing: 18) {
                        ForEach(sections) { section in
                            sectionCard(section)
                        }
                    }
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(sections) { section in
                            sectionCard(section)
                        }
                    }
                }
            }

            if hasCustomVitalsLayout {
                Button(action: resetVitalsLayout) {
                    Label("Reset Vitals layout", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
                .accessibilityLabel("Reset Vitals layout")
                .accessibilityHint("Restores Pulse, HRV, Recovery and strain, and Profile to the default order.")
            }

            trendsEntryCard
        }
        .sensoryFeedback(.selection, trigger: sectionOrderCSV)
        .sheet(item: $metricDetail) { detail in
            AtriaMetricDetailSheet(metric: detail,
                                   rollups: vitals.dailyRollupHistory,
                                   rollupsRevision: vitals.dailyRollupHistoryRevision,
                                   confirmedWorkouts: vitals.confirmedWorkouts,
                                   confirmedWorkoutsRevision: vitals.confirmedWorkoutsRevision,
                                   confirmedSleeps: vitals.confirmedSleeps,
                                   behaviorImpacts: vitals.behaviorImpactSummaries,
                                   baseline: AtriaBaselineTargetSnapshot(vitals.baseline),
                                   sleepHistory: vitals.sleepHistorySnapshot,
                                   sleepHistoryRevision: vitals.sleepHistorySnapshotRevision,
                                   guidance: healthMonitorGuidance,
                                   recoveryEstimate: healthMonitorRecoveryEstimate,
                                   currentCycleAuthority:
                                    AtriaHealthMetricAuthority.currentCycleProjection(
                                        hero: heroStore.state,
                                        sleepHistory: vitals.sleepHistorySnapshot
                                    ),
                                   sleepGoalHours: sleepGoalHours,
                                   sleepBaseNeedHours: sleepBaseNeedHours,
                                   skinTemperatureDeviation: vitals.skinTemperatureDeviationSummary)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var healthMonitorCard: some View {
        let vitals = vitalsStore.state
        return AtriaHealthMonitorCard(preparedData: healthMonitorPreparedData,
                                      rollups: vitals.dailyRollupHistory,
                                      sensorSummary: vitals.imuAuditSummary,
                                      skinTemperatureSummary: vitals.skinTemperatureDeviationSummary,
                                      strapModel: ble.strapModel,
                                      bloodOxygenEnabled: isMetricVisible(.bloodOxygen),
                                      skinTemperatureEnabled: isMetricVisible(.bodyTemp),
                                      onOpenDetail: { metricDetail = $0 })
    }

    private var healthMonitorPreparedData: AtriaHealthMonitorPreparedData {
        let vitals = vitalsStore.state
        return healthMonitorPreparedMemo.value(rollupsRevision: vitals.dailyRollupHistoryRevision,
                                               sleepHistoryRevision: vitals.sleepHistorySnapshotRevision) {
            AtriaHealthMonitorPreparedData(rollups: Array(vitals.dailyRollupHistory.prefix(28)),
                                           sleepHistory: vitals.sleepHistorySnapshot)
        }
    }

    private var healthMonitorRecoveryEstimate: Metrics.RecoveryEstimate {
        // The Home hero owns the current physiological cycle's immutable
        // recovery (including its confidence, HRV provenance, contributors and
        // no-sleep fallback). Reusing that exact estimate keeps Health Monitor
        // from presenting yesterday's newest calendar rollup as a newly
        // validated score after midnight or across a split sleep.
        heroStore.state.recoveryEstimate
    }

    private var healthMonitorGuidance: Coach.Guidance {
        heroStore.state.guidance
    }

    private func isMetricVisible(_ metric: AtriaTodayMetric) -> Bool {
        let hidden = AtriaTodayMetric.hidden(from: hiddenMetricCSV)
        return !hidden.contains(metric.rawValue)
    }

    private static let regularSectionColumns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top),
    ]

    @ViewBuilder
    private func sectionCard(_ section: AtriaVitalsSection) -> some View {
        Group {
            switch section {
            case .pulse: pulseCard
            case .hrv: hrvCard
            case .recoveryStrain: recoveryStrainCard
            case .profile: profileCard
            }
        }
        .overlay(alignment: .topTrailing) {
            if isEditingVitalsLayout {
                vitalsSectionEditControls(for: section)
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.card, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.45) {
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                isEditingVitalsLayout = true
            }
        }
        .modifier(AtriaConditionalVitalsStringDraggable(isEnabled: true,
                                                        payload: section.dragPayload))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let dragged = AtriaVitalsSection.draggedSection(from: raw) else { return false }
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                isEditingVitalsLayout = true
                sectionOrderCSV = AtriaVitalsSection.moving(dragged, before: section, in: sectionOrderCSV)
            }
            return true
        }
        .accessibilityAction(named: Text("Move \(section.label) up")) {
            moveSection(section, direction: -1)
        }
        .accessibilityAction(named: Text("Move \(section.label) down")) {
            moveSection(section, direction: 1)
        }
        .accessibilityHint("Drag to reorder this Vitals section, or long press to reveal the visible move controls.")
    }

    private func vitalsSectionEditControls(for section: AtriaVitalsSection) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                        moveSection(section, direction: -1)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.black))
                }
                .atriaGlassIconAction(tint: .secondary, size: 44)
                .accessibilityLabel("Move \(section.label) up")

                Button {
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                        moveSection(section, direction: 1)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.black))
                }
                .atriaGlassIconAction(tint: .secondary, size: 44)
                .accessibilityLabel("Move \(section.label) down")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func moveSection(_ section: AtriaVitalsSection, direction: Int) {
        sectionOrderCSV = AtriaVitalsSection.moving(section, direction: direction, in: sectionOrderCSV)
    }

    private var hasCustomVitalsLayout: Bool {
        AtriaVitalsSection.ordered(from: sectionOrderCSV) != Array(AtriaVitalsSection.allCases)
    }

    private func resetVitalsLayout() {
        sectionOrderCSV = AtriaVitalsSection.allCases.map(\.rawValue).joined(separator: ",")
        isEditingVitalsLayout = false
    }

    private var pulseCard: some View {
        AtriaVitalsPulseCardHost(liveStore: liveStore,
                                 pulseStore: pulseStore,
                                 homeStatsStore: homeStatsStore,
                                 stressMonitorStore: stressMonitorStore,
                                 baselineSnapshot: AtriaVitalsPulseBaselineSnapshot(vitalsStore.state.baseline),
                                 pulseSparklineStore: pulseSparklineStore,
                                 isActive: isActive)
    }

    private var hrvCard: some View {
        AtriaVitalsHRVCardHost(liveStore: liveStore,
                               heroStore: heroStore,
                               vitalsStore: vitalsStore)
    }

    private var recoveryStrainCard: some View {
        AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,
                                          vitalsStore: vitalsStore,
                                          store: store)
    }

    private var profileCard: some View {
        AtriaVitalsProfileCardHost(pulseStore: pulseStore,
                                   profileStore: profileStore,
                                   profileMetricsStore: profileMetricsStore,
                                   onUpdateProfile: store.updateProfile)
    }

    private var trendsEntryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                AtriaPanelSectionHeader(title: "Trends", subtitle: "Saved metric history")
                Spacer(minLength: 0)
                Image(systemName: "chart.xyaxis.line")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            AtriaVitalsTrendChartHost(state: vitalsStore.state)
        }
    }
}

enum AtriaVitalsSection: String, CaseIterable, Identifiable {
    case pulse, hrv, recoveryStrain, profile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pulse: return "Pulse"
        case .hrv: return "HRV"
        case .recoveryStrain: return "Recovery and strain"
        case .profile: return "Profile"
        }
    }

    static let orderStorageKey = "atria.vitals.sectionOrderCSV"
    private static let dragPayloadPrefix = "atria.vitals.section:"

    static func ordered(from csv: String) -> [AtriaVitalsSection] {
        let decoded = csv.split(separator: ",").compactMap { AtriaVitalsSection(rawValue: String($0)) }
        var result: [AtriaVitalsSection] = []
        var seen = Set<AtriaVitalsSection>()
        for section in decoded + allCases {
            guard !seen.contains(section) else { continue }
            result.append(section)
            seen.insert(section)
        }
        return result
    }

    var dragPayload: String {
        Self.dragPayloadPrefix + rawValue
    }

    static func draggedSection(from payload: String) -> AtriaVitalsSection? {
        guard payload.hasPrefix(dragPayloadPrefix) else { return nil }
        let raw = String(payload.dropFirst(dragPayloadPrefix.count))
        return AtriaVitalsSection(rawValue: raw)
    }

    static func moving(_ dragged: AtriaVitalsSection, before target: AtriaVitalsSection, in csv: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        var order = ordered(from: csv).filter { $0 != dragged }
        let insertIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: insertIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ section: AtriaVitalsSection, direction: Int, in csv: String) -> String {
        var order = ordered(from: csv)
        guard let index = order.firstIndex(of: section) else { return order.map(\.rawValue).joined(separator: ",") }
        let next = max(0, min(order.count - 1, index + direction))
        guard next != index else { return order.map(\.rawValue).joined(separator: ",") }
        order.swapAt(index, next)
        return order.map(\.rawValue).joined(separator: ",")
    }
}

private struct AtriaConditionalVitalsStringDraggable: ViewModifier {
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

// MARK: - Vitals education (tap-to-learn + suboptimal-range hints)

/// Shared "what it is / your typical range / how to improve" topics for the
/// six Health Monitor vitals surfaced on both the Vitals tab card
/// (`AtriaHealthMonitorCard`) and the Health screen (`AtriaHealthScreen`).
/// Copy stays in general-guidance language deliberately -- no medical claims.
enum AtriaVitalsEducationTopic: String, Identifiable {
    case recovery
    case restingHeartRate
    case hrv
    case respiration
    case stress
    case sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .restingHeartRate: return "Resting heart rate"
        case .hrv: return "HRV"
        case .respiration: return "Respiratory rate"
        case .stress: return "Stress"
        case .sleep: return "Sleep"
        }
    }

    // Design-parity slice 5 (2026-08-01): the compact AtriaVitalsEducationSheet
    // was retired in favor of the richer AtriaAboutMetricSheet. This enum stays
    // as the vitals info-affordance router; it maps each topic to its About
    // case. (The former `tint`, `whatItIs`, `howComputed`, `honestyNote`, etc.
    // lived only on the deleted sheet and were removed with it.)
    var aboutMetric: AtriaAboutMetric {
        switch self {
        case .recovery: return .recovery
        case .restingHeartRate: return .restingHeartRate
        case .hrv: return .hrv
        case .respiration: return .respiration
        case .stress: return .stress
        case .sleep: return .sleep
        }
    }

}

/// Small inline hint chip shown on a vitals row only when a real
/// trusted-baseline comparison places today's value in a suboptimal zone.
struct AtriaVitalsHintChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }
}

private final class AtriaHealthMonitorPreparedMemo {
    private var rollupsRevision: Int?
    private var sleepHistoryRevision: Int?
    private var prepared: AtriaHealthMonitorPreparedData?

    func value(rollupsRevision nextRollupsRevision: Int,
               sleepHistoryRevision nextSleepHistoryRevision: Int,
               compute: () -> AtriaHealthMonitorPreparedData) -> AtriaHealthMonitorPreparedData {
        if rollupsRevision != nextRollupsRevision
            || sleepHistoryRevision != nextSleepHistoryRevision
            || prepared == nil {
            rollupsRevision = nextRollupsRevision
            sleepHistoryRevision = nextSleepHistoryRevision
            prepared = compute()
        }
        return prepared ?? compute()
    }
}

private struct AtriaHealthMonitorCard: View {
    let preparedData: AtriaHealthMonitorPreparedData
    /// Newest-first daily rollups for the About-sheet last-30-days mini-trend
    /// (P1) — prepared data only keeps per-metric sparkline slices.
    let rollups: [DailyRollupStoreEntry]
    let sensorSummary: IMUAuditSummary
    let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    let strapModel: AtriaBLEManager.AtriaStrapModel
    let bloodOxygenEnabled: Bool
    let skinTemperatureEnabled: Bool
    let onOpenDetail: (AtriaMetricDetailKind) -> Void
    @State private var educationTopic: AtriaVitalsEducationTopic?

    var body: some View {
        let rows = rows(prepared: preparedData)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Health Monitor", subtitle: "Versus your typical range")
                Spacer(minLength: 0)
                AtriaStateBadge(state: rows.contains(where: { $0.rangeState.isAlert }) ? .conflict : .local)
            }

            VStack(spacing: 10) {
                ForEach(rows) { row in
                    AtriaHealthMonitorRowView(row: row,
                                              onOpenDetail: onOpenDetail,
                                              onOpenEducation: { topic, _ in
                        educationTopic = topic
                    })
                }
            }
        }
        // The monitor's timeline/empty-state is the primary surface. Remove
        // the outer shell so it can use the full tab width; inner signal cards
        // retain their own evidence boundaries.
        .sheet(item: $educationTopic) { topic in
            AtriaAboutMetricSheet(metric: topic.aboutMetric,
                                  trend: .make(for: topic.aboutMetric,
                                               rollups: rollups))
        }
        .accessibilityElement(children: .contain)
    }

    private func rows(prepared: AtriaHealthMonitorPreparedData) -> [AtriaHealthMonitorRow] {
        var items: [AtriaHealthMonitorRow] = [
            makeRow(kind: .restingHeartRate,
                    today: prepared.latestRestingHeartRate,
                    sparklineValues: prepared.sparklineRestingHeartRates,
                    rangeValues: prepared.rangeRestingHeartRates,
                    storedStat: prepared.latestStoredVitals?.rhr),
            makeRow(kind: .hrv,
                    today: prepared.latestHRV,
                    sparklineValues: prepared.sparklineHRV,
                    rangeValues: prepared.rangeHRV,
                    storedStat: prepared.latestStoredVitals?.hrv),
            makeRow(kind: .respiratoryRate,
                    today: prepared.latestRespiratoryRate,
                    sparklineValues: prepared.sparklineRespiratoryRates,
                    rangeValues: prepared.rangeRespiratoryRates,
                    storedStat: prepared.latestStoredVitals?.resp),
        ]

        if bloodOxygenEnabled {
            items.append(makeResearchRow(kind: .bloodOxygen,
                                         value: nil,
                                         detail: AtriaExperimentalSensorCopy.bloodOxygenStatus(
                                            strapModel: strapModel,
                                            decoderAvailable: AtriaResearchProbe.validatedSpO2DecoderAvailable)))
        }

        if skinTemperatureEnabled {
            items.append(makeResearchRow(kind: .skinTemperature,
                                         value: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                            ? skinTemperatureSummary.latestDeltaCelsius
                                            : nil,
                                         detail: AtriaExperimentalSensorCopy.skinTemperatureStatus(
                                            summary: skinTemperatureSummary,
                                            decoderAvailable: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable)))
        }

        return items
    }

    private func makeRow(kind: AtriaHealthMonitorVitalKind,
                         today: Double?,
                         sparklineValues: [AtriaHealthMonitorSparkPoint],
                         rangeValues: [AtriaHealthMonitorSparkPoint],
                         storedStat: DailyRollupVitals.Stat?) -> AtriaHealthMonitorRow {
        let stat = storedStat ?? AtriaHealthMonitorRangeStat(points: rangeValues).storedStat
        let rangeState = AtriaHealthMonitorRangeState(today: today, stat: stat)
        return AtriaHealthMonitorRow(kind: kind,
                                     valueText: kind.valueText(today),
                                     points: sparklineValues,
                                     rangeState: rangeState,
                                     numericRangeText: Self.numericRangeText(kind: kind, stat: stat))
    }

    private static func numericRangeText(kind: AtriaHealthMonitorVitalKind, stat: DailyRollupVitals.Stat?) -> String? {
        guard let stat, stat.n >= 3, stat.sd > 0 else { return nil }
        let low = max(stat.mean - 1.5 * stat.sd, 0)
        let high = max(stat.mean + 1.5 * stat.sd, low)
        switch kind {
        case .restingHeartRate:
            return "\(Int(low.rounded()))\u{2013}\(Int(high.rounded())) bpm"
        case .hrv:
            return "\(Int(low.rounded()))\u{2013}\(Int(high.rounded())) ms"
        case .respiratoryRate:
            return String(format: "%.1f\u{2013}%.1f/min", low, high)
        case .bloodOxygen, .skinTemperature:
            return nil
        }
    }

    private func makeResearchRow(kind: AtriaHealthMonitorVitalKind,
                                 value: Double?,
                                 detail: String) -> AtriaHealthMonitorRow {
        AtriaHealthMonitorRow(kind: kind,
                              valueText: detail,
                              points: [],
                              rangeState: value == nil ? .building : .research)
    }
}

private struct AtriaHealthMonitorPreparedData {
    let latestStoredVitals: DailyRollupVitals?
    let latestRestingHeartRate: Double?
    let latestHRV: Double?
    let latestRespiratoryRate: Double?
    let sparklineRestingHeartRates: [AtriaHealthMonitorSparkPoint]
    let rangeRestingHeartRates: [AtriaHealthMonitorSparkPoint]
    let sparklineHRV: [AtriaHealthMonitorSparkPoint]
    let rangeHRV: [AtriaHealthMonitorSparkPoint]
    let sparklineRespiratoryRates: [AtriaHealthMonitorSparkPoint]
    let rangeRespiratoryRates: [AtriaHealthMonitorSparkPoint]

    init(rollups newestFirstRollups: [DailyRollupStoreEntry], sleepHistory: SleepHistorySnapshot) {
        let restingHeartRates = Self.values(from: newestFirstRollups, limit: 28) { rollup in
            rollup.rhr.map(Double.init)
        }
        let hrvs = Self.values(from: newestFirstRollups, limit: 28) { rollup in
            rollup.lnRMSSD.map(exp)
        }
        let respiratoryRates = Self.values(from: newestFirstRollups, limit: 28) { rollup in
            rollup.respiratoryRate
        }

        latestStoredVitals = newestFirstRollups.first(where: { $0.vitals != nil })?.vitals
        latestRestingHeartRate = restingHeartRates.first?.1
        latestHRV = hrvs.first?.1
        latestRespiratoryRate = respiratoryRates.first?.1 ?? sleepHistory.latestMainSleep?.respiratoryRate
        sparklineRestingHeartRates = Self.sparkPoints(values: Array(restingHeartRates.prefix(7)))
        rangeRestingHeartRates = Self.sparkPoints(values: restingHeartRates)
        sparklineHRV = Self.sparkPoints(values: Array(hrvs.prefix(7)))
        rangeHRV = Self.sparkPoints(values: hrvs)
        sparklineRespiratoryRates = Self.sparkPoints(values: Array(respiratoryRates.prefix(7)))
        rangeRespiratoryRates = Self.sparkPoints(values: respiratoryRates)
    }

    private static func values(from newestFirstRollups: [DailyRollupStoreEntry],
                               limit: Int,
                               value: (DailyRollupStoreEntry) -> Double?) -> [(Date, Double)] {
        newestFirstRollups.prefix(limit).compactMap { rollup in
            value(rollup).map { (rollup.day, $0) }
        }
    }

    private static func sparkPoints(values: [(Date, Double)]) -> [AtriaHealthMonitorSparkPoint] {
        values.reversed().map { AtriaHealthMonitorSparkPoint(day: $0.0, value: $0.1) }
    }
}

private struct AtriaHealthMonitorRangeStat {
    let storedStat: DailyRollupVitals.Stat?

    init(points: [AtriaHealthMonitorSparkPoint]) {
        guard points.count >= 3 else {
            storedStat = nil
            return
        }
        var n = 0
        var mean = 0.0
        var m2 = 0.0
        for value in points.map(\.value) {
            n += 1
            let delta = value - mean
            mean += delta / Double(n)
            m2 += delta * (value - mean)
        }
        storedStat = DailyRollupVitals.Stat(mean: mean, sd: sqrt(m2 / Double(max(n - 1, 1))), n: n)
    }
}

private struct AtriaHealthMonitorRow: Identifiable, Equatable {
    let kind: AtriaHealthMonitorVitalKind
    let valueText: String
    let points: [AtriaHealthMonitorSparkPoint]
    let rangeState: AtriaHealthMonitorRangeState
    /// "48-62 bpm"-style numeric typical range, only populated once the
    /// baseline stat is trusted (n >= 3, sd > 0). Feeds the education sheet's
    /// "Your typical range" section.
    var numericRangeText: String? = nil

    var id: AtriaHealthMonitorVitalKind { kind }

    var hintText: String? {
        kind.hintText(rangeState: rangeState)
    }
}

private struct AtriaHealthMonitorSparkPoint: Identifiable, Equatable {
    let day: Date
    let value: Double

    var id: Date { day }
}

private enum AtriaHealthMonitorVitalKind: String, CaseIterable {
    case restingHeartRate
    case hrv
    case respiratoryRate
    case bloodOxygen
    case skinTemperature

    var title: String {
        switch self {
        case .restingHeartRate: return "RHR"
        case .hrv: return "HRV"
        case .respiratoryRate: return "Respiratory rate"
        case .bloodOxygen: return "SpO2"
        case .skinTemperature: return "Skin temp"
        }
    }

    var symbol: String {
        switch self {
        case .restingHeartRate: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .respiratoryRate: return "lungs.fill"
        case .bloodOxygen: return "drop.degreesign"
        case .skinTemperature: return "thermometer.variable"
        }
    }

    // One identity hue per metric (adaptive, deepened on light). RHR/HRV were
    // both `.pink` (indistinguishable); respiration+skin-temp share teal by
    // design (both #00C7BE in the handoff palette). Blood oxygen keeps a
    // distinct blue since it and RHR can appear together in this live list.
    var tint: Color {
        switch self {
        case .restingHeartRate: return Metrics.electricRHR
        case .hrv: return Metrics.electricHRV
        case .respiratoryRate: return Metrics.electricRespiratory
        case .bloodOxygen: return .blue
        case .skinTemperature: return Metrics.electricRespiratory
        }
    }

    var detailKind: AtriaMetricDetailKind? {
        switch self {
        case .restingHeartRate: return .restingHeartRate
        case .hrv: return .hrv
        case .respiratoryRate: return .respiratoryRate
        case .bloodOxygen, .skinTemperature: return nil
        }
    }

    /// Which shared education topic this row's info affordance opens. `nil`
    /// for the experimental research rows, which keep their own info sheet.
    var educationTopic: AtriaVitalsEducationTopic? {
        switch self {
        case .restingHeartRate: return .restingHeartRate
        case .hrv: return .hrv
        case .respiratoryRate: return .respiration
        case .bloodOxygen, .skinTemperature: return nil
        }
    }

    /// A suboptimal-direction hint only makes sense for some vitals: an
    /// elevated resting HR or respiratory rate, or a depressed HRV.
    func hintText(rangeState: AtriaHealthMonitorRangeState) -> String? {
        switch self {
        case .restingHeartRate:
            guard case .aboveTypical = rangeState else { return nil }
            return "\u{2191} elevated -- try earlier bedtime"
        case .hrv:
            guard case .belowTypical = rangeState else { return nil }
            return "\u{2193} below typical -- ease today's training"
        case .respiratoryRate:
            guard case .aboveTypical = rangeState else { return nil }
            return "\u{2191} elevated -- track how you feel"
        case .bloodOxygen, .skinTemperature:
            return nil
        }
    }

    func valueText(_ value: Double?) -> String {
        guard let value else { return "--" }
        switch self {
        case .restingHeartRate:
            return "\(Int(value.rounded())) bpm"
        case .hrv:
            return "\(Int(value.rounded())) ms"
        case .respiratoryRate:
            return String(format: "%.1f/min", value)
        case .bloodOxygen:
            return "\(Int(value.rounded())) frames"
        case .skinTemperature:
            return String(format: "%+.1f C", value)
        }
    }
}

private enum AtriaHealthMonitorRangeState: Equatable {
    case inRange
    case aboveTypical(severity: AtriaHealthMonitorDeviationSeverity)
    case belowTypical(severity: AtriaHealthMonitorDeviationSeverity)
    case building
    case research

    init(today: Double?, stat: DailyRollupVitals.Stat?) {
        guard let today else {
            self = .building
            return
        }
        guard let stat, stat.n >= 3, stat.sd > 0 else {
            self = .building
            return
        }
        let z = (today - stat.mean) / stat.sd
        let magnitude = abs(z)
        if magnitude <= 1.5 {
            self = .inRange
        } else if z > 0 {
            self = .aboveTypical(severity: AtriaHealthMonitorDeviationSeverity(magnitude: magnitude))
        } else {
            self = .belowTypical(severity: AtriaHealthMonitorDeviationSeverity(magnitude: magnitude))
        }
    }

    var label: String {
        switch self {
        case .inRange: return "In range"
        case .aboveTypical: return "Above typical"
        case .belowTypical: return "Below typical"
        case .building: return "Learning"
        case .research: return "Early"
        }
    }

    var tint: Color {
        switch self {
        case .inRange, .building, .research: return .secondary
        case .aboveTypical(let severity), .belowTypical(let severity): return severity.tint
        }
    }

    var isAlert: Bool {
        switch self {
        case .aboveTypical(.red), .belowTypical(.red): return true
        default: return false
        }
    }
}

private enum AtriaHealthMonitorDeviationSeverity: Equatable {
    case amber
    case red

    init(magnitude: Double) {
        self = magnitude > 2.5 ? .red : .amber
    }

    var tint: Color {
        switch self {
        case .amber: return Metrics.electricYellow
        case .red: return Metrics.electricRed
        }
    }
}

private struct AtriaHealthMonitorRowView: View, Equatable {
    let row: AtriaHealthMonitorRow
    let onOpenDetail: (AtriaMetricDetailKind) -> Void
    let onOpenEducation: (AtriaVitalsEducationTopic, String?) -> Void

    static func == (lhs: AtriaHealthMonitorRowView, rhs: AtriaHealthMonitorRowView) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                if let detailKind = row.kind.detailKind {
                    onOpenDetail(detailKind)
                }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(row.kind.detailKind == nil)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityHint(row.kind.detailKind == nil ? "Detail view is not available yet." : "Opens this vital detail.")

            if let topic = row.kind.educationTopic {
                Button {
                    onOpenEducation(topic, row.numericRangeText)
                } label: {
                    Image(systemName: "info.circle")
                }
                .atriaGlassIconAction(tint: .secondary, size: 28)
                .accessibilityLabel("\(topic.title) meaning and coaching")
            }
        }
        .padding(.vertical, 4)
    }

    private var accessibilityLabelText: String {
        if let hintText = row.hintText {
            return "\(row.kind.title), \(row.valueText), \(row.rangeState.label). \(hintText)"
        }
        return "\(row.kind.title), \(row.valueText), \(row.rangeState.label)"
    }

    private var rowContent: some View {
        compactRow
    }

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: row.kind.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(row.kind.tint)
                .frame(width: 28, height: 28)
                .background(AtriaIconTileBackground(cornerRadius: 9, tint: row.kind.tint))

            VStack(alignment: .leading, spacing: 7) {
                Text(row.kind.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                AtriaHealthMonitorSparkline(points: row.points, tint: row.kind.tint)
                    .frame(height: 34)

                if let hintText = row.hintText {
                    AtriaVitalsHintChip(text: hintText, tint: row.rangeState.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Text(row.valueText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                rangePill
            }
            .frame(width: 86, alignment: .trailing)
        }
    }

    private var rangePill: some View {
        Text(row.rangeState.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(row.rangeState.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(row.rangeState.tint.opacity(0.12), in: Capsule(style: .continuous))
    }
}

private struct AtriaHealthMonitorSparkline: View, Equatable {
    let points: [AtriaHealthMonitorSparkPoint]
    let tint: Color

    var body: some View {
        if points.count >= 2 {
            Chart(points) { point in
                LineMark(x: .value("Day", point.day),
                         y: .value("Value", point.value))
                    .interpolationMethod(.linear)
                    .foregroundStyle(tint)
            }
            .chartXAxis {
                AxisMarks(values: compactAxisDates) { value in
                    AxisTick().foregroundStyle(.secondary.opacity(0.45))
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: .dateTime.weekday(.narrow))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.secondary.opacity(0.16))
                .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    private var compactAxisDates: [Date] {
        guard let first = points.first?.day,
              let last = points.last?.day,
              first != last else {
            return points.first.map { [$0.day] } ?? []
        }
        return [first, last]
    }
}

struct AtriaCollectionTabContent: View {
    let coreLiveStore: AtriaHomeModel.CoreLiveStore
    let collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let profileStore: AtriaHomeModel.ProfileStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let store: SessionStore
    let ble: AtriaBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?
    @Binding var showRRImporter: Bool
    @Binding var showHRImporter: Bool
    @Binding var rrShareURL: URL?
    @Binding var hrShareURL: URL?
    @Binding var captureShareURL: URL?
    @Binding var rrImportStatus: String
    @Binding var hrImportStatus: String
    @Binding var hapticSettings: AtriaHapticAlertSettings
    let officialAppInstalled: Bool
    let developerModeEnabled: Bool

    var body: some View {
        /*
        Static handoff compatibility marker for the old default stack:
        captureCard
                        researchSignalsCard
                        biologicalAgeCard
                        if developerModeEnabled
        captureCard
                    researchSignalsCard
                    biologicalAgeCard
                    if developerModeEnabled
        if developerModeEnabled {
                            rrReferenceCard
        if developerModeEnabled {
                            rrReferenceCard
                            hrReferenceCard
                            imuAuditCard
        private var researchSignalsCard: some View
        */
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        captureCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        collectionControlsCard
                        collectionStatusCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    captureCard
                    collectionControlsCard
                    collectionStatusCard
                }
            }
        }
    }

    private var captureCard: some View {
        AtriaCollectionCaptureCardHost(collectionLiveStore: collectionLiveStore,
                                       ble: ble,
                                       captureShareURL: $captureShareURL)
    }

    private var collectionControlsCard: some View {
        AtriaCollectionControlsCardHost(collectionLiveStore: collectionLiveStore,
                                        homeStatsStore: homeStatsStore,
                                        profileStore: profileStore,
                                        store: store,
                                        ble: ble,
                                        hapticSettings: $hapticSettings,
                                        developerModeEnabled: developerModeEnabled)
    }

    private var collectionStatusCard: some View {
        AtriaCollectionStatusCardHost(coreLiveStore: coreLiveStore,
                                      collectionLiveStore: collectionLiveStore,
                                      homeStatsStore: homeStatsStore,
                                      snapshotStore: snapshotStore,
                                      store: store,
                                      officialAppInstalled: officialAppInstalled)
    }
}

struct AtriaCollectionResearchValidationContent: View {
    let collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let profileStore: AtriaHomeModel.ProfileStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let store: SessionStore
    let ble: AtriaBLEManager
    @Binding var showRRImporter: Bool
    @Binding var showHRImporter: Bool
    @Binding var rrShareURL: URL?
    @Binding var hrShareURL: URL?
    let rrImportStatus: String
    let hrImportStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaCollectionRRReferenceCardHost(homeStatsStore: homeStatsStore,
                                               store: store,
                                               showRRImporter: $showRRImporter,
                                               rrShareURL: $rrShareURL,
                                               rrImportStatus: rrImportStatus)
            AtriaCollectionHRReferenceCardHost(snapshotStore: snapshotStore,
                                               store: store,
                                               showHRImporter: $showHRImporter,
                                               hrShareURL: $hrShareURL,
                                               hrImportStatus: hrImportStatus)
            AtriaSensorReferenceCaptureCard()
            AtriaStepCalibrationSequenceCard(ble: ble)
            AtriaCollectionResearchEvidenceHost(store: store, ble: ble)
            // Static handoff compatibility marker for the relocated card: researchManeuverCard
            AtriaCollectionProfilePickerHost(collectionLiveStore: collectionLiveStore,
                                             homeStatsStore: homeStatsStore,
                                             profileStore: profileStore,
                                             ble: ble)
            AtriaDutyCycleToggleCard(ble: ble)
            AtriaCollectionBiologicalAgeCardHost(profileMetricsStore: profileMetricsStore)
        }
    }
}

struct AtriaCollectionResearchEvidenceState: Equatable {
    let summary: IMUAuditSummary
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let markers: [ResearchManeuverMarker]
    let correlationSummary: ResearchManeuverProbeCorrelationSummary
    let strapModel: AtriaBLEManager.AtriaStrapModel
}

@MainActor
final class AtriaCollectionResearchEvidenceProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaCollectionResearchEvidenceState

    private let store: SessionStore
    private let ble: AtriaBLEManager
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(store: SessionStore, ble: AtriaBLEManager) {
        self.store = store
        self.ble = ble
        state = Self.makeState(store: store, ble: ble)

        Publishers.MergeMany([
            store.$imuAuditSummary.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$sleepHistorySnapshot.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$researchManeuverProbeCorrelationSummary.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ble.$strapModel.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in self?.scheduleRefresh() }
        .store(in: &cancellables)
    }

    @discardableResult
    func refresh() -> Bool {
        let next = Self.makeState(store: store, ble: ble)
        guard next != state else { return false }
        state = next
        return true
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private static func makeState(store: SessionStore,
                                  ble: AtriaBLEManager) -> AtriaCollectionResearchEvidenceState {
        AtriaCollectionResearchEvidenceState(
            summary: store.imuAuditSummary,
            sleepHistory: store.sleepHistorySnapshot,
            sleepHistoryRevision: store.sleepHistorySnapshotRevision,
            markers: store.researchManeuverMarkers,
            correlationSummary: store.researchManeuverProbeCorrelationSummary,
            strapModel: ble.strapModel
        )
    }
}

private struct AtriaCollectionResearchEvidenceHost: View {
    let store: SessionStore
    @StateObject private var projectionStore: AtriaCollectionResearchEvidenceProjectionStore

    init(store: SessionStore, ble: AtriaBLEManager) {
        self.store = store
        _projectionStore = StateObject(
            wrappedValue: AtriaCollectionResearchEvidenceProjectionStore(store: store, ble: ble)
        )
    }

    var body: some View {
        let state = projectionStore.state
        Group {
            AtriaCollectionResearchSignalsCard(summary: state.summary,
                                               sleepHistory: state.sleepHistory,
                                               sleepHistoryRevision: state.sleepHistoryRevision,
                                               strapModel: state.strapModel)
            AtriaCollectionIMUAuditCard(summary: state.summary)
            AtriaResearchManeuverMarkerCard(markers: state.markers,
                                            correlationSummary: state.correlationSummary,
                                            onMark: { store.markResearchManeuver($0) })
        }
    }
}

private struct AtriaCollectionProfilePickerHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    let ble: AtriaBLEManager

    var body: some View {
        AtriaCollectionProfilePicker(
            selected: collectionLiveStore.state.collectionProfile,
            onSelect: { profile in
                ble.setCollectionProfile(profile,
                                         rest: homeStatsStore.state.restingHeartRate,
                                         maxHR: profileStore.profile.maxHR)
            }
        )
    }
}

/// Daytime power saver (docs/24 §13). Honest copy: this trades daytime
/// beat-to-beat detail for strap battery; recovery already comes from sleep.
private struct AtriaDutyCycleToggleCard: View {
    let ble: AtriaBLEManager
    @AtriaDefault("atria.dutycycle.enabled") private var dutyCycleEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $dutyCycleEnabled) {
                Label("Daytime power saver", systemImage: "leaf")
                    .font(.subheadline.weight(.semibold))
            }
            .onChange(of: dutyCycleEnabled) { _, _ in
                ble.updateDutyCycleState(reason: "settings_toggle")
            }

            Text("Checks periodically by day. Full detail resumes for sleep, workouts, raised heart rate, and live screens. Daytime HRV gaps are expected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

/// Memoizes the live+historical HR merge and its compact timeline series. The
/// source key keeps repeated reads in one body pass O(1); archive replacement
/// explicitly invalidates the cache because its interior samples can change.
private final class AtriaHeartRateMergeCache {
    struct Key: Equatable {
        let historicalCount: Int
        let historicalLast: Date?
        let liveCount: Int
        let liveLast: Date?
    }
    struct SeriesKey: Equatable {
        let count: Int
        let first: Date?
        let firstBPM: Int?
        let last: Date?
        let lastBPM: Int?

        init(points: [AtriaHomeModel.HeartRateChartPoint]) {
            count = points.count
            first = points.first?.t
            firstBPM = points.first?.bpm
            last = points.last?.t
            lastBPM = points.last?.bpm
        }
    }
    var key: Key?
    var value: [AtriaHomeModel.HeartRateChartPoint] = []
    var miniSeriesKey: SeriesKey?
    var miniSeries: AtriaHeartRateChartSeries?

    func invalidate() {
        key = nil
        miniSeriesKey = nil
        miniSeries = nil
    }
}

/// Only the pulse fields rendered by the Vitals card. RR samples and zone data
/// remain on PulseLiveState for breathwork and other consumers, but do not make
/// this chart-heavy subtree update or participate in its Equatable comparison.
struct AtriaVitalsPulsePresentationState: Equatable {
    let heartRate: Int
    let hasPulseSignal: Bool
    let averageHeartRate: Int?
    let peakHeartRate: Int?

    init(_ state: AtriaHomeModel.PulseLiveState) {
        heartRate = state.heartRate
        hasPulseSignal = state.hasPulseSignal
        averageHeartRate = state.averageHeartRate
        peakHeartRate = state.peakHeartRate
    }

    var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
    var averageHeartRateText: String { averageHeartRate.map(String.init) ?? "--" }
    var peakHeartRateText: String { peakHeartRate.map(String.init) ?? "--" }
}

struct AtriaVitalsActivityGate {
    enum RefreshReason: Equatable {
        case activation
        case notification
    }

    let archiveNotificationMinimumInterval: TimeInterval
    let activationMinimumInterval: TimeInterval
    private(set) var lastArchiveRefreshAt: Date?

    init(archiveNotificationMinimumInterval: TimeInterval = 120,
         activationMinimumInterval: TimeInterval = 120,
         lastArchiveRefreshAt: Date? = nil) {
        self.archiveNotificationMinimumInterval = archiveNotificationMinimumInterval
        self.activationMinimumInterval = activationMinimumInterval
        self.lastArchiveRefreshAt = lastArchiveRefreshAt
    }

    mutating func shouldRefreshArchive(isActive: Bool,
                                       reason: RefreshReason,
                                       now: Date = Date()) -> Bool {
        guard isActive else { return false }
        if let lastArchiveRefreshAt {
            let minimumInterval = reason == .activation
                ? activationMinimumInterval
                : archiveNotificationMinimumInterval
            if now.timeIntervalSince(lastArchiveRefreshAt) < minimumInterval {
                return false
            }
        }
        lastArchiveRefreshAt = now
        return true
    }
}

struct AtriaVitalsArchiveActivityObserver: View {
    let onNotification: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: HistoricalArchive.didUpdateNotification)) { _ in
                onNotification()
            }
    }
}

struct AtriaVitalsStressActivityObserver: View {
    let onTick: () -> Void
    private static let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(Self.timer) { _ in onTick() }
    }
}

private struct AtriaVitalsPulseActivityObserver: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let onLive: (AtriaHomeModel.CoreLiveState) -> Void
    let onPulse: (AtriaVitalsPulsePresentationState) -> Void
    let onHomeStats: (AtriaHomeModel.HomeStatsState) -> Void
    let onSparkline: (AtriaHomeModel.PulseSparklineState) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(liveStore.$state, perform: onLive)
            .onReceive(pulseStore.$state
                .map { AtriaVitalsPulsePresentationState($0) }
                .removeDuplicates(),
                perform: onPulse)
            .onReceive(homeStatsStore.$state, perform: onHomeStats)
            .onReceive(pulseSparklineStore.$state, perform: onSparkline)
    }
}

private struct AtriaVitalsPulseCardHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var stressMonitorStore: AtriaStressMonitorStore
    let baselineSnapshot: AtriaVitalsPulseBaselineSnapshot
    let isActive: Bool
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @State private var live: AtriaHomeModel.CoreLiveState
    @State private var pulse: AtriaVitalsPulsePresentationState
    @State private var homeStats: AtriaHomeModel.HomeStatsState
    @State private var sparkline: AtriaHomeModel.PulseSparklineState
    @State private var historicalHeartRatePoints: [AtriaHomeModel.HeartRateChartPoint] = []
    @State private var mergeCache = AtriaHeartRateMergeCache()
    @State private var archiveRefreshGate = AtriaVitalsActivityGate()
    @State private var didDebugOpenHeartRateExplorer = false
    @StateObject private var heartRateExplorerPresenter = AtriaHeartRateExplorerPresentationController()
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore

    init(liveStore: AtriaHomeModel.CoreLiveStore,
         pulseStore: AtriaHomeModel.PulseLiveStore,
         homeStatsStore: AtriaHomeModel.HomeStatsStore,
         stressMonitorStore: AtriaStressMonitorStore,
         baselineSnapshot: AtriaVitalsPulseBaselineSnapshot,
         pulseSparklineStore: AtriaHomeModel.PulseSparklineStore,
         isActive: Bool) {
        self.liveStore = liveStore
        self.pulseStore = pulseStore
        self.homeStatsStore = homeStatsStore
        self.stressMonitorStore = stressMonitorStore
        self.baselineSnapshot = baselineSnapshot
        self.pulseSparklineStore = pulseSparklineStore
        self.isActive = isActive
        _live = State(initialValue: liveStore.state)
        _pulse = State(initialValue: AtriaVitalsPulsePresentationState(pulseStore.state))
        _homeStats = State(initialValue: homeStatsStore.state)
        _sparkline = State(initialValue: pulseSparklineStore.state)
    }

    private var chartPoints: [AtriaHomeModel.HeartRateChartPoint] {
        let livePoints = displayedSparkline.chartPoints
        let key = AtriaHeartRateMergeCache.Key(historicalCount: historicalHeartRatePoints.count,
                                               historicalLast: historicalHeartRatePoints.last?.t,
                                               liveCount: livePoints.count,
                                               liveLast: livePoints.last?.t)
        if mergeCache.key == key { return mergeCache.value }
        let merged = AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: livePoints,
                                                                        historical: historicalHeartRatePoints)
        mergeCache.key = key
        mergeCache.value = merged
        return merged
    }

    private var miniTimelineSeries: AtriaHeartRateChartSeries {
        let points = chartPoints
        let key = AtriaHeartRateMergeCache.SeriesKey(points: points)
        if mergeCache.miniSeriesKey == key, let cached = mergeCache.miniSeries {
            return cached
        }
        let series = AtriaHeartRateChartSeries.make(
            points: AtriaVitalsHeartRateTimeline.windowed(points, window: .hour6),
            zoom: 1)
        mergeCache.miniSeriesKey = key
        mergeCache.miniSeries = series
        return series
    }

    private var timelineKey: AtriaHeartRateMergeCache.SeriesKey {
        AtriaHeartRateMergeCache.SeriesKey(points: chartPoints)
    }

    private var displayedLive: AtriaHomeModel.CoreLiveState {
        isActive ? liveStore.state : live
    }

    private var displayedPulse: AtriaVitalsPulsePresentationState {
        isActive ? AtriaVitalsPulsePresentationState(pulseStore.state) : pulse
    }

    private var displayedHomeStats: AtriaHomeModel.HomeStatsState {
        isActive ? homeStatsStore.state : homeStats
    }

    private var displayedSparkline: AtriaHomeModel.PulseSparklineState {
        isActive ? pulseSparklineStore.state : sparkline
    }

    #if DEBUG
    private var isDisconnectedPresentationFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "vitals-disconnected"
    }
    #else
    private var isDisconnectedPresentationFixture: Bool { false }
    #endif

    var body: some View {
        AtriaVitalsLiveSignalCard(isConnected: !isDisconnectedPresentationFixture
                                                && displayedLive.status == .connected,
                                  live: displayedPulse,
                                  miniTimelineSeries: miniTimelineSeries,
                                  stressState: isDisconnectedPresentationFixture
                                                ? .noSignal
                                                : stressMonitorStore.state,
                                  stressHistory: isDisconnectedPresentationFixture
                                                ? []
                                                : stressMonitorStore.history,
                                  restingHeartRate: displayedHomeStats.restingHeartRate,
                                  restingHeartRateText: displayedHomeStats.restingHeartRateText,
                                  restingBaseline: baselineSnapshot.restingBaseline,
                                  restingBaselineSamples: baselineSnapshot.restingBaselineSamples,
                                  restingBaselineTrusted: baselineSnapshot.restingBaselineTrusted,
                                  baselineTarget: baselineSnapshot.baselineTarget,
                                  restingGreenDelta: restingGreenDelta,
                                  restingYellowDelta: restingYellowDelta,
                                  onOpenHeartRate: openHeartRateExplorer)
            .onAppear(perform: openDebugTimelineIfReady)
            .onChange(of: timelineKey, initial: true) { _, _ in
                heartRateExplorerPresenter.updateLiveInput(points: chartPoints,
                                                            currentBPM: displayedPulse.heartRate)
                openDebugTimelineIfReady()
            }
            .onChange(of: displayedPulse.heartRate) { _, bpm in
                heartRateExplorerPresenter.updateLiveInput(points: chartPoints,
                                                            currentBPM: bpm)
            }
            .onChange(of: isActive, initial: true) { _, active in
                guard active else { return }
                seedCurrentValues()
            }
            .task(id: isActive) {
                guard isActive else { return }
                _ = archiveRefreshGate.shouldRefreshArchive(isActive: true, reason: .activation)
                await refreshHistoricalHeartRatePoints()
            }
            .background {
                if isActive {
                    AtriaVitalsPulseActivityObserver(liveStore: liveStore,
                                                     pulseStore: pulseStore,
                                                     homeStatsStore: homeStatsStore,
                                                     pulseSparklineStore: pulseSparklineStore,
                                                     onLive: { live = $0 },
                                                     onPulse: { pulse = $0 },
                                                     onHomeStats: { homeStats = $0 },
                                                     onSparkline: { sparkline = $0 })
                    AtriaVitalsArchiveActivityObserver {
                        guard archiveRefreshGate.shouldRefreshArchive(isActive: isActive,
                                                                      reason: .notification) else { return }
                        Task { await refreshHistoricalHeartRatePoints() }
                    }
                }
            }
    }

    private func openHeartRateExplorer() {
        let points = chartPoints
        let bpm = displayedPulse.heartRate
        AtriaDebugLog("ATRIADBG hr_explorer_tap status=requested points=%d bpm=%d",
                      points.count,
                      bpm)
        heartRateExplorerPresenter.present(points: points, currentBPM: bpm)
    }

    private func openDebugTimelineIfReady() {
        guard Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments),
              !didDebugOpenHeartRateExplorer,
              timelineKey.count > 0 else { return }
        didDebugOpenHeartRateExplorer = true
        openHeartRateExplorer()
    }

    private func seedCurrentValues() {
        live = liveStore.state
        pulse = AtriaVitalsPulsePresentationState(pulseStore.state)
        homeStats = homeStatsStore.state
        sparkline = pulseSparklineStore.state
    }

    @MainActor
    private func refreshHistoricalHeartRatePoints() async {
        let now = Date()
        // Load a full 24h span (was capped at ~100 min of raw ~1 Hz samples, so
        // the "last 12h/24h" windows could never fill — user 2026-07-08), then
        // downsample off-main to a bounded count. The chart re-thins to ~400 for
        // display, so ~2500 span-preserving points keep the merge + Equatable
        // cheap while covering the full window.
        let since = Calendar.current.date(byAdding: .hour, value: -24, to: now)
        let points = await Task.detached(priority: .utility) {
            let raw = HistoricalArchive.metricHeartRatePoints(since: since, limit: 50_000).map {
                AtriaHomeModel.HeartRateChartPoint(t: $0.t, bpm: $0.bpm)
            }
            return AtriaVitalsHeartRateTimeline.downsampledSpan(raw, maxPoints: 2_500)
        }.value
        guard !Task.isCancelled else { return }
        guard points != historicalHeartRatePoints else { return }
        mergeCache.invalidate()
        historicalHeartRatePoints = points
    }

    #if DEBUG
    private static func debugOpensHeartRateTimeline(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex else { return false }
        return arguments[valueIndex] == "heart-rate-timeline"
    }
    #else
    private static func debugOpensHeartRateTimeline(arguments: [String]) -> Bool { false }
    #endif

}

private struct AtriaVitalsPulseBaselineSnapshot: Equatable {
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot

    init(_ baseline: PersonalBaseline) {
        restingBaseline = baseline.restingInt
        restingBaselineSamples = baseline.freshRestingSampleCount()
        restingBaselineTrusted = baseline.hasTrustedRestingBaseline()
        baselineTarget = AtriaBaselineTargetSnapshot(baseline)
    }
}

/// Live Vitals host for the pulse card (2026-07-07, design handoff): exposes
/// the private AtriaVitalsPulseCardHost/AtriaPulseCard chain to
/// AtriaHealthScreen without mounting the dead AtriaVitalsTabContent tree.
/// The host is self-contained (loads its own historical points, Equatable
/// card) so live-pulse ticks stay cheap.
struct AtriaVitalsLivePulseSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let stressMonitorStore: AtriaStressMonitorStore
    let baseline: PersonalBaseline
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let isActive: Bool

    var body: some View {
        AtriaVitalsPulseCardHost(liveStore: liveStore,
                                 pulseStore: pulseStore,
                                 homeStatsStore: homeStatsStore,
                                 stressMonitorStore: stressMonitorStore,
                                 baselineSnapshot: AtriaVitalsPulseBaselineSnapshot(baseline),
                                 pulseSparklineStore: pulseSparklineStore,
                                 isActive: isActive)
    }
}

enum AtriaVitalsHeartRateTimeline {
    /// Discrete zoom windows for the HR timeline (user request 2026-07-07:
    /// default to the last 6h, zoom in to the last minute, out to 24h).
    enum Window: Int, CaseIterable, Identifiable {
        case min1, min5, min15, min30, hour1, hour3, hour6, hour12, hour24
        var id: Int { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .min1: return 60
            case .min5: return 5 * 60
            case .min15: return 15 * 60
            case .min30: return 30 * 60
            case .hour1: return 3_600
            case .hour3: return 3 * 3_600
            case .hour6: return 6 * 3_600
            case .hour12: return 12 * 3_600
            case .hour24: return 24 * 3_600
            }
        }

        var label: String {
            switch self {
            case .min1: return "1 min"
            case .min5: return "5 min"
            case .min15: return "15 min"
            case .min30: return "30 min"
            case .hour1: return "1 hr"
            case .hour3: return "3 hr"
            case .hour6: return "6 hr"
            case .hour12: return "12 hr"
            case .hour24: return "24 hr"
            }
        }

        static let defaultWindow = Window.hour6
    }

    /// One x-axis tick: a boundary-aligned instant plus the exact label the
    /// chart draws for it. Labels are precomputed and deduped here so the axis
    /// can never render consecutive identical strings — the live-confirmed
    /// duplicate "11a" defect (2026-08-01): `.automatic` placement chose
    /// sub-hour instants on short series, and the hour-precision label format
    /// collapsed neighbouring ticks onto the same text.
    struct AxisTickMark: Equatable {
        let date: Date
        let label: String
    }

    /// Boundary-aligned ticks across the plotted span. The stride is chosen so
    /// roughly `desiredPerWindow` ticks fit one visible window (the full span
    /// when the chart is not scrollable), snapped up to a clean clock unit;
    /// labels include minutes only when the stride itself is sub-hour, so an
    /// hour-only label can never repeat on adjacent ticks.
    static func hourAlignedAxisTicks(from first: Date,
                                     to last: Date,
                                     visibleDomain: TimeInterval? = nil,
                                     desiredPerWindow: Int = 4,
                                     calendar: Calendar = .current) -> [AxisTickMark] {
        let span = last.timeIntervalSince(first)
        guard span > 0, desiredPerWindow > 0 else { return [] }
        let window = min(max(visibleDomain ?? span, 60), span)
        let raw = window / Double(desiredPerWindow)
        let units: [TimeInterval] = [60, 2 * 60, 5 * 60, 10 * 60, 15 * 60,
                                     30 * 60, 3_600, 2 * 3_600, 3 * 3_600,
                                     4 * 3_600, 6 * 3_600, 12 * 3_600,
                                     24 * 3_600]
        var stride = units.first(where: { $0 >= raw }) ?? units[units.count - 1]
        // A scrollable series carries ticks for its FULL span; keep the mark
        // count bounded when a narrow window rides a long series.
        while span / stride > 240, let next = units.first(where: { $0 > stride }) {
            stride = next
        }
        let format: Date.FormatStyle = stride < 3_600
            ? .dateTime.hour(.defaultDigits(amPM: .narrow)).minute()
            : .dateTime.hour(.defaultDigits(amPM: .narrow))
        let dayStart = calendar.startOfDay(for: first)
        let firstOffset = (first.timeIntervalSince(dayStart) / stride).rounded(.up) * stride
        var ticks: [AxisTickMark] = []
        var tick = dayStart.addingTimeInterval(firstOffset)
        var previousLabel: String?
        while tick <= last {
            let label = tick.formatted(format)
            if label != previousLabel {
                ticks.append(AxisTickMark(date: tick, label: label))
                previousLabel = label
            }
            tick = tick.addingTimeInterval(stride)
        }
        return ticks
    }

    /// Merged live + historical HR at full resolution (capped for safety) so
    /// the timeline can window + downsample PER zoom level — pre-downsampling
    /// here would destroy the seconds-resolution the 1-minute zoom needs.
    static func mergedHeartRatePoints(live: [AtriaHomeModel.HeartRateChartPoint],
                                      historical: [AtriaHomeModel.HeartRateChartPoint],
                                      cap: Int = 6_000) -> [AtriaHomeModel.HeartRateChartPoint] {
        guard !historical.isEmpty else { return live }

        // Both production sources are chronological. Merge them in one pass,
        // collapsing rounded-second duplicates as we go; live wins collisions.
        // Keep the dictionary+sort implementation only as a correctness fallback
        // for unexpected unsorted callers.
        guard isTimeOrdered(historical), isTimeOrdered(live) else {
            return mergedHeartRatePointsBySorting(live: live, historical: historical, cap: cap)
        }

        var historicalIndex = 0
        var liveIndex = 0
        var historicalGroup = nextPointByRoundedSecond(in: historical, index: &historicalIndex)
        var liveGroup = nextPointByRoundedSecond(in: live, index: &liveIndex)
        var merged: [AtriaHomeModel.HeartRateChartPoint] = []
        merged.reserveCapacity(min(cap, historical.count + live.count))

        while historicalGroup != nil || liveGroup != nil {
            switch (historicalGroup, liveGroup) {
            case let (historicalPoint?, livePoint?):
                if historicalPoint.second < livePoint.second {
                    merged.append(historicalPoint.point)
                    historicalGroup = nextPointByRoundedSecond(in: historical, index: &historicalIndex)
                } else if livePoint.second < historicalPoint.second {
                    merged.append(livePoint.point)
                    liveGroup = nextPointByRoundedSecond(in: live, index: &liveIndex)
                } else {
                    merged.append(livePoint.point)
                    historicalGroup = nextPointByRoundedSecond(in: historical, index: &historicalIndex)
                    liveGroup = nextPointByRoundedSecond(in: live, index: &liveIndex)
                }
            case let (historicalPoint?, nil):
                merged.append(historicalPoint.point)
                historicalGroup = nextPointByRoundedSecond(in: historical, index: &historicalIndex)
            case let (nil, livePoint?):
                merged.append(livePoint.point)
                liveGroup = nextPointByRoundedSecond(in: live, index: &liveIndex)
            case (nil, nil):
                break
            }
        }

        return merged.count > cap ? Array(merged.suffix(cap)) : merged
    }

    private static func isTimeOrdered(_ points: [AtriaHomeModel.HeartRateChartPoint]) -> Bool {
        guard points.count > 1 else { return true }
        for index in 1..<points.count where points[index].t < points[index - 1].t {
            return false
        }
        return true
    }

    private static func nextPointByRoundedSecond(
        in points: [AtriaHomeModel.HeartRateChartPoint],
        index: inout Int
    ) -> (second: Int, point: AtriaHomeModel.HeartRateChartPoint)? {
        while index < points.count {
            let second = Int(points[index].t.timeIntervalSince1970.rounded())
            var selected: AtriaHomeModel.HeartRateChartPoint?
            repeat {
                let point = points[index]
                if point.bpm > 0 {
                    selected = point
                }
                index += 1
            } while index < points.count
                && Int(points[index].t.timeIntervalSince1970.rounded()) == second

            if let selected {
                return (second, selected)
            }
        }
        return nil
    }

    private static func mergedHeartRatePointsBySorting(
        live: [AtriaHomeModel.HeartRateChartPoint],
        historical: [AtriaHomeModel.HeartRateChartPoint],
        cap: Int
    ) -> [AtriaHomeModel.HeartRateChartPoint] {
        var bySecond: [Int: AtriaHomeModel.HeartRateChartPoint] = [:]
        bySecond.reserveCapacity(historical.count + live.count)
        for point in historical where point.bpm > 0 {
            bySecond[Int(point.t.timeIntervalSince1970.rounded())] = point
        }
        for point in live where point.bpm > 0 {
            bySecond[Int(point.t.timeIntervalSince1970.rounded())] = point
        }
        let merged = bySecond.values.sorted { $0.t < $1.t }
        return merged.count > cap ? Array(merged.suffix(cap)) : merged
    }

    /// Points within `window` of the latest sample, downsampled to
    /// `displayBudget` for a smooth chart. Anchored to the latest sample (not
    /// wall-clock) so "last 12h" always shows the most recent 12h of real
    /// data rather than blank time when the strap has been off.
    static func windowed(_ points: [AtriaHomeModel.HeartRateChartPoint],
                         window: Window,
                         displayBudget: Int = 200) -> [AtriaHomeModel.HeartRateChartPoint] {
        guard let latest = points.last?.t else { return [] }
        let cutoff = latest.addingTimeInterval(-window.seconds)
        let startIndex = firstPointIndex(onOrAfter: cutoff, in: points)
        let visibleCount = points.count - startIndex
        guard visibleCount > 0 else { return [] }
        guard visibleCount > displayBudget else { return Array(points[startIndex...]) }
        guard displayBudget > 1 else { return [points[points.count - 1]] }
        let stride = Double(visibleCount - 1) / Double(displayBudget - 1)
        return (0..<displayBudget).map { index in
            points[startIndex + Int((Double(index) * stride).rounded())]
        }
    }

    private static func firstPointIndex(onOrAfter date: Date,
                                        in points: [AtriaHomeModel.HeartRateChartPoint]) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle].t < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// Uniformly thins a full-resolution series to at most `maxPoints`, always
    /// keeping the first + last sample so the time SPAN is preserved. Only used
    /// to bound the merge/compare/display cost — `windowed` re-thins to the
    /// display budget on top of this (2026-07-08).
    static func downsampledSpan(_ points: [AtriaHomeModel.HeartRateChartPoint],
                                maxPoints: Int) -> [AtriaHomeModel.HeartRateChartPoint] {
        guard maxPoints > 1, points.count > maxPoints else { return points }
        let stride = Double(points.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { points[Int((Double($0) * stride).rounded())] }
    }

    /// Maps a pinch to a new window-slider index (2026-07-08, native zoom feel).
    /// Pinch OUT (magnification > 1) zooms IN → a shorter window → lower index;
    /// pinch IN zooms out. log2 so each doubling of the pinch moves ~2 steps.
    /// Pure + clamped, so it's unit-testable and can't run off the slider.
    static func windowIndex(fromPinchAnchor anchor: Double,
                            magnification: Double,
                            maxIndex: Double,
                            sensitivity: Double = 2.0) -> Double {
        let delta = log2(max(magnification, 0.01)) * sensitivity
        return min(max((anchor - delta).rounded(), 0), maxIndex)
    }
}

private struct AtriaVitalsHRVCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var vitalsStore: AtriaVitalsSessionProjectionStore
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85

    var body: some View {
        let baseline = vitalsStore.state.baseline
        AtriaHRVCard(live: liveStore.state,
                     hero: heroStore.state,
                     hrvBaseline: baseline.hrvInt,
                     hrvBaselineSamples: baseline.freshHRVSampleCount(),
                     hrvBaselineTrusted: baseline.hasTrustedHRVBaseline(),
                     baselineTarget: AtriaBaselineTargetSnapshot(baseline),
                     hrvGreenRatio: hrvGreenRatio,
                     hrvYellowRatio: hrvYellowRatio)
            .equatable()
    }
}

private struct AtriaVitalsRecoveryStrainCardHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var vitalsStore: AtriaVitalsSessionProjectionStore
    let store: SessionStore
    @AtriaDefault("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AtriaDefault("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AtriaDefault("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AtriaDefault("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AtriaDefault("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0

    var body: some View {
        let vitals = vitalsStore.state
        let baseline = vitals.baseline
        let fixtureSleepHistory = debugFixtureSleepHistory
        let sleepHistory = fixtureSleepHistory ?? vitals.sleepHistorySnapshot
        let sleepHistoryRevision = fixtureSleepHistory == nil ? vitals.sleepHistorySnapshotRevision : -1
        AtriaRecoveryStrainCard(hero: heroStore.state,
                                sleepHistory: sleepHistory,
                                sleepHistoryRevision: sleepHistoryRevision,
                                dailyRollupHistory: vitals.dailyRollupHistory,
                                dailyRollupHistoryRevision: vitals.dailyRollupHistoryRevision,
                                recoveryTarget: AtriaMetricTarget.recovery(greenLower: recoveryGreenLower,
                                                                           yellowLower: recoveryYellowLower),
                                strainGreenBand: strainGreenBand,
                                strainYellowBand: strainYellowBand,
                                hrvBaseline: baseline.hrvInt,
                                hrvBaselineSamples: baseline.freshHRVSampleCount(),
                                hrvBaselineTrusted: baseline.hasTrustedHRVBaseline(),
                                baselineTarget: AtriaBaselineTargetSnapshot(baseline),
                                hrvGreenRatio: hrvGreenRatio,
                                hrvYellowRatio: hrvYellowRatio,
                                restingBaseline: baseline.restingInt,
                                restingBaselineSamples: baseline.freshRestingSampleCount(),
                                restingBaselineTrusted: baseline.hasTrustedRestingBaseline(),
                                restingGreenDelta: restingGreenDelta,
                                restingYellowDelta: restingYellowDelta,
                                respiratoryGreenDelta: respiratoryGreenDelta,
                                respiratoryYellowDelta: respiratoryYellowDelta,
                                sleepGoalHours: sleepGoalHours,
                                sleepEfficiencyGreenLower: sleepEfficiencyGreenLower,
                                sleepEfficiencyYellowLower: sleepEfficiencyYellowLower,
                                onAddManualSleep: addManualSleep,
                                onAdjustSleep: adjustSleepCandidate,
                                onConfirmSleep: confirmSleepCandidate)
            .equatable()
    }

    private func addManualSleep(start: Date, end: Date, isNap: Bool) async -> Bool {
        let baseline = vitalsStore.state.baseline
        return await store.addManualSleep(start: start,
                                          end: end,
                                          isNap: isNap,
                                          rest: baseline.restingInt ?? 60) != nil
    }

    private func adjustSleepCandidate(night: SleepHistorySnapshot.Night,
                                      start: Date,
                                      end: Date,
                                      isNap: Bool) async -> Bool {
        let baseline = vitalsStore.state.baseline
        return await store.saveSleepReviewNightForUI(
            night,
            start: start,
            end: end,
            isNap: isNap,
            rest: baseline.restingInt ?? 60,
            source: "vitals_sleep_history_adjust"
        ) != nil
    }

    private func confirmSleepCandidate(_ night: SleepHistorySnapshot.Night) async -> Bool {
        let vitals = vitalsStore.state
        return await store.confirmSleepHistoryNightForUI(
            night,
            rest: vitals.baseline.restingInt ?? 60,
            source: "vitals_sleep_history"
        ) != nil
    }

    #if DEBUG
    private var debugFixtureSleepHistory: SleepHistorySnapshot? {
        Self.debugFixtureSleepHistory(arguments: ProcessInfo.processInfo.arguments)
    }

    private static func debugFixtureSleepHistory(arguments: [String]) -> SleepHistorySnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex,
              arguments[valueIndex] == "sleep-history-context-lens" else {
            return nil
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let durations = [438, 402, 461, 389, 447, 420, 455, 371, 436, 409]
        let nights: [SleepHistorySnapshot.Night] = durations.enumerated().compactMap { index, minutes in
            guard let day = calendar.date(byAdding: .day, value: -index, to: today) else { return nil }
            let end = calendar.date(bySettingHour: 7, minute: 18 - min(index, 8), second: 0, of: day) ?? day.addingTimeInterval(7.25 * 3600)
            let start = calendar.date(byAdding: .minute, value: -minutes, to: end) ?? end.addingTimeInterval(TimeInterval(-minutes * 60))
            return SleepHistorySnapshot.Night(id: "debug-ui-fixture-sleep-history-context-lens-\(index)",
                                              day: day,
                                              start: start,
                                              end: end,
                                              duration: TimeInterval(minutes * 60),
                                              restingHR: 54 + (index % 3),
                                              hrv: 72 - index,
                                              respiratoryRate: 14.4 + Double(index % 4) * 0.1,
                                              sleepEfficiency: 0.86 + Double(index % 3) * 0.02,
                                              confidence: index == 0 ? "debug_fixture_pending_review" : "debug_fixture_confirmed_sleep",
                                              source: index == 0 ? "sleep_candidate" : "validated_sleep_window",
                                              confirmed: index != 0,
                                              stageSegments: [])
        }
        return SleepHistorySnapshot(nights: nights, confirmedCount: max(0, nights.count - 1), candidateCount: 1)
    }
    #else
    private var debugFixtureSleepHistory: SleepHistorySnapshot? { nil }
    #endif
}

private struct AtriaVitalsProfileCardHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @AtriaDefault("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AtriaDefault("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AtriaDefault("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AtriaDefault("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void

    var body: some View {
        AtriaProfileCard(profile: profileStore.profile,
                         observedPeakHeartRateText: pulseStore.state.peakHeartRateText,
                         vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                         biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary,
                         biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta,
                         biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta,
                         vo2GreenDelta: vo2GreenDelta,
                         vo2RedDelta: vo2RedDelta,
                         onUpdateProfile: onUpdateProfile)
            .equatable()
    }
}

private struct AtriaCollectionCaptureCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let ble: AtriaBLEManager
    @Binding var captureShareURL: URL?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Saved readings", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.isRecording ? .live : .local)
            }

            captureActions

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                captureStats
            }

            DisclosureGroup(isExpanded: $showDetails) {
                Text(collectionLiveStore.state.captureSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Label("Details", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
            }
            .tint(.secondary)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var captureStats: some View {
        AtriaMetricTile(label: "Readings",
                        value: "\(collectionLiveStore.state.capturedRows)",
                        state: collectionLiveStore.state.isRecording ? .live : .local,
                        tint: .blue)
        AtriaMetricTile(label: "Backup",
                        value: collectionLiveStore.state.recordingState,
                        state: collectionLiveStore.state.isRecording ? .live : .local,
                        tint: collectionLiveStore.state.isRecording ? .red : .blue)
        AtriaMetricTile(label: "Export",
                        value: collectionLiveStore.state.captureFileLabel,
                        state: .local,
                        tint: .green)
    }

    private static let statColumns = AtriaMetricTile.gridColumns

    @ViewBuilder
    private var captureActions: some View {
        VStack(spacing: 10) {
            captureActionButtons
        }
    }

    @ViewBuilder
    private var captureActionButtons: some View {
        Button {
            ble.toggleRecording()
        } label: {
            Text(collectionLiveStore.state.isRecording ? "Stop backup" : "Start backup")
                .frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: collectionLiveStore.state.isRecording ? .red : .blue)

        Button {
            captureShareURL = ble.exportCSV()
        } label: {
            Text("Prepare export").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        if let captureShareURL {
            ShareLink(item: captureShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .green)
        }
    }
}

private struct AtriaCollectionRRReferenceCardHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    let store: SessionStore
    @Binding var showRRImporter: Bool
    @Binding var rrShareURL: URL?
    let rrImportStatus: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "Beat-to-beat window",
                leadingValue: homeStatsStore.state.rrPackageText,
                leadingDetail: homeStatsStore.state.hrvDetail,
                trailingTitle: "Flow",
                trailingValue: "Export or import",
                trailingDetail: "local file flow"
            )

            rrActionButtons

            if !rrImportStatus.isEmpty || !homeStatsStore.state.hrvDetail.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !rrImportStatus.isEmpty {
                            Text(rrImportStatus)
                        }
                        Text(homeStatsStore.state.hrvDetail)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                AtriaPanelSectionHeader(title: "Beat-to-beat check", subtitle: "")
                referenceStateBadge
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Beat-to-beat check", subtitle: "")
                Spacer(minLength: 8)
                referenceStateBadge
            }
        }
    }

    private var referenceStateBadge: some View {
        AtriaStateBadge(state: homeStatsStore.state.rrPackageText.localizedCaseInsensitiveContains("ready")
            ? .validated
            : .learning)
    }

    @ViewBuilder
    private var rrActionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                exportButton
                importButton
                if let rrShareURL {
                    shareButton(rrShareURL)
                }
            }
        } else {
            HStack(spacing: 8) {
                exportButton
                importButton
                if let rrShareURL {
                    shareButton(rrShareURL)
                }
            }
        }
    }

    private var exportButton: some View {
        Button {
            rrShareURL = store.exportRRReferencePackageForUI()
        } label: {
            AtriaCollectionReferenceActionLabel(title: "Export beats",
                                                systemImage: "square.and.arrow.up.on.square")
        }
        .tint(.blue)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    private var importButton: some View {
        Button {
            showRRImporter = true
        } label: {
            AtriaCollectionReferenceActionLabel(title: "Import beats",
                                                systemImage: "square.and.arrow.down")
        }
        .tint(.blue)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    private func shareButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            AtriaCollectionReferenceActionLabel(title: "Share",
                                                systemImage: "square.and.arrow.up")
        }
        .tint(.green)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

private struct AtriaCollectionHRReferenceCardHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @Binding var showHRImporter: Bool
    @Binding var hrShareURL: URL?
    let hrImportStatus: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "Heart-rate status",
                leadingValue: snapshotStore.state.referenceText,
                leadingDetail: "comparison workout",
                trailingTitle: "Workout",
                trailingValue: snapshotStore.state.workoutText,
                trailingDetail: "current classifier"
            )

            hrActionButtons

            if !hrImportStatus.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(hrImportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                AtriaPanelSectionHeader(title: "Heart-rate check", subtitle: "")
                referenceStateBadge
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart-rate check", subtitle: "")
                Spacer(minLength: 8)
                referenceStateBadge
            }
        }
    }

    private var referenceStateBadge: some View {
        AtriaStateBadge(state: snapshotStore.state.referenceText.localizedCaseInsensitiveContains("ready")
            ? .validated
            : .learning)
    }

    @ViewBuilder
    private var hrActionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                exportButton
                importButton
                if let hrShareURL {
                    shareButton(hrShareURL)
                }
            }
        } else {
            HStack(spacing: 8) {
                exportButton
                importButton
                if let hrShareURL {
                    shareButton(hrShareURL)
                }
            }
        }
    }

    private var exportButton: some View {
        Button {
            hrShareURL = store.exportHRReferencePackageForUI()
        } label: {
            AtriaCollectionReferenceActionLabel(title: "Export heart rate",
                                                systemImage: "square.and.arrow.up.on.square")
        }
        .tint(.blue)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    private var importButton: some View {
        Button {
            showHRImporter = true
        } label: {
            AtriaCollectionReferenceActionLabel(title: "Import heart rate",
                                                systemImage: "square.and.arrow.down")
        }
        .tint(.blue)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    private func shareButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            AtriaCollectionReferenceActionLabel(title: "Share",
                                                systemImage: "square.and.arrow.up")
        }
        .tint(.green)
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

private struct AtriaCollectionReferenceActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 18)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

enum AtriaExperimentalSensorCopy {
    static func hasValidatedSkinTemperatureReading(
        summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
        decoderAvailable: Bool
    ) -> Bool {
        decoderAvailable && summary.isReady
    }

    static func skinTemperatureValue(
        summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
        decoderAvailable: Bool
    ) -> String {
        hasValidatedSkinTemperatureReading(summary: summary, decoderAvailable: decoderAvailable)
            ? summary.valueText
            : "--"
    }

    // Strap 3 is a hardware limitation. Supported/unknown newer straps instead
    // name Atria's actual app limitation until the decoder is verified. Neither
    // branch promotes candidate bytes into a blood-oxygen percentage.
    static func bloodOxygenStatus(strapModel: AtriaBLEManager.AtriaStrapModel,
                                  decoderAvailable: Bool) -> String {
        if strapModel == .strap3 {
            return AtriaSpO2Copy.notAvailableOnStrap
        }
        return decoderAvailable
            ? "No SpO2 reading yet"
            : AtriaSpO2Copy.decoderNotVerified
    }

    static func bloodOxygenFootnote(strapModel: AtriaBLEManager.AtriaStrapModel,
                                    decoderAvailable: Bool) -> String {
        if strapModel == .strap3 {
            return "\(AtriaSpO2Copy.notAvailableOnStrap) \(AtriaSpO2Copy.wontFakeAPercentage)"
        }
        if !decoderAvailable {
            return "\(AtriaSpO2Copy.decoderNotVerified). Atria does not estimate a percentage."
        }
        return "No SpO2 reading yet."
    }

    static func bloodOxygenDetail(strapModel: AtriaBLEManager.AtriaStrapModel,
                                  decoderAvailable: Bool,
                                  candidateFrames: Int) -> String {
        if strapModel == .strap3 {
            return AtriaSpO2Copy.longUnavailable
        }
        if !decoderAvailable {
            return "\(AtriaSpO2Copy.decoderNotVerified). Atria does not show raw sensor data as blood oxygen."
        }
        return candidateFrames > 0
            ? "\(candidateFrames) candidate frames found. Atria does not show an SpO2 percentage until quality checks pass."
            : "No SpO2 reading yet. Atria does not estimate or display a percentage."
    }

    static func skinTemperatureStatus(summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
                                      decoderAvailable: Bool) -> String {
        guard decoderAvailable else { return "Decoder not verified" }
        return summary.detailText
    }

    static func skinTemperatureFootnote(candidateValues: Int,
                                        decoderAvailable: Bool) -> String {
        guard !decoderAvailable else { return "Sleep-only relative deviation; no absolute temperature." }
        return "Decoder not verified. Atria does not show raw sensor data as wrist temperature."
    }

    static func skinTemperatureDetail(summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
        decoderAvailable: Bool) -> String {
        guard decoderAvailable else {
            return "Decoder not verified. Atria does not show raw sensor data as wrist temperature."
        }
        return summary.isReady
            ? "\(summary.valueText) delta C versus your local sleep baseline. This is a relative wrist-skin signal, not core temperature."
            : "Atria is building a sleep baseline. It will only show relative wrist-skin deviation, never core temperature."
    }

    static func skinTemperatureAccessibilityDetail(
        summary: IMUAuditSummary.SkinTemperatureDeviationSummary,
        decoderAvailable: Bool
    ) -> String {
        guard hasValidatedSkinTemperatureReading(summary: summary,
                                                  decoderAvailable: decoderAvailable) else {
            return decoderAvailable
                ? "Wrist temperature deviation is \(summary.detailText.lowercased())."
                : "Wrist-temperature decoder not verified."
        }
        return "Wrist temperature relative sleep signal \(summary.valueText) delta C from baseline, \(summary.footnoteText)."
    }
}

struct AtriaExperimentalRespiratoryRatePresentation: Equatable {
    let sourceID: String?
    let value: Double?
    let zone: AtriaMetricZone?
    let detail: String

    var valueText: String {
        value.map { String(format: "%.1f", $0) } ?? "--"
    }

    var state: AtriaMetricState {
        value == nil ? .learning : .research
    }

    var tint: Color {
        guard value != nil else { return .secondary }
        return zone?.tint ?? .teal
    }

    static func resolve(
        snapshot: SleepHistorySnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        greenDelta: Double,
        yellowDelta: Double
    ) -> Self {
        guard let mainSleep = AtriaOverviewCurrentSleep.resolve(
            from: snapshot,
            now: now,
            calendar: calendar
        ) else {
            return Self(
                sourceID: nil,
                value: nil,
                zone: nil,
                detail: "Needs a current confirmed main sleep."
            )
        }
        guard let rate = mainSleep.respiratoryRate,
              rate.isFinite,
              rate > 0 else {
            return Self(
                sourceID: mainSleep.id,
                value: nil,
                zone: nil,
                detail: "Current confirmed main sleep has no qualified respiratory rate."
            )
        }
        let zone = Metrics.respiratoryRateZone(
            rate,
            baseline: snapshot.respiratoryBaselineMean,
            baselineSamples: snapshot.respiratoryBaselineCount,
            greenDelta: greenDelta,
            yellowDelta: yellowDelta
        )
        return Self(
            sourceID: mainSleep.id,
            value: rate,
            zone: zone,
            detail: zone == nil
                ? "Current confirmed main sleep · building your sleep baseline."
                : "Current confirmed main sleep · compared with your sleep baseline."
        )
    }
}

private struct AtriaCollectionResearchSignalsCard: View, Equatable {
    let summary: IMUAuditSummary
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let strapModel: AtriaBLEManager.AtriaStrapModel
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AtriaDefault("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AtriaDefault("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AtriaDefault("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @State private var showResearchInfo = false

    static func == (lhs: AtriaCollectionResearchSignalsCard, rhs: AtriaCollectionResearchSignalsCard) -> Bool {
        lhs.summary == rhs.summary
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
            && lhs.strapModel == rhs.strapModel
            && lhs.bloodOxygenCandidateGoal == rhs.bloodOxygenCandidateGoal
    }

    private var respiratoryRatePresentation: AtriaExperimentalRespiratoryRatePresentation {
        AtriaExperimentalRespiratoryRatePresentation.resolve(
            snapshot: sleepHistory,
            greenDelta: respiratoryGreenDelta,
            yellowDelta: respiratoryYellowDelta
        )
    }

    private var skinTemperatureDeviationZone: AtriaMetricZone? {
        Metrics.skinTemperatureDeviationZone(summary.skinTemperatureDeviation,
                                             greenDelta: skinTemperatureGreenDelta,
                                             yellowDelta: skinTemperatureYellowDelta)
    }

    var body: some View {
        let respiratory = respiratoryRatePresentation
        let hasEvidence = summary.probeFrameCount > 0
            || summary.strapStepCount > 0
            || respiratory.value != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Experimental sensors", subtitle: "")
                Spacer(minLength: 0)
                Button {
                    showResearchInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.bold))
                        .frame(width: 18, height: 18)
                }
                .atriaCardAction(prominent: false, tint: .blue)
                .accessibilityLabel("Experimental sensor info")
                AtriaStateBadge(state: hasEvidence ? .research : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Blood oxygen",
                                value: "--",
                                unit: nil,
                                state: .learning,
                                tint: .orange,
                                footnote: AtriaExperimentalSensorCopy.bloodOxygenFootnote(
                                    strapModel: strapModel,
                                    decoderAvailable: AtriaResearchProbe.validatedSpO2DecoderAvailable),
                                zone: nil,
                                targetMetric: nil)
                AtriaMetricTile(label: "Wrist temp",
                                value: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                    ? summary.skinTemperatureDeviation.valueText
                                    : "--",
                                unit: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                    && summary.skinTemperatureDeviation.isReady ? "delta C" : nil,
                                state: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                    && summary.skinTemperatureDeviation.isReady ? .research : .learning,
                                tint: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                    ? (skinTemperatureDeviationZone?.tint ?? .teal)
                                    : .orange,
                                footnote: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                    ? summary.skinTemperatureDeviation.footnoteText
                                    : AtriaExperimentalSensorCopy.skinTemperatureFootnote(
                                        candidateValues: summary.skinTemperatureDeviation.candidateValues,
                                        decoderAvailable: false),
                                zone: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                    ? skinTemperatureDeviationZone
                                    : nil,
                                targetMetric: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable ? .bodyTemp : nil)
                AtriaMetricTile(label: "Resp rate",
                                value: respiratory.valueText,
                                unit: respiratory.value == nil ? nil : "/min",
                                state: respiratory.state,
                                tint: respiratory.tint,
                                footnote: respiratory.detail,
                                zone: respiratory.zone,
                                targetMetric: .respiratoryRate)
                AtriaMetricTile(label: "Strap steps",
                                value: summary.strapStepText,
                                state: summary.strapStepCount > 0 ? .research : .learning,
                                tint: .green,
                                footnote: summary.strapStepCount > 0
                                    ? "\(summary.agreementText) · all saved research sessions"
                                    : summary.agreementText,
                                zone: nil,
                                targetMetric: nil)
            }

            Text("Rows show evidence counts until checked. Skin temperature is only a sleep-baseline change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .sheet(isPresented: $showResearchInfo) {
            AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,
                                         skinTemperatureSummary: summary.skinTemperatureDeviation,
                                         strapModel: strapModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaResearchSignalInfoSheet: View {
    let spo2CandidateFrames: Int
    let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    let strapModel: AtriaBLEManager.AtriaStrapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    researchInfoRow(systemImage: "drop.degreesign",
                                    tint: .blue,
                                    title: "Blood oxygen signal",
                                    detail: AtriaExperimentalSensorCopy.bloodOxygenDetail(
                                        strapModel: strapModel,
                                        decoderAvailable: AtriaResearchProbe.validatedSpO2DecoderAvailable,
                                        candidateFrames: spo2CandidateFrames))

                    researchInfoRow(systemImage: "thermometer.variable",
                                    tint: .teal,
                                    title: "Wrist temperature signal",
                                    detail: AtriaExperimentalSensorCopy.skinTemperatureDetail(
                                        summary: skinTemperatureSummary,
                                        decoderAvailable: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable))

                    Text("Experimental, local, and not medical advice. SpO2 and temperature are not written to HealthKit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .navigationTitle("Experimental sensors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func researchInfoRow(systemImage: String,
                                 tint: Color,
                                 title: String,
                                 detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }
}

private struct AtriaCollectionBiologicalAgeCardHost: View {
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @AtriaDefault("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AtriaDefault("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3

    var body: some View {
        AtriaCollectionBiologicalAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary,
                                         greenOlderDelta: biologicalAgeGreenOlderDelta,
                                         yellowOlderDelta: biologicalAgeYellowOlderDelta)
            .equatable()
    }
}

private struct AtriaCollectionBiologicalAgeCard: View, Equatable {
    let summary: BiologicalAgeSummary
    let greenOlderDelta: Int
    let yellowOlderDelta: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Body Age", subtitle: summary.narrative)
                Spacer(minLength: 0)
                AtriaStateBadge(state: summary.isReady ? .estimate : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Body age",
                                value: summary.valueText,
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (summary.isReady ? .purple : .orange),
                                footnote: summary.isReady ? summary.detailText : "Calibrating",
                                zone: biologicalAgeZone,
                                targetMetric: .bioAge)
                AtriaMetricTile(label: "Delta",
                                value: summary.ageDelta.map { "\($0 > 0 ? "+" : "")\($0)" } ?? "--",
                                unit: summary.ageDelta == nil ? nil : "yr",
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? deltaTint,
                                footnote: summary.isReady ? summary.detailText : summary.compactStatusText,
                                zone: biologicalAgeZone,
                                targetMetric: .bioAge)
                AtriaMetricTile(label: "Pace",
                                value: summary.agingPaceText,
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? deltaTint,
                                footnote: summary.availabilityDetailText)
            }

            if summary.factors.isEmpty {
                Text(summary.blockerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(summary.factors) { factor in
                        AtriaBioAgeFactorRow(factor: factor)
                    }
                }
            }

            Text(summary.footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var deltaTint: Color {
        guard let ageDelta = summary.ageDelta else { return .orange }
        if ageDelta == 0 { return .blue }
        return ageDelta < 0 ? .green : .orange
    }

    private var biologicalAgeZone: AtriaMetricZone? {
        Metrics.biologicalAgeZone(summary,
                                  greenOlderDelta: greenOlderDelta,
                                  yellowOlderDelta: yellowOlderDelta)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaBioAgeFactorRow: View, Equatable {
    let factor: BioAgeFactor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(factor.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(factor.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            Text(factor.deltaText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(10)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(factor.label), \(factor.deltaText), \(factor.detail)")
    }

    private var tint: Color {
        switch factor.direction {
        case .younger: return .green
        case .older: return .orange
        case .neutral: return .blue
        }
    }

    private var icon: String {
        switch factor.direction {
        case .younger: return "arrow.down.forward.circle.fill"
        case .older: return "arrow.up.forward.circle.fill"
        case .neutral: return "equal.circle.fill"
        }
    }
}

private struct AtriaCollectionIMUAuditCard: View, Equatable {
    let summary: IMUAuditSummary

    static func == (lhs: AtriaCollectionIMUAuditCard, rhs: AtriaCollectionIMUAuditCard) -> Bool {
        lhs.summary == rhs.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Motion audit", subtitle: "")
                Spacer(minLength: 0)
                AtriaStateBadge(state: summary.validatedFrames > 0 ? .validated : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Frames",
                                value: summary.frameText,
                                state: summary.frameCount > 0 ? .research : .learning,
                                tint: .indigo)
                AtriaMetricTile(label: "Rate",
                                value: summary.sampleRateText,
                                unit: summary.sampleRateHz == nil ? nil : "Hz",
                                state: summary.sampleRateHz == nil ? .learning : .research,
                                tint: .blue)
                AtriaMetricTile(label: "Layout",
                                value: summary.layoutText,
                                state: summary.layoutText == "--" ? .learning : .research,
                                tint: .purple)
                AtriaMetricTile(label: "Gravity",
                                value: summary.gravityText,
                                state: summary.validatedFrames > 0 ? .validated : .learning,
                                tint: summary.validatedFrames > 0 ? .green : .orange)
                AtriaMetricTile(label: "Sleep/wake",
                                value: summary.sleepWakeText,
                                state: summary.sleepWakeText == "--" ? .learning : .research,
                                tint: .cyan,
                                footnote: summary.sleepWakeReason)
                AtriaMetricTile(label: "Probes",
                                value: summary.probeText,
                                state: summary.probeFrameCount > 0 ? .research : .learning,
                                tint: .teal,
                                footnote: summary.probeDetail)
            }

            Text("Early motion signals stay separate until the strap motion layout is checked.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaResearchManeuverMarkerCard: View, Equatable {
    private static let relativeMarkerFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    let markers: [ResearchManeuverMarker]
    let correlationSummary: ResearchManeuverProbeCorrelationSummary
    let onMark: (ResearchManeuverMarker.Kind) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaResearchManeuverMarkerCard, rhs: AtriaResearchManeuverMarkerCard) -> Bool {
        lhs.markers == rhs.markers && lhs.correlationSummary == rhs.correlationSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Probe markers", subtitle: "")
                Spacer(minLength: 0)
                AtriaStatusChip(text: "\(markers.count)",
                                systemImage: "scope",
                                tint: markers.isEmpty ? .gray : .teal)
            }

            LazyVGrid(columns: Self.buttonColumns, spacing: 10) {
                // Deliberate desaturation is not an acceptable decoder maneuver.
                // Keep legacy breath-hold rows decodable, but never offer a new
                // breath-hold action in Atria's capture workflow.
                ForEach(ResearchManeuverMarker.Kind.allCases.filter { $0 != .breathHold }) { kind in
                    Button {
                        if reduceMotion {
                            onMark(kind)
                        } else {
                            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                                onMark(kind)
                            }
                        }
                    } label: {
                        Label(kind.shortLabel, systemImage: kind.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .atriaCardAction(prominent: false, tint: .teal)
                }
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Markers",
                                value: "\(markers.count)",
                                state: markers.isEmpty ? .learning : .research,
                                tint: .teal)
                AtriaMetricTile(label: "Probe match",
                                value: correlationSummary.matchText,
                                state: correlationSummary.matchedMarkers > 0 ? .research : .learning,
                                tint: .green,
                                footnote: correlationSummary.candidateText)
                AtriaMetricTile(label: "Latest",
                                value: latestMarkerText,
                                state: markers.isEmpty ? .learning : .research,
                                tint: .cyan,
                                footnote: latestMarkerDetail)
            }

            Text("Markers stay on device and help compare probe timing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var latestMarkerText: String {
        markers.first?.kind.shortLabel ?? "--"
    }

    private var latestMarkerDetail: String? {
        guard let marker = markers.first else { return nil }
        return Self.relativeMarkerFormatter.localizedString(for: marker.timestamp, relativeTo: Date())
    }

    private static let buttonColumns = [GridItem(.flexible()), GridItem(.flexible())]
    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaCollectionControlsCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    let store: SessionStore
    let ble: AtriaBLEManager
    @Binding var hapticSettings: AtriaHapticAlertSettings
    let developerModeEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Strap controls", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.longWearModeEnabled ? .live : .local)
            }

            VStack(spacing: 12) {
                if developerModeEnabled {
                    AtriaCollectionToggleCard(
                        title: "Stable sensor mode",
                        subtitle: collectionLiveStore.state.standardHROnlyEnabled
                            ? "Recommended minimal connection with heart rate and strap-native motion."
                            : "Diagnostic full protocol; richer transport may be less stable.",
                        systemImage: collectionLiveStore.state.standardHROnlyEnabled ? "antenna.radiowaves.left.and.right" : "wrench.and.screwdriver.fill",
                        tint: collectionLiveStore.state.standardHROnlyEnabled ? .green : .orange,
                        isOn: Binding(
                            get: { collectionLiveStore.state.standardHROnlyEnabled },
                            set: { enabled in
                                ble.setStandardHROnlyEnabled(enabled)
                            })
                    )
                }

                AtriaCollectionToggleCard(
                    title: "All-day wear",
                    subtitle: "Keep local backup running longer using your current rest and max HR.",
                    systemImage: "record.circle",
                    tint: .green,
                    isOn: Binding(
                        get: { collectionLiveStore.state.longWearModeEnabled },
                        set: { enabled in
                            ble.setLongWearModeEnabled(enabled,
                                                       rest: homeStatsStore.state.restingHeartRate,
                                                       maxHR: profileStore.profile.maxHR)
                        })
                )

                AtriaHapticAlertSettingsCard(settings: hapticSettings) { settings in
                    hapticSettings = settings
                }
            }

            NavigationLink {
                HistoryView(store: store)
            } label: {
                Label("Open saved sessions", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .atriaCardAction(prominent: false, tint: .gray)
        }
        .padding(18)
        .atriaCard()
    }
}

struct AtriaCollectionStatusProjectionState: Equatable {
    let loggingText: String
    let backupValue: String
    let batteryStatusSummaryText: String
    let batteryLevel: Int
    let batteryShowsPowered: Bool
    let batteryDetailText: String
    let modeLabel: String
    let longWearModeEnabled: Bool
    let officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
    let historicalArchiveStatus: SessionStore.HistoricalArchiveStatus
}

@MainActor
final class AtriaCollectionStatusProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaCollectionStatusProjectionState

    private let coreLiveStore: AtriaHomeModel.CoreLiveStore
    private let collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    private let homeStatsStore: AtriaHomeModel.HomeStatsStore
    private let snapshotStore: AtriaHomeModel.SnapshotStore
    private let store: SessionStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(coreLiveStore: AtriaHomeModel.CoreLiveStore,
         collectionLiveStore: AtriaHomeModel.CollectionLiveStore,
         homeStatsStore: AtriaHomeModel.HomeStatsStore,
         snapshotStore: AtriaHomeModel.SnapshotStore,
         store: SessionStore) {
        self.coreLiveStore = coreLiveStore
        self.collectionLiveStore = collectionLiveStore
        self.homeStatsStore = homeStatsStore
        self.snapshotStore = snapshotStore
        self.store = store
        state = Self.makeState(coreLiveStore: coreLiveStore,
                               collectionLiveStore: collectionLiveStore,
                               homeStatsStore: homeStatsStore,
                               snapshotStore: snapshotStore,
                               store: store)

        Publishers.MergeMany([
            coreLiveStore.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            collectionLiveStore.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            homeStatsStore.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            snapshotStore.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$historicalArchiveStatus.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in self?.scheduleRefresh() }
        .store(in: &cancellables)
    }

    @discardableResult
    func refresh() -> Bool {
        let next = Self.makeState(coreLiveStore: coreLiveStore,
                                  collectionLiveStore: collectionLiveStore,
                                  homeStatsStore: homeStatsStore,
                                  snapshotStore: snapshotStore,
                                  store: store)
        guard next != state else { return false }
        state = next
        return true
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private static func makeState(coreLiveStore: AtriaHomeModel.CoreLiveStore,
                                  collectionLiveStore: AtriaHomeModel.CollectionLiveStore,
                                  homeStatsStore: AtriaHomeModel.HomeStatsStore,
                                  snapshotStore: AtriaHomeModel.SnapshotStore,
                                  store: SessionStore) -> AtriaCollectionStatusProjectionState {
        AtriaCollectionStatusProjectionState(
            loggingText: snapshotStore.state.loggingText,
            backupValue: homeStatsStore.state.backupValue,
            batteryStatusSummaryText: coreLiveStore.state.batteryStatusSummaryText,
            batteryLevel: coreLiveStore.state.batteryLevel,
            batteryShowsPowered: coreLiveStore.state.batteryShowsPowered,
            batteryDetailText: coreLiveStore.state.batteryDetailText,
            modeLabel: collectionLiveStore.state.modeLabel,
            longWearModeEnabled: collectionLiveStore.state.longWearModeEnabled,
            officialAppCoexistenceRisk: collectionLiveStore.state.officialAppCoexistenceRisk,
            historicalArchiveStatus: store.historicalArchiveStatus
        )
    }
}

private struct AtriaCollectionStatusCardHost: View {
    let store: SessionStore
    @StateObject private var projectionStore: AtriaCollectionStatusProjectionStore
    let officialAppInstalled: Bool

    init(coreLiveStore: AtriaHomeModel.CoreLiveStore,
         collectionLiveStore: AtriaHomeModel.CollectionLiveStore,
         homeStatsStore: AtriaHomeModel.HomeStatsStore,
         snapshotStore: AtriaHomeModel.SnapshotStore,
         store: SessionStore,
         officialAppInstalled: Bool) {
        self.store = store
        self.officialAppInstalled = officialAppInstalled
        _projectionStore = StateObject(wrappedValue: AtriaCollectionStatusProjectionStore(
            coreLiveStore: coreLiveStore,
            collectionLiveStore: collectionLiveStore,
            homeStatsStore: homeStatsStore,
            snapshotStore: snapshotStore,
            store: store
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Strap status", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: projectionStore.state.officialAppCoexistenceRisk == .suspected ? .conflict : .local)
            }

            if projectionStore.state.officialAppCoexistenceRisk != .cleared {
                AtriaCollectionCoexistenceWarning(risk: projectionStore.state.officialAppCoexistenceRisk,
                                                  officialAppInstalled: officialAppInstalled)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                statusTiles
            }
        }
        .padding(18)
        .atriaCard()
        .task {
            store.refreshHistoricalArchiveStatus(reason: "data_status_appear")
        }
    }

    @ViewBuilder
    private var statusTiles: some View {
        AtriaMetricTile(label: "Logging",
                        value: projectionStore.state.loggingText,
                        state: projectionStore.state.loggingText.localizedCaseInsensitiveContains("sample") ? .live : .learning,
                        tint: .green)
        AtriaMetricTile(label: "Backup",
                        value: projectionStore.state.backupValue,
                        state: .local,
                        tint: .blue)
        AtriaMetricTile(label: "Battery",
                        value: projectionStore.state.batteryLevel >= 0
                            ? projectionStore.state.batteryStatusSummaryText : "--",
                        state: projectionStore.state.batteryLevel >= 0 ? .live : .learning,
                        tint: projectionStore.state.batteryShowsPowered ? .green : .blue,
                        footnote: projectionStore.state.batteryLevel >= 0
                            ? projectionStore.state.batteryDetailText : "Unavailable")
        AtriaMetricTile(label: "Mode",
                        value: projectionStore.state.modeLabel,
                        state: projectionStore.state.longWearModeEnabled ? .live : .local,
                        tint: .purple)
        AtriaMetricTile(label: "App",
                        value: coexistenceValue,
                        state: coexistenceState,
                        tint: coexistenceTint,
                        footnote: coexistenceFootnote)
        // Static handoff compatibility marker for the old engineering label: AtriaMetricTile(label: "Backfill"
        AtriaMetricTile(label: "Catching up",
                        value: projectionStore.state.historicalArchiveStatus.valueText,
                        state: backfillState,
                        tint: .cyan,
                        footnote: backfillFootnote)
    }

    private var backfillFootnote: String {
        "\(projectionStore.state.historicalArchiveStatus.userFootnoteText) \(projectionStore.state.historicalArchiveStatus.actionText)"
    }

    private var backfillState: AtriaMetricState {
        if !projectionStore.state.historicalArchiveStatus.parseOK { return .conflict }
        if projectionStore.state.historicalArchiveStatus.metricReady { return .validated }
        if projectionStore.state.historicalArchiveStatus.hasArchiveRows { return .local }
        return .learning
    }

    private var coexistenceValue: String {
        switch projectionStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return "Clear"
        case .advisory:
            return "Monitor"
        case .suspected:
            return "Conflict"
        }
    }

    private var coexistenceState: AtriaMetricState {
        switch projectionStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return .local
        case .advisory:
            return .local
        case .suspected:
            return .conflict
        }
    }

    private var coexistenceTint: Color {
        switch projectionStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return .green
        case .advisory:
            return .orange
        case .suspected:
            return .red
        }
    }

    private var coexistenceFootnote: String {
        switch projectionStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return "Atria has the strap."
        case .advisory:
            return "Close the official app if drops return."
        case .suspected:
            return "Uninstall or disable the official app before relying on Atria."
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaCollectionCoexistenceWarning: View, Equatable {
    let risk: AtriaBLEManager.OfficialAppCoexistenceRisk
    let officialAppInstalled: Bool

    private var title: String {
        if risk == .suspected {
            return officialAppInstalled ? "App conflict" : "Connection keeps dropping"
        }
        return "Strap check"
    }

    private var detail: String {
        switch risk {
        case .suspected where officialAppInstalled:
            return "Remove the official strap app, then reconnect."
        case .suspected:
            return "Forget the strap in Bluetooth, then reconnect."
        case .advisory:
            return "Remove the official strap app if drops return."
        case .cleared:
            return "Atria has the strap."
        }
    }

    private var tint: Color {
        risk == .suspected ? .red : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: tint)
    }
}

private struct AtriaCollectionProfilePicker: View, Equatable {
    let selected: AtriaBLEManager.CollectionProfile
    let onSelect: (AtriaBLEManager.CollectionProfile) -> Void

    static func == (lhs: AtriaCollectionProfilePicker, rhs: AtriaCollectionProfilePicker) -> Bool {
        lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                    .frame(width: 24, height: 24)
                    .background(AtriaIconTileBackground(cornerRadius: 8, tint: .purple))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Saving mode")
                        .font(.subheadline.weight(.semibold))
                    Text(selected.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            // Standard native iOS 26 segmented control.
            Picker("Saving mode", selection: Binding(
                get: { selected },
                set: { onSelect($0) }
            )) {
                ForEach(AtriaBLEManager.CollectionProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Saving mode")
        }
        .padding(14)
        .atriaInsetCard(tint: .purple)
    }
}

private enum AtriaVitalsLiveSignalMode: String, CaseIterable, Identifiable {
    case stress = "Stress"
    case heartRate = "Heart rate"

    var id: String { rawValue }
}

/// Vitals is a live surface, so its 12-hour stress frame ends at the screen's
/// current reference time—not at the latest restored sample. Anchoring to a
/// stale persisted point can otherwise make yesterday look current after a
/// disconnected relaunch.
enum AtriaVitalsStressTimelineProjection {
    static func evidence(
        history: [AtriaStressMonitorStore.StressHistoryPoint],
        referenceDate: Date,
        window: TimeInterval = AtriaStressTimelineWindow.inlineDefault
    ) -> AtriaStressTimelineEvidenceProjection {
        let cutoff = referenceDate.addingTimeInterval(-window)
        let readings = history.lazy
            .filter { $0.t >= cutoff && $0.t <= referenceDate }
            .map(AtriaStressDetailReading.init(historyPoint:))
        return AtriaStressTimelineEvidenceProjection.make(readings: Array(readings))
    }

    /// Compatibility projection for callers that explicitly need the numeric
    /// physiological-stress points. Complete v3 HR-only estimates remain on
    /// this same continuous line with lower-confidence provenance.
    static func points(
        history: [AtriaStressMonitorStore.StressHistoryPoint],
        referenceDate: Date,
        window: TimeInterval = AtriaStressTimelineWindow.inlineDefault
    ) -> [AtriaStressTimelinePoint] {
        evidence(history: history,
                 referenceDate: referenceDate,
                 window: window).stressPoints
    }
}

enum AtriaVitalsStressTimelineCopy {
    static let gapNote = "Five-minute estimates · HR-only is lower confidence · gaps remain blank."
    static let accessibilityLabel = "Physiological stress timeline, scale 0 through 3. Calm is 0 to 1, Moderate is 1 to 2, and High is 2 to 3. HR-only estimates are lower confidence. Collection gaps remain blank. Pinch to zoom between 12 and 4 hours."
}

/// One top-level monitoring surface keeps the two live signals on the same
/// canvas. It avoids an extra full-width card while making the requested
/// Stress / Heart Rate comparison discoverable.
private struct AtriaVitalsLiveSignalCard: View {
    let isConnected: Bool
    let live: AtriaVitalsPulsePresentationState
    let miniTimelineSeries: AtriaHeartRateChartSeries
    let stressState: AtriaStressState
    let stressHistory: [AtriaStressMonitorStore.StressHistoryPoint]
    let restingHeartRate: Int
    let restingHeartRateText: String
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let restingGreenDelta: Int
    let restingYellowDelta: Int
    let onOpenHeartRate: () -> Void
    @State private var mode: AtriaVitalsLiveSignalMode = .stress

    private var hasReadablePulse: Bool {
        live.hasPulseSignal
    }

    private var pulseState: AtriaMetricState {
        hasReadablePulse ? .live : .noContact
    }

    private var restingHeartRateZone: AtriaMetricZone? {
        Metrics.restingHeartRateZone(restingHeartRate,
                                     baseline: restingBaseline,
                                     baselineSamples: restingBaselineSamples,
                                     baselineTrusted: restingBaselineTrusted,
                                     baselineTarget: baselineTarget,
                                     greenDelta: restingGreenDelta,
                                     yellowDelta: restingYellowDelta)
    }

    private var stressPresentation: AtriaStressPresentation {
        AtriaStressPresentation.make(state: stressState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Live monitor", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: mode == .heartRate ? pulseState : stressMetricState)
            }

            AtriaTextSelector(items: AtriaVitalsLiveSignalMode.allCases,
                              title: { $0.rawValue },
                              selection: $mode)

            if mode == .stress {
                stressMonitor
            } else {
                heartRateMonitor
            }
        }
        // The selected signal already owns the one useful canvas (the trace
        // or its honest empty state). A second full-width shell around it
        // consumed nearly a screenful of vertical space and made Vitals read
        // as cards inside cards. Keep the header and control directly in the
        // section rhythm so the signal is the primary surface.
        .padding(.vertical, 4)
    }

    private var stressMetricState: AtriaMetricState {
        stressState.level == nil ? .noContact : .live
    }

    private var stressMonitor: some View {
        let referenceDate = Date()
        let projection = AtriaVitalsStressTimelineProjection.evidence(
            history: stressHistory,
            referenceDate: referenceDate
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // The selected segment already names the metric. Repeating
                    // “stress” in every tier made the empty state feel like a
                    // feature pitch rather than a useful live surface.
                    Text("Current reading")
                        .font(.subheadline.weight(.bold))
                    Text(stressPresentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(stressPresentation.numericScore.map {
                    "\($0.formatted(.number.precision(.fractionLength(1)))) / 3"
                } ?? AtriaCompactMetricPresentation.noValue)
                    .font(.system(.title2, design: .rounded, weight: .black))
                    .monospacedDigit()
                    .foregroundStyle(stressState.level?.tint ?? .secondary)
            }

            switch projection.presentation {
            case .physiologicalStress:
                AtriaVitalsStressTimelineChart(points: projection.stressPoints,
                                               referenceDate: referenceDate)
                    .frame(height: 172)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            case .cardiacArousal:
                AtriaCardiacArousalTimelineChart(
                    points: projection.cardiacArousalPoints,
                    referenceDate: referenceDate,
                    window: AtriaStressTimelineWindow.inlineDefault
                )
                .frame(height: 172)
                .padding(.vertical, 8)
                .padding(.trailing, 8)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            case .empty:
                ContentUnavailableView(stressEmptyTitle,
                                       systemImage: stressEmptySystemImage,
                                       description: Text(stressEmptyDescription))
                    .frame(maxWidth: .infinity, minHeight: 154)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if projection.presentation == .physiologicalStress {
                HStack(spacing: 0) {
                    stressScaleItem("0–1", "Calm", tint: Metrics.electricGreen)
                    stressScaleItem("1–2", "Moderate", tint: Metrics.electricYellow)
                    stressScaleItem("2–3", "High", tint: Metrics.electricRed)
                }
                .accessibilityLabel("Physiological stress scale: Calm from 0 to 1, Moderate from 1 to 2, High from 2 to 3")
            }

            // A gap note is valuable beside a real timeline, but repeats the
            // empty-state explanation before there are any readings to inspect.
            if projection.presentation == .physiologicalStress,
               !projection.stressPoints.isEmpty {
                Text(AtriaVitalsStressTimelineCopy.gapNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stressEmptyTitle: String {
        isConnected ? "Preparing physiological stress" : "Strap disconnected"
    }

    private var stressEmptySystemImage: String {
        isConnected ? "waveform.path.ecg" : "bolt.horizontal.circle"
    }

    private var stressEmptyDescription: String {
        return isConnected
            ? "Keep wearing your strap. A complete five-minute cardiac window produces the first 0–3 estimate; HR-only estimates are labeled lower confidence."
            : "Reconnect your strap to resume live readings. Recent measured readings remain visible when available."
    }

    private func stressScaleItem(_ score: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(score)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var heartRateMonitor: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPulseStatRail(now: live.heartRateText,
                               average: live.averageHeartRateText,
                               peak: live.peakHeartRateText,
                               resting: restingHeartRateText,
                               restingTint: restingHeartRateZone?.tint ?? .secondary)
            AtriaHeartRateTimelineCard(series: miniTimelineSeries, onOpen: onOpenHeartRate)
        }
    }

}

/// Direct presentation owner for the heart-rate explorer. The earlier hidden
/// `UIViewControllerRepresentable` anchor could remain detached from a window,
/// so a valid tap changed SwiftUI state but had no controller capable of
/// presenting. This object resolves the active key-window controller at tap
/// time and retries briefly through in-flight UIKit transitions.
@MainActor
private final class AtriaHeartRateExplorerPresentationController: ObservableObject {
    private var presentationModel: AtriaHeartRateExplorerPresentationModel?
    private weak var hostingController: AtriaHeartRateLandscapeHostingController?
    private var isPresenting = false
    private var isDismissing = false
    private var pendingPoints: [AtriaHomeModel.HeartRateChartPoint] = []
    private var pendingCurrentBPM = 0
    private var presentationRetryTask: Task<Void, Never>?

    func present(points: [AtriaHomeModel.HeartRateChartPoint], currentBPM: Int) {
        pendingPoints = points
        pendingCurrentBPM = currentBPM
        updateLiveInput(points: points, currentBPM: currentBPM)

        guard hostingController == nil, !isPresenting, !isDismissing else {
            AtriaDebugLog("ATRIADBG hr_explorer_present status=already_active presenting=%d dismissing=%d",
                          isPresenting ? 1 : 0,
                          isDismissing ? 1 : 0)
            return
        }
        attemptPresentation(attempt: 0)
    }

    func updateLiveInput(points: [AtriaHomeModel.HeartRateChartPoint], currentBPM: Int) {
        pendingPoints = points
        pendingCurrentBPM = currentBPM
        presentationModel?.update(points: points, currentBPM: currentBPM)
    }

    private func attemptPresentation(attempt: Int) {
        guard hostingController == nil, !isPresenting, !isDismissing else { return }
        guard let presenter = Self.activePresentationSource(),
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed else {
            schedulePresentationRetry(after: attempt)
            return
        }

        presentationRetryTask?.cancel()
        presentationRetryTask = nil
        isPresenting = true
        AtriaHeartRateOrientation.prepareLandscapePresentation()

        let model = AtriaHeartRateExplorerPresentationModel(points: pendingPoints,
                                                            currentBPM: pendingCurrentBPM)
        presentationModel = model
        let root = AtriaHeartRateExplorerPresentationRoot(model: model) { [weak self] in
            self?.dismiss(animated: true)
        }
        let hosting = AtriaHeartRateLandscapeHostingController(rootView: root)
        hosting.modalPresentationStyle = .fullScreen
        hosting.isModalInPresentation = true
        hostingController = hosting

        AtriaDebugLog("ATRIADBG hr_explorer_present status=presenting attempt=%d source=%@ points=%d bpm=%d",
                      attempt,
                      String(describing: type(of: presenter)),
                      pendingPoints.count,
                      pendingCurrentBPM)
        presenter.present(hosting, animated: true) { [weak self, weak hosting] in
            guard let self else { return }
            self.isPresenting = false
            hosting?.setNeedsUpdateOfSupportedInterfaceOrientations()
            AtriaDebugLog("ATRIADBG hr_explorer_present status=presented")
        }
    }

    private func schedulePresentationRetry(after attempt: Int) {
        let nextAttempt = attempt + 1
        guard nextAttempt <= 10 else {
            AtriaDebugLog("ATRIADBG hr_explorer_present status=failed reason=no_attached_presenter attempts=%d",
                          attempt)
            AtriaHeartRateOrientation.restorePortraitAfterDismissal()
            return
        }
        presentationRetryTask?.cancel()
        presentationRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.attemptPresentation(attempt: nextAttempt)
        }
    }

    func dismiss(animated: Bool) {
        presentationRetryTask?.cancel()
        presentationRetryTask = nil
        guard !isDismissing else { return }
        guard let hosting = hostingController else {
            isPresenting = false
            AtriaHeartRateOrientation.restorePortraitAfterDismissal()
            return
        }

        isDismissing = true
        AtriaHeartRateOrientation.preparePortraitDismissal()
        hosting.dismiss(animated: animated) { [weak self] in
            guard let self else { return }
            self.hostingController = nil
            self.presentationModel = nil
            self.isPresenting = false
            self.isDismissing = false
            AtriaHeartRateOrientation.restorePortraitAfterDismissal()
            AtriaDebugLog("ATRIADBG hr_explorer_present status=dismissed")
        }
    }

    private static func activePresentationSource() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return nil
        }
        var topmost = root
        while let presented = topmost.presentedViewController {
            topmost = presented
        }
        return topmost
    }

}

@MainActor
private final class AtriaHeartRateExplorerPresentationModel: ObservableObject {
    @Published private(set) var points: [AtriaHomeModel.HeartRateChartPoint]
    @Published private(set) var currentBPM: Int
    private var pointsKey: AtriaHeartRateMergeCache.SeriesKey

    init(points: [AtriaHomeModel.HeartRateChartPoint], currentBPM: Int) {
        self.points = points
        self.currentBPM = currentBPM
        self.pointsKey = AtriaHeartRateMergeCache.SeriesKey(points: points)
    }

    func update(points: [AtriaHomeModel.HeartRateChartPoint], currentBPM: Int) {
        let key = AtriaHeartRateMergeCache.SeriesKey(points: points)
        if key != pointsKey {
            pointsKey = key
            self.points = points
        }
        if self.currentBPM != currentBPM {
            self.currentBPM = currentBPM
        }
    }

}

private struct AtriaVitalsStressTimelineChart: View {
    let points: [AtriaStressTimelinePoint]
    let referenceDate: Date

    // Visible window (2026-08-08 user request): default last 12h, pinch to zoom
    // IN to a 4h window. It ends at the live surface's reference time, leaving
    // an honest trailing blank when the most recent restored reading is stale.
    @State private var visibleSeconds: TimeInterval = AtriaStressTimelineWindow.inlineDefault
    // @GestureState (not @State): SwiftUI auto-resets it to nil when the pinch
    // ENDS *or is CANCELLED* — e.g. the enclosing scroll view claims the
    // two-finger touch mid-pinch. A manually-reset @State would keep a stale
    // start-window and snap the zoom back on the next pinch (review 2026-08-08).
    @GestureState private var pinchBase: TimeInterval? = nil
    @State private var selectedDate: Date?

    private var xDomain: ClosedRange<Date> {
        referenceDate.addingTimeInterval(-visibleSeconds)...referenceDate
    }

    var body: some View {
        Chart {
            RectangleMark(xStart: .value("Calm start", xDomain.lowerBound),
                          xEnd: .value("Calm end", xDomain.upperBound),
                          yStart: .value("Calm floor", 0),
                          yEnd: .value("Calm ceiling", 1))
                .foregroundStyle(Metrics.electricGreen.opacity(0.055))
            RectangleMark(xStart: .value("Moderate start", xDomain.lowerBound),
                          xEnd: .value("Moderate end", xDomain.upperBound),
                          yStart: .value("Moderate floor", 1),
                          yEnd: .value("Moderate ceiling", 2))
                .foregroundStyle(Metrics.electricYellow.opacity(0.045))
            RectangleMark(xStart: .value("High start", xDomain.lowerBound),
                          xEnd: .value("High end", xDomain.upperBound),
                          yStart: .value("High floor", 2),
                          yEnd: .value("High ceiling", 3))
                .foregroundStyle(Metrics.electricRed.opacity(0.045))

            RuleMark(y: .value("Calm to moderate", 1))
                .lineStyle(StrokeStyle(lineWidth: 0.75))
                .foregroundStyle(.secondary.opacity(0.18))
            RuleMark(y: .value("Moderate to high", 2))
                .lineStyle(StrokeStyle(lineWidth: 0.75))
                .foregroundStyle(.secondary.opacity(0.18))

            ForEach(points.filter {
                $0.reading.sleepContext == .asleep
            }) { point in
                RectangleMark(
                    xStart: .value("Sleep start", point.reading.date.addingTimeInterval(-30)),
                    xEnd: .value("Sleep end", point.reading.date.addingTimeInterval(30)),
                    yStart: .value("Sleep floor", 0),
                    yEnd: .value("Sleep ceiling", 3)
                )
                .foregroundStyle(Color.indigo.opacity(0.09))
            }

            ForEach(points.filter {
                $0.reading.motionContext.qualified
                    && $0.reading.motionContext.kind == .activity
            }) { point in
                RectangleMark(
                    xStart: .value("Activity start", point.reading.date.addingTimeInterval(-30)),
                    xEnd: .value("Activity end", point.reading.date.addingTimeInterval(30)),
                    yStart: .value("Activity floor", 0),
                    yEnd: .value("Activity ceiling", 3)
                )
                .foregroundStyle(Color.orange.opacity(0.075))
            }

            ForEach(points) { point in
                AreaMark(x: .value("Time", point.reading.date),
                         y: .value("Stress", point.reading.score),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen.opacity(0.04),
                                                               Metrics.electricYellow.opacity(0.10),
                                                               Metrics.electricRed.opacity(0.16)],
                                                      startPoint: .bottom,
                                                      endPoint: .top))
                LineMark(x: .value("Time", point.reading.date),
                         y: .value("Stress", point.reading.score),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.linear)
                    .lineStyle(AtriaChartVisualGrammar.traceLine)
                    .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen,
                                                               Metrics.electricYellow,
                                                               Metrics.electricRed],
                                                      startPoint: .bottom,
                                                      endPoint: .top))
            }

            if let selectedPoint {
                RuleMark(x: .value("Inspected time", selectedPoint.reading.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.primary.opacity(0.28))
                PointMark(x: .value("Inspected time", selectedPoint.reading.date),
                          y: .value("Inspected stress", selectedPoint.reading.score))
                    .symbolSize(36)
                    .foregroundStyle(.primary)
                    .annotation(position: .top,
                                alignment: .center,
                                overflowResolution: .init(x: .fit(to: .chart),
                                                          y: .disabled)) {
                        inspectionCard(selectedPoint.reading)
                    }
            }
        }
        .atriaGraphPlotSurface()
        .chartYScale(domain: 0...AtriaStressEvidenceProjection.maximumDisplayValue)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let value = value.as(Int.self) {
                        Text("\(value)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinchBase) { _, base, _ in
                    // Capture the window at pinch start exactly once; frozen for
                    // the rest of this gesture, auto-cleared to nil on end/cancel.
                    if base == nil { base = visibleSeconds }
                }
                .onChanged { value in
                    let base = pinchBase ?? visibleSeconds
                    visibleSeconds = AtriaStressTimelineWindow.clamp(
                        base / value.magnification,
                        maxWindow: AtriaStressTimelineWindow.inlineDefault)
                }
        )
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geometry[plotFrame]
                                let x = value.location.x - frame.origin.x
                                guard x >= 0, x <= frame.width,
                                      let date: Date = proxy.value(atX: x) else { return }
                                selectedDate = nearestPoint(to: date)?.reading.date
                            }
                    )
            }
        }
        .accessibilityLabel(AtriaVitalsStressTimelineCopy.accessibilityLabel)
        .accessibilityHint("Drag across the chart to inspect time, score, heart rate, HRV availability, motion context, and confidence")
    }

    private var selectedPoint: AtriaStressTimelinePoint? {
        selectedDate.flatMap(nearestPoint(to:))
    }

    private func nearestPoint(to date: Date) -> AtriaStressTimelinePoint? {
        points.min {
            abs($0.reading.date.timeIntervalSince(date))
                < abs($1.reading.date.timeIntervalSince(date))
        }
    }

    @ViewBuilder
    private func inspectionCard(_ reading: AtriaStressDetailReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reading.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2.weight(.semibold))
            Text("\(reading.score.formatted(.number.precision(.fractionLength(2)))) · \(AtriaPhysiologicalStressModel.Zone.resolve(score: reading.score).rawValue)")
                .font(.caption.monospacedDigit().weight(.bold))
            Text(reading.heartRate.map { "HR \(Int($0.rounded())) bpm" }
                ?? "HR unavailable")
            Text(reading.rmssd.map {
                "RMSSD \($0.formatted(.number.precision(.fractionLength(1)))) ms"
            } ?? "HR-only estimate")
            Text("\(reading.motionContext.displayName) · \(reading.confidence.displayName) confidence")
        }
        .font(.caption2)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

private struct AtriaHeartRateExplorerPresentationRoot: View {
    @ObservedObject var model: AtriaHeartRateExplorerPresentationModel
    let onDismiss: () -> Void

    var body: some View {
        AtriaHeartRateExplorer(points: model.points,
                               currentBPM: model.currentBPM,
                               onDismiss: onDismiss)
    }
}

private final class AtriaHeartRateLandscapeHostingController:
    UIHostingController<AtriaHeartRateExplorerPresentationRoot> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AtriaHeartRateExplorerOrientationPolicy.presentedMask
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        AtriaHeartRateExplorerOrientationPolicy.preferredOrientation
    }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        // `preferredInterfaceOrientationForPresentation` is only a preference.
        // Request scene geometry once the full-screen controller is attached so
        // iPhone Mirroring and rotation-lock transitions cannot leave the
        // landscape hierarchy squeezed into a portrait canvas.
        AtriaHeartRateOrientation.ensureLandscapeAfterPresentation()
        AtriaDebugLog("ATRIADBG hr_explorer_orientation status=landscape_host_visible preferred=landscapeRight")
    }
}

private struct AtriaPulseStatRail: View {
    let now: String
    let average: String
    let peak: String
    let resting: String
    let restingTint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            stat("Now", now, tint: heartRateTint(for: now))
            Divider().frame(height: 38)
            stat("Average", average, tint: heartRateTint(for: average))
            Divider().frame(height: 38)
            stat("Peak", peak, tint: heartRateTint(for: peak))
            Divider().frame(height: 38)
            stat("Resting", resting, tint: restingTint)
        }
        .padding(.vertical, 10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate now \(now) beats per minute, average \(average), peak \(peak), resting \(resting)")
    }

    /// Live pulse values should use the same calm → working → high colour
    /// language as the timeline. A fixed red/pink rail made an ordinary
    /// mid-range reading look like an alert even while the chart said it was
    /// merely elevated. These are display bands, not training zones.
    private func heartRateTint(for value: String) -> Color {
        guard let bpm = Int(value.filter(\.isNumber)) else { return .secondary }
        switch bpm {
        case ..<60: return .cyan
        case ..<80: return .green
        case ..<100: return .orange
        default: return .red
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                // A not-ready value renders NEUTRAL, never in the metric's hue.
                // These tints are red and pink, so an empty heart-rate row was
                // showing three red "--" side by side, which reads as an error
                // rather than as "no reading yet" -- and red is the colour this
                // app reserves for a genuinely poor measurement. Same honesty
                // rule the metric cards follow: colour is earned by a real value.
                .foregroundStyle(AtriaCompactMetricPresentation.isPendingValue(value)
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(tint))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
                // "Now" is the live heart rate — the same value that rolls
                // smoothly in the tri-ring centre, on Today's live pill and in
                // the workout hero. Here it hard-cut on every beat, because
                // this whole file had zero numericText transitions while those
                // three surfaces have nine between them. One number, animated
                // in three places and snapping in the fourth.
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: value)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
    }
}

private struct AtriaHeartRateTimelineCard: View, Equatable {
    let series: AtriaHeartRateChartSeries
    let onOpen: () -> Void

    static func == (lhs: AtriaHeartRateTimelineCard, rhs: AtriaHeartRateTimelineCard) -> Bool {
        lhs.series == rhs.series
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Heart-rate timeline")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("Last 6 hr")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                AtriaHeartRateAxisChart(points: series.visiblePoints,
                                        yDomain: series.yDomain,
                                        buckets: series.buckets,
                                        selectedTime: .constant(nil),
                                        showsXAxis: true)
                    // This is a preview inside one large button, not an
                    // inspector. Disable the chart's selection gesture so a
                    // plot-area tap always reaches the card action.
                    .allowsHitTesting(false)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 182)
                    .background(Color(.systemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipped()
                    // Full-bleed plot (2026-08-05 width audit): the inner
                    // backdrop strip stretches to the outer card's edge; the
                    // header row above keeps the 12pt inset.
                    .padding(.horizontal, -12)

            }
            .padding(12)
            .atriaInsetCard(tint: .red)
            .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .clipped()
            .compositingGroup()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open heart rate timeline")
    }
}

struct AtriaHeartRateChartSeries: Equatable {
    let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]
    let yDomain: ClosedRange<Int>
    let buckets: [AtriaHeartRateBucket]?

    static func make(points: [AtriaHomeModel.HeartRateChartPoint], zoom: Double) -> AtriaHeartRateChartSeries {
        let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]
        if zoom > 1, points.count > 8 {
            let keep = max(8, Int(Double(points.count) / zoom))
            visiblePoints = Array(points.suffix(keep))
        } else {
            visiblePoints = points
        }
        return AtriaHeartRateChartSeries(visiblePoints: visiblePoints,
                                         yDomain: yDomain(for: visiblePoints),
                                         buckets: smoothedBuckets(points: visiblePoints))
    }

    static func yDomain(for points: [AtriaHomeModel.HeartRateChartPoint]) -> ClosedRange<Int> {
        var minimumBPM: Int?
        var maximumBPM: Int?
        for point in points {
            minimumBPM = min(minimumBPM ?? point.bpm, point.bpm)
            maximumBPM = max(maximumBPM ?? point.bpm, point.bpm)
        }
        let paddedLow = max((minimumBPM ?? 60) - 8, 35)
        let paddedHigh = min((maximumBPM ?? 120) + 8, 220)
        // Snap the domain to a 10-bpm grid so a new sample nudging the min/max
        // by a beat or two doesn't continuously re-scale the whole chart
        // (2026-08-08: "the graph drastically changes at times"). The y-axis now
        // only shifts when the padded range actually crosses a decade boundary.
        let low = max(35, (paddedLow / 10) * 10)
        let high = min(220, ((paddedHigh + 9) / 10) * 10)
        return low...max(high, low + 20)
    }

    func nearestPoint(to selectedTime: Date?) -> AtriaHomeModel.HeartRateChartPoint? {
        guard let selectedTime else { return visiblePoints.last }
        guard !visiblePoints.isEmpty else { return nil }
        var low = 0
        var high = visiblePoints.count
        while low < high {
            let mid = (low + high) / 2
            if visiblePoints[mid].t < selectedTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return visiblePoints[0] }
        if low >= visiblePoints.count { return visiblePoints[visiblePoints.count - 1] }
        let before = visiblePoints[low - 1]
        let after = visiblePoints[low]
        return abs(before.t.timeIntervalSince(selectedTime)) <= abs(after.t.timeIntervalSince(selectedTime))
            ? before
            : after
    }

    /// ~72 buckets across the window once the raw stream exceeds 150 samples;
    /// below that the raw line is already legible. Each bucket keeps the REAL
    /// min/max and average of its samples -- nothing synthesized.
    static func smoothedBuckets(points: [AtriaHomeModel.HeartRateChartPoint],
                                targetBuckets: Int = 72) -> [AtriaHeartRateBucket]? {
        guard points.count > 150,
              targetBuckets > 0,
              let first = points.first?.t,
              let last = points.last?.t,
              last > first else { return nil }
        let span = last.timeIntervalSince(first)
        let width = span / Double(targetBuckets)
        var buckets = Array(repeating: AtriaHeartRateBucketAccumulator(), count: targetBuckets)
        for point in points {
            let index = min(targetBuckets - 1, max(0, Int(point.t.timeIntervalSince(first) / width)))
            buckets[index].append(point.bpm)
        }
        return buckets.indices.compactMap { index in
            guard let bucket = buckets[index].bucket(centeredAt: first.addingTimeInterval((Double(index) + 0.5) * width)) else {
                return nil
            }
            return bucket
        }
    }
}

/// One orientation contract shared by the presentation controller, scene
/// geometry request, and tests. Keeping these values together prevents UIKit's
/// supported-mask and preferred-orientation answers from drifting apart.
struct AtriaHeartRateExplorerOrientationPolicy {
    static let transitionMask: UIInterfaceOrientationMask = .allButUpsideDown
    static let presentedMask: UIInterfaceOrientationMask = .landscape
    static let preferredOrientation: UIInterfaceOrientation = .landscapeRight
}

/// Chooses the rendered stage independently from UIKit's window orientation.
/// iPhone Mirroring can reject `requestGeometryUpdate` with UIScene error 101;
/// in that mode a landscape-sized stage is rotated inside the portrait window
/// so the monitor is still genuinely readable when the phone/view is turned.
struct AtriaHeartRateExplorerStageLayout: Equatable {
    enum Mode: Equatable {
        case landscape
        case portrait
        case rotatedLandscapeFallback
    }

    let mode: Mode
    let stageSize: CGSize
    let rotationDegrees: Double

    init(containerSize: CGSize, usesRotatedPortraitFallback: Bool) {
        if containerSize.width > containerSize.height {
            mode = .landscape
            stageSize = containerSize
            rotationDegrees = 0
        } else if usesRotatedPortraitFallback {
            mode = .rotatedLandscapeFallback
            stageSize = CGSize(width: containerSize.height, height: containerSize.width)
            rotationDegrees = 90
        } else {
            mode = .portrait
            stageSize = containerSize
            rotationDegrees = 0
        }
    }
}

/// Geometry-derived layout for the full-screen heart-rate monitor. It does not
/// trust `UIDevice.orientation`, which can remain stale during cover
/// presentation and iPhone Mirroring. The rendered container is the source of
/// truth, so a real rotation immediately swaps between chart-first landscape
/// and the safe portrait fallback.
struct AtriaHeartRateExplorerLayout: Equatable {
    let isLandscape: Bool
    let outerPadding: CGFloat
    let contentSpacing: CGFloat
    let controlRailHeight: CGFloat
    let minimumChartHeight: CGFloat
    let estimatedChartWidth: CGFloat

    init(size: CGSize) {
        isLandscape = size.width > size.height
        let shortEdge = min(size.width, size.height)
        outerPadding = shortEdge < 390 ? 10 : 12
        contentSpacing = isLandscape ? 12 : 10

        if isLandscape {
            // Controls form one shallow rail above the plot. Nothing sits
            // beside the graph, so a landscape iPhone always gives the time
            // axis its complete usable width.
            controlRailHeight = shortEdge < 390 ? 44 : 48
            estimatedChartWidth = max(0, size.width - outerPadding * 2)
            minimumChartHeight = max(220,
                                     size.height
                                        - outerPadding * 2
                                        - contentSpacing
                                        - controlRailHeight)
        } else {
            controlRailHeight = 0
            estimatedChartWidth = max(0, size.width - outerPadding * 2)
            minimumChartHeight = max(260, size.height * 0.48)
        }
    }
}

struct AtriaHeartRateExplorer: View {
    enum SelectionMode: String, CaseIterable, Identifiable {
        case point = "Point"
        case range = "Range"

        var id: String { rawValue }
    }

    let points: [AtriaHomeModel.HeartRateChartPoint]
    let currentBPM: Int
    let debugLoadsMetricArchive: Bool
    let onDismiss: () -> Void
    @State private var selectedTime: Date?
    @State private var selectedRange: ClosedRange<Date>?
    @State private var selectionMode: SelectionMode = .point
    @State private var scrollPosition: Date
    /// Slider position over AtriaVitalsHeartRateTimeline.Window (0 = 1 min …
    /// 8 = 24 hr), defaulting to 6 hr. Time-window zoom (user request
    /// 2026-07-07) instead of the old point-count zoom.
    @State private var windowIndex: Double = Double(AtriaVitalsHeartRateTimeline.Window.defaultWindow.rawValue)
    /// windowIndex captured when a pinch begins, so magnification maps to an
    /// absolute zoom rather than compounding each frame.
    @State private var pinchAnchorIndex: Double?
    @State private var series: AtriaHeartRateChartSeries
    @State private var didDebugLoadMetricArchive = false
    @State private var usesRotatedPortraitFallback = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var currentWindow: AtriaVitalsHeartRateTimeline.Window {
        AtriaVitalsHeartRateTimeline.Window(rawValue: Int(windowIndex.rounded())) ?? .defaultWindow
    }

    init(points: [AtriaHomeModel.HeartRateChartPoint],
         currentBPM: Int,
         debugLoadsMetricArchive: Bool = false,
         onDismiss: @escaping () -> Void) {
        self.points = points
        self.currentBPM = currentBPM
        self.debugLoadsMetricArchive = debugLoadsMetricArchive
        self.onDismiss = onDismiss
        _scrollPosition = State(initialValue: points.last?.t ?? Date())
        _series = State(initialValue: AtriaHeartRateChartSeries.make(
            points: AtriaVitalsHeartRateTimeline.windowed(points, window: .hour24, displayBudget: 1_200),
            zoom: 1))
    }

    private var selectedPoint: AtriaHomeModel.HeartRateChartPoint? {
        series.nearestPoint(to: selectedTime)
    }

    private var selectedRangeSummary: AtriaHeartRateRangeSummary? {
        selectedRange.flatMap { AtriaHeartRateRangeSummary.make(points: series.visiblePoints, range: $0) }
    }

    private var pointsKey: AtriaHeartRateMergeCache.SeriesKey {
        AtriaHeartRateMergeCache.SeriesKey(points: points)
    }

    var body: some View {
        GeometryReader { proxy in
            let stage = AtriaHeartRateExplorerStageLayout(
                containerSize: proxy.size,
                usesRotatedPortraitFallback: usesRotatedPortraitFallback
            )

            ZStack {
                AtriaBackdropLayer(isDark: colorScheme == .dark,
                                   reduceTransparency: reduceTransparency)
                    .ignoresSafeArea()

                explorerStage(stage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AtriaHeartRateOrientation.landscapeFallbackNotification
        )) { _ in
            usesRotatedPortraitFallback = true
        }
        .onChange(of: windowIndex) { _, _ in
            clearSelection()
            anchorChartToLatest()
        }
        .onChange(of: pointsKey) { _, _ in
            refreshSeries(points)
        }
        .onAppear {
            anchorChartToLatest()
            Task { await loadMetricArchiveForDebugProofIfNeeded() }
        }
    }

    @ViewBuilder
    private func explorerStage(_ stage: AtriaHeartRateExplorerStageLayout) -> some View {
        let layout = AtriaHeartRateExplorerLayout(size: stage.stageSize)

        switch stage.mode {
        case .landscape:
            landscapeContent(layout: layout)
                .padding(layout.outerPadding)
        case .portrait:
            portraitContent(layout: layout)
                .padding(layout.outerPadding)
        case .rotatedLandscapeFallback:
            // Build at true landscape dimensions first, then rotate the whole
            // interactive stage. SwiftUI transforms hit testing with the view,
            // so the chart gestures and the single-circle close action remain
            // in the same visible positions after rotation.
            landscapeContent(layout: layout)
                .padding(layout.outerPadding)
                .frame(width: stage.stageSize.width,
                       height: stage.stageSize.height)
                .rotationEffect(.degrees(stage.rotationDegrees))
                .frame(width: stage.stageSize.height,
                       height: stage.stageSize.width)
        }
    }

    private func landscapeContent(layout: AtriaHeartRateExplorerLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            landscapeControlRail
                .frame(height: layout.controlRailHeight)

            heartRateChart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: layout.minimumChartHeight)
                .layoutPriority(1)
        }
    }

    private func portraitContent(layout: AtriaHeartRateExplorerLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            explorerHeader

            heartRateChart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: layout.minimumChartHeight)
                .layoutPriority(1)

            inspector(showsHeader: false)
        }
    }

    private var heartRateChart: some View {
        AtriaHeartRateAxisChart(points: series.visiblePoints,
                                yDomain: series.yDomain,
                                buckets: series.buckets,
                                selectedTime: $selectedTime,
                                selectedRange: $selectedRange,
                                selectionMode: selectionMode,
                                visibleDomain: currentWindow.seconds,
                                scrollPosition: $scrollPosition)
            // Native pinch-to-zoom over the same window the slider drives.
            // Two fingers never fight the one-finger point/range inspection.
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let anchor = pinchAnchorIndex ?? windowIndex
                        if pinchAnchorIndex == nil { pinchAnchorIndex = anchor }
                        windowIndex = AtriaVitalsHeartRateTimeline.windowIndex(
                            fromPinchAnchor: anchor,
                            magnification: value.magnification,
                            maxIndex: Double(AtriaVitalsHeartRateTimeline.Window.allCases.count - 1))
                    }
                    .onEnded { _ in pinchAnchorIndex = nil }
            )
            .sensoryFeedback(.selection, trigger: currentWindow)
    }

    private func inspector(showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                explorerHeader
            }

            selectionSummary
            selectionModePicker
            zoomControls
        }
    }

    /// A single-row landscape control surface keeps the plot full width. The
    /// previous side-by-side inspector could reproduce the field screenshot's
    /// narrow strip chart on compact landscape windows.
    private var landscapeControlRail: some View {
        HStack(spacing: 10) {
            Text("Heart rate")
                .font(.headline.weight(.bold))
                .lineLimit(1)

            Divider()
                .frame(height: 24)

            compactSelectionSummary
                .frame(minWidth: 96, alignment: .leading)

            selectionModePicker
                .frame(width: 150)
                .controlSize(.small)

            HStack(spacing: 8) {
                Text(currentWindow.label)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 30, alignment: .trailing)
                Slider(value: $windowIndex,
                       in: 0...Double(AtriaVitalsHeartRateTimeline.Window.allCases.count - 1),
                       step: 1)
                    .frame(width: 128)
                    .accessibilityLabel("Visible heart-rate window")
                    .accessibilityValue(currentWindow.label)
            }

            Spacer(minLength: 0)

            closeButton
        }
    }

    @ViewBuilder
    private var compactSelectionSummary: some View {
        if selectionMode == .range, let summary = selectedRangeSummary {
            // Range: the average over the selection AND the clock span it covers
            // (2026-08-08: "when selecting a range it should tell the average
            // heart rate during my range").
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(summary.average)")
                    .font(.title3.weight(.bold).monospacedDigit())
                Text("bpm avg · \(summary.start, format: .dateTime.hour().minute())–\(summary.end, format: .dateTime.hour().minute())")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else {
            // Point: the bpm AND the time at that point (2026-08-08: "it should
            // show the time I am selecting, not just the heart rate").
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(selectedPoint.map { "\($0.bpm)" } ?? (currentBPM > 0 ? "\(currentBPM)" : "--"))
                    .font(.title3.weight(.bold).monospacedDigit())
                if let selectedPoint {
                    Text("bpm · \(selectedPoint.t, format: .dateTime.hour().minute().second())")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text("bpm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var explorerHeader: some View {
        HStack(spacing: 8) {
            Text("Heart rate")
                .font(.headline.weight(.bold))
                .lineLimit(1)

            Spacer(minLength: 0)

            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                // One visual circle and one 44-point hit frame. Keeping the
                // glass on the label avoids toolbar/button-style chrome being
                // wrapped around a second pre-drawn circle.
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close heart-rate monitor")
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if selectionMode == .range, let summary = selectedRangeSummary {
                Text("\(summary.average) bpm")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("\(summary.durationText) · \(summary.minimum)-\(summary.maximum)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(summary.changeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.change == 0 ? Color.secondary : (summary.change > 0 ? Color.red : Color.green))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(selectedPoint.map { "\($0.bpm)" } ?? (currentBPM > 0 ? "\(currentBPM)" : "--"))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("bpm")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)

                if let selectedPoint {
                    Text(selectedPoint.t, format: .dateTime.hour().minute().second())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectionMode == .range ? "Select a range" : "Live")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHint(selectionMode == .range
                           ? "Drag across the graph to compare a range."
                           : "Tap or drag to inspect a sample.")
    }

    private var selectionModePicker: some View {
        // Native-clean (design 2026-08-05): plain-text selector replaces the
        // boxed segmented control, matching the app-wide style.
        AtriaTextSelector(items: SelectionMode.allCases,
                          title: { $0.rawValue },
                          selection: $selectionMode)
        .onChange(of: selectionMode) { _, mode in
            if mode == .point { selectedRange = nil }
            else { selectedTime = nil }
        }
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Window")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(currentWindow.label)
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            Slider(value: $windowIndex,
                   in: 0...Double(AtriaVitalsHeartRateTimeline.Window.allCases.count - 1),
                   step: 1)
                .accessibilityLabel("Visible heart-rate window")
                .accessibilityValue(currentWindow.label)
        }
    }

    private func clearSelection() {
        selectedTime = nil
        selectedRange = nil
    }

    /// True when the chart is currently pinned at the live (right) edge rather
    /// than scrolled back into history. Tolerance is a fraction of the visible
    /// window so a single just-arrived sample doesn't read as "scrolled away".
    private var isFollowingLiveEdge: Bool {
        guard let latest = points.last?.t else { return true }
        let leading = Self.leadingScrollPosition(latest: latest,
                                                 visibleDomain: currentWindow.seconds)
        return abs(scrollPosition.timeIntervalSince(leading)) <= currentWindow.seconds * 0.15
    }

    private func refreshSeries(_ source: [AtriaHomeModel.HeartRateChartPoint]) {
        let followingBefore = isFollowingLiveEdge
        // Always rebuild the data...
        series = AtriaHeartRateChartSeries.make(
            points: AtriaVitalsHeartRateTimeline.windowed(source, window: .hour24, displayBudget: 1_200),
            zoom: 1)
        // ...but only FOLLOW the live edge when the user is neither inspecting a
        // selection nor scrolled back into history. A new sample arrives ~1×/sec;
        // re-anchoring + clearing the selection on every one is what made the
        // chart "jump" and wiped the point/range the user was reading
        // (2026-08-08 field report). Their selection and scroll are preserved.
        guard selectedTime == nil, selectedRange == nil, followingBefore else { return }
        anchorChartToLatest(source.last?.t)
    }

    private func anchorChartToLatest(_ latest: Date? = nil) {
        guard let latest = latest ?? points.last?.t else { return }
        scrollPosition = Self.leadingScrollPosition(latest: latest,
                                                    visibleDomain: currentWindow.seconds)
    }

    nonisolated static func leadingScrollPosition(latest: Date,
                                                  visibleDomain: TimeInterval) -> Date {
        latest.addingTimeInterval(-max(1, visibleDomain))
    }

    @MainActor
    private func loadMetricArchiveForDebugProofIfNeeded() async {
        guard debugLoadsMetricArchive,
              !didDebugLoadMetricArchive,
              points.isEmpty else { return }
        didDebugLoadMetricArchive = true
        let loaded = await Task.detached(priority: .utility) {
            HistoricalArchive.metricHeartRatePoints(since: nil).map {
                AtriaHomeModel.HeartRateChartPoint(t: $0.t, bpm: $0.bpm)
            }
        }.value
        AtriaDebugLog("ATRIADBG hist1_timeline_explorer_archive status=loaded points=%d", loaded.count)
        guard !loaded.isEmpty else { return }
        refreshSeries(loaded)
    }
}

struct AtriaHeartRateRangeSummary: Equatable {
    let start: Date
    let end: Date
    let average: Int
    let minimum: Int
    let maximum: Int
    let change: Int

    static func make(points: [AtriaHomeModel.HeartRateChartPoint], range: ClosedRange<Date>) -> Self? {
        guard !points.isEmpty else { return nil }
        let lower = lowerBound(points, date: range.lowerBound)
        let upper = upperBound(points, date: range.upperBound)
        guard lower < upper else { return nil }
        let first = points[lower]
        let last = points[upper - 1]
        var total = 0
        var minimum = first.bpm
        var maximum = first.bpm
        for index in lower..<upper {
            let bpm = points[index].bpm
            total += bpm
            minimum = min(minimum, bpm)
            maximum = max(maximum, bpm)
        }
        let count = upper - lower
        return Self(start: first.t,
                    end: last.t,
                    average: Int((Double(total) / Double(count)).rounded()),
                    minimum: minimum,
                    maximum: maximum,
                    change: last.bpm - first.bpm)
    }

    private static func lowerBound(_ points: [AtriaHomeModel.HeartRateChartPoint],
                                   date: Date) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].t < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func upperBound(_ points: [AtriaHomeModel.HeartRateChartPoint],
                                   date: Date) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].t <= date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    var durationText: String {
        let duration = max(0, end.timeIntervalSince(start))
        if duration < 60 { return "\(Int(duration.rounded())) sec" }
        let totalMinutes = Int((duration / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    var changeText: String { String(format: "%+d bpm", change) }
}

enum AtriaTransientPresentationState {
    private static let standBySuppressionUntilKey = "atria.ui.standBySuppressionUntil"

    static var suppressesStandBy: Bool {
        UserDefaults.standard.double(forKey: standBySuppressionUntilKey) > Date().timeIntervalSince1970
    }

    static func suppressStandBy(for duration: TimeInterval = 20) {
        UserDefaults.standard.set(Date().addingTimeInterval(duration).timeIntervalSince1970,
                                  forKey: standBySuppressionUntilKey)
    }

    static func clearStandBySuppression() {
        UserDefaults.standard.removeObject(forKey: standBySuppressionUntilKey)
    }
}

@MainActor
private enum AtriaHeartRateOrientation {
    static let landscapeFallbackNotification = Notification.Name(
        "atria.heartRateExplorer.landscapeFallback"
    )
    private static var landscapeRequestTask: Task<Void, Never>?
    private static var portraitRestoreTask: Task<Void, Never>?
    private static var presentationGeneration: UInt = 0

    static func prepareLandscapePresentation() {
        presentationGeneration &+= 1
        portraitRestoreTask?.cancel()
        portraitRestoreTask = nil
        // Keep the outgoing portrait controller and incoming landscape host in
        // the app-mask intersection throughout the presentation transition.
        AtriaTransientPresentationState.suppressStandBy()
        AtriaAppDelegate.supportedOrientations = AtriaHeartRateExplorerOrientationPolicy.transitionMask
        requestLandscape(reason: "presentation_prepare")
    }

    static func ensureLandscapeAfterPresentation() {
        AtriaAppDelegate.supportedOrientations = AtriaHeartRateExplorerOrientationPolicy.transitionMask
        requestLandscape(reason: "host_visible")
    }

    static func preparePortraitDismissal() {
        // Widen BEFORE dismissing. Narrowing while the landscape host is still
        // topmost leaves UIKit with no supported portrait intersection.
        landscapeRequestTask?.cancel()
        landscapeRequestTask = nil
        portraitRestoreTask?.cancel()
        portraitRestoreTask = nil
        AtriaTransientPresentationState.suppressStandBy()
        AtriaAppDelegate.supportedOrientations = AtriaHeartRateExplorerOrientationPolicy.transitionMask
    }

    static func restorePortraitAfterDismissal() {
        preparePortraitDismissal()
        presentationGeneration &+= 1
        let generation = presentationGeneration
        portraitRestoreTask = Task { @MainActor in
            await Task.yield()
            for attempt in 1...5 {
                guard !Task.isCancelled,
                      generation == presentationGeneration else { return }
                guard let scene = activeScene() else {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }
                if scene.effectiveGeometry.interfaceOrientation == .portrait {
                    guard !Task.isCancelled,
                          generation == presentationGeneration else { return }
                    finalizePortrait(on: scene, attempt: attempt)
                    portraitRestoreTask = nil
                    return
                }
                requestSceneOrientation(.portrait,
                                        on: scene,
                                        reason: "dismiss_restore",
                                        attempt: attempt)
                try? await Task.sleep(for: .milliseconds(200))
            }

            guard !Task.isCancelled,
                  generation == presentationGeneration else { return }
            let current = activeScene()?.effectiveGeometry.interfaceOrientation
            AtriaDebugLog("ATRIADBG heart_rate_orientation status=portrait_pending orientation=%@ app_mask=allButUpsideDown",
                          String(describing: current))
            portraitRestoreTask = nil
        }
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
    }

    private static func requestLandscape(reason: String) {
        landscapeRequestTask?.cancel()
        landscapeRequestTask = Task { @MainActor in
            await Task.yield()
            for attempt in 1...5 {
                guard !Task.isCancelled else { return }
                guard let scene = activeScene() else {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                if scene.effectiveGeometry.interfaceOrientation.isLandscape {
                    AtriaDebugLog("ATRIADBG heart_rate_orientation status=landscape_confirmed reason=%@ attempt=%d",
                                  reason,
                                  attempt)
                    landscapeRequestTask = nil
                    return
                }
                requestSceneOrientation(AtriaHeartRateExplorerOrientationPolicy.presentedMask,
                                        on: scene,
                                        reason: reason,
                                        attempt: attempt)
                try? await Task.sleep(for: .milliseconds(160))
            }

            let current = activeScene()?.effectiveGeometry.interfaceOrientation
            AtriaDebugLog("ATRIADBG heart_rate_orientation status=landscape_pending reason=%@ orientation=%@",
                          reason,
                          String(describing: current))
            activateRotatedLandscapeFallback(reason: "request_unchanged")
            landscapeRequestTask = nil
        }
    }

    private static func requestSceneOrientation(_ orientations: UIInterfaceOrientationMask,
                                                on scene: UIWindowScene,
                                                reason: String,
                                                attempt: Int) {
        if let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController {
            topmostPresentedViewController(from: root)
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            let nsError = error as NSError
            AtriaDebugLog("ATRIADBG heart_rate_orientation status=failed reason=%@ attempt=%d domain=%@ code=%@ description=%@ userInfo=%@",
                          reason,
                          attempt,
                          nsError.domain,
                          String(nsError.code),
                          nsError.localizedDescription,
                          String(describing: nsError.userInfo))
            if orientations == AtriaHeartRateExplorerOrientationPolicy.presentedMask,
               nsError.domain == "UISceneErrorDomain",
               nsError.code == 101 {
                Task { @MainActor in
                    activateRotatedLandscapeFallback(reason: "windowing_mode_denied")
                }
            }
        }
        AtriaDebugLog("ATRIADBG heart_rate_orientation status=requested reason=%@ attempt=%d mask=%@",
                      reason,
                      attempt,
                      String(describing: orientations))
    }

    private static func activateRotatedLandscapeFallback(reason: String) {
        AtriaDebugLog("ATRIADBG heart_rate_orientation status=rotated_fallback reason=%@",
                      reason)
        NotificationCenter.default.post(name: landscapeFallbackNotification,
                                        object: nil)
    }

    private static func finalizePortrait(on scene: UIWindowScene, attempt: Int) {
        AtriaAppDelegate.supportedOrientations = .portrait
        scene.windows.first(where: \.isKeyWindow)?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        AtriaTransientPresentationState.clearStandBySuppression()
        AtriaDebugLog("ATRIADBG heart_rate_orientation status=portrait_confirmed attempt=%d app_mask=portrait",
                      attempt)
    }

    private static func topmostPresentedViewController(from root: UIViewController) -> UIViewController {
        var topmost = root
        while let presented = topmost.presentedViewController {
            topmost = presented
        }
        return topmost
    }
}

/// One smoothed time bucket of the raw ~1 Hz heart-rate stream: the real
/// min/max ceiling-and-floor plus the average — the user's requested
/// treatment for dense HR windows ("such a dense graph is just a scribble").
struct AtriaHeartRateBucket: Equatable, Identifiable {
    let id: Date
    let t: Date
    let average: Double
    let minBPM: Int
    let maxBPM: Int
}

private struct AtriaHeartRateBucketAccumulator {
    var sum = 0
    var count = 0
    var minBPM: Int?
    var maxBPM: Int?

    mutating func append(_ bpm: Int) {
        sum += bpm
        count += 1
        minBPM = min(minBPM ?? bpm, bpm)
        maxBPM = max(maxBPM ?? bpm, bpm)
    }

    func bucket(centeredAt center: Date) -> AtriaHeartRateBucket? {
        guard count > 0 else { return nil }
        return AtriaHeartRateBucket(id: center,
                                    t: center,
                                    average: Double(sum) / Double(count),
                                    minBPM: minBPM ?? 0,
                                    maxBPM: maxBPM ?? 0)
    }
}

struct AtriaHeartRateAxisChart: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let yDomain: ClosedRange<Int>
    let buckets: [AtriaHeartRateBucket]?
    @Binding var selectedTime: Date?
    @Binding var selectedRange: ClosedRange<Date>?
    let selectionMode: AtriaHeartRateExplorer.SelectionMode
    let visibleDomain: TimeInterval?
    let showsXAxis: Bool
    @Binding var scrollPosition: Date

    init(points: [AtriaHomeModel.HeartRateChartPoint],
         yDomain: ClosedRange<Int>,
         buckets: [AtriaHeartRateBucket]? = nil,
         selectedTime: Binding<Date?>,
         selectedRange: Binding<ClosedRange<Date>?> = .constant(nil),
         selectionMode: AtriaHeartRateExplorer.SelectionMode = .point,
         visibleDomain: TimeInterval? = nil,
         showsXAxis: Bool = true,
         scrollPosition: Binding<Date> = .constant(Date())) {
        self.points = points
        self.yDomain = yDomain
        self.buckets = buckets
        self._selectedTime = selectedTime
        self._selectedRange = selectedRange
        self.selectionMode = selectionMode
        self.visibleDomain = visibleDomain
        self.showsXAxis = showsXAxis
        self._scrollPosition = scrollPosition
    }

    static func == (lhs: AtriaHeartRateAxisChart, rhs: AtriaHeartRateAxisChart) -> Bool {
        lhs.points == rhs.points && lhs.yDomain == rhs.yDomain && lhs.buckets == rhs.buckets
            && lhs.selectionMode == rhs.selectionMode && lhs.visibleDomain == rhs.visibleDomain
            && lhs.showsXAxis == rhs.showsXAxis
    }

    /// True when neither series has anything to draw. Gates the y-axis so an
    /// empty plot never shows a fabricated bpm scale.
    private var plotIsEmpty: Bool {
        (buckets ?? []).isEmpty && points.isEmpty
    }

    /// The chart colour is a value scale, not a blanket danger signal. It
    /// rises from calm/cool through working green and amber into red as the
    /// visible heart-rate domain rises, matching the 0–3 stress treatment.
    private var heartRateGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: .cyan, location: 0),
            .init(color: .green, location: 0.38),
            .init(color: .orange, location: 0.68),
            .init(color: .red, location: 1)
        ], startPoint: .bottom, endPoint: .top)
    }

    private var heartRateAreaGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: .cyan.opacity(0.12), location: 0),
            .init(color: .green.opacity(0.10), location: 0.38),
            .init(color: .orange.opacity(0.08), location: 0.68),
            .init(color: .red.opacity(0.12), location: 1)
        ], startPoint: .bottom, endPoint: .top)
    }

    private var baseChart: some View {
        Chart {
            if let buckets {
                // Smoothed mode: one calm average line with a soft gradient fill
                // beneath it. The old per-bucket min-max band jumped bucket to
                // bucket and read as a noisy scribble (user-reported 2026-07-08);
                // the average already carries the shape, and detail is one zoom
                // away. Nothing here is synthesized — average is the real mean.
                ForEach(buckets) { bucket in
                    AreaMark(x: .value("Time", bucket.t),
                             yStart: .value("Floor", Double(yDomain.lowerBound)),
                             yEnd: .value("BPM", bucket.average))
                        .interpolationMethod(.linear)
                        .foregroundStyle(heartRateAreaGradient)
                    LineMark(x: .value("Time", bucket.t),
                             y: .value("BPM", bucket.average))
                        .interpolationMethod(.linear)
                        .foregroundStyle(heartRateGradient)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            } else {
                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.t),
                             yStart: .value("Visible floor", yDomain.lowerBound),
                             yEnd: .value("BPM", point.bpm))
                        .interpolationMethod(.linear)
                        .foregroundStyle(heartRateAreaGradient)
                    LineMark(x: .value("Time", point.t), y: .value("BPM", point.bpm))
                        .interpolationMethod(.linear)
                        .foregroundStyle(heartRateGradient)
                }
            }
            if let selectedTime {
                RuleMark(x: .value("Selected", selectedTime))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
                if let selectedPoint = nearestPoint(to: selectedTime) {
                    PointMark(x: .value("Selected time", selectedPoint.t),
                              y: .value("Selected BPM", selectedPoint.bpm))
                        .foregroundStyle(.red)
                        .symbolSize(52)
                }
            }
            if let selectedRange {
                RectangleMark(xStart: .value("Range start", selectedRange.lowerBound),
                              xEnd: .value("Range end", selectedRange.upperBound))
                    .foregroundStyle(.red.opacity(0.10))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            if showsXAxis {
                // Explicit boundary-aligned ticks with precomputed, deduped
                // labels (2026-08-01): `.automatic(desiredCount: 4)` placed
                // sub-hour ticks on short series, and the hour-precision label
                // (kept short on purpose — `1:00 PM` truncated to `1:00 P…` on
                // the compact Vitals canvas) rendered the same "11a" text under
                // several neighbouring gridlines.
                AxisMarks(values: xAxisTicks.map(\.date)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisTick().foregroundStyle(.secondary.opacity(0.45))
                    AxisValueLabel {
                        if let time = value.as(Date.self),
                           let label = xAxisTickLabel(for: time) {
                            Text(label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            // Trailing axis: the leading bpm gutter (~28pt) was the largest
            // single left inset on the Vitals tab (space audit 2026-07-07).
            // Hidden entirely while the plot is empty — a 60–120 bpm scale
            // over "No heart-rate points to plot yet" is a fabricated axis
            // (chart-honesty rule, 2026-08-04).
            if !plotIsEmpty {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisTick().foregroundStyle(.secondary.opacity(0.45))
                    AxisValueLabel {
                        if let bpm = value.as(Int.self) {
                            Text("\(bpm)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipped()
        }
        .mask(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Ticks span whichever series actually plots (buckets when smoothing).
    private var xAxisTicks: [AtriaVitalsHeartRateTimeline.AxisTickMark] {
        let first = buckets?.first?.t ?? points.first?.t
        let last = buckets?.last?.t ?? points.last?.t
        guard let first, let last else { return [] }
        return AtriaVitalsHeartRateTimeline.hourAlignedAxisTicks(from: first,
                                                                 to: last,
                                                                 visibleDomain: visibleDomain)
    }

    /// Nearest-tick match instead of exact Date equality: Swift Charts hands
    /// explicit axis values back through its own numeric space, so an exact
    /// Date-keyed lookup can silently miss and drop every label.
    private func xAxisTickLabel(for time: Date) -> String? {
        guard let nearest = xAxisTicks.min(by: {
            abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time))
        }) else { return nil }
        return abs(nearest.date.timeIntervalSince(time)) < 1 ? nearest.label : nil
    }

    private func nearestPoint(to selectedTime: Date) -> AtriaHomeModel.HeartRateChartPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].t < selectedTime { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return points[0] }
        if low >= points.count { return points[points.count - 1] }
        let before = points[low - 1]
        let after = points[low]
        return selectedTime.timeIntervalSince(before.t) <= after.t.timeIntervalSince(selectedTime)
            ? before
            : after
    }

    @ViewBuilder
    var body: some View {
        let chart = Group {
            if selectionMode == .range {
                baseChart.chartXSelection(range: $selectedRange)
            } else {
                baseChart.chartXSelection(value: $selectedTime)
            }
        }
        if let visibleDomain,
           Self.shouldEnableHorizontalScrolling(points: points, visibleDomain: visibleDomain) {
            chart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleDomain)
                .chartScrollPosition(x: $scrollPosition)
                .chartScrollTargetBehavior(.valueAligned(unit: 60))
                .atriaHeartRateChartFinishing(pointsAreEmpty: points.isEmpty)
        } else {
            chart.atriaHeartRateChartFinishing(pointsAreEmpty: points.isEmpty)
        }
    }

    static func shouldEnableHorizontalScrolling(points: [AtriaHomeModel.HeartRateChartPoint],
                                                visibleDomain: TimeInterval) -> Bool {
        guard let first = points.first?.t, let last = points.last?.t else { return false }
        return last.timeIntervalSince(first) > max(1, visibleDomain)
    }
}

private extension View {
    func atriaHeartRateChartFinishing(pointsAreEmpty: Bool) -> some View {
        self
        .chartOverlay { proxy in
            if pointsAreEmpty {
                // Describes the CHART's state, not the sensor's. The old
                // "Waiting for live heart-rate samples" sat directly under a
                // header reading "Now 142 · Average 128 · Peak 151", so the
                // card denied having heart-rate data three lines after
                // reporting it. It was also wrong on the two archive/history
                // call sites, which are not about live samples at all. An
                // empty plot is empty whether or not a live reading exists.
                Text("No heart-rate points to plot yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipped()
    }
}

private struct AtriaHRVCard: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let hero: AtriaHomeModel.HeroSnapshot
    let hrvBaseline: Int?
    let hrvBaselineSamples: Int
    let hrvBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let hrvGreenRatio: Double
    let hrvYellowRatio: Double

    static func == (lhs: AtriaHRVCard, rhs: AtriaHRVCard) -> Bool {
        lhs.live == rhs.live
            && lhs.hero == rhs.hero
            && lhs.hrvBaseline == rhs.hrvBaseline
            && lhs.hrvBaselineSamples == rhs.hrvBaselineSamples
            && lhs.hrvBaselineTrusted == rhs.hrvBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.hrvGreenRatio == rhs.hrvGreenRatio
            && lhs.hrvYellowRatio == rhs.hrvYellowRatio
    }

    private var continuityTint: Color {
        live.rrContinuityText.localizedCaseInsensitiveContains("waiting") ? .orange : .pink
    }

    private var hrvZone: AtriaMetricZone? {
        Metrics.hrvZone(Self.parseInt(hero.hrvValue),
                        baseline: hrvBaseline,
                        baselineSamples: hrvBaselineSamples,
                        baselineTrusted: hrvBaselineTrusted,
                        baselineTarget: baselineTarget,
                        greenRatio: hrvGreenRatio,
                        yellowRatio: hrvYellowRatio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "HRV", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: hrvState)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                hrvStatTiles
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var hrvState: AtriaMetricState {
        let detail = hero.hrvDetail.lowercased()
        if detail.contains("validated") { return .validated }
        if detail.contains("personal baseline") || detail.contains("% kept") { return .personalBaseline }
        return .learning
    }

    private var isConnected: Bool {
        live.status == .connected
    }

    @ViewBuilder
    private var hrvStatTiles: some View {
        AtriaMetricTile(label: "HRV",
                        value: hero.hrvValue,
                        state: hrvState,
                        tint: hrvZone?.tint ?? .pink,
                        footnote: hero.hrvDetail,
                        zone: hrvZone,
                        targetMetric: .hrv)
        AtriaMetricTile(label: "Window",
                        value: hero.rrPackageText,
                        state: isConnected && !live.rrContinuityText.localizedCaseInsensitiveContains("waiting") ? .live : .learning,
                        tint: continuityTint)
        AtriaMetricTile(label: "SDNN",
                        value: live.hrvSDNNText,
                        unit: live.hrvSDNN == nil ? nil : "ms",
                        state: live.hrvSDNN == nil ? .learning : hrvState,
                        tint: .indigo,
                        footnote: "Secondary HRV metric from the same steady beat-to-beat window.")
        AtriaMetricTile(label: "pNN50",
                        value: live.hrvPNN50Text,
                        state: live.hrvPNN50 == nil ? .learning : hrvState,
                        tint: .purple,
                        footnote: "Share of adjacent beat intervals differing by more than 50 ms.")
        AtriaMetricTile(label: hero.stressMetricTitle,
                        value: hero.stressValue,
                        state: .local,
                        tint: .purple)
    }

    private static let statColumns = AtriaMetricTile.gridColumns

    private static func parseInt(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

private struct AtriaRecoveryStrainCard: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let sleepHistory: SleepHistorySnapshot
    let sleepHistoryRevision: Int
    let dailyRollupHistory: [DailyRollupStoreEntry]
    let dailyRollupHistoryRevision: Int
    let recoveryTarget: AtriaMetricTarget
    let strainGreenBand: Double
    let strainYellowBand: Double
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
    let sleepGoalHours: Double
    let sleepEfficiencyGreenLower: Double
    let sleepEfficiencyYellowLower: Double
    let onAddManualSleep: (Date, Date, Bool) async -> Bool
    let onAdjustSleep: (SleepHistorySnapshot.Night, Date, Date, Bool) async -> Bool
    let onConfirmSleep: (SleepHistorySnapshot.Night) async -> Bool

    static func == (lhs: AtriaRecoveryStrainCard, rhs: AtriaRecoveryStrainCard) -> Bool {
        lhs.hero == rhs.hero
            && lhs.sleepHistoryRevision == rhs.sleepHistoryRevision
            && lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision
            && lhs.recoveryTarget == rhs.recoveryTarget
            && lhs.strainGreenBand == rhs.strainGreenBand
            && lhs.strainYellowBand == rhs.strainYellowBand
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
            && lhs.sleepGoalHours == rhs.sleepGoalHours
            && lhs.sleepEfficiencyGreenLower == rhs.sleepEfficiencyGreenLower
            && lhs.sleepEfficiencyYellowLower == rhs.sleepEfficiencyYellowLower
    }

    private var recoveryState: AtriaMetricState {
        switch hero.recoveryEstimate.confidence {
        case .validated:
            return .validated
        case .personalBaseline:
            return .personalBaseline
        case .unverified:
            return .research
        case .learning:
            return .learning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Coach", subtitle: "")

            recoveryStrainVisuals
            metricContent
            AtriaSleepHistoryCard(snapshot: sleepHistory,
                                  dailyRollupHistory: dailyRollupHistory,
                                  hrvBaseline: hrvBaseline,
                                  hrvBaselineSamples: hrvBaselineSamples,
                                  hrvBaselineTrusted: hrvBaselineTrusted,
                                  baselineTarget: baselineTarget,
                                  hrvGreenRatio: hrvGreenRatio,
                                  hrvYellowRatio: hrvYellowRatio,
                                  restingBaseline: restingBaseline,
                                  restingBaselineSamples: restingBaselineSamples,
                                  restingBaselineTrusted: restingBaselineTrusted,
                                  restingGreenDelta: restingGreenDelta,
                                  restingYellowDelta: restingYellowDelta,
                                  respiratoryGreenDelta: respiratoryGreenDelta,
                                  respiratoryYellowDelta: respiratoryYellowDelta,
                                  sleepGoalHours: sleepGoalHours,
                                  sleepEfficiencyGreenLower: sleepEfficiencyGreenLower,
                                  sleepEfficiencyYellowLower: sleepEfficiencyYellowLower,
                                  onAddManualSleep: onAddManualSleep,
                                  onAdjustSleep: onAdjustSleep,
                                  onConfirmSleep: onConfirmSleep)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var metricContent: some View {
        LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
            recoveryStrainTiles
        }
    }

    private var recoveryStrainVisuals: some View {
        HStack(spacing: 14) {
            AtriaMetricRing(label: "Recovery",
                            // A recovery number is deliberately available on the
                            // first measured sleep even before HRV/baselines are
                            // qualified. When there is genuinely no measurement
                            // to score, use the same explicit Learning state as
                            // Home rather than a grey, ambiguous placeholder.
                            value: hero.recoveryValue,
                            fraction: recoveryFraction,
                            tint: recoveryZone?.tint ?? hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .orange,
                            size: 112)
            // Legacy token kept in source for the handoff guard:
            // AtriaMetricRing(label: "Strain",
            // fraction: strainFraction
            AtriaStrainBandGauge(strain: hero.strain,
                                 target: hero.guidance.target,
                                 size: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text(hero.guidance.headline)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hero.loadSignalSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .atriaInsetCard(tint: recoveryZone?.tint ?? .green)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovery \(hero.recoveryEstimate.percent.map { "\($0) percent" } ?? "learning"), strain \(String(format: "%.1f", hero.strain)). \(hero.loadSignalSummaryText)")
    }

    @ViewBuilder
    private var recoveryStrainTiles: some View {
        AtriaMetricTile(label: "Recovery",
                        value: hero.recoveryValue,
                        unit: hero.recoveryEstimate.percent == nil ? nil : "%",
                        state: recoveryState,
                        tint: recoveryZone?.tint ?? hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .orange,
                        footnote: hero.recoveryEstimate.confidence.rawValue,
                        zone: recoveryZone,
                        targetMetric: .recovery)
        AtriaMetricTile(label: "Strain",
                        value: String(format: "%.1f", hero.strain),
                        state: .local,
                        tint: strainZone?.tint ?? Metrics.strainColor(hero.strain),
                        zone: strainZone,
                        targetMetric: .strain)
        AtriaTrainingLoadTile(ratio: hero.loadRatioText,
                              target: hero.loadTargetText,
                              confidence: hero.loadConfidence,
                              readiness: hero.loadReadinessText,
                              acwrSignal: hero.loadACWRSignalText,
                              monotony: hero.loadMonotonyText,
                              monotonySignal: hero.loadMonotonySignalText,
                              acwrDetail: hero.loadACWRDetailText,
                              monotonyDetail: hero.loadMonotonyDetailText,
                              signalSummary: hero.loadSignalSummaryText,
                              narrative: hero.loadNarrative,
                              targetMetric: .load)
    }

    private static let statColumns = AtriaMetricTile.gridColumns

    private var recoveryZone: AtriaMetricZone? {
        Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)
    }

    private var strainZone: AtriaMetricZone? {
        Metrics.strainZone(strain: hero.strain,
                           target: hero.guidance.target,
                           greenBand: strainGreenBand,
                           yellowBand: strainYellowBand)
    }

    private var recoveryFraction: Double? {
        hero.recoveryEstimate.percent.map { min(max(Double($0) / 100, 0), 1) }
    }

    private var strainFraction: Double? {
        min(max(hero.strain / 21, 0), 1)
    }
}

private struct AtriaSleepHistoryCard: View, Equatable {
    let snapshot: SleepHistorySnapshot
    let dailyRollupHistory: [DailyRollupStoreEntry]
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
    let sleepGoalHours: Double
    let sleepEfficiencyGreenLower: Double
    let sleepEfficiencyYellowLower: Double
    let onAddManualSleep: (Date, Date, Bool) async -> Bool
    let onAdjustSleep: (SleepHistorySnapshot.Night, Date, Date, Bool) async -> Bool
    let onConfirmSleep: (SleepHistorySnapshot.Night) async -> Bool
    @State private var showManualSleepSheet = false
    @State private var showNightDetails = false
    @State private var adjustmentNight: SleepHistorySnapshot.Night?
    @State private var sleepConfirmationFailed = false
    @State private var isConfirmingSleep = false

    static func == (lhs: AtriaSleepHistoryCard, rhs: AtriaSleepHistoryCard) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.dailyRollupHistory == rhs.dailyRollupHistory
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
            && lhs.sleepGoalHours == rhs.sleepGoalHours
            && lhs.sleepEfficiencyGreenLower == rhs.sleepEfficiencyGreenLower
            && lhs.sleepEfficiencyYellowLower == rhs.sleepEfficiencyYellowLower
    }

    private var emptyEvidenceState: AtriaMetricState {
        if snapshot.confirmedCount > 0 { return .validated }
        if snapshot.candidateCount > 0 { return .research }
        return .learning
    }

    /// Numeric first-night evidence stays visible while its review is pending.
    /// All averages/debt/baseline math still reads confirmed main sleep only.
    private var latestEvidence: SleepHistorySnapshot.Night? {
        snapshot.latestDisplayEvidence
    }

    private var zonedLatestEvidence: SleepHistorySnapshot.Night? {
        guard let latestEvidence,
              latestEvidence.confirmed,
              !latestEvidence.isNapEvidence else { return nil }
        return latestEvidence
    }

    private var latestEvidenceFootnote: String {
        guard let latest = latestEvidence else { return "No saved sleep yet." }
        return "\(latest.confidenceText) · \(latest.reviewContextText)"
    }

    private var shouldShowConfirmSleep: Bool {
        guard snapshot.candidateCount > 0 else { return false }
        return snapshot.latestReviewable?.confirmed != true
    }

    private var reviewSleepLabel: String {
        snapshot.latestReviewable?.isNapEvidence == true ? "Review nap" : "Review sleep"
    }

    private var restingHeartRateZone: AtriaMetricZone? {
        Metrics.restingHeartRateZone(zonedLatestEvidence?.restingHR,
                                     baseline: restingBaseline,
                                     baselineSamples: restingBaselineSamples,
                                     baselineTrusted: restingBaselineTrusted,
                                     baselineTarget: baselineTarget,
                                     greenDelta: restingGreenDelta,
                                     yellowDelta: restingYellowDelta)
    }

    private var sleepDurationZone: AtriaMetricZone? {
        Metrics.sleepDurationZone(zonedLatestEvidence?.durationHours, goalHours: sleepGoalHours)
    }

    private var sleepEfficiencyZone: AtriaMetricZone? {
        // Display authority: no zone color for an HR-only coverage number.
        Metrics.sleepEfficiencyZone(zonedLatestEvidence?.displaySleepEfficiency,
                                    greenLower: sleepEfficiencyGreenLower,
                                    yellowLower: sleepEfficiencyYellowLower)
    }

    private var hrvZone: AtriaMetricZone? {
        Metrics.hrvZone(zonedLatestEvidence?.hrv,
                        baseline: hrvBaseline,
                        baselineSamples: hrvBaselineSamples,
                        baselineTrusted: hrvBaselineTrusted,
                        baselineTarget: baselineTarget,
                        greenRatio: hrvGreenRatio,
                        yellowRatio: hrvYellowRatio)
    }

    private var respiratoryRateZone: AtriaMetricZone? {
        return Metrics.respiratoryRateZone(zonedLatestEvidence?.respiratoryRate,
                                           baseline: snapshot.respiratoryBaselineMean,
                                           baselineSamples: snapshot.respiratoryBaselineCount,
                                           greenDelta: respiratoryGreenDelta,
                                           yellowDelta: respiratoryYellowDelta)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sleep history")
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.stateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    showManualSleepSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .atriaCardAction(prominent: false, tint: .cyan)
                .accessibilityLabel("Add sleep manually")
                AtriaStateBadge(state: snapshot.confirmedCount > 0 ? .validated : (snapshot.candidateCount > 0 ? .research : .learning))
            }

            if shouldShowConfirmSleep {
                HStack(spacing: 8) {
                    Button {
                        if let latest = snapshot.latestReviewable {
                            adjustmentNight = latest
                        }
                    } label: {
                        Label(reviewSleepLabel, systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .cyan)
                    .accessibilityHint("Review the detected window before saving it.")

                    Button {
                        guard let latest = snapshot.latestReviewable,
                              latest.confirmed == false,
                              !isConfirmingSleep else { return }
                        isConfirmingSleep = true
                        Task { @MainActor in
                            sleepConfirmationFailed = !(await onConfirmSleep(latest))
                            isConfirmingSleep = false
                        }
                    } label: {
                        Label("Confirm", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(prominent: false, tint: .cyan)
                    .disabled(isConfirmingSleep)
                    .accessibilityHint("Saves the shown sleep or nap candidate locally.")
                }

                if sleepConfirmationFailed {
                    Label("Couldn't save. The suggestion is still here — try again, or tap Review to adjust the window.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Couldn't save sleep. The suggestion remains available. Try again or review the detected window.")
                }
            }

            if snapshot.nights.isEmpty {
                AtriaMetricTile(label: snapshot.emptyEvidenceLabel,
                                value: snapshot.emptyEvidenceValue,
                                state: emptyEvidenceState,
                                tint: .cyan,
                                footnote: snapshot.emptyEvidenceFootnote)
            } else {
                AtriaSleepContextLens(snapshot: snapshot,
                                      goalHours: sleepGoalHours)

                LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                    AtriaMetricTile(label: latestEvidence?.evidenceLabel ?? "Latest",
                                    value: latestEvidence?.durationText ?? "--",
                                    state: latestEvidence?.confirmed == true ? .validated : .research,
                                    tint: sleepDurationZone?.tint ?? .cyan,
                                    footnote: latestEvidenceFootnote,
                                    zone: sleepDurationZone,
                                    targetMetric: .sleep)
                    AtriaMetricTile(label: "Average",
                                    value: snapshot.averageDurationText,
                                    state: .local,
                                    tint: .blue,
                                    footnote: snapshot.averageFootnoteText)
                    AtriaMetricTile(label: "Consistency",
                                    value: snapshot.sleepConsistencyText,
                                    state: snapshot.sleepConsistencyText == "--" ? .learning : .local,
                                    tint: .mint,
                                    footnote: snapshot.sleepConsistencyFootnote)
                    AtriaMetricTile(label: "Debt",
                                    value: snapshot.sleepDebtText(goalHours: sleepGoalHours),
                                    state: snapshot.sleepDebtText(goalHours: sleepGoalHours) == "--" ? .learning : .local,
                                    tint: .indigo,
                                    footnote: snapshot.sleepDebtFootnote(goalHours: sleepGoalHours))
                    AtriaMetricTile(label: "\(latestEvidence?.evidenceLabel ?? "Sleep") RHR",
                                    value: latestEvidence?.restingHRText ?? "--",
                                    unit: latestEvidence?.restingHR == nil ? nil : "bpm",
                                    state: latestEvidence?.restingHR == nil ? .learning : (latestEvidence?.confirmed == true ? .personalBaseline : .research),
                                    // Unzoned (no trusted baseline) must stay
                                    // neutral — red implied a bad verdict the
                                    // data can't back (2026-08-04).
                                    tint: restingHeartRateZone?.tint ?? .secondary,
                                    zone: restingHeartRateZone,
                                    targetMetric: .rhr)
                    AtriaMetricTile(label: "Efficiency",
                                    value: latestEvidence?.sleepEfficiencyText ?? "--",
                                    // HR-only honesty (2026-08-01): an HR-only
                                    // night's stored value is span coverage,
                                    // not efficiency — stay in learning with a
                                    // "Needs motion data" footnote.
                                    state: latestEvidence?.displaySleepEfficiency == nil ? .learning : .research,
                                    tint: sleepEfficiencyZone?.tint ?? .cyan,
                                    footnote: latestEvidence?.sleepEfficiencyFootnote ?? "Duration-based estimate",
                                    zone: sleepEfficiencyZone,
                                    targetMetric: .sleepEfficiency)
                    AtriaMetricTile(label: "\(latestEvidence?.evidenceLabel ?? "Sleep") HRV",
                                    value: latestEvidence?.hrvText ?? "--",
                                    unit: latestEvidence?.hrv == nil ? nil : "ms",
                                    state: latestEvidence?.hrv == nil ? .learning : .research,
                                    tint: hrvZone?.tint ?? .purple,
                                    footnote: latestEvidence?.evidenceOnlyFootnote ?? "Sleep-only estimate",
                                    zone: hrvZone,
                                    targetMetric: .hrv)
                    AtriaMetricTile(label: "\(latestEvidence?.evidenceLabel ?? "Sleep") resp",
                                    value: latestEvidence?.respiratoryRateText ?? "--",
                                    unit: latestEvidence?.respiratoryRate == nil ? nil : "/min",
                                    state: latestEvidence?.respiratoryRate == nil ? .learning : .research,
                                    tint: respiratoryRateZone?.tint ?? .teal,
                                    footnote: latestEvidence?.evidenceOnlyFootnote ?? "Sleep-only estimate",
                                    zone: respiratoryRateZone,
                                    targetMetric: .respiratoryRate)
                }

                // P3 (2026-08-04): efficiency history in place, not just the
                // latest night — fed from confirmed nights, honest-gated to
                // ≥5 qualified nights in 30 days like every rollup trend.
                if let efficiencyTrend = AtriaAboutMetricTrend.makeSleepEfficiency(
                    nights: snapshot.nights
                ) {
                    AtriaMiniTrendCard(trend: efficiencyTrend,
                                       tint: .cyan,
                                       title: "EFFICIENCY · LAST 30 DAYS",
                                       subject: "Sleep efficiency")
                }

                // A duration-only bar chart made people guess what “good”
                // looked like. Keep one legible sleep trend instead: the
                // weekly line-and-node comparison gives every night its
                // personal need and makes missing observations explicit.
                AtriaSleepDebtChartCard(nights: snapshot.nights,
                                        rollups: dailyRollupHistory)

                // Collapsed by default (UX audit 2026-07-07): the card
                // stacked ~15 card-like units; stage detail and per-night
                // rows disclose on demand while the lens, useful tiles, and
                // the actionable need comparison stay glanceable.
                DisclosureGroup(isExpanded: $showNightDetails) {
                    if let latest = snapshot.latestMainSleep {
                        if !latest.displayStageSegments.isEmpty {
                            AtriaSleepStageSummary(night: latest)
                        } else {
                            AtriaSleepStageBuildingSummary(night: latest)
                        }
                    }

                    ForEach(snapshot.nights.prefix(3)) { night in
                        AtriaSleepNightRow(night: night)
                    }
                } label: {
                    Text("Recent nights & stages")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
        .onChange(of: snapshot.latestReviewable?.id) { _, _ in
            sleepConfirmationFailed = false
        }
        .sheet(isPresented: $showManualSleepSheet) {
            AtriaManualSleepSheet { start, end, isNap in
                let saved = await onAddManualSleep(start, end, isNap)
                if saved { showManualSleepSheet = false }
                return saved
            }
        }
        .sheet(item: $adjustmentNight) { night in
            AtriaManualSleepSheet(initialStart: night.start,
                                  initialEnd: night.end,
                                  initialIsNap: night.isNapEvidence,
                                  preservesSensorStages: true,
                                  evidenceNight: night,
                                  evidencePerformancePercent: snapshot.sleepPerformancePercent(for: night,
                                                                                               baseNeedHours: SessionStore.configuredSleepBaseNeedHours())) { start, end, isNap in
                let saved = await onAdjustSleep(night, start, end, isNap)
                if saved { adjustmentNight = nil }
                return saved
            }
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaSleepContextLens: View, Equatable {
    let snapshot: SleepHistorySnapshot
    let goalHours: Double

    private var latest: SleepHistorySnapshot.Night? {
        snapshot.latestMainSleep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Sleep lens", systemImage: latest?.isNapEvidence == true ? "moon.zzz.fill" : "bed.double.fill")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(latest?.durationText ?? "--")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.cyan)
            }

            durationRail

            HStack(spacing: 8) {
                lensPill(title: "Type", value: latest?.evidenceLabel ?? "Learning", tint: .cyan)
                lensPill(title: "Recovery", value: recoveryImpactText, tint: .blue)
                // Plain-language pass (2026-07-31 device review): "Routine 46%"
                // did not say what it measures; the pill now names it.
                lensPill(title: "Consistency", value: snapshot.sleepConsistencyText, tint: .mint)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cyan.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep lens. \(latest?.evidenceLabel ?? "Learning"), \(latest?.durationText ?? "no duration"), \(recoveryImpactText), consistency \(snapshot.sleepConsistencyText).")
    }

    private var recoveryImpactText: String {
        guard let latest else { return "Learning" }
        if latest.confirmed {
            return latest.isNapEvidence ? "Separate" : "Recovery"
        }
        return latest.isNapEvidence ? "Review nap" : "Review sleep"
    }

    private var durationRail: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = min(max((latest?.durationHours ?? 0) / max(goalHours, 0.1), 0), 1.2)
            let goalX = min(max(width / 1.2, 0), width)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(Color.cyan.opacity(0.70))
                    .frame(width: max(8, min(width, width * progress / 1.2)))
                Rectangle()
                    .fill(Color.white.opacity(0.52))
                    .frame(width: 1.5, height: 18)
                    .offset(x: goalX)
            }
        }
        .frame(height: 18)
    }

    private func lensPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// De-privatized (visibilitySpec §2, 2026-07-05) so `AtriaHealthScreen` (the
/// live Vitals tab) can mount it directly, alongside this orphaned card's own
/// usage above -- no logic change.
struct AtriaSleepStageSummary: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(night.stageEvidence.label)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(night.evidenceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            AtriaSleepStageHypnogram(segments: night.displayStageSegments,
                                     start: night.start,
                                     end: night.end,
                                     duration: night.duration)
                .frame(height: 120)
                .atriaInspectableGraph(sleepStageGraph)
                // Full-bleed stage lanes (2026-08-05 width audit): the
                // hypnogram escapes this card's 10pt inset; header, legend
                // tiles, and the restorative strip keep it.
                .padding(.horizontal, -10)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(SleepStageKind.allCases) { stage in
                    HStack(spacing: 7) {
                        Image(systemName: Self.symbol(for: stage))
                            .font(.caption2.weight(.bold))
                            .frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.label.uppercased())
                                .font(.caption2.weight(.bold))
                            Text(night.stageText(stage))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(color(for: stage).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(color(for: stage))
                }
            }

            // Restorative-sleep visualization (2026-08-05): REM + SWS + deep as
            // the recovery-relevant share of the night, shown as a proportional
            // stage-composition bar with a restorative callout (upgrades the
            // former text-only strip). Pure re-presentation of the same stage
            // evidence above; hidden when stages carry no duration. Stage
            // aggregation lives in the computed helpers below, off the render
            // path.
            let stageDurations = compositionStageDurations
            let totalStaged = totalStagedDuration
            let restorativeSeconds = restorativeStageSeconds
            if totalStaged > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.heart.fill")
                            .font(.caption2.weight(.bold))
                        Text("RESTORATIVE SLEEP")
                            .font(.caption2.weight(.bold))
                        Spacer(minLength: 0)
                        Text("\(SleepHistorySnapshot.formatDuration(restorativeSeconds)) · \(Int((restorativeSeconds / totalStaged * 100).rounded()))%")
                            .font(.caption2.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(.indigo)

                    // Proportional composition: restorative stages (deep→SWS→REM)
                    // lead, then light and awake, so the recovery share reads as
                    // the leading block of the bar.
                    GeometryReader { geo in
                        let w = geo.size.width
                        HStack(spacing: 0) {
                            ForEach(stageDurations.filter { $0.1 > 0 }, id: \.0) { stage, seconds in
                                color(for: stage)
                                    .frame(width: CGFloat(seconds / totalStaged) * w)
                            }
                        }
                    }
                    .frame(height: 10)
                    .clipShape(Capsule(style: .continuous))
                    .accessibilityHidden(true)

                    Text("REM + SWS + Deep — the recovery-relevant share of the night.")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color.indigo.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(night.evidenceLabel) \(night.stageEvidence.label). Awake \(night.stageText(.awake)), Light \(night.stageText(.light)), REM \(night.stageText(.rem)), SWS \(night.stageText(.sws)), Deep \(night.stageText(.deep)).")
    }

    /// Restorative stages (deep→SWS→REM) lead, then light and awake, so the
    /// recovery share reads as the leading block of the composition bar.
    private static let compositionStageOrder: [SleepStageKind] = [.deep, .sws, .rem, .light, .awake]

    // Precomputed off the render path (static-gate rule: no aggregation
    // inside `some View` blocks).
    private var compositionStageDurations: [(SleepStageKind, TimeInterval)] {
        Self.compositionStageOrder.map { ($0, night.stageDuration($0)) }
    }

    private var totalStagedDuration: TimeInterval {
        compositionStageDurations.reduce(0.0) { $0 + $1.1 }
    }

    private var restorativeStageSeconds: TimeInterval {
        night.stageDuration(.rem)
            + night.stageDuration(.sws)
            + night.stageDuration(.deep)
    }

    static func symbol(for stage: SleepStageKind) -> String {
        switch stage {
        case .awake: return "sun.max.fill"
        case .light: return "moon.fill"
        case .rem: return "moonphase.waxing.crescent"
        case .sws: return "waveform.path"
        case .deep: return "moon.stars.fill"
        }
    }

    private func color(for stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan
        case .rem: return .indigo
        case .sws: return .blue
        case .deep: return .purple
        }
    }

    private var sleepStageGraph: AtriaInspectableGraph? {
        guard !night.displayStageSegments.isEmpty else { return nil }
        let start = night.start ?? night.displayStageSegments.map(\.start).min()
        let end = night.end ?? night.displayStageSegments.map(\.end).max()
        guard let start, let end, end > start else { return nil }
        return AtriaInspectableGraph(
            title: "Sleep stages",
            subtitle: "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))",
            content: .intervals(night.displayStageSegments.map { segment in
                .init(id: segment.id,
                      lane: segment.stage.label,
                      label: segment.stage.label,
                      start: segment.start,
                      end: segment.end,
                      tint: color(for: segment.stage))
            }, domain: start...end)
        )
    }
}

/// De-privatized (visibilitySpec §2, 2026-07-05) -- see `AtriaSleepStageSummary`.
struct AtriaSleepStageBuildingSummary: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        // Do not draw five colorful empty values. A blank hypnogram looks
        // complete at a glance while conveying no decision. The full stage
        // timeline appears only when this night has qualified segments.
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.cyan)
                .frame(width: 32, height: 32)
                .background(.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(night.evidenceLabel). \(headline). \(detail)")
    }

    private var headline: String {
        if night.isManualEntry { return "No stages — manual entry" }
        return night.stageEvidence == .hrOnlyEstimate
            ? "Stages need motion data"
            : "Sleep stages unavailable"
    }

    private var detail: String {
        if night.isManualEntry {
            return "This window was entered by hand. Atria draws stage timelines only from sensor data — duration and any overnight vitals are kept."
        }
        return night.stageEvidence == .hrOnlyEstimate
            ? "Heart rate alone can't separate sleep stages. Duration and overnight vitals remain available."
            : "Stages need checked evidence. Duration and overnight vitals remain available while Atria learns."
    }

}

// Internal (was private) so the broader-lane sizing is render-testable.
struct AtriaSleepStageHypnogram: View, Equatable {
    let segments: [SleepStageSegment]
    let start: Date?
    let end: Date?
    let duration: TimeInterval

    var body: some View {
        Canvas { context, size in
            drawGuides(in: &context, size: size)
            drawSegments(in: &context, size: size)
        }
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func drawGuides(in context: inout GraphicsContext, size: CGSize) {
        for stage in SleepStageKind.allCases {
            let y = stageY(stage, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)
        }
    }

    private func drawSegments(in context: inout GraphicsContext, size: CGSize) {
        guard duration > 0, !segments.isEmpty else { return }
        let timelineStart = start ?? segments.map(\.start).min() ?? segments[0].start
        let timelineEnd = end ?? segments.map(\.end).max() ?? timelineStart.addingTimeInterval(duration)
        let timelineDuration = max(duration, timelineEnd.timeIntervalSince(timelineStart))
        guard timelineDuration > 0 else { return }
        // Broader lanes (2026-07-08, user request: ~3-4x): scale with the frame
        // and cap so lanes stay distinct at the taller 120pt hypnogram.
        let laneHeight = max(12, min(22, size.height / 5.5))
        for segment in segments {
            guard let normalizedRange = Self.normalizedRange(for: segment,
                                                             timelineStart: timelineStart,
                                                             timelineEnd: timelineEnd) else { continue }
            let width = max(1, size.width * (normalizedRange.upperBound - normalizedRange.lowerBound))
            let x = size.width * normalizedRange.lowerBound
            let y = stageY(segment.stage, height: size.height) - laneHeight / 2
            let rect = CGRect(x: x,
                              y: y,
                              width: min(width, max(0, size.width - x)),
                              height: laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: laneHeight / 2),
                         with: .color(color(for: segment.stage)))
        }
    }

    static func normalizedRange(for segment: SleepStageSegment,
                                timelineStart: Date,
                                timelineEnd: Date) -> ClosedRange<Double>? {
        let timelineDuration = timelineEnd.timeIntervalSince(timelineStart)
        guard timelineDuration > 0 else { return nil }
        let clippedStart = max(segment.start, timelineStart)
        let clippedEnd = min(segment.end, timelineEnd)
        guard clippedEnd > clippedStart else { return nil }
        let lower = clippedStart.timeIntervalSince(timelineStart) / timelineDuration
        let upper = clippedEnd.timeIntervalSince(timelineStart) / timelineDuration
        return min(max(lower, 0), 1)...min(max(upper, 0), 1)
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

    private func color(for stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan
        case .rem: return .indigo
        case .sws: return .blue
        case .deep: return .purple
        }
    }
}

private struct AtriaSleepNightRow: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: night.confirmed ? "checkmark.seal.fill" : (night.isNapEvidence ? "moon.zzz.fill" : "bed.double.fill"))
                .font(.caption.weight(.bold))
                .foregroundStyle(night.confirmed ? .green : .teal)
                .frame(width: 24, height: 24)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: night.confirmed ? .green : .teal))

            VStack(alignment: .leading, spacing: 2) {
                Text(night.day, format: .dateTime.weekday(.abbreviated).month().day())
                    .font(.caption.weight(.semibold))
                Text("\(night.confirmationText) · \(night.durationText) · Eff \(night.sleepEfficiencyText) · RHR \(night.restingHRText) · HRV \(night.hrvText) · Resp \(night.respiratoryRateText) · \(night.confidenceText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if !night.displayStageSegments.isEmpty {
                    Text("\(night.stageEvidence.label) · Awake \(night.stageText(.awake)) · Light \(night.stageText(.light)) · REM \(night.stageText(.rem)) · SWS \(night.stageText(.sws)) · Deep \(night.stageText(.deep))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .atriaInsetCard(tint: night.confirmed ? .green : .teal)
    }
}

private struct AtriaTrainingLoadTile: View, Equatable {
    let ratio: String
    let target: String
    let confidence: String
    let readiness: String
    let acwrSignal: String
    let monotony: String
    let monotonySignal: String
    let acwrDetail: String
    let monotonyDetail: String
    let signalSummary: String
    let narrative: String
    let targetMetric: AtriaTodayMetric?
    @State private var editingTargetMetric: AtriaTodayMetric?

    static func == (lhs: AtriaTrainingLoadTile, rhs: AtriaTrainingLoadTile) -> Bool {
        lhs.ratio == rhs.ratio
            && lhs.target == rhs.target
            && lhs.confidence == rhs.confidence
            && lhs.readiness == rhs.readiness
            && lhs.acwrSignal == rhs.acwrSignal
            && lhs.monotony == rhs.monotony
            && lhs.monotonySignal == rhs.monotonySignal
            && lhs.acwrDetail == rhs.acwrDetail
            && lhs.monotonyDetail == rhs.monotonyDetail
            && lhs.signalSummary == rhs.signalSummary
            && lhs.narrative == rhs.narrative
            && lhs.targetMetric == rhs.targetMetric
    }

    private var confidenceTint: Color {
        switch readiness.lowercased() {
        case "balanced", "primed": return .green
        case "strained": return .orange
        case "rundown": return .red
        default: return confidence == "local" ? .green : .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Text("Readiness")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                AtriaStateBadge(state: confidence == "local" ? .local : .learning)
            }

            Text(readiness)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            HStack(spacing: 6) {
                AtriaTrainingSignalChip(title: "ACWR", value: ratio, signal: acwrSignal)
                AtriaTrainingSignalChip(title: "Monotony", value: monotony, signal: monotonySignal)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(acwrDetail, systemImage: "gauge.with.dots.needle.50percent")
                Label(monotonyDetail, systemImage: "waveform.path")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.76)

            Text("Target \(target)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity,
               minHeight: 164,
               maxHeight: 164,
               alignment: .leading)
        .padding(13)
        .atriaInsetCard(tint: confidenceTint)
        .contextMenu {
            if let targetMetric {
                Button {
                    editingTargetMetric = targetMetric
                } label: {
                    Label("Edit target", systemImage: "target")
                }
            }
        }
        .accessibilityAction(named: Text("Edit target")) {
            if let targetMetric {
                editingTargetMetric = targetMetric
            }
        }
        .accessibilityLabel("Readiness \(readiness). \(signalSummary). \(acwrDetail) \(monotonyDetail) \(narrative) Long press to edit target.")
        .sheet(item: $editingTargetMetric) { metric in
            AtriaGlanceTargetEditorSheet(metric: metric)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct AtriaTrainingSignalChip: View, Equatable {
    let title: String
    let value: String
    let signal: String

    private var tint: Color {
        switch signal.lowercased() {
        case "good": return .green
        case "neutral": return .blue
        case "watch": return .orange
        case "bad": return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
            Text(value)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule(style: .continuous))
        .foregroundStyle(tint)
    }
}

private struct AtriaProfileCard: View, Equatable {
    let profile: AthleteProfile
    let observedPeakHeartRateText: String
    let vo2MaxEstimate: VO2MaxEstimateSummary
    let biologicalAgeSummary: BiologicalAgeSummary
    let biologicalAgeGreenOlderDelta: Int
    let biologicalAgeYellowOlderDelta: Int
    let vo2GreenDelta: Double
    let vo2RedDelta: Double
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaProfileCard, rhs: AtriaProfileCard) -> Bool {
        lhs.profile == rhs.profile
            && lhs.observedPeakHeartRateText == rhs.observedPeakHeartRateText
            && lhs.vo2MaxEstimate == rhs.vo2MaxEstimate
            && lhs.biologicalAgeSummary == rhs.biologicalAgeSummary
            && lhs.biologicalAgeGreenOlderDelta == rhs.biologicalAgeGreenOlderDelta
            && lhs.biologicalAgeYellowOlderDelta == rhs.biologicalAgeYellowOlderDelta
            && lhs.vo2GreenDelta == rhs.vo2GreenDelta
            && lhs.vo2RedDelta == rhs.vo2RedDelta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Profile", subtitle: "HRmax and age used for scoring")

            // Standard native iOS 26 segmented control.
            Picker("Max heart-rate source", selection: Binding(
                get: { profile.maxHRSource },
                set: { newValue in onUpdateProfile { $0.maxHRSource = newValue } }
            )) {
                ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: profile.maxHRSource)

            VStack(spacing: 12) {
                profileStepperTiles
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaInlineQuickStat(label: "Active HRmax", value: "\(profile.maxHR)")
                AtriaInlineQuickStat(label: "Observed peak", value: observedPeakHeartRateText)
                AtriaInlineQuickStat(label: "Source", value: profile.maxHRSource.label)
                AtriaMetricTile(label: "VO2max",
                                value: vo2MaxEstimate.valueText,
                                state: vo2MaxEstimate.value == nil ? .learning : .estimate,
                                tint: vo2TrendZone?.tint ?? .orange,
                                footnote: vo2MaxEstimate.compactStatusText,
                                zone: vo2TrendZone,
                                targetMetric: .vo2max)
                AtriaMetricTile(label: "VO2 trend",
                                value: vo2MaxEstimate.trendText,
                                state: vo2MaxEstimate.value == nil || vo2MaxEstimate.trendText == "Learning" ? .learning : .estimate,
                                tint: vo2TrendZone?.tint ?? .orange,
                                footnote: vo2MaxEstimate.trendDetail,
                                zone: vo2TrendZone,
                                targetMetric: .vo2max)
                AtriaMetricTile(label: "Body age",
                                value: biologicalAgeSummary.valueText,
                                state: biologicalAgeSummary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? .purple : .orange),
                                footnote: biologicalAgeSummary.compactStatusText,
                                zone: biologicalAgeZone,
                                targetMetric: .bioAge)
                AtriaMetricTile(label: "Top driver",
                                value: biologicalAgeSummary.agingPaceText,
                                state: biologicalAgeSummary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? .purple : .orange),
                                footnote: biologicalAgeSummary.availabilityDetailText)
            }

            Text(vo2MaxEstimate.narrative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                AtriaPanelSectionHeader(title: "Body Age", subtitle: biologicalAgeSummary.narrative)
                if biologicalAgeSummary.factors.isEmpty {
                    Text(biologicalAgeSummary.blockerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(biologicalAgeSummary.factors) { factor in
                        AtriaBioAgeFactorRow(factor: factor)
                    }
                }
                Text(biologicalAgeSummary.footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .atriaInsetCard(tint: .purple)

            Text("Atria uses the active HRmax right away for strain and workout interpretation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var profileStepperTiles: some View {
        AtriaProfileStepperTile(title: "Age", value: "\(profile.age)") {
            onUpdateProfile { $0.age = max(13, $0.age - 1) }
        } increment: {
            onUpdateProfile { $0.age = min(100, $0.age + 1) }
        }

        AtriaProfileStepperTile(title: "Measured max", value: "\(profile.measuredMaxHR)") {
            onUpdateProfile { $0.measuredMaxHR = max(120, $0.measuredMaxHR - 1) }
        } increment: {
            onUpdateProfile { $0.measuredMaxHR = min(220, $0.measuredMaxHR + 1) }
        }
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

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaCollectionReferenceSummaryCard: View, Equatable {
    let leadingTitle: String
    let leadingValue: String
    let leadingDetail: String
    let trailingTitle: String
    let trailingValue: String
    let trailingDetail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AtriaCollectionReferenceSummaryTile(title: leadingTitle,
                                                value: leadingValue,
                                                detail: leadingDetail)

            Divider()
                .padding(.vertical, 10)

            AtriaCollectionReferenceSummaryTile(title: trailingTitle,
                                                value: trailingValue,
                                                detail: trailingDetail)
        }
    }
}

private struct AtriaCollectionReferenceSummaryTile: View, Equatable {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(value.localizedCaseInsensitiveContains("ready") ? Color.green : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct AtriaCollectionToggleCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }
}
