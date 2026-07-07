import SwiftUI

/// Sparring — a 1-v-1 head-to-head challenge (2026-07-08, user-requested P3,
/// DEMO). Same honesty stance as the leaderboard: this is a clearly-labeled
/// PREVIEW. Your side shows only your OWN real weekly number (or an honest
/// learning state); the opponent is an explicitly-labeled sample until a real
/// friend is connected through a backend later. No one's data is fabricated
/// as real, and no "winner" is declared while your side is still learning.
struct AtriaSparringScreen: View {
    /// The user's real weekly recovery average (nil while still learning).
    let myWeeklyRecovery: Int?

    // A single clearly-labeled sample opponent for the preview matchup.
    private let opponentName = "Sample · Riya"
    private let opponentRecovery = 74

    @Environment(\.dismiss) private var dismiss

    private var hasRealMe: Bool { myWeeklyRecovery != nil }
    private var iLead: Bool? {
        guard let mine = myWeeklyRecovery else { return nil }
        if mine == opponentRecovery { return nil }
        return mine > opponentRecovery
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewBanner
                    matchupCard
                    statusLine
                    Text("Sample matchup, shown so you can see how sparring will look. Challenge a real friend once accounts are connected — your weekly numbers are compared only after you both opt in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .navigationTitle("Sparring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.body.weight(.semibold))
                }
            }
        }
    }

    private var previewBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.fencing")
                .font(.title3.weight(.bold))
                .foregroundStyle(.purple)
                .frame(width: 44, height: 44)
                .background(.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Preview")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.purple.opacity(0.16), in: Capsule())
                    Text("Not connected yet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Only your side is real.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var matchupCard: some View {
        HStack(alignment: .top, spacing: 8) {
            fighter(title: "You",
                    initial: "Y",
                    valueText: myWeeklyRecovery.map { "\($0)%" } ?? "Learning",
                    subtitle: "Weekly recovery",
                    tint: .blue,
                    leads: iLead == true,
                    isSample: false)
            VStack(spacing: 4) {
                Text("VS")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            fighter(title: opponentName,
                    initial: "R",
                    valueText: "\(opponentRecovery)%",
                    subtitle: "Sample",
                    tint: .green,
                    leads: iLead == false,
                    isSample: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func fighter(title: String, initial: String, valueText: String,
                         subtitle: String, tint: Color, leads: Bool, isSample: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Text(initial)
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(tint.gradient, in: Circle())
                if leads {
                    Image(systemName: "crown.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .offset(x: 4, y: -4)
                }
            }
            Text(valueText)
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(isSample ? .tertiary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch iLead {
        case .some(true):
            sparringStatus(text: "You're ahead this week.", tint: .green, icon: "checkmark.seal.fill")
        case .some(false):
            sparringStatus(text: "You're behind — room to push.", tint: .orange, icon: "flame.fill")
        case .none where hasRealMe:
            sparringStatus(text: "Dead even this week.", tint: .secondary, icon: "equal.circle.fill")
        default:
            sparringStatus(text: "Your side is still learning — a real matchup starts once your baseline is ready.",
                           tint: .secondary, icon: "hourglass")
        }
    }

    private func sparringStatus(text: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
