import SwiftUI

/// Published widget payload, with overnight clocks. This is not a second
/// WidgetKit renderer: it prints the same `WidgetSnapshot` the extension
/// already received, so Home/Lock faces cannot silently disagree with Today.
struct AtriaWidgetOvernightBoard: View {
    @State private var snapshot: WidgetSnapshot?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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

                    if let live = snapshot?.heartRate, live > 0 {
                        metricRow(title: "Live HR (widget tile)",
                                  value: "\(live) bpm",
                                  tint: .red.opacity(0.85))
                    }

                    if let createdAt = snapshot?.createdAt {
                        Text("Payload write \(createdAt.formatted(date: .omitted, time: .shortened)). Overnight numbers keep the morning clock above, not this write time.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("Widget payload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("atria-widget-overnight-board")
        .onAppear {
            snapshot = AtriaIntentSnapshotStore.loadPublishedPayload()
        }
    }

    private var clockText: String {
        guard let capturedAt = snapshot?.hrvCapturedAt else {
            return snapshot == nil ? "No shared widget payload" : "Overnight clock missing"
        }
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
