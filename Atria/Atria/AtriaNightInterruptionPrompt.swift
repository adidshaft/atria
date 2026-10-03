import Foundation
import SwiftUI

/// Local, private answers to the morning "what was it?" prompt.
///
/// Answers live only in this device's UserDefaults. `AtriaNightInterruptionLabel.isSensitive`
/// labels must never leave the device: every off-device path (export,
/// research sharing, cloud coach) must read answers through
/// `offDeviceAnswers(_:)`, which drops them. Nothing reads this store for an
/// off-device path today; the guard exists so the first one cannot forget.
struct AtriaNightInterruptionAnswer: Codable, Equatable, Sendable {
    let episodeID: String
    let start: Date
    let end: Date
    let kind: String
    /// nil = skipped.
    let label: AtriaNightInterruptionLabel?
    let answeredAt: Date

    var isSkipped: Bool { label == nil }
}

enum AtriaNightInterruptionAnswerStore {
    static let defaultsKey = "atria.nightInterruptions.answers.v1"
    /// Answers are context for recent nights and future personal patterns;
    /// a bounded list keeps the defaults blob small.
    static let maximumAnswers = 400

    static func episodeID(_ episode: AtriaNightTimelineAnalyzer.Episode) -> String {
        "\(episode.kind.rawValue)-\(Int(episode.start.timeIntervalSince1970))"
    }

    static func all(defaults: UserDefaults = .standard) -> [AtriaNightInterruptionAnswer] {
        guard let data = defaults.data(forKey: defaultsKey),
              let answers = try? JSONDecoder().decode([AtriaNightInterruptionAnswer].self, from: data) else {
            // Corrupt or absent: no answers, never a crash or an invented one.
            return []
        }
        return answers
    }

    static func answer(for episode: AtriaNightTimelineAnalyzer.Episode,
                       defaults: UserDefaults = .standard) -> AtriaNightInterruptionAnswer? {
        let id = episodeID(episode)
        return all(defaults: defaults).last { $0.episodeID == id }
    }

    /// Records a label (or a skip when `label` is nil), replacing any
    /// earlier answer for the same episode.
    static func record(_ label: AtriaNightInterruptionLabel?,
                       for episode: AtriaNightTimelineAnalyzer.Episode,
                       now: Date = Date(),
                       defaults: UserDefaults = .standard) {
        let id = episodeID(episode)
        var answers = all(defaults: defaults).filter { $0.episodeID != id }
        answers.append(AtriaNightInterruptionAnswer(episodeID: id,
                                                    start: episode.start,
                                                    end: episode.end,
                                                    kind: episode.kind.rawValue,
                                                    label: label,
                                                    answeredAt: now))
        if answers.count > maximumAnswers { answers = Array(answers.suffix(maximumAnswers)) }
        if let data = try? JSONEncoder().encode(answers) {
            defaults.set(data, forKey: defaultsKey)
            if defaults === UserDefaults.standard {
                NotificationCenter.default.post(name: didRecordNotification, object: nil)
            }
        }
    }

    /// Posted after an answer is saved, so stored sleeps can take it in.
    static let didRecordNotification = Notification.Name("AtriaNightInterruptionAnswerStore.didRecord")

    /// Every answered interruption is time the wearer says they were awake,
    /// whatever the reason ("Couldn't sleep", "Bathroom", ...). Skips are not.
    static func confirmedWakeIntervals(defaults: UserDefaults = .standard) -> [DateInterval] {
        all(defaults: defaults).compactMap { answer in
            guard answer.label != nil, answer.end > answer.start else { return nil }
            return DateInterval(start: answer.start, end: answer.end)
        }
    }

    /// Episodes still waiting for an answer (neither labeled nor skipped).
    static func pending(_ episodes: [AtriaNightTimelineAnalyzer.Episode],
                        defaults: UserDefaults = .standard) -> [AtriaNightTimelineAnalyzer.Episode] {
        let answered = Set(all(defaults: defaults).map(\.episodeID))
        return episodes.filter { !answered.contains(episodeID($0)) }
    }

    /// The ONLY sanctioned read for anything that leaves the device.
    /// Sensitive labels and skips are dropped.
    static func offDeviceAnswers(_ answers: [AtriaNightInterruptionAnswer]) -> [AtriaNightInterruptionAnswer] {
        answers.filter { answer in
            guard let label = answer.label else { return false }
            return !label.isSensitive
        }
    }
}

/// Morning card: "You were up 01:43–02:28 — what was it?" with label chips
/// and a one-tap Skip. Optional and light: one episode at a time, gone once
/// every interruption is answered or skipped.
struct AtriaNightInterruptionPromptCard: View {
    let episodes: [AtriaNightTimelineAnalyzer.Episode]
    var timeZone: TimeZone = .current
    var defaults: UserDefaults = .standard
    /// Bumped after each answer so the card re-reads the store.
    @State private var revision = 0

    private var current: AtriaNightTimelineAnalyzer.Episode? {
        _ = revision
        return AtriaNightInterruptionAnswerStore.pending(episodes, defaults: defaults).first
    }

    static func question(for episode: AtriaNightTimelineAnalyzer.Episode,
                         timeZone: TimeZone,
                         locale: Locale = .current) -> String {
        let clock = AtriaNightTimelinePresentation.clockFormatter(timeZone, locale: locale)
        let span = "\(clock.string(from: episode.start))–\(clock.string(from: episode.end))"
        switch episode.kind {
        case .up: return "You were up \(span) — what was it?"
        default: return "You were restless \(span) — what was it?"
        }
    }

    var body: some View {
        if let episode = current {
            VStack(alignment: .leading, spacing: AtriaDesignTokens.Spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last night").atriaEyebrow()
                    Spacer(minLength: 0)
                    Button("Skip") { answer(nil, episode) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHint("Dismiss this question without an answer")
                }
                Text(Self.question(for: episode, timeZone: timeZone))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                AtriaChipFlow(spacing: 8) {
                    ForEach(AtriaNightInterruptionLabel.allCases, id: \.self) { label in
                        Button(label.title) { answer(label, episode) }
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                            .foregroundStyle(.primary)
                            .buttonStyle(.plain)
                    }
                }
                Text("Private to this phone.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atriaInsetCard(tint: Metrics.electricSleep)
        }
    }

    private func answer(_ label: AtriaNightInterruptionLabel?,
                        _ episode: AtriaNightTimelineAnalyzer.Episode) {
        AtriaNightInterruptionAnswerStore.record(label, for: episode, defaults: defaults)
        withAnimation(.easeOut(duration: 0.2)) { revision += 1 }
    }
}

/// Minimal wrapping row for chips (left-aligned, wraps to new lines).
struct AtriaChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
