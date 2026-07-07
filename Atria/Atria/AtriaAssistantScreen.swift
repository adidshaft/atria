import SwiftUI

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
    @ObservedObject var store: SessionStore
    let context: AtriaCoachContext
    let coachPayload: AtriaCoachPayload?
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void

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
    }

    @State private var exchanges: [Exchange] = []

    private static let prompts: [Prompt] = [
        Prompt(id: "recovery", question: "Why is my recovery where it is?"),
        Prompt(id: "sleep", question: "How much sleep do I need tonight?"),
        Prompt(id: "typical", question: "What's typical for me?"),
        Prompt(id: "behaviors", question: "What's been moving my recovery?"),
        Prompt(id: "week", question: "How was my past week?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            introBubble

            ForEach(exchanges) { exchange in
                exchangeBubbles(exchange)
            }

            promptChips

            Divider()
                .padding(.vertical, 4)

            Text("FREE-FORM (OPTIONAL)")
                .font(.caption2.weight(.black))
                .foregroundStyle(.tertiary)
                .kerning(0.8)
            AtriaAICoachCard(context: context,
                             preparedPayload: coachPayload,
                             settings: aiCoachSettings,
                             hasAPIKey: aiCoachHasAPIKey,
                             onSettingsChange: onAICoachSettingsChange,
                             onSaveAPIKey: onSaveAICoachAPIKey,
                             onDeleteAPIKey: onDeleteAICoachAPIKey)
        }
        .padding(16)
        .animation(.snappy(duration: 0.25), value: exchanges)
    }

    #if DEBUG
    /// Test seam: the deterministic answer + provenance for a prompt id,
    /// without going through a tap. Lets unit tests lock down the honesty
    /// guarantee that every answer fails closed when the data isn't ready.
    func debugAnswer(promptID: String) -> (answer: String, provenance: String) {
        let exchange = answer(for: Prompt(id: promptID, question: ""))
        return (exchange.answer, exchange.provenance)
    }
    #endif

    private var introBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your data")
                .font(.headline.weight(.bold))
            Text("These answers come straight from your own recorded data on this phone \u{2014} the same math behind every screen, nothing generated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atriaInsetCard(tint: .cyan)
    }

    private func exchangeBubbles(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(exchange.answer)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(exchange.provenance)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var promptChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.prompts.filter { prompt in !exchanges.contains { $0.question == prompt.question } }) { prompt in
                Button {
                    exchanges.append(answer(for: prompt))
                } label: {
                    HStack {
                        Text(prompt.question)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: Capsule(style: .continuous))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
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
        let answer = context.recoveryText == "--"
            ? "Your recovery is still learning \u{2014} it needs overnight baselines before it can score a morning."
            : "Recovery is \(context.recoveryText). \(headline). Day strain so far is \(String(format: "%.1f", context.strain)) and HRV reads \(context.hrvText)."
        return Exchange(question: prompt.question, answer: answer,
                        provenance: "From today's recovery estimate and coach guidance.")
    }

    private func sleepAnswer(_ prompt: Prompt) -> Exchange {
        let snapshot = store.sleepHistorySnapshot
        guard let latest = snapshot.latest else {
            return Exchange(question: prompt.question,
                            answer: "No confirmed nights yet \u{2014} once Atria has a night of sleep, it can plan tonight.",
                            provenance: "Sleep planner (needs at least one confirmed night).")
        }
        let baseNeed = SessionStore.configuredSleepBaseNeedHours()
        let need = snapshot.sleepNeedHours(for: latest, baseNeedHours: baseNeed, yesterdayStrain: nil)
        let goal = AtriaSleepPlannerGoal(rawValue: plannerGoalRaw) ?? .peak
        let plan = AtriaSleepPlanner.plan(needHours: need, goal: goal, wakeByMinutes: wakeByMinutes,
                                          nightEfficiencies: snapshot.nights.filter(\.confirmed).compactMap(\.sleepEfficiency))
        return Exchange(question: prompt.question,
                        answer: "Tonight's need is about \(AtriaMetricFormat.sleepHours(need)). For your \(goal.title) goal, aim to be in bed by \(plan.inBedByText) to get \(AtriaMetricFormat.sleepHours(plan.targetSleepHours)) asleep before your \(String(format: "%d:%02d", wakeByMinutes / 60, wakeByMinutes % 60)) wake-by time.",
                        provenance: "Sleep planner: your need ledger, wake alarm, and \(plan.efficiencyIsDefault ? "a typical-population efficiency (still learning yours)" : "your own typical efficiency").")
    }

    private func typicalAnswer(_ prompt: Prompt) -> Exchange {
        var lines: [String] = []
        if let resting = store.baseline.restingInt { lines.append("resting HR \(resting) bpm") }
        if let hrv = store.baseline.hrvInt { lines.append("overnight HRV around \(hrv) ms") }
        guard !lines.isEmpty else {
            return Exchange(question: prompt.question,
                            answer: "Your personal baselines are still building \u{2014} they firm up after 14 nights of data.",
                            provenance: "Personal baseline (learning).")
        }
        let trusted = store.baseline.hasTrustedRestingBaseline()
        return Exchange(question: prompt.question,
                        answer: "Typically for you: \(lines.joined(separator: ", ")).\(trusted ? "" : " These are still settling \u{2014} trusted after 14 nights.")",
                        provenance: "Your personal baseline, learned from your own nights.")
    }

    private func behaviorsAnswer(_ prompt: Prompt) -> Exchange {
        let impacts = Array(store.behaviorImpactSummariesCache.prefix(3))
        guard !impacts.isEmpty else {
            return Exchange(question: prompt.question,
                            answer: "Nothing has cleared the statistical bar yet. Log journal tags on more days \u{2014} a behavior needs 5+ logged days and a real, unlikely-by-chance effect before it shows here.",
                            provenance: "Behavior impact engine (no qualifying behaviors yet).")
        }
        let lines = impacts.map { "\($0.tag.label): \($0.valueText) across \($0.nightsText)" }
        return Exchange(question: prompt.question,
                        answer: lines.joined(separator: "\n"),
                        provenance: "Your journal tags vs next-day recovery over 90 days. Association, not proof of cause.")
    }

    private func weekAnswer(_ prompt: Prompt) -> Exchange {
        let report = WeeklyReport(rollups: store.dailyRollupHistory)
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
                            provenance: "Weekly report (building).")
        }
        return Exchange(question: prompt.question,
                        answer: "This week: \(parts.joined(separator: "; ")).",
                        provenance: "Your weekly report, computed from daily rollups.")
    }
}
