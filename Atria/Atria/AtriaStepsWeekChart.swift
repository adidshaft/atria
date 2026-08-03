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

    var body: some View {
        let end = calendar.startOfDay(for: referenceDate)
        let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let days = (0...6).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let hasAny = days.contains { stepsByDay[$0] != nil }
        let axisLo = calendar.date(byAdding: .hour, value: -12, to: start) ?? start
        let axisHi = calendar.date(byAdding: .hour, value: 12, to: end) ?? end

        VStack(alignment: .leading, spacing: 8) {
            Text("This week")
                .font(.subheadline.weight(.semibold))

            if hasAny {
                Chart {
                    ForEach(days, id: \.self) { day in
                        if let steps = stepsByDay[day] {
                            BarMark(x: .value("Day", day, unit: .day),
                                    y: .value("Steps", steps))
                                .foregroundStyle(Metrics.electricGreen.opacity(0.85))
                                .cornerRadius(4)
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
                .chartXScale(domain: axisLo...axisHi)
                .chartXAxis {
                    AxisMarks(values: days) { _ in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 140)
                .clipped()

                Text("Verified strap steps per day. A day with no verified reading shows no bar.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Building your step history — days with verified strap steps will appear here as they're recorded.")
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
