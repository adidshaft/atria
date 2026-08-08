import Charts
import SwiftUI

/// One measured stress reading for the detail timeline.
///
/// `score` uses Atria's live 0...3 scale. Callers should only create readings
/// from values the stress monitor actually emitted; the detail view never
/// fills gaps or manufactures a baseline.
struct AtriaStressDetailReading: Identifiable, Equatable {
    let date: Date
    /// The evidence coordinate this reading belongs to. Cardiac-arousal points
    /// remain queryable but are never plotted on the numeric Stress timeline.
    let evidenceMode: AtriaStressEvidenceMode
    let score: Double
    /// Persisted/inferred qualitative band. Cardiac arousal is always capped at
    /// Medium, including an exact activation at the numeric High boundary.
    let level: AtriaStressLevel

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }

    init(date: Date,
         score: Double,
         evidenceMode: AtriaStressEvidenceMode = .physiologicalStress,
         level: AtriaStressLevel? = nil) {
        self.date = date
        self.evidenceMode = evidenceMode
        let boundedScore = score.isFinite
            ? min(max(score, 0), AtriaStressEvidenceProjection.maximumDisplayValue)
            : 0
        self.score = boundedScore
        let projection = AtriaStressEvidenceProjection(
            activation: boundedScore / AtriaStressEvidenceProjection.maximumDisplayValue,
            mode: evidenceMode
        )
        let proposedLevel = level ?? projection.qualitativeLevel
        self.level = evidenceMode == .cardiacArousal && proposedLevel == .high
            ? .medium
            : proposedLevel
    }

    init(historyPoint: AtriaStressMonitorStore.StressHistoryPoint) {
        let projection = historyPoint.evidenceProjection
        self.init(date: historyPoint.t,
                  score: projection.displayValue,
                  evidenceMode: projection.mode,
                  level: historyPoint.level)
    }
}

/// The detailed chart is intentionally a 24-hour recent-observation surface,
/// even though Activity retains two days so yesterday can be browsed. Frame the
/// input before elevated-window analysis so its count and overlays describe the
/// same readings the chart can actually display.
enum AtriaStressDetailHistoryWindow {
    static func framed(
        _ readings: [AtriaStressDetailReading],
        maximumDuration: TimeInterval = AtriaStressTimelineWindow.expandedDefault
    ) -> [AtriaStressDetailReading] {
        let sorted = readings.sorted { $0.date < $1.date }
        guard let end = sorted.last?.date else { return [] }
        let start = end.addingTimeInterval(-maximumDuration)
        return sorted.filter { $0.date >= start && $0.date <= end }
    }
}

/// Immutable input for `AtriaStressDetailView`.
///
/// Keeping this as a value makes the detail screen cheap to update across both
/// live and locally restored `AtriaStressMonitorStore` readings.
struct AtriaStressDetailInput: Equatable {
    let state: AtriaStressState
    let readings: [AtriaStressDetailReading]
    let elevatedEvidence: AtriaStressElevatedEvidence
    /// Time the current state was actually evaluated. Nil is rendered honestly
    /// as an untimed state rather than being replaced with `Date()`.
    let updatedAt: Date?
    let distributionComparison: AtriaStressDistributionComparison?
    /// Measured days from the persisted distribution archive, for the daily
    /// stress trend (§3.3). Only days that cleared the archive's per-day sample
    /// floor arrive here; the card additionally hides below 3 such days.
    let trendDays: [AtriaStressDistributionArchive.Day]
    /// Explicitly logged context for the current day. These are displayed as
    /// context—not inferred causes—because daily journal tags have no timestamp
    /// precise enough to attribute a stress peak.
    let loggedContext: [AtriaStressLoggedContext]

    init(state: AtriaStressState,
         readings: [AtriaStressDetailReading],
         updatedAt: Date?,
         distributionComparison: AtriaStressDistributionComparison? = nil,
         trendDays: [AtriaStressDistributionArchive.Day] = [],
         loggedContext: [AtriaStressLoggedContext] = []) {
        self.state = state
        let framedReadings = AtriaStressDetailHistoryWindow.framed(readings)
        self.readings = framedReadings
        self.elevatedEvidence = AtriaStressElevatedEvidence.analyze(framedReadings)
        self.updatedAt = updatedAt
        self.distributionComparison = distributionComparison
        self.trendDays = trendDays
        self.loggedContext = loggedContext
    }

    init(state: AtriaStressState,
         history: [AtriaStressMonitorStore.StressHistoryPoint],
         updatedAt: Date?,
         distributionComparison: AtriaStressDistributionComparison? = nil,
         trendDays: [AtriaStressDistributionArchive.Day] = [],
         loggedContext: [AtriaStressLoggedContext] = []) {
        self.init(state: state,
                  readings: history.map(AtriaStressDetailReading.init(historyPoint:)),
                  updatedAt: updatedAt,
                  distributionComparison: distributionComparison,
                  trendDays: trendDays,
                  loggedContext: loggedContext)
    }

    var presentation: AtriaStressPresentation {
        AtriaStressPresentation.make(state: state)
    }

    /// Numeric 0...3 Stress is present only for qualified HR+HRV evidence.
    /// HR-only cardiac arousal deliberately returns nil rather than occupying a
    /// capped portion of the Stress scale.
    var score: Double? {
        presentation.numericScore
    }

    var tint: Color {
        state.level?.tint ?? Metrics.electricStress
    }
}

enum AtriaStressReadingFreshness: Equatable {
    case live
    case stale
    case previousPhysiologicalCycle
    case untimed

    static let liveWindow: TimeInterval = 90
    static let futureTolerance: TimeInterval = 5

    static func resolve(isScored: Bool,
                        updatedAt: Date?,
                        physiologicalCycleStart: Date? = nil,
                        now: Date = Date()) -> Self {
        guard isScored, let updatedAt else { return .untimed }
        if let physiologicalCycleStart,
           updatedAt < physiologicalCycleStart {
            return .previousPhysiologicalCycle
        }
        let age = now.timeIntervalSince(updatedAt)
        guard age >= -futureTolerance, age <= liveWindow else { return .stale }
        return .live
    }

    /// The compact projection needs one wake-up at the first boundary that can
    /// invalidate a scored value: either its normal age lease or the next
    /// deterministic physiological-day rollover. This is deliberately pure so
    /// scheduling never becomes a second definition of freshness.
    static func expirationDeadline(
        updatedAt: Date?,
        nextPhysiologicalCycleStart: Date?
    ) -> Date? {
        guard let updatedAt else { return nil }
        let ageDeadline = updatedAt.addingTimeInterval(liveWindow)
        guard let nextPhysiologicalCycleStart else { return ageDeadline }
        return min(ageDeadline, nextPhysiologicalCycleStart)
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
    static let elevatedThresholdScore = AtriaStressEvidenceProjection.mediumStartsAt
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
        let sorted = readings
            .filter { $0.evidenceMode == .physiologicalStress }
            .sorted { $0.date < $1.date }
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
              state.evidenceMode == .physiologicalStress,
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
    @State private var freshnessNow = Date()
    // Knowledge slice 5 (2026-08-01): the ⓘ presents the richer spec §20
    // "About Stress" education sheet directly, self-contained. `onInfo` is kept
    // for source compatibility with existing call sites.
    @State private var showAbout = false

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
                    AtriaStressDailyTrendCard(days: input.trendDays)
                    if !input.loggedContext.isEmpty {
                        loggedContextCard
                    }
                    interventionCard
                }
                // 12pt gutter (2026-08-05 width audit): match the app-wide
                // screen gutter so the timeline and trend charts gain 12pt.
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.primary)
        .task(id: input.updatedAt) {
            freshnessNow = Date()
            guard input.state.kind == .scored,
                  let updatedAt = input.updatedAt else { return }
            let expiresAt = updatedAt.addingTimeInterval(
                AtriaStressReadingFreshness.liveWindow
            )
            let delay = expiresAt.timeIntervalSince(freshnessNow)
            guard delay > 0 else { return }
            let nanoseconds = UInt64(
                min(delay + 0.05, 24 * 60 * 60) * 1_000_000_000
            )
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            // One invalidation at the actual expiry boundary is enough; avoid
            // a per-second timer invalidating the entire chart hierarchy.
            freshnessNow = Date()
        }
        .sheet(isPresented: $showAbout) {
            AtriaAboutMetricSheet(metric: .stress)
        }
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
            .accessibilityLabel("Close \(input.presentation.metricTitle)")

            VStack(alignment: .leading, spacing: 1) {
                Text(input.presentation.metricTitle)
                    .font(.headline.weight(.bold))
                Text(updateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button { showAbout = true } label: {
                Image(systemName: "info.circle")
                    .frame(width: 40, height: 40)
            }
            .atriaGlassIconAction(tint: .primary, size: 40)
            .accessibilityLabel("About Stress")

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
                    .accessibilityLabel("Live \(input.presentation.metricTitle.lowercased()) reading")
            }
        }
        .frame(minHeight: 48)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            AtriaStressGauge(score: input.score,
                             label: input.state.label,
                             evidenceMode: input.presentation.evidenceMode,
                             tint: input.tint,
                             reduceMotion: reduceMotion)
                .frame(height: 190)

            if !input.presentation.detail.isEmpty {
                Text(input.presentation.detail)
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
        let projection = timelineProjection
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(projection.presentation.title)
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

            switch projection.presentation {
            case .physiologicalStress where projection.stressPoints.count >= 2:
                AtriaStressTimelineChart(
                    points: projection.stressPoints,
                    elevatedWindows: input.elevatedEvidence.windows,
                    tint: input.tint,
                    tintKey: input.state.level?.rawValue ?? -1
                )
                .equatable()
                .frame(height: 142)
                .accessibilityLabel(timelineAccessibilityLabel(points: projection.stressPoints))
                .atriaInspectableGraph(
                    AtriaInspectableGraph(
                        title: "Stress timeline",
                        subtitle: "Observed HR + HRV readings only; blanks are collection gaps",
                        content: .timeSeries([
                            .init(title: "Stress",
                                  unit: "",
                                  tint: input.tint,
                                  points: projection.stressPoints.map {
                                      .init(date: $0.reading.date,
                                            value: $0.reading.score,
                                            segment: $0.segment)
                                  })
                        ])
                    )
                )
                // Full-bleed plot inside the card (2026-08-05 width audit).
                .padding(.horizontal, -16)

            case .cardiacArousal:
                AtriaCardiacArousalTimelineChart(points: projection.cardiacArousalPoints)
                    .equatable()
                    .frame(height: 142)
                    .padding(.horizontal, -16)
                Text("HR only · qualitative Calm / Low / Medium bands · no 0–3 Stress score or High claim")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .physiologicalStress, .empty:
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(input.tint)
                    Text(timelineEmptyText)
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
        case .previousPhysiologicalCycle:
            return "Last reading · previous cycle"
        case .untimed:
            return input.state.kind == .scored ? "Current reading · time unavailable" : input.state.label
        }
    }

    private var stressFreshness: AtriaStressReadingFreshness {
        AtriaStressReadingFreshness.resolve(
            isScored: input.state.kind == .scored,
            updatedAt: input.updatedAt,
            now: freshnessNow
        )
    }

    private var rangeText: String? {
        let displayedReadings = timelineProjection.displayedReadings
        guard let first = displayedReadings.first?.date,
              let last = displayedReadings.last?.date else { return nil }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(first.formatted(date: .omitted, time: .shortened))–\(last.formatted(date: .omitted, time: .shortened))"
        }
        return "\(first.formatted(date: .abbreviated, time: .omitted))–\(last.formatted(date: .abbreviated, time: .omitted))"
    }

    private var timelineStatusText: String? {
        timelineProjection.presentation == .physiologicalStress
            ? (input.elevatedEvidence.countText ?? rangeText)
            : rangeText
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
        if input.presentation.evidenceMode == .cardiacArousal {
            return "Check the context"
        }
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
        if input.presentation.evidenceMode == .cardiacArousal {
            return "Cardiac arousal, \(input.state.label), qualitative heart-rate evidence; no numeric Stress score"
        }
        return "Stress, \(input.state.label)"
    }

    private var timelineEmptyText: String {
        switch timelineProjection.presentation {
        case .physiologicalStress:
            return "A second measured HR + HRV reading will begin the Stress line."
        case .cardiacArousal:
            return "Cardiac arousal is shown as qualitative HR-only bands."
        case .empty:
            return "Timeline starts with the first measured HR + HRV or HR-only reading."
        }
    }

    private var timelineProjection: AtriaStressTimelineEvidenceProjection {
        AtriaStressTimelineEvidenceProjection.make(readings: input.readings)
    }
}

private struct AtriaStressGauge: View {
    let score: Double?
    let label: String
    let evidenceMode: AtriaStressEvidenceMode?
    let tint: Color
    let reduceMotion: Bool

    private let arcStart = 0.12
    private let arcSpan = 0.76

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if evidenceMode == .cardiacArousal {
                    Circle()
                        .fill(tint.opacity(0.10))
                    Circle()
                        .stroke(tint.opacity(0.24), lineWidth: 1)
                } else {
                    Circle()
                        .trim(from: arcStart, to: arcStart + arcSpan)
                        .stroke(.secondary.opacity(0.16),
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(90))
                }

                if let score {
                    Circle()
                        .trim(from: arcStart,
                              to: arcStart + arcSpan * min(max(
                                score / AtriaStressEvidenceProjection.maximumDisplayValue,
                                0
                              ), 1))
                        .stroke(tint.gradient,
                                style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(90))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: score)
                }

                if evidenceMode == .cardiacArousal {
                    VStack(spacing: 5) {
                        Image(systemName: "heart.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(tint)
                        Text(label)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("HR only")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 2) {
                        Text(scoreText)
                            .font(.system(size: 43, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 170, height: 170)

            if evidenceMode == .cardiacArousal {
                Text("Qualitative cardiac-arousal evidence · no numeric Stress score")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 286)
            } else {
                Text(Self.thresholdSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(maxWidth: 286)
            }
        }
    }

    private var scoreText: String {
        score?.formatted(.number.precision(.fractionLength(1))) ?? "--"
    }

    private static var thresholdSummary: String {
        String(format: "Low %.2f · Medium %.2f · High %.2f",
               AtriaStressEvidenceProjection.lowStartsAt,
               AtriaStressEvidenceProjection.mediumStartsAt,
               AtriaStressEvidenceProjection.highStartsAt)
    }
}

/// Daily stress trend (§3.3): one stacked bar per MEASURED day — the share of
/// measured physiological-Stress samples spent Calm + Low / Medium / High,
/// from the same persisted
/// distribution archive the "Today vs typical" card reads. Honesty: a bar only
/// claims measured time (never wall-clock coverage); days without enough
/// samples simply have no bar; under 3 measured days the card shows a building
/// state instead of a plot. Internal (not private) + self-contained so a render
/// test can compose it directly.
struct AtriaStressDailyTrendCard: View {
    let days: [AtriaStressDistributionArchive.Day]
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    private static let frameDays = 7
    private static let minimumMeasuredDays = 3
    @State private var weekOffset = 0

    private var frameEnd: Date {
        let today = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day,
                            value: -(weekOffset * Self.frameDays),
                            to: today) ?? today
    }

    private var frameStart: Date {
        calendar.date(byAdding: .day,
                      value: -(Self.frameDays - 1),
                      to: frameEnd) ?? frameEnd
    }

    private var canNavigateToPreviousWeek: Bool {
        days.contains { calendar.startOfDay(for: $0.day) < frameStart }
    }

    /// Measured days clipped to the fixed frame, oldest first.
    private var framedDays: [AtriaStressDistributionArchive.Day] {
        return days
            .filter {
                let day = calendar.startOfDay(for: $0.day)
                return day >= frameStart && day <= frameEnd
            }
            .sorted { $0.day < $1.day }
    }

    private var xDomain: ClosedRange<Date> {
        let lo = calendar.date(byAdding: .hour, value: -12, to: frameStart) ?? frameStart
        let hi = calendar.date(byAdding: .hour, value: 12, to: frameEnd) ?? frameEnd
        return lo...hi
    }

    var body: some View {
        let framed = framedDays
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stress by day")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard canNavigateToPreviousWeek else { return }
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                        weekOffset += 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canNavigateToPreviousWeek)
                .accessibilityLabel("Previous stress week")

                Text(weekOffset == 0 ? "This week" : "\(weekOffset) week\(weekOffset == 1 ? "" : "s") ago")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    guard weekOffset > 0 else { return }
                    withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) {
                        weekOffset -= 1
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(weekOffset == 0)
                .accessibilityLabel("Next stress week")
            }

            if framed.count >= Self.minimumMeasuredDays {
                // Full-bleed plot inside the card (2026-08-05 width audit).
                chart(framed)
                    .padding(.horizontal, -16)
                HStack(spacing: 14) {
                    legend(color: .green, label: "Calm + Low")
                    legend(color: .yellow, label: "Medium")
                    legend(color: .red, label: "High")
                }
                Text("Share of measured time per day. Days without enough measured readings stay blank.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Building stress history — \(framed.count) of \(Self.minimumMeasuredDays) measured days so far. A day counts once it has enough measured readings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 22, emphasis: .strong)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(framed))
    }

    private func chart(_ framed: [AtriaStressDistributionArchive.Day]) -> some View {
        Chart {
            ForEach(framed, id: \.day) { day in
                if let fractions = day.distribution.fractions {
                    BarMark(x: .value("Day", calendar.startOfDay(for: day.day), unit: .day),
                            y: .value("Calm + Low", fractions.calm))
                        .foregroundStyle(.green)
                    BarMark(x: .value("Day", calendar.startOfDay(for: day.day), unit: .day),
                            y: .value("Medium", fractions.medium))
                        .foregroundStyle(.yellow)
                    BarMark(x: .value("Day", calendar.startOfDay(for: day.day), unit: .day),
                            y: .value("High", fractions.high))
                        .foregroundStyle(.red)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel(format: .dateTime.day(), centered: true)
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }
        }
        // No y-axis: every stacked bar sums to exactly 1 by construction
        // (fractions of measured time), so a scale would label a constant.
        // The caption carries the unit instead.
        .chartYAxis(.hidden)
        .frame(height: 120)
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

    private func accessibilitySummary(_ framed: [AtriaStressDistributionArchive.Day]) -> String {
        guard framed.count >= Self.minimumMeasuredDays else {
            return "Stress by day: building history, \(framed.count) of \(Self.minimumMeasuredDays) measured days."
        }
        return "Stress by day: \(framed.count) measured days in the selected week."
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
                    legend(color: .green, label: "Calm + Low")
                    legend(color: .yellow, label: "Medium")
                    legend(color: .red, label: "High")
                }
            } else {
                Text("A typical bar appears after 3 comparable days with enough measured readings.")
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
        "\(label): \(Int((fractions.calm * 100).rounded())) percent calm or low, "
            + "\(Int((fractions.medium * 100).rounded())) percent medium, "
            + "\(Int((fractions.high * 100).rounded())) percent high"
    }
}

/// Shared visible-window constants + clamp for the stress timeline charts
/// (2026-08-08 user request). The inline "Live monitor" chart defaults to the
/// last 12h and pinches IN to 4h; the expanded detail defaults to the last 24h
/// and pinches IN to 4h. Kept separate from the HR `Window` enum so a 4h stop
/// never leaks into the shared HR slider/pinch.
enum AtriaStressTimelineWindow {
    static let minWindow: TimeInterval = 4 * 3600
    static let inlineDefault: TimeInterval = 12 * 3600
    static let expandedDefault: TimeInterval = 24 * 3600

    /// Clamp a pinch-adjusted window to [minWindow, maxWindow].
    static func clamp(_ seconds: TimeInterval, maxWindow: TimeInterval) -> TimeInterval {
        min(max(seconds, minWindow), maxWindow)
    }
}

struct AtriaStressTimelinePoint: Identifiable, Equatable {
    let reading: AtriaStressDetailReading
    let segment: Int

    var id: TimeInterval { reading.id }

    /// Split readings around real gaps so Charts never draws data Atria did not
    /// observe. HR-only cardiac arousal is retained by the source collection but
    /// omitted from this numeric Stress projection; every omitted sample breaks
    /// the line so two Stress points are never connected across another metric.
    /// Kept internal for focused unit testing.
    static func segment(_ readings: [AtriaStressDetailReading],
                        gapThreshold: TimeInterval = 5 * 60) -> [AtriaStressTimelinePoint] {
        let sorted = readings.sorted { $0.date < $1.date }
        var segment = 0
        var previousStressDate: Date?
        var omittedEvidenceSincePreviousStress = false
        var output: [AtriaStressTimelinePoint] = []
        output.reserveCapacity(sorted.count)

        for reading in sorted {
            guard reading.evidenceMode == .physiologicalStress else {
                if previousStressDate != nil {
                    omittedEvidenceSincePreviousStress = true
                }
                continue
            }

            if let previousStressDate,
               omittedEvidenceSincePreviousStress
                    || reading.date.timeIntervalSince(previousStressDate) > gapThreshold {
                segment += 1
            }

            output.append(AtriaStressTimelinePoint(reading: reading,
                                                   segment: segment))
            previousStressDate = reading.date
            omittedEvidenceSincePreviousStress = false
        }
        return output
    }
}

/// A qualitative HR-only cardiac-arousal observation. Its vertical coordinate
/// is a category (Calm / Low / Medium), never a numeric Stress score; High is
/// structurally impossible in this projection.
struct AtriaCardiacArousalTimelinePoint: Identifiable, Equatable {
    let reading: AtriaStressDetailReading
    let segment: Int

    var id: TimeInterval { reading.id }
    var level: AtriaStressLevel {
        reading.level.rawValue > AtriaStressLevel.medium.rawValue
            ? .medium
            : reading.level
    }

    static func segment(_ readings: [AtriaStressDetailReading],
                        gapThreshold: TimeInterval = 5 * 60) -> [Self] {
        let sorted = readings.sorted { $0.date < $1.date }
        var segment = 0
        var previousArousalDate: Date?
        var omittedEvidenceSincePreviousArousal = false
        var output: [Self] = []
        output.reserveCapacity(sorted.count)

        for reading in sorted {
            guard reading.evidenceMode == .cardiacArousal else {
                if previousArousalDate != nil {
                    omittedEvidenceSincePreviousArousal = true
                }
                continue
            }
            if let previousArousalDate,
               omittedEvidenceSincePreviousArousal
                    || reading.date.timeIntervalSince(previousArousalDate) > gapThreshold {
                segment += 1
            }
            output.append(Self(reading: reading, segment: segment))
            previousArousalDate = reading.date
            omittedEvidenceSincePreviousArousal = false
        }
        return output
    }
}

enum AtriaStressTimelineEvidencePresentation: Equatable {
    case physiologicalStress
    case cardiacArousal
    case empty

    var title: String {
        switch self {
        case .physiologicalStress: return "Stress timeline"
        case .cardiacArousal: return "Cardiac arousal"
        case .empty: return "Timeline"
        }
    }
}

/// Pure selection contract for the expanded history card. Numeric Stress wins
/// when any qualified HR+HRV point exists. If none exists, retained HR-only
/// evidence becomes a useful qualitative cardiac-arousal timeline instead of a
/// blank or a fabricated 0...3 Stress trace.
struct AtriaStressTimelineEvidenceProjection: Equatable {
    let stressPoints: [AtriaStressTimelinePoint]
    let cardiacArousalPoints: [AtriaCardiacArousalTimelinePoint]

    static func make(readings: [AtriaStressDetailReading]) -> Self {
        Self(stressPoints: AtriaStressTimelinePoint.segment(readings),
             cardiacArousalPoints: AtriaCardiacArousalTimelinePoint.segment(readings))
    }

    var presentation: AtriaStressTimelineEvidencePresentation {
        if !stressPoints.isEmpty { return .physiologicalStress }
        if !cardiacArousalPoints.isEmpty { return .cardiacArousal }
        return .empty
    }

    var displayedReadings: [AtriaStressDetailReading] {
        switch presentation {
        case .physiologicalStress: return stressPoints.map(\.reading)
        case .cardiacArousal: return cardiacArousalPoints.map(\.reading)
        case .empty: return []
        }
    }
}

private struct AtriaStressTimelineChart: View, Equatable {
    let points: [AtriaStressTimelinePoint]
    let elevatedWindows: [AtriaStressElevatedWindow]
    let tint: Color
    let tintKey: Int

    // Visible window (2026-08-08 user request): the expanded detail defaults to
    // the last 24h and pinches IN to 4h. Anchored to the latest reading so it
    // ends at the most recent data, with honest blanks where the strap was off.
    @State private var visibleSeconds: TimeInterval = AtriaStressTimelineWindow.expandedDefault
    // @GestureState (not @State): auto-resets to nil on pinch end *or cancel*
    // (e.g. the surrounding ScrollView claims the two-finger touch), so a
    // stale start-window can't snap the zoom back on the next pinch.
    @GestureState private var pinchBase: TimeInterval? = nil

    private var xDomain: ClosedRange<Date> {
        let last = points.map(\.reading.date).max() ?? Date()
        return last.addingTimeInterval(-visibleSeconds)...last
    }

    // visibleSeconds/pinchBase are internal view state, not inputs, so they
    // are intentionally excluded from equality.
    static func == (lhs: AtriaStressTimelineChart, rhs: AtriaStressTimelineChart) -> Bool {
        lhs.points == rhs.points
            && lhs.elevatedWindows == rhs.elevatedWindows
            && lhs.tintKey == rhs.tintKey
    }

    var body: some View {
        Chart {
            ForEach(Self.thresholdRules, id: \.value) { threshold in
                RuleMark(y: .value(threshold.label, threshold.value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.24))
            }

            ForEach(elevatedWindows) { window in
                RectangleMark(xStart: .value("Elevated start", window.start),
                              xEnd: .value("Elevated end", window.end),
                              yStart: .value("Stress floor", 0),
                              yEnd: .value("Stress ceiling",
                                           AtriaStressEvidenceProjection.maximumDisplayValue))
                    .foregroundStyle(Color.orange.opacity(0.10))
            }

            ForEach(points) { point in
                AreaMark(x: .value("Time", point.reading.date),
                         y: .value("Stress", point.reading.score),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(tint.opacity(0.12))

                LineMark(x: .value("Time", point.reading.date),
                         y: .value("Stress", point.reading.score),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5,
                                           lineCap: .round,
                                           lineJoin: .round))
                    // The fixed 0–3 gradient communicates increasing intensity;
                    // dashed rules, not integer ticks or color changes, mark the
                    // exact band boundaries.
                    .foregroundStyle(.linearGradient(colors: [.blue, .green, .orange],
                                                      startPoint: .bottom,
                                                      endPoint: .top))
            }
        }
        .chartYScale(domain: 0...AtriaStressEvidenceProjection.maximumDisplayValue)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(values: [0, 1, 2, 3]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let score = value.as(Double.self) {
                        Text(score == 0 ? "0" : String(format: "%.0f", score))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
        .gesture(
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
                        maxWindow: AtriaStressTimelineWindow.expandedDefault)
                }
        )
        .accessibilityLabel(Self.timelineAccessibilityLabel)
    }

    private static let thresholdRules: [(label: String, value: Double)] = [
        ("Low starts", AtriaStressEvidenceProjection.lowStartsAt),
        ("Medium starts", AtriaStressEvidenceProjection.mediumStartsAt),
        ("High starts", AtriaStressEvidenceProjection.highStartsAt),
    ]

    private static var timelineAccessibilityLabel: String {
        String(format: "Stress timeline, scale 0 through 3. Low starts at %.2f, Medium at %.2f, and High at %.2f. Pinch to zoom between 24 and 4 hours.",
               AtriaStressEvidenceProjection.lowStartsAt,
               AtriaStressEvidenceProjection.mediumStartsAt,
               AtriaStressEvidenceProjection.highStartsAt)
    }
}

struct AtriaCardiacArousalTimelineChart: View, Equatable {
    let points: [AtriaCardiacArousalTimelinePoint]
    let referenceDate: Date?
    let window: TimeInterval

    init(points: [AtriaCardiacArousalTimelinePoint],
         referenceDate: Date? = nil,
         window: TimeInterval = AtriaStressTimelineWindow.expandedDefault) {
        self.points = points
        self.referenceDate = referenceDate
        self.window = window
    }

    private var xDomain: ClosedRange<Date> {
        let end = referenceDate ?? points.map(\.reading.date).max() ?? Date()
        return end.addingTimeInterval(-window)...end
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.reading.date),
                         y: .value("Cardiac arousal band", point.level.rawValue),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.stepCenter)
                    .lineStyle(StrokeStyle(lineWidth: 1.25,
                                           lineCap: .round,
                                           lineJoin: .round,
                                           dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.56))

                PointMark(x: .value("Time", point.reading.date),
                          y: .value("Cardiac arousal band", point.level.rawValue))
                    .symbolSize(18)
                    .foregroundStyle(point.level.tint)
            }
        }
        .chartYScale(domain: -0.25...2.25)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(values: [0, 1, 2]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let rawValue = value.as(Int.self),
                       let level = AtriaStressLevel(rawValue: rawValue) {
                        Text(level.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let levels = Set(points.map(\.level.title)).sorted().joined(separator: ", ")
        return "Cardiac arousal timeline with \(points.count) HR-only readings. Qualitative bands shown: \(levels). No numeric Stress score or High claim."
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
