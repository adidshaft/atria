import Charts
import SwiftUI

/// One measured stress reading for the detail timeline.
///
/// `score` uses Atria's live 0...3 scale. Callers should only create readings
/// from values the stress monitor actually emitted; the detail view never
/// fills gaps or manufactures a baseline.
struct AtriaStressDetailReading: Identifiable, Equatable {
    let date: Date
    /// The evidence provenance this reading belongs to. Complete version-3
    /// HR-only estimates remain on the same numeric physiological-stress line.
    let evidenceMode: AtriaStressEvidenceMode
    let score: Double
    /// Persisted/inferred qualitative band on the v3 Calm / Moderate / High
    /// scale.
    let level: AtriaStressLevel
    let heartRate: Double?
    let rmssd: Double?
    let motionContext: AtriaPhysiologicalStressModel.MotionContext
    let sleepContext: AtriaPhysiologicalStressModel.SleepContext
    let confidence: AtriaPhysiologicalStressModel.Confidence
    let baselineLearning: Bool

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }

    init(date: Date,
         score: Double,
         evidenceMode: AtriaStressEvidenceMode = .physiologicalStress,
         level: AtriaStressLevel? = nil,
         heartRate: Double? = nil,
         rmssd: Double? = nil,
         motionContext: AtriaPhysiologicalStressModel.MotionContext = .unavailable,
         sleepContext: AtriaPhysiologicalStressModel.SleepContext = .unavailable,
         confidence: AtriaPhysiologicalStressModel.Confidence = .low,
         baselineLearning: Bool = false) {
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
        self.level = level ?? projection.qualitativeLevel
        self.heartRate = heartRate
        self.rmssd = rmssd
        self.motionContext = motionContext
        self.sleepContext = sleepContext
        self.confidence = confidence
        self.baselineLearning = baselineLearning
    }

    init(historyPoint: AtriaStressMonitorStore.StressHistoryPoint) {
        let projection = historyPoint.evidenceProjection
        self.init(date: historyPoint.t,
                  score: projection.displayValue,
                  evidenceMode: projection.mode,
                  level: historyPoint.level,
                  heartRate: historyPoint.minuteFact?.meanHeartRate,
                  rmssd: historyPoint.minuteFact?.rmssd,
                  motionContext: historyPoint.minuteFact?.motionContext ?? .unavailable,
                  sleepContext: historyPoint.minuteFact?.sleepContext ?? .unavailable,
                  confidence: historyPoint.minuteFact?.confidence
                    ?? (historyPoint.hrvAvailable ? .medium : .low),
                  baselineLearning: historyPoint.minuteFact?.baselineLearning ?? false)
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
    let heartRateReadings: [AtriaStressMonitorStore.HeartRateHistoryPoint]
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
         heartRateReadings: [AtriaStressMonitorStore.HeartRateHistoryPoint] = [],
         updatedAt: Date?,
         distributionComparison: AtriaStressDistributionComparison? = nil,
         trendDays: [AtriaStressDistributionArchive.Day] = [],
         loggedContext: [AtriaStressLoggedContext] = []) {
        self.state = state
        let framedReadings = AtriaStressDetailHistoryWindow.framed(readings)
        self.readings = framedReadings
        let heartRateEnd = heartRateReadings.map(\.t).max()
        self.heartRateReadings = heartRateReadings
            .filter {
                guard let heartRateEnd else { return false }
                return $0.t >= heartRateEnd.addingTimeInterval(
                    -AtriaStressTimelineWindow.expandedDefault
                ) && $0.t <= heartRateEnd
            }
            .sorted { $0.t < $1.t }
        self.elevatedEvidence = AtriaStressElevatedEvidence.analyze(framedReadings)
        self.updatedAt = updatedAt
        self.distributionComparison = distributionComparison
        self.trendDays = trendDays
        self.loggedContext = loggedContext
    }

    init(state: AtriaStressState,
         history: [AtriaStressMonitorStore.StressHistoryPoint],
         heartRateHistory: [AtriaStressMonitorStore.HeartRateHistoryPoint] = [],
         updatedAt: Date?,
         distributionComparison: AtriaStressDistributionComparison? = nil,
         trendDays: [AtriaStressDistributionArchive.Day] = [],
         loggedContext: [AtriaStressLoggedContext] = []) {
        self.init(state: state,
                  readings: history.map(AtriaStressDetailReading.init(historyPoint:)),
                  heartRateReadings: heartRateHistory,
                  updatedAt: updatedAt,
                  distributionComparison: distributionComparison,
                  trendDays: trendDays,
                  loggedContext: loggedContext)
    }

    var presentation: AtriaStressPresentation {
        AtriaStressPresentation.make(state: state)
    }

    /// Continuous 0...3 physiological-stress estimate. HR-only readings remain
    /// numeric but are explicitly labeled lower-confidence in the model fact.
    var score: Double? {
        presentation.numericScore
    }

    var tint: Color {
        state.level?.tint ?? Metrics.electricStress
    }
}

enum AtriaStressAccessibilityCopy {
    static func heroLabel(state: AtriaStressState, score: Double?) -> String {
        guard let score else {
            return "Physiological stress, \(state.label)"
        }
        // Version 3 deliberately keeps HR-only estimates in the same
        // `.physiologicalStress` presentation mode. Provenance must therefore
        // come from the canonical minute fact, never the presentation enum.
        let provenance = state.minuteFact?.isHROnly == true
            ? ", HR-only estimate, lower confidence"
            : ""
        return "Physiological stress \(score.formatted(.number.precision(.fractionLength(1)))) out of 3, \(state.label)\(provenance)"
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

/// A bounded run of consecutive minute facts that share one context kind
/// (asleep, or qualified activity). Coalescing contiguous facts into a single
/// interval replaces the per-minute ±30 s "barcode" — one narrow rectangle per
/// reading — with one continuous band, without ever bridging a real telemetry
/// gap or a context change. A run breaks on a non-member reading, on a gap
/// longer than the shared continuity threshold, or at the end of the series.
struct AtriaStressContextInterval: Identifiable, Equatable {
    let start: Date
    let end: Date
    let readingCount: Int

    var id: TimeInterval { start.timeIntervalSinceReferenceDate }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    static func intervals(
        from readings: [AtriaStressDetailReading],
        gapThreshold: TimeInterval = AtriaPhysiologicalStressModel.maximumFactContinuityGap,
        minimumWidth: TimeInterval = 60,
        isMember: (AtriaStressDetailReading) -> Bool
    ) -> [AtriaStressContextInterval] {
        let sorted = readings.sorted { $0.date < $1.date }
        var intervals: [AtriaStressContextInterval] = []
        var start: Date?
        var end: Date?
        var count = 0
        var previousMemberDate: Date?

        func flush() {
            guard let start, let end, count > 0 else { return }
            // A lone or very short run still needs a visible width equal to one
            // minute fact's own coverage; this is bounded and never bridges the
            // gap to the next reading (a gap longer than the threshold already
            // closed the run).
            let boundedEnd = max(end, start.addingTimeInterval(minimumWidth))
            intervals.append(AtriaStressContextInterval(start: start,
                                                        end: boundedEnd,
                                                        readingCount: count))
        }

        for reading in sorted {
            if isMember(reading) {
                let continuesRun = start != nil && (previousMemberDate.map {
                    let gap = reading.date.timeIntervalSince($0)
                    return gap > 0 && gap <= gapThreshold
                } ?? false)
                if continuesRun {
                    end = reading.date
                    count += 1
                } else {
                    flush()
                    start = reading.date
                    end = reading.date
                    count = 1
                }
                previousMemberDate = reading.date
            } else {
                flush()
                start = nil
                end = nil
                count = 0
                previousMemberDate = nil
            }
        }
        flush()
        return intervals
    }
}

/// Pure visual classification for one rendered stress minute (2026-08-20):
/// a minute whose stored fact carries `sleepContext == .asleep` renders as a
/// dedicated Sleep band (`Metrics.electricSleep`) instead of a Calm / Moderate
/// / High zone color, because sleeping REM heart-rate rises are not waking
/// stress. Presentation only — the score is never altered or hidden, so every
/// score-derived aggregate (elevated windows, zone medians, distribution
/// fractions) keeps counting these minutes.
enum AtriaStressMinuteBand: Equatable {
    case sleep
    case zone(AtriaPhysiologicalStressModel.Zone)

    static func resolve(sleepContext: AtriaPhysiologicalStressModel.SleepContext,
                        score: Double) -> Self {
        sleepContext == .asleep
            ? .sleep
            : .zone(.resolve(score: score))
    }

    static func resolve(_ reading: AtriaStressDetailReading) -> Self {
        resolve(sleepContext: reading.sleepContext, score: reading.score)
    }

    /// The word beside the score in the drag-inspection cards, and what
    /// accessibility reads for the inspected minute.
    var displayName: String {
        switch self {
        case .sleep: return "Sleep"
        case .zone(let zone): return zone.rawValue
        }
    }

    var tint: Color {
        switch self {
        case .sleep: return Metrics.electricSleep
        case .zone(.calm): return Metrics.electricGreen
        case .zone(.moderate): return Metrics.electricYellow
        case .zone(.high): return Metrics.electricRed
        }
    }

    /// Shared inspection copy: "1.40 · Moderate", "2.37 · Sleep". The numeric
    /// score always renders — sleep changes the classification word, never the
    /// value.
    static func scoreLine(_ reading: AtriaStressDetailReading) -> String {
        scoreLine(score: reading.score,
                  isAsleep: reading.sleepContext == .asleep)
    }

    /// Same line for surfaces that carry only the recorded score and confirmed
    /// sleep membership (Activity's day-chart scrub card). The zone word is
    /// resolved from the score by the one shared authority; a confirmed-sleep
    /// minute says "Sleep", never a zone word.
    static func scoreLine(score: Double, isAsleep: Bool) -> String {
        let band: AtriaStressMinuteBand = isAsleep
            ? .sleep
            : .zone(.resolve(score: score))
        return "\(score.formatted(.number.precision(.fractionLength(2)))) · \(band.displayName)"
    }

    /// Legend gating: a Sleep legend entry belongs on a stress timeline only
    /// while at least one rendered minute actually is confirmed sleep.
    static func containsSleepMinutes(_ readings: [AtriaStressDetailReading]) -> Bool {
        readings.contains { $0.sleepContext == .asleep }
    }

    /// Appended to a timeline's accessibility label only when a Sleep band is
    /// actually rendered — mirroring the visible legend gating.
    static let accessibilityDisclosure =
        "Confirmed sleep is shaded as a Sleep band, not a stress zone."
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
        // Dedupe (2026-08-20): provenance renders once, in the hero detail line.
        return "\(minutes) min elevated"
    }
}

enum AtriaStressDetailCopy {
    static let relaxButtonTitle = "Relax · 3 min"
}

enum AtriaStressTimelineMetric: String, CaseIterable, Identifiable {
    case stress = "Stress"
    case heartRate = "Heart rate"

    var id: String { rawValue }
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
    @State private var selectedTimelineMetric: AtriaStressTimelineMetric = .stress
    // Knowledge slice 5 (2026-08-01): the ⓘ presents the richer spec §20
    // "About physiological stress" education sheet directly, self-contained. `onInfo` is kept
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
                if let updateText {
                    Text(updateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button { showAbout = true } label: {
                Image(systemName: "info.circle")
                    .frame(width: 40, height: 40)
            }
            .atriaGlassIconAction(tint: .primary, size: 40)
            .accessibilityLabel("About physiological stress")

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

            if projection.stressPoints.count >= 2 {
                Picker("Timeline metric", selection: $selectedTimelineMetric) {
                    ForEach(AtriaStressTimelineMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Switches between physiological stress and measured heart rate")
            }

            switch projection.presentation {
            case .physiologicalStress where projection.stressPoints.count >= 2:
                Group {
                    if selectedTimelineMetric == .stress {
                        AtriaStressTimelineChart(
                            points: projection.stressPoints,
                            elevatedWindows: input.elevatedEvidence.windows,
                            tint: input.tint,
                            tintKey: input.state.level?.rawValue ?? -1
                        )
                        // Declutter batch 3 (2026-08-20, plan D8): 184 → 230
                        // after the batch-1 copy dedupes freed the space.
                        .frame(height: 230)
                        .accessibilityLabel(timelineAccessibilityLabel(points: projection.stressPoints))
                        .atriaInspectableGraph(
                            AtriaInspectableGraph(
                                title: "Physiological stress timeline",
                                subtitle: "Five-minute estimates each minute; HR-only points are lower confidence and blanks are telemetry gaps",
                                content: .timeSeries([
                                    .init(title: "Physiological stress",
                                          unit: "",
                                          tint: input.tint,
                                          points: projection.stressPoints.map {
                                              .init(date: $0.reading.date,
                                                    value: $0.reading.score,
                                                    segment: $0.segment)
                                          })
                                ], domain: nil)
                            )
                        )
                    } else if !input.heartRateReadings.isEmpty {
                        AtriaStressHeartRateTimelineChart(points: input.heartRateReadings)
                            // Matches the stress variant above so the card
                            // does not jump when the picker toggles.
                            .frame(height: 230)
                            .accessibilityLabel("Measured heart rate timeline; blanks are telemetry gaps")
                    } else {
                        Text("Measured minute heart rate will appear here as live observations arrive.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                    }
                }
                // Full-bleed plot inside the card (2026-08-05 width audit).
                .padding(.horizontal, -16)

                // The Sleep legend appears only while sleep minutes are
                // actually in the rendered window — a permanent entry would
                // advertise a band most days never draw.
                if selectedTimelineMetric == .stress,
                   AtriaStressMinuteBand.containsSleepMinutes(
                        projection.stressPoints.map(\.reading)
                   ) {
                    sleepBandLegend
                }

            case .cardiacArousal:
                Text("HR-only estimate · lower confidence")
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

    /// Legend for the confirmed-sleep band. Rendered only when the visible
    /// window actually contains sleep minutes (gated at the call site).
    private var sleepBandLegend: some View {
        Label {
            Text("Sleep · confirmed sleep")
        } icon: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Metrics.electricSleep.opacity(0.5))
                .frame(width: 14, height: 8)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel(AtriaStressMinuteBand.accessibilityDisclosure)
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

    private var updateText: String? {
        switch stressFreshness {
        case .live:
            // Dedupe (2026-08-20): the header's Live pill already announces it.
            return nil
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
        let base = "Physiological stress timeline with \(points.count) measured readings"
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
        AtriaStressAccessibilityCopy.heroLabel(state: input.state,
                                               score: input.score)
    }

    private var timelineEmptyText: String {
        switch timelineProjection.presentation {
        case .physiologicalStress:
            return "A second measured reading will begin the physiological stress line."
        case .cardiacArousal:
            return "A second HR-only estimate will begin the physiological stress line."
        case .empty:
            return "Timeline starts with the first complete five-minute estimate."
        }
    }

    private var timelineProjection: AtriaStressTimelineEvidenceProjection {
        AtriaStressTimelineEvidenceProjection.make(readings: input.readings)
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
                              to: arcStart + arcSpan * min(max(
                                score / AtriaStressEvidenceProjection.maximumDisplayValue,
                                0
                              ), 1))
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

            // Dedupe (2026-08-20): HR-only provenance renders once, in the
            // hero detail line below the gauge (and in heroAccessibilityLabel).
            Text(Self.thresholdSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(maxWidth: 286)
        }
    }

    private var scoreText: String {
        score?.formatted(.number.precision(.fractionLength(1))) ?? "--"
    }

    private static var thresholdSummary: String {
        "Calm 0–1 · Moderate 1–2 · High 2–3"
    }
}

/// Daily stress trend (§3.3): one stacked bar per MEASURED day — the share of
/// measured physiological-stress samples spent Calm / Moderate / High,
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

    /// A day-unit BarMark fills [day, day+24h), so the domain must end at the
    /// last framed day's following midnight. The old +12h stopped at its noon
    /// and the plot surface clipped away the right half of that bar, while the
    /// leading -12h was dead margin no bar could occupy. Same
    /// [first 00:00, last 24:00) rule the steps week chart uses.
    ///
    /// Deliberately NOT swept to the strain/recovery combo chart: that one
    /// draws LineMark/PointMark, where a point sits ON its date, so its
    /// symmetric ±12h inset is correct and removing it would clip the marks.
    private var xDomain: ClosedRange<Date> {
        let hi = calendar.date(byAdding: .day, value: 1, to: frameEnd) ?? frameEnd
        return frameStart...hi
    }

    /// Every day in the frame, measured or not. `AxisValueLabel(centered:)`
    /// centres a label in the step to the NEXT mark, not within the bar's unit,
    /// so marks have to be exactly one day apart. The old `.stride(count: 3)`
    /// made the step three days and pushed each label a day and a half right —
    /// landing it dead centre over the following day's bar.
    private var axisDays: [Date] {
        var days: [Date] = []
        var cursor = frameStart
        while cursor <= frameEnd {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
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
                    legend(color: .green, label: "Calm")
                    legend(color: .yellow, label: "Moderate")
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
                            y: .value("Calm", fractions.calm))
                        .foregroundStyle(.green)
                    BarMark(x: .value("Day", calendar.startOfDay(for: day.day), unit: .day),
                            y: .value("Moderate", fractions.medium))
                        .foregroundStyle(.yellow)
                    BarMark(x: .value("Day", calendar.startOfDay(for: day.day), unit: .day),
                            y: .value("High", fractions.high))
                        .foregroundStyle(.red)
                }
            }
        }
        .atriaGraphPlotSurface()
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: axisDays) { _ in
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
        // Declutter batch 3 (2026-08-20, plan D8): 120 → 150.
        .frame(height: 150)
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
                    legend(color: .green, label: "Calm")
                    legend(color: .yellow, label: "Moderate")
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
        "\(label): \(Int((fractions.calm * 100).rounded())) percent calm, "
            + "\(Int((fractions.medium * 100).rounded())) percent moderate, "
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
    /// observe. HR-only estimates stay on the same continuous scale with their
    /// lower-confidence provenance; they are never moved into categorical rows.
    /// Kept internal for focused unit testing.
    static func segment(_ readings: [AtriaStressDetailReading],
                        gapThreshold: TimeInterval = AtriaPhysiologicalStressModel.maximumFactContinuityGap) -> [AtriaStressTimelinePoint] {
        let sorted = readings.sorted { $0.date < $1.date }
        var segment = 0
        var previousStressDate: Date?
        var output: [AtriaStressTimelinePoint] = []
        output.reserveCapacity(sorted.count)

        for reading in sorted {
            if let previousStressDate,
               reading.date.timeIntervalSince(previousStressDate) > gapThreshold {
                segment += 1
            }

            output.append(AtriaStressTimelinePoint(reading: reading,
                                                   segment: segment))
            previousStressDate = reading.date
        }
        return output
    }
}

/// Compatibility projection for consumers that still request HR-only points.
/// Rendering remains continuous on Atria's 0...3 physiological-stress scale.
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
                        gapThreshold: TimeInterval = AtriaPhysiologicalStressModel.maximumFactContinuityGap) -> [Self] {
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

    // Dedupe (2026-08-20): the screen header already reads "Physiological
    // stress"; every state reuses the neutral `.empty` caption.
    var title: String { "Timeline" }
}

/// Pure selection contract for the expanded history card. Every model-emitted
/// reading occupies the same continuous 0...3 coordinate; HR-only provenance
/// remains attached for confidence and inspection copy. The cardiac-arousal
/// array is retained only for legacy compatibility and is not a second chart.
struct AtriaStressTimelineEvidenceProjection: Equatable {
    let stressPoints: [AtriaStressTimelinePoint]
    let cardiacArousalPoints: [AtriaCardiacArousalTimelinePoint]

    static func make(readings: [AtriaStressDetailReading]) -> Self {
        // Ambient / live stress card (Health + Vitals): brief signal hiccups
        // (≤5 min) read as one smooth run, while a genuine dropout still breaks
        // and stays blank — the same display-continuity policy every rendered
        // stress trace now follows. The stricter fact-continuity gap (the
        // `segment` default) is reserved for coverage accounting, not display.
        Self(stressPoints: AtriaStressTimelinePoint.segment(
                readings,
                gapThreshold: AtriaChartVisualGrammar.traceDisplayContinuityGap),
             cardiacArousalPoints: AtriaCardiacArousalTimelinePoint.segment(
                readings,
                gapThreshold: AtriaChartVisualGrammar.traceDisplayContinuityGap))
    }

    var presentation: AtriaStressTimelineEvidencePresentation {
        if !stressPoints.isEmpty { return .physiologicalStress }
        return .empty
    }

    var displayedReadings: [AtriaStressDetailReading] {
        switch presentation {
        case .physiologicalStress: return stressPoints.map(\.reading)
        case .cardiacArousal: return stressPoints.map(\.reading)
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
    @State private var selectedDate: Date?

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
            RectangleMark(xStart: .value("Calm start", xDomain.lowerBound),
                          xEnd: .value("Calm end", xDomain.upperBound),
                          yStart: .value("Calm floor", 0),
                          yEnd: .value("Calm ceiling", 1))
                .foregroundStyle(Metrics.electricGreen.opacity(0.055))
            RectangleMark(xStart: .value("Moderate start", xDomain.lowerBound),
                          xEnd: .value("Moderate end", xDomain.upperBound),
                          yStart: .value("Moderate floor", 1),
                          yEnd: .value("Moderate ceiling", 2))
                .foregroundStyle(Metrics.electricYellow.opacity(0.045))
            RectangleMark(xStart: .value("High start", xDomain.lowerBound),
                          xEnd: .value("High end", xDomain.upperBound),
                          yStart: .value("High floor", 2),
                          yEnd: .value("High ceiling", 3))
                .foregroundStyle(Metrics.electricRed.opacity(0.045))

            RuleMark(y: .value("Calm to moderate", 1))
                .lineStyle(StrokeStyle(lineWidth: 0.75))
                .foregroundStyle(.secondary.opacity(0.18))
            RuleMark(y: .value("Moderate to high", 2))
                .lineStyle(StrokeStyle(lineWidth: 0.75))
                .foregroundStyle(.secondary.opacity(0.18))

            ForEach(AtriaStressContextInterval.intervals(from: points.map(\.reading)) {
                $0.sleepContext == .asleep
            }) { interval in
                RectangleMark(
                    xStart: .value("Sleep start", interval.start),
                    xEnd: .value("Sleep end", interval.end),
                    yStart: .value("Sleep floor", 0),
                    yEnd: .value("Sleep ceiling", 3)
                )
                // The dedicated Sleep tint, not a stress zone color — these
                // minutes are confirmed sleep, and their sleeping HR rises are
                // not waking stress (2026-08-20).
                .foregroundStyle(Metrics.electricSleep.opacity(0.14))
            }

            ForEach(AtriaStressContextInterval.intervals(from: points.map(\.reading)) {
                $0.motionContext.qualified && $0.motionContext.kind == .activity
            }) { interval in
                RectangleMark(
                    xStart: .value("Activity start", interval.start),
                    xEnd: .value("Activity end", interval.end),
                    yStart: .value("Activity floor", 0),
                    yEnd: .value("Activity ceiling", 3)
                )
                .foregroundStyle(Color.orange.opacity(0.075))
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
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [
                            Metrics.electricGreen.opacity(0.04),
                            Metrics.electricYellow.opacity(0.10),
                            Metrics.electricRed.opacity(0.16),
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    ))

                LineMark(x: .value("Time", point.reading.date),
                         y: .value("Stress", point.reading.score),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.traceLine)
                    .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen,
                                                               Metrics.electricYellow,
                                                               Metrics.electricRed],
                                                      startPoint: .bottom,
                                                      endPoint: .top))
            }

            if let selectedPoint {
                RuleMark(x: .value("Inspected time", selectedPoint.reading.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.primary.opacity(0.28))
                PointMark(x: .value("Inspected time", selectedPoint.reading.date),
                          y: .value("Inspected stress", selectedPoint.reading.score))
                    .symbolSize(42)
                    .foregroundStyle(.primary)
                    .annotation(position: .top,
                                alignment: .center,
                                overflowResolution: .init(x: .fit(to: .chart),
                                                          y: .disabled)) {
                        inspectionCard(selectedPoint.reading)
                    }
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
        .simultaneousGesture(
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geometry[plotFrame]
                                let x = value.location.x - frame.origin.x
                                guard x >= 0, x <= frame.width,
                                      let date: Date = proxy.value(atX: x) else { return }
                                selectedDate = nearestPoint(to: date)?.reading.date
                            }
                    )
            }
        }
        .accessibilityLabel(Self.timelineAccessibilityLabel(
            containsSleep: AtriaStressMinuteBand.containsSleepMinutes(points.map(\.reading))
        ))
        .accessibilityHint("Drag across the chart to inspect time, score, heart rate, HRV, motion context, and confidence")
    }

    private var selectedPoint: AtriaStressTimelinePoint? {
        selectedDate.flatMap(nearestPoint(to:))
    }

    private func nearestPoint(to date: Date) -> AtriaStressTimelinePoint? {
        points.min {
            abs($0.reading.date.timeIntervalSince(date))
                < abs($1.reading.date.timeIntervalSince(date))
        }
    }

    @ViewBuilder
    private func inspectionCard(_ reading: AtriaStressDetailReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reading.date.formatted(date: .omitted, time: .shortened))
                .font(.caption2.weight(.semibold))
            // Confirmed-sleep minutes say "Sleep" here, never a zone word; the
            // numeric score stays visible either way.
            Text(AtriaStressMinuteBand.scoreLine(reading))
                .font(.caption.monospacedDigit().weight(.bold))
            Text(reading.heartRate.map { "HR \(Int($0.rounded())) bpm" } ?? "HR unavailable")
            Text(reading.rmssd.map { "RMSSD \($0.formatted(.number.precision(.fractionLength(1)))) ms" }
                ?? "HR-only estimate")
            Text("\(reading.motionContext.displayName) · \(reading.confidence.displayName) confidence")
            if reading.baselineLearning { Text("Personal baseline learning") }
        }
        .font(.caption2)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private static func timelineAccessibilityLabel(containsSleep: Bool) -> String {
        let base = "Physiological stress timeline, scale 0 through 3. Calm is 0 to 1, Moderate is 1 to 2, and High is 2 to 3. Gaps are not connected. Pinch to zoom between 24 and 4 hours."
        guard containsSleep else { return base }
        return "\(base) \(AtriaStressMinuteBand.accessibilityDisclosure)"
    }
}

private struct AtriaStressHeartRateTimelineChart: View {
    let points: [AtriaStressMonitorStore.HeartRateHistoryPoint]
    // Same drag-to-inspect grammar as the stress timeline beside it
    // (2026-08-29): time + measured bpm on the shared clamped card.
    @State private var selectedDate: Date?

    private var segmentedPoints: [(point: AtriaStressMonitorStore.HeartRateHistoryPoint,
                                   segment: Int)] {
        var segment = 0
        var previous: Date?
        return points.sorted { $0.t < $1.t }.map { point in
            if let previous,
               point.t.timeIntervalSince(previous)
                > AtriaChartVisualGrammar.traceDisplayContinuityGap {
                segment += 1
            }
            previous = point.t
            return (point, segment)
        }
    }

    private var xDomain: ClosedRange<Date> {
        let end = points.map(\.t).max() ?? Date()
        return end.addingTimeInterval(-AtriaStressTimelineWindow.expandedDefault)...end
    }

    var body: some View {
        Chart(segmentedPoints, id: \.point.id) { item in
            LineMark(x: .value("Time", item.point.t),
                     y: .value("Heart rate", item.point.bpm),
                     series: .value("Segment", item.segment))
                .interpolationMethod(.monotone)
                .lineStyle(AtriaChartVisualGrammar.traceLine)
                .foregroundStyle(Metrics.electricRed)
        }
        .chartXScale(domain: xDomain)
        .chartYAxisLabel("bpm")
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                AtriaChartScrubOverlay(proxy: proxy,
                                       geometry: geometry,
                                       points: points,
                                       date: { $0.t },
                                       value: { Double($0.bpm) },
                                       selectedDate: $selectedDate) { point in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.t.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.weight(.semibold))
                        Text("\(point.bpm) bpm")
                            .font(.caption.monospacedDigit().weight(.bold))
                    }
                    .atriaChartScrubCardChrome()
                }
            }
        }
        .accessibilityHint("Drag across the chart to inspect time and measured heart rate")
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
            RectangleMark(xStart: .value("Calm start", xDomain.lowerBound),
                          xEnd: .value("Calm end", xDomain.upperBound),
                          yStart: .value("Calm floor", 0),
                          yEnd: .value("Calm ceiling", 1))
                .foregroundStyle(Metrics.electricGreen.opacity(0.055))
            RectangleMark(xStart: .value("Moderate start", xDomain.lowerBound),
                          xEnd: .value("Moderate end", xDomain.upperBound),
                          yStart: .value("Moderate floor", 1),
                          yEnd: .value("Moderate ceiling", 2))
                .foregroundStyle(Metrics.electricYellow.opacity(0.045))
            RectangleMark(xStart: .value("High start", xDomain.lowerBound),
                          xEnd: .value("High end", xDomain.upperBound),
                          yStart: .value("High floor", 2),
                          yEnd: .value("High ceiling", 3))
                .foregroundStyle(Metrics.electricRed.opacity(0.045))

            ForEach(AtriaStressContextInterval.intervals(from: points.map(\.reading)) {
                $0.sleepContext == .asleep
            }) { interval in
                RectangleMark(
                    xStart: .value("Sleep start", interval.start),
                    xEnd: .value("Sleep end", interval.end),
                    yStart: .value("Sleep floor", 0),
                    yEnd: .value("Sleep ceiling", 3)
                )
                .foregroundStyle(Metrics.electricSleep.opacity(0.14))
            }

            ForEach(points) { point in
                LineMark(x: .value("Time", point.reading.date),
                         y: .value("Physiological stress", point.reading.score),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.traceLine)
                    .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen,
                                                               Metrics.electricYellow,
                                                               Metrics.electricRed],
                                                      startPoint: .bottom,
                                                      endPoint: .top))
            }
        }
        .chartYScale(domain: 0...3)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(values: [0, 1, 2, 3]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let score = value.as(Int.self) {
                        Text("\(score)")
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
        let base = "Physiological stress timeline with \(points.count) lower-confidence HR-only estimates on a zero through three scale. Missing telemetry remains a gap."
        guard AtriaStressMinuteBand.containsSleepMinutes(points.map(\.reading)) else {
            return base
        }
        return "\(base) \(AtriaStressMinuteBand.accessibilityDisclosure)"
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
