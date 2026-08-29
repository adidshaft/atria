import SwiftUI

// Sleep-stages hypnogram (design source: Claude Design "Atria App UI.dc.html",
// "SLEEP · FULL SCROLL" screen, "STAGES · HYPNOGRAM" card):
//   - four lanes top→bottom Awake / REM / Light / Deep, one 16pt lane per
//     stage with 5pt gaps and 40pt lane labels tinted in the stage's own hue
//   - segmented per-lane bars (radius 3) positioned on the real time axis
//   - axis row with the exact clock at both ends and sparse whole hours
//     between ("11:42p · 2a · 4a · 7:24a" — lowercase single-letter am/pm)
//   - one compact per-stage legend line under the graph ("· Deep 1h 34m";
//     2026-08-29 minimalism pass replaced the four tinted tiles — stage
//     color survives only in the dot and the plot ribbons, and the lane
//     labels read neutral)
// Stage hues from the design's stage table: Awake #FFB340, REM #64D2FF,
// Light #4C8DFF, Deep #7B6CF0 (the app's SWS band folds into Deep for
// display, as everywhere else).
//
// Honesty (hard constraint): motion-validated timelines render exactly as
// before. A confirmed `.hrOnlyEstimate` night whose stored timeline passed
// integrity now renders a display-only RECONCILED estimate timeline
// (2026-08-12, c7c15e1d product) — but only under the mandatory
// `AtriaSleepStageEstimateLabel` title + caption, visible with the bars.
// HR-only nights whose segments failed integrity/reconciliation still render
// the single generic estimated-asleep window plus measured HR context.

/// Pure segment→lane / legend / axis math, unit-testable without SwiftUI.
enum AtriaSleepHypnogramPresentation {
    /// Design lane order, top → bottom.
    static let lanes: [SleepStageKind] = [.awake, .rem, .light, .deep]

    struct Span: Equatable {
        let laneIndex: Int
        let stage: SleepStageKind
        let startFraction: Double
        let endFraction: Double
    }

    struct LegendEntry: Equatable {
        let stage: SleepStageKind
        /// Real minutes of this displayed stage — never re-derived from percent.
        let minutes: Int
        /// Largest-remainder share of classified time; entries sum to 100.
        let percent: Int
    }

    struct AxisTick: Equatable {
        let fraction: Double
        let label: String
    }

    static func laneIndex(for stage: SleepStageKind) -> Int {
        lanes.firstIndex(of: stage.displayStage) ?? lanes.count - 1
    }

    /// Segments clipped to the sleep window and normalized to 0...1 fractions
    /// of it. SWS folds into the Deep lane; zero-length or out-of-window
    /// segments drop out. Positions come from the segment's real wall-clock
    /// range — a late segment stays late even when earlier coverage is sparse.
    static func spans(for segments: [SleepStageSegment],
                      windowStart: Date,
                      windowEnd: Date) -> [Span] {
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        guard windowDuration > 0 else { return [] }
        return segments.compactMap { segment in
            let clippedStart = max(segment.start, windowStart)
            let clippedEnd = min(segment.end, windowEnd)
            guard clippedEnd > clippedStart else { return nil }
            let display = segment.stage.displayStage
            return Span(laneIndex: laneIndex(for: display),
                        stage: display,
                        startFraction: clippedStart.timeIntervalSince(windowStart) / windowDuration,
                        endFraction: clippedEnd.timeIntervalSince(windowStart) / windowDuration)
        }
    }

    /// Real minutes per displayed stage in design lane order, present stages
    /// only. Percent reuses the existing largest-remainder share allocation so
    /// this legend and the review sheet's distribution row can never disagree.
    static func legend(for segments: [SleepStageSegment]) -> [LegendEntry] {
        var durations: [SleepStageKind: TimeInterval] = [:]
        for segment in segments {
            durations[segment.stage.displayStage, default: 0] += max(0, segment.duration)
        }
        guard durations.values.reduce(0, +) > 0 else { return [] }
        let shares = AtriaSleepStagePresentation.shares(for: segments)
        return lanes.compactMap { stage in
            guard let duration = durations[stage], duration > 0 else { return nil }
            return LegendEntry(stage: stage,
                               minutes: Int((duration / 60).rounded()),
                               percent: shares.first(where: { $0.stage == stage })?.percent ?? 0)
        }
    }

    static func durationText(minutes: Int) -> String {
        SleepHistorySnapshot.formatDuration(TimeInterval(minutes) * 60)
    }

    /// Axis ticks for the real window: exact clock at both endpoints, then
    /// whole hours strictly inside it, kept clear of the endpoint labels and
    /// thinned to at most three so the row never crowds.
    static func axisTicks(windowStart: Date,
                          windowEnd: Date,
                          calendar: Calendar) -> [AxisTick] {
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        guard windowDuration > 0 else { return [] }
        var ticks: [AxisTick] = [AxisTick(fraction: 0,
                                          label: clockLabel(windowStart, calendar: calendar))]
        var interior: [AxisTick] = []
        var hour = nextWholeHour(after: windowStart, calendar: calendar)
        while let current = hour, current < windowEnd {
            let fraction = current.timeIntervalSince(windowStart) / windowDuration
            if fraction > endpointClearance, fraction < 1 - endpointClearance {
                interior.append(AxisTick(fraction: fraction,
                                         label: clockLabel(current, calendar: calendar)))
            }
            hour = calendar.date(byAdding: .hour, value: 1, to: current)
        }
        let stride = max(1, Int((Double(interior.count) / Double(maximumInteriorTicks)).rounded(.up)))
        for (index, tick) in interior.enumerated() where index % stride == 0 {
            ticks.append(tick)
        }
        ticks.append(AxisTick(fraction: 1,
                              label: clockLabel(windowEnd, calendar: calendar)))
        return ticks
    }

    /// Design axis clock: "11:42p" when minutes matter, "2a" on the whole hour.
    static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = components.hour ?? 0
        let minute = components.minute ?? 0
        let suffix = hour24 >= 12 ? "p" : "a"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        guard minute > 0 else { return "\(hour12)\(suffix)" }
        return "\(hour12):" + String(format: "%02d", minute) + suffix
    }

    private static let endpointClearance = 0.12
    private static let maximumInteriorTicks = 3

    // MARK: - Stepped timeline runs (2026-08-13 graph-system convergence)

    /// One drawn run of a display stage on the stepped timeline. Identity is
    /// derived from stage + real wall-clock bounds — never array offsets — so
    /// SwiftUI diffing stays stable while segments stream in.
    struct Run: Equatable, Identifiable {
        let stage: SleepStageKind
        let start: Date
        let end: Date
        /// True when a width-aware bucket collapsed more than one raw run
        /// into this mark. Display-only; legend totals never read runs.
        let isComposite: Bool

        var id: String {
            "\(stage.rawValue)-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))"
        }

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Exactly-adjacent same-stage spans merge losslessly (epoch outputs abut
    /// to the second); a real gap or stage change always starts a new run.
    private static let adjacencyTolerance: TimeInterval = 0.5

    /// Clip → fold (SWS→Deep) → lossless adjacent merge → width-aware
    /// display compositor. `composited` is true only when sub-pixel runs
    /// were collapsed, so callers can show a "Dense estimate" cue instead of
    /// pretending the trace became scientifically cleaner.
    static func timelineRuns(
        for segments: [SleepStageSegment],
        windowStart: Date,
        windowEnd: Date,
        maximumMarks: Int = 96
    ) -> (runs: [Run], composited: Bool) {
        guard windowEnd > windowStart else { return ([], false) }
        var merged: [Run] = []
        for segment in segments {
            let clippedStart = max(segment.start, windowStart)
            let clippedEnd = min(segment.end, windowEnd)
            guard clippedEnd > clippedStart else { continue }
            let display = segment.stage.displayStage
            if let last = merged.last,
               last.stage == display,
               clippedStart.timeIntervalSince(last.end) <= adjacencyTolerance,
               clippedStart >= last.start {
                merged[merged.count - 1] = Run(stage: display,
                                               start: last.start,
                                               end: max(last.end, clippedEnd),
                                               isComposite: last.isComposite)
            } else {
                merged.append(Run(stage: display,
                                  start: clippedStart,
                                  end: clippedEnd,
                                  isComposite: false))
            }
        }
        guard merged.count > maximumMarks, maximumMarks > 0 else {
            return (merged, false)
        }
        return (compositedRuns(merged,
                               windowStart: windowStart,
                               windowEnd: windowEnd,
                               maximumMarks: maximumMarks), true)
    }

    /// Pixel-bucket compositor: each bucket takes its DOMINANT stage by
    /// covered duration. First/last boundaries are preserved exactly, long
    /// runs survive by dominance, and adjacent equal-stage buckets re-merge,
    /// so the output count is bounded by `maximumMarks`.
    private static func compositedRuns(
        _ runs: [Run],
        windowStart: Date,
        windowEnd: Date,
        maximumMarks: Int
    ) -> [Run] {
        guard let firstRun = runs.first, let lastRun = runs.last else { return runs }
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        let bucketDuration = windowDuration / Double(maximumMarks)
        guard bucketDuration > 0 else { return runs }
        var buckets: [(stage: SleepStageKind, start: Date, end: Date, merged: Bool)] = []
        var runIndex = 0
        for bucket in 0..<maximumMarks {
            let bucketStart = windowStart.addingTimeInterval(Double(bucket) * bucketDuration)
            let bucketEnd = bucket == maximumMarks - 1
                ? windowEnd
                : windowStart.addingTimeInterval(Double(bucket + 1) * bucketDuration)
            var coverage: [SleepStageKind: TimeInterval] = [:]
            var contributors = 0
            var probe = runIndex
            while probe < runs.count, runs[probe].start < bucketEnd {
                let overlap = min(runs[probe].end, bucketEnd)
                    .timeIntervalSince(max(runs[probe].start, bucketStart))
                if overlap > 0 {
                    coverage[runs[probe].stage, default: 0] += overlap
                    contributors += 1
                }
                if runs[probe].end <= bucketEnd { probe += 1 } else { break }
            }
            runIndex = probe
            guard let dominant = coverage.max(by: {
                $0.value != $1.value ? $0.value < $1.value
                    : laneIndex(for: $0.key) > laneIndex(for: $1.key)
            })?.key else { continue }
            if let last = buckets.last, last.stage == dominant,
               abs(last.end.timeIntervalSince(bucketStart)) <= adjacencyTolerance {
                buckets[buckets.count - 1].end = bucketEnd
                buckets[buckets.count - 1].merged =
                    buckets[buckets.count - 1].merged || contributors > 1
            } else {
                buckets.append((dominant, bucketStart, bucketEnd, contributors > 1))
            }
        }
        guard !buckets.isEmpty else { return runs }
        // Endpoint truth: the first mark starts exactly where the first raw
        // run started, the last mark ends exactly where the last raw run
        // ended — a compositor may coarsen the middle, never the edges.
        buckets[0].start = firstRun.start
        buckets[buckets.count - 1].end = lastRun.end
        return buckets.map {
            Run(stage: $0.stage, start: $0.start, end: $0.end, isComposite: $0.merged)
        }
    }

    private static func nextWholeHour(after date: Date, calendar: Calendar) -> Date? {
        let truncated = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return truncated < date
            ? calendar.date(byAdding: .hour, value: 1, to: truncated)
            : truncated
    }
}

/// The one shared stage-color token (2026-08-20 palette consolidation): the
/// design file's stage table — Awake #FFB340, REM #64D2FF, Light #4C8DFF,
/// Deep #7B6CF0 — with the app's SWS band folding into Deep exactly like
/// every other display surface. Any stage-derived pixels (hypnogram lanes,
/// review-sheet distribution bars, Vitals chips) draw from here so a chip
/// can never disagree with the plot beside it.
enum AtriaSleepStagePalette {
    static func color(for stage: SleepStageKind) -> Color {
        switch stage.displayStage {
        case .awake: return Color(red: 1.0, green: 0.702, blue: 0.251)      // #FFB340
        case .rem: return Color(red: 0.392, green: 0.824, blue: 1.0)        // #64D2FF
        case .light: return Color(red: 0.298, green: 0.553, blue: 1.0)      // #4C8DFF
        case .sws, .deep: return Color(red: 0.482, green: 0.424, blue: 0.941) // #7B6CF0
        }
    }
}

/// Shared hypnogram card for the sleep detail sheet and the History day sheet.
/// Fed by display segments + the real sleep window; axis, lanes, and legend
/// derive from data only.
struct AtriaSleepHypnogramCard: View, Equatable {
    enum DisplayState: Equatable {
        case timeline
        /// Confirmed HR-only night whose reconciled display segments earned
        /// a real timeline — rendered ONLY with the mandatory estimate
        /// label + caption (never with `.timeline`'s visual authority).
        case estimatedTimeline
        /// HR-only night rendered as one generic estimated-asleep window —
        /// the fail-closed state when no reconciled display segments exist.
        case estimate
        /// HR-only night without a usable time window.
        case needsMotion
        /// Hand-typed window: stages will never arrive without sensor data,
        /// so "building"/"calibrating" copy would be a false promise
        /// (2026-08-05 manual-sleep honesty audit).
        case manualEntry
        /// No usable segments/window at all.
        case building
    }

    let segments: [SleepStageSegment]
    let start: Date?
    let end: Date?
    let stageEvidence: SleepStageEvidence
    let provenanceText: String
    let eventTimeZoneIdentifier: String?
    let isManualEntry: Bool
    let measuredHeartRate: Int?
    /// ITEM-3 2026-08-15: optional strap motion state so the honest empty
    /// states can say what will unlock stages instead of only what is
    /// missing. nil keeps the generic (still honest) copy.
    let motionAvailability: AtriaStrapMotionAvailability?
    /// P8 (2026-08-20 design 2.1): the night's SAVED sleep total, powering the
    /// coarse sleep/wake totals on the generic estimate window. This is the
    /// same duration authority every other surface displays — never a new
    /// number, never stage-derived on estimate nights (the duration-credit
    /// fence is upstream and untouched). nil keeps the pre-P8 capsule.
    let sleepTotalSeconds: TimeInterval?
    /// P8: coarse totals render only for CONFIRMED nights — candidates keep
    /// the generic capsule so an unconfirmed window never gains total-style
    /// authority.
    let isConfirmedNight: Bool

    init(segments: [SleepStageSegment],
         start: Date?,
         end: Date?,
         stageEvidence: SleepStageEvidence,
         provenanceText: String,
         eventTimeZoneIdentifier: String? = nil,
         isManualEntry: Bool = false,
         measuredHeartRate: Int? = nil,
         motionAvailability: AtriaStrapMotionAvailability? = nil,
         sleepTotalSeconds: TimeInterval? = nil,
         isConfirmedNight: Bool = false) {
        // Truth boundary (updated 2026-08-12): `.hrOnlyEstimate` segments may
        // render, but only as the labeled estimate timeline — the body pairs
        // any bars for that evidence with `AtriaSleepStageEstimateLabel`.
        // The canonical night initializer below feeds the reconciled,
        // integrity-gated `displayStageSegments`, never raw engine output.
        self.segments = segments
        self.start = start
        self.end = end
        self.stageEvidence = stageEvidence
        self.provenanceText = provenanceText
        self.eventTimeZoneIdentifier = eventTimeZoneIdentifier
        self.isManualEntry = isManualEntry
        self.measuredHeartRate = measuredHeartRate
        self.motionAvailability = motionAvailability
        self.sleepTotalSeconds = sleepTotalSeconds
        self.isConfirmedNight = isConfirmedNight
    }

    /// The canonical feed: `displayStageSegments` is already honesty-gated
    /// (empty for `.hrOnlyEstimate`/`.none`), so this card can never render a
    /// stage lane that motion evidence does not back.
    init(night: SleepHistorySnapshot.Night,
         motionAvailability: AtriaStrapMotionAvailability? = nil) {
        // For withheld-stage states the honest body already names the state,
        // so the provenance line carries confirmation provenance only.
        let provenance: String
        let feedSegments: [SleepStageSegment]
        switch night.stageEvidence {
        case .hrOnlyEstimate:
            // Defense in depth: feed only the reconciled, integrity-gated
            // display segments — never raw HR-derived engine output. When
            // the night failed reconciliation these are empty and the card
            // draws its generic non-stage estimate window.
            provenance = "\(night.confirmationText) · Estimate"
            feedSegments = night.displayStageSegments
        case .none:
            provenance = night.confirmationText
            feedSegments = night.displayStageSegments
        default:
            provenance = "\(night.confirmationText) · \(night.stageEvidence.label)"
            feedSegments = night.displayStageSegments
        }
        self.init(segments: feedSegments,
                  start: night.start,
                  end: night.end,
                  stageEvidence: night.stageEvidence,
                  provenanceText: provenance,
                  eventTimeZoneIdentifier: night.eventTimeZoneIdentifier,
                  isManualEntry: night.isManualEntry,
                  measuredHeartRate: night.restingHR,
                  motionAvailability: motionAvailability,
                  sleepTotalSeconds: night.duration,
                  isConfirmedNight: night.confirmed)
    }

    static func displayState(segments: [SleepStageSegment],
                             stageEvidence: SleepStageEvidence,
                             start: Date?,
                             end: Date?,
                             isManualEntry: Bool = false) -> DisplayState {
        // Manual wins over the sensor states: a hand-typed window without
        // segments must say "manual entry", not promise motion or building.
        if isManualEntry, segments.isEmpty { return .manualEntry }
        if stageEvidence == .hrOnlyEstimate {
            // Reconciled display segments earn the labeled estimate timeline;
            // without them the presentation stays the generic window (or the
            // terminal needs-motion state when no window exists either).
            if !segments.isEmpty, let start, let end, end > start { return .estimatedTimeline }
            if let start, let end, end > start { return .estimate }
            return .needsMotion
        }
        guard !segments.isEmpty, let start, let end, end > start else { return .building }
        return .timeline
    }

    static func measuredHeartRateText(_ beatsPerMinute: Int?) -> String? {
        guard let beatsPerMinute, (20...300).contains(beatsPerMinute) else { return nil }
        return "Measured resting HR · \(beatsPerMinute) bpm"
    }

    /// Stage hues from the design file's stage table (dark-first palette).
    /// Delegates to the shared token so every stage surface keys one palette.
    static func color(for stage: SleepStageKind) -> Color {
        AtriaSleepStagePalette.color(for: stage)
    }

    private var state: DisplayState {
        Self.displayState(segments: segments,
                          stageEvidence: stageEvidence,
                          start: start,
                          end: end,
                          isManualEntry: isManualEntry)
    }

    private var eventCalendar: Calendar {
        EventCivilTime.eventCalendar(timeZoneIdentifier: eventTimeZoneIdentifier,
                                     fallback: .current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.sm) {
                Text(sectionTitle)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(provenanceText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            switch state {
            case .timeline:
                if let start, let end {
                    sharedTimeline(windowStart: start,
                                   windowEnd: end,
                                   isEstimate: false)
                    legendTiles
                }
            case .estimatedTimeline:
                // The estimate title is this card's section header (above);
                // the caption renders directly under the bars so the two are
                // never separated from the timeline they qualify.
                if let start, let end {
                    sharedTimeline(windowStart: start,
                                   windowEnd: end,
                                   isEstimate: true)
                    legendTiles
                    Text(AtriaSleepStageEstimateLabel.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // P8: the why line renders only under the mandatory
                    // estimate label above, and only when the transport
                    // evidence adds truth the caption doesn't already state.
                    if let whyLine = Self.timelineWhyEstimateLine(
                        motionAvailability: motionAvailability) {
                        Text(whyLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .estimate:
                if let start, let end {
                    estimatedAsleepWindow(windowStart: start, windowEnd: end)
                }
            case .needsMotion:
                honestState(title: "Stage analysis unavailable for this night",
                            detail: Self.unavailableStagesDetail(
                                base: Self.needsMotionBase,
                                motionAvailability: motionAvailability))
            case .manualEntry:
                honestState(title: "No stages — manual entry",
                            detail: Self.manualEntryDetail)
            case .building:
                honestState(title: "Stage analysis unavailable for this night",
                            detail: Self.unavailableStagesDetail(
                                base: Self.buildingBase,
                                motionAvailability: motionAvailability))
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// ITEM-3 2026-08-15: the unlock story for the honest empty states. Maps
    /// the strap motion transport to what will actually happen next — and
    /// never promises motion on a link that cannot deliver it (same doctrine
    /// as the truthful step copy). 2026-08-29 minimalism pass: each appended
    /// unlock clause compressed to one sentence; the per-transport honesty
    /// substrings pinned by AtriaSleepDetailLegibilityTests survive verbatim.
    /// 2026-08-29 minimalism pass: the two-sentence state bases collapse to
    /// one sentence each — the saved-duration honesty claim and the reason
    /// stay, the elaboration goes. Shared by the body and VoiceOver.
    static let needsMotionBase =
        "Your sleep duration is saved — heart rate alone cannot separate stages."
    static let buildingBase =
        "Your sleep duration is saved — hours asleep alone do not create a hypnogram."
    static let manualEntryDetail =
        "Entered by hand — stage timelines come only from sensor data; duration and overnight vitals are kept."

    static func unavailableStagesDetail(base: String,
                                        motionAvailability: AtriaStrapMotionAvailability?) -> String {
        switch motionAvailability {
        case .catchingUp:
            return base + " Stages validate after the strap syncs motion — catching up now."
        case .unavailableInCurrentTransport:
            return base + " This strap link is heart-rate-only, so Atria may show a labeled HR-only estimate instead."
        default:
            return base + " Stages validate after the strap syncs motion; without it Atria may show a labeled HR-only estimate."
        }
    }

    // MARK: - P8 coarse fallback + "why tonight is an estimate" (2026-08-20)

    /// Coarse sleep/wake accounting for a confirmed HR-only night whose stage
    /// output stays withheld (the sub-0.60 fallback). Both numbers come from
    /// the night's OBSERVED record only: asleep is the saved sleep total (the
    /// same duration authority every surface displays) and the second figure
    /// is the saved window's remainder — honestly labeled "awake or
    /// unmeasured" because HR alone cannot split real wake from coverage
    /// gaps. Never derived from stage segments; nothing is interpolated.
    struct CoarseNightTotals: Equatable {
        let asleepMinutes: Int
        let awakeOrUnmeasuredMinutes: Int
    }

    static let coarseAsleepTotalLabel = "Asleep"
    static let coarseAwakeTotalLabel = "Awake or unmeasured"

    static func coarseNightTotals(windowStart: Date,
                                  windowEnd: Date,
                                  sleepDuration: TimeInterval?) -> CoarseNightTotals? {
        guard let sleepDuration, sleepDuration > 0 else { return nil }
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return nil }
        // The saved total is displayed verbatim; only the remainder is
        // clamped so contradictory data fails toward the saved number
        // instead of minting negative wake time.
        return CoarseNightTotals(
            asleepMinutes: Int((sleepDuration / 60).rounded()),
            awakeOrUnmeasuredMinutes: Int((max(0, span - sleepDuration) / 60).rounded())
        )
    }

    /// Coarse-total text: a real zero reads "0m" — an honest amount, never
    /// the unknown "--" the shared formatter uses for missing data.
    static func coarseTotalText(minutes: Int) -> String {
        minutes > 0 ? AtriaSleepHypnogramPresentation.durationText(minutes: minutes) : "0m"
    }

    /// The "why tonight is an estimate" line (P8; research-brief §2 Oura
    /// pattern): one sentence naming the actual cause, keyed on the same
    /// strap-motion transport evidence as `unavailableStagesDetail` — never a
    /// promise the link cannot deliver.
    static func whyEstimateLine(motionAvailability: AtriaStrapMotionAvailability?) -> String {
        switch motionAvailability {
        case .catchingUp:
            return "Strap was in HR-only mode — motion data pending; a catch-up sync can still upgrade this night."
        case .unavailableInCurrentTransport:
            return "Strap was in HR-only mode — this link cannot sync motion right now, so this night stays an estimate."
        default:
            return "Motion evidence for this night hasn't synced, so Atria estimated from heart rate alone."
        }
    }

    /// The why line for the LABELED estimate timeline. There the mandatory
    /// `AtriaSleepStageEstimateLabel` caption already states the generic why
    /// ("Motion not available — …"), so this adds a line only when the
    /// transport evidence carries extra truth the caption lacks; nil means
    /// the caption stands alone (never duplicated).
    static func timelineWhyEstimateLine(
        motionAvailability: AtriaStrapMotionAvailability?
    ) -> String? {
        switch motionAvailability {
        case .catchingUp, .unavailableInCurrentTransport:
            return whyEstimateLine(motionAvailability: motionAvailability)
        default:
            return nil
        }
    }

    /// Single gate for the coarse totals: only the generic `.estimate` state
    /// (no reconciled stage timeline), only confirmed nights, only a real
    /// saved total inside a real window. `.estimatedTimeline` nights never
    /// show totals — their legend already carries real stage minutes.
    var coarseTotals: CoarseNightTotals? {
        guard state == .estimate, isConfirmedNight, let start, let end else { return nil }
        return Self.coarseNightTotals(windowStart: start,
                                      windowEnd: end,
                                      sleepDuration: sleepTotalSeconds)
    }

    // MARK: - Estimate + timeline

    private var sectionTitle: String {
        switch state {
        case .estimate: return "Estimated asleep window"
        // Mandatory label: estimated bars must never carry the plain
        // "Stages · Hypnogram" authority of validated timelines.
        case .estimatedTimeline: return AtriaSleepStageEstimateLabel.title
        default: return "Stages · Hypnogram"
        }
    }

    /// HR-only presentation intentionally has no lane/stage input. The single
    /// band communicates the estimated window; the copy states exactly which
    /// signal was measured and which stage claims are withheld.
    private func estimatedAsleepWindow(windowStart: Date, windowEnd: Date) -> some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AtriaDesignTokens.Spacing.sm) {
                // 2026-08-29 minimalism pass: the label reads neutral — the
                // electricSleep band below already carries the theme.
                Text("Estimated asleep")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let heartRateText = Self.measuredHeartRateText(measuredHeartRate) {
                    Text(heartRateText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            ZStack {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                Capsule(style: .continuous)
                    .fill(Metrics.electricSleep.opacity(0.62))
            }
            .frame(height: 16)
            .accessibilityHidden(true)

            HStack {
                Text(AtriaSleepHypnogramPresentation.clockLabel(windowStart, calendar: eventCalendar))
                Spacer(minLength: 0)
                Text(AtriaSleepHypnogramPresentation.clockLabel(windowEnd, calendar: eventCalendar))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)

            // P8 sub-0.60 coarse fallback: a confirmed HR-only night whose
            // stage output stays withheld still gets honest sleep/wake
            // TOTALS from the saved record — never fabricated stages.
            // 2026-08-29 minimalism pass: neutral compact rows, no tinted
            // tiles — the numbers, not their color, are the content.
            if let totals = coarseTotals {
                HStack(spacing: AtriaDesignTokens.Spacing.md) {
                    coarseTotalEntry(label: Self.coarseAsleepTotalLabel,
                                     minutes: totals.asleepMinutes)
                    coarseTotalEntry(label: Self.coarseAwakeTotalLabel,
                                     minutes: totals.awakeOrUnmeasuredMinutes)
                }
            }

            // P8 "why tonight is an estimate": the one sentence of prose in
            // this state, naming the actual cause (pinned copy).
            Text(Self.whyEstimateLine(motionAvailability: motionAvailability))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One coarse-total entry: neutral value + secondary label, no tinted
    /// chrome (2026-08-29 minimalism pass — only two totals, never stages).
    private func coarseTotalEntry(label: String, minutes: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.coarseTotalText(minutes: minutes))
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sharedTimeline(windowStart: Date,
                                windowEnd: Date,
                                isEstimate: Bool) -> some View {
        let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
            for: segments,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        return AtriaSleepStageTimelineChart(
            runs: timeline.runs,
            windowStart: windowStart,
            windowEnd: windowEnd,
            calendar: eventCalendar,
            isEstimate: isEstimate,
            composited: timeline.composited,
            accessibilitySummary: accessibilityText
        )
    }

    /// 2026-08-29 minimalism pass: the four tinted legend tiles collapse to
    /// one compact line — only the small dot carries the stage color (a
    /// legend key for the ribbons above), text stays neutral, no chrome.
    private var legendTiles: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.md) {
            ForEach(AtriaSleepHypnogramPresentation.legend(for: segments),
                    id: \.stage) { entry in
                HStack(spacing: AtriaDesignTokens.Spacing.xs) {
                    Circle()
                        .fill(Self.color(for: entry.stage))
                        .frame(width: 6, height: 6)
                    Text("\(entry.stage.label) \(AtriaSleepHypnogramPresentation.durationText(minutes: entry.minutes))")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func honestState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .timeline:
            let legend = AtriaSleepHypnogramPresentation.legend(for: segments)
            let stages = legend
                .map { "\($0.stage.label) \(AtriaSleepHypnogramPresentation.durationText(minutes: $0.minutes))" }
                .joined(separator: ", ")
            return "Sleep stages hypnogram. \(provenanceText). \(stages)."
        case .estimatedTimeline:
            let legend = AtriaSleepHypnogramPresentation.legend(for: segments)
            let stages = legend
                .map { "\($0.stage.label) \(AtriaSleepHypnogramPresentation.durationText(minutes: $0.minutes))" }
                .joined(separator: ", ")
            // P8: VoiceOver reads the same transport why line as the visual
            // copy whenever one renders.
            let whyLine = Self.timelineWhyEstimateLine(motionAvailability: motionAvailability)
                .map { " \($0)" } ?? ""
            return "\(AtriaSleepStageEstimateLabel.title). \(AtriaSleepStageEstimateLabel.caption)\(whyLine) \(provenanceText). \(stages)."
        case .estimate:
            let heartRate = Self.measuredHeartRateText(measuredHeartRate)
                .map { ". \($0)" } ?? ""
            // P8: the coarse totals and the why line are spoken exactly when
            // they are drawn.
            let totalsText = coarseTotals.map {
                " \(Self.coarseAsleepTotalLabel) \(Self.coarseTotalText(minutes: $0.asleepMinutes))."
                    + " \(Self.coarseAwakeTotalLabel) \(Self.coarseTotalText(minutes: $0.awakeOrUnmeasuredMinutes))."
            } ?? ""
            return "Estimated asleep window. \(provenanceText)\(heartRate).\(totalsText) "
                + Self.whyEstimateLine(motionAvailability: motionAvailability)
        case .needsMotion:
            // ITEM-3 2026-08-15: VoiceOver reads the same unlock story as the
            // visual copy so the two can never diverge.
            return "\(provenanceText). Stage analysis unavailable for this night. "
                + Self.unavailableStagesDetail(
                    base: Self.needsMotionBase,
                    motionAvailability: motionAvailability)
        case .manualEntry:
            return "\(provenanceText). No stages — manual entry. \(Self.manualEntryDetail)"
        case .building:
            return "\(provenanceText). Stage analysis unavailable for this night. "
                + Self.unavailableStagesDetail(
                    base: Self.buildingBase,
                    motionAvailability: motionAvailability)
        }
    }

    private static let laneHeight: CGFloat = 16
    private static let laneLabelWidth: CGFloat = 40
}

/// One shared stepped sleep-stage timeline for every hypnogram surface
/// (2026-08-13 graph-system convergence): the sleep detail card and the
/// Vitals sleep section render THIS, never their own drawing grammar.
/// Four lanes top→bottom (Awake/REM/Light/Deep, SWS folded into Deep for
/// display per the existing presentation contract), calm rounded ribbons per
/// run, a thin vertical connector at each real transition, quiet lane bands,
/// and real clock ticks. Scrubbing shows the exact clock range and stage with
/// `Estimated` provenance on HR-only nights — never a clinical claim.
struct AtriaSleepStageTimelineChart: View {
    let runs: [AtriaSleepHypnogramPresentation.Run]
    let windowStart: Date
    let windowEnd: Date
    let calendar: Calendar
    let isEstimate: Bool
    let composited: Bool
    let accessibilitySummary: String

    @State private var selectedRunID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let laneLabelWidth: CGFloat = 42
    private static let ribbonHeight: CGFloat = 9
    private static let plotHeight: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selected = runs.first(where: { $0.id == selectedRunID }) {
                selectionCallout(for: selected)
            } else if composited {
                Text(isEstimate ? "Dense estimate" : "Dense timeline")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: AtriaDesignTokens.Spacing.sm) {
                laneLabels
                plot
            }
            axisRow
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var laneLabels: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(AtriaSleepHypnogramPresentation.lanes.enumerated()),
                    id: \.element) { _, stage in
                // 2026-08-29 minimalism pass: neutral lane labels — the
                // ribbon beside each label already carries the stage color.
                Text(stage.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: Self.laneLabelWidth, height: Self.plotHeight)
    }

    private var plot: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                drawLaneBands(in: &context, size: size)
                drawRuns(in: &context, size: size)
            }
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(plotWidth: proxy.size.width))
        }
        .frame(height: Self.plotHeight)
    }

    private var axisRow: some View {
        GeometryReader { proxy in
            let ticks = AtriaSleepHypnogramPresentation.axisTicks(
                windowStart: windowStart,
                windowEnd: windowEnd,
                calendar: calendar
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    Text(tick.label)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in
                            -((proxy.size.width - Self.laneLabelWidth
                               - AtriaDesignTokens.Spacing.sm) * tick.fraction
                              + Self.laneLabelWidth
                              + AtriaDesignTokens.Spacing.sm
                              - dimensions.width * tick.fraction)
                        }
                }
            }
        }
        .frame(height: 12)
    }

    /// 2026-08-29 minimalism pass: the scrub callout uses the same neutral
    /// glass chrome as the trend chart's scrub callout (primary text on
    /// `atriaGlassCard`) instead of a stage-tinted capsule — a small stage
    /// dot keys it to the ribbon, everything else stays neutral.
    private func selectionCallout(for run: AtriaSleepHypnogramPresentation.Run) -> some View {
        let range = "\(AtriaSleepHypnogramPresentation.clockLabel(run.start, calendar: calendar))–\(AtriaSleepHypnogramPresentation.clockLabel(run.end, calendar: calendar))"
        let provenance = isEstimate ? " · Estimated" : ""
        return HStack(spacing: AtriaDesignTokens.Spacing.xs) {
            Circle()
                .fill(AtriaSleepHypnogramCard.color(for: run.stage.displayStage))
                .frame(width: 6, height: 6)
            Text("\(range) · \(run.stage.displayStage.label)\(provenance)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .atriaGlassCard(cornerRadius: AtriaDesignTokens.Radius.chip)
    }

    private func laneCenterY(_ laneIndex: Int, height: CGFloat) -> CGFloat {
        let laneHeight = height / CGFloat(AtriaSleepHypnogramPresentation.lanes.count)
        return laneHeight * (CGFloat(laneIndex) + 0.5)
    }

    private func drawLaneBands(in context: inout GraphicsContext, size: CGSize) {
        let laneHeight = size.height / CGFloat(AtriaSleepHypnogramPresentation.lanes.count)
        for index in AtriaSleepHypnogramPresentation.lanes.indices {
            let y = laneHeight * CGFloat(index)
            if index.isMultiple(of: 2) {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: laneHeight)),
                    with: .color(Color.primary.opacity(0.018))
                )
            }
            var guide = Path()
            let centerY = y + laneHeight / 2
            guide.move(to: CGPoint(x: 0, y: centerY))
            guide.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(guide,
                           with: .color(Color.primary.opacity(0.05)),
                           lineWidth: 1)
        }
    }

    private func drawRuns(in context: inout GraphicsContext, size: CGSize) {
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        guard windowDuration > 0 else { return }
        func x(_ date: Date) -> CGFloat {
            size.width * CGFloat(date.timeIntervalSince(windowStart) / windowDuration)
        }
        var previous: AtriaSleepHypnogramPresentation.Run?
        for run in runs {
            let laneIndex = AtriaSleepHypnogramPresentation.laneIndex(for: run.stage)
            let y = laneCenterY(laneIndex, height: size.height)
            let startX = x(run.start)
            let endX = x(run.end)
            // Thin connector at the real transition between consecutive runs.
            if let previous {
                let previousY = laneCenterY(
                    AtriaSleepHypnogramPresentation.laneIndex(for: previous.stage),
                    height: size.height
                )
                if abs(previousY - y) > 0.5,
                   abs(x(previous.end) - startX) < 3 {
                    var connector = Path()
                    connector.move(to: CGPoint(x: startX, y: previousY))
                    connector.addLine(to: CGPoint(x: startX, y: y))
                    context.stroke(connector,
                                   with: .color(Color.secondary.opacity(0.28)),
                                   lineWidth: 1.25)
                }
            }
            let isSelected = run.id == selectedRunID
            var ribbon = Path()
            ribbon.move(to: CGPoint(x: startX + Self.ribbonHeight / 2, y: y))
            ribbon.addLine(to: CGPoint(x: max(startX + Self.ribbonHeight / 2,
                                              endX - Self.ribbonHeight / 2), y: y))
            context.stroke(
                ribbon,
                with: .color(
                    AtriaSleepHypnogramCard.color(for: run.stage)
                        .opacity(isSelected ? 1.0 : 0.72)
                ),
                style: StrokeStyle(lineWidth: Self.ribbonHeight,
                                   lineCap: .round)
            )
            previous = run
        }
    }

    private func scrubGesture(plotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let windowDuration = windowEnd.timeIntervalSince(windowStart)
                guard windowDuration > 0, plotWidth > 0 else { return }
                let fraction = Double(
                    min(max(value.location.x / plotWidth, 0), 1)
                )
                let scrubbed = windowStart.addingTimeInterval(
                    windowDuration * fraction
                )
                let hit = runs.first {
                    $0.start <= scrubbed && scrubbed < $0.end
                } ?? runs.last(where: { $0.end <= scrubbed })
                if hit?.id != selectedRunID {
                    selectedRunID = hit?.id
                    #if canImport(UIKit)
                    if !reduceMotion {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    #endif
                }
            }
            .onEnded { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    selectedRunID = nil
                }
            }
    }
}

#if DEBUG
// Deterministic fixtures (handoff-7 2D): the dense HR-only estimate shape
// from the 2026-08-13 user screenshot and a calm motion-validated night.
private enum AtriaSleepStageTimelineFixtures {
    static let anchor = Date(timeIntervalSinceReferenceDate: 805_000_000)

    static func denseEstimate() -> [SleepStageSegment] {
        var segments: [SleepStageSegment] = []
        var cursor: TimeInterval = 0
        let cycle: [(SleepStageKind, TimeInterval)] = [
            (.light, 12 * 60), (.deep, 9 * 60), (.light, 3 * 60),
            (.rem, 8 * 60), (.deep, 14 * 60), (.rem, 2 * 60)
        ]
        while cursor < 9 * 3_600 {
            for (stage, duration) in cycle where cursor < 9 * 3_600 {
                segments.append(SleepStageSegment(
                    id: "fixture-\(Int(cursor))",
                    start: anchor.addingTimeInterval(cursor),
                    end: anchor.addingTimeInterval(cursor + duration),
                    stage: stage
                ))
                cursor += duration
            }
        }
        return segments
    }

    static func validated() -> [SleepStageSegment] {
        let plan: [(SleepStageKind, TimeInterval)] = [
            (.awake, 8 * 60), (.light, 45 * 60), (.deep, 70 * 60),
            (.light, 30 * 60), (.rem, 55 * 60), (.light, 40 * 60),
            (.deep, 50 * 60), (.rem, 65 * 60), (.light, 35 * 60),
            (.awake, 6 * 60)
        ]
        var segments: [SleepStageSegment] = []
        var cursor: TimeInterval = 0
        for (stage, duration) in plan {
            segments.append(SleepStageSegment(
                id: "validated-\(Int(cursor))",
                start: anchor.addingTimeInterval(cursor),
                end: anchor.addingTimeInterval(cursor + duration),
                stage: stage
            ))
            cursor += duration
        }
        return segments
    }
}

#Preview("Stage timeline · dense HR-only estimate") {
    let segments = AtriaSleepStageTimelineFixtures.denseEstimate()
    let start = AtriaSleepStageTimelineFixtures.anchor
    let end = segments.last?.end ?? start
    let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
        for: segments, windowStart: start, windowEnd: end
    )
    return AtriaSleepStageTimelineChart(
        runs: timeline.runs,
        windowStart: start,
        windowEnd: end,
        calendar: .current,
        isEstimate: true,
        composited: timeline.composited,
        accessibilitySummary: "Estimated stages, dense HR-only fixture."
    )
    .padding()
}

#Preview("Stage timeline · motion validated · dark") {
    let segments = AtriaSleepStageTimelineFixtures.validated()
    let start = AtriaSleepStageTimelineFixtures.anchor
    let end = segments.last?.end ?? start
    let timeline = AtriaSleepHypnogramPresentation.timelineRuns(
        for: segments, windowStart: start, windowEnd: end
    )
    return AtriaSleepStageTimelineChart(
        runs: timeline.runs,
        windowStart: start,
        windowEnd: end,
        calendar: .current,
        isEstimate: false,
        composited: timeline.composited,
        accessibilitySummary: "Validated stages fixture."
    )
    .padding()
    .preferredColorScheme(.dark)
}
#endif

