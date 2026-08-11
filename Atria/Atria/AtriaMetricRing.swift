import SwiftUI

/// A premium progress ring for a single metric. Gradient stroke + subtle glow
/// when there is a value; one quiet dashed track while the metric is learning.
/// Center text is always scale-safe (never clipped).
struct AtriaMetricRing: View, Equatable {
    let label: String
    /// Display value, e.g. "85%", "0.4", or "--".
    let value: String
    /// 0...1 progress, or nil while the metric is still learning.
    let fraction: Double?
    let tint: Color
    let size: CGFloat
    /// Short confidence/provenance marker ("estimate", "limited", …) shown
    /// under the label. 2026-08-08: this layout rendered title + value ONLY,
    /// so a provisional RHR-only recovery (41%) looked exactly as settled as a
    /// validated one (67%) — and the number visibly "jumped" as better
    /// evidence landed, which reads as a random product rather than an
    /// upgrading estimate. The concentric hero already says this; both
    /// layouts must. Nil remains visually distinct without claiming a fill.
    var confidenceMarker: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fill actually drawn; sweeps toward `clamped` so the ring animates in
    /// instead of popping to its final value.
    @State private var animatedFraction: Double = 0

    static func == (lhs: AtriaMetricRing, rhs: AtriaMetricRing) -> Bool {
        lhs.label == rhs.label
            && lhs.value == rhs.value
            && lhs.fraction == rhs.fraction
            && lhs.tint == rhs.tint
            && lhs.size == rhs.size
            && lhs.confidenceMarker == rhs.confidenceMarker
    }

    private var lineWidth: CGFloat { max(7, size * 0.085) }
    private var clamped: Double { min(max(fraction ?? 0, 0), 1) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                // Matches the concentric hero's awaiting-data treatment
                // (2026-08-08) so the same metric never reads as "present" in
                // one ring layout and "missing" in the other.
                if fraction == nil {
                    Circle()
                        .stroke(tint.opacity(0.30),
                                style: StrokeStyle(lineWidth: lineWidth,
                                                   lineCap: .round,
                                                   dash: [2, lineWidth * 1.4]))
                } else {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
                }

                // A measured zero owns the ordinary base track but no arc. Any
                // positive measurement draws its factual magnitude, including
                // sub-one-percent values; nil already drew the one unavailable
                // track above and must not acquire a second legacy cap here.
                if fraction != nil && clamped > 0 {
                    Circle()
                        .trim(from: 0, to: animatedFraction)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [tint.opacity(0.55), tint]),
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(-90 + 360 * clamped)
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .onAppear {
                            if reduceMotion {
                                animatedFraction = clamped
                            } else {
                                withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) {
                                    animatedFraction = clamped
                                }
                            }
                        }
                        .onChange(of: clamped) { _, newValue in
                            if reduceMotion {
                                animatedFraction = newValue
                            } else {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                                    animatedFraction = newValue
                                }
                            }
                        }
                }

                Text(value)
                    .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(fraction == nil ? Color.secondary : Color.primary)
                    .padding(.horizontal, size * 0.16)
            }
            .frame(width: size, height: size)

            VStack(spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let confidenceMarker, !confidenceMarker.isEmpty {
                    Text(confidenceMarker)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(confidenceMarker.map { "\(label) \(value), \($0)" }
                            ?? "\(label) \(value)")
    }
}

#Preview {
    HStack(spacing: 20) {
        AtriaMetricRing(label: "Recovery", value: "82%", fraction: 0.82, tint: .green, size: 116)
        AtriaMetricRing(label: "Strain", value: "12.4", fraction: 12.4 / 21, tint: .orange, size: 88)
        AtriaMetricRing(label: "Sleep", value: "--", fraction: nil, tint: .cyan, size: 88)
    }
    .padding()
    .background(Color.black)
}
