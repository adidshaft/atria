import SwiftUI

/// One-time prompt shown when the user slept more than once on a day: it asks
/// which sleep is their main one. The chosen sleep drives Recovery and the
/// physiological-cycle boundary; the other is kept as a real second sleep that
/// still counts and now shares the same day so it appears under Activity. Every
/// path resolves the day (records a `dayPrimaryChoice`) so it never re-prompts.
struct AtriaSameDayMainSleepSheet: View {
    let choice: AtriaSameDayMainSleepChoice
    /// Called with the chosen primary sleep id.
    let onResolve: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String

    init(choice: AtriaSameDayMainSleepChoice, onResolve: @escaping (String) -> Void) {
        self.choice = choice
        self.onResolve = onResolve
        _selectedID = State(initialValue: choice.recommendedPrimaryID)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("You slept more than once on \(Self.dayFormatter.string(from: choice.morningDay)). Which one is your main sleep? It drives Recovery — the other stays a second sleep, still counts toward your total, and shows up under Activity.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        ForEach(choice.options) { option in
                            optionRow(option)
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            onResolve(selectedID)
                            dismiss()
                        } label: {
                            Text("Set as main sleep")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Keep the longer one automatically") {
                            onResolve(choice.recommendedPrimaryID)
                            dismiss()
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Two sleeps")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func optionRow(_ option: UserConfirmedSleep) -> some View {
        let isSelected = option.id == selectedID
        let isRecommended = option.id == choice.recommendedPrimaryID
        Button {
            selectedID = option.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(rangeText(option))
                            .font(.headline)
                        if isRecommended {
                            Text("Longer")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text("\(durationText(option)) of sleep")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(isSelected ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rangeText(option)), \(durationText(option)) of sleep\(isRecommended ? ", the longer sleep" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func rangeText(_ option: UserConfirmedSleep) -> String {
        "\(Self.timeFormatter.string(from: option.start)) – \(Self.timeFormatter.string(from: option.end))"
    }

    private func durationText(_ option: UserConfirmedSleep) -> String {
        let seconds = max(0, option.effectiveSleepDuration)
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
