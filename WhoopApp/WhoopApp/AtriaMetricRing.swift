import SwiftUI

/// A premium progress ring for a single metric. Gradient stroke + subtle glow
/// when there is a value; a calm dashed ring while the metric is still learning.
/// Center text is always scale-safe (never clipped).
struct AtriaMetricRing: View, Equatable {
    let label: String
    /// Display value, e.g. "85%", "0.4", or "--".
    let value: String
    /// 0...1 progress, or nil while the metric is still learning.
    let fraction: Double?
    let tint: Color
    let size: CGFloat

    static func == (lhs: AtriaMetricRing, rhs: AtriaMetricRing) -> Bool {
        lhs.label == rhs.label
            && lhs.value == rhs.value
            && lhs.fraction == rhs.fraction
            && lhs.size == rhs.size
    }

    private var lineWidth: CGFloat { max(7, size * 0.085) }
    private var clamped: Double { min(max(fraction ?? 0, 0), 1) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

                if fraction != nil && clamped >= 0.01 {
                    Circle()
                        .trim(from: 0, to: clamped)
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
                        .shadow(color: tint.opacity(0.45), radius: 3)
                } else {
                    // Learning: neutral grey dashes across every metric, so colour
                    // (the filled gradient) only ever means "real data is in".
                    Circle()
                        .stroke(Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [3, 7]))
                }

                Text(value)
                    .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                    .monospacedDigit()
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
