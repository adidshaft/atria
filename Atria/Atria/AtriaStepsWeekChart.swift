import SwiftUI
import Charts

/// Fixed 7-day weekday bar chart of verified per-day step totals (design backlog
/// P2, 2026-08-03). Matches the "7 fixed weekday ticks" rule: seven day-ticks
/// always, a bar only on days with a verified receipt (missing ≠ zero, never a
/// zero-height bar implying "0 steps recorded"). Native Swift Charts.
///
/// Self-contained (no environment) so it renders straight to an image in a test.
struct AtriaStepsWeekChart: View {
    /// Day-start → verified step total. Days absent from the map draw no bar.
    let stepsByDay: [Date: Int]
    let goal: Int
    /// The day the 7-day window ends on (defaults to today). A parameter so a
    /// test can anchor deterministically.
    var referenceDate: Date = Date()

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
    private func barTint(steps: Int) -> Color {
        let safeGoal = max(goal, 1)
        let ratio = Double(steps) / Double(safeGoal)
        if ratio >= 1.0 { return Metrics.electricGreen }
        if ratio >= 0.5 { return .orange }
        return .red
    }

    var body: some View {
        let end = calendar.startOfDay(for: referenceDate)
        let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let days = (0...6).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let hasAny = days.contains { stepsByDay[$0] != nil }
        // Exactly the seven days, edge to edge. A `unit: .day` BarMark occupies
        // its whole day slot, so a domain of [first 00:00, last 24:00) gives
        // each bar precisely one seventh of the width with no dead margin —
        // the earlier ±18h padding bought room for the end labels at the cost
        // of insetting every bar from the plot edges.
        let axisLo = start
        let axisHi = calendar.date(byAdding: .day, value: 1, to: end) ?? end

        VStack(alignment: .leading, spacing: 8) {
            Text("This week")
                .font(.subheadline.weight(.semibold))

            if hasAny {
                Chart {
                    ForEach(days, id: \.self) { day in
                        if let steps = stepsByDay[day] {
                            BarMark(x: .value("Day", day, unit: .day),
                                    y: .value("Steps", steps))
                                .foregroundStyle(barTint(steps: steps).opacity(0.85))
                                .cornerRadius(4)
                                // Per-bar count (2026-08-08): bars alone gave no
                                // read of the actual number. Small label above
                                // each bar; days with no bar stay empty.
                                // The newest day sits hard against the trailing
                                // edge, so its count was clipped mid-number
                                // ("5,8" for 5,878) — the chart cut the one
                                // value the reader most wants. Let Charts pull
                                // an overflowing label back inside the plot.
                                .annotation(position: .top, spacing: 2) {
                                    Text(steps.formatted(.number.grouping(.automatic)))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                        }
                    }
                    if goal > 0 {
                        RuleMark(y: .value("Goal", goal))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .annotation(position: .top, alignment: .trailing, spacing: 1) {
                                Text("goal \(goal)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .atriaGraphPlotSurface()
                .chartXScale(domain: axisLo...axisHi)
                .chartXAxis {
                    AxisMarks(values: days) { _ in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        // `centered: true` places the letter in the MIDDLE of
                        // the day it names, which is where a `unit: .day` bar
                        // is drawn. Without it the tick sits at midnight while
                        // the bar occupies the whole day, so every weekday
                        // letter sat half a day left of its own bar. The grid
                        // line stays on the boundary, which is correct — only
                        // the label is centred. (Same treatment the stress
                        // distribution chart already uses.)
                        AxisValueLabel(format: .dateTime.weekday(.narrow),
                                       centered: true)
                            .foregroundStyle(.secondary)
                    }
                }
                // Leading axis, like every other chart in the app. Swift Charts
                // defaults the value axis to the TRAILING edge, which put these
                // labels on the right where they collided with the "goal"
                // annotation and were the first thing clipped.
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel().foregroundStyle(.secondary)
                    }
                }
                .frame(height: 140)
                // The plot used to be pulled 12pt wider than its card on each
                // side to sit "full bleed". That is wider than the space it
                // has, so the axis labels and the newest day's bar fell outside
                // and `.clipped()` cut them off — the chart lost its most
                // recent column, which is the one the reader wants most. Let it
                // fit the card instead.

                Text("Vs your daily goal — green met, amber under, red well under. Verified so far; no bar means no reading.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Verified strap-step days will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: Metrics.electricGreen)
    }
}
