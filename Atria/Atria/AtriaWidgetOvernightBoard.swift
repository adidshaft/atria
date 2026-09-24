import SwiftUI

/// Opens from a Lock Screen/overnight widget tap (`atria://widget-board`).
/// This is not a second WidgetKit renderer: it prints the same
/// `WidgetSnapshot` the extension already received, so Home/Lock faces
/// cannot silently disagree with Today. Clean, simple recap by default;
/// the raw payload-write timestamp stays one line, gated to developer mode.
struct AtriaWidgetOvernightBoard: View {
    @State private var snapshot: WidgetSnapshot?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasOvernightNumbers {
                        Text(clockText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        metricRow(title: "Recovery",
                                  value: snapshot?.recoveryPercent.map { "\($0)%" } ?? "--",
                                  tint: .green)
                        metricRow(title: "HRV",
                                  value: snapshot?.hrvRMSSD.map { "\($0) ms" } ?? "--",
                                  tint: .purple)
                        metricRow(title: "Resting HR",
                                  value: snapshot?.restingHR.map { "\($0) bpm" } ?? "--",
                                  tint: .cyan)
                    } else {
                        AtriaWidgetBoardEmptyState()
                    }

                    if AtriaDeveloperMode.isEnabled, let createdAt = snapshot?.createdAt {
                        Text("Payload write \(createdAt.formatted(date: .omitted, time: .shortened)). Overnight numbers keep the morning clock above, not this write time.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Overnight recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("atria-widget-overnight-board")
        .onAppear {
            snapshot = AtriaIntentSnapshotStore.loadPublishedPayload()
        }
    }

    private var hasOvernightNumbers: Bool {
        snapshot?.recoveryPercent != nil
            || snapshot?.hrvRMSSD != nil
            || snapshot?.restingHR != nil
    }

    private var clockText: String {
        guard let capturedAt = snapshot?.hrvCapturedAt else { return "Overnight" }
        return AtriaOvernightClockText.status(capturedAt)
    }

    private func metricRow(title: String, value: String, tint: Color) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(value)
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
    }
}

private struct AtriaWidgetBoardEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No overnight numbers yet")
                .font(.title3.weight(.semibold))
            Text("Recovery, HRV, and resting heart rate will appear here after your next night with Atria.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

enum AtriaOvernightClockText {
    static func status(_ capturedAt: Date,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> String {
        let savedDay = calendar.startOfDay(for: capturedAt)
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(savedDay, inSameDayAs: today) {
            return "This morning"
        }
        guard savedDay < today else { return "Overnight" }
        let age = max(calendar.dateComponents([.day], from: savedDay, to: today).day ?? 0, 1)
        return age == 1 ? "Yesterday morning" : "\(age)d ago"
    }
}
