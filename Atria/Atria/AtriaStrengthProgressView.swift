import SwiftUI

// Estimated-1RM progress surface (design source: Claude Design "Atria App
// UI.dc.html", section 7b, 2026-08-01 design-parity slice 2).
//
// Every value is real: the hero is the latest saved session's Epley e1RM, the
// delta compares it to the most recent session at least 90 days back (and is
// withheld when nothing was logged that far back), the chart plots one dot per
// saved day, and the PR markers are days that actually beat every earlier day.
// Under three plotted sessions the card shows the learning state instead of a
// line — see `AtriaStrengthProgressPresentation`.

/// Section-7 hues from the design file: strength amber #FF9F0A with the PR
/// gold #FFD60A. On dark this is the same amber the stress metric already
/// uses, so the strength identity stays inside the app's hue system.
enum AtriaStrengthPalette {
    static let amber = Color(red: 1.0, green: 0.624, blue: 0.039)        // #FF9F0A
    static let amberTint = Color(red: 1.0, green: 0.776, blue: 0.439)    // #FFC670
    static let recordGold = Color(red: 1.0, green: 0.839, blue: 0.039)   // #FFD60A
    static let done = Color(red: 0.494, green: 0.886, blue: 0.604)       // #7EE29A
}

struct AtriaStrengthProgressView: View {
    let exercise: String
    private let timeline: [AtriaStrengthProgressPresentation.Session]
    private let records: StrengthPersonalRecords
    private let now: Date

    @State private var range: AtriaStrengthProgressPresentation.Range = .threeMonths
    @Environment(\.dismiss) private var dismiss

    init(exercise: String,
         history: [StrengthHistoryDay],
         records: StrengthPersonalRecords,
         now: Date = Date()) {
        self.exercise = exercise
        self.timeline = AtriaStrengthProgressPresentation.timeline(history)
        self.records = records
        self.now = now
    }

    // MARK: - Derived (kept out of render blocks)

    private var windowedSessions: [AtriaStrengthProgressPresentation.Session] {
        AtriaStrengthProgressPresentation.windowed(timeline, range: range, now: now)
    }

    private var chart: AtriaStrengthProgressPresentation.Chart? {
        AtriaStrengthProgressPresentation.chart(for: windowedSessions)
    }

    private var currentE1RM: Double? {
        timeline.last?.e1RM
    }

    private var delta: Double? {
        AtriaStrengthProgressPresentation.delta(timeline, now: now)
    }

    private var totalSets: Int {
        AtriaStrengthProgressPresentation.setCount(timeline)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.lg) {
                header
                heroCard
                if timeline.count >= AtriaStrengthProgressPresentation.minimumSessions {
                    rangePicker
                    chartCard
                } else {
                    learningCard
                }
                recordChips
            }
            .padding(AtriaDesignTokens.Spacing.xl)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise)
                    .font(.title3.weight(.bold))
                Text("Estimated 1RM \u{00B7} Epley")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            Button("Done") { dismiss() }
                .font(.subheadline.weight(.bold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text("CURRENT e1RM")
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.md) {
                Text(AtriaStrengthProgressPresentation.weightText(currentE1RM))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(currentE1RM == nil ? Color.secondary : AtriaStrengthPalette.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let delta {
                    deltaPill(delta)
                }
            }

            Text(heroCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.card, tint: AtriaStrengthPalette.amber)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityText)
    }

    private var heroCaption: String {
        guard let latest = timeline.last else {
            return "No sets with a weight and 1\u{2013}12 reps yet \u{2014} that's what an Epley estimate needs."
        }
        let best = "Best set \(AtriaStrengthProgressPresentation.weightText(latest.weightKg)) \u{00D7} \(latest.reps)"
        guard delta == nil else { return best }
        return "\(best) \u{00B7} a 90-day change needs a session that far back"
    }

    private var heroAccessibilityText: String {
        var text = "Current estimated one rep max "
            + AtriaStrengthProgressPresentation.weightText(currentE1RM)
        if let delta {
            text += ", \(AtriaStrengthProgressPresentation.signedWeightText(delta)) over 90 days"
        }
        return text
    }

    private func deltaPill(_ value: Double) -> some View {
        let rising = value > 0.05
        let falling = value < -0.05
        let tint: Color = rising ? AtriaStrengthPalette.done : (falling ? .red : .secondary)
        return HStack(spacing: 4) {
            Image(systemName: rising ? "arrow.up" : (falling ? "arrow.down" : "equal"))
                .font(.caption2.weight(.black))
            Text("\(AtriaStrengthProgressPresentation.signedWeightText(value)) / 90d")
                .font(.caption.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.16), in: Capsule(style: .continuous))
    }

    // MARK: - Range

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(AtriaStrengthProgressPresentation.Range.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                        range = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(option == range ? Color.black : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(option == range ? Color.white.opacity(0.95) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityName)
                .accessibilityAddTraits(option == range ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            if let chart {
                AtriaStrengthE1RMChart(chart: chart)
                    .frame(height: 170)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(chartAccessibilityText(chart))
                chartLegend
            } else {
                Text("Fewer than 3 sessions in this range.")
                    .font(.subheadline.weight(.semibold))
                Text("Pick a longer range, or log more sets \u{2014} Atria won't draw a trend from two points.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.tile, tint: AtriaStrengthPalette.amber)
    }

    private func chartAccessibilityText(_ chart: AtriaStrengthProgressPresentation.Chart) -> String {
        let records = chart.points.filter(\.isPersonalRecord).count
        let recordsText = records == 1 ? "1 personal record" : "\(records) personal records"
        return "Estimated one rep max, \(chart.points.count) sessions, "
            + "\(AtriaStrengthProgressPresentation.weightText(chart.lowValue)) to "
            + "\(AtriaStrengthProgressPresentation.weightText(chart.highValue)), \(recordsText)."
    }

    private var chartLegend: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.lg) {
            HStack(spacing: 6) {
                Capsule(style: .continuous)
                    .fill(AtriaStrengthPalette.amber)
                    .frame(width: 16, height: 2.5)
                Text("e1RM")
            }
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(AtriaStrengthPalette.recordGold, lineWidth: 2)
                    .frame(width: 10, height: 10)
                Text("PR set")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: - Learning

    private var learningCard: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.primary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(AtriaStrengthProgressPresentation.learningText(sessions: timeline.count,
                                                                    sets: totalSets))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.08), in: Capsule(style: .continuous))

            Text(AtriaStrengthProgressPresentation.needMoreText(sessions: timeline.count))
                .font(.subheadline.weight(.bold))

            Text("An estimated 1RM trend needs three workouts with a weight and 1\u{2013}12 reps. Until then Atria shows the sets you logged, not a line through them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.lg)
        .atriaInsetCard(cornerRadius: AtriaDesignTokens.Radius.tile, tint: AtriaStrengthPalette.amber)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Records

    private var recordChips: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            Text("PERSONAL RECORDS")
                .font(.caption2.weight(.bold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                recordChip(title: "Top weight",
                           value: AtriaStrengthProgressPresentation.weightText(records.maxWeightKg),
                           highlighted: false)
                recordChip(title: "Best e1RM",
                           value: AtriaStrengthProgressPresentation.weightText(records.maxE1RM),
                           highlighted: records.maxE1RM != nil)
                recordChip(title: "Rep PR",
                           value: repRecordText,
                           highlighted: false)
            }
        }
    }

    private var repRecordText: String {
        guard let record = AtriaStrengthProgressPresentation.repRecord(records) else { return "--" }
        return "\(record.reps)@\(AtriaStrengthProgressPresentation.weightText(record.weightKg))"
    }

    private func recordChip(title: String, value: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(highlighted ? AtriaStrengthPalette.recordGold : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AtriaDesignTokens.Spacing.md)
        .background(highlighted
                    ? AtriaStrengthPalette.recordGold.opacity(0.14)
                    : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

/// The amber e1RM line with its gradient area, one dot per saved session and
/// the PR markers (hollow for past records, solid for the newest).
struct AtriaStrengthE1RMChart: View {
    let chart: AtriaStrengthProgressPresentation.Chart

    private let leadingInset: CGFloat = 42
    private let bottomInset: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let plotWidth = max(proxy.size.width - leadingInset - 8, 1)
            let plotHeight = max(proxy.size.height - bottomInset - 8, 1)

            ZStack(alignment: .topLeading) {
                gridlines(width: plotWidth, height: plotHeight)
                yAxis(height: plotHeight)
                area(width: plotWidth, height: plotHeight)
                line(width: plotWidth, height: plotHeight)
                markers(width: plotWidth, height: plotHeight)
                xAxis(width: plotWidth, top: plotHeight + 8)
            }
        }
    }

    private func point(_ item: AtriaStrengthProgressPresentation.Point,
                       width: CGFloat,
                       height: CGFloat) -> CGPoint {
        CGPoint(x: leadingInset + width * item.x,
                y: 8 + height * (1 - item.y))
    }

    private func gridlines(width: CGFloat, height: CGFloat) -> some View {
        ForEach(0..<3) { index in
            let y = 8 + height * CGFloat(index) / 2
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(width: width, height: 1)
                .position(x: leadingInset + width / 2, y: y)
        }
    }

    private func yAxis(height: CGFloat) -> some View {
        ForEach(Array(chart.yLabels.enumerated()), id: \.offset) { index, value in
            Text("\(Int(value.rounded()))")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: leadingInset - 8, alignment: .trailing)
                .position(x: (leadingInset - 8) / 2,
                          y: 8 + height * CGFloat(index) / 2)
        }
    }

    private func area(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            guard let first = chart.points.first, let last = chart.points.last else { return }
            path.move(to: CGPoint(x: point(first, width: width, height: height).x, y: 8 + height))
            for item in chart.points {
                path.addLine(to: point(item, width: width, height: height))
            }
            path.addLine(to: CGPoint(x: point(last, width: width, height: height).x, y: 8 + height))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [AtriaStrengthPalette.amber.opacity(0.3),
                                      AtriaStrengthPalette.amber.opacity(0.0)],
                             startPoint: .top,
                             endPoint: .bottom))
    }

    private func line(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            guard let first = chart.points.first else { return }
            path.move(to: point(first, width: width, height: height))
            for item in chart.points.dropFirst() {
                path.addLine(to: point(item, width: width, height: height))
            }
        }
        .stroke(AtriaStrengthPalette.amber,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func markers(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(chart.points.enumerated()), id: \.offset) { _, item in
            let center = point(item, width: width, height: height)
            if item.isNewestPersonalRecord {
                Circle()
                    .fill(AtriaStrengthPalette.recordGold)
                    .frame(width: 12, height: 12)
                    .position(center)
            } else if item.isPersonalRecord {
                Circle()
                    .strokeBorder(AtriaStrengthPalette.recordGold, lineWidth: 2)
                    .background(Circle().fill(.black.opacity(0.85)))
                    .frame(width: 10, height: 10)
                    .position(center)
            } else {
                Circle()
                    .fill(AtriaStrengthPalette.amberTint)
                    .frame(width: 6, height: 6)
                    .position(center)
            }
        }
    }

    private func xAxis(width: CGFloat, top: CGFloat) -> some View {
        ForEach(Array(chart.xLabels.enumerated()), id: \.offset) { _, label in
            Text(label.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .position(x: leadingInset + width * label.fraction, y: top + 6)
        }
    }
}
