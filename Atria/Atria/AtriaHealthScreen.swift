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

/// Retained history is useful context when the active wake-to-wake cycle has no
/// sleep, but it must be labelled as previous and must never feed current
/// Recovery, sleep need, respiration, stages, or ring values.
enum AtriaHealthPreviousSleepEvidence {
    static func resolve(
        from snapshot: SleepHistorySnapshot
    ) -> SleepHistorySnapshot.Night? {
        snapshot.nights.first { $0.confirmed && !$0.isNapEvidence }
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
                // "needs enough wear" implied more daytime wear would produce
                // it — false since RHR became sleep-only (2026-08-04): only a
                // night can.
                restingHeartRateDetail: restingHeartRate == nil
                    ? "after tonight's sleep" : "current cycle",
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
            let strainPresentation = Metrics.StrainPresentation.resolve(
                value: rollup.strain,
                coverageFraction: rollup.strainCoverageFraction,
                baseConfidence: "dated history",
                persistedQuality: rollup.strainEvidenceQuality
            )
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
                strain: strainPresentation.value,
                strainDetail: strainPresentation.coverageText
                    ?? strainPresentation.confidence,
                strainIsPartial: strainPresentation.quality == .partial,
                wearCoverageFraction: strainPresentation.coverageFraction,
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
        // Single status carrier (2026-08-04): the header chip already names
        // the evidence scope ("Last known" / "Current cycle"); repeating it
        // here made two adjacent rows restate one fact in two vocabularies.
        // This notice now carries only the CONNECTION state (and the retry
        // affordance where reconnecting is actionable).
        case .scanning, .connecting:
            return Notice(title: "Reconnecting",
                          systemImage: "arrow.triangle.2.circlepath",
                          allowsRetry: false)
        case .poweredOff:
            return Notice(title: "Bluetooth off",
                          systemImage: "bolt.slash.fill",
                          allowsRetry: false)
        case .disconnected:
            return Notice(title: "Strap disconnected",
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
        let age = settledMorningAgeDetail(day: rollup.day,
                                          now: now,
                                          calendar: calendar)
        // Stale-carry hint (2026-07-31 device review): "72 · 2d ago" was
        // honest about age but offered no next step. A carried HRV only
        // refreshes after another confirmed sleep, so say so.
        guard age.hasSuffix("d ago") else { return age }
        return "\(age) · confirm a sleep to update"
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
    @State private var sleepStressProjection = AtriaSleepStressProjection.unavailable
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
                    // Native-clean selector (design 2026-08-05): replaces the
                    // congested `.segmented` picker with a spacious Apple-Stocks
                    // style plain-text row + sliding highlight.
                    AtriaTextSelector(items: Scope.allCases,
                                      title: { $0.rawValue },
                                      selection: $scope)
                        .padding(.horizontal, 4)

                    switch scope {
                    case .live:
                        // Today owns the compact daily summary. This is the deep,
                        // inspectable live surface: pulse timeline plus source-aware
                        // health-monitor rows and a direct breathwork action.
                        AtriaVitalsLivePulseSection(liveStore: liveStore,
                                                    pulseStore: pulseStore,
                                                    homeStatsStore: homeStatsStore,
                                                    stressMonitorStore: stressMonitorStore,
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
        .task(id: sleepStressRequestKey) {
            await refreshSleepStressProjection()
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
            AtriaAboutMetricSheet(metric: topic.aboutMetric,
                                  trend: .make(for: topic.aboutMetric,
                                               rollups: vitals.dailyRollupHistory))
        }
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
                .presentationDetents([.large])
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

    private struct SleepStressRequestKey: Equatable {
        let scope: Scope
        let nightID: String?
        let start: Date?
        let end: Date?
        let restingHeartRate: Int?
    }

    private var sleepStressRequestKey: SleepStressRequestKey {
        SleepStressRequestKey(scope: scope,
                              nightID: currentMainSleep?.id,
                              start: currentMainSleep?.start,
                              end: currentMainSleep?.end,
                              restingHeartRate: vitalsStore.state.baseline.restingInt)
    }

    @MainActor
    private func refreshSleepStressProjection() async {
        guard scope == .sleep,
              let sleep = currentMainSleep,
              let start = sleep.start,
              let end = sleep.end,
              end > start else {
            sleepStressProjection = .unavailable
            return
        }

        let restingHeartRate = vitalsStore.state.baseline.restingInt
        // Union the archive read with canonical session points and observed HR
        // history so this card cannot disagree with the Activity day-timeline HR
        // over the same sleep window. Snapshot both on MainActor before the
        // detached read.
        let sessions = store.sessions
        let observed = stressMonitorStore.heartRateHistory.map {
            HistoricalArchive.HeartRatePoint(t: $0.t, bpm: $0.bpm)
        }
        if sleepStressProjection.availability != .ready {
            sleepStressProjection = .loading
        }
        let projection = await Task.detached(priority: .utility) {
            AtriaSleepStressArchiveProjection.load(
                sleepStart: start,
                sleepEnd: end,
                restingHeartRate: restingHeartRate,
                sessions: sessions,
                observed: observed
            )
        }.value
        guard !Task.isCancelled else { return }
        sleepStressProjection = projection
    }

    /// Mounts the sleep-stage hypnogram summary (SWS/REM/Light/Awake) that
    /// previously rendered nowhere live, plus the performance/efficiency stat
    /// pair -- both computed the same honest way the Today ring and its
    /// caption are (visibilitySpec §2, 2026-07-05).
    private var sleepDetailCard: some View {
        let currentSleep = currentMainSleep
        let previousSleep = currentSleep == nil
            ? AtriaHealthPreviousSleepEvidence.resolve(
                from: vitalsStore.state.sleepHistorySnapshot
            )
            : nil
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sleep detail")
                .font(.title2.weight(.bold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                // Drill-in (design UI pass): these tiles used to be dead-taps.
                // Route them to the rich, day-organized AtriaMetricDetailSheet
                // (already wired below), matching the metric-as-object model the
                // live vital tiles already use.
                Button {
                    metricDetail = .sleepPerformance
                } label: {
                    AtriaMetricTile(label: "Sufficiency",
                                    value: sleepPerformanceValue,
                                    state: currentSleep == nil ? .learning : .local,
                                    tint: Metrics.electricSleep,
                                    // A percentage without its numerator and
                                    // denominator left the user guessing what
                                    // “80%” meant. Keep the compact value, but
                                    // show the exact recorded sleep and frozen
                                    // need receipt directly underneath it.
                                    footnote: sleepPerformanceFootnote)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens sleep sufficiency detail")
                Button {
                    metricDetail = .sleepEfficiency
                } label: {
                    AtriaMetricTile(label: "Efficiency",
                                    value: currentSleep?.sleepEfficiencyText ?? "--",
                                    // HR-only honesty (2026-08-01): without
                                    // validated motion the stored value is span
                                    // coverage, not efficiency.
                                    state: currentSleep?.displaySleepEfficiency == nil ? .learning : .research,
                                    tint: .cyan,
                                    footnote: currentSleep?.sleepEfficiencyFootnote ?? "Duration-based estimate")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens sleep efficiency detail")
            }

            if let provisionalSleepScore {
                AtriaSleepScoreCard(score: provisionalSleepScore)
            }

            if currentSleep == nil {
                HStack(spacing: AtriaDesignTokens.Spacing.md) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(Metrics.electricSleep)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No sleep recorded in this cycle")
                            .font(.caption.weight(.bold))
                        if let previousSleep {
                            Text(
                                "Last saved sleep · \(previousSleep.durationText) · "
                                    + previousSleep.day.formatted(
                                        .dateTime.day().month(.abbreviated)
                                    )
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Atria will detect and review the next qualified sleep automatically.")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .atriaInsetCard(tint: Metrics.electricSleep)
            }

            if let currentSleep {
                if currentSleep.displayStageSegments.isEmpty {
                    AtriaSleepStageBuildingSummary(night: currentSleep)
                } else {
                    AtriaSleepStageSummary(night: currentSleep)
                }

                AtriaSleepStressCard(projection: sleepStressProjection,
                                     typicalRestingBand: typicalOvernightRestingBand)
            }

            // Real bed-to-wake windows, now explicitly explained with their
            // typical schedule and spread instead of a decorative bar stack.
            AtriaSleepConsistencyStrip(nights: vitalsStore.state.sleepHistorySnapshot.nights)
        }
        // The screen already provides its own horizontal rhythm. Keeping an
        // additional container here made the metric tiles, stage evidence and
        // overnight chart compete with a redundant outer card.
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

    /// GAP-06: the provisional composite, built only from components that are
    /// independently displayable for this night — the same Sufficiency the tile
    /// shows, the canonical Consistency, and Efficiency only when motion
    /// qualified. Overnight load stays out until its model is validated.
    private var provisionalSleepScore: AtriaSleepScore? {
        guard let currentSleep = currentMainSleep else { return nil }
        let sufficiency = sleepPerformancePercentUnified.map(Double.init)
        let consistency = AtriaSleepConsistency
            .result(from: vitalsStore.state.sleepHistorySnapshot.nights)
            .combinedPercent
            .map(Double.init)
        let efficiency = currentSleep.displaySleepEfficiency.map { $0 * 100 }
        let score = AtriaSleepScore.make(sufficiencyPercent: sufficiency,
                                         consistencyPercent: consistency,
                                         efficiencyPercent: efficiency,
                                         validatedOvernightLoadPercent: nil)
        // Below the minimum present components the composite is withheld and
        // Sleep Sufficiency remains the primary measure — don't mount the card.
        return score.score == nil ? nil : score
    }

    /// GAP-07: the user's typical overnight resting-HR band from recent
    /// qualified nights, or nil below the documented minimum.
    private var typicalOvernightRestingBand: ClosedRange<Double>? {
        let restingHRs = vitalsStore.state.sleepHistorySnapshot.nights
            .filter { $0.confirmed && !$0.isNapEvidence }
            .suffix(30)
            .compactMap { $0.restingHR }
        return AtriaOvernightTypical.restingBand(restingHRs: restingHRs)
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

    private var sleepPerformanceFootnote: String {
        guard let currentMainSleep else {
            return "Needs a confirmed sleep"
        }
        return vitalsStore.state.sleepHistorySnapshot.sleepPerformanceSummary(
            for: currentMainSleep,
            baseNeedHours: sleepBaseNeedHours,
            yesterdayStrain: yesterdayStrainForLatestNight
        )
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

    // Box-in-box removed (2026-08-05 width audit): AtriaTrendChartCard already
    // draws its own card chrome AND a "Trends" section header, so the old
    // wrapper double-boxed the chart and duplicated the title, costing 16pt of
    // plot width per side.
    private var trendsCard: some View {
        AtriaVitalsTrendChartHost(state: vitalsStore.state)
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

            // Vitals IA split (user-directed, 2026-08-01): one metric family
            // per card. The former single Health Monitor surface stacked every
            // aggregate behind one fill; each tile now carries its own flat
            // card (dense content stays flat — no glass on this grid), a
            // chevron affordance, and a tap into the metric's EXISTING detail
            // sheet (the education copy lives on inside each detail sheet's
            // info button). The compact grid grouping is kept for density.
            // "Recovery" is this cluster's own vocabulary (the Recovery tile
            // + its inputs); "Readiness" was a competitor's term for the same
            // pillar (2026-08-04 WHOOP-alignment review, rank 3).
            monitorGroupKicker("Recovery")

            LazyVGrid(columns: monitorGridColumns, alignment: .leading, spacing: 8) {
                AtriaHealthMetricRow(title: "Recovery",
                                     value: recoveryValue(live: live),
                                     detail: recoveryDetail(live: live),
                                     systemImage: "heart.fill",
                                     tint: recoveryTint(live: live),
                                     hint: recoveryHint,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .recovery })
                AtriaHealthMetricRow(title: "Resting HR",
                                     value: restingHeartRateValue(live: live),
                                     detail: restingHeartRateDetail(live: live),
                                     systemImage: "heart.text.square.fill",
                                     tint: Metrics.electricRHR,
                                     rangeText: restingHeartRateRangeText,
                                     hint: restingHeartRateHint,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .restingHeartRate })
                AtriaHealthMetricRow(title: "HRV",
                                     value: hrvValue(live: live),
                                     detail: hrvDetail(live: live),
                                     systemImage: "waveform.path.ecg",
                                     tint: Metrics.electricHRV,
                                     rangeText: hrvRangeText,
                                     hint: hrvHint,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .hrv })
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
                                     onTap: { metricDetail = .respiratoryRate })
                AtriaHealthMetricRow(title: "Sleep",
                                     value: sleepValue,
                                     detail: sleepDetail,
                                     systemImage: "moon.fill",
                                     tint: Metrics.electricSleep,
                                     hint: sleepHint,
                                     layout: .compactTile,
                                     onTap: { metricDetail = .sleep })
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
        // No outer mega-card chrome (2026-08-01 Vitals IA split): the tiles
        // are the cards now, so wrapping them in a second surface would
        // reintroduce the box-inside-box stack this change removes.
        .padding(.horizontal, 2)
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
        // "/min" matches the Vitals/Overview surfaces and the detail sheet this
        // row opens (2026-08-05 audit: "rpm" reads as revolutions per minute).
        return String(format: "%.1f/min", value)
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
            return "\(performance)% of need"
        }
        return "No sleep this cycle"
    }

    // MARK: Stress (AtriaStressMonitor)

    /// Downsample the bounded live/restored physiological-stress history for
    /// display. Complete v3 HR-only facts stay on this same line with their
    /// lower-confidence provenance. The raw ring can reach 2,880 points (48h @
    /// one minute); drawing an AreaMark + LineMark per fact on every body eval
    /// would make this the worst scroll-jank
    /// offender on Vitals. Bucket each contiguous run so the whole strip stays near
    /// `targetTotal` display points, averaging the REAL activation per bucket
    /// (nothing synthesized). A gap longer than the scorer's 90-second
    /// continuity boundary starts a NEW segment so Swift Charts leaves a blank instead of
    /// interpolating across a stretch the strap wasn't read — the honesty contract
    /// the store comments promise. Runs in `.onChange`, never in body; the reduced
    /// array feeds an Equatable chart subview so unrelated re-renders (the 5s stress
    /// tick, live-pulse publishes) don't re-lay-out the chart.
    // `internal` (not private) so AtriaPerfFixesTests can exercise the honesty
    // contract + downsample bound directly against `@testable import Atria`.
    static func reduceStressStrip(_ history: [AtriaStressMonitorStore.StressHistoryPoint],
                                  targetTotal: Int = 110) -> [StressStripPoint] {
        guard history.count > 1 else { return [] }

        // Contiguous v3 runs split at the exact scorer continuity boundary.
        var segments: [[AtriaStressMonitorStore.StressHistoryPoint]] = []
        var current: [AtriaStressMonitorStore.StressHistoryPoint] = []
        for point in history.sorted(by: { $0.t < $1.t }) {
            guard point.evidenceProjection.numericStressScore != nil else {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
                continue
            }
            if let previous = current.last,
               point.t.timeIntervalSince(previous.t)
                    > AtriaPhysiologicalStressModel.maximumFactContinuityGap {
                segments.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }

        let total = segments.reduce(0) { $0 + $1.count }
        guard total > 1 else { return [] }
        var out: [StressStripPoint] = []
        out.reserveCapacity(min(total, targetTotal + segments.count))
        var emittedID = 0
        for (segmentIndex, segment) in segments.enumerated() {
            let reduced: [(t: Date, value: Double)]
            if total <= 150 || segment.count <= 2 {
                // Already legible / too small to thin — keep full fidelity.
                reduced = segment.compactMap { point in
                    point.evidenceProjection.numericStressScore.map { (point.t, $0) }
                }
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
    /// numeric Stress score of the samples that fall in each bucket (the real
    /// mean, matching the HR chart's `smoothedBuckets`). The shared evidence
    /// projection owns the 0...1 to 0...3 conversion for full and HR-only facts.
    private static func bucketStressSegment(_ segment: [AtriaStressMonitorStore.StressHistoryPoint],
                                            targetBuckets: Int) -> [(t: Date, value: Double)] {
        guard let first = segment.first?.t, let last = segment.last?.t, last > first,
              segment.count > targetBuckets else {
            return segment.compactMap { point in
                point.evidenceProjection.numericStressScore.map { (point.t, $0) }
            }
        }
        let span = last.timeIntervalSince(first)
        let width = span / Double(targetBuckets)
        var grouped: [Int: [Double]] = [:]
        for point in segment {
            guard let score = point.evidenceProjection.numericStressScore else { continue }
            let index = min(targetBuckets - 1, Int(point.t.timeIntervalSince(first) / width))
            grouped[index, default: []].append(score)
        }
        return grouped.keys.sorted().compactMap { index in
            guard let activations = grouped[index], !activations.isEmpty else { return nil }
            let center = first.addingTimeInterval((Double(index) + 0.5) * width)
            let avg = activations.reduce(0, +) / Double(activations.count)
            return (center, avg)
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
        return Self.typicalRangeText(mean: stats.mean, sd: stats.sd, unit: "/min", decimals: 1)
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

    @State private var lastStressEvaluationAt: Date?
    @State private var showStressDetail = false

    var body: some View {
        Group {
            AtriaHealthMetricRow(title: stressPresentation.metricTitle,
                                 value: stressValue,
                                 detail: stressDetail,
                                 systemImage: "bolt.heart.fill",
                                 tint: stressTint,
                                 hint: stressHint,
                                 onTap: { showStressDetail = true })
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
        .fullScreenCover(isPresented: $showStressDetail) {
            AtriaStressDetailView(
                input: AtriaStressDetailInput(state: stressMonitorStore.state,
                                              history: stressMonitorStore.history,
                                              heartRateHistory: stressMonitorStore.heartRateHistory,
                                              updatedAt: lastStressEvaluationAt,
                                              distributionComparison: stressMonitorStore.distributionComparison(),
                                              trendDays: stressMonitorStore.dailyTrendDays(),
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
        stressPresentation.value
    }

    private var stressDetail: String {
        stressPresentation.detail
    }

    private var stressPresentation: AtriaStressPresentation {
        AtriaStressPresentation.make(state: stressMonitorStore.state)
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

/// One downsampled+segmented measured stress reading. A gap
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
    /// Opens this metric's existing detail surface (2026-08-01 Vitals IA
    /// split: taps route to the metric detail sheets; the "what it is / how
    /// to improve" education copy remains one tap further, behind each detail
    /// sheet's info button).
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
        .accessibilityHint(onTap == nil ? "" : "Opens this metric's detail and trend.")
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

                if onTap != nil {
                    pressableChevron
                }
            }

            if let hint {
                AtriaVitalsHintChip(text: hint, tint: Metrics.electricYellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 60)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Family card treatment (2026-08-01 Vitals IA split): flat secondary
        // fill + chip-token radius, replacing the stray radius-8 tertiary
        // wash, so the full-width Stress row reads as its own pressable card.
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
    }

    private var compactTileContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                metricIcon
                // 0.62 floor (was 0.78): the chevron affordance costs ~12pt of
                // tile width, which truncated "Resting HR" to "Resting…" on the
                // three-column grid (2026-08-01 screenshot check).
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                Spacer(minLength: 0)
                if onTap != nil {
                    pressableChevron
                }
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
        // Vitals IA split (2026-08-01): each tile is its own flat card —
        // hairline-separated rows inside one shared surface read as one
        // aggregated block, not distinct pressable metrics. Flat fill on
        // purpose (dense grid, no glass), chip radius from the token scale.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
    }

    /// Small trailing chevron: the visible "this card presses" affordance.
    private var pressableChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
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

/// Night-only HR load from archived, observed heart-rate rows. This remains a
/// separate metric from the live Stress Monitor: it describes overnight
/// cardiac load relative to resting HR and never relabels it as psychological
/// stress or a sleep stage. Atria does not yet publish a validated in-progress
/// sleep interval authority, so this projection must not imply that the live
/// monitor independently knew the wearer was asleep at capture time.
///
/// Internal (not file-private) so the Sleep detail sheet in
/// `AtriaActivityMonitor` renders the exact same overnight HR trace and
/// HR-load reading as the Health screen — one card, not two divergent copies
/// (GAP-07).
struct AtriaSleepStressProjection: Equatable {
    struct Sample: Identifiable, Equatable {
        let date: Date
        let score: Double
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    }

    struct HeartRateSample: Identifiable, Equatable {
        let date: Date
        let bpm: Double
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    }

    enum Availability: Equatable {
        case loading
        case unavailable
        case baselineNeeded
        case insufficientWear
        case ready

        var title: String {
            switch self {
            // A still-loading read is distinct from a failed one: the card must
            // not flash "unavailable" before the detached archive/observed union
            // returns.
            case .loading: return "Loading overnight HR…"
            // `AtriaSleepStressCard` is mounted only after the enclosing Sleep
            // detail has resolved a real sleep window. Calling this state
            // "Sleep window unavailable" therefore contradicted the saved
            // sleep shown directly above it. What is unavailable here is the
            // archived heart-rate evidence needed to construct the load trace.
            case .unavailable: return "Overnight HR load unavailable"
            case .baselineNeeded: return "Building overnight HR baseline"
            case .insufficientWear: return "Not enough overnight wear"
            case .ready: return "Observed HR · personal baseline"
            }
        }

        var detail: String {
            switch self {
            case .loading: return "Reading saved and observed overnight heart rate for this sleep window…"
            case .unavailable: return "This saved sleep has no usable archived heart-rate evidence for an overnight load trace."
            case .baselineNeeded: return "A personal resting heart-rate baseline is needed before overnight HR load can be interpreted."
            case .insufficientWear: return "Keep the strap on through the night to map observed overnight HR load."
            case .ready: return "Atria's 0–3 heart-rate-load scale, relative to your resting heart rate. It is not stress, a sleep stage, or a diagnosis."
            }
        }
    }

    let samples: [Sample]
    let heartRateSamples: [HeartRateSample]
    let availability: Availability

    static let unavailable = Self(samples: [], heartRateSamples: [], availability: .unavailable)
    static let loading = Self(samples: [], heartRateSamples: [], availability: .loading)

    static func make(points: [HistoricalArchive.HeartRatePoint],
                     sleepStart: Date,
                     sleepEnd: Date,
                     restingHeartRate: Int?) -> Self {
        guard let restingHeartRate, (35...120).contains(restingHeartRate) else {
            return Self(samples: [], heartRateSamples: [], availability: .baselineNeeded)
        }
        guard sleepEnd.timeIntervalSince(sleepStart) >= 60 * 60 else {
            // The caller has already distinguished a failed archive read from a
            // successful one. A readable short window simply cannot provide the
            // minimum overnight bucket coverage; it is not a history failure.
            return Self(samples: [], heartRateSamples: [], availability: .insufficientWear)
        }

        // Five-minute buckets make the graph legible without inventing samples
        // between sparse archive rows. A bucket's score comes from its observed
        // mean only; missing buckets remain gaps in the chart.
        let bucketSeconds: TimeInterval = 5 * 60
        var valuesByBucket: [Int: [Int]] = [:]
        for point in points where point.t >= sleepStart && point.t <= sleepEnd && (30...240).contains(point.bpm) {
            let bucket = Int(floor(point.t.timeIntervalSince(sleepStart) / bucketSeconds))
            valuesByBucket[bucket, default: []].append(point.bpm)
        }
        let pairs = valuesByBucket.keys.sorted().compactMap { bucket -> (Sample, HeartRateSample)? in
            guard let values = valuesByBucket[bucket], !values.isEmpty else { return nil }
            let average = Double(values.reduce(0, +)) / Double(values.count)
            // A deliberately conservative HR-only activation. It takes a
            // meaningful elevation above the wearer's own resting rate to
            // enter the high zone; HRV is not silently inferred from HR.
            let threshold = max(10, Double(restingHeartRate) * 0.20)
            let score = min(max((average - Double(restingHeartRate) - 3) / threshold, 0), 1) * 3
            let date = sleepStart.addingTimeInterval((Double(bucket) + 0.5) * bucketSeconds)
            return (Sample(date: date, score: score), HeartRateSample(date: date, bpm: average))
        }

        let samples = pairs.map(\.0)
        let heartRateSamples = pairs.map(\.1)

        guard samples.count >= 12,
              let first = samples.first?.date,
              let last = samples.last?.date,
              last.timeIntervalSince(first) >= min(3 * 60 * 60, sleepEnd.timeIntervalSince(sleepStart) * 0.45) else {
            return Self(samples: [], heartRateSamples: [], availability: .insufficientWear)
        }
        return Self(samples: samples, heartRateSamples: heartRateSamples, availability: .ready)
    }
}

/// One typed archive-read boundary for every overnight HR-load surface. A
/// successful empty read means the archive was readable but the night lacked
/// enough observed buckets; nil means the exact history could not be read (for
/// example an unreadable/truncated file or row overflow). Missing baseline is
/// resolved before I/O and remains a distinct, truthful prerequisite state.
enum AtriaSleepStressArchiveProjection {
    static func make(
        read: HistoricalArchive.HeartRateWindowRead?,
        sleepStart: Date,
        sleepEnd: Date,
        restingHeartRate: Int?,
        canonical: [HistoricalArchive.HeartRatePoint] = [],
        observed: [HistoricalArchive.HeartRatePoint] = []
    ) -> AtriaSleepStressProjection {
        guard let restingHeartRate, (35...120).contains(restingHeartRate) else {
            return AtriaSleepStressProjection.make(
                points: [],
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                restingHeartRate: restingHeartRate
            )
        }
        // Union the durable archive read with canonical saved-session points and
        // the retained observed history so this overnight surface builds from the
        // SAME exact-window evidence as the Activity day-timeline HR trace. A nil
        // archive read is only truly "unavailable" when no source has in-window
        // points; a readable-but-thin night still resolves to insufficient wear.
        let union = AtriaExactWindowHeartRate.union(
            canonical: canonical,
            archive: read?.points ?? [],
            observed: observed,
            interval: DateInterval(start: sleepStart,
                                   end: max(sleepEnd, sleepStart).addingTimeInterval(1))
        )
        if read == nil, union.isEmpty { return .unavailable }
        return AtriaSleepStressProjection.make(
            points: union,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            restingHeartRate: restingHeartRate
        )
    }

    static func load(
        sleepStart: Date,
        sleepEnd: Date,
        restingHeartRate: Int?,
        sessions: [SavedSession] = [],
        observed: [HistoricalArchive.HeartRatePoint] = [],
        maximumPoints: Int = 50_000
    ) -> AtriaSleepStressProjection {
        guard let restingHeartRate, (35...120).contains(restingHeartRate) else {
            return make(
                read: nil,
                sleepStart: sleepStart,
                sleepEnd: sleepEnd,
                restingHeartRate: restingHeartRate
            )
        }
        let read = HistoricalArchive.metricHeartRatePoints(
            start: sleepStart,
            end: sleepEnd,
            maximumPoints: maximumPoints
        )
        let canonical = sessions
            .filter { $0.end > sleepStart && $0.start < sleepEnd }
            .flatMap { session in
                session.points.compactMap { point -> HistoricalArchive.HeartRatePoint? in
                    let date = session.start.addingTimeInterval(point.t)
                    guard date >= sleepStart, date <= sleepEnd,
                          (25...240).contains(point.bpm) else { return nil }
                    return .init(t: date, bpm: point.bpm)
                }
            }
        return make(
            read: read,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            restingHeartRate: restingHeartRate,
            canonical: canonical,
            observed: observed
        )
    }
}

struct AtriaSleepStressCard: View {
    let projection: AtriaSleepStressProjection
    /// Timezone the trace's time axis renders in. Defaults to the device zone
    /// (correct for the current-cycle card on the Health screen); the Sleep
    /// detail passes the night's recorded event zone so a travel night reads in
    /// the clock it was actually slept in (GAP-07).
    var displayTimeZone: TimeZone = .current
    /// GAP-07: the user's typical overnight resting-HR band, shaded behind the
    /// heart-rate trace when enough qualified nights exist. Nil hides it.
    var typicalRestingBand: ClosedRange<Double>? = nil
    private enum Mode: String, CaseIterable, Identifiable { case heartRate = "Heart rate", load = "HR load"; var id: String { rawValue } }
    @State private var mode: Mode = .heartRate

    private struct HighPeriod: Identifiable {
        let start: Date
        let end: Date

        var id: Date { start }
        /// Samples are five-minute observed buckets; include the final bucket
        /// so a single reading reads as a five-minute period, not zero time.
        var duration: TimeInterval { end.timeIntervalSince(start) + 5 * 60 }
    }

    private var points: [AtriaStressTimelinePoint] {
        AtriaStressTimelinePoint.segment(projection.samples.map {
            AtriaStressDetailReading(date: $0.date, score: $0.score)
        })
    }

    private struct HRTracePoint: Identifiable {
        let date: Date
        let bpm: Double
        let segment: Int
        var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    }

    /// Raw overnight BPM, segmented around real gaps (the same 5-minute rule the
    /// load trace uses). It must NOT go through AtriaStressDetailReading, whose
    /// initializer clamps score to 0...3 — that silently collapsed every bpm to
    /// 3 and rendered the heart-rate line far below the axis (invisible).
    private var heartRatePoints: [HRTracePoint] {
        let sorted = projection.heartRateSamples.sorted { $0.date < $1.date }
        var segment = 0
        var previousDate: Date?
        return sorted.map { sample in
            if let previousDate, sample.date.timeIntervalSince(previousDate) > 5 * 60 {
                segment += 1
            }
            previousDate = sample.date
            return HRTracePoint(date: sample.date, bpm: sample.bpm, segment: segment)
        }
    }

    private var highPeriods: [HighPeriod] {
        let highSamples = projection.samples
            .filter { $0.score >= 2 }
            .sorted { $0.date < $1.date }
        guard let first = highSamples.first else { return [] }

        var result: [HighPeriod] = []
        var start = first.date
        var end = first.date
        for sample in highSamples.dropFirst() {
            // Consecutive real five-minute buckets form one period. Gaps stay
            // gaps — we do not bridge missing wear into a longer high period.
            if sample.date.timeIntervalSince(end) <= 6 * 60 {
                end = sample.date
            } else {
                result.append(HighPeriod(start: start, end: end))
                start = sample.date
                end = sample.date
            }
        }
        result.append(HighPeriod(start: start, end: end))
        return result
    }

    private var highDuration: TimeInterval {
        highPeriods.reduce(0) { $0 + $1.duration }
    }

    private var highSummary: String {
        guard !highPeriods.isEmpty else { return "No high periods" }
        let periodLabel = highPeriods.count == 1 ? "period" : "periods"
        return "\(highPeriods.count) high \(periodLabel) · \(Int((highDuration / 60).rounded()))m"
    }

    private var highTimingSummary: String? {
        guard !highPeriods.isEmpty else { return nil }
        let periods = highPeriods.prefix(2).map { period in
            let range = "\(period.start.formatted(date: .omitted, time: .shortened))–\(period.end.formatted(date: .omitted, time: .shortened))"
            return "\(range) (\(Int((period.duration / 60).rounded()))m)"
        }
        let remainder = highPeriods.count > 2 ? " +\(highPeriods.count - 2) more" : ""
        return "High periods: \(periods.joined(separator: " · "))\(remainder)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overnight HR load")
                        .font(.subheadline.weight(.bold))
                    Text(projection.availability.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if projection.availability == .ready {
                    Text(highSummary)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(highPeriods.isEmpty ? Metrics.electricGreen : .orange)
                }
            }

            if projection.availability == .ready {
                AtriaTextSelector(items: Mode.allCases,
                                  title: { $0.rawValue },
                                  selection: $mode)
                Chart {
                    if mode == .load {
                        ForEach(points) { point in
                            AreaMark(x: .value("Time", point.reading.date),
                                     y: .value("Load", point.reading.score),
                                     series: .value("Segment", point.segment))
                                .interpolationMethod(.linear)
                                .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.14), .green.opacity(0.08), .orange.opacity(0.03)],
                                                                  startPoint: .bottom,
                                                                  endPoint: .top))
                            LineMark(x: .value("Time", point.reading.date),
                                     y: .value("Load", point.reading.score),
                                     series: .value("Segment", point.segment))
                                .interpolationMethod(.linear)
                                .lineStyle(AtriaChartVisualGrammar.traceLine)
                                .foregroundStyle(.linearGradient(colors: [.blue, .green, .orange],
                                                                  startPoint: .bottom,
                                                                  endPoint: .top))
                        }
                        ForEach(points.filter { $0.reading.score >= 2 }) { point in
                            PointMark(x: .value("Time", point.reading.date),
                                      y: .value("Load", point.reading.score))
                                .symbolSize(28)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        ForEach(heartRatePoints) { point in
                            AreaMark(x: .value("Time", point.date),
                                     y: .value("BPM", point.bpm),
                                     series: .value("Segment", point.segment))
                                .interpolationMethod(.linear)
                                .foregroundStyle(.linearGradient(colors: [.red.opacity(0.18), .red.opacity(0.02)],
                                                                  startPoint: .bottom,
                                                                  endPoint: .top))
                            LineMark(x: .value("Time", point.date),
                                     y: .value("BPM", point.bpm),
                                     series: .value("Segment", point.segment))
                                .interpolationMethod(.linear)
                                .lineStyle(AtriaChartVisualGrammar.traceLine)
                                .foregroundStyle(.linearGradient(colors: [.red, .orange],
                                                                  startPoint: .bottom,
                                                                  endPoint: .top))
                        }
                    }
                }
                .atriaGraphPlotSurface()
                .chartYScale(domain: mode == .load ? 0...3 : heartRateDomain)
                .chartBackground { proxy in
                    // Draw the typical band as a background layer, decoupled from
                    // the marks: a band mark with no x collapses the x-domain and
                    // drops the x-positioned HR line. This cannot.
                    GeometryReader { geo in
                        if mode == .heartRate, let band = typicalRestingBand,
                           let plotFrame = proxy.plotFrame {
                            let plot = geo[plotFrame]
                            let topY = plot.minY + (proxy.position(forY: band.upperBound) ?? 0)
                            let bottomY = plot.minY + (proxy.position(forY: band.lowerBound) ?? 0)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: plot.width, height: max(1, bottomY - topY))
                                .position(x: plot.midX, y: (topY + bottomY) / 2)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisTick().foregroundStyle(.clear)
                        AxisValueLabel {
                            if mode == .load, let value = value.as(Int.self) {
                                Text(value == 3 ? "High" : "\(value)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(value >= 2 ? .orange : (value == 1 ? .green : .blue))
                            } else if let value = value.as(Double.self) { Text("\(Int(value.rounded()))") }
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
                .frame(height: 156)
                // Clip the AreaMark gradient to the plot frame (2026-08-08):
                // unlike every other AreaMark chart this one had no clip, so the
                // fill/glow bled below the 156pt frame onto the caption text.
                .clipped()
                .environment(\.timeZone, displayTimeZone)
                .atriaInspectableGraph(inspectorGraph)
                if let highTimingSummary {
                    Text(highTimingSummary)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mode == .heartRate, let band = typicalRestingBand {
                    Text("Shaded band: your typical overnight resting HR, \(Int(band.lowerBound.rounded()))–\(Int(band.upperBound.rounded())) bpm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ContentUnavailableView(projection.availability.title,
                                       systemImage: "moon.zzz.fill",
                                       description: Text(projection.availability.detail))
                    .frame(maxWidth: .infinity, minHeight: 126)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text(projection.availability.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(projection.availability == .ready
                            ? "Overnight heart-rate load. \(highSummary). \(highTimingSummary ?? "")"
                            : "Overnight heart-rate load. \(projection.availability.title). \(projection.availability.detail)")
    }

    private var heartRateDomain: ClosedRange<Double> {
        let values = projection.heartRateSamples.map(\.bpm)
        var low = max(35, (values.min() ?? 50) - 5)
        var high = max(low + 10, (values.max() ?? 80) + 5)
        // Keep the typical band in view when it sits below the night's samples.
        if let band = typicalRestingBand {
            low = min(low, band.lowerBound - 3)
            high = max(high, band.upperBound + 3)
        }
        return low...high
    }

    /// The compact selector and the landscape inspector read the exact same
    /// observed buckets and segment IDs. Expanding the chart therefore cannot
    /// bridge an unworn interval or silently switch from HR to the derived
    /// 0–3 load view.
    private var inspectorGraph: AtriaInspectableGraph {
        switch mode {
        case .heartRate:
            return AtriaInspectableGraph(
                title: "Overnight heart rate",
                subtitle: typicalRestingBand.map {
                    "Typical resting band \(Int($0.lowerBound.rounded()))–\(Int($0.upperBound.rounded())) bpm"
                },
                content: .timeSeries([
                    .init(title: "Heart rate",
                          unit: " bpm",
                          tint: .red,
                          points: heartRatePoints.map {
                              .init(date: $0.date,
                                    value: $0.bpm,
                                    segment: $0.segment)
                          })
                ])
            )
        case .load:
            return AtriaInspectableGraph(
                title: "Overnight HR load",
                subtitle: "Observed HR relative to your resting baseline · 0–3 scale",
                content: .timeSeries([
                    .init(title: "HR load",
                          unit: "",
                          tint: .orange,
                          points: points.map {
                              .init(date: $0.reading.date,
                                    value: $0.reading.score,
                                    segment: $0.segment)
                          })
                ])
            )
        }
    }
}

/// A schedule graph has to explain itself. The former unlabeled cyan bars gave
/// no answer to when a person slept, how much the schedule moved, or whether
/// that movement is meaningful. This uses the same real bed-to-wake windows,
/// but makes the times and the consistency verdict explicit.
private struct AtriaSleepConsistencyStrip: View {
    let nights: [SleepHistorySnapshot.Night]

    private var consistency: AtriaSleepConsistency {
        AtriaSleepConsistency.result(from: nights)
    }

    // Night-centric axis: anchored at 18:00, spanning 18h to 12:00 next day.
    private static let anchorHour: Double = 18
    private static let spanHours: Double = 18

    private struct Row: Identifiable {
        let id: String
        let dayLabel: String
        let startFrac: CGFloat
        let endFrac: CGFloat
        let startHour: Double
        let endHour: Double
    }

    private var rows: [Row] {
        nights.prefix(14).compactMap { night in
            guard let start = night.start, let end = night.end, end > start else { return nil }
            var calendar = Calendar.current
            if let identifier = night.eventTimeZoneIdentifier,
               let timeZone = TimeZone(identifier: identifier) {
                calendar.timeZone = timeZone
            }
            func relativeHour(_ date: Date) -> Double? {
                let comps = calendar.dateComponents([.hour, .minute], from: date)
                let hour = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
                var rel = (hour - Self.anchorHour).truncatingRemainder(dividingBy: 24)
                if rel < 0 { rel += 24 }
                guard rel <= Self.spanHours else { return nil }   // outside the night window (daytime nap)
                return rel
            }
            guard let startHour = relativeHour(start),
                  let endHour = relativeHour(end),
                  endHour > startHour else { return nil }
            return Row(id: night.id,
                       dayLabel: night.day.formatted(.dateTime.weekday(.narrow)),
                       startFrac: CGFloat(startHour / Self.spanHours),
                       endFrac: CGFloat(endHour / Self.spanHours),
                       startHour: startHour,
                       endHour: endHour)
        }
    }

    private var bedtimeSpreadMinutes: Int { consistency.bedtimeVariationMinutes ?? 0 }
    private var wakeTimeSpreadMinutes: Int { consistency.wakeVariationMinutes ?? 0 }
    private var typicalBedtime: String { consistency.typicalBedtimeText }
    private var typicalWakeTime: String { consistency.typicalWakeTimeText }

    private var consistencyVerdict: (title: String, detail: String, tint: Color) {
        switch consistency.combinedPercent ?? 0 {
        case 85...:
            return ("Very consistent", "Your bed and wake times stayed within half an hour.", Metrics.electricGreen)
        case 70...:
            return ("Consistent", "Your schedule moved less than an hour night to night.", .cyan)
        case 50...:
            return ("Variable", "A steadier bedtime would make this week more regular.", .orange)
        default:
            return ("Irregular", "Bed and wake times moved by more than 90 minutes.", Metrics.electricRed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep schedule")
                        .font(.caption.weight(.semibold))
                    if consistency.isQualified {
                        Text("Usually \(typicalBedtime) – \(typicalWakeTime)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if consistency.isQualified {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(consistency.displayText) · \(consistencyVerdict.title)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(consistencyVerdict.tint)
                        Text("\(consistency.qualifiedNightCount) qualified nights")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if consistency.isQualified {
                Text("Bedtime varies \(minutesText(bedtimeSpreadMinutes)) · wake time varies \(minutesText(wakeTimeSpreadMinutes))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    let plotWidth = geo.size.width - 28
                    VStack(spacing: 5) {
                        ForEach(rows) { row in
                            HStack(spacing: 7) {
                                Text(row.dayLabel)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 21, alignment: .leading)
                                ZStack(alignment: .leading) {
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                        .frame(height: 11)
                                    Capsule(style: .continuous)
                                        .fill(consistencyVerdict.tint.opacity(0.84))
                                        .frame(width: max(3, (row.endFrac - row.startFrac) * plotWidth), height: 11)
                                        .offset(x: row.startFrac * plotWidth)
                                    Circle()
                                        .fill(consistencyVerdict.tint)
                                        .frame(width: 7, height: 7)
                                        .offset(x: row.startFrac * plotWidth - 3.5)
                                    Circle()
                                        .fill(consistencyVerdict.tint)
                                        .frame(width: 7, height: 7)
                                        .offset(x: row.endFrac * plotWidth - 3.5)
                                }
                            }
                        }
                    }
                }
                .frame(height: CGFloat(rows.count) * 16)

                HStack(spacing: 0) {
                    Color.clear.frame(width: 28)
                    HStack {
                        Text("6 PM")
                        Spacer(minLength: 0)
                        Text("12 AM")
                        Spacer(minLength: 0)
                        Text("6 AM")
                        Spacer(minLength: 0)
                        Text("12 PM")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                }

                Text(consistencyVerdict.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(consistency.footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(consistency.isQualified
                            ? "Sleep schedule across \(consistency.qualifiedNightCount) qualified recent nights. Usually \(typicalBedtime) to \(typicalWakeTime). \(consistencyVerdict.title). Bedtime varies \(minutesText(bedtimeSpreadMinutes)); wake time varies \(minutesText(wakeTimeSpreadMinutes))."
                            : "Sleep schedule, \(consistency.footnote)")
    }

    private func averageHour(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func spreadMinutes(_ values: [Double]) -> Int {
        guard values.count >= 2 else { return 0 }
        let mean = averageHour(values)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return Int((sqrt(variance) * 60).rounded())
    }

    private func clockText(_ relativeHour: Double) -> String {
        let totalMinutes = Int((relativeHour * 60).rounded()) + Int(Self.anchorHour * 60)
        let hour24 = ((totalMinutes / 60) % 24 + 24) % 24
        let minute = ((totalMinutes % 60) + 60) % 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, hour24 < 12 ? "AM" : "PM")
    }

    private func minutesText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
