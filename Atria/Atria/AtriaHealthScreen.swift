import SwiftUI

struct AtriaHealthScreen: View {
    #if DEBUG
    static let debugOpenHeartRateTimelineKey = "atria.debug.openHeartRateTimeline"
    #endif

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
    @State private var historicalHeartRatePoints: [AtriaHomeModel.HeartRateChartPoint] = []
    @State private var isLoadingHistoricalHeartRatePoints = true
    @StateObject private var stressMonitorStore = AtriaStressMonitorStore()

    private static let stressRecomputeTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var chartPoints: [AtriaHomeModel.HeartRateChartPoint] {
        AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: pulseSparklineStore.state.chartPoints,
                                                           historical: historicalHeartRatePoints)
    }

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaHealthScreen")
        Group {
            if Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments) {
                AtriaHealthTimelineProofCard(points: chartPoints,
                                             isLoading: isLoadingHistoricalHeartRatePoints)
            } else {
                VStack(spacing: 12) {
                    healthMonitorCard
                    AtriaHealthFitnessAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary)
                }
            }
        }
        .task {
            await refreshHistoricalHeartRatePoints()
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoricalArchive.didUpdateNotification)) { _ in
            Task {
                await refreshHistoricalHeartRatePoints()
            }
        }
        .onAppear { recomputeStress() }
        .onReceive(Self.stressRecomputeTimer) { _ in recomputeStress() }
    }

    private func recomputeStress() {
        stressMonitorStore.update(heartRate: pulseStore.state.heartRate,
                                  hasContact: pulseStore.state.hasContact,
                                  recentRRSamples: pulseStore.state.recentRRSamples,
                                  isRecording: ble.isRecording,
                                  zoneIndex: pulseStore.state.heartRateZone?.index,
                                  hrvSnapshot: ble.hrvSnapshot,
                                  baseline: store.baseline,
                                  restingMaxHR: (rest: store.baseline.restingInt ?? 60,
                                                max: profileStore.profile.maxHR))
    }

    private var healthMonitorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 8) {
                AtriaHealthMetricRow(title: "Recovery",
                                     value: recoveryValue,
                                     detail: recoveryDetail,
                                     systemImage: "heart.fill",
                                     tint: recoveryTint)
                AtriaHealthMetricRow(title: "Resting HR",
                                     value: restingHeartRateValue,
                                     detail: "overnight low",
                                     systemImage: "heart.text.square.fill",
                                     tint: .cyan,
                                     rangeText: restingHeartRateRangeText)
                AtriaHealthMetricRow(title: "HRV",
                                     value: hrvValue,
                                     detail: "night signal",
                                     systemImage: "waveform.path.ecg",
                                     tint: Metrics.electricGreen,
                                     rangeText: hrvRangeText)
                AtriaHealthMetricRow(title: "Stress",
                                     value: stressValue,
                                     detail: stressDetail,
                                     systemImage: "bolt.heart.fill",
                                     tint: stressTint)
                AtriaHealthMetricRow(title: "Respiration",
                                     value: respiratoryValue,
                                     detail: "sleep average",
                                     systemImage: "lungs.fill",
                                     tint: .teal,
                                     rangeText: respiratoryRangeText)
                AtriaHealthMetricRow(title: "Sleep",
                                     value: sleepValue,
                                     detail: sleepDetail,
                                     systemImage: "moon.fill",
                                     tint: Metrics.electricSleep)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @MainActor
    private func refreshHistoricalHeartRatePoints() async {
        let debugTimeline = Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments)
        let since = debugTimeline
            ? nil
            : Calendar.current.date(byAdding: .day, value: -2, to: Date())
        let limit = debugTimeline ? 6_000 : nil
        isLoadingHistoricalHeartRatePoints = true
        let points: [AtriaHomeModel.HeartRateChartPoint]
        if debugTimeline {
            points = HistoricalArchive.metricHeartRatePoints(since: since, limit: limit).map {
                AtriaHomeModel.HeartRateChartPoint(t: $0.t, bpm: $0.bpm)
            }
        } else {
            points = await Task.detached(priority: .utility) {
                HistoricalArchive.metricHeartRatePoints(since: since, limit: limit).map {
                    AtriaHomeModel.HeartRateChartPoint(t: $0.t, bpm: $0.bpm)
                }
            }.value
        }
#if DEBUG
        AtriaDebugLog("ATRIADBG hist1_timeline_fixture status=loaded points=%d since=%@ limit=%d",
                      points.count,
                      since.map { ISO8601DateFormatter().string(from: $0) } ?? "full_archive",
                      limit ?? 0)
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Health Monitor")
                    .font(.title2.weight(.bold))
                Text("Typical range")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(statusValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(statusTint.opacity(0.12), in: Capsule(style: .continuous))
        }
    }

    private var latestRollup: DailyRollupStoreEntry? {
        store.dailyRollupHistory.sorted { $0.day > $1.day }.first
    }

    private var recoveryValue: String {
        if let value = latestRollup?.recovery {
            return "\(value)%"
        }
        return "Building"
    }

    private var recoveryDetail: String {
        latestRollup?.recovery == nil ? "building" : "saved"
    }

    private var recoveryTint: Color {
        if let value = latestRollup?.recovery {
            return Metrics.recoveryColor(value)
        }
        return .secondary
    }

    private var restingHeartRateValue: String {
        AtriaMetricFormat.restingHeartRate(latestRollup?.rhr.map(Double.init))
    }

    private var hrvValue: String {
        if let lnRMSSD = latestRollup?.lnRMSSD {
            return AtriaMetricFormat.hrv(exp(lnRMSSD))
        }
        return "--"
    }

    private var respiratoryValue: String {
        guard let value = latestRollup?.respiratoryRate else {
            return "--"
        }
        return String(format: "%.1f rpm", value)
    }

    private var sleepValue: String {
        AtriaMetricFormat.sleepDuration(seconds: latestRollup?.sleepSeconds)
    }

    private var sleepDetail: String {
        if let performance = latestRollup?.sleepPerformance {
            return "\(performance)% need"
        }
        return "last night"
    }

    // MARK: Stress (AtriaStressMonitor)

    private var stressValue: String {
        stressMonitorStore.state.level?.title ?? stressMonitorStore.state.label
    }

    private var stressDetail: String {
        stressMonitorStore.state.detail.isEmpty ? stressMonitorStore.state.label : stressMonitorStore.state.detail
    }

    private var stressTint: Color {
        stressMonitorStore.state.level?.tint ?? .secondary
    }

    // MARK: Typical-for-you reference ranges (only shown once a baseline is trusted)

    private var restingHeartRateRangeText: String? {
        guard store.baseline.hasTrustedRestingBaseline(),
              let stats = store.baseline.restingStats, stats.count > 1 else { return nil }
        return Self.typicalRangeText(mean: stats.mean, sd: stats.sd, unit: "bpm", decimals: 0)
    }

    private var hrvRangeText: String? {
        guard store.baseline.hasTrustedHRVBaseline(),
              let stats = store.baseline.lnRMSSDStats, stats.count > 1 else { return nil }
        let low = exp(stats.mean - 1.5 * stats.sd)
        let high = exp(stats.mean + 1.5 * stats.sd)
        return Self.typicalRangeText(low: max(low, 0), high: high, unit: "ms", decimals: 0)
    }

    private var respiratoryRangeText: String? {
        guard let stats = store.sleepHistorySnapshot.respiratoryBaselineStats, stats.count > 1 else { return nil }
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

    private var statusValue: String {
        guard latestRollup != nil else { return "Learning" }
        return "Updated"
    }

    private var statusTint: Color {
        statusValue == "Updated" ? Metrics.electricGreen : .secondary
    }
}

private struct AtriaHealthFitnessAgeCard: View, Equatable {
    let summary: BiologicalAgeSummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Fitness age")
                        .font(.headline.weight(.bold))
                    Text(summary.isReady ? summary.detailText : "Calibrating 28-day baseline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(summary.valueText)
                    .font(.system(.title3, design: .rounded, weight: .black))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(tint)
            }

            Text(summary.isReady ? summary.agingPaceDetail : summary.blockerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(summary.footnote)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fitness age. \(summary.valueText). \(summary.isReady ? summary.detailText : "Calibrating 28-day baseline"). \(summary.footnote)")
    }

    private var tint: Color {
        guard summary.isReady else { return .orange }
        return (summary.ageDelta ?? 0) <= 0 ? .green : .purple
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
                        .lineLimit(2)
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
                                    selectedTime: $selectedTime)
                .frame(height: 430)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Heart-rate timeline proof. \(countText). \(rangeText).")
    }
}

private struct AtriaHealthMetricRow: View, Equatable {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    var rangeText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaHealthMetricRow, rhs: AtriaHealthMetricRow) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.systemImage == rhs.systemImage
            && lhs.rangeText == rhs.rangeText
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Fixed-height slot rendered on every row (even when this
                // metric has no trusted range yet) so all six rows share
                // one height and every reference-range line that does
                // appear lands on the same baseline across rows.
                Text(rangeText ?? " ")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .opacity(rangeText == nil ? 0 : 1)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rangeText.map { "\(title), \(value), \(detail). \($0)." } ?? "\(title), \(value), \(detail)")
    }
}
