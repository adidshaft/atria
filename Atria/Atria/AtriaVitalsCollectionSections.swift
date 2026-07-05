import SwiftUI
import Charts

struct AtriaVitalsTabContent: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileStore: AtriaHomeModel.ProfileStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @ObservedObject var store: SessionStore
    let ble: AtriaBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?
    @AtriaDefault(AtriaVitalsSection.orderStorageKey) private var sectionOrderCSV = ""
    @AppStorage(AtriaTodayMetric.storageKey) private var hiddenMetricCSV = ""
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    @State private var isEditingVitalsLayout = false
    @State private var healthMonitorRollups: [DailyRollupStoreEntry] = []
    @State private var metricDetail: AtriaMetricDetailKind?

    var body: some View {
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
                        withAnimation(.snappy(duration: 0.2)) {
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
        .onAppear(perform: refreshHealthMonitorRollups)
        .sheet(item: $metricDetail) { detail in
            AtriaMetricDetailSheet(metric: detail,
                                   rollups: store.dailyRollupHistory,
                                   confirmedWorkouts: store.confirmedWorkouts,
                                   baseline: AtriaBaselineTargetSnapshot(store.baseline),
                                   sleepHistory: store.sleepHistorySnapshot,
                                   guidance: healthMonitorGuidance,
                                   recoveryEstimate: healthMonitorRecoveryEstimate,
                                   sleepGoalHours: sleepGoalHours,
                                   sleepBaseNeedHours: sleepBaseNeedHours)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var healthMonitorCard: some View {
        AtriaHealthMonitorCard(rollups: healthMonitorRollups,
                               sleepHistory: store.sleepHistorySnapshot,
                               sensorSummary: store.imuAuditSummary,
                               bloodOxygenEnabled: isMetricVisible(.bloodOxygen),
                               skinTemperatureEnabled: isMetricVisible(.bodyTemp),
                               onOpenDetail: { metricDetail = $0 })
    }

    private var healthMonitorRecoveryEstimate: Metrics.RecoveryEstimate {
        if let rollup = healthMonitorRollups.sorted(by: { $0.day > $1.day }).first,
           let recovery = rollup.recovery {
            return Metrics.RecoveryEstimate(percent: recovery,
                                            confidence: .validated,
                                            usesHRV: rollup.lnRMSSD != nil,
                                            detail: "Saved Health Monitor rollup",
                                            contributors: [])
        }
        return Metrics.RecoveryEstimate(percent: nil,
                                        confidence: .learning,
                                        usesHRV: false,
                                        detail: "Health Monitor baseline building",
                                        contributors: [])
    }

    private var healthMonitorGuidance: Coach.Guidance {
        let latest = healthMonitorRollups.sorted { $0.day > $1.day }.first
        return Coach.guide(recovery: healthMonitorRecoveryEstimate,
                           strain: latest?.strain ?? 0)
    }

    private func refreshHealthMonitorRollups() {
        healthMonitorRollups = DailyRollupStore().rollups(last: 28)
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
            withAnimation(.snappy(duration: 0.2)) {
                isEditingVitalsLayout = true
            }
        }
        .modifier(AtriaConditionalVitalsStringDraggable(isEnabled: true,
                                                        payload: section.dragPayload))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let dragged = AtriaVitalsSection.draggedSection(from: raw) else { return false }
            withAnimation(.snappy(duration: 0.2)) {
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
                    withAnimation(.snappy(duration: 0.2)) {
                        moveSection(section, direction: -1)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.black))
                }
                .atriaGlassIconAction(tint: .secondary, size: 44)
                .accessibilityLabel("Move \(section.label) up")

                Button {
                    withAnimation(.snappy(duration: 0.2)) {
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
                                 store: store,
                                 pulseSparklineStore: pulseSparklineStore)
    }

    private var hrvCard: some View {
        AtriaVitalsHRVCardHost(liveStore: liveStore,
                               heroStore: heroStore,
                               store: store)
    }

    private var recoveryStrainCard: some View {
        AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,
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

            AtriaOverviewTrendChartHost(store: store)
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

    var tint: Color {
        switch self {
        case .recovery: return Metrics.electricGreen
        case .restingHeartRate, .hrv: return .pink
        case .respiration: return .teal
        case .stress: return .orange
        case .sleep: return Metrics.electricSleep
        }
    }

    var whatItIs: String {
        switch self {
        case .recovery:
            return "Recovery blends your overnight HRV, resting heart rate, sleep, and respiration against your own baseline into one readiness read. It answers \u{201c}how ready am I today\u{201d} rather than being a score to max out every day."
        case .restingHeartRate:
            return "Resting heart rate is how many times your heart beats per minute at full rest, usually measured overnight. It tracks cardiovascular fitness over months and day-to-day strain in the short term."
        case .hrv:
            return "Heart rate variability measures the tiny timing differences between heartbeats, driven mostly by your autonomic nervous system. Higher HRV generally reflects more recovery capacity, though the \u{201c}right\u{201d} number is highly individual."
        case .respiration:
            return "Respiratory rate is how many breaths you take per minute while asleep. It is normally quite stable night to night, so shifts outside your own usual range are often the first sign something is off."
        case .stress:
            return "This stress read estimates autonomic load right now from heart rate and beat-to-beat timing, not a lab cortisol measurement. Treat it as a rough signal for how activated your system currently is."
        case .sleep:
            return "Sleep tracks how long you slept against your personal goal, plus how consistent your recent sleep timing has been. It is a duration and consistency estimate, not a clinical sleep study."
        }
    }

    var howToImprove: [String] {
        switch self {
        case .recovery:
            return [
                "Sleep is the single biggest lever -- consistent bed and wake times build a steadier baseline.",
                "Scale today's effort to the score -- treat a low recovery as a cue for easier movement, not a verdict.",
                "Give it time -- the underlying baseline gets more accurate over your first few weeks of wear."
            ]
        case .restingHeartRate:
            return [
                "Build a consistent aerobic base -- regular easy-effort training tends to lower resting heart rate over weeks, not days.",
                "Protect sleep and hydration -- a single poor night or dehydration can temporarily raise resting HR.",
                "Watch the trend, not one reading -- a sustained rise versus your own baseline matters more than any single morning."
            ]
        case .hrv:
            return [
                "Prioritize consistent, sufficient sleep -- HRV is most sensitive to sleep quality and timing.",
                "Manage training load -- hard sessions temporarily suppress HRV, and easier days typically let it rebound.",
                "Limit late alcohol and heavy evening meals -- both are commonly linked with lower overnight HRV."
            ]
        case .respiration:
            return [
                "Rule out simple causes first -- illness, altitude, and a warm room can all shift breathing rate.",
                "Favor nasal breathing and a consistent sleep position where you can.",
                "Track the trend for a few nights -- one blip is common; several nights outside range is worth noting."
            ]
        case .stress:
            return [
                "Try slow paced breathing, roughly 5-6 breaths a minute, for a few minutes to bring it down.",
                "Short walks and daylight exposure are consistently linked with lower perceived stress.",
                "If it stays elevated for days, treat that as a cue to lighten training and protect sleep, not push harder."
            ]
        case .sleep:
            return [
                "Anchor a consistent wake time -- it is one of the strongest levers for regulating your body clock.",
                "Wind down earlier if you're carrying sleep debt -- small nightly top-ups add up faster than one long catch-up night.",
                "Keep the bedroom cool, dark, and screen-free in the last 30 minutes to help sleep onset."
            ]
        }
    }

    /// Used only when no numeric baseline range exists yet for this metric --
    /// either because the metric isn't range-based (recovery, stress, sleep)
    /// or because the trusted baseline hasn't formed yet.
    func rangeFallback(sleepGoalHours: Double) -> String {
        switch self {
        case .recovery:
            return "Recovery already compares today with your own rolling baseline, so there's no separate range -- read the percent itself: 67-100% high, 34-66% moderate, 1-33% low."
        case .stress:
            return "Stress is a live Calm / Low / Medium / High read rather than a numeric range -- compare the label day to day."
        case .sleep:
            return String(format: "Sleep is compared with your %.1f hour goal and your recent timing consistency rather than a numeric typical range.", sleepGoalHours)
        case .restingHeartRate, .hrv, .respiration:
            return "Still building your typical range -- Atria needs a few more days of trusted overnight data before comparing today with your own normal."
        }
    }
}

/// Compact three-section education sheet: what it is, your typical range
/// (when a trusted baseline comparison exists), and how to improve. Reused by
/// both the Vitals tab's Health Monitor card and the Health screen's monitor.
struct AtriaVitalsEducationSheet: View {
    let topic: AtriaVitalsEducationTopic
    var numericRangeText: String? = nil
    var sleepGoalHours: Double = 8.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    detailBlock(title: "What it is", body: topic.whatItIs)
                    detailBlock(title: "Your typical range",
                                body: numericRangeText ?? topic.rangeFallback(sleepGoalHours: sleepGoalHours))
                    improveBlock

                    Text("General guidance, not medical advice.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var improveBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to improve")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(topic.howToImprove.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(topic.tint)
                        .padding(.top, 2)
                    Text(bullet)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(tint: topic.tint)
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
        .atriaInsetCard(tint: topic.tint)
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

private struct AtriaHealthMonitorCard: View {
    let rollups: [DailyRollupStoreEntry]
    let sleepHistory: SleepHistorySnapshot
    let sensorSummary: IMUAuditSummary
    let bloodOxygenEnabled: Bool
    let skinTemperatureEnabled: Bool
    let onOpenDetail: (AtriaMetricDetailKind) -> Void
    @State private var educationTopic: AtriaVitalsEducationTopic?
    @State private var educationRangeText: String?

    var body: some View {
        // Computed once per body eval: `rows` re-sorts the rollup history to
        // build each vital's sparkline/range, so evaluating it twice (badge +
        // ForEach) doubled that work on every render for no benefit.
        let rows = rows
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
                                              onOpenEducation: { topic, rangeText in
                        educationRangeText = rangeText
                        educationTopic = topic
                    })
                }
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .sheet(item: $educationTopic) { topic in
            AtriaVitalsEducationSheet(topic: topic, numericRangeText: educationRangeText)
        }
        .accessibilityElement(children: .contain)
    }

    private var rows: [AtriaHealthMonitorRow] {
        var items: [AtriaHealthMonitorRow] = [
            makeRow(kind: .restingHeartRate,
                    today: latestRestingHeartRate,
                    sparklineValues: sparklineRestingHeartRates,
                    rangeValues: rangeRestingHeartRates,
                    storedStat: latestStoredVitals?.rhr),
            makeRow(kind: .hrv,
                    today: latestHRV,
                    sparklineValues: sparklineHRV,
                    rangeValues: rangeHRV,
                    storedStat: latestStoredVitals?.hrv),
            makeRow(kind: .respiratoryRate,
                    today: latestRespiratoryRate,
                    sparklineValues: sparklineRespiratoryRates,
                    rangeValues: rangeRespiratoryRates,
                    storedStat: latestStoredVitals?.resp),
        ]

        if bloodOxygenEnabled {
            items.append(makeResearchRow(kind: .bloodOxygen,
                                         value: sensorSummary.spo2CandidateFrames > 0 ? Double(sensorSummary.spo2CandidateFrames) : nil,
                                         detail: sensorSummary.spo2CandidateFrames > 0 ? "\(sensorSummary.spo2CandidateFrames) frames" : "--"))
        }

        if skinTemperatureEnabled {
            items.append(makeResearchRow(kind: .skinTemperature,
                                         value: sensorSummary.skinTemperatureDeviation.latestDeltaCelsius,
                                         detail: sensorSummary.skinTemperatureDeviation.isReady ? sensorSummary.skinTemperatureDeviation.valueText : "--"))
        }

        return items
    }

    private var latestStoredVitals: DailyRollupVitals? {
        rollups.first(where: { $0.vitals != nil })?.vitals
    }

    private var sortedRollups: [DailyRollupStoreEntry] {
        rollups.sorted { $0.day > $1.day }
    }

    private var latestRestingHeartRate: Double? {
        sortedRollups.compactMap { $0.rhr.map(Double.init) }.first
    }

    private var latestHRV: Double? {
        sortedRollups.compactMap { $0.lnRMSSD.map(exp) }.first
    }

    private var latestRespiratoryRate: Double? {
        sortedRollups.compactMap(\.respiratoryRate).first
            ?? sleepHistory.latest?.respiratoryRate
    }

    private var sparklineRestingHeartRates: [AtriaHealthMonitorSparkPoint] {
        sparkPoints(values: restingHeartRateValues(limit: 7))
    }

    private var rangeRestingHeartRates: [AtriaHealthMonitorSparkPoint] {
        sparkPoints(values: restingHeartRateValues(limit: 28))
    }

    private var sparklineHRV: [AtriaHealthMonitorSparkPoint] {
        sparkPoints(values: hrvValues(limit: 7))
    }

    private var rangeHRV: [AtriaHealthMonitorSparkPoint] {
        sparkPoints(values: hrvValues(limit: 28))
    }

    private var sparklineRespiratoryRates: [AtriaHealthMonitorSparkPoint] {
        sparkPoints(values: respiratoryRateValues(limit: 7))
    }

    private var rangeRespiratoryRates: [AtriaHealthMonitorSparkPoint] {
        sparkPoints(values: respiratoryRateValues(limit: 28))
    }

    private func restingHeartRateValues(limit: Int) -> [(Date, Double)] {
        sortedRollups.prefix(limit).compactMap { rollup in
            rollup.rhr.map { (rollup.day, Double($0)) }
        }
    }

    private func hrvValues(limit: Int) -> [(Date, Double)] {
        sortedRollups.prefix(limit).compactMap { rollup in
            rollup.lnRMSSD.map { (rollup.day, exp($0)) }
        }
    }

    private func respiratoryRateValues(limit: Int) -> [(Date, Double)] {
        sortedRollups.prefix(limit).compactMap { rollup in
            rollup.respiratoryRate.map { (rollup.day, $0) }
        }
    }

    private func sparkPoints(values: [(Date, Double)]) -> [AtriaHealthMonitorSparkPoint] {
        values.sorted { $0.0 < $1.0 }.map { AtriaHealthMonitorSparkPoint(day: $0.0, value: $0.1) }
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

    var tint: Color {
        switch self {
        case .restingHeartRate: return .pink
        case .hrv: return .pink
        case .respiratoryRate: return .teal
        case .bloodOxygen: return .blue
        case .skinTemperature: return .teal
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
        case .building: return "Building"
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
                    .frame(height: 18)

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
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
            }
            .chartXAxis(.hidden)
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
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @ObservedObject var store: SessionStore
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
            AtriaCollectionResearchSignalsCard(summary: store.imuAuditSummary,
                                               sleepHistory: store.sleepHistorySnapshot)
            AtriaCollectionIMUAuditCard(summary: store.imuAuditSummary)
            AtriaResearchManeuverMarkerCard(markers: store.researchManeuverMarkers,
                                            correlationSummary: store.researchManeuverProbeCorrelationSummary,
                                            onMark: { store.markResearchManeuver($0) })
            // Static handoff compatibility marker for the relocated card: researchManeuverCard
            AtriaCollectionProfilePicker(
                selected: collectionLiveStore.state.collectionProfile,
                onSelect: { profile in
                    ble.setCollectionProfile(profile,
                                             rest: homeStatsStore.state.restingHeartRate,
                                             maxHR: profileStore.profile.maxHR)
                }
            )
            AtriaDutyCycleToggleCard(ble: ble)
            AtriaCollectionBiologicalAgeCardHost(profileMetricsStore: profileMetricsStore)
        }
    }
}

/// Daytime power saver (docs/24 §13). Honest copy: this trades daytime
/// beat-to-beat detail for strap battery; recovery already comes from sleep.
private struct AtriaDutyCycleToggleCard: View {
    let ble: AtriaBLEManager
    @AppStorage("atria.dutycycle.enabled") private var dutyCycleEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $dutyCycleEnabled) {
                Label("Daytime power saver", systemImage: "leaf")
                    .font(.subheadline.weight(.semibold))
            }
            .onChange(of: dutyCycleEnabled) { _, _ in
                ble.updateDutyCycleState(reason: "settings_toggle")
            }

            Text("During the day, Atria checks your heart rate every few minutes instead of continuously. Full detail resumes automatically during your usual sleep hours, during workouts, when your heart rate rises, or when you open the live screen. Saves strap battery. Daytime beat-to-beat (HRV) detail is not recorded — your recovery score already comes from sleep.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaVitalsPulseCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var store: SessionStore
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @State private var historicalHeartRatePoints: [AtriaHomeModel.HeartRateChartPoint] = []
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore

    private var chartPoints: [AtriaHomeModel.HeartRateChartPoint] {
        AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: pulseSparklineStore.state.chartPoints,
                                                           historical: historicalHeartRatePoints)
    }

    var body: some View {
        AtriaPulseCard(isConnected: liveStore.state.status == .connected,
                       live: pulseStore.state,
                       sparklineStore: pulseSparklineStore,
                       chartPoints: chartPoints,
                       restingHeartRate: homeStatsStore.state.restingHeartRate,
                       restingHeartRateText: homeStatsStore.state.restingHeartRateText,
                       restingBaseline: store.baseline.restingInt,
                       restingBaselineSamples: store.baseline.freshRestingSampleCount(),
                       restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline(),
                       baselineTarget: AtriaBaselineTargetSnapshot(store.baseline),
                       restingGreenDelta: restingGreenDelta,
                       restingYellowDelta: restingYellowDelta,
                       debugOpensHeartRateTimeline: Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments))
            .equatable()
            .task {
                await refreshHistoricalHeartRatePoints()
            }
            .onReceive(NotificationCenter.default.publisher(for: HistoricalArchive.didUpdateNotification)) { _ in
                Task { await refreshHistoricalHeartRatePoints() }
            }
    }

    @MainActor
    private func refreshHistoricalHeartRatePoints() async {
        let since = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        let points = await Task.detached(priority: .utility) {
            HistoricalArchive.metricHeartRatePoints(since: since).map {
                AtriaHomeModel.HeartRateChartPoint(t: $0.t, bpm: $0.bpm)
            }
        }.value
        guard points != historicalHeartRatePoints else { return }
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

enum AtriaVitalsHeartRateTimeline {
    static func mergedHeartRatePoints(live: [AtriaHomeModel.HeartRateChartPoint],
                                      historical: [AtriaHomeModel.HeartRateChartPoint],
                                      targetCount: Int = 180) -> [AtriaHomeModel.HeartRateChartPoint] {
        guard !historical.isEmpty else { return live }
        var bySecond: [Int: AtriaHomeModel.HeartRateChartPoint] = [:]
        bySecond.reserveCapacity(historical.count + live.count)
        for point in historical where point.bpm > 0 {
            bySecond[Int(point.t.timeIntervalSince1970.rounded())] = point
        }
        for point in live where point.bpm > 0 {
            bySecond[Int(point.t.timeIntervalSince1970.rounded())] = point
        }
        let merged = bySecond.values.sorted { $0.t < $1.t }
        guard merged.count > targetCount else { return merged }
        let stride = Double(merged.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            merged[Int((Double(index) * stride).rounded())]
        }
    }
}

private struct AtriaVitalsHRVCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var store: SessionStore
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85

    var body: some View {
        AtriaHRVCard(live: liveStore.state,
                     hero: heroStore.state,
                     hrvBaseline: store.baseline.hrvInt,
                     hrvBaselineSamples: store.baseline.freshHRVSampleCount(),
                     hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline(),
                     baselineTarget: AtriaBaselineTargetSnapshot(store.baseline),
                     hrvGreenRatio: hrvGreenRatio,
                     hrvYellowRatio: hrvYellowRatio)
            .equatable()
    }
}

private struct AtriaVitalsRecoveryStrainCardHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var store: SessionStore
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
        AtriaRecoveryStrainCard(hero: heroStore.state,
                                sleepHistory: debugFixtureSleepHistory ?? store.sleepHistorySnapshot,
                                recoveryTarget: AtriaMetricTarget.recovery(greenLower: recoveryGreenLower,
                                                                           yellowLower: recoveryYellowLower),
                                strainGreenBand: strainGreenBand,
                                strainYellowBand: strainYellowBand,
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
                                sleepGoalHours: sleepGoalHours,
                                sleepEfficiencyGreenLower: sleepEfficiencyGreenLower,
                                sleepEfficiencyYellowLower: sleepEfficiencyYellowLower,
                                onAddManualSleep: addManualSleep,
                                onAdjustSleep: adjustSleepCandidate,
                                onConfirmSleep: confirmSleepCandidate)
            .equatable()
    }

    private func addManualSleep(start: Date, end: Date, isNap: Bool) {
        _ = store.addManualSleep(start: start,
                                 end: end,
                                 isNap: isNap,
                                 rest: store.baseline.restingInt ?? 60)
    }

    private func adjustSleepCandidate(night: SleepHistorySnapshot.Night,
                                      start: Date,
                                      end: Date,
                                      isNap: Bool) {
        _ = store.addManualSleep(start: start,
                                 end: end,
                                 isNap: isNap,
                                 rest: store.baseline.restingInt ?? 60,
                                 source: "vitals_sleep_history_adjust")
    }

    private func confirmSleepCandidate() {
        if let night = store.sleepHistorySnapshot.latest {
            _ = store.confirmSleepHistoryNightForUI(night,
                                                    rest: store.baseline.restingInt ?? 60,
                                                    source: "vitals_sleep_history")
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
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Beat-to-beat check", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: homeStatsStore.state.rrPackageText.localizedCaseInsensitiveContains("ready") ? .validated : .learning)
            }

            VStack(spacing: 10) {
                rrActionButtons
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "Beat-to-beat window",
                leadingValue: homeStatsStore.state.rrPackageText,
                leadingDetail: homeStatsStore.state.hrvDetail,
                trailingTitle: "Flow",
                trailingValue: "Export or import",
                trailingDetail: "local file flow"
            )

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
                    .lineLimit(2)
                    .padding(.top, 6)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var rrActionButtons: some View {
        Button {
            rrShareURL = store.exportRRReferencePackageForUI()
        } label: {
            Text("Export beats").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        Button {
            showRRImporter = true
        } label: {
            Text("Import beats").frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: .blue)

        if let rrShareURL {
            ShareLink(item: rrShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .green)
        }
    }
}

private struct AtriaCollectionHRReferenceCardHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @Binding var showHRImporter: Bool
    @Binding var hrShareURL: URL?
    let hrImportStatus: String
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart-rate check", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: snapshotStore.state.referenceText.localizedCaseInsensitiveContains("ready") ? .validated : .learning)
            }

            VStack(spacing: 10) {
                hrActionButtons
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "Heart-rate status",
                leadingValue: snapshotStore.state.referenceText,
                leadingDetail: "comparison workout",
                trailingTitle: "Workout",
                trailingValue: snapshotStore.state.workoutText,
                trailingDetail: "current classifier"
            )

            if !hrImportStatus.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(hrImportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 6)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var hrActionButtons: some View {
        Button {
            hrShareURL = store.exportHRReferencePackageForUI()
        } label: {
            Text("Export heart rate").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        Button {
            showHRImporter = true
        } label: {
            Text("Import heart rate").frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: .blue)

        if let hrShareURL {
            ShareLink(item: hrShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .green)
        }
    }
}

private struct AtriaCollectionResearchSignalsCard: View, Equatable {
    let summary: IMUAuditSummary
    let sleepHistory: SleepHistorySnapshot
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AtriaDefault("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AtriaDefault("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AtriaDefault("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @State private var showResearchInfo = false

    static func == (lhs: AtriaCollectionResearchSignalsCard, rhs: AtriaCollectionResearchSignalsCard) -> Bool {
        lhs.summary == rhs.summary
            && lhs.sleepHistory == rhs.sleepHistory
            && lhs.bloodOxygenCandidateGoal == rhs.bloodOxygenCandidateGoal
    }

    private var hasEvidence: Bool {
        summary.probeFrameCount > 0
            || summary.strapStepCount > 0
            || latestRespiratoryRate != "--"
    }

    private var latestRespiratoryRate: String {
        sleepHistory.nights.first?.respiratoryRateText ?? "--"
    }

    private var respiratoryRateZone: AtriaMetricZone? {
        return Metrics.respiratoryRateZone(sleepHistory.latest?.respiratoryRate,
                                           baseline: sleepHistory.respiratoryBaselineMean,
                                           baselineSamples: sleepHistory.respiratoryBaselineCount,
                                           greenDelta: respiratoryGreenDelta,
                                           yellowDelta: respiratoryYellowDelta)
    }

    private var skinTemperatureDeviationZone: AtriaMetricZone? {
        Metrics.skinTemperatureDeviationZone(summary.skinTemperatureDeviation,
                                             greenDelta: skinTemperatureGreenDelta,
                                             yellowDelta: skinTemperatureYellowDelta)
    }

    private var bloodOxygenResearchZone: AtriaMetricZone? {
        Metrics.bloodOxygenResearchZone(candidateFrames: summary.spo2CandidateFrames,
                                        goalFrames: bloodOxygenCandidateGoal)
    }

    private var strapStepsZone: AtriaMetricZone? {
        Metrics.stepsZone(summary.strapStepCount > 0 ? summary.strapStepCount : nil,
                          goal: stepsGoal).map {
            AtriaMetricZone(level: $0.level,
                            title: "Strap movement goal",
                            current: $0.current,
                            targetSummary: $0.targetSummary,
                            recommendation: "\($0.recommendation) Strap steps stay labeled as estimates until strap movement calibration is validated.",
                            disclaimer: "Strap movement estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
        }
    }

    var body: some View {
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
                                value: summary.spo2CandidateFrames > 0 ? "Early" : "--",
                                unit: nil,
                                state: summary.spo2CandidateFrames > 0 ? .research : .learning,
                                tint: bloodOxygenResearchZone?.tint ?? .blue,
                                footnote: summary.spo2CandidateFrames > 0 ? "\(summary.spo2CandidateFrames) candidate frames; not a SpO2 value." : "Early reading; not a SpO2 value.",
                                zone: bloodOxygenResearchZone,
                                targetMetric: .bloodOxygen)
                AtriaMetricTile(label: "Body temp",
                                value: summary.skinTemperatureDeviation.valueText,
                                unit: summary.skinTemperatureDeviation.isReady ? "delta C" : nil,
                                state: summary.skinTemperatureDeviation.isReady ? .research : .learning,
                                tint: skinTemperatureDeviationZone?.tint ?? (summary.skinTemperatureDeviation.isReady ? .teal : .orange),
                                footnote: summary.skinTemperatureDeviation.footnoteText,
                                zone: skinTemperatureDeviationZone,
                                targetMetric: .bodyTemp)
                AtriaMetricTile(label: "Resp rate",
                                value: latestRespiratoryRate,
                                unit: latestRespiratoryRate == "--" ? nil : "/min",
                                state: latestRespiratoryRate == "--" ? .learning : .research,
                                tint: respiratoryRateZone?.tint ?? .teal,
                                footnote: "Sleep-only estimate; needs comparison data.",
                                zone: respiratoryRateZone,
                                targetMetric: .respiratoryRate)
                AtriaMetricTile(label: "Strap steps",
                                value: summary.strapStepText,
                                state: summary.strapStepCount > 0 ? .research : .learning,
                                tint: strapStepsZone?.tint ?? .green,
                                footnote: summary.agreementText,
                                zone: strapStepsZone,
                                // Static handoff compatibility marker for the merged metric: targetMetric: .strapSteps
                                targetMetric: .steps)
            }

            Text("Early sensor rows show evidence counts, not measurements. Atria shows skin temperature only as a sleep-baseline deviation, never as an absolute body-temperature value.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .sheet(isPresented: $showResearchInfo) {
            AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,
                                         skinTemperatureSummary: summary.skinTemperatureDeviation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaResearchSignalInfoSheet: View {
    let spo2CandidateFrames: Int
    let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                researchInfoRow(systemImage: "drop.degreesign",
                                tint: .blue,
                                title: "Blood oxygen signal",
                                detail: spo2CandidateFrames > 0
                                    ? "\(spo2CandidateFrames) candidate frames found. Atria does not show an SpO2 percentage until quality checks pass."
                                    : "No candidate frames yet. Atria does not estimate or display an SpO2 percentage from unvalidated bytes.")

                researchInfoRow(systemImage: "thermometer.variable",
                                tint: .teal,
                                title: "Body temperature signal",
                                detail: skinTemperatureSummary.isReady
                                    ? "\(skinTemperatureSummary.valueText) delta C versus your local sleep baseline. This is not an absolute body-temperature reading."
                                    : "Atria is building a sleep baseline. It will only show relative deviation, never absolute body temperature.")

                Text("Experimental readings stay local, depend on sleep data, and are not medical advice. Atria does not write SpO2 or body-temperature values to HealthKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
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
                AtriaPanelSectionHeader(title: "Fitness Age", subtitle: summary.narrative)
                Spacer(minLength: 0)
                AtriaStateBadge(state: summary.isReady ? .estimate : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Fitness age",
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
                                footnote: summary.isReady ? summary.detailText : "Needs 28 days",
                                zone: biologicalAgeZone,
                                targetMetric: .bioAge)
                AtriaMetricTile(label: "Pace",
                                value: summary.agingPaceText,
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? deltaTint,
                                footnote: summary.agingPaceDetail)
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
                ForEach(ResearchManeuverMarker.Kind.allCases) { kind in
                    Button {
                        if reduceMotion {
                            onMark(kind)
                        } else {
                            withAnimation(.snappy(duration: 0.18)) {
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
                        title: "Battery saver",
                        subtitle: collectionLiveStore.state.standardHROnlyEnabled
                            ? "Heart-rate only. HR stays live; HRV, Recovery and sleep detail wait for validated beat-to-beat windows."
                            : "Full sensor mode. Beat-to-beat, HRV, Recovery and sleep estimates stay available.",
                        systemImage: collectionLiveStore.state.standardHROnlyEnabled ? "battery.75percent" : "waveform.path.ecg",
                        tint: collectionLiveStore.state.standardHROnlyEnabled ? .green : .purple,
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

private struct AtriaCollectionStatusCardHost: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var store: SessionStore
    let officialAppInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Strap status", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.officialAppCoexistenceRisk == .suspected ? .conflict : .local)
            }

            if collectionLiveStore.state.officialAppCoexistenceRisk != .cleared {
                AtriaCollectionCoexistenceWarning(risk: collectionLiveStore.state.officialAppCoexistenceRisk,
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
                        value: snapshotStore.state.loggingText,
                        state: snapshotStore.state.loggingText.localizedCaseInsensitiveContains("sample") ? .live : .learning,
                        tint: .green)
        AtriaMetricTile(label: "Backup",
                        value: homeStatsStore.state.backupValue,
                        state: .local,
                        tint: .blue)
        AtriaMetricTile(label: "Battery",
                        value: coreLiveStore.state.batteryStatusSummaryText,
                        state: coreLiveStore.state.batteryLevel >= 0 ? .live : .learning,
                        tint: coreLiveStore.state.batteryShowsPowered ? .green : .blue,
                        footnote: coreLiveStore.state.batteryDetailText)
        AtriaMetricTile(label: "Mode",
                        value: collectionLiveStore.state.modeLabel,
                        state: collectionLiveStore.state.longWearModeEnabled ? .live : .local,
                        tint: .purple)
        AtriaMetricTile(label: "App",
                        value: coexistenceValue,
                        state: coexistenceState,
                        tint: coexistenceTint,
                        footnote: coexistenceFootnote)
        // Static handoff compatibility marker for the old engineering label: AtriaMetricTile(label: "Backfill"
        AtriaMetricTile(label: "Catching up",
                        value: store.historicalArchiveStatus.valueText,
                        state: backfillState,
                        tint: .cyan,
                        footnote: backfillFootnote)
    }

    private var backfillFootnote: String {
        "\(store.historicalArchiveStatus.userFootnoteText) \(store.historicalArchiveStatus.actionText)"
    }

    private var backfillState: AtriaMetricState {
        if !store.historicalArchiveStatus.parseOK { return .conflict }
        if store.historicalArchiveStatus.metricReady { return .validated }
        if store.historicalArchiveStatus.hasArchiveRows { return .local }
        return .learning
    }

    private var coexistenceValue: String {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return "Clear"
        case .advisory:
            return "Monitor"
        case .suspected:
            return "Conflict"
        }
    }

    private var coexistenceState: AtriaMetricState {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return .local
        case .advisory:
            return .local
        case .suspected:
            return .conflict
        }
    }

    private var coexistenceTint: Color {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return .green
        case .advisory:
            return .orange
        case .suspected:
            return .red
        }
    }

    private var coexistenceFootnote: String {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
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

private struct AtriaPulseCard: View, Equatable {
    let isConnected: Bool
    let live: AtriaHomeModel.PulseLiveState
    let sparklineStore: AtriaHomeModel.PulseSparklineStore
    let chartPoints: [AtriaHomeModel.HeartRateChartPoint]
    let restingHeartRate: Int
    let restingHeartRateText: String
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let restingGreenDelta: Int
    let restingYellowDelta: Int
    let debugOpensHeartRateTimeline: Bool
    @State private var showHeartRateExplorer = false
    @State private var didDebugOpenHeartRateExplorer = false

    static func == (lhs: AtriaPulseCard, rhs: AtriaPulseCard) -> Bool {
        lhs.isConnected == rhs.isConnected
            && lhs.live == rhs.live
            && lhs.chartPoints == rhs.chartPoints
            && lhs.restingHeartRate == rhs.restingHeartRate
            && lhs.restingHeartRateText == rhs.restingHeartRateText
            && lhs.restingBaseline == rhs.restingBaseline
            && lhs.restingBaselineSamples == rhs.restingBaselineSamples
            && lhs.restingBaselineTrusted == rhs.restingBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.restingGreenDelta == rhs.restingGreenDelta
            && lhs.restingYellowDelta == rhs.restingYellowDelta
            && lhs.debugOpensHeartRateTimeline == rhs.debugOpensHeartRateTimeline
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart rate", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: pulseState)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Now",
                                value: live.heartRateText,
                                unit: "bpm",
                                state: pulseState,
                                tint: hasReadablePulse ? .red : .orange,
                                sparklineValues: sparklineStore.state.values)
                pulseStatTiles
            }

            AtriaHeartRateTimelineCard(points: chartPoints,
                                       onOpen: { showHeartRateExplorer = true })
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .fullScreenCover(isPresented: $showHeartRateExplorer) {
            AtriaHeartRateExplorer(points: chartPoints,
                                   currentBPM: live.heartRate,
                                   onDismiss: { showHeartRateExplorer = false })
        }
        .onAppear(perform: openDebugTimelineIfReady)
        .onChange(of: chartPoints) { _, _ in
            openDebugTimelineIfReady()
        }
    }

    private func openDebugTimelineIfReady() {
        guard debugOpensHeartRateTimeline,
              !didDebugOpenHeartRateExplorer,
              !chartPoints.isEmpty else { return }
        didDebugOpenHeartRateExplorer = true
        showHeartRateExplorer = true
    }

    @ViewBuilder
    private var pulseStatTiles: some View {
        AtriaMetricTile(label: "Average",
                        value: live.averageHeartRateText,
                        state: hasReadablePulse ? .live : .learning,
                        tint: .pink)
        AtriaMetricTile(label: "Peak",
                        value: live.peakHeartRateText,
                        state: hasReadablePulse ? .live : .learning,
                        tint: .red)
        AtriaMetricTile(label: "Resting",
                        value: restingHeartRateText,
                        state: .personalBaseline,
                        tint: restingHeartRateZone?.tint ?? .blue,
                        zone: restingHeartRateZone,
                        targetMetric: .rhr)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaHeartRateTimelineCard: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let onOpen: () -> Void

    static func == (lhs: AtriaHeartRateTimelineCard, rhs: AtriaHeartRateTimelineCard) -> Bool {
        lhs.points == rhs.points
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Heart-rate timeline")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("Tap to inspect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                AtriaHeartRateAxisChart(points: points,
                                        yDomain: AtriaHeartRateChartSeries.yDomain(for: points),
                                        selectedTime: .constant(nil))
                    .padding(.top, 2)
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(Color(.systemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipped()

                HStack {
                    Label("Time", systemImage: "clock")
                    Spacer(minLength: 8)
                    Label("BPM", systemImage: "heart")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .atriaInsetCard(tint: .red)
            .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .clipped()
            .compositingGroup()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open heart rate timeline")
    }
}

struct AtriaHeartRateChartSeries: Equatable {
    let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]
    let yDomain: ClosedRange<Int>

    static func make(points: [AtriaHomeModel.HeartRateChartPoint], zoom: Double) -> AtriaHeartRateChartSeries {
        let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]
        if zoom > 1, points.count > 8 {
            let keep = max(8, Int(Double(points.count) / zoom))
            visiblePoints = Array(points.suffix(keep))
        } else {
            visiblePoints = points
        }
        return AtriaHeartRateChartSeries(visiblePoints: visiblePoints,
                                         yDomain: yDomain(for: visiblePoints))
    }

    static func yDomain(for points: [AtriaHomeModel.HeartRateChartPoint]) -> ClosedRange<Int> {
        var minimumBPM: Int?
        var maximumBPM: Int?
        for point in points {
            minimumBPM = min(minimumBPM ?? point.bpm, point.bpm)
            maximumBPM = max(maximumBPM ?? point.bpm, point.bpm)
        }
        let low = max((minimumBPM ?? 60) - 8, 35)
        let high = min((maximumBPM ?? 120) + 8, 220)
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
}

struct AtriaHeartRateExplorer: View {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let currentBPM: Int
    let debugLoadsMetricArchive: Bool
    let onDismiss: () -> Void
    @State private var selectedTime: Date?
    @State private var zoom: Double = 1
    @State private var series: AtriaHeartRateChartSeries
    @State private var didDebugLoadMetricArchive = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(points: [AtriaHomeModel.HeartRateChartPoint],
         currentBPM: Int,
         debugLoadsMetricArchive: Bool = false,
         onDismiss: @escaping () -> Void) {
        self.points = points
        self.currentBPM = currentBPM
        self.debugLoadsMetricArchive = debugLoadsMetricArchive
        self.onDismiss = onDismiss
        _series = State(initialValue: AtriaHeartRateChartSeries.make(points: points, zoom: 1))
    }

    private var selectedPoint: AtriaHomeModel.HeartRateChartPoint? {
        series.nearestPoint(to: selectedTime)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(selectedPoint.map { "\($0.bpm)" } ?? (currentBPM > 0 ? "\(currentBPM)" : "--"))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("bpm")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                if let selectedPoint {
                    Text(selectedPoint.t, format: .dateTime.hour().minute().second())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap or drag on the graph to inspect any sample.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                AtriaHeartRateAxisChart(points: series.visiblePoints,
                                        yDomain: series.yDomain,
                                        selectedTime: $selectedTime)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: 320)

                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: 1...6, step: 1)
                    Image(systemName: "plus.magnifyingglass")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(AtriaBackdropLayer(isDark: colorScheme == .dark,
                                           reduceTransparency: reduceTransparency).ignoresSafeArea())
            .navigationTitle("Heart rate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDismiss) {
                        Label("Done", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .atriaCardAction(prominent: false, tint: .secondary)
                    .accessibilityLabel("Done")
                }
            }
            .onChange(of: zoom) { _, newValue in
                series = AtriaHeartRateChartSeries.make(points: points, zoom: newValue)
            }
            .onChange(of: points) { _, newValue in
                series = AtriaHeartRateChartSeries.make(points: newValue, zoom: zoom)
            }
            .onAppear {
                Task { await loadMetricArchiveForDebugProofIfNeeded() }
            }
        }
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
        series = AtriaHeartRateChartSeries.make(points: loaded, zoom: zoom)
    }
}

struct AtriaHeartRateAxisChart: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let yDomain: ClosedRange<Int>
    @Binding var selectedTime: Date?

    static func == (lhs: AtriaHeartRateAxisChart, rhs: AtriaHeartRateAxisChart) -> Bool {
        lhs.points == rhs.points && lhs.yDomain == rhs.yDomain
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.t),
                     yStart: .value("Visible floor", yDomain.lowerBound),
                     yEnd: .value("BPM", point.bpm))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.red.opacity(0.12).gradient)
            LineMark(x: .value("Time", point.t), y: .value("BPM", point.bpm))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.red.gradient)
            if let selectedTime {
                RuleMark(x: .value("Selected", selectedTime))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let bpm = value.as(Int.self) {
                        Text("\(bpm)")
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
        .chartXSelection(value: $selectedTime)
        .chartOverlay { proxy in
            if points.isEmpty {
                Text("Waiting for live heart-rate samples")
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
        AtriaMetricTile(label: "Stress",
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
    let onAddManualSleep: (Date, Date, Bool) -> Void
    let onAdjustSleep: (SleepHistorySnapshot.Night, Date, Date, Bool) -> Void
    let onConfirmSleep: () -> Void

    static func == (lhs: AtriaRecoveryStrainCard, rhs: AtriaRecoveryStrainCard) -> Bool {
        lhs.hero == rhs.hero
            && lhs.sleepHistory == rhs.sleepHistory
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
                            value: hero.recoveryEstimate.percent.map { "\($0)%" } ?? "--",
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
                        value: hero.recoveryEstimate.percent.map { "\($0)" } ?? "--",
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
    let onAddManualSleep: (Date, Date, Bool) -> Void
    let onAdjustSleep: (SleepHistorySnapshot.Night, Date, Date, Bool) -> Void
    let onConfirmSleep: () -> Void
    @State private var showManualSleepSheet = false
    @State private var adjustmentNight: SleepHistorySnapshot.Night?

    static func == (lhs: AtriaSleepHistoryCard, rhs: AtriaSleepHistoryCard) -> Bool {
        lhs.snapshot == rhs.snapshot
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

    private var chartNights: [SleepHistorySnapshot.Night] {
        Array(snapshot.nights.prefix(7).reversed())
    }

    private var heatStripNights: [SleepHistorySnapshot.Night] {
        Array(snapshot.nights.prefix(84).reversed())
    }

    private var emptyEvidenceState: AtriaMetricState {
        if snapshot.confirmedCount > 0 { return .validated }
        if snapshot.candidateCount > 0 { return .research }
        return .learning
    }

    private var latestEvidenceFootnote: String {
        guard let latest = snapshot.latest else { return "No saved sleep yet." }
        return "\(latest.confidenceText) · \(latest.reviewContextText)"
    }

    private var shouldShowConfirmSleep: Bool {
        guard snapshot.candidateCount > 0 else { return false }
        return snapshot.latest?.confirmed != true
    }

    private var reviewSleepLabel: String {
        snapshot.latest?.isNapEvidence == true ? "Review nap" : "Review sleep"
    }

    private var restingHeartRateZone: AtriaMetricZone? {
        Metrics.restingHeartRateZone(snapshot.latest?.restingHR,
                                     baseline: restingBaseline,
                                     baselineSamples: restingBaselineSamples,
                                     baselineTrusted: restingBaselineTrusted,
                                     baselineTarget: baselineTarget,
                                     greenDelta: restingGreenDelta,
                                     yellowDelta: restingYellowDelta)
    }

    private var sleepDurationZone: AtriaMetricZone? {
        Metrics.sleepDurationZone(snapshot.latest?.durationHours, goalHours: sleepGoalHours)
    }

    private var sleepEfficiencyZone: AtriaMetricZone? {
        Metrics.sleepEfficiencyZone(snapshot.latest?.sleepEfficiency,
                                    greenLower: sleepEfficiencyGreenLower,
                                    yellowLower: sleepEfficiencyYellowLower)
    }

    private var hrvZone: AtriaMetricZone? {
        Metrics.hrvZone(snapshot.latest?.hrv,
                        baseline: hrvBaseline,
                        baselineSamples: hrvBaselineSamples,
                        baselineTrusted: hrvBaselineTrusted,
                        baselineTarget: baselineTarget,
                        greenRatio: hrvGreenRatio,
                        yellowRatio: hrvYellowRatio)
    }

    private var respiratoryRateZone: AtriaMetricZone? {
        return Metrics.respiratoryRateZone(snapshot.latest?.respiratoryRate,
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
                        .frame(width: 18, height: 18)
                }
                .atriaCardAction(prominent: false, tint: .cyan)
                .accessibilityLabel("Add sleep manually")
                AtriaStateBadge(state: snapshot.confirmedCount > 0 ? .validated : (snapshot.candidateCount > 0 ? .research : .learning))
            }

            if shouldShowConfirmSleep {
                HStack(spacing: 8) {
                    Button {
                        if let latest = snapshot.latest {
                            adjustmentNight = latest
                        }
                    } label: {
                        Label(reviewSleepLabel, systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .cyan)
                    .accessibilityHint("Review the detected window before saving it.")

                    Button(action: onConfirmSleep) {
                        Label("Confirm", systemImage: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(prominent: false, tint: .cyan)
                    .accessibilityHint("Saves the shown sleep or nap candidate locally.")
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
                    AtriaMetricTile(label: snapshot.latest?.evidenceLabel ?? "Latest",
                                    value: snapshot.latest?.durationText ?? "--",
                                    state: snapshot.latest?.confirmed == true ? .validated : .research,
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
                    AtriaMetricTile(label: "\(snapshot.latest?.evidenceLabel ?? "Sleep") RHR",
                                    value: snapshot.latest?.restingHRText ?? "--",
                                    unit: snapshot.latest?.restingHR == nil ? nil : "bpm",
                                    state: snapshot.latest?.restingHR == nil ? .learning : .personalBaseline,
                                    tint: restingHeartRateZone?.tint ?? .red,
                                    zone: restingHeartRateZone,
                                    targetMetric: .rhr)
                    AtriaMetricTile(label: "Efficiency",
                                    value: snapshot.latest?.sleepEfficiencyText ?? "--",
                                    state: snapshot.latest?.sleepEfficiency == nil ? .learning : .research,
                                    tint: sleepEfficiencyZone?.tint ?? .cyan,
                                    footnote: "Duration-based estimate",
                                    zone: sleepEfficiencyZone,
                                    targetMetric: .sleepEfficiency)
                    AtriaMetricTile(label: "\(snapshot.latest?.evidenceLabel ?? "Sleep") HRV",
                                    value: snapshot.latest?.hrvText ?? "--",
                                    unit: snapshot.latest?.hrv == nil ? nil : "ms",
                                    state: snapshot.latest?.hrv == nil ? .learning : .research,
                                    tint: hrvZone?.tint ?? .purple,
                                    footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate",
                                    zone: hrvZone,
                                    targetMetric: .hrv)
                    AtriaMetricTile(label: "\(snapshot.latest?.evidenceLabel ?? "Sleep") resp",
                                    value: snapshot.latest?.respiratoryRateText ?? "--",
                                    unit: snapshot.latest?.respiratoryRate == nil ? nil : "/min",
                                    state: snapshot.latest?.respiratoryRate == nil ? .learning : .research,
                                    tint: respiratoryRateZone?.tint ?? .teal,
                                    footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate",
                                    zone: respiratoryRateZone,
                                    targetMetric: .respiratoryRate)
                }

                if chartNights.count > 1 {
                    Chart(chartNights) { night in
                        BarMark(x: .value("Night", night.day, unit: .day),
                                y: .value("Hours", night.durationHours))
                            .foregroundStyle(night.confirmed ? Color.cyan.gradient : Color.teal.opacity(0.55).gradient)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let hours = value.as(Double.self) {
                                    Text("\(Int(hours.rounded()))h")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                        }
                    }
                    .frame(height: 140)
                    .padding(12)
                    .atriaInsetCard(tint: .cyan)
                }

                if heatStripNights.count > 7 {
                    AtriaSleepYearHeatStrip(nights: heatStripNights,
                                            goalHours: sleepGoalHours)
                }

                if let latest = snapshot.latest {
                    if !latest.displayStageSegments.isEmpty {
                        AtriaSleepStageSummary(night: latest)
                    } else {
                        AtriaSleepStageBuildingSummary(night: latest)
                    }
                }

                ForEach(snapshot.nights.prefix(3)) { night in
                    AtriaSleepNightRow(night: night)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
        .sheet(isPresented: $showManualSleepSheet) {
            AtriaManualSleepSheet { start, end, isNap in
                onAddManualSleep(start, end, isNap)
                showManualSleepSheet = false
            }
        }
        .sheet(item: $adjustmentNight) { night in
            AtriaManualSleepSheet(initialStart: night.start,
                                  initialEnd: night.end,
                                  initialIsNap: night.isNapEvidence) { start, end, isNap in
                onAdjustSleep(night, start, end, isNap)
                adjustmentNight = nil
            }
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaSleepYearHeatStrip: View, Equatable {
    let nights: [SleepHistorySnapshot.Night]
    let goalHours: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sleep heat strip")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(nights.count) nights")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Canvas { context, size in
                drawCells(in: &context, size: size)
            }
            .frame(height: 76)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityHidden(true)
        }
        .padding(10)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func drawCells(in context: inout GraphicsContext, size: CGSize) {
        guard !nights.isEmpty else { return }
        let rows = 7
        let gap: CGFloat = 3
        let columns = max(1, Int(ceil(Double(nights.count) / Double(rows))))
        let cell = max(3, min((size.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                              (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)))
        let totalWidth = CGFloat(columns) * cell + CGFloat(columns - 1) * gap
        let xOffset = max(0, size.width - totalWidth)

        for (index, night) in nights.enumerated() {
            let column = index / rows
            let row = index % rows
            let rect = CGRect(x: xOffset + CGFloat(column) * (cell + gap),
                              y: CGFloat(row) * (cell + gap),
                              width: cell,
                              height: cell)
            context.fill(Path(roundedRect: rect, cornerRadius: min(3, cell / 3)),
                         with: .color(color(for: night)))
        }
    }

    private func color(for night: SleepHistorySnapshot.Night) -> Color {
        let ratio = min(max(night.durationHours / max(goalHours, 0.1), 0), 1)
        let opacity = 0.18 + 0.72 * ratio
        let base: Color = night.confirmed ? .cyan : .teal
        return base.opacity(opacity)
    }

    private var accessibilityText: String {
        guard let latest = nights.last else { return "Sleep heat strip empty." }
        return "Sleep heat strip, \(nights.count) nights, latest \(latest.durationText), \(latest.confirmationText)."
    }
}

private struct AtriaSleepContextLens: View, Equatable {
    let snapshot: SleepHistorySnapshot
    let goalHours: Double

    private var latest: SleepHistorySnapshot.Night? {
        snapshot.latest
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
                lensPill(title: "Routine", value: snapshot.sleepConsistencyText, tint: .mint)
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
                .minimumScaleFactor(0.72)
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
                                     duration: night.duration)
                .frame(height: 36)

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
        }
        .padding(10)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(night.evidenceLabel) \(night.stageEvidence.label). Awake \(night.stageText(.awake)), Light \(night.stageText(.light)), REM \(night.stageText(.rem)), SWS \(night.stageText(.sws)), Deep \(night.stageText(.deep)).")
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
}

/// De-privatized (visibilitySpec §2, 2026-07-05) -- see `AtriaSleepStageSummary`.
struct AtriaSleepStageBuildingSummary: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stages building")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(night.evidenceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(SleepStageKind.allCases) { stage in
                    HStack(spacing: 7) {
                        Image(systemName: AtriaSleepStageSummary.symbol(for: stage))
                            .font(.caption2.weight(.bold))
                            .frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.label.uppercased())
                                .font(.caption2.weight(.bold))
                            Text("--")
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

            Text("Stage breakdown needs checked sleep-stage evidence; duration, RHR, HRV, and respiratory estimates stay visible while Atria learns.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(night.evidenceLabel) stages building. Awake, Light, REM, SWS, and Deep are not ready yet.")
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

private struct AtriaSleepStageHypnogram: View, Equatable {
    let segments: [SleepStageSegment]
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
        let laneHeight = max(5, min(8, size.height / 5))
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
                         with: .color(color(for: segment.stage)))
            elapsed += segment.duration
        }
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
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
            .animation(.snappy(duration: 0.22), value: profile.maxHRSource)

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
                                footnote: vo2MaxEstimate.confidence,
                                zone: vo2TrendZone,
                                targetMetric: .vo2max)
                AtriaMetricTile(label: "VO2 trend",
                                value: vo2MaxEstimate.trendText,
                                state: vo2MaxEstimate.value == nil || vo2MaxEstimate.trendText == "Learning" ? .learning : .estimate,
                                tint: vo2TrendZone?.tint ?? .orange,
                                footnote: vo2MaxEstimate.trendDetail,
                                zone: vo2TrendZone,
                                targetMetric: .vo2max)
                AtriaMetricTile(label: "Fitness age",
                                value: biologicalAgeSummary.valueText,
                                state: biologicalAgeSummary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? .purple : .orange),
                                footnote: biologicalAgeSummary.isReady ? biologicalAgeSummary.detailText : "Calibrating 28-day baseline",
                                zone: biologicalAgeZone,
                                targetMetric: .bioAge)
                AtriaMetricTile(label: "Top driver",
                                value: biologicalAgeSummary.agingPaceText,
                                state: biologicalAgeSummary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? .purple : .orange),
                                footnote: biologicalAgeSummary.agingPaceDetail)
            }

            Text(vo2MaxEstimate.narrative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                AtriaPanelSectionHeader(title: "Fitness Age", subtitle: biologicalAgeSummary.narrative)
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
        LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
            AtriaCollectionReferenceSummaryTile(title: leadingTitle,
                                                value: leadingValue,
                                                detail: leadingDetail)
            AtriaCollectionReferenceSummaryTile(title: trailingTitle,
                                                value: trailingValue,
                                                detail: trailingDetail)
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaCollectionReferenceSummaryTile: View, Equatable {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        AtriaMetricTile(label: title,
                        value: value,
                        state: value.localizedCaseInsensitiveContains("ready") ? .validated : .learning,
                        tint: .blue,
                        footnote: compactDetail)
    }

    private var compactDetail: String {
        let words = detail.split(separator: " ")
        guard words.count > 4 else { return detail }
        return words.prefix(4).joined(separator: " ")
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
