import SwiftUI

/// Owner 2026-10-03: learnings and suggestions as a stacked feed on Today.
/// Only findings — never a restatement of the Sleep / Recovery / Strain rings
/// above it (owner removed a ring-cloning "Today's read" bar on 2026-09-18).
struct AtriaTodayLearningsFeed: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let systemImage: String
        let headline: String
        let detail: String
        let tint: Color
    }

    let items: [Item]
    let onOpen: () -> Void

    /// Kinds that only restate a ring value; the feed is for learnings.
    static let ringRestatingKinds: Set<AtriaLearnedInsight.Kind> = [
        .daySnapshot, .readiness, .yesterdayStrain
    ]

    static func items(learned: [AtriaLearnedInsight],
                      behavior: [AtriaInsight]) -> [Item] {
        let learnedItems = learned
            .filter { !ringRestatingKinds.contains($0.kind) }
            .map { insight in
                Item(id: "learned-\(insight.id)",
                     systemImage: insight.systemImage,
                     headline: insight.headline,
                     detail: insight.detail,
                     tint: insight.pictureTint)
            }
        let behaviorItems = behavior.prefix(3).map { insight in
            Item(id: "behavior-\(insight.id)",
                 systemImage: insight.symbolName,
                 headline: insight.headline,
                 detail: insight.detail,
                 tint: insight.isPositive ? Metrics.electricGreen : Metrics.electricRed)
        }
        return Array((learnedItems + behaviorItems).prefix(8))
    }

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        Button(action: onOpen) {
                            card(item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Opens Insights")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            .accessibilityLabel("Learnings")
        }
    }

    private func card(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.tint)
                Text(item.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(width: 240, alignment: .topLeading)
        .frame(minHeight: 44, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect(cornerRadius: 20))
        .glassEffect(.regular.tint(item.tint.opacity(0.10)).interactive(),
                     in: .rect(cornerRadius: 20))
    }
}
