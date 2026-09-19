import SwiftUI

/// Bedtime planning may consume only the same motion-qualified efficiency the
/// app is willing to display. HR-only captured/span coverage can be stored for
/// diagnostics, but it is not sleep efficiency and must not move bedtime.
enum AtriaAssistantSleepPlannerEvidence {
    static func efficiencies(from snapshot: SleepHistorySnapshot) -> [Double] {
        snapshot.nights
            .filter { $0.confirmed && !$0.isNapEvidence }
            .compactMap(\.displaySleepEfficiency)
    }
}

/// The Assistant, implemented (2026-07-07, user-directed — previously
/// "Coming Soon"). Two honest layers:
///
/// 1. Question chips answered DETERMINISTICALLY from the app's own engines —
///    the same numbers the rest of the app shows, never a language model,
///    each answer stating where it came from and failing closed to a
///    "still learning" line when the data isn't ready.
/// 2. The existing provider-backed coach card (off by default, local/cloud
///    opt-in with fabrication-flag auditing) for free-form summaries.
struct AtriaAssistantScreen: View {
    let store: SessionStore
    let context: AtriaCoachContext
    let coachPayload: AtriaCoachPayload?
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AtriaDefault("atria.sleepPlanner.goal") private var plannerGoalRaw: String = AtriaSleepPlannerGoal.peak.rawValue
    @AtriaDefault(AtriaWakeAlarmStore.wakeByMinutesKey) private var wakeByMinutes: Int = AtriaWakeAlarmPlan.defaultPlan.wakeByMinutes

    private struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        let answer: String
        let provenance: String
    }

    private struct Prompt: Identifiable {
        let id: String
        let question: String
        let compactTitle: String
    }

    @State private var exchanges: [Exchange] = []

    private static let prompts: [Prompt] = [
        Prompt(id: "recovery", question: "Why is my recovery where it is?", compactTitle: "My recovery"),
        Prompt(id: "sleep", question: "How much sleep do I need tonight?", compactTitle: "Tonight's sleep"),
        Prompt(id: "typical", question: "What's typical for me?", compactTitle: "My baseline"),
        Prompt(id: "behaviors", question: "What's been moving my recovery?", compactTitle: "Recovery drivers"),
        Prompt(id: "week", question: "How was my past week?", compactTitle: "Past week"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            introBubble

            ForEach(exchanges) { exchange in
                exchangeBubbles(exchange)
            }

            promptChips

            if aiCoachSettings.mode != .off {
                AtriaAICoachCard(context: context,
                                 preparedPayload: coachPayload,
                                 settings: aiCoachSettings,
                                 hasAPIKey: aiCoachHasAPIKey)
            }
        }
        .padding(16)
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: exchanges)
    }

    #if DEBUG
    /// Test seam: the deterministic answer + provenance for a prompt id,
    /// without going through a tap. Lets unit tests lock down the honesty
    /// guarantee that every answer fails closed when the data isn't ready.
    func debugAnswer(promptID: String) -> (answer: String, provenance: String) {
        let exchange = answer(for: Prompt(id: promptID, question: "", compactTitle: ""))
        return (exchange.answer, exchange.provenance)
    }
    #endif

    private var introBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("Ask Atria")
                    .font(.headline.weight(.bold))
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.cyan)
            }
            // The on-device promise was a VoiceOver-only hint (2026-09-02);
            // sighted readers saw a shield with no words behind it. One
            // caption says it for everyone.
            Text("Quick answers come from your data on this phone, not generated text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func exchangeBubbles(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(exchange.answer)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(exchange.provenance)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Source: \(exchange.provenance)")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        }
    }

    private var promptChips: some View {
        LazyVGrid(columns: promptColumns,
                  alignment: .leading,
                  spacing: 8) {
            ForEach(Self.prompts.filter { prompt in !exchanges.contains { $0.question == prompt.question } }) { prompt in
                Button {
                    exchanges.append(answer(for: prompt))
                } label: {
                    HStack(spacing: 8) {
                        Text(prompt.compactTitle)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(prompt.question)
                .accessibilityHint("Shows an answer from your recorded data.")
            }
        }
    }

    private var promptColumns: [GridItem] {
        let column = GridItem(.flexible(minimum: 0), spacing: 8, alignment: .topLeading)
        return dynamicTypeSize.isAccessibilitySize ? [column] : [column, column]
    }

    // MARK: deterministic answers

    private func answer(for prompt: Prompt) -> Exchange {
        switch prompt.id {
        case "recovery": return recoveryAnswer(prompt)
        case "sleep": return sleepAnswer(prompt)
        case "typical": return typicalAnswer(prompt)
        case "behaviors": return behaviorsAnswer(prompt)
        default: return weekAnswer(prompt)
        }
    }

    private func recoveryAnswer(_ prompt: Prompt) -> Exchange {
        let headline = context.guidance.headline.isEmpty ? context.guidance.detail : context.guidance.headline
        // Production emits "Learning" (not "--") from HeroSnapshot.recoveryValue
        // when there's no score yet; guard on both so the still-learning line
        // isn't dead code and we never build a "Recovery is Learning." sentence.
        let recoveryReady = context.recoveryText != "Learning" && context.recoveryText != "--"
        let answer = !recoveryReady
            ? "Your recovery is still learning \u{2014} it needs overnight baselines before it can score a morning."
            : "Recovery is \(context.recoveryText). \(headline). Day strain so far is \(String(format: "%.1f", context.strain)) and HRV reads \(context.hrvText)."
        return Exchange(question: prompt.question, answer: answer,
                        provenance: "Today's recovery and coach guidance.")
    }

    private func sleepAnswer(_ prompt: Prompt) -> Exchange {
        let snapshot = store.sleepHistorySnapshot
        guard let latest = snapshot.latestMainSleep else {
            return Exchange(question: prompt.question,
                            answer: "No confirmed nights yet \u{2014} once Atria has a night of sleep, it can plan tonight.",
                            provenance: "Sleep planner · awaiting a confirmed night.")
        }
        let baseNeed = SessionStore.configuredSleepBaseNeedHours()
        guard let need = snapshot.sleepNeedHours(for: latest,
                                                 baseNeedHours: baseNeed,
                                                 yesterdayStrain: nil) else {
            return Exchange(question: prompt.question,
                            answer: "That night's Sleep Need was not saved with the record, so I won't reconstruct a target from today's settings. New nights retain their exact target when they settle.",
                            provenance: "Sleep Need · legacy record unavailable.")
        }
        let goal = AtriaSleepPlannerGoal(rawValue: plannerGoalRaw) ?? .peak
        let plan = AtriaSleepPlanner.plan(needHours: need, goal: goal, wakeByMinutes: wakeByMinutes,
                                          nightEfficiencies: AtriaAssistantSleepPlannerEvidence
                                            .efficiencies(from: snapshot))
        return Exchange(question: prompt.question,
                        answer: "Tonight's need is about \(AtriaMetricFormat.sleepHours(need)). For your \(goal.title) goal, aim to be in bed by \(plan.inBedByText) to get \(AtriaMetricFormat.sleepHours(plan.targetSleepHours)) asleep before your \(String(format: "%d:%02d", wakeByMinutes / 60, wakeByMinutes % 60)) wake-by time.",
                        provenance: "Sleep need, wake time, and \(plan.efficiencyIsDefault ? "typical efficiency while yours is learned" : "your typical efficiency").")
    }

    private func typicalAnswer(_ prompt: Prompt) -> Exchange {
        var lines: [String] = []
        if let resting = store.baseline.restingInt { lines.append("resting HR \(resting) bpm") }
        if let hrv = store.baseline.hrvInt { lines.append("overnight HRV around \(hrv) ms") }
        guard !lines.isEmpty else {
            return Exchange(question: prompt.question,
                            answer: "Your personal baselines are still building \u{2014} they firm up after 14 nights of data.",
                            provenance: "Personal overnight baseline · learning.")
        }
        let trusted = store.baseline.hasTrustedRestingBaseline()
        return Exchange(question: prompt.question,
                        answer: "Typically for you: \(lines.joined(separator: ", ")).\(trusted ? "" : " These are still settling \u{2014} trusted after 14 nights.")",
                        provenance: "Your personal overnight baseline.")
    }

    private func behaviorsAnswer(_ prompt: Prompt) -> Exchange {
        let impacts = Array(store.behaviorImpactSummariesCache.prefix(3))
        guard !impacts.isEmpty else {
            return Exchange(question: prompt.question,
                            answer: "Nothing has cleared the statistical bar yet. Log journal tags on more days \u{2014} a behavior needs 5+ logged days and a real, unlikely-by-chance effect before it shows here.",
                            provenance: "Journal impact analysis · no qualified behaviors.")
        }
        let lines = impacts.map { "\($0.tag.label): \($0.valueText) across \($0.nightsText)" }
        return Exchange(question: prompt.question,
                        answer: lines.joined(separator: "\n"),
                        provenance: "90-day journal associations · not proof of cause.")
    }

    private func weekAnswer(_ prompt: Prompt) -> Exchange {
        let report = WeeklyReport(rollups: store.dailyRollupHistory,
                                  sleepNights: store.sleepHistorySnapshot.nights,
                                  cycleStrainByDisplayDay: store.physiologicalCycleStrainByDisplayDay)
        var parts: [String] = []
        if let recovery = report.recoveryAvg {
            let delta = report.recoveryDeltaVsPriorWeek.map { $0 >= 0 ? " (up \($0) on the prior week)" : " (down \(-$0) on the prior week)" } ?? ""
            parts.append("recovery averaged \(recovery)%\(delta)")
        }
        if let strain = report.strainAvg, strain > 0 { parts.append(String(format: "daily strain averaged %.1f", strain)) }
        if let sleep = report.sleepAvgSeconds, sleep > 0 { parts.append("sleep averaged \(SleepHistorySnapshot.formatDuration(sleep)) a night") }
        guard !parts.isEmpty else {
            return Exchange(question: prompt.question,
                            answer: "Not enough recorded days this week to summarize yet.",
                            provenance: "Weekly report · building.")
        }
        return Exchange(question: prompt.question,
                        answer: "This week: \(parts.joined(separator: "; ")).",
                        provenance: "Weekly report from daily rollups.")
    }
}
