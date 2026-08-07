import SwiftUI
import UIKit

struct AtriaTriRingMetric: Equatable {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    /// Single coherent identity hue for this metric -- paints the ring
    /// track, the ring fill, the legend-chip icon, the legend-chip value,
    /// and the matching glance tile. Color-coherence pass (2026-07-05): one
    /// hue per metric, everywhere, so the ring never disagrees with the
    /// number underneath it. Zone/state (under/optimal/over) is carried
    /// separately by `stateTint` below, never by swapping this hue.
    let tint: Color
    let fill: Double?
    /// Under/optimal/over ZONE color for the small legend dot and the radial
    /// target marker only -- never routed to the fill/track hue. Nil means
    /// "no zone dot" (the identity hue already carries the meaning, e.g.
    /// recovery, whose hue IS its 0-100 grade, or HRV/RHR, which only have a
    /// personal-baseline ratio, not a zone).
    var stateTint: Color? = nil
    /// Fractional position (0...1, same 0-at-top/clockwise scale `fill`
    /// sweeps) of a REAL target/recommendation to notch onto the ring -- e.g.
    /// the coach's recovery-derived strain target, or "sleep need met" at
    /// 1.0. Nil -- and no marker drawn -- whenever there isn't a real target
    /// to honestly show (never fabricated).
    var targetFraction: Double? = nil
    /// True when the ring center already shows this metric's value — the
    /// chip then renders title + detail only (dedup audit 2026-07-07: the
    /// big center numeral repeated verbatim in its own legend chip).
    var suppressesValue: Bool = false
    /// True when the ring center's caption already says exactly what this
    /// chip's detail would say. `suppressesValue` deduped the numeral but not
    /// the line under it, so a learning hero rendered "Learning / Save sleep
    /// to score" in 44pt type with "Recovery / Save sleep to score" repeating
    /// it 40pt below (dedup audit 2026-07-27). The chip keeps its title,
    /// which is what makes it a usable ring selector.
    var suppressesDetail: Bool = false
}

/// Pure ring math shared by Today and Overview. Actual strain owns the arc;
/// achievement and target markers exist only when a real target exists.
enum AtriaRingMetricProjection {
    static let neutralTintHex = "#8c929e"
    static let strainIdentityTintHex = "#0093e7"

    static func strainFill(strain: Double, isPending: Bool = false) -> Double? {
        guard !isPending, strain.isFinite else { return nil }
        return min(max(strain / 21, 0), 1)
    }

    static func strainTargetProgress(strain: Double, target: Double?) -> Double? {
        guard strain.isFinite, let target, target.isFinite, target > 0 else { return nil }
        return min(max(strain / target, 0), 1.2)
    }

    static func strainTargetFraction(_ target: Double?) -> Double? {
        guard let target, target.isFinite, target > 0 else { return nil }
        return min(max(target / 21, 0), 1)
    }

    static func achievementTintHex(fill: Double?) -> String {
        guard let fill, fill.isFinite else { return neutralTintHex }
        if fill >= 1 { return "#42f59b" }
        if fill >= 0.6 { return "#f5d142" }
        return "#ff8a3d"
    }

    /// A measured strain remains a real metric even before Recovery can mint a
    /// personalized target. In that state the arc uses strain's identity blue;
    /// only the target-relative achievement hue is unavailable. Returning the
    /// neutral tint for a numeric value made the ring look missing alongside a
    /// legitimately unavailable Recovery score.
    static func strainTint(targetProgress: Double?, actualFill: Double?) -> Color {
        guard let actualFill, actualFill.isFinite else { return .secondary }
        guard targetProgress != nil else { return Metrics.electricStrain }
        return Metrics.ringAchievementTint(fill: targetProgress)
    }

    static func strainTintHex(targetProgress: Double?, actualFill: Double?) -> String {
        guard let actualFill, actualFill.isFinite else { return neutralTintHex }
        guard targetProgress != nil else { return strainIdentityTintHex }
        return achievementTintHex(fill: targetProgress)
    }

    static func zoneTintHex(_ level: AtriaMetricZoneLevel?) -> String {
        switch level {
        case .green: return "#42f59b"
        case .yellow: return "#f5d142"
        case .red: return "#ff4f7b"
        case nil: return neutralTintHex
        }
    }

    static func sleepStateTintHex(percent: Double?) -> String? {
        guard let percent, percent.isFinite else { return nil }
        switch percent {
        case ..<70: return "#ff4f7b"
        case 70..<85: return "#f5d142"
        case 85...110: return "#42f59b"
        default: return "#0093e7"
        }
    }

    static func higherIsBetterProgress(value: Int?,
                                       baseline: Int?,
                                       baselineIsTrusted: Bool,
                                       goalMultiplier: Double = 1.15) -> Double? {
        guard baselineIsTrusted,
              let value, value > 0,
              let baseline, baseline > 0,
              goalMultiplier.isFinite, goalMultiplier > 0 else { return nil }
        return min(max(Double(value) / (Double(baseline) * goalMultiplier), 0), 1.15)
    }

    static func lowerIsBetterProgress(value: Int?,
                                      baseline: Int?,
                                      baselineIsTrusted: Bool) -> Double? {
        guard baselineIsTrusted,
              let value, value > 0,
              let baseline, baseline > 0 else { return nil }
        return min(max(Double(baseline) / Double(value), 0), 1.15)
    }
}

/// Turns Recovery v2's fail-closed reason into concise user-facing evidence
/// guidance. A calibration countdown is not a substitute for this reason: the
/// score can be available provisionally before a trusted 14-night baseline,
/// while a missing current HRV/RHR/sleep input will remain unavailable no
/// matter which nominal "day" the UI shows.
enum AtriaRecoveryAvailabilityPresentation {
    static func detail(estimateDetail: String,
                       hrvBaselineSamples: Int,
                       restingBaselineSamples: Int) -> String {
        let normalized = estimateDetail.lowercased()
        if normalized.contains("need saved sleep") {
            return "Save sleep to score"
        }
        if normalized.contains("need a steady hrv") {
            return "Needs steady HRV"
        }
        if normalized.contains("need resting hr") {
            return "Needs resting HR"
        }
        if normalized.contains("rhr baseline") {
            return "RHR baseline \(max(0, restingBaselineSamples)) of \(PersonalBaseline.trustedMinimumSamples) days"
        }
        if normalized.contains("hrv baseline") {
            return "HRV baseline \(max(0, hrvBaselineSamples)) of \(PersonalBaseline.trustedMinimumSamples) nights"
        }
        if hrvBaselineSamples <= 0 && restingBaselineSamples <= 0 {
            return "Needs sleep, HRV & RHR"
        }
        return "Recovery evidence incomplete"
    }
}

/// Which ring band (outer/middle/inner) a slot draws on, AND -- since the
/// ring-metric-picker migration -- which of the five supported metrics a
/// slot can carry. A slot's position only decides paint/hit-test priority
/// (the way Apple Activity lets you re-prioritize which ring is biggest);
/// its metric assignment is independent and user-configurable.
enum AtriaTriRingSlot: String, CaseIterable, Equatable {
    case sleep, recovery, strain, hrv, rhr

    /// Original visual order: outer -> inner. Also the fixed trio the
    /// backward-compatible sleep/recovery/strain initializer below still
    /// assumes, and the fallback used to pad out any incomplete/legacy
    /// persisted slot list.
    static let defaultOrder: [AtriaTriRingSlot] = [.sleep, .recovery, .strain]

    var label: String {
        switch self {
        case .sleep: return "Sleep"
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .hrv: return "HRV"
        case .rhr: return "RHR"
        }
    }

    /// Compact, language-independent glance mark used only in the pinned
    /// Today summary. The full ring and VoiceOver continue to carry the
    /// metric name, so this can stay as the tiny emoji + number treatment the
    /// user requested without squeezing another label into the top-right rail.
    var compactEmoji: String {
        switch self {
        case .sleep: return "🌙"
        case .recovery: return "❤️"
        case .strain: return "🔥"
        case .hrv: return "📈"
        case .rhr: return "💓"
        }
    }
}

/// One ring position's fully-resolved content: which metric fills it. This
/// is the "slots array" `AtriaTriRing` was generalized to (ring-metric-
/// picker migration, coordinated with the IA-6.1 static-check pin update in
/// test_handoff_static_checks.py) -- each of the three ring positions can
/// now carry any of the five supported metrics, not just the original fixed
/// sleep/recovery/strain trio.
struct AtriaTriRingSlotContent: Equatable {
    let slot: AtriaTriRingSlot
    let metric: AtriaTriRingMetric
}

/// How the Today vitals rings are laid out — a user preference (Settings ->
/// Display). `concentric` is the default Apple-Activity-style nested rings;
/// `separate` is the WHOOP-style row of three side-by-side rings, each carrying
/// its own value and label. Persisted under `defaultsKey`; read live by
/// `AtriaTriRing` and the share card, so flipping it updates every ring surface
/// at once. Default `.concentric` keeps every existing call site unchanged.
enum AtriaRingLayoutStyle: String, CaseIterable, Equatable {
    case concentric
    case separate

    static let defaultsKey = "atria.home.ringLayoutStyle"

    var label: String {
        switch self {
        case .concentric: return "Concentric"
        case .separate: return "Separate"
        }
    }
}

/// Apple-Activity-style concentric progress rings, generalized to any of
/// five metrics (sleep/recovery/strain/hrv/rhr) per ring position.
///
/// HIG guidelines applied here (developer.apple.com/design/human-interface-guidelines):
/// - "Charting data": encode magnitude consistently -- equal stroke widths
///   and a constant gap between rings so relative size differences read as
///   real geometry, not incidental layout.
/// - "Progress indicators": a single frame must be legible without waiting
///   for animation to finish; the learning state uses a short static cap
///   rather than an empty ring so it never looks broken or stalled.
/// - "Materials" (Liquid Glass): glass/shadow should signal depth and
///   feedback, not decorate -- the arc's soft shadow reinforces which ring
///   is in front, and the legend chips sit on the card's existing glass
///   surface rather than adding a second competing material.
/// - Reduce Motion: the fill sweep is skipped entirely (values snap to
///   final state) when the system accessibility setting is on.
struct AtriaTriRing: View, Equatable {
    /// Canonical, ordered (outer -> inner) ring content, capped at 3.
    let slots: [AtriaTriRingSlotContent]
    let centerValue: String
    let centerState: String
    /// Which metric the center numeral describes ("Recovery", "Sleep", ...).
    /// The hero's "61% / Fair" read named its zone but not its metric
    /// (2026-08-01 ring-presentation fix); when neither the value nor the
    /// state line already says the name, a small caption states it. Nil keeps
    /// call sites that bake the name into `centerState` (onboarding, the
    /// customize preview) rendering exactly as before.
    var centerMetricName: String? = nil
    /// Tiny, honest delta vs. the prior day (e.g. "+4% vs yesterday").
    /// Nil -- and simply omitted -- whenever there isn't a real prior-day
    /// value to compare against.
    var centerDelta: String? = nil
    let accessibilitySummary: String
    /// Tap handler per slot. A slot with no entry is inert (used by the
    /// off-screen share-card render, where taps are never delivered).
    let actions: [AtriaTriRingSlot: () -> Void]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFills: [AtriaTriRingSlot: Double] = [:]
    /// User-selected layout (Settings). Default concentric keeps Home, the
    /// customize preview and the share card rendering exactly as before until
    /// the user opts into the WHOOP-style separate rings.
    @AtriaDefault(AtriaRingLayoutStyle.defaultsKey) private var ringLayoutRaw: String = "concentric"
    private var ringLayout: AtriaRingLayoutStyle { AtriaRingLayoutStyle(rawValue: ringLayoutRaw) ?? .concentric }

    init(slots: [AtriaTriRingSlotContent],
         centerValue: String,
         centerState: String,
         centerMetricName: String? = nil,
         centerDelta: String? = nil,
         accessibilitySummary: String,
         actions: [AtriaTriRingSlot: () -> Void]) {
        self.slots = Array(slots.prefix(3))
        self.centerValue = centerValue
        self.centerState = centerState
        self.centerMetricName = centerMetricName
        self.centerDelta = centerDelta
        self.accessibilitySummary = accessibilitySummary
        self.actions = actions
    }

    /// Backward-compatible fixed sleep/recovery/strain convenience, kept so
    /// pre-existing call sites that predate the ring-metric-picker work
    /// (AtriaOverviewSections, AtriaCustomizeSheet) keep compiling
    /// unchanged. Internally this just builds the same `slots` array the
    /// designated initializer above takes.
    init(sleep: AtriaTriRingMetric,
         recovery: AtriaTriRingMetric,
         strain: AtriaTriRingMetric,
         centerValue: String,
         centerState: String,
         centerMetricName: String? = nil,
         centerDelta: String? = nil,
         accessibilitySummary: String,
         ringOrder: [AtriaTriRingSlot] = AtriaTriRingSlot.defaultOrder,
         onSleep: @escaping () -> Void,
         onRecovery: @escaping () -> Void,
         onStrain: @escaping () -> Void) {
        var seen = Set<AtriaTriRingSlot>()
        var order = ringOrder.filter { AtriaTriRingSlot.defaultOrder.contains($0) && seen.insert($0).inserted }
        for slot in AtriaTriRingSlot.defaultOrder where !order.contains(slot) {
            order.append(slot)
        }
        func metric(for slot: AtriaTriRingSlot) -> AtriaTriRingMetric {
            switch slot {
            case .sleep: return sleep
            case .recovery: return recovery
            case .strain: return strain
            case .hrv, .rhr: return sleep // unreachable: `order` is filtered to the fixed trio above.
            }
        }
        self.init(slots: order.prefix(3).map { AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0)) },
                  centerValue: centerValue,
                  centerState: centerState,
                  centerMetricName: centerMetricName,
                  centerDelta: centerDelta,
                  accessibilitySummary: accessibilitySummary,
                  actions: [.sleep: onSleep, .recovery: onRecovery, .strain: onStrain])
    }

    static func == (lhs: AtriaTriRing, rhs: AtriaTriRing) -> Bool {
        lhs.slots == rhs.slots
            && lhs.centerValue == rhs.centerValue
            && lhs.centerState == rhs.centerState
            && lhs.centerMetricName == rhs.centerMetricName
            && lhs.centerDelta == rhs.centerDelta
            && lhs.accessibilitySummary == rhs.accessibilitySummary
    }

    /// Sleep performance is the one ring zone whose thresholds are intrinsic
    /// to its percent-of-need scale. Recovery and strain must go through
    /// `Metrics.recoveryZone` / `Metrics.strainZone` so edited targets apply.
    enum ZoneMetric {
        case sleep
    }

    /// Shared under/optimal/over color semantics -- deliberately independent
    /// of each metric's identity hue (`Metrics.electricSleep` purple,
    /// `Metrics.electricStrain` blue): this is about whether *this reading*
    /// is good, not which ring it lives on. `percent` is always "actual as a
    /// percent of the reference" (100 == exactly on target/need):
    /// - sleep: percent of sleep need (the same number `sleepPerformance`
    ///   already carries).
    static func zoneTint(_ metric: ZoneMetric, percent: Double) -> Color {
        switch metric {
        case .sleep:
            switch percent {
            case ..<70: return Metrics.electricRed
            case 70..<85: return Metrics.electricYellow
            case 85...110: return Metrics.electricGreen
            default: return Metrics.electricStrain // oversleep: cool blue-ish, not a warning color
            }
        }
    }

    // Even-gap concentric geometry: every ring shares the same stroke width;
    // each ring inward is exactly `lineWidth + gap` narrower (per side) than
    // the one outside it, so the empty space between any two adjacent rings
    // is identical.
    private static let outerDiameter: CGFloat = 226
    private static let lineWidth: CGFloat = 19
    private static let gap: CGFloat = 3
    // The innermost ring's clear hole is ~119pt across (outer 226, three 19pt
    // strokes + 3pt gaps: inner ring centerline 138, minus the 19pt stroke =
    // 119 clear). The old 136 clamp was WIDER than that hole, so the center
    // numeral's glyphs spilled onto the inner ring (esp. a tall value like a
    // big "67%" at the top of the stack). Keep the content inside the hole.
    private static let centerContentWidth: CGFloat = 116

    private static func diameter(at index: Int) -> CGFloat {
        outerDiameter - CGFloat(index) * (lineWidth + gap) * 2
    }

    /// Non-overlapping annulus for tap hit-testing, contiguous with its
    /// neighbors (the whole visible gap between two rings splits evenly
    /// between them) so every point under the rings routes to exactly one
    /// ring's action -- never none, never both.
    private static func hitRadii(at index: Int) -> (inner: CGFloat, outer: CGFloat) {
        let radius = diameter(at: index) / 2
        let pad = lineWidth / 2 + gap / 2
        return (max(0, radius - pad), radius + pad)
    }

    private func action(for slot: AtriaTriRingSlot) -> () -> Void {
        actions[slot] ?? {}
    }

    var body: some View {
        switch ringLayout {
        case .concentric: concentricBody
        case .separate: separateBody
        }
    }

    /// WHOOP-style row of three equal, side-by-side rings — each carries its own
    /// value and label (no shared center numeral). Same `slots` and tap actions
    /// as the concentric layout; only the arrangement differs. Ring size adapts
    /// to the available width so all three always fit, down to the narrowest
    /// iPhone. Reuses the tested `AtriaMetricRing` primitive (identity-hue arc,
    /// honest learning cap, numericText value).
    private var separateBody: some View {
        GeometryReader { geo in
            let count = max(1, slots.count)
            let spacing: CGFloat = 16
            let fit = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            // Smaller than the concentric hero (user feedback) and capped so the
            // three rings group toward the center rather than stretching edge to
            // edge.
            let ringSize = min(94, max(62, fit))
            HStack(spacing: spacing) {
                ForEach(slots, id: \.slot) { content in
                    Button(action: action(for: content.slot)) {
                        AtriaMetricRing(label: content.metric.title,
                                        value: content.metric.value,
                                        fraction: content.metric.fill,
                                        tint: content.metric.tint,
                                        size: ringSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(height: 128)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var concentricBody: some View {
        VStack(spacing: 14) {
            ZStack {
                if let recovery = slots.first(where: { $0.slot == .recovery })?.metric,
                   recovery.fill != nil,
                   actions[.recovery] != nil {
                    Circle()
                        .stroke(recovery.tint.opacity(0.22), lineWidth: 1.5)
                        .frame(width: Self.outerDiameter + 12, height: Self.outerDiameter + 12)
                        // Keep the overview quiescent after its one-time value
                        // reveal. A SwiftUI repeatForever halo kept the display
                        // link and async renderer awake indefinitely on the
                        // app's most common idle screen for decoration alone.
                        .opacity(0.28)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                // Visual layer: purely decorative rendering, in outer-to-inner
                // paint order so the front-most (smallest) ring's shadow reads
                // correctly against the ones behind it.
                ForEach(Array(slots.enumerated()), id: \.offset) { index, content in
                    ringVisual(metric: content.metric,
                              diameter: Self.diameter(at: index),
                              lineWidth: Self.lineWidth,
                              fill: animatedFills[content.slot] ?? 0)
                        .allowsHitTesting(false)
                }

                // Interaction layer: disjoint annulus hit targets, each sized
                // to the full hero canvas so a tap anywhere under a ring's
                // band -- including the shared gap -- resolves to exactly
                // that ring, regardless of paint order.
                ForEach(Array(slots.enumerated()), id: \.offset) { index, content in
                    let radii = Self.hitRadii(at: index)
                    Color.clear
                        .frame(width: Self.outerDiameter, height: Self.outerDiameter)
                        .contentShape(AtriaRingBandShape(innerRadius: radii.inner, outerRadius: radii.outer), eoFill: true)
                        .onTapGesture(perform: action(for: content.slot))
                }

                centerContent
                    .allowsHitTesting(false)
            }
            .frame(width: Self.outerDiameter, height: Self.outerDiameter)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)

            HStack(spacing: 8) {
                ForEach(slots, id: \.slot) { content in
                    legendChip(metric: content.metric, action: action(for: content.slot))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            animateToFinalValues()
        }
        .onChange(of: fillSignature) { _, _ in animateToFinalValues() }
    }

    /// Flattened fill snapshot (slot-order-stable since `slots` is fixed for
    /// the view's lifetime) used solely to detect "some fill value changed"
    /// for the re-animate trigger below.
    private var fillSignature: [Double] {
        slots.map { $0.metric.fill ?? -1 }
    }

    /// The caption renders only when neither existing center line already
    /// carries the metric's name — never a second statement of it.
    private var showsCenterMetricName: Bool {
        guard let centerMetricName, !centerMetricName.isEmpty else { return false }
        return !centerValue.localizedCaseInsensitiveContains(centerMetricName)
            && !centerState.localizedCaseInsensitiveContains(centerMetricName)
    }

    private var centerContent: some View {
        VStack(spacing: 1) {
            Text(centerValue)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText())
            if showsCenterMetricName, let centerMetricName {
                // Names WHICH metric the numeral describes ("61% / RECOVERY /
                // Fair" instead of the ambiguous "61% / Fair") — ring
                // presentation fix, 2026-08-01.
                Text(centerMetricName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(centerState)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let centerDelta {
                Text(centerDelta)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: Self.centerContentWidth)
    }

    /// One ring's decoration only (no gesture handling -- see the
    /// interaction layer in `body`): a faint full track, a rounded-cap
    /// gradient progress arc with a soft end shadow (Activity-rings look),
    /// and a bright overshoot marker on the rare metric (Strain) that can
    /// exceed its target.
    private func ringVisual(metric: AtriaTriRingMetric,
                            diameter: CGFloat,
                            lineWidth: CGFloat,
                            fill: Double) -> some View {
        // Color-coherence pass (2026-07-05): track AND fill both paint in the
        // metric's single identity hue (`tint`) -- the ring never disagrees
        // with the chip/tile underneath it. Zone/state (under/optimal/over)
        // is carried only by `stateTint`, applied to the small legend dot
        // and the radial target marker, never to the fill hue itself.
        return ZStack {
            // Awaiting-data honesty (2026-08-08): a metric with no fill used to
            // paint ONLY this 20%-opacity track, which on the dark hero reads as
            // "the ring isn't there" — the same state the separate layout shows
            // as a clearly present grey ring with its label. A dashed, brighter
            // track says "this ring exists and is waiting for data" instead of
            // looking broken, without ever implying a value.
            if metric.fill == nil {
                Circle()
                    .stroke(metric.tint.opacity(0.34),
                            style: StrokeStyle(lineWidth: lineWidth,
                                               lineCap: .round,
                                               dash: [2, lineWidth * 1.4]))
            } else {
                Circle()
                    .stroke(metric.tint.opacity(0.20),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }

            if metric.fill != nil {
                Circle()
                    .trim(from: 0, to: min(max(fill, 0), 1))
                    .stroke(
                        // The whole arc is rotated -90deg below so it starts at
                        // 12 o'clock. The gradient must span the SAME angles as
                        // the trimmed arc in that pre-rotation frame (0 -> fill),
                        // NOT -90 -> -90+fill, or the bright leading edge lands
                        // 90deg off the arc's start and each ring's fill appears
                        // to begin at a different place.
                        AngularGradient(gradient: Gradient(colors: [metric.tint.opacity(0.85), metric.tint]),
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * min(max(fill, 0), 1))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    // Soft depth cue, not a neon halo. The heavier glow made the
                    // rings read as glowing tubes (esp. the dominant outer ring)
                    // — "why does the ring look weird". Dialed down toward the
                    // design's clean flat arcs while keeping a hint of lift.
                    .shadow(color: metric.tint.opacity(0.22), radius: 2, x: 0, y: 0)

                if (metric.fill ?? 0) > 1 {
                    Circle()
                        .fill(metric.tint)
                        .frame(width: lineWidth + 3, height: lineWidth + 3)
                        .offset(y: -diameter / 2)
                        .shadow(color: metric.tint.opacity(0.55), radius: 7, x: 0, y: 0)
                }
            } else {
                // Learning: a DASHED full track (design handoff's learning ring).
                // This supersedes the previous short solid cap at 12 o'clock.
                // That cap honored the "all rings start at the same place" rule,
                // but with two or three metrics still calibrating the caps
                // stacked into a pile of lozenges at the top of the hero that
                // read as a rendering fault. A dash pattern sweeps the whole
                // circumference, so there is no start position to disagree about
                // at all, and it states "not measured yet" more honestly than a
                // solid arc -- a solid arc is the same mark a real fill uses, so
                // at a glance it still implied ~10% of something.
                // NOTE: .butt, not .round. A round cap on a stroke this thick
                // swells every dash into a full circle, which turned the hero
                // into three rings of polka dots.
                // Sparse + faint on purpose: three calibrating rings at once,
                // so a dense or bright dash pattern turns the hero into a
                // ratchet texture that pulls more attention than the real
                // values below it. The handoff draws this band at ~0.09 alpha.
                Circle()
                    .stroke(metric.tint.opacity(0.22),
                            style: StrokeStyle(lineWidth: lineWidth,
                                               lineCap: .butt,
                                               dash: [4, 16]))
            }

            if let targetFraction = metric.targetFraction {
                targetMarker(diameter: diameter, lineWidth: lineWidth, tint: metric.stateTint ?? metric.tint, fraction: targetFraction)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// A small RADIAL clock-tick marking a REAL target/recommendation on the
    /// ring (e.g. the coach's recovery-derived strain target, or "sleep need
    /// met"). Positioned at the same angle convention the fill arc above
    /// uses (`-90deg + 360 * fraction`, i.e. 0 at the top, sweeping
    /// clockwise) so it always lines up with where the fill arc's edge would
    /// sit at that fraction. The capsule's long axis is rotated to the
    /// POSITION angle + 90deg so it points along the ring's radius (like a
    /// clock tick) rather than tangent to the ring. The tint plus a thin
    /// contrasting border keeps it legible over both the faint track and a
    /// bright fill.
    private func targetMarker(diameter: CGFloat, lineWidth: CGFloat, tint: Color, fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let theta = Angle.degrees(-90 + 360 * clamped) // position: 0 at top, CW
        let radius = diameter / 2
        let length = lineWidth + 6
        let width: CGFloat = 3
        return Capsule()
            .fill(tint)
            .overlay(Capsule().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1))
            .frame(width: width, height: length)
            .rotationEffect(theta + .degrees(90)) // radial, not tangential
            .offset(x: radius * cos(theta.radians), y: radius * sin(theta.radians))
            .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0)
    }

    /// Whether the status line has something worth saying. The name line
    /// already states the metric, and in the not-ready state several metrics
    /// resolve name, value and detail to the same word ("Strain / Learning /
    /// Learning"), which reads as a rendering fault rather than a state. One
    /// statement of a state is the design-handoff rule.
    ///
    /// Extracted so the rendered chip and its accessibility label read from the
    /// same predicate -- they were two copies of this condition, and a change to
    /// either would have let VoiceOver and the screen disagree.
    private func showsLegendDetail(_ metric: AtriaTriRingMetric) -> Bool {
        metric.detail != metric.title
            && metric.detail != metric.value
            && !metric.suppressesDetail
    }

    private func legendChip(metric: AtriaTriRingMetric, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: metric.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(metric.tint)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    // Metric NAME leads the chip (user feedback 2026-07-07:
                    // "it's not mentioned what they are — Sleep, Recovery,
                    // Strain") — value and context alone weren't legible.
                    Text(metric.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                    // Value line suppressed when the ring center owns this
                    // metric's numeral (dedup audit 2026-07-07). The row is
                    // still LAID OUT when suppressed -- see the reserved-space
                    // note on the status line below -- so suppression removes
                    // the duplicate text without changing the chip's height.
                    HStack(spacing: 4) {
                        // Tiny zone-tint dot -- an at-a-glance under/optimal/
                        // over cue that doesn't depend on reading the number.
                        // Nil (e.g. recovery, HRV, RHR) omits the dot -- the
                        // identity hue above already carries the meaning.
                        if let stateTint = metric.stateTint, !metric.suppressesValue {
                            Circle()
                                .fill(stateTint)
                                .frame(width: 5, height: 5)
                        }
                        Text(metric.suppressesValue ? " " : metric.value)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(metric.tint)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .allowsTightening(true)
                    }
                    .accessibilityHidden(metric.suppressesValue)
                    // The name line above already says it -- don't repeat
                    // it when a learning-state detail defaults to the name.
                    // Nor when the detail collapses onto the VALUE: in the
                    // learning state several metrics resolve both to the same
                    // word ("Strain / Learning / Learning"), which read as a
                    // rendering fault rather than a state. One statement of a
                    // state is the whole design-handoff rule.
                    // RESERVED STATUS SPACE. This line is always laid out, even
                    // when there is nothing to say, so every chip in the row is
                    // the same height by construction rather than by all of
                    // them happening to fall under a minimum. Previously the
                    // line appeared and disappeared with the data, which is how
                    // Recovery rendered short while Sleep and Strain rendered
                    // tall in the same row.
                    //
                    // One line is now correct where two used to be required.
                    // That rule existed because the engine's confidence
                    // captions were sentences -- "Limited confidence · HRV
                    // unavailable" truncated to "Limited confidence · H…" at a
                    // third of the screen width, clipping the half that said
                    // what to do about it. Markers are now short by contract
                    // (<= 14 characters, enumerated and machine-checked in
                    // AtriaMetricConfidencePresentationTests), so the reason
                    // for wrapping has been removed at the source instead of
                    // being absorbed by a growing chip.
                    Text(showsLegendDetail(metric) ? metric.detail : " ")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .allowsTightening(true)
                        .accessibilityHidden(!showsLegendDetail(metric))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            // Identity-forward chip, unified with the glance tiles and trend
            // summary pills (design-handoff "metric chip": hue wash + hue
            // hairline). Radius snapped off the stray 8 to the `chip` token.
            .background(metric.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                    .stroke(metric.tint.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // Mirror the visual de-duplication above so VoiceOver does not read
        // "Strain Learning, Learning" either.
        .accessibilityLabel(showsLegendDetail(metric)
                            ? "\(metric.title) \(metric.value), \(metric.detail)"
                            : "\(metric.title) \(metric.value)")
    }

    /// Spring fill-in that plays once per real appearance/value change, and
    /// is skipped entirely under Reduce Motion (values snap straight to
    /// their final state).
    private func animateToFinalValues() {
        var finals: [AtriaTriRingSlot: Double] = [:]
        for content in slots {
            finals[content.slot] = min(max(content.metric.fill ?? 0, 0), 1)
        }

        if reduceMotion {
            animatedFills = finals
            return
        }

        for content in slots {
            animatedFills[content.slot] = 0
        }
        // The withAnimation writes must not share the onAppear frame: on
        // iOS 27 the same-frame transaction is dropped before the view is
        // mounted, leaving every concentric fill at 0 (verified 2026-08-06 —
        // uniform track-only rings; Reduce Motion's direct-assign path was
        // unaffected). Deferring one runloop makes the spring reliable.
        Task { @MainActor in
            for (index, content) in slots.enumerated() {
                let target = finals[content.slot] ?? 0
                withAnimation(.spring(duration: 0.8).delay(Double(index) * 0.15)) {
                    animatedFills[content.slot] = target
                }
            }
        }
    }
}

/// An annulus (ring band) hit-test shape: the region between two concentric
/// circles sharing a center, using the even-odd fill rule so the inner
/// circle carves a hole out of the outer one.
private struct AtriaRingBandShape: Shape {
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        return path
    }
}
