import SwiftUI

struct AtriaTriRingMetric: Equatable {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let fill: Double?
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

    init(slots: [AtriaTriRingSlotContent],
         centerValue: String,
         centerState: String,
         centerDelta: String? = nil,
         accessibilitySummary: String,
         actions: [AtriaTriRingSlot: () -> Void]) {
        self.slots = Array(slots.prefix(3))
        self.centerValue = centerValue
        self.centerState = centerState
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
                  centerDelta: centerDelta,
                  accessibilitySummary: accessibilitySummary,
                  actions: [.sleep: onSleep, .recovery: onRecovery, .strain: onStrain])
    }

    static func == (lhs: AtriaTriRing, rhs: AtriaTriRing) -> Bool {
        lhs.slots == rhs.slots
            && lhs.centerValue == rhs.centerValue
            && lhs.centerState == rhs.centerState
            && lhs.centerDelta == rhs.centerDelta
            && lhs.accessibilitySummary == rhs.accessibilitySummary
    }

    // Even-gap concentric geometry: every ring shares the same stroke width;
    // each ring inward is exactly `lineWidth + gap` narrower (per side) than
    // the one outside it, so the empty space between any two adjacent rings
    // is identical.
    private static let outerDiameter: CGFloat = 214
    private static let lineWidth: CGFloat = 12
    private static let gap: CGFloat = 10
    private static let centerContentWidth: CGFloat = 96

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
        VStack(spacing: 14) {
            ZStack {
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
        .onAppear(perform: animateToFinalValues)
        .onChange(of: fillSignature) { _, _ in animateToFinalValues() }
    }

    /// Flattened fill snapshot (slot-order-stable since `slots` is fixed for
    /// the view's lifetime) used solely to detect "some fill value changed"
    /// for the re-animate trigger below.
    private var fillSignature: [Double] {
        slots.map { $0.metric.fill ?? -1 }
    }

    private var centerContent: some View {
        VStack(spacing: 2) {
            Text(centerValue)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.58)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText())
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
        ZStack {
            Circle()
                .stroke(metric.tint.opacity(0.16), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            if metric.fill != nil {
                Circle()
                    .trim(from: 0, to: min(max(fill, 0), 1))
                    .stroke(
                        AngularGradient(gradient: Gradient(colors: [metric.tint.opacity(0.85), metric.tint]),
                                        center: .center,
                                        startAngle: .degrees(-90),
                                        endAngle: .degrees(-90 + 360 * min(max(fill, 0), 1))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: metric.tint.opacity(0.45), radius: 3, x: 0, y: 0)

                if (metric.fill ?? 0) > 1 {
                    Circle()
                        .fill(metric.tint)
                        .frame(width: lineWidth + 3, height: lineWidth + 3)
                        .offset(y: -diameter / 2)
                        .shadow(color: metric.tint.opacity(0.55), radius: 7, x: 0, y: 0)
                }
            } else {
                // Learning: a short static cap gives the ring life without
                // implying a real scored value exists yet (honesty rule --
                // never fabricate progress).
                Circle()
                    .trim(from: 0.06, to: 0.16)
                    .stroke(metric.tint.opacity(0.4),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func legendChip(metric: AtriaTriRingMetric, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: metric.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(metric.tint)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.value)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(metric.detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 8)
            .background(metric.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metric.title) \(metric.value), \(metric.detail)")
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
        for (index, content) in slots.enumerated() {
            let target = finals[content.slot] ?? 0
            withAnimation(.spring(duration: 0.8).delay(Double(index) * 0.15)) {
                animatedFills[content.slot] = target
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
