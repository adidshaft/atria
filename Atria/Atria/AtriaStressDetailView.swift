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
    let elevatedEvidence: AtriaStressElevatedEvidence
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
        let sortedReadings = readings.sorted { $0.date < $1.date }
        self.readings = sortedReadings
        self.elevatedEvidence = AtriaStressElevatedEvidence.analyze(sortedReadings)
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

enum AtriaStressReadingFreshness: Equatable {
    case live
    case stale
    case untimed

    static let liveWindow: TimeInterval = 90
    static let futureTolerance: TimeInterval = 5

    static func resolve(isScored: Bool,
                        updatedAt: Date?,
                        now: Date = Date()) -> Self {
        guard isScored, let updatedAt else { return .untimed }
        let age = now.timeIntervalSince(updatedAt)
        guard age >= -futureTolerance, age <= liveWindow else { return .stale }
        return .live
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

struct AtriaStressElevatedWindow: Identifiable, Equatable {
    let start: Date
    let end: Date
    let readingCount: Int

    var id: TimeInterval { start.timeIntervalSinceReferenceDate }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Measured-only elevated-stress evidence for the visible timeline. Atria
/// integrates only adjacent readings with a plausible 30-second history
/// cadence; gaps, isolated peaks, and short sparse runs never become windows.
struct AtriaStressElevatedEvidence: Equatable {
    static let elevatedThresholdScore = AtriaStressMonitor.lowUpperBound * 3
    static let maximumReadingGap: TimeInterval = 90
    static let minimumWindowDuration: TimeInterval = 3 * 60
    static let minimumWindowReadings = 5
    static let minimumObservedDuration: TimeInterval = 10 * 60
    static let minimumTotalReadings = 12

    let windows: [AtriaStressElevatedWindow]
    let observedDuration: TimeInterval
    let readingCount: Int
    let isSupported: Bool
    let latestReadingAt: Date?

    static func analyze(_ readings: [AtriaStressDetailReading]) -> Self {
        let sorted = readings.sorted { $0.date < $1.date }
        var observedDuration: TimeInterval = 0
        if sorted.count > 1 {
            for index in 1..<sorted.count {
                let gap = sorted[index].date.timeIntervalSince(sorted[index - 1].date)
                if gap > 0, gap <= maximumReadingGap {
                    observedDuration += gap
                }
            }
        }

        let supported = sorted.count >= minimumTotalReadings
            && observedDuration >= minimumObservedDuration
        guard supported else {
            return Self(windows: [],
                        observedDuration: observedDuration,
                        readingCount: sorted.count,
                        isSupported: false,
                        latestReadingAt: sorted.last?.date)
        }

        var windows: [AtriaStressElevatedWindow] = []
        var windowStart: Date?
        var windowEnd: Date?
        var windowReadings = 0
        var previous: AtriaStressDetailReading?

        func appendWindow() {
            guard let start = windowStart,
                  let end = windowEnd,
                  windowReadings >= minimumWindowReadings,
                  end.timeIntervalSince(start) >= minimumWindowDuration else { return }
            windows.append(AtriaStressElevatedWindow(start: start,
                                                     end: end,
                                                     readingCount: windowReadings))
        }

        for reading in sorted {
            let elevated = reading.score >= elevatedThresholdScore
            let continuesWindow = previous.map {
                let gap = reading.date.timeIntervalSince($0.date)
                return $0.score >= elevatedThresholdScore
                    && elevated
                    && gap > 0
                    && gap <= maximumReadingGap
            } ?? false

            if elevated {
                if continuesWindow {
                    windowEnd = reading.date
                    windowReadings += 1
                } else {
                    appendWindow()
                    windowStart = reading.date
                    windowEnd = reading.date
                    windowReadings = 1
                }
            } else {
                appendWindow()
                windowStart = nil
                windowEnd = nil
                windowReadings = 0
            }
            previous = reading
        }
        appendWindow()

        return Self(windows: windows,
                    observedDuration: observedDuration,
                    readingCount: sorted.count,
                    isSupported: true,
                    latestReadingAt: sorted.last?.date)
    }

    var countText: String? {
        guard isSupported else { return nil }
        switch windows.count {
        case 0: return "No elevated windows"
        case 1: return "1 elevated window"
        default: return "\(windows.count) elevated windows"
        }
    }

    func interventionDetail(state: AtriaStressState,
                            updatedAt: Date?) -> String? {
        guard isSupported,
              state.kind == .scored,
              let level = state.level,
              level.rawValue >= AtriaStressLevel.medium.rawValue,
              let updatedAt,
              let latestReadingAt,
              abs(updatedAt.timeIntervalSince(latestReadingAt)) <= Self.maximumReadingGap,
              let active = windows.last,
              active.end == latestReadingAt,
              !state.detail.isEmpty else { return nil }
        let minutes = max(1, Int((active.duration / 60).rounded(.down)))
        return "\(minutes) min elevated · \(state.detail)"
    }
}

enum AtriaStressDetailCopy {
    static let relaxButtonTitle = "Relax · 3 min"
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

            if stressFreshness == .live {
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

                if let timelineStatusText {
                    Text(timelineStatusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if points.count >= 2 {
                AtriaStressTimelineChart(points: points,
                                         elevatedWindows: input.elevatedEvidence.windows,
                                         tint: input.tint,
                                         tintKey: input.state.level?.rawValue ?? -1)
                    .equatable()
                    .frame(height: 142)
                    .accessibilityLabel(timelineAccessibilityLabel(points: points))
                    .atriaInspectableGraph(
                        AtriaInspectableGraph(
                            title: "Stress timeline",
                            subtitle: "Observed readings only; blanks are collection gaps",
                            content: .timeSeries([
                                .init(title: "Stress",
                                      unit: "",
                                      tint: input.tint,
                                      points: points.map {
                                          .init(date: $0.reading.date,
                                                value: $0.reading.score,
                                                segment: $0.segment)
                                      })
                            ])
                        )
                    )
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

            if let interventionEvidenceText {
                Text(interventionEvidenceText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: onRelax) {
                    Label(AtriaStressDetailCopy.relaxButtonTitle, systemImage: "wind")
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
        switch stressFreshness {
        case .live:
            return "Live"
        case .stale:
            guard let updatedAt = input.updatedAt else { return "Last reading" }
            return "Last reading \(updatedAt.formatted(.relative(presentation: .named)))"
        case .untimed:
            return input.state.kind == .scored ? "Current reading · time unavailable" : input.state.label
        }
    }

    private var stressFreshness: AtriaStressReadingFreshness {
        AtriaStressReadingFreshness.resolve(
            isScored: input.state.kind == .scored,
            updatedAt: input.updatedAt
        )
    }

    private var rangeText: String? {
        guard let first = input.readings.first?.date,
              let last = input.readings.last?.date else { return nil }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(first.formatted(date: .omitted, time: .shortened))–\(last.formatted(date: .omitted, time: .shortened))"
        }
        return "Session"
    }

    private var timelineStatusText: String? {
        input.elevatedEvidence.countText ?? rangeText
    }

    private var interventionEvidenceText: String? {
        input.elevatedEvidence.interventionDetail(state: input.state,
                                                   updatedAt: input.updatedAt)
    }

    private func timelineAccessibilityLabel(points: [AtriaStressTimelinePoint]) -> String {
        let base = "Stress timeline with \(points.count) measured readings"
        guard let countText = input.elevatedEvidence.countText else { return base }
        return "\(base), \(countText.lowercased())"
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
    let elevatedWindows: [AtriaStressElevatedWindow]
    let tint: Color
    let tintKey: Int

    static func == (lhs: AtriaStressTimelineChart, rhs: AtriaStressTimelineChart) -> Bool {
        lhs.points == rhs.points
            && lhs.elevatedWindows == rhs.elevatedWindows
            && lhs.tintKey == rhs.tintKey
    }

    var body: some View {
        Chart {
            ForEach(elevatedWindows) { window in
                RectangleMark(xStart: .value("Elevated start", window.start),
                              xEnd: .value("Elevated end", window.end),
                              yStart: .value("Stress floor", 0),
                              yEnd: .value("Stress ceiling", 3))
                    .foregroundStyle(Color.orange.opacity(0.10))
            }

            ForEach(points) { point in
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
