import SwiftUI

struct AtriaManualSleepSheet: View {
    let onSave: (Date, Date, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isNap = false
    @State private var start = Date().addingTimeInterval(-8 * 60 * 60)
    @State private var end = Date()

    private var durationText: String {
        SleepHistorySnapshot.formatDuration(max(0, end.timeIntervalSince(start)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $isNap) {
                    Text("Sleep").tag(false)
                    Text("Nap").tag(true)
                }
                .pickerStyle(.segmented)

                DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])

                Section("Stages") {
                    ForEach(SleepStageKind.allCases) { stage in
                        HStack {
                            Label(stage.label, systemImage: AtriaSleepStageGlyph.symbol(for: stage))
                            Spacer()
                            Text(stagePreviewText(stage))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Atria will save this \(isNap ? "nap" : "sleep") locally and split the window into research stages: Awake, Light, SWS, and Deep.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add \(isNap ? "Nap" : "Sleep")")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(start, end, isNap)
                    }
                    .disabled(end <= start)
                }
            }
        }
    }

    private func stagePreviewText(_ stage: SleepStageKind) -> String {
        let duration = max(0, end.timeIntervalSince(start))
        let fraction: Double
        switch (isNap, stage) {
        case (_, .awake): fraction = isNap ? 0.06 : 0.08
        case (true, .light): fraction = 0.72
        case (false, .light): fraction = 0.52
        case (true, .sws): fraction = 0.14
        case (false, .sws): fraction = 0.22
        case (true, .deep): fraction = 0.08
        case (false, .deep): fraction = 0.18
        }
        return SleepHistorySnapshot.formatDuration(duration * fraction)
    }
}
