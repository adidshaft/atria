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
                                     tint: .cyan)
                AtriaHealthMetricRow(title: "HRV",
                                     value: hrvValue,
                                     detail: "night signal",
                                     systemImage: "waveform.path.ecg",
                                     tint: Metrics.electricGreen)
                AtriaHealthMetricRow(title: "Respiration",
                                     value: respiratoryValue,
                                     detail: "sleep average",
                                     systemImage: "lungs.fill",
                                     tint: .teal)
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
                    .font(.title3.weight(.black).monospacedDigit())
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

    static func == (lhs: AtriaHealthMetricRow, rhs: AtriaHealthMetricRow) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.systemImage == rhs.systemImage
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
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}
