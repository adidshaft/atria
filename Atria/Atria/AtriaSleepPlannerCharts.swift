import SwiftUI
import Charts

// Sleep Planner charts (design source: Claude Design "Atria App UI.dc.html",
// section 6 "SLEEP PLANNER & SMART WAKE", 2026-08-01 design-parity slice 1):
//   6a — itemized need ledger: stacked bar h26 r8 on a fixed 0–10h axis
//        (baseline #5E5CE6 / strain add #FF9F0A / debt add #FF453A / nap
//        credit hatched #7EE29A), axis labels 0h·4h·8h·10h, legend rows with
//        the exact minute values, total row "Tonight's need".
//   6b — 7-night need-vs-slept chart: per-morning paired bars (need =
//        translucent track, slept = solid #0A84FF, shortfall night #FF9F0A),
//        day letters, carried-debt hero from the real recency-weighted debt,
//        "fulfilled last night" ring.
//
// Honesty (hard constraint): every number renders from the app's real
// AtriaSleepBudget ledger/debt math — nothing is recomputed or sampled here.
// Mornings without a confirmed main sleep stay empty slots, and fewer than
// three real nights renders the building state instead of bars.

/// Pure ledger→bar-segment math, unit-testable without SwiftUI.
enum AtriaSleepNeedLedgerPresentation {
    /// Design axis 0h–10h — 10h is also the hard upper clamp of the need
    /// math, so the stacked bar can never overflow its own axis.
    static let axisHours: Double = 10
    /// Sub-minute slivers drop out rather than render as 1px noise.
    static let minimumSegmentHours = 1.0 / 60

    enum Term: String, CaseIterable {
        case baseline, strain, debt, napCredit
    }

    struct Segment: Equatable {
        let term: Term
        let startFraction: Double
        let widthFraction: Double
    }

    /// Stacked segments left→right: baseline, strain add, debt add — then the
    /// nap credit hatched over the LAST napCredit-worth of that stack (it is
    /// the slice the nap removes; net need ends where the hatch begins).
    static func segments(for components: AtriaSleepBudget.NeedComponents) -> [Segment] {
        var out: [Segment] = []
        var cursorHours = 0.0
        let positiveTerms: [(Term, Double)] = [(.baseline, components.baseHours),
                                               (.strain, components.strainAdderHours),
                                               (.debt, components.debtAdderHours)]
        for (term, hours) in positiveTerms where hours >= minimumSegmentHours {
            let clipped = min(hours, axisHours - cursorHours)
            guard clipped >= minimumSegmentHours else { continue }
            out.append(Segment(term: term,
                               startFraction: cursorHours / axisHours,
                               widthFraction: clipped / axisHours))
            cursorHours += clipped
        }
        let napHours = min(components.napCreditHours, cursorHours)
        if napHours >= minimumSegmentHours {
            out.append(Segment(term: .napCredit,
                               startFraction: (cursorHours - napHours) / axisHours,
                               widthFraction: napHours / axisHours))
        }
        return out
    }

    /// Where "Tonight's need" actually lands on the axis (post-nap and
    /// post-clamp — the exact `totalHours` the plan card consumes).
    static func netFraction(for components: AtriaSleepBudget.NeedComponents) -> Double {
        min(max(components.totalHours / axisHours, 0), 1)
    }

    /// End of the positive stack; the net tick only draws when it differs
    /// from this (a nap or the clamp moved the total off the stack end).
    static func grossFraction(for components: AtriaSleepBudget.NeedComponents) -> Double {
        let gross = components.baseHours + components.strainAdderHours + components.debtAdderHours
        return min(max(gross / axisHours, 0), 1)
    }

    /// Design axis labels: 0h · 4h · 8h · 10h.
    static let axisTicks: [(fraction: Double, label: String)] = [
        (0.0, "0h"), (0.4, "4h"), (0.8, "8h"), (1.0, "10h")
    ]

    /// "+27m" / "−18m" / "0m" legend values — real minutes of the term.
    static func minutesText(hours: Double, sign: String) -> String {
        let minutes = Int((max(0, hours) * 60).rounded())
        guard minutes > 0 else { return "0m" }
        return "\(sign)\(minutes)m"
    }

    /// ITEM-2 2026-08-15: one-line receipt itemization for the plan card —
    /// "8 h base +37m strain +86m debt −45m naps" (zero adders dropped,
    /// base always shown; the clamp is disclosed by the caller via
    /// isClamped).
    static func componentsSummaryText(for components: AtriaSleepBudget.NeedComponents) -> String {
        var parts = ["\(AtriaMetricFormat.sleepHours(components.baseHours)) base"]
        if components.strainAdderHours >= minimumSegmentHours {
            parts.append("\(minutesText(hours: components.strainAdderHours, sign: "+")) strain")
        }
        if components.debtAdderHours >= minimumSegmentHours {
            parts.append("\(minutesText(hours: components.debtAdderHours, sign: "+")) debt")
        }
        if components.napCreditHours >= minimumSegmentHours {
            parts.append("\(minutesText(hours: components.napCreditHours, sign: "\u{2212}")) naps")
        }
        return parts.joined(separator: " ")
    }
}

/// 2026-08-29 minimalism pass: the seven unrelated section-6 hexes reduce to
/// one ramp of the sleep theme hue (`Metrics.electricSleep` at stepped
/// opacities) plus a single warning tone for debt. The stacked-bar SEGMENTS
/// stay visually distinct (data encoding — opacity steps + the nap hatch),
/// but the card no longer introduces identity hues of its own.
enum AtriaSleepLedgerPalette {
    static let baseline = Metrics.electricSleep
    static let strain = Metrics.electricSleep.opacity(0.55)
    static let debt = Color(red: 1.0, green: 0.271, blue: 0.227)         // warning tone
    static let napCredit = Metrics.electricSleep.opacity(0.30)
    static let slept = Metrics.electricSleep
    /// The dashed "needed" line in the 7-night chart — the same theme hue,
    /// stepped down so the two series separate without a second identity hue.
    static let needed = Metrics.electricSleep.opacity(0.5)

    static func fill(for term: AtriaSleepNeedLedgerPresentation.Term) -> Color {
        switch term {
        case .baseline: return baseline
        case .strain: return strain
        case .debt: return debt
        case .napCredit: return napCredit
        }
    }
}

/// 45° hatch for the nap-credit (negative) segment — design spec: repeating
/// 45deg stripes every 4px.
struct AtriaHatchedFill: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 4
            var x = -size.height
            while x < size.width {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(stripe, with: .color(tint), lineWidth: 1.2)
                x += step
            }
        }
    }
}

/// "How we got <total>" itemized need card (design 6a). The components are
/// the real `AtriaSleepBudget.NeedComponents` — the exact number the plan
/// card and last night's performance both consume.
struct AtriaSleepNeedLedgerCard: View {
    let components: AtriaSleepBudget.NeedComponents
    /// Real strain of the prior day when known — names the strain row.
    let yesterdayStrain: Double?
    /// ITEM-2 2026-08-15: this card shows the SHOWN night's need — for a
    /// settled night that is the frozen receipt, not tonight's target.
    var isFrozenReceipt: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            // "How we got 8h 10m" read as a sleep-stage/onset breakdown and so
            // looked hardcoded/broken (2026-08-08 field report). This is the
            // sleep-NEED ledger (baseline + strain + debt − nap credit), all
            // computed — name it so it can't be mistaken for stages.
            // ITEM-2 2026-08-15: "Tonight's" was dishonest for a settled
            // night — these are that night's frozen components.
            Text("This night's sleep need · \(AtriaMetricFormat.sleepHours(components.totalHours))")
                .font(.headline.weight(.semibold))

            stackedBar
            axisRow

            // 2026-08-29 minimalism pass: value text reads neutral — the
            // swatch beside each row already keys it to its bar segment.
            legendRow(term: .baseline,
                      name: "Baseline need",
                      value: AtriaMetricFormat.sleepHours(components.baseHours))
            legendRow(term: .strain,
                      name: yesterdayStrain.map { "Yesterday's strain \(AtriaMetricFormat.strain($0))" }
                          ?? "Recent strain",
                      value: AtriaSleepNeedLedgerPresentation.minutesText(hours: components.strainAdderHours, sign: "+"))
            legendRow(term: .debt,
                      name: "Recent sleep debt",
                      value: AtriaSleepNeedLedgerPresentation.minutesText(hours: components.debtAdderHours, sign: "+"))
            legendRow(term: .napCredit,
                      name: "Nap credit",
                      value: AtriaSleepNeedLedgerPresentation.minutesText(hours: components.napCreditHours, sign: "\u{2212}"))

            Divider()

            HStack {
                Text("This night's need")
                    .font(.subheadline.weight(.bold))
                Spacer(minLength: AtriaDesignTokens.Spacing.sm)
                Text(AtriaMetricFormat.sleepHours(components.totalHours))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Metrics.electricSleep)
            }

            if components.isClamped {
                Text("Capped to the 6\u{2013}10h range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 2026-08-29 minimalism pass: one sentence — the provenance claim
            // stays, the cross-reference elaboration goes.
            Text(isFrozenReceipt
                 ? "Frozen when this night was saved."
                 : "Provisional until this night is saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Bar

    private var stackedBar: some View {
        let segments = AtriaSleepNeedLedgerPresentation.segments(for: components)
        let netFraction = AtriaSleepNeedLedgerPresentation.netFraction(for: components)
        let grossFraction = AtriaSleepNeedLedgerPresentation.grossFraction(for: components)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                        .frame(width: max(2, proxy.size.width * segment.widthFraction))
                        .offset(x: proxy.size.width * segment.startFraction)
                }
                // "Tonight's need" tick — only when a nap or the clamp moved
                // the net total off the end of the positive stack.
                if abs(netFraction - grossFraction) * AtriaSleepNeedLedgerPresentation.axisHours
                    >= AtriaSleepNeedLedgerPresentation.minimumSegmentHours {
                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 1.5)
                        .offset(x: proxy.size.width * netFraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 26)
    }

    @ViewBuilder
    private func segmentView(_ segment: AtriaSleepNeedLedgerPresentation.Segment) -> some View {
        let tint = AtriaSleepLedgerPalette.fill(for: segment.term)
        if segment.term == .napCredit {
            ZStack {
                Rectangle().fill(tint.opacity(0.16))
                AtriaHatchedFill(tint: tint.opacity(0.85))
            }
        } else {
            Rectangle().fill(tint.opacity(0.85))
        }
    }

    private var axisRow: some View {
        GeometryReader { proxy in
            ForEach(AtriaSleepNeedLedgerPresentation.axisTicks, id: \.label) { tick in
                Text(tick.label)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(proxy.size.width * tick.fraction, 10),
                                     proxy.size.width - 12),
                              y: proxy.size.height / 2)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func legendRow(term: AtriaSleepNeedLedgerPresentation.Term,
                           name: String,
                           value: String) -> some View {
        HStack(spacing: AtriaDesignTokens.Spacing.sm) {
            swatch(for: term)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private func swatch(for term: AtriaSleepNeedLedgerPresentation.Term) -> some View {
        let tint = AtriaSleepLedgerPalette.fill(for: term)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(term == .napCredit ? tint.opacity(0.18) : tint.opacity(0.85))
            .overlay {
                if term == .napCredit {
                    AtriaHatchedFill(tint: tint.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .frame(width: 10, height: 10)
    }

    private var accessibilityText: String {
        var parts = ["Sleep need ledger.",
                     "Baseline need \(AtriaMetricFormat.sleepHours(components.baseHours))."]
        parts.append("Recent strain adds \(AtriaSleepNeedLedgerPresentation.minutesText(hours: components.strainAdderHours, sign: "")).")
        parts.append("Sleep debt adds \(AtriaSleepNeedLedgerPresentation.minutesText(hours: components.debtAdderHours, sign: "")).")
        parts.append("Nap credit removes \(AtriaSleepNeedLedgerPresentation.minutesText(hours: components.napCreditHours, sign: "")).")
        parts.append("This night's need \(AtriaMetricFormat.sleepHours(components.totalHours)).")
        return parts.joined(separator: " ")
    }
}

/// Pure night-slot selection for the 7-night need-vs-slept chart,
/// unit-testable without SwiftUI.
enum AtriaSleepDebtChartPresentation {
    static let slotCount = 7
    static let minimumRealNights = 3

    struct NightSlot: Equatable {
        let day: Date
        let dayLetter: String
        /// nil = no confirmed main sleep that morning — renders as an empty
        /// slot with a subtle mark, never a fabricated bar.
        let sleptHours: Double?
        /// nil means this historical night predates frozen adaptive need. The
        /// chart must leave that node absent instead of rebuilding it from the
        /// wearer's current baseline.
        let needHours: Double?

        var shortfall: Bool {
            guard let sleptHours, let needHours else { return false }
            return sleptHours < needHours
        }
    }

    /// One requested 7-night window, anchored to the newest confirmed morning
    /// and movable backwards in whole weeks. Need per slot is the clamped base
    /// need — the exact per-night need `AtriaSleepBudget.sleepDebt` itself
    /// scores against, so the chart can never disagree with the ledger.
    static func slots(nights: [SleepHistorySnapshot.Night],
                      frozenNeedSecondsByDay: [Date: TimeInterval],
                      weekOffset: Int = 0,
                      calendar: Calendar = .current) -> [NightSlot] {
        let confirmed = nights.filter { $0.confirmed && !$0.isNapEvidence }
        guard let newestDay = confirmed.map({ calendar.startOfDay(for: $0.day) }).max(),
              let windowEnd = calendar.date(byAdding: .day,
                                             value: min(weekOffset, 0) * slotCount,
                                             to: newestDay) else {
            return []
        }
        return (0..<slotCount).reversed().compactMap { daysBack in
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: windowEnd) else {
                return nil
            }
            // Two confirmed main sleeps on one morning is a rare edit
            // artifact; show the longer one rather than a summed fiction.
            let slept = confirmed
                .filter { calendar.isDate($0.day, inSameDayAs: day) }
                .map(\.durationHours)
                .max()
            return NightSlot(day: day,
                             dayLetter: dayLetter(for: day, calendar: calendar),
                             sleptHours: slept,
                             needHours: frozenNeedSecondsByDay[calendar.startOfDay(for: day)]
                                .flatMap { $0 > 0 ? $0 / 3_600 : nil })
        }
    }

    static func canNavigateToPreviousWeek(nights: [SleepHistorySnapshot.Night],
                                           weekOffset: Int,
                                           calendar: Calendar = .current) -> Bool {
        let confirmed = nights.filter { $0.confirmed && !$0.isNapEvidence }
        guard let newest = confirmed.map({ calendar.startOfDay(for: $0.day) }).max(),
              let oldest = confirmed.map({ calendar.startOfDay(for: $0.day) }).min(),
              let nextEnd = calendar.date(byAdding: .day,
                                          value: (min(weekOffset, 0) - 1) * slotCount,
                                          to: newest),
              let nextStart = calendar.date(byAdding: .day,
                                            value: -(slotCount - 1),
                                            to: nextEnd) else {
            return false
        }
        return nextStart >= oldest
    }

    static func realNightCount(_ slots: [NightSlot]) -> Int {
        slots.filter { $0.sleptHours != nil }.count
    }

    /// GAP-01 gap grammar: contiguous runs of slots that actually carry a
    /// value. The chart draws each run as its own line series, so a night
    /// without a frozen need (or without a confirmed sleep) breaks the line
    /// into a real gap instead of interpolating an invented segment across
    /// the missing night. Slots are consecutive mornings by construction, so
    /// index adjacency is day adjacency.
    static func valueRuns(_ slots: [NightSlot],
                          value: (NightSlot) -> Double?) -> [[(day: Date, hours: Double)]] {
        var runs: [[(day: Date, hours: Double)]] = []
        var current: [(day: Date, hours: Double)] = []
        for slot in slots {
            if let hours = value(slot) {
                current.append((day: slot.day, hours: hours))
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func dayLetter(for day: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }

    /// Debt as it stood one week before the newest night — the same
    /// recency-weighted `AtriaSleepBudget.sleepDebt` over the 7 most recent
    /// confirmed nights at that cutoff. nil while fewer than 3 nights existed
    /// back then, so the delta line never compares against a guess.
    static func weekAgoDebtHours(nights: [SleepHistorySnapshot.Night],
                                 baseNeedHours: Double,
                                 calendar: Calendar = .current) -> Double? {
        let confirmed = nights.filter { $0.confirmed && !$0.isNapEvidence }
        guard let newestDay = confirmed.map({ calendar.startOfDay(for: $0.day) }).max(),
              let cutoff = calendar.date(byAdding: .day, value: -7, to: newestDay) else {
            return nil
        }
        let past = confirmed
            .filter { calendar.startOfDay(for: $0.day) <= cutoff }
            .sorted { $0.day > $1.day }
            .prefix(7)
        guard past.count >= minimumRealNights else { return nil }
        let need = min(max(baseNeedHours, 6), 10)
        let oldestFirst = past.reversed().map { (needed: need, slept: $0.durationHours) }
        return AtriaSleepBudget.sleepDebt(nights: oldestFirst)
    }

    /// "Down 24m from last week" — only when the week-ago debt is real.
    static func weekDeltaText(currentDebtHours: Double,
                              weekAgoDebtHours: Double?) -> String? {
        guard let weekAgoDebtHours else { return nil }
        let deltaMinutes = Int(((currentDebtHours - weekAgoDebtHours) * 60).rounded())
        if abs(deltaMinutes) < 5 { return "About even with last week" }
        return deltaMinutes < 0
            ? "Down \(-deltaMinutes)m from last week"
            : "Up \(deltaMinutes)m from last week"
    }
}

/// 7-night need-vs-slept debt card (design 6b). Fed by real slots and the
/// real recency-weighted debt only.
struct AtriaSleepDebtChartCard: View {
    let nights: [SleepHistorySnapshot.Night]
    let rollups: [DailyRollupStoreEntry]
    @State private var weekOffset = 0

    init(nights: [SleepHistorySnapshot.Night],
         rollups: [DailyRollupStoreEntry] = []) {
        self.nights = nights
        self.rollups = rollups
    }

    private var frozenNeedSecondsByDay: [Date: TimeInterval] {
        var byDay: [Date: TimeInterval] = [:]
        // Prefer each night's own frozen need — the exact value the sleep-need
        // ledger, Sufficiency, and day history read (Night.frozenSleepNeed) — so
        // this chart shows the identical number on every surface, even when no
        // rollups are threaded in.
        for night in nights {
            guard let need = night.sleepNeedSeconds, need > 0 else { continue }
            byDay[Calendar.current.startOfDay(for: night.day)] = need
        }
        // Fall back to a rollup's frozen need only for a day no night froze one,
        // never overwriting a night's own frozen value with the parallel receipt.
        for rollup in rollups {
            guard let need = rollup.sleepNeedSeconds, need > 0 else { continue }
            let day = Calendar.current.startOfDay(for: rollup.day)
            if byDay[day] == nil { byDay[day] = need }
        }
        return byDay
    }

    private var slots: [AtriaSleepDebtChartPresentation.NightSlot] {
        AtriaSleepDebtChartPresentation.slots(nights: nights,
                                              frozenNeedSecondsByDay: frozenNeedSecondsByDay,
                                              weekOffset: weekOffset)
    }

    private var realNightCount: Int {
        AtriaSleepDebtChartPresentation.realNightCount(slots)
    }

    private var needPointCount: Int {
        slots.compactMap(\.needHours).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .center, spacing: 8) {
                Text("Hours vs. need")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    weekOffset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!canNavigateToPreviousWeek)
                .foregroundStyle(canNavigateToPreviousWeek ? .primary : .tertiary)
                .accessibilityLabel("Previous sleep week")

                Text(weekTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70)

                Button {
                    weekOffset = min(weekOffset + 1, 0)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(weekOffset == 0)
                .foregroundStyle(weekOffset == 0 ? .tertiary : .primary)
                .accessibilityLabel("Next sleep week")
            }

            if realNightCount < AtriaSleepDebtChartPresentation.minimumRealNights {
                buildingState
            } else {
                hoursVsNeedChart
                dualLineLegend
                // 2026-08-29 minimalism pass: one sentence per variant — the
                // never-rebuilt honesty claim survives, elaboration goes.
                Text(needPointCount == 0
                     ? "Sleep Need appears for nights frozen with the adaptive calculation; older history stays blank, never rebuilt."
                     : "Each Sleep Need point is the target frozen for that night; missing targets stay blank.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var canNavigateToPreviousWeek: Bool {
        AtriaSleepDebtChartPresentation.canNavigateToPreviousWeek(nights: nights,
                                                                   weekOffset: weekOffset)
    }

    private var weekTitle: String {
        guard let first = slots.first?.day, let last = slots.last?.day else { return "No nights" }
        if Calendar.current.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(first.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.day()))"
        }
        return "\(first.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    // MARK: - Building

    private var buildingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debt chart building")
                .font(.caption.weight(.semibold))
            // 2026-08-29 minimalism pass: one sentence keeps the real-nights-
            // only honesty claim.
            Text("Needs \(AtriaSleepDebtChartPresentation.minimumRealNights) confirmed nights — \(realNightCount) so far; nothing is filled in for you.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hoursVsNeedChart: some View {
        let slept = slots.compactMap { slot in
            slot.sleptHours.map { (day: slot.day, hours: $0) }
        }
        let needed = slots.compactMap { slot in
            slot.needHours.map { (day: slot.day, hours: $0) }
        }
        let allHours = slept.map(\.hours) + needed.map(\.hours)
        let highest = allHours.max() ?? 8
        let lowest = allHours.min() ?? 7
        let lowerBound = max(0, floor(lowest - 0.75))
        let upperBound = ceil(highest + 0.75)

        // GAP-01 gap grammar: one line series per contiguous run, so a night
        // missing its frozen need (or missing a confirmed sleep) renders as a
        // real break — never an interpolated segment across the gap.
        let neededRuns = AtriaSleepDebtChartPresentation.valueRuns(slots, value: \.needHours)
        let sleptRuns = AtriaSleepDebtChartPresentation.valueRuns(slots, value: \.sleptHours)

        return Chart {
            ForEach(Array(neededRuns.enumerated()), id: \.offset) { runIndex, run in
                ForEach(run, id: \.day) { point in
                    LineMark(x: .value("Morning", point.day), y: .value("Sleep needed", point.hours), series: .value("Series", "Sleep needed \(runIndex)"))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2,
                                               lineCap: .round,
                                               lineJoin: .round,
                                               dash: [4, 3]))
                        .foregroundStyle(AtriaSleepLedgerPalette.needed)
                    PointMark(x: .value("Morning", point.day), y: .value("Sleep needed", point.hours))
                        .symbol(Circle())
                        .symbolSize(44)
                        .foregroundStyle(AtriaSleepLedgerPalette.needed)
                }
            }
            ForEach(Array(sleptRuns.enumerated()), id: \.offset) { runIndex, run in
                ForEach(run, id: \.day) { point in
                    LineMark(x: .value("Morning", point.day), y: .value("Hours slept", point.hours), series: .value("Series", "Hours slept \(runIndex)"))
                        .interpolationMethod(.monotone)
                        .lineStyle(AtriaChartVisualGrammar.trendLine)
                        .foregroundStyle(AtriaSleepLedgerPalette.slept)
                    PointMark(x: .value("Morning", point.day), y: .value("Hours slept", point.hours))
                        .symbol(Circle())
                        .symbolSize(58)
                        .foregroundStyle(AtriaSleepLedgerPalette.slept)
                        .annotation(position: point.hours >= (needed.first(where: { $0.day == point.day })?.hours ?? point.hours) ? .top : .bottom, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(AtriaMetricFormat.sleepHours(point.hours))
                                .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(AtriaSleepLedgerPalette.slept)
                        }
                }
            }
        }
        .atriaGraphPlotSurface()
        .chartYScale(domain: lowerBound...upperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let value = value.as(Double.self) {
                        Text(AtriaMetricFormat.sleepHours(value))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: slots.map(\.day)) { value in
                AxisTick().foregroundStyle(.clear)
                AxisValueLabel {
                    if let day = value.as(Date.self) {
                        VStack(spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                            Text(day.formatted(.dateTime.day()))
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 172)
        .padding(.trailing, 8)
    }

    private var dualLineLegend: some View {
        HStack(spacing: 14) {
            Label("Hours slept", systemImage: "circle")
                .foregroundStyle(AtriaSleepLedgerPalette.slept)
            Label("Sleep needed", systemImage: "circle.dashed")
                .foregroundStyle(AtriaSleepLedgerPalette.needed)
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
    }

    private var accessibilityText: String {
        guard realNightCount >= AtriaSleepDebtChartPresentation.minimumRealNights else {
            return "Hours versus sleep need chart building. Needs \(AtriaSleepDebtChartPresentation.minimumRealNights) confirmed nights, \(realNightCount) so far."
        }
        return "Hours versus sleep need for \(weekTitle). \(realNightCount) of 7 mornings have confirmed sleep."
    }
}

/// GAP-06 — the provisional composite Sleep Score, presented with its
/// components always visible and its provisional state stated outright. It never
/// implies a validated four-component score, and never hides a missing
/// component behind a filled number.
struct AtriaSleepScoreCard: View {
    let score: AtriaSleepScore

    /// 2026-08-29 minimalism pass: overnight load is excluded from the
    /// composite until its model validates, so the card shows only the three
    /// scoring components — the exclusion is disclosed in the caption instead
    /// of an extra "Needs more evidence" row.
    private var shownComponents: [AtriaSleepScore.ComponentValue] {
        score.components.filter { $0.component != .overnightLoad }
    }

    private func valueText(_ component: AtriaSleepScore.ComponentValue) -> String {
        if let percent = component.percent { return "\(Int(percent.rounded()))%" }
        return "Not yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep Score")
                        .font(.subheadline.weight(.bold))
                    // 2026-08-29 minimalism pass: neutral capsule, secondary
                    // text — the provisional claim, without an alarm hue.
                    Text("Early estimate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AtriaDesignTokens.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06),
                                    in: Capsule(style: .continuous))
                        .accessibilityLabel("Early sleep score estimate")
                }
                Spacer(minLength: AtriaDesignTokens.Spacing.sm)
                if let value = score.score {
                    Text("\(value)")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Metrics.electricSleep)
                }
            }

            VStack(spacing: 6) {
                ForEach(shownComponents, id: \.component) { component in
                    HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                        Text(component.component.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(component.isPresent ? .primary : .secondary)
                        Spacer(minLength: 4)
                        Text(valueText(component))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(component.isPresent ? .primary : .secondary)
                    }
                }
            }

            // 2026-08-29 minimalism pass: one sentence per variant — the
            // provisional/unvalidated honesty claims survive, prose goes.
            Text(score.score == nil
                 ? "Not enough qualified components yet — Sleep Sufficiency remains your primary measure."
                 : "Provisional composite — weights unvalidated, overnight load excluded until its model validates; Sleep Sufficiency stays the hours-versus-need measure.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricSleep)
        .accessibilityElement(children: .combine)
    }
}
