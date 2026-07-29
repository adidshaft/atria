import SwiftUI
import Charts
import Combine

/// The Health tab intentionally does not observe the fast Home stores at its
/// root: doing so would rebuild its chart-heavy hierarchy for every live pulse.
/// This projection keeps only values the Health Monitor actually renders and
/// publishes when one of those values changes. The small monitor subtree stays
/// live while the timeline and trend charts remain outside the invalidation
/// boundary.
struct AtriaHealthMonitorLiveProjection: Equatable {
    let connectionStatus: AtriaBLEManager.Status
    let recoveryPercent: Int?
    let recoveryDetail: String
    let restingHeartRateText: String
    let hrvValue: String
    let hrvDetail: String
    let vo2MaxEstimate: VO2MaxEstimateSummary
    let maxHeartRate: Int
}

@MainActor
final class AtriaHealthMonitorLiveProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaHealthMonitorLiveProjection

    private let liveStore: AtriaHomeModel.CoreLiveStore
    private let heroStore: AtriaHomeModel.HeroStore
    private let profileStore: AtriaHomeModel.ProfileStore
    private let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    private var cancellables = Set<AnyCancellable>()

    init(liveStore: AtriaHomeModel.CoreLiveStore,
         heroStore: AtriaHomeModel.HeroStore,
         profileStore: AtriaHomeModel.ProfileStore,
         profileMetricsStore: AtriaHomeModel.ProfileMetricsStore) {
        self.liveStore = liveStore
        self.heroStore = heroStore
        self.profileStore = profileStore
        self.profileMetricsStore = profileMetricsStore
        state = Self.makeState(liveStore: liveStore,
                               heroStore: heroStore,
                               profileStore: profileStore,
                               profileMetricsStore: profileMetricsStore)

        Publishers.MergeMany([
            liveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            heroStore.$state.map { _ in () }.eraseToAnyPublisher(),
            profileStore.$profile.map { _ in () }.eraseToAnyPublisher(),
            profileMetricsStore.$state.map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)
    }

    @discardableResult
    func refresh() -> Bool {
        let next = Self.makeState(liveStore: liveStore,
                                  heroStore: heroStore,
                                  profileStore: profileStore,
                                  profileMetricsStore: profileMetricsStore)
        guard next != state else { return false }
        state = next
        return true
    }

    private static func makeState(
        liveStore: AtriaHomeModel.CoreLiveStore,
        heroStore: AtriaHomeModel.HeroStore,
        profileStore: AtriaHomeModel.ProfileStore,
        profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    ) -> AtriaHealthMonitorLiveProjection {
        AtriaHealthMonitorLiveProjection(
            connectionStatus: liveStore.state.status,
            recoveryPercent: heroStore.state.recoveryEstimate.percent,
            recoveryDetail: heroStore.state.recoveryDetail,
            restingHeartRateText: heroStore.state.restingHeartRateText,
            hrvValue: heroStore.state.hrvValue,
            hrvDetail: heroStore.state.hrvDetail,
            vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
            maxHeartRate: profileStore.profile.maxHR
        )
    }
}

private struct AtriaHealthMonitorLiveHost<Content: View>: View {
    @StateObject private var projectionStore: AtriaHealthMonitorLiveProjectionStore
    let content: (AtriaHealthMonitorLiveProjection) -> Content

    init(liveStore: AtriaHomeModel.CoreLiveStore,
         heroStore: AtriaHomeModel.HeroStore,
         profileStore: AtriaHomeModel.ProfileStore,
         profileMetricsStore: AtriaHomeModel.ProfileMetricsStore,
         @ViewBuilder content: @escaping (AtriaHealthMonitorLiveProjection) -> Content) {
        _projectionStore = StateObject(wrappedValue: AtriaHealthMonitorLiveProjectionStore(
            liveStore: liveStore,
            heroStore: heroStore,
            profileStore: profileStore,
            profileMetricsStore: profileMetricsStore
        ))
        self.content = content
    }

    var body: some View {
        content(projectionStore.state)
    }
}

private struct AtriaHealthFitnessAgeCardHost: View {
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore

    var body: some View {
        AtriaHealthFitnessAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary)
    }
}

private struct AtriaHealthspanDetailPresentationHost: View {
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let store: SessionStore
    let onClose: () -> Void
    let onViewPlan: () -> Void

    var body: some View {
        NavigationStack {
            AtriaHealthspanDetailView(
                model: Self.model(
                    summary: profileMetricsStore.state.biologicalAgeSummary,
                    projection: store.biologicalAgeHealthspanDetailProjection
                ),
                onViewPlan: onViewPlan
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    private static func model(
        summary: BiologicalAgeSummary,
        projection: AtriaFitnessAge.DetailProjection?
    ) -> AtriaHealthspanDetailModel {
        let contributors = summary.factors.map { factor in
            let tone: AtriaHealthspanDetailModel.ContributorTone
            switch factor.direction {
            case .younger: tone = .positive
            case .neutral: tone = .neutral
            case .older: tone = .attention
            }
            return AtriaHealthspanDetailModel.Contributor(id: factor.id,
                                                          label: factor.label,
                                                          valueText: factor.deltaText,
                                                          tone: tone)
        }
        let points = (projection?.weeklyObservations ?? []).map {
            AtriaHealthspanDetailModel.TrendPoint(
                day: $0.day,
                value: Double(summary.chronologicalAge + $0.delta)
            )
        }
        return AtriaHealthspanDetailModel(
            summary: summary,
            paceOfAging: projection?.paceOfAging,
            contributors: contributors,
            trendPoints: points,
            trendTitle: "Fitness age · 6 months",
            trendChangeText: projection?.trendChangeText,
            confidence: .init(level: summary.isReady ? "Estimate ready" : "Learning",
                              detail: summary.footnote),
            cachedAt: projection?.cachedAt
        )
    }
}

enum AtriaHealthMonitorGrid {
    static func columnCount(for dynamicTypeSize: DynamicTypeSize) -> Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        if dynamicTypeSize >= .xxLarge { return 2 }
        return 3
    }
}

/// Vitals must use the same wake-to-wake sleep authority as Today. The sleep
/// history snapshot intentionally retains an older confirmed night for charts,
/// so reading `latestMainSleep` directly can make Vitals show stale duration,
/// stages, performance, or respiration after Today has correctly rolled over
/// to Learning.
enum AtriaHealthCurrentSleepEvidence {
    static func resolve(from snapshot: SleepHistorySnapshot,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> SleepHistorySnapshot.Night? {
        AtriaOverviewCurrentSleep.resolve(from: snapshot,
                                          now: now,
                                          calendar: calendar)
    }
}

/// Current Vitals values are wake-to-wake Hero projections. A civil rollup is
/// valid only when the UI is explicitly rendering that dated historical row.
/// Keeping the choice in one pure resolver prevents midnight from silently
/// replacing the active physiological cycle with a newly-created civil day.
enum AtriaHealthMetricAuthority {
    struct CurrentCycle: Equatable {
        let recoveryPercent: Int?
        let recoveryDetail: String
        let restingHeartRateText: String
        let hrvValue: String
        let hrvDetail: String
        let strain: Double?
        let strainDetail: String
        let strainIsPartial: Bool
        let wearCoverageFraction: Double?
        let cycleStart: Date?
        let projectedAt: Date?

        init(recoveryPercent: Int?,
             recoveryDetail: String,
             restingHeartRateText: String,
             hrvValue: String,
             hrvDetail: String,
             strain: Double? = nil,
             strainDetail: String = "",
             strainIsPartial: Bool = false,
             wearCoverageFraction: Double? = nil,
             cycleStart: Date? = nil,
             projectedAt: Date? = nil) {
            self.recoveryPercent = recoveryPercent
            self.recoveryDetail = recoveryDetail
            self.restingHeartRateText = restingHeartRateText
            self.hrvValue = hrvValue
            self.hrvDetail = hrvDetail
            self.strain = strain
            self.strainDetail = strainDetail
            self.strainIsPartial = strainIsPartial
            self.wearCoverageFraction = wearCoverageFraction
            self.cycleStart = cycleStart
            self.projectedAt = projectedAt
        }
    }

    struct Projection: Equatable {
        let recoveryPercent: Int?
        let recoveryValue: String
        let recoveryDetail: String
        let restingHeartRate: Int?
        let restingHeartRateValue: String
        let restingHeartRateDetail: String
        let hrvMS: Int?
        let hrvValue: String
        let hrvDetail: String
        let strain: Double?
        let strainDetail: String
        let strainIsPartial: Bool
        let wearCoverageFraction: Double?
        let cycleStart: Date?
        let projectedAt: Date?

        var hasEvidence: Bool {
            recoveryPercent != nil
                || restingHeartRate != nil
                || hrvMS != nil
                || strain != nil
        }
    }

    enum Scope {
        case currentCycle(CurrentCycle)
        case datedHistory(DailyRollupStoreEntry)
    }

    static func resolve(_ scope: Scope) -> Projection {
        switch scope {
        case .currentCycle(let current):
            let restingHeartRate = Int(current.restingHeartRateText)
            let normalizedHRV = normalizedMetricText(current.hrvValue)
            return Projection(
                recoveryPercent: current.recoveryPercent,
                recoveryValue: current.recoveryPercent.map { "\($0)%" } ?? AtriaCompactMetricPresentation.noValue,
                recoveryDetail: current.recoveryPercent == nil
                    ? specificDetail(current.recoveryDetail,
                                     fallback: "Recovery evidence incomplete")
                    : current.recoveryDetail,
                restingHeartRate: restingHeartRate,
                restingHeartRateValue: restingHeartRate.map {
                    AtriaMetricFormat.restingHeartRate(Double($0))
                } ?? AtriaCompactMetricPresentation.noValue,
                restingHeartRateDetail: restingHeartRate == nil
                    ? "needs enough wear" : "current cycle",
                hrvMS: Int(normalizedHRV),
                hrvValue: normalizedHRV,
                hrvDetail: normalizedHRV == AtriaCompactMetricPresentation.noValue
                    ? specificDetail(current.hrvDetail,
                                     fallback: "Needs quiet rest or sleep")
                    : current.hrvDetail,
                strain: current.strain,
                strainDetail: current.strainDetail,
                strainIsPartial: current.strainIsPartial,
                wearCoverageFraction: current.wearCoverageFraction,
                cycleStart: current.cycleStart,
                projectedAt: current.projectedAt
            )
        case .datedHistory(let rollup):
            let hrvMS = rollup.lnRMSSD.map { Int(exp($0).rounded()) }
            return Projection(
                recoveryPercent: rollup.recovery,
                recoveryValue: rollup.recovery.map { "\($0)%" } ?? AtriaCompactMetricPresentation.noValue,
                recoveryDetail: AtriaHealthMetricEvidencePresentation.recoveryDetail(
                    rollup: rollup,
                    liveRecoveryAvailable: false
                ),
                restingHeartRate: rollup.rhr,
                restingHeartRateValue: rollup.rhr.map {
                    AtriaMetricFormat.restingHeartRate(Double($0))
                } ?? AtriaCompactMetricPresentation.noValue,
                restingHeartRateDetail:
                    AtriaHealthMetricEvidencePresentation.restingHeartRateDetail(
                        rollup: rollup,
                        liveValueAvailable: false
                    ),
                hrvMS: hrvMS,
                hrvValue: hrvMS.map(String.init) ?? AtriaCompactMetricPresentation.noValue,
                hrvDetail: AtriaHealthMetricEvidencePresentation.hrvDetail(
                    rollup: rollup,
                    liveValueAvailable: false
                ),
                strain: rollup.strain,
                strainDetail: "dated history",
                strainIsPartial: false,
                wearCoverageFraction: nil,
                cycleStart: rollup.day,
                projectedAt: nil
            )
        }
    }

    /// Builds the one wake-to-wake authority shared by Today, Health, Vitals,
    /// Overview, widgets, and metric detail. A civil rollup remains valid history,
    /// but it must not replace these current-cycle values after midnight.
    static func currentCycleProjection(
        hero: AtriaHomeModel.HeroSnapshot,
        sleepHistory: SleepHistorySnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Projection {
        let physiologicalDay = AtriaPhysiologicalDay.current(
            now: now,
            sleepHistory: sleepHistory,
            calendar: calendar
        )
        return resolve(.currentCycle(.init(
            recoveryPercent: hero.recoveryEstimate.percent,
            recoveryDetail: hero.recoveryDetail,
            restingHeartRateText: hero.restingHeartRateText,
            hrvValue: hero.hrvValue,
            hrvDetail: hero.hrvDetail,
            strain: hero.strain,
            strainDetail: hero.strainConfidence,
            strainIsPartial:
                hero.strainConfidence.localizedCaseInsensitiveContains("partial"),
            wearCoverageFraction: hero.dayWearCoverageFraction,
            cycleStart: physiologicalDay.start,
            // The projection participates in the metric-chart cache key. Use
            // the stable civil-day anchor rather than the render instant so
            // unchanged metric evidence does not invalidate that cache on
            // every SwiftUI body evaluation. It still advances at midnight,
            // which is exactly when D/W/M period membership can change.
            projectedAt: calendar.startOfDay(for: now)
        )))
    }

    /// Pure selector used by metric detail. The current wake-to-wake authority
    /// replaces a stale civil row only while the user is viewing the period that
    /// contains the live projection. Navigating to an older day/week/month keeps
    /// the explicitly dated historical values untouched.
    struct DetailProjection: Equatable {
        let recoveryPercent: Int?
        let strain: Double?
        let usesCurrentCycle: Bool
    }

    /// A partial cumulative strain is useful as a Day lower bound, but it is
    /// not an exact sample and must never enter Day/Week/Month chart averages.
    struct StrainTrendTruth: Equatable {
        let heroLowerBound: Double?
        let exactTrendValue: Double?
        let isPartial: Bool
    }

    static func strainTrendTruth(
        _ currentCycle: Projection?
    ) -> StrainTrendTruth {
        let isPartial = currentCycle?.strainIsPartial == true
        return StrainTrendTruth(
            heroLowerBound: currentCycle?.strain,
            exactTrendValue: isPartial ? nil : currentCycle?.strain,
            isPartial: isPartial
        )
    }

    static func detailProjection(
        currentCycle: Projection?,
        historicalRecoveryPercent: Int?,
        historicalStrain: Double?,
        range: AtriaTrendRange,
        periodAnchor: Date,
        calendar: Calendar = .current
    ) -> DetailProjection {
        guard let currentCycle,
              let currentDisplayAnchor =
                currentCycle.cycleStart ?? currentCycle.projectedAt,
              range.periodInterval(
                containing: periodAnchor,
                calendar: calendar
              ).contains(currentDisplayAnchor) else {
            return DetailProjection(
                recoveryPercent: historicalRecoveryPercent,
                strain: historicalStrain,
                usesCurrentCycle: false
            )
        }
        return DetailProjection(
            recoveryPercent: currentCycle.recoveryPercent,
            strain: currentCycle.strain,
            usesCurrentCycle: true
        )
    }

    /// Normalises an absent metric onto the deterministic no-value token.
    ///
    /// This previously did the REVERSE -- it rewrote "--" into "Learning" --
    /// which silently undid the token upstream and left Health Monitor reading
    /// "Learning" beside a Vitals row already showing "--". A normaliser that
    /// converts the canonical token into a different word is the one place a
    /// vocabulary can never converge.
    private static func normalizedMetricText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return AtriaCompactMetricPresentation.isPendingValue(trimmed)
            ? AtriaCompactMetricPresentation.noValue
            : trimmed
    }

    /// The Hero already knows why a current-cycle metric is absent (for
    /// example, "HRV settling" versus "no sleep yet"). Do not erase that
    /// concrete reason with a generic baseline message on the Vitals screen.
    private static func specificDetail(_ detail: String,
                                       fallback: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return AtriaCompactMetricPresentation.isPendingValue(trimmed)
            ? fallback
            : trimmed
    }
}

/// Status-specific presentation for saved current-cycle metrics in Health.
///
/// A retry is useful only from a settled disconnected state. While iOS is
/// already scanning/connecting, another scan request is redundant; while
/// Bluetooth is off, it cannot work. This keeps the row from offering a false
/// "Reconnect" action in either state.
enum AtriaHealthConnectionEvidencePresentation {
    struct Notice: Equatable {
        let title: String
        let systemImage: String
        let allowsRetry: Bool
    }

    static func notice(status: AtriaBLEManager.Status,
                       hasEvidence: Bool) -> Notice? {
        guard hasEvidence else { return nil }
        switch status {
        case .connected:
            return nil
        case .scanning, .connecting:
            return Notice(title: "Reconnecting · saved current cycle",
                          systemImage: "arrow.triangle.2.circlepath",
                          allowsRetry: false)
        case .poweredOff:
            return Notice(title: "Bluetooth off · saved current cycle",
                          systemImage: "bolt.slash.fill",
                          allowsRetry: false)
        case .disconnected:
            return Notice(title: "Last known · current cycle",
                          systemImage: "clock.arrow.circlepath",
                          allowsRetry: true)
        }
    }
}

enum AtriaHealthMetricEvidencePresentation {
    static func recoveryDetail(rollup: DailyRollupStoreEntry?,
                               liveRecoveryAvailable: Bool) -> String {
        if let rollup, rollup.recovery != nil {
            if rollup.recoverySummary?.confidence
                == Metrics.RecoveryEstimate.Confidence.unverified.rawValue {
                return "limited estimate"
            }
            return rollup.recoverySummary == nil ? "saved" : "saved morning"
        }
        return liveRecoveryAvailable ? "today · estimate" : "needs a few nights"
    }

    static func restingHeartRateDetail(rollup: DailyRollupStoreEntry?,
                                       liveValueAvailable: Bool) -> String {
        if let rollup, rollup.rhr != nil {
            return (rollup.sleepSeconds ?? 0) > 0 ? "sleep-derived" : "wear estimate"
        }
        return liveValueAvailable ? "live estimate" : "needs enough wear"
    }

    static func hrvDetail(rollup: DailyRollupStoreEntry?,
                          liveValueAvailable: Bool) -> String {
        if let rollup, rollup.lnRMSSD != nil {
            return (rollup.sleepSeconds ?? 0) > 0 ? "sleep signal" : "limited signal"
        }
        return liveValueAvailable ? "live estimate" : "needs qualified sleep"
    }

    static func respiratoryDetail(valueAvailable: Bool) -> String {
        valueAvailable ? "sleep average" : "needs qualified sleep"
    }

    static func settledRestingHeartRateDetail(rollup: DailyRollupStoreEntry,
                                              now: Date = Date(),
                                              calendar: Calendar = .current) -> String {
        guard (rollup.sleepSeconds ?? 0) > 0 else { return "wear estimate" }
        return settledMorningAgeDetail(day: rollup.day,
                                       now: now,
                                       calendar: calendar)
    }

    static func settledHRVDetail(rollup: DailyRollupStoreEntry,
                                 now: Date = Date(),
                                 calendar: Calendar = .current) -> String {
        guard (rollup.sleepSeconds ?? 0) > 0 else { return "limited signal" }
        return settledMorningAgeDetail(day: rollup.day,
                                       now: now,
                                       calendar: calendar)
    }

    /// Saved morning vitals may intentionally be carried until another
    /// qualified sleep produces a replacement. Calling every carried value
    /// "yesterday" hid its real age: after several nights without qualified RR,
    /// a week-old HRV looked one day old. Keep the compact label, but derive it
    /// from the saved rollup's civil day.
    private static func settledMorningAgeDetail(day: Date,
                                                now: Date,
                                                calendar: Calendar) -> String {
        let savedDay = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(savedDay, inSameDayAs: today) {
            return "this morning"
        }
        guard savedDay < today else { return "saved morning" }
        let age = max(calendar.dateComponents([.day],
                                              from: savedDay,
                                              to: today).day ?? 0,
                      1)
        return age == 1 ? "yesterday" : "\(age)d ago"
    }
}

struct AtriaHealthScreen: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case live = "Live"
        case sleep = "Sleep"
        case trends = "Trends"

        var id: String { rawValue }
    }

    #if DEBUG
    static let debugOpenHeartRateTimelineKey = "atria.debug.openHeartRateTimeline"
    #endif

    let isActive: Bool
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileStore: AtriaHomeModel.ProfileStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let stressMonitorStore: AtriaStressMonitorStore
    let store: SessionStore
    let onViewPlan: () -> Void
    @StateObject private var vitalsStore: AtriaVitalsSessionProjectionStore
    let ble: AtriaBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?
    @State private var historicalHeartRatePoints: [AtriaHomeModel.HeartRateChartPoint] = []
    @State private var isLoadingHistoricalHeartRatePoints = true
    @State private var educationTopic: AtriaVitalsEducationTopic?
    // Visibility/IA fix (2026-07-05): route audit + mounted sections. The
    // Health screen previously had no Trends surface, no sleep-stage
    // breakdown, and three new rows (VO2, skin temp, SpO2) that need a real
    // detail sheet rather than just the education sheet.
    @State private var metricDetail: AtriaMetricDetailKind?
    @State private var showBreathworkSession = false
    /// Reference identity lives here, but HealthScreen deliberately does not
    /// observe its publications. Only the presented session host observes the
    /// reading, keeping 30-second stress updates from rebuilding all of Vitals.
    @State private var breathworkStressStore = AtriaHealthBreathworkStressStore()
    @State private var showHealthspanDetail = false
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    @AtriaDefault(DetectionEventLog.revisionKey) private var detectionsRevision: Int = 0
    @StateObject private var historyProjectionStore = AtriaVitalsHistoryProjectionStore()
    /// Immutable, slow-moving review-queue projection supplied by the narrow
    /// detected-activities host. History never observes SessionStore directly.
    @State private var historyReviewCandidateDays: [AtriaHistoryReviewCandidateDay] = []
    @State private var debugArchiveRefreshGate = AtriaVitalsActivityGate()
    // The detected-activities fixture lives in the Trends scope; opening
    // there directly keeps the sim screenshot loop honest (simctl cannot tap
    // the segmented picker). DEBUG-only launch-argument routing.
    @State private var scope: Scope = {
        let arguments = ProcessInfo.processInfo.arguments
        if Self.debugOpensTrendsScope(arguments: arguments) { return .trends }
        if Self.debugOpensSleepScope(arguments: arguments) { return .sleep }
        return .live
    }()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(isActive: Bool,
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
         horizontalSizeClass: UserInterfaceSizeClass?,
         onViewPlan: @escaping () -> Void) {
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
        self.onViewPlan = onViewPlan
        _vitalsStore = StateObject(wrappedValue: AtriaVitalsSessionProjectionStore(store: store))
        self.ble = ble
        self.horizontalSizeClass = horizontalSizeClass
    }

    private var chartPoints: [AtriaHomeModel.HeartRateChartPoint] {
        AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: pulseSparklineStore.state.chartPoints,
                                                           historical: historicalHeartRatePoints)
    }

    private var debugShowsHeartRateTimeline: Bool {
        Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments)
    }

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaHealthScreen")
        let vitals = vitalsStore.state
        let historyInput = AtriaHistoryProjectionInput(
            key: AtriaHistoryRevisionKey(rollup: vitals.dailyRollupHistoryRevision,
                                         workouts: vitals.confirmedWorkoutsRevision,
                                         sleep: vitals.sleepHistorySnapshotRevision,
                                         detections: detectionsRevision,
                                         reviewCandidateDays: historyReviewCandidateDays),
            rollups: vitals.dailyRollupHistory,
            workouts: vitals.confirmedWorkouts,
            sleeps: vitals.confirmedSleeps,
            reviewCandidateDays: historyReviewCandidateDays
        )
        let historyProjection = historyProjectionStore.projection
        Group {
            if debugShowsHeartRateTimeline {
                AtriaHealthTimelineProofCard(points: chartPoints,
                                             isLoading: isLoadingHistoricalHeartRatePoints)
            } else {
                // LazyVStack, not VStack (2026-07-08 perf): Vitals stacks ~10 heavy
                // sections incl. 7+ Swift Charts. In an eager VStack they all render
                // synchronously on tab-open — a multi-second main-thread freeze that
                // grows with data. The outer tabNavigation LazyVStack can't help
                // because this whole screen is a single child of it; making THIS stack
                // lazy renders only the on-screen sections, the rest as they scroll in.
                LazyVStack(spacing: 12) {
                    Picker("Vitals view", selection: $scope) {
                        ForEach(Scope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Vitals view")

                    switch scope {
                    case .live:
                        // Today owns the compact daily summary. This is the deep,
                        // inspectable live surface: pulse timeline plus source-aware
                        // health-monitor rows and a direct breathwork action.
                        AtriaVitalsLivePulseSection(liveStore: liveStore,
                                                    pulseStore: pulseStore,
                                                    homeStatsStore: homeStatsStore,
                                                    baseline: vitals.baseline,
                                                    pulseSparklineStore: pulseSparklineStore,
                                                    isActive: isActive)
                        AtriaHealthMonitorLiveHost(liveStore: liveStore,
                                                   heroStore: heroStore,
                                                   profileStore: profileStore,
                                                   profileMetricsStore: profileMetricsStore) { projection in
                            healthMonitorCard(live: projection)
                        }
                        breathworkCard
                    case .sleep:
                        sleepDetailCard
                    case .trends:
                        // The screenshot fixture hoists the detected-activities
                        // section above the fold: simctl cannot scroll, and the
                        // verification target is the section's own layout.
                        // Production order is unchanged (fixture is DEBUG-only).
                        if Self.debugOpensTrendsScope(arguments: ProcessInfo.processInfo.arguments) {
                            detectedActivitiesAndHistory(historyProjection: historyProjection)
                            trendsCard
                            fitnessAgeCard
                        } else {
                            trendsCard
                            fitnessAgeCard
                            detectedActivitiesAndHistory(historyProjection: historyProjection)
                        }
                    }
                }
            }
        }
        .task(id: isActive && debugShowsHeartRateTimeline) {
            guard isActive, debugShowsHeartRateTimeline else { return }
            _ = debugArchiveRefreshGate.shouldRefreshArchive(isActive: true,
                                                             reason: .activation)
            await refreshHistoricalHeartRatePoints()
        }
        .task(id: historyInput.key) {
            await historyProjectionStore.refresh(from: historyInput)
        }
        .background {
            if isActive && debugShowsHeartRateTimeline {
                AtriaVitalsArchiveActivityObserver {
                    guard debugArchiveRefreshGate.shouldRefreshArchive(isActive: isActive,
                                                                        reason: .notification) else { return }
                    Task {
                        await refreshHistoricalHeartRatePoints()
                    }
                }
            }
        }
        .sheet(item: $educationTopic) { topic in
            AtriaVitalsEducationSheet(topic: topic,
                                      numericRangeText: typicalRangeText(for: topic),
                                      sleepGoalHours: sleepGoalHours)
        }
        .sheet(item: $metricDetail) { detail in
            AtriaMetricDetailSheet(metric: detail,
                                   rollups: vitals.dailyRollupHistory,
                                   rollupsRevision: vitals.dailyRollupHistoryRevision,
                                   confirmedWorkouts: vitals.confirmedWorkouts,
                                   confirmedWorkoutsRevision: vitals.confirmedWorkoutsRevision,
                                   behaviorImpacts: vitals.behaviorImpactSummaries,
                                   baseline: AtriaBaselineTargetSnapshot(vitals.baseline),
                                   sleepHistory: vitals.sleepHistorySnapshot,
                                   sleepHistoryRevision: vitals.sleepHistorySnapshotRevision,
                                   guidance: heroStore.state.guidance,
                                   recoveryEstimate: heroStore.state.recoveryEstimate,
                                   currentCycleAuthority:
                                    AtriaHealthMetricAuthority.currentCycleProjection(
                                        hero: heroStore.state,
                                        sleepHistory: vitals.sleepHistorySnapshot
                                    ),
                                   sleepGoalHours: sleepGoalHours,
                                   sleepBaseNeedHours: sleepBaseNeedHours,
                                   hrZoneMinutes: heroStore.state.hrZoneMinutes,
                                   maxHeartRate: vitals.maxHeartRate,
                                   vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                                   skinTemperatureDeviation: vitals.skinTemperatureDeviationSummary)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showBreathworkSession) {
            AtriaHealthBreathworkSessionHost(pulseStore: pulseStore,
                                             stressStore: breathworkStressStore,
                                             onSave: { session in
                                                 store.add(session)
                                             }) {
                showBreathworkSession = false
            }
        }
        .fullScreenCover(isPresented: $showHealthspanDetail) {
            AtriaHealthspanDetailPresentationHost(
                profileMetricsStore: profileMetricsStore,
                store: store,
                onClose: { showHealthspanDetail = false },
                onViewPlan: {
                    showHealthspanDetail = false
                    Task { @MainActor in
                        await Task.yield()
                        onViewPlan()
                    }
                }
            )
        }
    }

    /// Mounts the sleep-stage hypnogram summary (SWS/REM/Light/Awake) that
    /// previously rendered nowhere live, plus the performance/efficiency stat
    /// pair -- both computed the same honest way the Today ring and its
    /// caption are (visibilitySpec §2, 2026-07-05).
    private var sleepDetailCard: some View {
        let currentSleep = currentMainSleep
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sleep detail")
                .font(.title2.weight(.bold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                AtriaMetricTile(label: "Performance",
                                value: sleepPerformanceValue,
                                state: currentSleep == nil ? .learning : .local,
                                tint: Metrics.electricSleep,
                                footnote: "of nightly need")
                AtriaMetricTile(label: "Efficiency",
                                value: currentSleep?.sleepEfficiencyText ?? "--",
                                state: currentSleep?.sleepEfficiency == nil ? .learning : .research,
                                tint: .cyan,
                                footnote: "Duration-based estimate")
            }

            if let currentSleep {
                if currentSleep.displayStageSegments.isEmpty {
                    AtriaSleepStageBuildingSummary(night: currentSleep)
                } else {
                    AtriaSleepStageSummary(night: currentSleep)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    /// One sleep-performance number for this whole screen (UX audit
    /// inconsistency fix, 2026-07-07): live snapshot + the rollup path's
    /// yesterday-strain semantics. The Sleep row detail and the Performance
    /// tile both read this.
    private var sleepPerformancePercentUnified: Int? {
        let sleepHistory = vitalsStore.state.sleepHistorySnapshot
        guard let currentMainSleep else { return nil }
        return sleepHistory.sleepPerformancePercent(for: currentMainSleep,
                                                     baseNeedHours: sleepBaseNeedHours,
                                                     yesterdayStrain: yesterdayStrainForLatestNight)
    }

    private var yesterdayStrainForLatestNight: Double? {
        guard let latest = currentMainSleep else { return nil }
        let calendar = Calendar.current
        guard let priorDay = calendar.date(byAdding: .day,
                                           value: -1,
                                           to: calendar.startOfDay(for: latest.day)) else { return nil }
        return vitalsStore.state.dailyRollupHistory
            .first { calendar.isDate($0.day, inSameDayAs: priorDay) }?
            .strain
    }

    private var sleepPerformanceValue: String {
        guard let performance = sleepPerformancePercentUnified else { return "--" }
        return "\(performance)%"
    }

    /// Mounts the multi-metric trend chart (resting HR / strain / HRV, with
    /// its own range picker) that previously rendered nowhere in the live
    /// app -- the single highest-leverage fix in the visibility audit.
    private var fitnessAgeCard: some View {
        Button {
            showHealthspanDetail = true
        } label: {
            AtriaHealthFitnessAgeCardHost(profileMetricsStore: profileMetricsStore)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Healthspan details")
    }

    // Detected-workout review discoverability (2026-07-17): unconfirmed
    // activity candidates and the reversible dismissed-detections list live
    // with History. The host owns its own narrow observation, keeping
    // candidate publications outside this chart-heavy hierarchy.
    @ViewBuilder
    private func detectedActivitiesAndHistory(
        historyProjection: AtriaHistoryProjection
    ) -> some View {
        AtriaDetectedActivitiesHost(store: store,
                                    restingHeartRateFallback: { [heroStore] in
                                        heroStore.state.restingHeartRate
                                    },
                                    onCandidateDaysChange: { days in
                                        guard days != historyReviewCandidateDays else { return }
                                        historyReviewCandidateDays = days
                                    })
        AtriaHistorySection(model: historyProjection.model,
                            revisionKey: historyProjection.key,
                            store: store)
            .equatable()
    }

    private var trendsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trends")
                .font(.title2.weight(.bold))
            AtriaVitalsTrendChartHost(state: vitalsStore.state)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    /// First-class breathwork entry point (gap b, 2026-07-05): the pacer
    /// already exists (`AtriaBreathworkSession`) and is complete, it just had
    /// no front door on the Health screen.
    private var breathworkCard: some View {
        Button {
            showBreathworkSession = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wind")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Metrics.electricGreen)
                    .frame(width: 36, height: 36)
                    .background(AtriaIconTileBackground(cornerRadius: AtriaDesignTokens.Radius.chip, tint: Metrics.electricGreen))

                Text("Breathwork")
                    .font(.headline.weight(.bold))

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityLabel("Start breathwork")
        .accessibilityHint("Opens a guided paced-breathing session tracked from heart rate.")
    }

    private func healthMonitorCard(live: AtriaHealthMonitorLiveProjection) -> some View {
        let currentMetrics = currentMetricProjection(live: live)
        return VStack(alignment: .leading, spacing: 14) {
            header(live: live)

            // Disconnected honesty: Hero remains the active-cycle authority,
            // but its last projection is clearly labelled instead of borrowing
            // a civil-day rollup.
            if let notice = AtriaHealthConnectionEvidencePresentation.notice(
                status: live.connectionStatus,
                hasEvidence: currentMetrics.hasEvidence
            ) {
                HStack(spacing: 10) {
                    Image(systemName: notice.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(notice.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if notice.allowsRetry {
                        Button("Retry") {
                            ble.startScan(reason: "health_monitor_reconnect")
                        }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            }

            // The design reference uses one Health Monitor surface rather than
            // a card around every metric. Two compact groups preserve that
            // hierarchy while avoiding a nine-card vertical wall.
            monitorGroupKicker("Readiness")

            LazyVGrid(columns: monitorGridColumns, alignment: .leading, spacing: 8) {
                AtriaHealthMetricRow(title: "Recovery",
                                     value: recoveryValue(live: live),
                                     detail: recoveryDetail(live: live),
                                     systemImage: "heart.fill",
                                     tint: recoveryTint(live: live),
                                     hint: recoveryHint,
                                     layout: .compactTile,
                                     onTap: { educationTopic = .recovery })
                AtriaHealthMetricRow(title: "Resting HR",
                                     value: restingHeartRateValue(live: live),
                                     detail: restingHeartRateDetail(live: live),
                                     systemImage: "heart.text.square.fill",
                                     tint: Metrics.electricRHR,
                                     rangeText: restingHeartRateRangeText,
                                     hint: restingHeartRateHint,
                                     layout: .compactTile,
                                     onTap: { educationTopic = .restingHeartRate })
                AtriaHealthMetricRow(title: "HRV",
                                     value: hrvValue(live: live),
                                     detail: hrvDetail(live: live),
                                     systemImage: "waveform.path.ecg",
                                     tint: Metrics.electricHRV,
                                     rangeText: hrvRangeText,
                                     hint: hrvHint,
                                     layout: .compactTile,
                                     onTap: { educationTopic = .hrv })
            }
            .opacity(isDisconnected(live: live) && currentMetrics.hasEvidence ? 0.65 : 1)

            // Stress owns a timeline and action, so it remains full width while
            // the glanceable readiness metrics use a compact adaptive grid.
            AtriaHealthStressSection(behaviorJournalEntries: store.behaviorJournalEntries,
                                     isActive: isActive,
                                     stressMonitorStore: stressMonitorStore,
                                     breathworkStressStore: breathworkStressStore,
                                     onStartBreathwork: {
                                         showBreathworkSession = true
                                     },
                                     onOpenEducation: { educationTopic = .stress })
                .opacity(isDisconnected(live: live) && currentMetrics.hasEvidence ? 0.65 : 1)

            monitorGroupKicker("Sleep & body")

            LazyVGrid(columns: monitorGridColumns, alignment: .leading, spacing: 8) {
                AtriaHealthMetricRow(title: "Respiration",
                                     value: respiratoryValue,
                                     detail: respiratoryDetail,
                                     systemImage: "lungs.fill",
                                     tint: Metrics.electricRespiratory,
                                     rangeText: respiratoryRangeText,
                                     hint: respiratoryHint,
                                     layout: .compactTile,
                                     onTap: { educationTopic = .respiration })
                AtriaHealthMetricRow(title: "Sleep",
                                     value: sleepValue,
                                     detail: sleepDetail,
                                     systemImage: "moon.fill",
                                     tint: Metrics.electricSleep,
                                     hint: sleepHint,
                                     layout: .compactTile,
                                     onTap: { educationTopic = .sleep })
                // Visibility/IA fix (2026-07-05): three rows that previously had
                // no home on the live Vitals tab. Each opens the real detail
                // sheet (section 3), not just the education sheet, per spec.
                AtriaHealthMetricRow(title: "VO2 max",
                                     value: live.vo2MaxEstimate.valueText,
                                     detail: live.vo2MaxEstimate.compactStatusText,
                                     systemImage: "lungs.fill",
                                     tint: live.vo2MaxEstimate.value == nil
                                        ? .secondary
                                        : Metrics.electricGreen,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .vo2max })
                AtriaHealthMetricRow(title: "Skin temp",
                                     value: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                        && vitalsStore.state.skinTemperatureDeviationSummary.isReady
                                        ? vitalsStore.state.skinTemperatureDeviationSummary.valueText
                                        : "--",
                                     detail: AtriaExperimentalSensorCopy.skinTemperatureStatus(
                                        summary: vitalsStore.state.skinTemperatureDeviationSummary,
                                        decoderAvailable: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable),
                                     systemImage: "thermometer.variable",
                                     tint: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
                                        && vitalsStore.state.skinTemperatureDeviationSummary.isReady
                                        ? Metrics.electricRespiratory
                                        : .secondary,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .skinTemperature })
                AtriaHealthMetricRow(title: "SpO2",
                                     // Was a lone em dash, sitting directly
                                     // beside a Skin temp row already showing
                                     // "--" for the same state.
                                     value: AtriaCompactMetricPresentation.noValue,
                                     detail: AtriaExperimentalSensorCopy.bloodOxygenStatus(
                                        strapModel: ble.strapModel,
                                        decoderAvailable: AtriaResearchProbe.validatedSpO2DecoderAvailable),
                                     systemImage: "drop.degreesign",
                                     tint: .secondary,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .bloodOxygen })
            }
            // Dimmed while disconnected: these are saved values, not a live
            // read (paired with the last-known row above).
            .opacity(isDisconnected(live: live) && currentMetrics.hasEvidence ? 0.65 : 1)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    /// Complete rows avoid the large half-empty grid rows visible on compact
    /// phones. Very large text gets two columns before accessibility sizes
    /// return to one full-width item, keeping titles and values readable.
    private var monitorGridColumns: [GridItem] {
        let count = AtriaHealthMonitorGrid.columnCount(for: dynamicTypeSize)
        let minimum: CGFloat = count == 3 ? 76 : 112
        return Array(repeating: GridItem(.flexible(minimum: minimum),
                                         spacing: 8,
                                         alignment: .top),
                     count: count)
    }

    @MainActor
    private func refreshHistoricalHeartRatePoints() async {
        guard debugShowsHeartRateTimeline else { return }
        let since: Date? = nil
        let limit = 6_000
        isLoadingHistoricalHeartRatePoints = true
        let points = await Task.detached(priority: .utility) {
            HistoricalArchive.metricHeartRatePoints(since: since, limit: limit).map {
                AtriaHomeModel.HeartRateChartPoint(t: $0.t, bpm: $0.bpm)
            }
        }.value
#if DEBUG
        AtriaDebugLog("ATRIADBG hist1_timeline_fixture status=loaded points=%d since=%@ limit=%d",
                      points.count,
                      since.map { ISO8601DateFormatter().string(from: $0) } ?? "full_archive",
                      limit)
#endif
        isLoadingHistoricalHeartRatePoints = false
        if points != historicalHeartRatePoints {
            historicalHeartRatePoints = points
        }
#if DEBUG
        UserDefaults.standard.set(false, forKey: Self.debugOpenHeartRateTimelineKey)
#endif
    }

    #if DEBUG
    private static func debugOpensHeartRateTimeline(arguments: [String]) -> Bool {
        if UserDefaults.standard.bool(forKey: debugOpenHeartRateTimelineKey) {
            return true
        }
        if ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"] == "heart-rate-timeline" {
            return true
        }
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex else { return false }
        return arguments[valueIndex] == "heart-rate-timeline"
    }
    #else
    private static func debugOpensHeartRateTimeline(arguments: [String]) -> Bool { false }
    #endif

    #if DEBUG
    private static func debugOpensTrendsScope(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex else { return false }
        return arguments[valueIndex] == "detected-activities"
    }

    /// Opens the Sleep scope, mirroring the Trends hook above and existing for
    /// the same stated reason: simctl cannot scroll or tap, so a scope only
    /// reachable through the segmented control could not be screenshot-verified
    /// at all. Trends and Live already had a route; Sleep was the one blind spot.
    private static func debugOpensSleepScope(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard valueIndex < arguments.endIndex else { return false }
        return arguments[valueIndex] == "sleep-scope"
    }
    #else
    private static func debugOpensTrendsScope(arguments: [String]) -> Bool { false }
    private static func debugOpensSleepScope(arguments: [String]) -> Bool { false }
    #endif

    private func monitorGroupKicker(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.black))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func header(live: AtriaHealthMonitorLiveProjection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health Monitor")
                    .font(.title2.weight(.bold))
            }

            Spacer(minLength: 8)

            Text(statusValue(live: live))
                .font(.caption.weight(.bold))
                .foregroundStyle(statusTint(live: live))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusTint(live: live).opacity(0.12), in: Capsule(style: .continuous))
        }
    }

    /// Retained for explicitly dated historical projections and its focused
    /// performance contract. It is intentionally not used by current Vitals.
    final class LatestRollupCache {
        private var revision: Int?
        private var day: Date?
        private var cached: DailyRollupStoreEntry?

        func latest(revision: Int,
                    day: Date = .distantPast,
                    compute: () -> DailyRollupStoreEntry?) -> DailyRollupStoreEntry? {
            if revision != self.revision || day != self.day {
                self.revision = revision
                self.day = day
                cached = compute()
            }
            return cached
        }
    }

    private func currentMetricProjection(
        live: AtriaHealthMonitorLiveProjection
    ) -> AtriaHealthMetricAuthority.Projection {
        AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: live.recoveryPercent,
            recoveryDetail: live.recoveryDetail,
            restingHeartRateText: live.restingHeartRateText,
            hrvValue: live.hrvValue,
            hrvDetail: live.hrvDetail
        )))
    }

    private func recoveryValue(live: AtriaHealthMonitorLiveProjection) -> String {
        currentMetricProjection(live: live).recoveryValue
    }

    private func recoveryDetail(live: AtriaHealthMonitorLiveProjection) -> String {
        currentMetricProjection(live: live).recoveryDetail
    }

    private func recoveryTint(live: AtriaHealthMonitorLiveProjection) -> Color {
        if let value = currentMetricProjection(live: live).recoveryPercent {
            return Metrics.recoveryColor(value)
        }
        return .secondary
    }

    private func restingHeartRateValue(live: AtriaHealthMonitorLiveProjection) -> String {
        currentMetricProjection(live: live).restingHeartRateValue
    }

    private func restingHeartRateDetail(live: AtriaHealthMonitorLiveProjection) -> String {
        currentMetricProjection(live: live).restingHeartRateDetail
    }

    private func hrvValue(live: AtriaHealthMonitorLiveProjection) -> String {
        currentMetricProjection(live: live).hrvValue
    }

    private func hrvDetail(live: AtriaHealthMonitorLiveProjection) -> String {
        currentMetricProjection(live: live).hrvDetail
    }

    private var respiratoryValue: String {
        // Respiration is an overnight metric. An older retained history night
        // must not leak into the current wake-to-wake card after a no-sleep
        // rollover; the sleep snapshot already merges any matching rollup
        // respiratory evidence into the current night.
        guard let value = currentMainSleep?.respiratoryRate else {
            // Matches every sibling Health Monitor row. Those siblings have all
            // moved onto the deterministic no-value token, so keeping the word
            // here would make respiration the only row speaking the old
            // vocabulary. The "learns after a night" nuance lives in the detail
            // line, where it belongs -- the value line carries a numeral or "--".
            return AtriaCompactMetricPresentation.noValue
        }
        return String(format: "%.1f rpm", value)
    }

    private var respiratoryDetail: String {
        AtriaHealthMetricEvidencePresentation.respiratoryDetail(
            valueAvailable: respiratoryValue != AtriaCompactMetricPresentation.noValue
        )
    }

    private var sleepValue: String {
        guard let seconds = currentMainSleep?.duration else {
            // Consistent with Today/Overview, which now use the deterministic token.
            return AtriaCompactMetricPresentation.noValue
        }
        return AtriaMetricFormat.sleepDuration(seconds: seconds)
    }

    private var sleepDetail: String {
        // Same unified number as the Performance tile below; the persisted
        // rollup only backstops when no live night exists.
        if let performance = sleepPerformancePercentUnified {
            return "\(performance)% need"
        }
        return "No sleep this cycle"
    }

    // MARK: Stress (AtriaStressMonitor)

    /// Downsample the session stress history for display (perf handoff #2). The
    /// raw history is up to ~1440 pts (12h @ 30s); the strip drew an AreaMark + a
    /// LineMark PER point (~2880 marks) on every body eval — the worst scroll-jank
    /// offender on Vitals. Bucket each contiguous run so the whole strip stays near
    /// `targetTotal` display points, averaging the REAL activation per bucket
    /// (nothing synthesized). A gap longer than 5 minutes (well beyond the ~30s
    /// cadence) starts a NEW segment so Swift Charts leaves a real blank instead of
    /// interpolating across a stretch the strap wasn't read — the honesty contract
    /// the store comments promise. Runs in `.onChange`, never in body; the reduced
    /// array feeds an Equatable chart subview so unrelated re-renders (the 5s stress
    /// tick, live-pulse publishes) don't re-lay-out the chart.
    // `internal` (not private) so AtriaPerfFixesTests can exercise the honesty
    // contract + downsample bound directly against `@testable import Atria`.
    static func reduceStressStrip(_ history: [AtriaStressMonitorStore.StressHistoryPoint],
                                  targetTotal: Int = 110) -> [StressStripPoint] {
        guard history.count > 1 else { return [] }

        // Contiguous runs, split on a >5min gap.
        var segments: [[AtriaStressMonitorStore.StressHistoryPoint]] = []
        var current: [AtriaStressMonitorStore.StressHistoryPoint] = []
        for (index, point) in history.enumerated() {
            if index > 0, point.t.timeIntervalSince(history[index - 1].t) > 5 * 60 {
                segments.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }

        let total = history.count
        var out: [StressStripPoint] = []
        out.reserveCapacity(min(total, targetTotal + segments.count))
        var emittedID = 0
        for (segmentIndex, segment) in segments.enumerated() {
            let reduced: [(t: Date, value: Double)]
            if total <= 150 || segment.count <= 2 {
                // Already legible / too small to thin — keep full fidelity.
                reduced = segment.map { ($0.t, $0.activation * 3) }
            } else {
                // Budget proportional to this run's share of the readings (>=2 so a
                // real run never collapses to a single point).
                let budget = max(2, Int((Double(segment.count) / Double(total)
                                         * Double(targetTotal)).rounded()))
                reduced = Self.bucketStressSegment(segment, targetBuckets: budget)
            }
            for pair in reduced {
                out.append(StressStripPoint(id: emittedID, t: pair.t,
                                            value: pair.value, segment: segmentIndex))
                emittedID += 1
            }
        }
        return out
    }

    /// Time-bucket one contiguous run to ~`targetBuckets` points, averaging the
    /// activation of the samples that fall in each bucket (the real mean, matching
    /// the HR chart's `smoothedBuckets`). Value is the 0-1 activation scaled x3 to
    /// the chart's 0...3 domain — identical to the raw 1:1 mapping.
    private static func bucketStressSegment(_ segment: [AtriaStressMonitorStore.StressHistoryPoint],
                                            targetBuckets: Int) -> [(t: Date, value: Double)] {
        guard let first = segment.first?.t, let last = segment.last?.t, last > first,
              segment.count > targetBuckets else {
            return segment.map { ($0.t, $0.activation * 3) }
        }
        let span = last.timeIntervalSince(first)
        let width = span / Double(targetBuckets)
        var grouped: [Int: [Double]] = [:]
        for point in segment {
            let index = min(targetBuckets - 1, Int(point.t.timeIntervalSince(first) / width))
            grouped[index, default: []].append(point.activation)
        }
        return grouped.keys.sorted().compactMap { index in
            guard let activations = grouped[index], !activations.isEmpty else { return nil }
            let center = first.addingTimeInterval((Double(index) + 0.5) * width)
            let avg = activations.reduce(0, +) / Double(activations.count)
            return (center, avg * 3)
        }
    }

    // MARK: Typical-for-you reference ranges (only shown once a baseline is trusted)

    private var restingHeartRateRangeText: String? {
        let baseline = vitalsStore.state.baseline
        guard baseline.hasTrustedRestingBaseline(),
              let stats = baseline.restingStats, stats.count > 1 else { return nil }
        return Self.typicalRangeText(mean: stats.mean, sd: stats.sd, unit: "bpm", decimals: 0)
    }

    private var hrvRangeText: String? {
        let baseline = vitalsStore.state.baseline
        guard baseline.hasTrustedHRVBaseline(),
              let stats = baseline.lnRMSSDStats, stats.count > 1 else { return nil }
        let low = exp(stats.mean - 1.5 * stats.sd)
        let high = exp(stats.mean + 1.5 * stats.sd)
        return Self.typicalRangeText(low: max(low, 0), high: high, unit: "ms", decimals: 0)
    }

    private var respiratoryRangeText: String? {
        guard let stats = vitalsStore.state.sleepHistorySnapshot.respiratoryBaselineStats, stats.count > 1 else { return nil }
        return Self.typicalRangeText(mean: stats.mean, sd: stats.sd, unit: "rpm", decimals: 1)
    }

    private static func typicalRangeText(mean: Double, sd: Double, unit: String, decimals: Int) -> String {
        typicalRangeText(low: mean - 1.5 * sd, high: mean + 1.5 * sd, unit: unit, decimals: decimals)
    }

    private static func typicalRangeText(low: Double, high: Double, unit: String, decimals: Int) -> String {
        let format = "%.\(decimals)f"
        let lowText = String(format: format, max(low, 0))
        let highText = String(format: format, max(high, low))
        return "Typical for you: \(lowText)\u{2013}\(highText) \(unit)"
    }

    /// Feeds the tap-education sheet's "Your typical range" section. `nil`
    /// falls back to the topic's honest "still building" copy inside the
    /// sheet itself -- recovery, stress, and sleep are never range-based.
    private func typicalRangeText(for topic: AtriaVitalsEducationTopic) -> String? {
        switch topic {
        case .restingHeartRate: return restingHeartRateRangeText
        case .hrv: return hrvRangeText
        case .respiration: return respiratoryRangeText
        case .recovery, .stress, .sleep: return nil
        }
    }

    // MARK: Suboptimal-zone hint chips (only when a trusted comparison exists)

    private var recoveryHint: String? {
        guard let value = heroStore.state.recoveryEstimate.percent,
              value < 34 else { return nil }
        return "Low \u{2014} prioritize rest today"
    }

    private var restingHeartRateHint: String? {
        let baseline = vitalsStore.state.baseline
        let today = Int(heroStore.state.restingHeartRateText)
        guard baseline.hasTrustedRestingBaseline(),
              let stats = baseline.restingStats, stats.count > 1, stats.sd > 0,
              let today else { return nil }
        let z = (Double(today) - stats.mean) / stats.sd
        guard z > 1.5 else { return nil }
        return "\u{2191} elevated \u{2014} try earlier bedtime"
    }

    private var hrvHint: String? {
        let baseline = vitalsStore.state.baseline
        let hrvMS = Int(heroStore.state.hrvValue)
        guard baseline.hasTrustedHRVBaseline(),
              let stats = baseline.lnRMSSDStats, stats.count > 1, stats.sd > 0,
              let hrvMS, hrvMS > 0 else { return nil }
        let lnRMSSD = log(Double(hrvMS))
        let z = (lnRMSSD - stats.mean) / stats.sd
        guard z < -1.5 else { return nil }
        return "\u{2193} below typical \u{2014} ease today's training"
    }

    private var respiratoryHint: String? {
        let sleepHistory = vitalsStore.state.sleepHistorySnapshot
        guard let stats = sleepHistory.respiratoryBaselineStats, stats.count > 1, stats.sd > 0,
              let value = currentMainSleep?.respiratoryRate else { return nil }
        let z = (value - stats.mean) / stats.sd
        guard z > 1.5 else { return nil }
        return "\u{2191} elevated \u{2014} track how you feel"
    }

    private var currentMainSleep: SleepHistorySnapshot.Night? {
        AtriaHealthCurrentSleepEvidence.resolve(
            from: vitalsStore.state.sleepHistorySnapshot
        )
    }

    private var sleepHint: String? {
        let debtText = vitalsStore.state.sleepHistorySnapshot.sleepDebtText(goalHours: sleepGoalHours)
        guard debtText != "--", debtText != "Met" else { return nil }
        return "\u{2193} \(debtText) debt \u{2014} earlier bedtime tonight"
    }

    private func statusValue(live: AtriaHealthMonitorLiveProjection) -> String {
        guard currentMetricProjection(live: live).hasEvidence else {
            return AtriaCompactMetricPresentation.noValue
        }
        // Connection alone does not prove that Recovery, RHR, and HRV were
        // recomputed just now. These values belong to the active
        // physiological cycle, so name that scope instead of claiming a fresh
        // update without a metric timestamp.
        return isDisconnected(live: live) ? "Last known" : "Current cycle"
    }

    private func isDisconnected(live: AtriaHealthMonitorLiveProjection) -> Bool {
        live.connectionStatus != .connected
    }

    private func statusTint(live: AtriaHealthMonitorLiveProjection) -> Color {
        guard currentMetricProjection(live: live).hasEvidence else {
            return .secondary
        }
        return isDisconnected(live: live) ? .secondary : .cyan
    }
}

/// Keeps the Vitals screen itself off the live pulse invalidation path while an
/// open breathwork session continues receiving every HR and RR update.
private struct AtriaHealthBreathworkSessionHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var stressStore: AtriaHealthBreathworkStressStore
    let onSave: (SavedSession) -> Void
    let onClose: () -> Void

    var body: some View {
        AtriaBreathworkSession(currentHeartRate: pulseStore.state.heartRate,
                               currentRRSamples: pulseStore.state.recentRRSamples,
                               currentStress: stressStore.reading,
                               onSave: onSave,
                               onClose: onClose)
    }
}

private struct AtriaHealthStressSection: View {
    let behaviorJournalEntries: [BehaviorJournalEntry]
    let isActive: Bool
    @ObservedObject var stressMonitorStore: AtriaStressMonitorStore
    let breathworkStressStore: AtriaHealthBreathworkStressStore
    let onStartBreathwork: () -> Void
    let onOpenEducation: () -> Void

    @State private var stressStripReduced: [StressStripPoint] = []
    @State private var lastStressEvaluationAt: Date?
    @State private var showStressDetail = false

    var body: some View {
        Group {
            AtriaHealthMetricRow(title: "Stress",
                                 value: stressValue,
                                 detail: stressDetail,
                                 systemImage: "bolt.heart.fill",
                                 tint: stressTint,
                                 hint: stressHint,
                                 onTap: { showStressDetail = true })
            stressHistoryStrip
        }
        .onChange(of: isActive, initial: true) { _, active in
            guard active else { return }
            publishStressForBreathwork()
        }
        .onChange(of: stressMonitorStore.lastMeasuredAt, initial: true) { _, _ in
            publishStressForBreathwork()
        }
        .onChange(of: stressMonitorStore.state, initial: true) { _, _ in
            publishStressForBreathwork()
        }
        .onChange(of: stressMonitorStore.historyRevision, initial: true) { _, _ in
            stressStripReduced = AtriaHealthScreen.reduceStressStrip(stressMonitorStore.history)
        }
        .fullScreenCover(isPresented: $showStressDetail) {
            AtriaStressDetailView(
                input: AtriaStressDetailInput(state: stressMonitorStore.state,
                                              history: stressMonitorStore.history,
                                              updatedAt: lastStressEvaluationAt,
                                              distributionComparison: stressMonitorStore.distributionComparison(),
                                              loggedContext: todayLoggedContext),
                onDismiss: { showStressDetail = false },
                onRelax: {
                    showStressDetail = false
                    Task { @MainActor in
                        await Task.yield()
                        onStartBreathwork()
                    }
                },
                onInfo: {
                    showStressDetail = false
                    Task { @MainActor in
                        await Task.yield()
                        onOpenEducation()
                    }
                }
            )
        }
    }

    private var todayLoggedContext: [AtriaStressLoggedContext] {
        let calendar = Calendar.current
        let tags = behaviorJournalEntries
            .filter { calendar.isDateInToday($0.day) }
            .flatMap(\.tags)
        var seen = Set<String>()
        return tags.compactMap { tag in
            guard seen.insert(tag.rawValue).inserted else { return nil }
            return AtriaStressLoggedContext(tag: tag)
        }
    }

    private func publishStressForBreathwork() {
        let measuredAt = stressMonitorStore.lastMeasuredAt
        lastStressEvaluationAt = measuredAt
        breathworkStressStore.update(
            AtriaBreathworkStressReading(state: stressMonitorStore.state,
                                         measuredAt: measuredAt)
        )
    }

    /// Falls back to the deterministic no-value token, not to the state's label.
    /// Falling back to the label put "No signal" on the VALUE line while every
    /// sibling row showed "--" -- a third vocabulary for one state. The reason is
    /// not lost: `stressDetail` below already surfaces that same label as the
    /// detail, which is where an explanation belongs.
    private var stressValue: String {
        AtriaStressPresentation.make(state: stressMonitorStore.state).value
    }

    private var stressDetail: String {
        AtriaStressPresentation.make(state: stressMonitorStore.state).detail
    }

    private var stressHistoryStrip: some View {
        Group {
            if let first = stressStripReduced.first, let last = stressStripReduced.last,
               last.t.timeIntervalSince(first.t) >= 10 * 60 {
                VStack(alignment: .leading, spacing: 6) {
                    AtriaStressStripChart(points: stressStripReduced)
                        .equatable()
                        .frame(height: 56)
                        .clipped()
                        .atriaInspectableGraph(
                            AtriaInspectableGraph(
                                title: "Session stress",
                                subtitle: "Observed readings only; blanks are collection gaps",
                                content: .timeSeries([
                                    .init(title: "Stress",
                                          unit: "",
                                          tint: .orange,
                                          points: stressStripReduced.map {
                                              .init(date: $0.t,
                                                    value: $0.value,
                                                    segment: $0.segment)
                                          })
                                ])
                            )
                        )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Stress history for this session, \(stressStripReduced.count) readings.")
            }
        }
    }

    private var stressTint: Color {
        stressMonitorStore.state.level?.tint ?? .secondary
    }

    private var stressHint: String? {
        guard stressMonitorStore.state.level == .high else { return nil }
        return "High \u{2014} try a few slow breaths"
    }
}

/// Narrow sibling-to-presentation bridge for measured stress. The large Health
/// screen holds this as plain `@State` identity; only the full-screen host uses
/// `@ObservedObject`, so live feedback updates cannot invalidate every Vitals
/// chart and metric row behind it.
@MainActor
private final class AtriaHealthBreathworkStressStore: ObservableObject {
    @Published private(set) var reading: AtriaBreathworkStressReading?

    func update(_ next: AtriaBreathworkStressReading?) {
        guard next != reading else { return }
        reading = next
    }
}

/// One downsampled+segmented session-stress reading (perf handoff #2). A gap
/// longer than 5 minutes bumps `segment`, which Swift Charts treats as a new
/// series so the strip leaves a real blank instead of interpolating across a
/// stretch the strap wasn't read (the honesty contract).
// `internal` (not private) so AtriaPerfFixesTests can assert on the reduced strip.
struct StressStripPoint: Identifiable, Equatable {
    let id: Int
    let t: Date
    let value: Double
    let segment: Int
}

/// The session-stress area strip, isolated behind `Equatable` so it re-lays-out
/// ONLY when the reduced points change — not on every parent re-render (the 5s
/// stress tick, live-pulse publishes). Points are already downsampled to ~110
/// (see `AtriaHealthScreen.reduceStressStrip`); this view just draws them.
private struct AtriaStressStripChart: View, Equatable {
    let points: [StressStripPoint]

    static func == (lhs: AtriaStressStripChart, rhs: AtriaStressStripChart) -> Bool {
        lhs.points == rhs.points
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.t),
                         y: .value("Stress", point.value),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.orange.opacity(0.16))
                LineMark(x: .value("Time", point.t),
                         y: .value("Stress", point.value),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.orange.gradient)
            }
            RuleMark(y: .value("Medium", 1))
                .foregroundStyle(.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            RuleMark(y: .value("High", 2))
                .foregroundStyle(.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
        .chartYScale(domain: 0...3)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }
}

private struct AtriaHealthFitnessAgeCard: View, Equatable {
    let summary: BiologicalAgeSummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEstimateDetails = false
    /// Counts up from 0 to |ageDelta| on reveal via a spring-driven
    /// `.numericText()` transition. Static (set directly, no animation) when
    /// Reduce Motion is on. Whole years only -- `ageDelta` is an `Int`, so no
    /// decimal is fabricated.
    @State private var animatedDeltaMagnitude: Int = 0

    static func == (lhs: AtriaHealthFitnessAgeCard, rhs: AtriaHealthFitnessAgeCard) -> Bool {
        lhs.summary == rhs.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.stand.line.dotted.figure.stand")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(AtriaIconTileBackground(cornerRadius: AtriaDesignTokens.Radius.chip, tint: tint))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Fitness age")
                        .font(.headline.weight(.bold))
                    if summary.isReady {
                        deltaRevealRow
                        if let qualifier = summary.earlyEstimateQualifierText {
                            // Early phase (14–27 days): the estimate never
                            // carries the same visual authority as a confident
                            // one — an unmissable calibration-orange qualifier
                            // with day-count progress sits under the delta.
                            Text(qualifier)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    } else if summary.isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating weekly estimate")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(summary.compactStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Text(summary.valueText)
                    .font(.system(.title3, design: .rounded, weight: .black))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(tint)
            }

            if summary.isReady {
                DisclosureGroup(isExpanded: $showsEstimateDetails) {
                    Text(summary.agingPaceDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Label("How it's estimated", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .tint(tint)
                .accessibilityHint("Shows the inputs behind this estimate.")
            } else {
                Text(summary.blockerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(summary.footnote)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fitness age. \(summary.valueText). \(summary.isReady ? summary.detailText : summary.isRefreshing ? "Updating weekly estimate" : "Calibrating 28-day baseline").\(summary.earlyEstimateQualifierText.map { " \($0)." } ?? "") \(summary.footnote)")
        .onAppear { syncAnimatedDelta() }
        .onChange(of: summary) { _, _ in syncAnimatedDelta() }
    }

    private var deltaRevealRow: some View {
        let ageDelta = summary.ageDelta ?? 0
        return HStack(spacing: 4) {
            if ageDelta != 0 {
                Image(systemName: ageDelta < 0 ? "arrow.down.right" : "arrow.up.right")
                    .font(.caption2.weight(.bold))
            }
            Text(deltaLineText(ageDelta: ageDelta))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(animatedDeltaMagnitude)))
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(tint)
    }

    private func deltaLineText(ageDelta: Int) -> String {
        guard ageDelta != 0 else { return "Matches your age" }
        return "\(animatedDeltaMagnitude)y \(ageDelta < 0 ? "younger" : "older")"
    }

    private func syncAnimatedDelta() {
        let target = abs(summary.ageDelta ?? 0)
        guard summary.isReady else {
            animatedDeltaMagnitude = 0
            return
        }
        guard !reduceMotion else {
            animatedDeltaMagnitude = target
            return
        }
        animatedDeltaMagnitude = 0
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) {
            animatedDeltaMagnitude = target
        }
    }

    /// Green when at or below chronological age ("younger"), amber
    /// (electric-yellow) when above ("older") -- matches the app-wide
    /// green/amber/red vocabulary. Orange while still calibrating, including
    /// the early-estimate phase (14–27 days): an early value must never wear
    /// the confident green/amber authority.
    private var tint: Color {
        guard summary.isReady else { return .secondary }
        guard !summary.isEarlyEstimate else { return .orange }
        return (summary.ageDelta ?? 0) <= 0 ? Metrics.electricGreen : Metrics.electricYellow
    }
}

private struct AtriaHealthTimelineProofCard: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let isLoading: Bool
    @State private var selectedTime: Date?

    private var series: AtriaHeartRateChartSeries {
        AtriaHeartRateChartSeries.make(points: points, zoom: 1)
    }

    private var countText: String {
        points.isEmpty ? (isLoading ? "Loading archive" : "No archive points") : "\(points.count) points"
    }

    private var rangeText: String {
        guard let first = points.first?.t,
              let last = points.last?.t else {
            return "Waiting for metric-ready archive rows"
        }
        return "\(first.formatted(date: .abbreviated, time: .shortened)) - \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    static func == (lhs: AtriaHealthTimelineProofCard, rhs: AtriaHealthTimelineProofCard) -> Bool {
        lhs.points == rhs.points && lhs.isLoading == rhs.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heart-rate timeline")
                        .font(.title2.weight(.bold))
                    Text(rangeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(countText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(points.isEmpty ? Color.secondary : Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((points.isEmpty ? Color.secondary : Color.red).opacity(0.12),
                                in: Capsule(style: .continuous))
            }

            AtriaHeartRateAxisChart(points: series.visiblePoints,
                                     yDomain: series.yDomain,
                                     buckets: series.buckets,
                                     selectedTime: $selectedTime)
                .frame(height: 430)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Heart-rate timeline proof. \(countText). \(rangeText).")
    }
}

private struct AtriaHealthMetricRow: View, Equatable {
    enum Layout: Equatable {
        case row
        case compactTile
    }

    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    var rangeText: String? = nil
    /// Shown only when a real trusted-baseline comparison places today's
    /// value in a suboptimal zone (e.g. elevated RHR, depressed HRV).
    var hint: String? = nil
    var layout: Layout = .row
    /// Opens the compact "what it is / your typical range / how to improve"
    /// education sheet for this metric.
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaHealthMetricRow, rhs: AtriaHealthMetricRow) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.systemImage == rhs.systemImage
            && lhs.rangeText == rhs.rangeText
            && lhs.hint == rhs.hint
            && lhs.layout == rhs.layout
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(onTap == nil ? "" : "Opens what this means and how to improve it.")
    }

    private var accessibilityLabelText: String {
        var parts = ["\(title), \(value), \(detail)."]
        if let rangeText { parts.append("\(rangeText).") }
        if let hint { parts.append(hint) }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var rowContent: some View {
        switch layout {
        case .row:
            fullWidthRowContent
        case .compactTile:
            compactTileContent
        }
    }

    private var fullWidthRowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                metricIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let rangeText {
                        Text(rangeText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }

                Spacer(minLength: 8)

                metricValue
            }

            if let hint {
                AtriaVitalsHintChip(text: hint, tint: Metrics.electricYellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 60)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
    }

    private var compactTileContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 5) {
                metricIcon
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            metricValue

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            if let hint {
                AtriaVitalsHintChip(text: hint, tint: Metrics.electricYellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(.horizontal, 1)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator).opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 0.5)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
    }

    private var metricIcon: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var metricValue: some View {
        Text(value)
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.66)
    }
}
