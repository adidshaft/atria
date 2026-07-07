import SwiftUI

/// Leaderboard (2026-07-08, user-requested P3, DEMO). No backend is connected
/// yet, so this is an honest PREVIEW: the standings shown are clearly labeled
/// sample data (never presented as the user's real social standing), and the
/// "You" row shows only the user's OWN real weekly number — or an honest
/// learning state when the baseline isn't ready. When a real backend
/// (Supabase) and friends are connected later, the sample rows are replaced
/// by real ones; nothing here fabricates other people's data as real.
struct AtriaLeaderboardScreen: View {
    /// The user's real weekly recovery average (nil while still learning).
    let myWeeklyRecovery: Int?

    enum Board: String, CaseIterable, Identifiable {
        case recovery, strain
        var id: String { rawValue }
        var title: String { self == .recovery ? "Recovery" : "Strain" }
        var unit: String { self == .recovery ? "%" : "" }
    }

    private struct SampleEntry: Identifiable {
        let id = UUID()
        let name: String
        let initial: String
        let recovery: Int
        let strain: Double
        let tint: Color
    }

    // Clearly-illustrative sample opponents — shown only to demonstrate the
    // layout, always under an explicit "Sample" label. Not real people.
    private static let sample: [SampleEntry] = [
        SampleEntry(name: "Sample · Riya", initial: "R", recovery: 88, strain: 14.2, tint: .green),
        SampleEntry(name: "Sample · Dev", initial: "D", recovery: 74, strain: 12.8, tint: .mint),
        SampleEntry(name: "Sample · Aria", initial: "A", recovery: 61, strain: 9.5, tint: .teal),
    ]

    @State private var board: Board = .recovery
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewBanner

                    Picker("Board", selection: $board) {
                        ForEach(Board.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 8) {
                        ForEach(Array(rankedRows.enumerated()), id: \.offset) { index, row in
                            row.view(rank: index + 1, board: board)
                        }
                    }

                    Text("Sample standings, shown so you can see how the leaderboard will look. Connect an account and invite friends to compete for real — nobody's data is shared until you opt in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .navigationTitle("Leaderboard")
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
            Image(systemName: "trophy.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Preview")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.orange.opacity(0.16), in: Capsule())
                    Text("Not connected yet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Only your own number below is real.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private enum Row {
        case sample(SampleEntry)
        case you(recovery: Int?)

        @ViewBuilder
        func view(rank: Int, board: Board) -> some View {
            switch self {
            case .sample(let entry):
                AtriaLeaderboardRow(rank: rank, initial: entry.initial, name: entry.name,
                                    valueText: board == .recovery ? "\(entry.recovery)%" : String(format: "%.1f", entry.strain),
                                    tint: entry.tint, isYou: false, sample: true)
            case .you(let recovery):
                AtriaLeaderboardRow(rank: rank, initial: "Y", name: "You",
                                    valueText: board == .recovery ? (recovery.map { "\($0)%" } ?? "Learning") : "Learning",
                                    tint: .blue, isYou: true, sample: false)
            }
        }

        var sortRecovery: Int {
            switch self {
            case .sample(let e): return e.recovery
            case .you(let r): return r ?? -1   // learning sorts last, honestly
            }
        }
    }

    private var rankedRows: [Row] {
        var rows: [Row] = Self.sample.map(Row.sample)
        rows.append(.you(recovery: myWeeklyRecovery))
        return rows.sorted { $0.sortRecovery > $1.sortRecovery }
    }
}

private struct AtriaLeaderboardRow: View {
    let rank: Int
    let initial: String
    let name: String
    let valueText: String
    let tint: Color
    let isYou: Bool
    let sample: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(initial)
                .font(.subheadline.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(isYou ? .bold : .semibold))
                if sample {
                    Text("Sample")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(valueText)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(isYou ? .blue : .primary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(isYou ? Color.blue.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isYou ? Color.blue.opacity(0.4) : .clear, lineWidth: 1)
        )
    }
}
