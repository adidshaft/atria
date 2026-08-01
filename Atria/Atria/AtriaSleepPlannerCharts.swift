import SwiftUI

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
}

/// Section-6 hues from the design file (dark-first, same exact-hex idiom as
/// the hypnogram card's stage table).
enum AtriaSleepLedgerPalette {
    static let baseline = Color(red: 0.369, green: 0.361, blue: 0.902)   // #5E5CE6
    static let strain = Color(red: 1.0, green: 0.624, blue: 0.039)       // #FF9F0A
    static let debt = Color(red: 1.0, green: 0.271, blue: 0.227)         // #FF453A
    static let napCredit = Color(red: 0.494, green: 0.886, blue: 0.604)  // #7EE29A
    static let slept = Color(red: 0.039, green: 0.518, blue: 1.0)        // #0A84FF
    static let strainValue = Color(red: 1.0, green: 0.776, blue: 0.439)  // #FFC670
    static let debtValue = Color(red: 1.0, green: 0.541, blue: 0.502)    // #FF8A80

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

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            Text("How we got \(AtriaMetricFormat.sleepHours(components.totalHours))")
                .font(.headline.weight(.semibold))

            stackedBar
            axisRow

            legendRow(term: .baseline,
                      name: "Baseline need",
                      value: AtriaMetricFormat.sleepHours(components.baseHours),
                      valueTint: .primary)
            legendRow(term: .strain,
                      name: yesterdayStrain.map { "Yesterday's strain \(AtriaMetricFormat.strain($0))" }
                          ?? "Recent strain",
                      value: AtriaSleepNeedLedgerPresentation.minutesText(hours: components.strainAdderHours, sign: "+"),
                      valueTint: components.strainAdderHours >= AtriaSleepNeedLedgerPresentation.minimumSegmentHours
                          ? AtriaSleepLedgerPalette.strainValue : .secondary)
            legendRow(term: .debt,
                      name: "Recent sleep debt",
                      value: AtriaSleepNeedLedgerPresentation.minutesText(hours: components.debtAdderHours, sign: "+"),
                      valueTint: components.debtAdderHours >= AtriaSleepNeedLedgerPresentation.minimumSegmentHours
                          ? AtriaSleepLedgerPalette.debtValue : .secondary)
            legendRow(term: .napCredit,
                      name: "Nap credit",
                      value: AtriaSleepNeedLedgerPresentation.minutesText(hours: components.napCreditHours, sign: "\u{2212}"),
                      valueTint: components.napCreditHours >= AtriaSleepNeedLedgerPresentation.minimumSegmentHours
                          ? AtriaSleepLedgerPalette.napCredit : .secondary)

            Divider()

            HStack {
                Text("Tonight's need")
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
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
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
                           value: String,
                           valueTint: Color) -> some View {
        HStack(spacing: AtriaDesignTokens.Spacing.sm) {
            swatch(for: term)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueTint)
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
        parts.append("Tonight's need \(AtriaMetricFormat.sleepHours(components.totalHours)).")
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
        let needHours: Double

        var shortfall: Bool {
            guard let sleptHours else { return false }
            return sleptHours < needHours
        }
    }

    /// The last 7 civil mornings ending at the newest confirmed main sleep's
    /// wake day. Need per slot is the clamped base need — the exact per-night
    /// need `AtriaSleepBudget.sleepDebt` itself scores against, so the bars
    /// and the carried-debt hero can never disagree about the target.
    static func slots(nights: [SleepHistorySnapshot.Night],
                      baseNeedHours: Double,
                      calendar: Calendar = .current) -> [NightSlot] {
        let confirmed = nights.filter { $0.confirmed && !$0.isNapEvidence }
        guard let newestDay = confirmed.map({ calendar.startOfDay(for: $0.day) }).max() else {
            return []
        }
        let need = min(max(baseNeedHours, 6), 10)
        return (0..<slotCount).reversed().compactMap { daysBack in
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: newestDay) else {
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
                             needHours: need)
        }
    }

    static func realNightCount(_ slots: [NightSlot]) -> Int {
        slots.filter { $0.sleptHours != nil }.count
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
    let slots: [AtriaSleepDebtChartPresentation.NightSlot]
    let carriedDebtHours: Double
    let weekDeltaText: String?
    /// Real performance percent of the latest confirmed night, nil while
    /// unknown — the ring simply stays away rather than guessing.
    let fulfilledLastNightPercent: Int?
    let baseNeedHours: Double

    private var realNightCount: Int {
        AtriaSleepDebtChartPresentation.realNightCount(slots)
    }

    private var clampedNeedHours: Double {
        min(max(baseNeedHours, 6), 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sleep debt")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("Last 7 nights · recency-weighted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if realNightCount < AtriaSleepDebtChartPresentation.minimumRealNights {
                buildingState
            } else {
                heroRow
                pairedBars
                dayLetterRow
                legendRow
                Text("Need here is your base need (\(AtriaMetricFormat.sleepHours(clampedNeedHours))) — the same per-night target the debt math scores against. Shortfall nights show amber; mornings without confirmed sleep stay empty.")
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

    // MARK: - Building

    private var buildingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debt chart building")
                .font(.caption.weight(.semibold))
            Text("Needs \(AtriaSleepDebtChartPresentation.minimumRealNights) confirmed nights — \(realNightCount) so far. Real nights only; nothing is filled in for you.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Hero

    private var debtText: String {
        carriedDebtHours > 0.05
            ? SleepHistorySnapshot.formatDuration(carriedDebtHours * 3_600)
            : "0m"
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: AtriaDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Carried debt")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(debtText)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(carriedDebtHours > 0.05
                                     ? AtriaSleepLedgerPalette.debtValue
                                     : Metrics.electricGreen)
                if let weekDeltaText {
                    Text(weekDeltaText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let fulfilledLastNightPercent {
                fulfilledRing(percent: fulfilledLastNightPercent)
            }
        }
    }

    private func fulfilledRing(percent: Int) -> some View {
        let fraction = min(max(Double(percent) / 100, 0), 1)
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AtriaSleepLedgerPalette.slept,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)%")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            }
            .frame(width: 52, height: 52)
            Text("last night")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bars

    private var barScaleHours: Double {
        let tallest = slots.reduce(clampedNeedHours) { max($0, $1.sleptHours ?? 0) }
        return tallest + 0.5
    }

    private var pairedBars: some View {
        let scale = barScaleHours
        return HStack(alignment: .bottom, spacing: AtriaDesignTokens.Spacing.sm) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                ZStack(alignment: .bottom) {
                    // Need track — translucent, full slot width.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: Self.chartHeight * slot.needHours / scale)
                    if let sleptHours = slot.sleptHours {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(slot.shortfall
                                  ? AtriaSleepLedgerPalette.strain
                                  : AtriaSleepLedgerPalette.slept)
                            .frame(height: max(3, Self.chartHeight * sleptHours / scale))
                            .padding(.horizontal, 3)
                    } else {
                        // No confirmed sleep that morning — subtle mark only.
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.14))
                            .frame(height: 3)
                            .padding(.horizontal, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: Self.chartHeight, alignment: .bottom)
    }

    private var dayLetterRow: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.sm) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                Text(slot.dayLetter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(slot.shortfall
                                     ? AtriaSleepLedgerPalette.strain
                                     : Color.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var legendRow: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.md) {
            legendSwatch(fill: AnyShapeStyle(AtriaSleepLedgerPalette.slept), label: "Slept")
            legendSwatch(fill: AnyShapeStyle(Color.primary.opacity(0.10)), label: "Need")
            legendSwatch(fill: AnyShapeStyle(AtriaSleepLedgerPalette.strain), label: "Shortfall")
            Spacer(minLength: 0)
        }
    }

    private func legendSwatch(fill: AnyShapeStyle, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fill)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        guard realNightCount >= AtriaSleepDebtChartPresentation.minimumRealNights else {
            return "Sleep debt chart building. Needs \(AtriaSleepDebtChartPresentation.minimumRealNights) confirmed nights, \(realNightCount) so far."
        }
        var parts = ["Sleep debt over the last 7 nights.",
                     "Carried debt \(debtText)."]
        if let weekDeltaText { parts.append("\(weekDeltaText).") }
        if let fulfilledLastNightPercent {
            parts.append("Fulfilled \(fulfilledLastNightPercent) percent of need last night.")
        }
        parts.append("\(realNightCount) of 7 mornings have confirmed sleep.")
        return parts.joined(separator: " ")
    }

    private static let chartHeight: CGFloat = 120
}
