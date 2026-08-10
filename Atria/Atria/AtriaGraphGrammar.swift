import SwiftUI
import Charts

/// Shared rendering grammar for every chart surface.
///
/// Atria deliberately distinguishes visual smoothness from data smoothing:
/// trend charts curve between their real anchors, and high-frequency
/// physiological traces (live Heart-rate, Stress) join samples inside a short
/// continuity window with a shape-preserving curve while breaking hard across a
/// genuine dropout (see `traceDisplayContinuityGap`). Neither mode drops,
/// averages, nor manufactures a recorded sample.
enum AtriaChartVisualGrammar {
    /// Display-only continuity window for high-frequency physiological traces
    /// (live Heart-rate, Stress). Consecutive real samples closer than this are
    /// treated as one continuous run and joined with a shape-preserving
    /// `.monotone` curve, so a couple of dropped samples read as a smooth line
    /// instead of a jagged break. A gap LONGER than this is a real dropout: the
    /// run ends, the next sample opens a new Charts `series`, and the interval
    /// is left blank — never bridged. Deliberately tight (five minutes, not a
    /// multi-hour bridge) so it smooths only brief signal hiccups, and the
    /// strict data/coverage thresholds (`heartRateGapThreshold`,
    /// `maximumFactContinuityGap`) are left untouched, so telemetry-integrity
    /// and coverage accounting keep their exact meaning.
    static let traceDisplayContinuityGap: TimeInterval = 5 * 60

    static let trendLine = StrokeStyle(
        lineWidth: 2.25,
        lineCap: .round,
        lineJoin: .round
    )

    static let traceLine = StrokeStyle(
        lineWidth: 1.8,
        lineCap: .round,
        lineJoin: .round
    )

    static let comparisonLine = StrokeStyle(
        lineWidth: 1.5,
        lineCap: .round,
        lineJoin: .round,
        dash: [5, 4]
    )
}

extension View {
    /// A quiet, plot-aligned surface gives axes and dense traces enough
    /// contrast without adding a competing card inside the existing card.
    func atriaGraphPlotSurface() -> some View {
        chartPlotStyle { plotArea in
            plotArea
                .background(Color.primary.opacity(0.035))
                .clipShape(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
    }
}

/// Design-parity slice 4 — graph interaction grammar (design spec section 4).
/// The scrub (1), brush (5), and landscape (6) patterns already live in
/// AtriaGraphInspector / AtriaExpandedChart; this file adds the three gaps the
/// spec cross-reference calls out:
///   • pattern 2 — Compare (overlay a comparison period, honest delta card,
///     "compare against" options gated to data that actually exists)
///   • pattern 3 — Range & interval (window + bucket + real min–max band)
///   • pattern 4 — Edit chart (plot list, chart-type picker, journal markers)
///
/// Every model here is pure and value-typed so the delta math, the min–max
/// envelope, and the "no prior data → disabled" rule are unit-testable without
/// a view. Project law: no fabricated series — where the comparison data is
/// missing the mode is disabled with a plain-language reason, never invented.

// MARK: - Chart type (pattern 4: CHART TYPE — Line | Bars | Range)

enum AtriaGraphChartType: String, CaseIterable, Identifiable, Sendable {
    case line
    case bars
    case range

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: return "Line"
        case .bars: return "Bars"
        case .range: return "Range"
        }
    }

    /// Mini-glyph shown beside each type in the edit-chart sheet.
    var glyph: String {
        switch self {
        case .line: return "chart.xyaxis.line"
        case .bars: return "chart.bar.fill"
        case .range: return "arrow.up.and.down"
        }
    }

    /// "Range" draws a per-bucket min–max envelope, so it is only honest when
    /// the plotted points actually carry a real band. A single daily value has
    /// no range to draw, and Atria never synthesizes one — so Range is simply
    /// not offered for band-less series.
    static func options(hasMinMaxBand: Bool) -> [AtriaGraphChartType] {
        hasMinMaxBand ? allCases : [.line, .bars]
    }
}

// MARK: - Compare (pattern 2: COMPARE AGAINST)

enum AtriaGraphCompareMode: String, CaseIterable, Identifiable, Sendable {
    case previousPeriod
    case samePeriodLastYear
    case ageGroupTypical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previousPeriod: return "Previous period"
        case .samePeriodLastYear: return "Same period last year"
        case .ageGroupTypical: return "Age-group typical"
        }
    }

    var subtitle: String {
        switch self {
        case .previousPeriod: return "Overlay the window just before this one."
        case .samePeriodLastYear: return "Overlay the same dates a year ago."
        case .ageGroupTypical: return "Compare against a typical range for your age."
        }
    }
}

/// Which comparison modes can be shown, decided from the real stored series.
/// `ageGroupTypical` is always false: Atria ships no age-group reference set,
/// and the honesty rule forbids inventing one.
struct AtriaGraphCompareAvailability: Equatable {
    let previousPeriod: Bool
    let samePeriodLastYear: Bool
    let ageGroupTypical: Bool

    func isAvailable(_ mode: AtriaGraphCompareMode) -> Bool {
        switch mode {
        case .previousPeriod: return previousPeriod
        case .samePeriodLastYear: return samePeriodLastYear
        case .ageGroupTypical: return ageGroupTypical
        }
    }

    /// Plain-language reason a mode is off, or nil when it is available.
    func disabledNote(for mode: AtriaGraphCompareMode) -> String? {
        guard !isAvailable(mode) else { return nil }
        switch mode {
        case .previousPeriod:
            return "Not enough saved history before this window yet."
        case .samePeriodLastYear:
            return "You don't have a year of history for this metric yet."
        case .ageGroupTypical:
            return "Atria ships no age-group reference — it won't invent one."
        }
    }

    /// The first available mode, or nil when nothing can be compared honestly.
    var firstAvailable: AtriaGraphCompareMode? {
        AtriaGraphCompareMode.allCases.first(where: isAvailable)
    }

    /// Same minimum-evidence rule the detail chart's ghost overlay uses: a
    /// couple of stray comparison samples must not fabricate a comparison.
    static func minimumEvidenceMet(currentCount: Int, comparisonCount: Int) -> Bool {
        currentCount > 0 && comparisonCount >= max(3, currentCount / 2)
    }

    static func make(currentCount: Int,
                     previousPeriodCount: Int,
                     samePeriodLastYearCount: Int) -> AtriaGraphCompareAvailability {
        AtriaGraphCompareAvailability(
            previousPeriod: minimumEvidenceMet(currentCount: currentCount,
                                               comparisonCount: previousPeriodCount),
            samePeriodLastYear: minimumEvidenceMet(currentCount: currentCount,
                                                   comparisonCount: samePeriodLastYearCount),
            ageGroupTypical: false
        )
    }
}

/// Honest delta between the current window and its comparison window. Returns
/// nil when the comparison series is too thin to state a change — the caller
/// then shows the disabled note instead of a number.
struct AtriaGraphCompareDelta: Equatable {
    let currentAverage: Double
    let comparisonAverage: Double
    let delta: Double
    let deltaText: String
    let currentText: String
    let comparisonText: String
    let scopeText: String

    var isIncrease: Bool { delta > 0 }
    var isFlat: Bool { abs(delta) < 0.05 }

    init?(current: [Double],
          comparison: [Double],
          unit: String,
          scopeText: String) {
        guard AtriaGraphCompareAvailability.minimumEvidenceMet(currentCount: current.count,
                                                               comparisonCount: comparison.count)
        else { return nil }
        let currentAverage = current.reduce(0, +) / Double(current.count)
        let comparisonAverage = comparison.reduce(0, +) / Double(comparison.count)
        self.currentAverage = currentAverage
        self.comparisonAverage = comparisonAverage
        self.delta = currentAverage - comparisonAverage
        self.deltaText = Self.signedText(delta, unit: unit)
        self.currentText = Self.plainText(currentAverage, unit: unit)
        self.comparisonText = Self.plainText(comparisonAverage, unit: unit)
        self.scopeText = scopeText
    }

    /// "Month-over-month" style scope wording for a `.previousPeriod` compare
    /// over a single-word window noun; a longer phrase falls back to a clause.
    static func previousPeriodScope(noun: String) -> String {
        let trimmed = noun.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Vs previous period" }
        if trimmed.contains(" ") {
            return "Vs the previous \(trimmed)"
        }
        return "\(trimmed.prefix(1).uppercased())\(trimmed.dropFirst())-over-\(trimmed)"
    }

    static func scope(for mode: AtriaGraphCompareMode, noun: String) -> String {
        switch mode {
        case .previousPeriod:
            return previousPeriodScope(noun: noun)
        case .samePeriodLastYear:
            return "Vs the same \(noun) last year"
        case .ageGroupTypical:
            return "Vs age-group typical"
        }
    }

    private static func separator(for unit: String) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty || trimmed == "%") ? "" : " "
    }

    static func signedText(_ value: Double, unit: String) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        let sep = separator(for: unit)
        if value.rounded() == value {
            return String(format: "%+.0f%@%@", value, sep, trimmed)
        }
        return String(format: "%+.1f%@%@", value, sep, trimmed)
    }

    private static func plainText(_ value: Double, unit: String) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        let sep = separator(for: unit)
        if value.rounded() == value {
            return String(format: "%.0f%@%@", value, sep, trimmed)
        }
        return String(format: "%.1f%@%@", value, sep, trimmed)
    }
}

// MARK: - Range & interval (pattern 3: real per-bucket min–max envelope)

enum AtriaGraphBucketInterval: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// Pure per-bucket aggregation. Each emitted point's value is the bucket's
/// real average and its band is the bucket's real min–max — nothing is
/// interpolated or padded. `.day` returns the points unchanged (a single day
/// has no envelope). Optionally clamps the plotted day into a visible period
/// so a first partial bucket keyed before the window is not clipped away
/// (same fix as the weekly path in AtriaPreparedMetricHistory).
enum AtriaGraphMinMaxEnvelope {
    static func bucketed(_ points: [AtriaDetailChartPoint],
                         by interval: AtriaGraphBucketInterval,
                         calendar: Calendar = .current,
                         within clamp: DateInterval? = nil) -> [AtriaDetailChartPoint] {
        guard interval != .day, !points.isEmpty else { return points }
        var buckets: [Date: [AtriaDetailChartPoint]] = [:]
        for point in points {
            let start = calendar.dateInterval(of: interval.component, for: point.day)?.start
                ?? calendar.startOfDay(for: point.day)
            buckets[start, default: []].append(point)
        }
        return buckets.keys.sorted().map { start in
            let members = buckets[start] ?? []
            let values = members.map(\.value)
            let average = values.reduce(0, +) / Double(max(values.count, 1))
            let nearest = members.min { abs($0.value - average) < abs($1.value - average) }
            let plottedDay = clamp.map { max(start, $0.start) } ?? start
            return AtriaDetailChartPoint(day: plottedDay,
                                         value: average,
                                         tint: nearest?.tint ?? .secondary,
                                         bandLower: values.min(),
                                         bandUpper: values.max())
        }
    }
}

// MARK: - Compare legend + delta card (shared expanded-chart surfaces)

/// Legend swatches: current period solid in the metric hue, comparison dashed
/// in muted white — the exact grammar the spec's pattern 2 describes.
struct AtriaGraphCompareLegend: View {
    let currentTitle: String
    let currentTint: Color
    let comparisonTitle: String

    var body: some View {
        HStack(spacing: 14) {
            swatch(title: currentTitle, tint: currentTint, dashed: false)
            swatch(title: comparisonTitle, tint: .secondary, dashed: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(currentTitle), solid line. \(comparisonTitle), dashed line.")
    }

    private func swatch(title: String, tint: Color, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Capsule()
                    .fill(dashed ? Color.clear : tint.opacity(0.9))
                if dashed {
                    Capsule()
                        .stroke(tint.opacity(0.6),
                                style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                }
            }
            .frame(width: 18, height: 3)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// The delta card: "+8.4 ms · Month-over-month" plus the two real averages it
/// was computed from. Rendered only when a delta could be stated honestly.
struct AtriaGraphCompareDeltaCard: View {
    let delta: AtriaGraphCompareDelta
    let tint: Color

    private var symbol: String {
        if delta.isFlat { return "equal.circle.fill" }
        return delta.isIncrease ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(delta.deltaText)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(tint)
                    Text(delta.scopeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("This window \(delta.currentText) · comparison \(delta.comparisonText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(delta.scopeText), \(delta.deltaText). This window \(delta.currentText), comparison \(delta.comparisonText).")
    }
}

// MARK: - Compare sheet (pattern 2)

struct AtriaGraphCompareSheet: View {
    @Binding var compareOn: Bool
    @Binding var mode: AtriaGraphCompareMode
    let availability: AtriaGraphCompareAvailability
    let delta: AtriaGraphCompareDelta?
    let tint: Color
    @Environment(\.dismiss) private var dismiss

    private var anyAvailable: Bool { availability.firstAvailable != nil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if anyAvailable {
                    Toggle(isOn: $compareOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compare")
                                .font(.subheadline.weight(.semibold))
                            Text("Overlay a comparison period on this trend.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(tint)
                } else {
                    // Nothing to compare against yet — say so, don't offer a
                    // dead toggle.
                    Label("Nothing to compare against yet", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Keep wearing your strap — once there's enough saved history before this window, comparison turns on here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("COMPARE AGAINST")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.tertiary)
                        .kerning(0.8)
                    ForEach(AtriaGraphCompareMode.allCases) { option in
                        compareRow(option)
                    }
                }

                if compareOn, let delta {
                    AtriaGraphCompareDeltaCard(delta: delta, tint: tint)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func compareRow(_ option: AtriaGraphCompareMode) -> some View {
        let enabled = availability.isAvailable(option)
        let selected = enabled && compareOn && mode == option
        Button {
            guard enabled else { return }
            mode = option
            compareOn = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? tint : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Text(availability.disabledNote(for: option) ?? option.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((selected ? tint : Color.secondary).opacity(selected ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(option.title)
        .accessibilityValue(enabled ? (selected ? "Selected" : "Available") : "Unavailable")
        .accessibilityHint(availability.disabledNote(for: option) ?? "")
    }
}

// MARK: - Edit chart sheet (pattern 4)

struct AtriaEditChartPlotOption: Identifiable, Equatable {
    let title: String
    let tint: Color
    let hasData: Bool

    var id: String { title }
}

struct AtriaEditChartSheet: View {
    let primaryTitle: String
    let primaryTint: Color
    let plotOptions: [AtriaEditChartPlotOption]
    @Binding var activeOverlayTitle: String?
    @Binding var chartType: AtriaGraphChartType
    let chartTypeOptions: [AtriaGraphChartType]
    @Binding var markJournalEvents: Bool
    let hasJournalEvents: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    plotSection
                    chartTypeSection
                    journalSection
                }
                .padding(18)
            }
            .navigationTitle("Edit chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private var plotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLOT")
                .font(.caption2.weight(.black))
                .foregroundStyle(.tertiary)
                .kerning(0.8)

            // Primary metric is always plotted — shown fixed so the list reads
            // as a plot set, not a choice that could hide the metric itself.
            HStack(spacing: 10) {
                swatch(primaryTint)
                Text(primaryTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("Always shown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)

            if plotOptions.isEmpty {
                Text("No sibling metrics have enough saved data to overlay here yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(plotOptions) { option in
                    plotRow(option)
                }
                Text("Overlays are scaled to fit this chart — a shape comparison, not shared units.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func plotRow(_ option: AtriaEditChartPlotOption) -> some View {
        let isActive = activeOverlayTitle == option.title
        Button {
            guard option.hasData else { return }
            // One overlay at a time: the chart rescales a single sibling into
            // its y-domain, so selecting one clears the other.
            activeOverlayTitle = isActive ? nil : option.title
        } label: {
            HStack(spacing: 10) {
                swatch(option.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("+ \(option.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(option.hasData ? .primary : .secondary)
                    if !option.hasData {
                        Text("No saved data to overlay yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? option.tint : .secondary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(!option.hasData)
        .accessibilityLabel("Overlay \(option.title)")
        .accessibilityValue(isActive ? "On" : "Off")
    }

    private var chartTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHART TYPE")
                .font(.caption2.weight(.black))
                .foregroundStyle(.tertiary)
                .kerning(0.8)
            HStack(spacing: 10) {
                ForEach(chartTypeOptions) { type in
                    chartTypeChip(type)
                }
            }
            if !chartTypeOptions.contains(.range) {
                Text("Range needs a min–max band, so it appears only when the chart is bucketed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chartTypeChip(_ type: AtriaGraphChartType) -> some View {
        let selected = chartType == type
        return Button {
            chartType = type
        } label: {
            VStack(spacing: 6) {
                Image(systemName: type.glyph)
                    .font(.title3)
                Text(type.label)
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(selected ? primaryTint : .secondary)
            .background((selected ? primaryTint : Color.secondary).opacity(selected ? 0.14 : 0.06),
                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                    .stroke(selected ? primaryTint.opacity(0.4) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(type.label) chart")
        .accessibilityValue(selected ? "Selected" : "")
    }

    @ViewBuilder
    private var journalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $markJournalEvents) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mark journal events")
                        .font(.subheadline.weight(.semibold))
                    Text(hasJournalEvents
                         ? "Pin your real workouts and confirmed sleeps onto the chart."
                         : "No saved workouts or confirmed sleeps in this window to mark.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(primaryTint)
            .disabled(!hasJournalEvents)
        }
    }

    private func swatch(_ tint: Color) -> some View {
        Capsule()
            .fill(tint.opacity(0.9))
            .frame(width: 18, height: 3)
    }
}
