import SwiftUI

/// Owner 2026-10-03: learnings and suggestions as cards stacked on top of each
/// other on Today; tapping a card removes it. Only findings — never a
/// restatement of the Sleep / Recovery / Strain rings above it (owner removed
/// a ring-cloning "Today's read" bar on 2026-09-18).
struct AtriaTodayLearningsFeed: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let systemImage: String
        let headline: String
        let detail: String
        let tint: Color

        /// Insight ids are per kind ("sleep-debt"), so a dismissal is keyed
        /// on the finding itself: the same finding stays gone, a changed one
        /// (new numbers) is new information and returns.
        var dismissalKey: String { "\(id)|\(headline)" }
    }

    static let dismissedKey = "atria.today.learnings.dismissed.v1"
    static let maximumVisible = 4
    static let maximumRemembered = 100

    let items: [Item]
    @AppStorage(AtriaTodayLearningsFeed.dismissedKey) private var dismissedRaw: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        return learnedItems + behaviorItems
    }

    static func visible(_ items: [Item], dismissed: Set<String>) -> [Item] {
        Array(items.filter { !dismissed.contains($0.dismissalKey) }.prefix(maximumVisible))
    }

    static func remembering(_ key: String, in raw: String) -> String {
        var keys = raw.split(separator: "\n").map(String.init).filter { $0 != key }
        keys.append(key)
        return keys.suffix(maximumRemembered).joined(separator: "\n")
    }

    private var dismissed: Set<String> {
        Set(dismissedRaw.split(separator: "\n").map(String.init))
    }

    /// Wallet-style deck (owner 2026-10-03 sketch): the front card in full,
    /// the next ones peeking above it as narrower neutral slivers (only the
    /// icon carries colour — owner 2026-10-03). Tapping
    /// the front card removes it and the next one comes forward.
    static let peekStep: CGFloat = 9
    static let maximumPeeking = 3

    var body: some View {
        let shown = Self.visible(items, dismissed: dismissed)
        if let front = shown.first {
            let behind = Array(shown.dropFirst().prefix(Self.maximumPeeking))
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) {
                    dismissedRaw = Self.remembering(front.dismissalKey, in: dismissedRaw)
                }
            } label: {
                card(front)
                    .background(alignment: .top) {
                        ZStack(alignment: .top) {
                            ForEach(Array(behind.enumerated().reversed()), id: \.element.id) { index, item in
                                let depth = CGFloat(index + 1)
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .scaleEffect(x: 1 - 0.05 * depth, y: 1, anchor: .top)
                                    .offset(y: -Self.peekStep * depth)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .id(front.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity.combined(with: .move(edge: .trailing))))
            }
            .buttonStyle(.plain)
            .padding(.top, Self.peekStep * CGFloat(behind.count))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(front.headline). \(front.detail)")
            .accessibilityHint(behind.isEmpty ? "Removes this card"
                                              : "Removes this card and shows the next of \(shown.count)")
        }
    }

    private func card(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.headline)
                .foregroundStyle(item.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.headline)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect(cornerRadius: 18))
        // Opaque base so the peeking cards behind never show through.
        .background(Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 18))
        .glassEffect(.regular.interactive(),
                     in: .rect(cornerRadius: 18))
    }
}
