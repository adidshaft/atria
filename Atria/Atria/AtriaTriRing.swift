import SwiftUI

struct AtriaTriRingMetric: Equatable {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let fill: Double?
}

struct AtriaTriRing: View, Equatable {
    let sleep: AtriaTriRingMetric
    let recovery: AtriaTriRingMetric
    let strain: AtriaTriRingMetric
    let centerValue: String
    let centerState: String
    let accessibilitySummary: String
    let onSleep: () -> Void
    let onRecovery: () -> Void
    let onStrain: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedSleepFill = 0.0
    @State private var animatedRecoveryFill = 0.0
    @State private var animatedStrainFill = 0.0

    static func == (lhs: AtriaTriRing, rhs: AtriaTriRing) -> Bool {
        lhs.sleep == rhs.sleep
            && lhs.recovery == rhs.recovery
            && lhs.strain == rhs.strain
            && lhs.centerValue == rhs.centerValue
            && lhs.centerState == rhs.centerState
            && lhs.accessibilitySummary == rhs.accessibilitySummary
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ring(metric: sleep, diameter: 214, lineWidth: 14, fill: animatedSleepFill)
                ring(metric: recovery, diameter: 178, lineWidth: 12, fill: animatedRecoveryFill)
                ring(metric: strain, diameter: 146, lineWidth: 10, fill: animatedStrainFill)

                VStack(spacing: 2) {
                    Text(centerValue)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.58)
                        .lineLimit(1)
                    Text(centerState)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(width: 104)
            }
            .frame(width: 224, height: 224)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)

            HStack(spacing: 8) {
                legendChip(metric: sleep, action: onSleep)
                legendChip(metric: recovery, action: onRecovery)
                legendChip(metric: strain, action: onStrain)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: animateToFinalValues)
        .onChange(of: sleep.fill) { _, _ in animateToFinalValues() }
        .onChange(of: recovery.fill) { _, _ in animateToFinalValues() }
        .onChange(of: strain.fill) { _, _ in animateToFinalValues() }
    }

    private func ring(metric: AtriaTriRingMetric,
                      diameter: CGFloat,
                      lineWidth: CGFloat,
                      fill: Double) -> some View {
        ZStack {
            Circle()
                .stroke(metric.tint.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            if metric.fill != nil {
                Circle()
                    .trim(from: 0, to: min(max(fill, 0), 1))
                    .stroke(metric.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                if (metric.fill ?? 0) > 1 {
                    Circle()
                        .fill(metric.tint)
                        .frame(width: lineWidth + 3, height: lineWidth + 3)
                        .offset(y: -diameter / 2)
                        .shadow(color: metric.tint.opacity(0.55), radius: 7, x: 0, y: 0)
                }
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

    private func animateToFinalValues() {
        let sleepFinal = min(max(sleep.fill ?? 0, 0), 1)
        let recoveryFinal = min(max(recovery.fill ?? 0, 0), 1)
        let strainFinal = min(max(strain.fill ?? 0, 0), 1)

        if reduceMotion {
            animatedSleepFill = sleepFinal
            animatedRecoveryFill = recoveryFinal
            animatedStrainFill = strainFinal
            return
        }

        animatedSleepFill = 0
        animatedRecoveryFill = 0
        animatedStrainFill = 0
        withAnimation(.spring(duration: 0.8)) {
            animatedSleepFill = sleepFinal
        }
        withAnimation(.spring(duration: 0.8).delay(0.15)) {
            animatedRecoveryFill = recoveryFinal
        }
        withAnimation(.spring(duration: 0.8).delay(0.30)) {
            animatedStrainFill = strainFinal
        }
    }
}
