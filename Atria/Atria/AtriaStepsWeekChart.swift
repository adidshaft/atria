import SwiftUI
import Charts

/// Last seven wake-to-wake days of verified strap steps (owner 2026-10-01:
/// the Steps headline and its bars both count since wake). The current
/// cycle's bar is the headline count itself, so the two can never disagree.
/// A cycle with no reading draws no bar — missing is not zero.
///
/// Self-contained (no environment) so it renders straight to an image in a test.
struct AtriaStepsWeekChart: View {
    struct CycleBar: Identifiable, Equatable {
        /// Wake that opened the cycle; the bar is labelled by its weekday.
        let start: Date
        let steps: Int?
        /// Still open, thinly covered, or answered only by a cycle receipt.
        let isPartial: Bool
        let isCurrent: Bool
        var id: Date { start }
    }

    /// Oldest first, at most seven.
    let bars: [CycleBar]
    let goal: Int

    private let calendar = Calendar.current

    /// The civil day a physiological cycle belongs to on this chart.
    ///
    /// Receipts are keyed by a WAKE boundary, not by midnight, so a cycle
    /// straddles two dates. Bucketing on `startOfDay(windowStart)` labelled a
    /// cycle by the day it woke, which for a late-evening wake put nearly all
    /// of its steps under the PREVIOUS day's letter — a cycle running
    /// Sun 20:26 → Mon 20:56 drew on Sunday while being almost entirely Monday.
    ///
    /// Owner's decision (2026-08-26): label by the day the cycle predominantly
    /// covers. This walks the civil days the window touches and returns the one
    /// holding the most of it.
    ///
    /// An exact tie — a cycle split evenly across midnight — keeps the EARLIER
    /// day, so the result is deterministic rather than dependent on iteration
    /// order.
    /// Open-cycle tolerance: a receipt whose window ends within this of now is
    /// still running.
    static let openCycleTolerance: TimeInterval = 90 * 60

    /// Strap-step receipts folded onto the civil days their cycles cover.
    ///
    /// ONE authority for every surface that draws daily strap steps. The
    /// Overview week chart and the Today sparkline are the same metric on two
    /// screens, and this rule is subtle enough that a second copy would drift:
    /// it already happened once between a card and its own chart, where the
    /// headline read 5,878 while the chart folded it into a 7,336 bar on the
    /// previous day.
    static func dailyStepTotals(
        receipts: [HistoricalArchive.MotionTickDayEvidence],
        now: Date,
        calendar: Calendar = .current
    ) -> [Date: Int] {
        let today = calendar.startOfDay(for: now)

        // Drop receipts whose window is FULLY CONTAINED in another receipt's.
        //
        // The sum below is correct for genuinely disjoint cycles, and its own
        // comment used to justify itself with "cycles do not overlap". The
        // device says otherwise: of 32 stored receipts, 17 overlap another and
        // EIGHT sit entirely inside one. Summing those counts the same walking
        // twice — 15 Aug held two 154-step receipts, one window inside the
        // other, and shipped 308. 21 Aug shipped 3,442 with a 901-step window
        // sitting inside an 1,118-step one.
        //
        // Only full containment is removed here, because it is the only case
        // that is provably duplicate: a contained window's steps all occurred
        // inside the outer window, so the outer receipt already counts them.
        // The store says the same thing in its own words -- see
        // `AtriaWhoop4MotionTickDailyStore.mergingCurrentCycleReceipt`: "A
        // receipt beginning later in the same physiological cycle is only a
        // CONTAINED SUBSET". That rule governs admitting a receipt to the
        // CURRENT cycle; this applies the same relationship to closed receipts
        // being folded onto civil days.
        //
        // WHY THEY OVERLAP AT ALL, since deduplicating here treats a symptom:
        // a receipt's window begins at
        // `AtriaPhysiologicalCycle.current(...).start`, derived from confirmed
        // sleeps. When no sleep confirms, that boundary comes from the
        // no-sleep fallback and MOVES between publications, so successive
        // publications of one real cycle are written with different starts and
        // the later lands inside the earlier. On this device 17 of 32 receipts
        // overlap -- a direct consequence of sleep not confirming, not an
        // independent bug.
        // PARTIAL overlaps are deliberately left alone — the receipts carry no
        // per-interval breakdown, so there is no honest way to subtract the
        // shared portion, and dropping either whole receipt would delete real
        // steps from outside the overlap.
        let ordered = receipts.sorted { $0.windowStart < $1.windowStart }
        let deduplicated = ordered.filter { candidate in
            !ordered.contains { other in
                guard other.windowStart != candidate.windowStart
                        || other.windowEnd != candidate.windowEnd else { return false }
                let contains = other.windowStart <= candidate.windowStart
                    && other.windowEnd >= candidate.windowEnd
                return contains
            }
        }

        var totals: [Date: Int] = [:]
        for receipt in deduplicated {
            // Predominant coverage is only stable once a window has CLOSED. An
            // open cycle that began yesterday morning reads as yesterday's now
            // and would flip to today's a few hours later, so its bar would
            // migrate between days while the user watched — and it is also the
            // number the card shows as "today", which the chart must match.
            let isOpenCycle = receipt.windowEnd >= now.addingTimeInterval(-openCycleTolerance)
            let day = isOpenCycle
                ? today
                : predominantCivilDay(windowStart: receipt.windowStart,
                                      windowEnd: receipt.windowEnd,
                                      calendar: calendar)
            // SUM, not max: two CLOSED receipts on one day are two genuinely
            // different cycles, and `max` silently dropped the smaller.
            totals[day, default: 0] += receipt.steps
        }
        return totals
    }

    static func predominantCivilDay(windowStart: Date,
                                    windowEnd: Date,
                                    calendar: Calendar) -> Date {
        let first = calendar.startOfDay(for: windowStart)
        guard windowEnd > windowStart else { return first }

        var best = first
        var bestOverlap: TimeInterval = 0
        var dayStart = first
        while dayStart < windowEnd {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  dayEnd > dayStart else { break }
            let overlap = min(windowEnd, dayEnd)
                .timeIntervalSince(max(windowStart, dayStart))
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = dayStart
            }
            dayStart = dayEnd
        }
        return best
    }

    /// Completed-day performance colour (2026-08-08 user request): green at or
    /// above the daily goal, orange under it, red well under (< half). This is
    /// deliberately NOT `Metrics.stepsZone`, which never reds a *mid-day* Today
    /// card; here every bar is a COMPLETED day where under-target is a real
    /// read. Bars are still verified LOWER BOUNDS, so the honest caption stays.
    enum BarStyle: Equatable { case met, under, wellUnder, partial }

    /// 2026-09-24: a partial day (today so far, or not fully covered) is not a
    /// completed day, so it is never judged against the goal: before this the
    /// in-progress bar for today turned red every morning. A partial day that
    /// already met the goal still shows met, since the count is a lower bound.
    static func barStyle(steps: Int, goal: Int, isPartial: Bool) -> BarStyle {
        let ratio = Double(steps) / Double(max(goal, 1))
        if ratio >= 1.0 { return .met }
        if isPartial { return .partial }
        return ratio >= 0.5 ? .under : .wellUnder
    }

    /// "4,210+" for a partial day: an at-least count, never a fake total.
    static func countLabel(steps: Int, isPartial: Bool) -> String {
        steps.formatted(.number.grouping(.automatic)) + (isPartial ? "+" : "")
    }

    private func barTint(_ style: BarStyle) -> Color {
        switch style {
        case .met: return Metrics.electricGreen
        case .under: return .orange
        case .wellUnder: return .red
        case .partial: return Color.secondary.opacity(0.55)
        }
    }

    /// "8.5k" above a bar: the exact count is the headline (current cycle)
    /// or one tap away; seven full numbers crowded into each other.
    static func compactCountLabel(steps: Int, isPartial: Bool) -> String {
        let text: String
        if steps >= 1_000 {
            text = (Double(steps) / 1_000).formatted(.number.precision(.fractionLength(1))) + "k"
        } else {
            text = "\(steps)"
        }
        return text + (isPartial ? "+" : "")
    }

    /// Recent wake-to-wake windows, oldest first. The last one is the open
    /// cycle and ends at `now`. Each earlier start is the cycle that was
    /// current just before the next one began, so no-sleep fallback days
    /// follow the same rule as everywhere else.
    static func cycleWindows(now: Date,
                             confirmedSleeps: [UserConfirmedSleep],
                             count: Int = 7,
                             calendar: Calendar = .current) -> [DateInterval] {
        var windows: [DateInterval] = []
        var end = now
        var probe = now
        for _ in 0..<max(count, 0) {
            let start = AtriaPhysiologicalCycle.current(
                now: probe,
                confirmedSleeps: confirmedSleeps,
                calendar: calendar
            ).start
            guard start < end else { break }
            windows.append(DateInterval(start: start, end: end))
            end = start
            probe = start.addingTimeInterval(-1)
        }
        return windows.reversed()
    }

    /// Receipt fallback per cycle: closed receipts whose window midpoint lies
    /// in the cycle, contained duplicates dropped (see `dailyStepTotals`).
    static func cycleStepTotals(
        receipts: [HistoricalArchive.MotionTickDayEvidence],
        windows: [DateInterval]
    ) -> [Date: Int] {
        let ordered = receipts.sorted { $0.windowStart < $1.windowStart }
        let deduplicated = ordered.filter { candidate in
            !ordered.contains { other in
                (other.windowStart != candidate.windowStart
                    || other.windowEnd != candidate.windowEnd)
                    && other.windowStart <= candidate.windowStart
                    && other.windowEnd >= candidate.windowEnd
            }
        }
        var totals: [Date: Int] = [:]
        for receipt in deduplicated {
            let middle = receipt.windowStart.addingTimeInterval(
                receipt.windowEnd.timeIntervalSince(receipt.windowStart) / 2
            )
            guard let window = windows.first(where: {
                $0.start <= middle && middle < $0.end
            }) else { continue }
            totals[window.start, default: 0] += receipt.steps
        }
        return totals
    }

    private var slotIDs: [String] { bars.indices.map(String.init) }

    var body: some View {
        let measured = bars.compactMap(\.steps)
        let top = Double(max(measured.max() ?? 0, max(goal, 1)))
        let hasPartial = bars.contains { $0.steps != nil && $0.isPartial && !$0.isCurrent }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                // The goal names its dashed line here, outside the plot, so it
                // can never sit on top of a bar's count (device 2026-10-01).
                HStack(spacing: 5) {
                    Capsule()
                        .stroke(Color.secondary.opacity(0.7),
                                style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 14, height: 1.5)
                    Text("Goal \(goal.formatted(.number.grouping(.automatic)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if measured.isEmpty {
                Text("Verified step days will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Chart {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                        if let steps = bar.steps {
                            let style = Self.barStyle(steps: steps, goal: goal,
                                                      isPartial: bar.isPartial)
                            BarMark(x: .value("Day", String(index)),
                                    y: .value("Steps", steps),
                                    width: .ratio(AtriaChartVisualGrammar.dailyBarWidthRatio))
                                .foregroundStyle(barTint(style).opacity(bar.isPartial ? 0.7 : 0.9))
                                .cornerRadius(AtriaChartVisualGrammar.dailyBarCornerRadius)
                                .annotation(position: .top, spacing: 3,
                                            overflowResolution: .init(x: .fit(to: .chart),
                                                                      y: .fit(to: .chart))) {
                                    Text(Self.compactCountLabel(steps: steps,
                                                                isPartial: bar.isPartial && !bar.isCurrent))
                                        .font(.caption2.weight(bar.isCurrent ? .semibold : .regular)
                                                .monospacedDigit())
                                        .foregroundStyle(bar.isCurrent
                                                         ? Color.primary
                                                         : AtriaChartVisualGrammar.axisLabelColor)
                                }
                                .accessibilityLabel(bar.start.formatted(.dateTime.weekday(.wide)))
                                .accessibilityValue("\(steps) steps\(bar.isPartial ? ", so far" : "")")
                        }
                    }
                }
                .chartXScale(domain: slotIDs)
                .chartYScale(domain: 0...(top * 1.18))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: slotIDs) { value in
                        if let id = value.as(String.self), let index = Int(id),
                           bars.indices.contains(index) {
                            let bar = bars[index]
                            AxisValueLabel {
                                Text(AtriaChartVisualGrammar.weekdayAxisLabel(for: bar.start))
                                    .font(bar.isCurrent
                                          ? AtriaChartVisualGrammar.axisLabelFont.weight(.bold)
                                          : AtriaChartVisualGrammar.axisLabelFont)
                                    .foregroundStyle(bar.isCurrent
                                                     ? Color.primary
                                                     : AtriaChartVisualGrammar.axisLabelColor)
                            }
                        }
                    }
                }
                .atriaDailyChartPlotChrome()
                .frame(height: 150)

                Text(hasPartial
                     ? "Each bar runs wake to wake · + still syncing"
                     : "Each bar runs wake to wake")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: Metrics.electricGreen)
    }
}

/// How far strap motion has reached the phone (owner 2026-10-01: "the user
/// never knows if their latest walk was recorded"). Steps come from the
/// strap's history, so the honest answer is the durable drain cursor.
struct AtriaStrapMotionSyncStatus: Equatable {
    let title: String
    let detail: String
    let isUpToDate: Bool

    /// The drain lands rows in ~1 min slices and keep-up runs every 30 min;
    /// inside this lag the wearer's latest movement is already counted.
    static let upToDateLag: TimeInterval = 15 * 60

    static func make(syncedThrough: Date?,
                     now: Date,
                     calendar: Calendar = .current) -> Self {
        guard let syncedThrough, syncedThrough.timeIntervalSince1970 > 0 else {
            return Self(title: "Waiting for first sync",
                        detail: "Steps appear once the strap's motion syncs",
                        isUpToDate: false)
        }
        let time = timeText(syncedThrough, now: now, calendar: calendar)
        let lag = now.timeIntervalSince(syncedThrough)
        if lag <= upToDateLag {
            return Self(title: "Up to date",
                        detail: "Motion synced through \(time)",
                        isUpToDate: true)
        }
        return Self(title: "Synced to \(time)",
                    detail: "\(lagText(lag)) of motion still on the strap",
                    isUpToDate: false)
    }

    static func persistedSyncedThrough(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Date? {
        // Sample data reads as a normal recent sync, like its motion badge.
        if AtriaAppReviewDemo.isActive {
            return now.addingTimeInterval(-AtriaAppReviewDemo.demoMotionAge)
        }
        let unix = defaults.double(
            forKey: AtriaBLEManager.OfflineSyncDefaults.historyDrainCursorUnix
        )
        return unix > 0 ? Date(timeIntervalSince1970: unix) : nil
    }

    static func timeText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + clock
    }

    static func lagText(_ lag: TimeInterval) -> String {
        let minutes = max(1, Int((lag / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
