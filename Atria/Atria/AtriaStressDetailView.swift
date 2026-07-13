import Charts
import SwiftUI

/// One measured stress reading for the detail timeline.
///
/// `score` uses Atria's live 0...3 scale. Callers should only create readings
/// from values the stress monitor actually emitted; the detail view never
/// fills gaps or manufactures a baseline.
struct AtriaStressDetailReading: Identifiable, Equatable {
    let date: Date
    let score: Double

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }

    init(date: Date, score: Double) {
        self.date = date
        self.score = min(max(score, 0), 3)
    }

    init(historyPoint: AtriaStressMonitorStore.StressHistoryPoint) {
        self.init(date: historyPoint.t, score: historyPoint.activation * 3)
    }
}

/// Immutable input for `AtriaStressDetailView`.
///
/// Keeping this as a value makes the detail screen cheap to update and easy to
/// integrate with either `AtriaStressMonitorStore` or a future persisted source.
struct AtriaStressDetailInput: Equatable {
    let state: AtriaStressState
    let readings: [AtriaStressDetailReading]
    /// Time the current state was actually evaluated. Nil is rendered honestly
    /// as an untimed state rather than being replaced with `Date()`.
    let updatedAt: Date?
    let distributionComparison: AtriaStressDistributionComparison?
    /// Explicitly logged context for the current day. These are displayed as
    /// context—not inferred causes—because daily journal tags have no timestamp
    /// precise enough to attribute a stress peak.
    let loggedContext: [AtriaStressLoggedContext]

    init(state: AtriaStressState,
         readings: [AtriaStressDetailReading],
         updatedAt: Date?,
         distributionComparison: AtriaStressDistributionComparison? = nil,
         loggedContext: [AtriaStressLoggedContext] = []) {
        self.state = state
        self.readings = readings.sorted { $0.date < $1.date }
        self.updatedAt = updatedAt
        self.distributionComparison = distributionComparison
        self.loggedContext = loggedContext
    }

    init(state: AtriaStressState,
         history: [AtriaStressMonitorStore.StressHistoryPoint],
         updatedAt: Date?,
         distributionComparison: AtriaStressDistributionComparison? = nil,
         loggedContext: [AtriaStressLoggedContext] = []) {
        self.init(state: state,
                  readings: history.map(AtriaStressDetailReading.init(historyPoint:)),
                  updatedAt: updatedAt,
                  distributionComparison: distributionComparison,
                  loggedContext: loggedContext)
    }

    /// The scoring core emits a continuous activation in 0...1. Presenting it
    /// on the product's documented 0...3 scale is a direct unit conversion.
    var score: Double? {
        guard state.kind == .scored, state.level != nil else { return nil }
        return min(max(state.rawActivation * 3, 0), 3)
    }

    var tint: Color {
        state.level?.tint ?? Metrics.electricStress
    }
}

struct AtriaStressLoggedContext: Identifiable, Equatable {
    let id: String
    let label: String
    let systemImage: String

    init(tag: BehaviorJournalEntry.Tag) {
        id = tag.rawValue
        label = tag.label
        systemImage = tag.symbolName
    }
}

/// Full-screen, native Stress experience inspired by the supplied design.
/// Content cards are intentionally static surfaces; Liquid Glass is reserved
/// for actions so the scrolling timeline stays inexpensive on-device.
struct AtriaStressDetailView: View {
    let input: AtriaStressDetailInput
    let onDismiss: () -> Void
    let onRelax: () -> Void
    let onEnergize: (() -> Void)?
    let onInfo: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(input: AtriaStressDetailInput,
         onDismiss: @escaping () -> Void,
         onRelax: @escaping () -> Void,
         onEnergize: (() -> Void)? = nil,
         onInfo: (() -> Void)? = nil) {
        self.input = input
        self.onDismiss = onDismiss
        self.onRelax = onRelax
        self.onEnergize = onEnergize
        self.onInfo = onInfo
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header
                    hero
                    timelineCard
                    if let comparison = input.distributionComparison {
                        AtriaStressDistributionCard(comparison: comparison)
                    }
                    if !input.loggedContext.isEmpty {
                        loggedContextCard
                    }
                    interventionCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.primary)
    }

    private var background: Color {
        colorScheme == .dark ? Color(uiColor: .black) : Color(uiColor: .systemGroupedBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .frame(width: 40, height: 40)
            }
            .atriaGlassIconAction(tint: .primary, size: 40)
            .accessibilityLabel("Close Stress")

            VStack(alignment: .leading, spacing: 1) {
                Text("Stress")
                    .font(.headline.weight(.bold))
                Text(updateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let onInfo {
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .frame(width: 40, height: 40)
                }
                .atriaGlassIconAction(tint: .primary, size: 40)
                .accessibilityLabel("About Stress")
            }

            if input.state.kind == .scored {
                Label("Live", systemImage: "circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(input.tint)
                    .labelStyle(AtriaStressLiveLabelStyle())
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(input.tint.opacity(colorScheme == .dark ? 0.14 : 0.10),
                                in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(input.tint.opacity(0.34), lineWidth: 1)
                    }
                    .accessibilityLabel("Live stress reading")
            }
        }
        .frame(minHeight: 48)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            AtriaStressGauge(score: input.score,
                             label: input.state.label,
                             tint: input.tint,
                             reduceMotion: reduceMotion)
                .frame(height: 190)

            if !input.state.detail.isEmpty {
                Text(input.state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    @ViewBuilder
    private var timelineCard: some View {
        let points = timelinePoints
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Timeline")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Spacer()

                if let rangeText {
                    Text(rangeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if points.count >= 2 {
                AtriaStressTimelineChart(points: points,
                                         tint: input.tint,
                                         tintKey: input.state.level?.rawValue ?? -1)
                    .equatable()
                    .frame(height: 142)
                    .accessibilityLabel("Stress timeline with \(points.count) measured readings")
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(input.tint)
                    Text(input.readings.isEmpty
                         ? "Timeline starts with the first live reading."
                         : "Learning your pattern.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 22, emphasis: .strong)
    }

    private var interventionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(interventionTitle)
                .font(.headline.weight(.bold))

            HStack(spacing: 10) {
                Button(action: onRelax) {
                    Label("Relax", systemImage: "wind")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: true, tint: input.tint)
                .controlSize(.large)
                .accessibilityHint("Starts a calming breathwork session")

                if let onEnergize {
                    Button(action: onEnergize) {
                        Label("Energize", systemImage: "bolt.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(prominent: false, tint: input.tint)
                    .controlSize(.large)
                    .accessibilityHint("Starts an energizing breathwork session")
                }
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 22, emphasis: .strong)
    }

    private var loggedContextCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logged context")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            ForEach(input.loggedContext) { context in
                HStack(spacing: 10) {
                    Image(systemName: context.systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(input.tint)
                        .frame(width: 28, height: 28)
                        .background(input.tint.opacity(0.12), in: Circle())
                    Text(context.label)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Journal context can explain patterns, but it does not prove what caused a stress reading.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(cornerRadius: 22, emphasis: .strong)
    }

    private var updateText: String {
        guard let updatedAt = input.updatedAt else {
            return input.state.kind == .scored ? "Live" : input.state.label
        }
        return "Updated \(updatedAt.formatted(.relative(presentation: .named)))"
    }

    private var rangeText: String? {
        guard let first = input.readings.first?.date,
              let last = input.readings.last?.date else { return nil }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(first.formatted(date: .omitted, time: .shortened))–\(last.formatted(date: .omitted, time: .shortened))"
        }
        return "Session"
    }

    private var interventionTitle: String {
        switch input.state.level {
        case .high: return "Bring it down"
        case .medium: return "Reset"
        case .low, .calm: return "Guided session"
        case nil: return "Guided session"
        }
    }

    private var heroAccessibilityLabel: String {
        if let score = input.score {
            return "Stress \(score.formatted(.number.precision(.fractionLength(1)))) out of 3, \(input.state.label)"
        }
        return "Stress, \(input.state.label)"
    }

    private var timelinePoints: [AtriaStressTimelinePoint] {
        AtriaStressTimelinePoint.segment(input.readings)
    }
}

private struct AtriaStressGauge: View {
    let score: Double?
    let label: String
    let tint: Color
    let reduceMotion: Bool

    private let arcStart = 0.12
    private let arcSpan = 0.76

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .trim(from: arcStart, to: arcStart + arcSpan)
                    .stroke(.secondary.opacity(0.16),
                            style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(90))

                if let score {
                    Circle()
                        .trim(from: arcStart,
                              to: arcStart + arcSpan * min(max(score / 3, 0), 1))
                        .stroke(tint.gradient,
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(90))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: score)
                }

                VStack(spacing: 2) {
                    Text(scoreText)
                        .font(.system(size: 43, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)

            HStack {
                Text("Calm")
                Spacer()
                Text("Medium")
                Spacer()
                Text("High")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 286)
        }
    }

    private var scoreText: String {
        score?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }
}

private struct AtriaStressDistributionCard: View {
    let comparison: AtriaStressDistributionComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today vs typical")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if comparison.typical == nil {
                    Text("Learning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            distributionRow(label: "Today", distribution: comparison.today)

            if let typical = comparison.typical {
                distributionRow(label: "Typical", distribution: typical)
                HStack(spacing: 14) {
                    legend(color: .green, label: "Calm")
                    legend(color: .yellow, label: "Medium")
                    legend(color: .red, label: "High")
                }
            } else {
                Text("A typical bar appears after 3 comparable days with enough live readings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 22, emphasis: .strong)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func distributionRow(label: String,
                                 distribution: AtriaStressDistribution) -> some View {
        if let fractions = distribution.fractions {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Color.green.frame(width: proxy.size.width * fractions.calm)
                        Color.yellow.frame(width: proxy.size.width * fractions.medium)
                        Color.red.frame(width: proxy.size.width * fractions.high)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 18)
                .accessibilityLabel(distributionAccessibility(label: label,
                                                              fractions: fractions))
            }
        }
    }

    private func legend(color: Color, label: String) -> some View {
        Label {
            Text(label)
        } icon: {
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func distributionAccessibility(
        label: String,
        fractions: (calm: Double, medium: Double, high: Double)
    ) -> String {
        "\(label): \(Int((fractions.calm * 100).rounded())) percent calm, "
            + "\(Int((fractions.medium * 100).rounded())) percent medium, "
            + "\(Int((fractions.high * 100).rounded())) percent high"
    }
}

struct AtriaStressTimelinePoint: Identifiable, Equatable {
    let reading: AtriaStressDetailReading
    let segment: Int

    var id: TimeInterval { reading.id }

    /// Split readings around real gaps so Charts never draws data Atria did not
    /// observe. Kept internal for focused unit testing.
    static func segment(_ readings: [AtriaStressDetailReading],
                        gapThreshold: TimeInterval = 5 * 60) -> [AtriaStressTimelinePoint] {
        let sorted = readings.sorted { $0.date < $1.date }
        var segment = 0
        var previousDate: Date?
        return sorted.map { reading in
            if let previousDate,
               reading.date.timeIntervalSince(previousDate) > gapThreshold {
                segment += 1
            }
            previousDate = reading.date
            return AtriaStressTimelinePoint(reading: reading, segment: segment)
        }
    }
}

private struct AtriaStressTimelineChart: View, Equatable {
    let points: [AtriaStressTimelinePoint]
    let tint: Color
    let tintKey: Int

    static func == (lhs: AtriaStressTimelineChart, rhs: AtriaStressTimelineChart) -> Bool {
        lhs.points == rhs.points && lhs.tintKey == rhs.tintKey
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.reading.date),
                     y: .value("Stress", point.reading.score),
                     series: .value("Segment", point.segment))
                .interpolationMethod(.monotone)
                .foregroundStyle(tint.opacity(0.12))

            LineMark(x: .value("Time", point.reading.date),
                     y: .value("Stress", point.reading.score),
                     series: .value("Segment", point.segment))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(tint)
        }
        .chartYScale(domain: 0...3)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(.secondary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct AtriaStressLiveLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}
