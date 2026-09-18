import SwiftUI

/// In-app render of the Lock Screen Live Activity using the same snapshot
/// ActivityKit already has. HID cannot lock the cabled phone, so this is the
/// photographable lock layout with live workout values.
struct AtriaLiveActivityLockPreview: View {
    let snapshot: AtriaLiveActivityCoordinator.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                heartRateHero
                    .frame(width: 112, alignment: .leading)
                zoneSummary
                Spacer(minLength: 4)
                if snapshot.showsWorkoutControls {
                    Text(elapsedText)
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(snapshot.isPaused ? .orange : .primary)
                }
            }
            zoneBar
            HStack(spacing: 16) {
                if snapshot.showsWorkoutControls {
                    labeledMetric(snapshot.workoutStrain.formatted(.number.precision(.fractionLength(1))),
                                  systemImage: "bolt.fill",
                                  tint: .yellow)
                    labeledMetric(stepsText,
                                  systemImage: "figure.walk",
                                  tint: .green)
                } else if let daily = snapshot.dailySteps {
                    labeledMetric("\(daily)",
                                  systemImage: "figure.walk",
                                  tint: .green)
                }
                Spacer()
                Text(snapshot.heartRateAvailability.rawValue.capitalized)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(statusTint)
            }
        }
        .padding(16)
        .background(.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityIdentifier("atria-live-activity-lock-preview")
    }

    private var header: some View {
        HStack {
            Label(snapshot.activityName, systemImage: snapshot.activitySystemImage)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            Spacer()
            if snapshot.batteryLevel >= 0 {
                Label("\(snapshot.batteryLevel)%", systemImage: "battery.100")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var heartRateHero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.caption.weight(.black))
            Text(snapshot.heartRate > 0 ? "\(snapshot.heartRate)" : "--")
                .font(.system(size: 29, weight: .black, design: .rounded))
                .monospacedDigit()
            Text("BPM")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(snapshot.heartRateAvailability == .live ? .red : .secondary)
    }

    private var zoneSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(zoneLabel)
                .font(.headline.monospacedDigit().weight(.black))
            if let lower = snapshot.targetLowerHeartRateZone,
               let upper = snapshot.targetUpperHeartRateZone {
                Text("T Z\(lower)–Z\(upper)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var zoneBar: some View {
        let active = snapshot.heartRateZoneIndex ?? 0
        return HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { zone in
                Capsule()
                    .fill(zone == active ? Color.red : Color.white.opacity(0.22))
                    .frame(height: 6)
            }
        }
        .accessibilityLabel("Heart-rate zone \(zoneLabel)")
    }

    private var zoneLabel: String {
        if let name = snapshot.heartRateZoneName, !name.isEmpty { return name }
        if let index = snapshot.heartRateZoneIndex, index > 0 { return "Z\(index)" }
        return "<Z1"
    }

    private var elapsedText: String {
        let seconds = max(0, Int(snapshot.elapsedDuration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var stepsText: String {
        guard let steps = snapshot.steps else { return "--" }
        return "\(steps)"
    }

    private var statusTint: Color {
        switch snapshot.heartRateAvailability {
        case .live: return .green
        case .reconnecting: return .orange
        case .stale: return .yellow
        case .unavailable: return .secondary
        }
    }

    private func labeledMetric(_ value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.monospacedDigit().weight(.black))
        }
    }
}

struct AtriaLiveActivityLockPreviewSheet: View {
    let snapshot: AtriaLiveActivityCoordinator.Snapshot?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.12).ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("Lock Screen Live Activity")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let snapshot, snapshot.isRecording || snapshot.heartRate > 0 {
                        AtriaLiveActivityLockPreview(snapshot: snapshot)
                            .padding(.horizontal, 16)
                    } else {
                        Text("Waiting for live heart rate")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
