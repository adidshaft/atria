import SwiftUI

/// A premium progress ring for a single metric. Gradient stroke + subtle glow
/// when there is a value; a quiet partial cap while the metric is still learning.
/// Center text is always scale-safe (never clipped).
struct AtriaMetricRing: View, Equatable {
    let label: String
    /// Display value, e.g. "85%", "0.4", or "--".
    let value: String
    /// 0...1 progress, or nil while the metric is still learning.
    let fraction: Double?
    let tint: Color
    let size: CGFloat

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

                if fraction != nil && clamped >= 0.01 {
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
                } else {
                    // Learning: a short cap gives the card life without implying
                    // the metric has a real scored value yet.
                    Circle()
                        .trim(from: 0.06, to: 0.22)
                        .stroke(tint.opacity(0.48),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
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

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
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
