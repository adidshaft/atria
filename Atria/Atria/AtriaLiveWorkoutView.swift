import SwiftUI

/// Identifiable wrapper so a live workout can drive `.fullScreenCover(item:)`.
struct AtriaWorkoutSession: Identifiable {
    let id = UUID()
    let start: Date
}

/// Live workout HUD: a full-screen, glanceable real-time view shown while a
/// workout is active — big live HR + zone, a zone bar, live strain building
/// toward a target, active calories, and elapsed time. All values come from the
/// existing live stores (no new pipeline); the strap is already recording.
struct AtriaLiveWorkoutView: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    let maxHR: Int
    let startDate: Date
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var heartRate: Int { pulseStore.state.heartRate }
    private var strain: Double { heroStore.state.strain }

    var body: some View {
        // Resolve the zone ONCE per render and pass it down (was recomputed in
        // body + every subview). The elapsed clock is isolated in a TimelineView
        // so the per-second tick no longer re-renders the whole HUD.
        let zone = HRZone.zone(for: heartRate, maxHR: maxHR)
        return ZStack {
            LinearGradient(colors: [zone.color.opacity(0.45), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: zone)

            VStack(spacing: 26) {
                header
                Spacer(minLength: 0)
                heartBlock(zone)
                zoneBar(zone)
                Spacer(minLength: 0)
                statsRow
                stopButton
            }
            .padding(24)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Label("Workout", systemImage: "figure.run")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            TimelineView(.periodic(from: startDate, by: 1)) { context in
                Text(elapsedText(context.date))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }

    private func heartBlock(_ zone: HRZone) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
            Text(heartRate > 0 ? "\(heartRate)" : "--")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("\(zone.name.uppercased()) · bpm")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(zone.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heart rate \(heartRate), \(zone.name) zone")
    }

    private func zoneBar(_ zone: HRZone) -> some View {
        HStack(spacing: 4) {
            ForEach(HRZone.allCases, id: \.self) { z in
                Capsule()
                    .fill(z == zone ? z.color : z.color.opacity(0.22))
                    .frame(height: z == zone ? 12 : 8)
                    .animation(.snappy(duration: 0.25), value: zone)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            statTile(title: "Strain",
                     value: String(format: "%.1f", strain),
                     tint: .orange)
            statTile(title: "Calories",
                     value: liveStore.state.liveActiveCalories.map { "\($0)" } ?? "--",
                     tint: .pink)
        }
    }

    private func statTile(title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            onStop()
            dismiss()
        } label: {
            Label("End workout", systemImage: "stop.fill")
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .atriaCardAction(tint: .red)
    }

    private func elapsedText(_ date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(startDate)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}
