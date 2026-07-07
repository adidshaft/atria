#!/usr/bin/env python3
import math
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
APP_ROOTS = [ROOT / "Atria" / "Atria", ROOT / "Atria" / "AtriaWidget"]


def swift_files():
    for root in APP_ROOTS:
        yield from root.rglob("*.swift")


def source(path):
    return path.read_text(encoding="utf-8")


def all_swift_source():
    return "\n".join(source(path) for path in swift_files())


def swift_braced_blocks(text, patterns):
    blocks = []
    matches = []
    for pattern in patterns:
        matches.extend(re.finditer(pattern, text))
    for match in sorted(matches, key=lambda item: item.start()):
        index = match.start()
        brace = text.find("{", index)
        if brace == -1:
            continue
        depth = 0
        for pos in range(brace, len(text)):
            char = text[pos]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    blocks.append((index, text[index:pos + 1]))
                    break
    return blocks


def swift_var_body_blocks(text):
    return swift_braced_blocks(text, [r"\bvar\s+body\s*:\s*some\s+View\b"])


def swift_some_view_blocks(text):
    return swift_braced_blocks(text, [
        r"\bvar\s+\w+\s*:\s*some\s+View\b",
        r"\bfunc\s+\w+(?:<[^>{}]+>)?\s*\([^{}]*?\)\s*->\s*some\s+View\b",
    ])


def assert_contains(testcase, haystack, needle):
    testcase.assertTrue(needle in haystack, f"missing required source token: {needle}")


def assert_not_contains(testcase, haystack, needle):
    testcase.assertFalse(needle in haystack, f"forbidden source token present: {needle}")


def today_metric_defaults():
    overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
    hidden_match = re.search(
        r"let metrics: \[AtriaTodayMetric\] = \[(?P<body>[^\]]+)\]",
        overview,
    )
    order_match = re.search(
        r"static var defaultGlanceOrder: \[AtriaTodayMetric\] \{\n        \[(?P<body>[^\]]+)\]",
        overview,
    )
    if not hidden_match or not order_match:
        raise AssertionError("Could not parse AtriaTodayMetric defaults")

    def parse_cases(body):
        return re.findall(r"\.([A-Za-z0-9_]+)", body)

    return parse_cases(hidden_match.group("body")), parse_cases(order_match.group("body"))


TODAY_NO_HIDDEN_SENTINEL = "__atria_all_today_cards_visible__"


def today_hidden_from_csv(csv):
    default_hidden, _ = today_metric_defaults()
    trimmed = csv.strip()
    if not trimmed:
        return set(default_hidden)
    if trimmed == TODAY_NO_HIDDEN_SENTINEL:
        return set()
    return {part for part in trimmed.split(",") if part}


def today_hidden_storage_value(hidden):
    return TODAY_NO_HIDDEN_SENTINEL if not hidden else ",".join(sorted(hidden))


def today_ordered(csv):
    _, default_order = today_metric_defaults()
    decoded = [part for part in csv.split(",") if part in default_order]
    result = []
    seen = set()
    for metric in decoded + default_order:
        if metric in default_order and metric not in seen:
            result.append(metric)
            seen.add(metric)
    return result


def today_visible_ordered(order_csv, hidden_csv):
    hidden = today_hidden_from_csv(hidden_csv)
    return [metric for metric in today_ordered(order_csv) if metric not in hidden]


def today_hidden_ordered(order_csv, hidden_csv):
    hidden = today_hidden_from_csv(hidden_csv)
    return [metric for metric in today_ordered(order_csv) if metric in hidden]


def today_moving_before(dragged, target, csv):
    ordered = today_ordered(csv)
    if dragged == target:
        return ",".join(ordered)
    order = [metric for metric in ordered if metric != dragged]
    try:
        index = order.index(target)
    except ValueError:
        index = len(order)
    order.insert(index, dragged)
    return ",".join(order)


def today_merge_visible_slots(order, hidden, visible):
    visible_iter = iter(visible)
    return [metric if metric in hidden else next(visible_iter, metric) for metric in order]


def today_moving_visible_before(dragged, target, csv, hidden_csv):
    hidden = today_hidden_from_csv(hidden_csv)
    ordered = today_ordered(csv)
    visible = [metric for metric in ordered if metric not in hidden]
    if dragged == target or dragged not in visible or target not in visible:
        return today_moving_before(dragged, target, csv)
    next_visible = [metric for metric in visible if metric != dragged]
    try:
        index = next_visible.index(target)
    except ValueError:
        index = len(next_visible)
    next_visible.insert(index, dragged)
    return ",".join(today_merge_visible_slots(ordered, hidden, next_visible))


def today_moving_direction(metric, direction, csv):
    order = today_ordered(csv)
    if metric not in order:
        return ",".join(order)
    index = order.index(metric)
    next_index = max(0, min(len(order) - 1, index + direction))
    if next_index != index:
        order[index], order[next_index] = order[next_index], order[index]
    return ",".join(order)


def today_moving_visible_direction(metric, direction, csv, hidden_csv):
    hidden = today_hidden_from_csv(hidden_csv)
    ordered = today_ordered(csv)
    visible = [item for item in ordered if item not in hidden]
    if metric not in visible:
        return today_moving_direction(metric, direction, csv)
    index = visible.index(metric)
    next_index = max(0, min(len(visible) - 1, index + direction))
    if next_index == index:
        return ",".join(ordered)
    visible[index], visible[next_index] = visible[next_index], visible[index]
    return ",".join(today_merge_visible_slots(ordered, hidden, visible))


class HandoffStaticChecks(unittest.TestCase):
    def test_vis1_dashboard_scroll_final_requires_release_fps_threshold(self):
        script = source(ROOT / "tools" / "capture_dashboard_scroll_performance.sh")
        evidence = source(ROOT / "tools" / "prepare_accessibility_performance_evidence.py")

        assert_contains(self, evidence, "MIN_SCROLL_FPS = 58.0")
        assert_contains(self, script, "if value < 58:")
        assert_contains(self, script, "Final mode requires measured FPS >= 58; got %s.")
        assert_contains(self, script, "--measured-fps-source PATH")
        assert_contains(self, script, "Final measured FPS override requires --measured-fps-source PATH.")
        assert_contains(self, script, "Final measured FPS source does not exist: %s")
        assert_contains(self, script, "Measured FPS override source: %s")
        assert_contains(self, script, "measured-fps-source")
        assert_contains(self, script, "cp \"$measured_fps_source\" \"$measured_fps_source_copy\"")
        assert_contains(self, script, "Measured FPS override source copy: %s")
        assert_contains(self, script, 'status = "zero" if fps_max <= 0 else "ok"')
        assert_contains(self, script, "FPS table exported, but all rows were zero; this is not accepted VIS-1 scroll evidence.")
        assert_contains(self, script, "--auto-scroll")
        assert_contains(self, script, "ATRIA_DASHBOARD_AUTOSCROLL")
        assert_contains(self, script, "dashboard-autoscroll")
        assert_not_contains(self, script, "Final mode requires positive measured FPS")

        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        for needle in [
            "ScrollViewReader { scrollProxy in",
            "atria-dashboard-scroll-top",
            "atria-dashboard-scroll-bottom",
            "runDebugDashboardAutoScrollIfNeeded(proxy: scrollProxy, title: title)",
            "debugDashboardAutoScrollEnabled(arguments: ProcessInfo.processInfo.arguments)",
            'debugLaunchFixtureValue(arguments: arguments) == "dashboard-autoscroll"',
            'ProcessInfo.processInfo.environment["ATRIA_DASHBOARD_AUTOSCROLL"] == "1"',
        ]:
            assert_contains(self, home, needle)

    def test_feat5_workout_prompt_gate_and_fixture_tokens_are_present(self):
        evaluator = source(ROOT / "Atria" / "Atria" / "AtriaWorkoutPromptEvaluator.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "static let minimumSustainedSamples = 480",
            "static let minimumBPMOverRest = 25",
            "static let zoneLookbackSeconds: TimeInterval = 6 * 60",
            "static let zoneMinimumSamples = 240",
            "static let zoneMinimumIndex = 3",
            "static let cooldown: TimeInterval = 45 * 60",
            "let sustainedPath = elevatedSamples >= minimumSustainedSamples && currentElevated",
            "let zonePath = zoneSamples >= zoneMinimumSamples",
            "return Result(shouldPrompt: sustainedPath || zonePath,",
            "static func isInCooldown(dismissedUntil: Date?, now: Date = Date()) -> Bool",
        ]:
            assert_contains(self, evaluator, needle)

        for needle in [
            "private static let workoutPromptCooldown: TimeInterval = AtriaWorkoutPromptEvaluator.cooldown",
            "AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: workoutPromptDismissedUntil, now: now)",
            "AtriaWorkoutPromptEvaluator.evaluate(samples: ble.session,",
            'arguments[valueIndex] == "workout-detection-zone-path"',
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func testWorkoutPromptEvaluatorFiresForEightMinutesAtRestPlusTwentySeven()",
            "func testWorkoutPromptEvaluatorRejectsTwentyMinutesAtRestPlusTwenty()",
            "func testWorkoutPromptEvaluatorFiresForFourMinutesInZoneThree()",
            "func testWorkoutPromptCooldownLatchExpiresAfterFortyFiveMinutes()",
            "XCTAssertFalse(AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: dismissedUntil,",
        ]:
            assert_contains(self, tests, needle)

    def test_feat2_bedtime_suggestion_tokens_are_present(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "func bedtimeSuggestionText(now: Date = Date(),",
            "guard calendar.component(.hour, from: now) >= 21 else { return nil }",
            "if let latest, !latest.confirmed, !latest.isNapEvidence { return nil }",
            ".prefix(14)",
            "return \"In bed by \\(Self.formatClockMinute(bedtimeMinute)) to hit \\(AtriaMetricFormat.sleepHours(targetHours))\"",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "private var sleepPlanBedtimeText: String?",
            "sleepHistory.bedtimeSuggestionText(now: debugFixtureNow,",
            "private var debugFixtureNow: Date",
            "ProcessInfo.processInfo.arguments.firstIndex(of: \"--atria-ui-now\")",
            "ProcessInfo.processInfo.arguments[valueIndex] == \"sleep-plan-bedtime\"",
            "debug-ui-fixture-sleep-plan-bedtime-\\(index)",
            "if debugShowsSleepPlanOnly {",
            "private var debugShowsSleepPlanOnly: Bool",
            "bedtimeText: sleepPlanBedtimeText,",
            "let bedtimeText: String?",
            "Text(bedtimeText)",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "let overviewContentFixtures = [\"sleep-plan-bedtime\", \"north-star-highlights\"]",
            "let shouldShowOverviewFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { overviewContentFixtures.contains($0) } ?? false",
            "|| shouldShowOverviewFixture",
            "Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == \"sleep-plan-bedtime\"",
            "if showsHero && !debugShowsSleepPlanBedtimeFixture {",
            "shouldLeadWithSystemBanners && !debugShowsSleepPlanBedtimeFixture && !debugShowsNorthStarTodayFixture",
            "private var debugShowsSleepPlanBedtimeFixture: Bool",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func testSleepHistorySnapshotSuggestsBedtimeAfterNineFromMedianWake()",
            "\"In bed by 11:20 to hit 8 h 20 m\"",
            "XCTAssertNil(snapshot.bedtimeSuggestionText(now: day.addingTimeInterval(20 * 60 * 60),",
        ]:
            assert_contains(self, tests, needle)

    def test_graph_readability_handoff_tokens_are_present(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        trend_chart = source(ROOT / "Atria" / "Atria" / "AtriaTrendChart.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")

        for needle in [
            "AtriaOverviewGuidanceSectionHost(heroStore: heroStore,",
            "private var sleepDebtValueText: String",
            "if let latest = sleepHistory.latest, !latest.confirmed",
            'return latest.isNapEvidence ? "Nap separate" : "Review"',
            "let debt = sleepHistory.sleepDebtText(goalHours: sleepGoalHours)",
            'return debt == "--" ? "Building" : debt',
            "private var sleepPlanTargetHours: Double",
            "sleepHistory.sleepNeedHours(for: latest, baseNeedHours: sleepBaseNeedHours)",
            "sleepHistory.sleepBudgetDebtHours(baseNeedHours: sleepBaseNeedHours)",
            "private var sleepPlanProgress: Double",
            "private var sleepPlanStatusText: String",
            "private var sleepPlanDebtText: String",
            "private var sleepPlanRoutineText: String",
            "private var sleepPlanBedtimeText: String?",
            "sleepHistory.bedtimeSuggestionText(now: debugFixtureNow,",
            "AtriaSleepPlanStrip(statusText: sleepPlanStatusText,",
            "bedtimeText: sleepPlanBedtimeText,",
            "AtriaDayPlanLane(position: dayLanePosition,",
            "private var dayLanePosition: Double",
            "private var dayLaneDetailText: String",
            'return "Baseline forming"',
            'return "Wear a few mornings to unlock targets."',
            'return "Target strain building"',
            'guard let target = hero.guidance.target else { return "Building" }',
            "private struct AtriaDayPlanLane: View, Equatable",
            "Label(\"Day lane\", systemImage: \"point.topleft.down.curvedto.point.bottomright.up\")",
            "laneSegment(label: \"Recover\", tint: .cyan)",
            "laneSegment(label: \"Hold\", tint: .secondary)",
            "laneSegment(label: \"Push\", tint: Metrics.electricStrain)",
            "Day lane. \\(cueText). \\(detailText). Recover, hold, push scale.",
            "private var planBalanceRail: some View",
            "planBalanceStep(systemImage: hero.recoveryEstimate.confidence == .learning ? \"clock.badge.checkmark\" : \"heart.circle.fill\"",
            "planBalanceStep(systemImage: \"bolt.heart.fill\"",
            "planBalanceStep(systemImage: \"moon.zzz.fill\"",
            "private func planBalanceStep(systemImage: String, title: String, value: String, tint: Color) -> some View",
            "Plan balance. \\(hero.recoveryEstimate.confidence == .learning ? \"Baseline\" : \"Recovery\")",
            "ProgressView(value: clampedProgress)",
            ".atriaInsetCard(cornerRadius: 20, tint: .cyan)",
            "Tonight sleep plan.",
            'Sleep \\(sleepDebtValueText).',
            "&& lhs.sleepGoalHours == rhs.sleepGoalHours",
            "AtriaDisconnectedOverviewPanel(status: statusStore.state.status,",
            "livePulseOverride: liveStore.state.hasRecentHeartRateSample",
            "private var effectiveStatus: AtriaBLEManager.Status",
            "private var effectiveStatus: AtriaBLEManager.Status {\n        switch status",
            "return livePulseOverride ? .connected : status",
            "AtriaDisconnectedOverviewAutomaticCard(status: effectiveStatus,",
            "AtriaMetricDetailSheet(metric: detail,",
            "AtriaMetricMeaningSheet(metric: metric,",
            "AtriaStrainBandGauge(strain: latest,",
            "AtriaPanelSectionHeader(title: \"Today's Plan\", subtitle: \"What to do today\")",
            "private struct AtriaSleepReviewHost: View",
            "private struct AtriaSleepSyncNeededHost: View",
            "private struct AtriaSleepSyncNeededCard: View, Equatable",
            "suppressSleepSyncPrompt: Bool = false",
            "self.suppressSleepSyncPrompt = suppressSleepSyncPrompt",
            "suppressSleepSyncPrompt: suppressSleepSyncPrompt",
            "let suppressForPrimaryReview: Bool",
            "if debugShowsPendingSleepReview { return false }",
            "guard rangeLossBackfillPending else { return false }",
            "guard !suppressForPrimaryReview else { return false }",
            "guard snapshot.latest == nil else { return false }",
            "guard snapshot.candidateCount == 0 else { return false }",
            "store.latestSleepReviewNightForUI(rest: store.baseline.restingInt ?? 60,",
            'source: "sleep_sync_needed_card") == nil',
            "static func debugShowsPendingSleepReview(arguments: [String]) -> Bool",
            'arguments[valueIndex] == "pending-sleep-review"',
            "AtriaSleepSyncNeededHost(store: store,",
            "rangeLossBackfillPending: liveStore.state.rangeLossBackfillPending",
            "protectsLiveStream: liveStore.state.status == .connected",
            "&& liveStore.state.sessionSampleCount > 0",
            "if !debugShowsDailyFocusOnly",
            "private var debugShowsDailyFocusOnly: Bool",
            '["daily-focus-rail", "nap-only-morning"].contains(ProcessInfo.processInfo.arguments[valueIndex])',
            "let protectsLiveStream: Bool",
            'Text(protectsLiveStream ? "Sleep recording protected" : "Sync sleep data")',
            "Keep wearing. Atria will sync the gap after recording is safe.",
            "Pull missed strap data. If Atria finds sleep, review it next.",
            'title: protectsLiveStream ? "Live" : "Sync"',
            'value: protectsLiveStream ? "Protected" : "Ready"',
            'value: protectsLiveStream ? "Recording" : "Waiting"',
            'value: protectsLiveStream ? "Morning" : "If found"',
            'arguments[valueIndex] == "sleep-sync-needed"',
            "@State private var adjustmentNight: SleepHistorySnapshot.Night?",
            "store.confirmSleepHistoryNightForUI(night,",
            "onAdjust: { adjustmentNight = night }",
            "AtriaManualSleepSheet(initialStart: adjustment.start,",
            'source: "overview_sleep_review_adjust"',
            'Label("Adjust", systemImage: "slider.horizontal.3")',
            'Label("Dismiss", systemImage: "xmark.circle")',
            '.accessibilityHint("Change the time window or save this as sleep or nap.")',
            '.accessibilityHint("Dismisses this review without saving it.")',
            # 2026-07-07: review-card title migrated to the design handoff's
            # detection-provenance copy ("Sleep detected" / "Nap detected").
            'private var title: String { isNap ? "Nap detected" : "Sleep detected" }',
            "Circle()",
            "sleepReviewActionButtons",
            "private var sleepReviewActionButtons: some View",
            "private var sleepReviewNightArc: some View",
            "nightArcNode(title: \"Start\"",
            "nightArcNode(title: \"Window\"",
            "nightArcNode(title: \"Wake\"",
            "private func nightArcNode(title: String,",
            "private func nightArcConnector(active: Bool) -> some View",
            "private var durationTargetHours: Double",
            "private var durationProgress: Double",
            "\"Nap · review separate\"",
            "Text(\"Why today's recovery landed here\")",
            "private struct AtriaRecoveryContributorMap: View",
            "Baseline sits in the middle. Factors to the right supported recovery; factors to the left pulled it down.",
            "private var supportMagnitude: Double",
            "private var pressureMagnitude: Double",
            "contributorBalanceStrip",
            "private var contributorBalanceStrip: some View",
            "Label(\"Recovery balance\", systemImage: \"scale.3d\")",
            "Text(balanceText)",
            "Recovery balance. \\(balanceText).",
            "private var balanceText: String",
            "private var balanceTint: Color",
            "return \"Supported\"",
            "return \"Pressured\"",
            "return \"Mixed\"",
            "contributorRail(contributor)",
            "directionText(for: contributor)",
            "case \"recovery-detail\", \"recovery-detail-nutrition\":",
            "case \"sleep-detail\":",
            "debugMetricDetailRecoveryEstimate",
            "private struct AtriaDetailPeriodSummary: Equatable",
            "private struct AtriaDetailPeriodSummaryStrip: View",
            "AtriaDetailPeriodSummary(points: recoveryPoints, unit: \"%\")",
            "AtriaDetailPeriodSummary(points: hrvPoints, unit: \"ms\")",
            "AtriaDetailPeriodSummary(points: restingPoints, unit: \"bpm\")",
            "AtriaDetailPeriodSummary(points: sleepPoints, unit: \"h\")",
            "AtriaDetailPeriodSummary(points: strainPoints, unit: \"\")",
            "AtriaDetailRangeDotStrip(points: points,",
            "private struct AtriaDetailRangeDotStrip: View, Equatable",
            "private struct Bar: Equatable, Identifiable",
            "private let bars: [Bar]",
            "AtriaDetailPeriodSummaryStrip(summary: summary,",
            # 2026-07-06: AtriaDetailPeriodReportCard call removed from metricChart
            # (detail-sheet redesign collapsed 3 redundant latest/avg/change cards
            # into the single AtriaDetailPeriodSummaryStrip). Struct definition kept
            # as uncalled scaffolding, so its declaration/internal pins still hold.
            "comparison: comparison,",
            "let latestPosition: Double",
            "private enum AtriaDetailPeriodChangeDirection",
            "summaryRangeRail",
            "summaryMiniStat(label: \"Avg\", value: summary.averageText)",
            "summaryMiniStat(label: \"Range\", value: summary.rangeText)",
            ".chartYScale(domain: chartDomain(points: points, baselineBand: baselineBand))",
            "private func chartDomain(points: [AtriaDetailChartPoint], baselineBand: AtriaDetailBaselineBand?) -> ClosedRange<Double>",
            "return AtriaTrendChartScale.domain(values: values)",
        ]:
            assert_contains(self, overview, needle)

        # TODO(unbuilt spec): docs/23 "Sleep review morning wording checkpoint" (July 1,
        # 2026) describes a wakeReviewCheckpoint/reviewStateText/countStateText header
        # plus a reviewProgressRail (Strap/Time/Save steps) replacing the plain night
        # arc inside AtriaSleepReviewCard, but that redesign was never actually landed
        # in AtriaOverviewSections.swift -- the card still ships the simpler
        # sleepReviewNightArc (Start/Window/Wake, no "Counts" node or windowImpactText)
        # this test already pins above. Revisit if/when that checkpoint redesign ships.

        sleep_sync_start = overview.index("private struct AtriaSleepSyncNeededCard")
        sleep_sync_end = overview.index("private struct AtriaSleepReviewCard", sleep_sync_start)
        sleep_sync_source = overview[sleep_sync_start:sleep_sync_end]
        for stale_copy in [
            "Sleep sync needed",
            "if a sleep window appears",
            "After sync",
        ]:
            assert_not_contains(self, sleep_sync_source, stale_copy)
        contributor_start = overview.index("private struct AtriaRecoveryContributorMap")
        contributor_end = overview.index("private struct AtriaMetricMeaningSheet", contributor_start)
        contributor_source = overview[contributor_start:contributor_end]
        assert_not_contains(self, contributor_source, "Signals to the right")
        assert_not_contains(self, contributor_source, "Signal balance")
        assert_not_contains(self, contributor_source, "Recovery signal balance")
        guidance_start = overview.index("struct AtriaOverviewGuidanceSection")
        guidance_end = overview.index("private struct AtriaDayPlanLane", guidance_start)
        guidance_source = overview[guidance_start:guidance_end]
        ordered_guidance_needles = [
            "AtriaDayPlanLane(position: dayLanePosition,",
            "AtriaSleepPlanStrip(statusText: sleepPlanStatusText,",
            "planBalanceRail",
        ]
        last_index = -1
        for needle in ordered_guidance_needles:
            next_index = guidance_source.index(needle)
            self.assertGreater(next_index, last_index, needle)
            last_index = next_index
        assert_not_contains(self, guidance_source, "private func planPill")
        assert_not_contains(self, guidance_source, 'planPill(title: "Strain"')
        assert_not_contains(self, guidance_source, 'planPill(title: "Sleep debt"')
        for needle in [
            '"Learning baseline"',
            '"A few more mornings before strain targets unlock."',
            '"Target strain learning"',
            'return "Learning"',
        ]:
            assert_not_contains(self, guidance_source, needle)
        # TODO(unbuilt spec): reviewProgressRail/reviewProgressStep (the compact
        # "Strap"/"Time"/"Save" review path from later docs/23 checkpoints) was never
        # landed -- AtriaSleepReviewCard's compact path is still sleepReviewActionButtons
        # -> sleepReviewNightArc (pinned above). The older-iteration copy this test cares
        # about is checked directly against the whole file below instead of a
        # reviewProgressRail-scoped slice.
        for needle in [
            'title: "Signal"',
            'value: "Strap"',
            "Sleep review path: strap signal",
            'title: "Captured"',
            'title: "Adjust"',
            'title: isNap ? "Save nap" : "Count"',
            'value: isNap ? "Separate" : "Pending"',
            "Sleep review progress: captured from strap heart rate",
        ]:
            assert_not_contains(self, overview, needle)
        assert_not_contains(self, overview, "private var sleepReviewClassificationLens")
        assert_not_contains(self, overview, "private func sleepReviewLensChip")
        assert_not_contains(self, overview, "sleepReviewLensChip(title:")
        assert_not_contains(self, overview, "private var sleepReviewDecisionPulse")
        assert_not_contains(self, overview, "private func decisionPulseStep")
        assert_not_contains(self, overview, "private var sleepReviewImpactStrip")
        assert_not_contains(self, overview, "private func sleepImpactStep")
        assert_not_contains(self, overview, "Heart rate captured, window editable")
        assert_not_contains(self, overview, "strap heart rate captured, review the window")
        assert_not_contains(self, overview, "Sleep review lens. Detected")
        card_start = overview.index("private struct AtriaSleepReviewCard")
        card_end = overview.index("struct AtriaOverviewLeadingSection", card_start)
        card_source = overview[card_start:card_end]
        self.assertLess(card_source.index("sleepReviewActionButtons"),
                        card_source.index("sleepReviewNightArc"),
                        "Sleep review actions should appear before detailed evidence rails.")
        # TODO(unbuilt spec): reviewProgressRail (the compact review path meant to sit
        # before sleepReviewNightArc) was never landed -- see TODO above. No ordering
        # assertion for it until it exists.
        for stale_copy in [
            "Atria found a nap",
            "Atria found your sleep",
            "Nap waiting",
            "Sleep waiting",
            "Separate until saved",
            "Confirm to count",
            'Label("Not me", systemImage: "xmark.circle")',
            "Dismisses this detection without saving it.",
            "impactText: windowImpactText,\n                                        durationProgress: durationProgress",
            "AtriaSleepReviewWindowStrip",
            "windowStripImpactText",
            "windowQualityText",
            "windowModeText",
        ]:
            assert_not_contains(self, card_source, stale_copy)
        night_arc_start = card_source.index("private var sleepReviewNightArc")
        night_arc_end = card_source.index("private func nightArcNode", night_arc_start)
        night_arc_source = card_source[night_arc_start:night_arc_end]
        assert_not_contains(self, night_arc_source, 'nightArcNode(title: "Impact"')
        assert_not_contains(self, night_arc_source, "impact \\(windowImpactText)")

        for needle in [
            "case day",
            "case sixMonths",
            "case .day: return 1",
            "case .sixMonths: return 180",
            'case .day: return "today"',
            'case .quarter: return "3 months"',
            'case .sixMonths: return "6 months"',
            'case .day: return "Day"',
            'case .quarter: return "3M"',
            'case .sixMonths: return "6M"',
            'case .day: return "D"',
            'case .quarter: return "3M"',
            "var headerLabel: String",
            'case .day: return "Today"',
            'default: return "Last \\(label)"',
            "var narrativeLabel: String",
            'case .quarter: return "3 months"',
            'case .sixMonths: return "6 months"',
            'AtriaPanelSectionHeader(title: "Trends", subtitle: "\\(range.headerLabel) · \\(prepared.series.count) days")',
            "case .strain: return Metrics.electricStrain",
            "func cutoffDate(now: Date = Date(), calendar: Calendar = .current) -> Date",
            "return calendar.startOfDay(for: now)",
            # 2026-07-05: cutoffDate's shared branch grew .year alongside the
            # existing week/month/quarter/sixMonths cases when the trends
            # range picker extended to 1Y/All; .all now has its own
            # `.distantPast` branch instead of falling through this one.
            "case .week, .month, .quarter, .sixMonths, .year:",
            "Picker(\"Range\", selection: $range)",
            "Text(item.segmentedLabel)",
            ".accessibilityLabel(item.menuLabel)",
            "@State private var rangeCoverage: [AtriaTrendRange: Int] = [:]",
            "AtriaTrendRangeDock(selectedRange: $range,",
            "if periodReadout.hasEnoughSignal",
            "AtriaTrendPeriodBalanceMap(readout: periodReadout)",
            "AtriaTrendGlanceBoard(readout: periodReadout)",
            "AtriaTrendRangeReportCard(readout: periodReadout)",
            "private struct AtriaTrendGlanceBoard: View, Equatable",
            "glanceLane(title: \"Recovery\"",
            "glanceLane(title: \"Strain\"",
            "metricGauge(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "metricGauge(label: \"RHR\", delta: readout.restingHR, tint: .pink)",
            "metricGauge(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            "Trend glance. \\(readout.title). \\(heroCue). Recovery",
            "AtriaTrendPeriodComparisonStrip(readout: readout)",
            "private struct AtriaTrendPeriodReadout: Equatable",
            "var hasPriorSignal: Bool",
            "hrv.hasPrevious || restingHR.hasPrevious || strain.hasPrevious",
            "return \"Recovery needs care\"",
            "if title.hasPrefix(\"Recovery needs care\") { return .cyan }",
            "private struct AtriaTrendPeriodOrbit: View, Equatable",
            "orbitGauge(label: \"HRV\"",
            "orbitGauge(label: \"RHR\"",
            "orbitGauge(label: \"Strain\"",
            "Trend period orbit for \\(readout.rangeLabel). HRV",
            "private struct AtriaTrendPeriodBalanceMap: View, Equatable",
            "Label(\"Balance map\", systemImage: \"circle.grid.cross\")",
            "Balance map. Recovery reserve \\(Int((readout.recoveryReserve * 100).rounded())) percent.",
            "private struct AtriaTrendPeriodLens: View, Equatable",
            "lensChip(title: \"Period\"",
            "lensChip(title: \"Cue\"",
            "lensChip(title: \"Compare\"",
            "value: readout.hasPriorSignal ? \"Prior\" : \"Building\"",
            "Trend period lens. \\(readout.rangeLabel). Cue \\(readout.balanceCue). Prior comparison",
            "private struct AtriaTrendPeriodHeroCard: View, Equatable",
            "Period report. \\(readout.title). \\(heroCue). Reserve",
            "Load \\(Int((readout.loadPressure * 100).rounded())) percent. HRV",
            "periodGauge(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "periodGauge(label: \"RHR\", delta: readout.restingHR, tint: .pink)",
            "periodGauge(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            "private var heroCue: String",
            "if readout.title.hasPrefix(\"Recovery needs care\") { return \"Protect\" }",
            "return \"Protect\"",
            "return \"Ready\"",
            "private struct AtriaTrendPeriodDelta: Equatable",
            "private struct AtriaTrendPeriodComparisonStrip: View, Equatable",
            "Label(\"Now vs prior\", systemImage: \"rectangle.split.3x1\")",
            "comparisonRow(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "comparisonRow(label: \"RHR\", delta: readout.restingHR, tint: .pink)",
            "comparisonRow(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            "let currentWidth = max(6, width * delta.currentProgress)",
            "let priorWidth = max(4, width * delta.previousProgress)",
            "var currentProgress: Double",
            "var previousProgress: Double",
            "private func progress(for value: Double?) -> Double",
            "metric.periodComparisonFloor",
            "var periodComparisonFloor: Double",
            "private static func prepareRangeCoverage(points: [AtriaTrendPoint]",
            "rangeCoverage = Self.prepareRangeCoverage(points: points,",
            "AtriaTrendRangeDock(selectedRange: $range,",
            "private struct AtriaTrendRangeDock: View",
            "@Binding var selectedRange: AtriaTrendRange",
            "ForEach(AtriaTrendRange.allCases) { range in",
            "withAnimation(.snappy(duration: 0.22))",
            "selectedRange = range",
            ".accessibilityLabel(\"\\(range.menuLabel) trend range, \\(rangeStatusText(for: range))\")",
            "rangeStatusText(for: selectedRange)",
            "private func rangeNode(for range: AtriaTrendRange) -> some View",
            "private func confidenceProgress(for range: AtriaTrendRange) -> CGFloat",
            "private struct AtriaTrendPreparedSeries",
            "@State private var prepared = AtriaTrendPreparedSeries.empty",
            "private static func prepareSeries(points: [AtriaTrendPoint]",
            "let cutoff = range.cutoffDate(now: now)",
            # 2026-07-05: previousCutoff now gates on `range.hasPriorPeriod`
            # (`.all` has no earlier window to overlay/diff against) instead
            # of always subtracting `range.days`; the unconditional form
            # below is still present in the guarded expression.
            "range.hasPriorPeriod",
            "var previousSamples: [AtriaTrendPoint.Sample] = []",
            "private struct AtriaTrendRangeSummary: Equatable",
            "private struct AtriaTrendRangeSummaryStrip: View",
            "AtriaTrendRangeSummary(series: samples,",
            "previousSeries: previousSamples",
            "let priorAverageText: String?",
            "self.rangeText = metric.rangeText(low: low, high: high)",
            "AtriaTrendRangeSummaryStrip(summary: summary, tint: metric.tint)",
            "summaryPill(label: \"Range\", value: summary.rangeText)",
            "summaryPill(label: \"Prior\", value: priorAverageText)",
            "AtriaTrendRangePositionBand(series: prepared.series,",
            "private struct AtriaTrendRangePositionBand: View, Equatable",
            "Text(\"Current position\")",
            "return metric.lowPositionText",
            "return \"middle of range\"",
            "return metric.highPositionText",
            "bandLabel(\"Low\", value: low)",
            "bandLabel(\"Now\", value: latest)",
            "bandLabel(\"High\", value: high)",
            "var lowPositionText: String",
            "var highPositionText: String",
            "func rangeText(low: Double, high: Double) -> String",
            "enum AtriaTrendChartScale",
            "static func domain(values: [Double], paddingRatio: Double = 0.16) -> ClosedRange<Double>",
            ".chartYScale(domain: prepared.yDomain)",
        ]:
            assert_contains(self, trend_chart, needle)
        assert_not_contains(self, trend_chart, "private var rangedPoints")
        assert_not_contains(self, trend_chart, "private var series")
        assert_not_contains(self, trend_chart, "Menu {")
        assert_not_contains(self, trend_chart, 'return "sparkles"')

        for needle in [
            "@Published private(set) var dailyMetricHistory: [SavedDailyMetric] = []",
            "@Published private(set) var dailyMetricSparklines = DailyMetricSparklineCache.empty",
            "private nonisolated static func makeSavedDailyMetrics(",
            "private nonisolated static func makeDailyMetricSparklines(from history: [SavedDailyMetric]) -> DailyMetricSparklineCache",
            # 2026-07-05: mergeDailyMetricHistory and makeMorningFrozenDailyMetric
            # dropped `private` (now plain `nonisolated static func`) so the
            # HR-only-sleep + today-rollup-from-wear unit tests can call them
            # directly, matching the existing partitionSessionsForPersist
            # pure-static-testing pattern.
            "nonisolated static func mergeDailyMetricHistory(",
            "nonisolated static func makeMorningFrozenDailyMetric(",
            "private nonisolated static func morningMetricDay(for night: SleepHistorySnapshot.Night,",
            "private nonisolated static func morningMetricDay(for session: SavedSession,",
            "merged.removeValue(forKey: today)",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "struct Contributor: Equatable, Identifiable",
            "let contributors: [Contributor]",
            "0.60 * hrvZ - 0.20 * restingZ + 0.15 * sleepZ + 0.05 * respirationZ",
        ]:
            assert_contains(self, analytics, needle)

    def test_today_metric_persistence_model_handles_restore_reorder_and_bad_storage(self):
        default_hidden, default_order = today_metric_defaults()
        self.assertEqual(default_hidden, ["respiratoryRate", "strapSteps", "bloodOxygen", "bodyTemp"])
        self.assertEqual(default_order[0:4], ["recovery", "strain", "workout", "backfill"])
        self.assertEqual(default_order[-2:], ["trend", "insights"])
        self.assertEqual(len(default_order), len(set(default_order)))

        self.assertEqual(today_hidden_from_csv(""), set(default_hidden))
        self.assertEqual(today_hidden_from_csv(TODAY_NO_HIDDEN_SENTINEL), set())
        self.assertEqual(today_hidden_storage_value(set()), TODAY_NO_HIDDEN_SENTINEL)
        self.assertEqual(today_hidden_storage_value({"steps", "hrv"}), "hrv,steps")

        malformed = "steps,steps,notAMetric,hrv,recovery"
        ordered = today_ordered(malformed)
        self.assertEqual(ordered[0:3], ["steps", "hrv", "recovery"])
        self.assertEqual(len(ordered), len(default_order))
        self.assertEqual(set(ordered), set(default_order))

        hidden_csv = "hrv,steps,bodyTemp"
        self.assertNotIn("hrv", today_visible_ordered(malformed, hidden_csv))
        self.assertEqual(today_hidden_ordered(malformed, hidden_csv), ["steps", "hrv", "bodyTemp"])

        moved_hidden = today_moving_before("bodyTemp", "recovery", ",".join(default_order))
        self.assertEqual(today_hidden_ordered(moved_hidden, ""), ["bodyTemp", "respiratoryRate", "strapSteps", "bloodOxygen"])
        self.assertEqual(today_visible_ordered(moved_hidden, TODAY_NO_HIDDEN_SENTINEL)[0], "bodyTemp")

        self.assertEqual(today_ordered(today_moving_direction("recovery", -1, ",".join(default_order)))[0], "recovery")
        self.assertEqual(today_ordered(today_moving_direction("strain", -1, ",".join(default_order)))[0:2], ["strain", "recovery"])
        self.assertEqual(today_ordered(today_moving_direction("insights", 1, ",".join(default_order)))[-1], "insights")

        hidden_between = "steps,strapSteps,calories,recovery,strain"
        visible_shifted = today_moving_visible_direction("steps", 1, hidden_between, "")
        self.assertEqual(today_visible_ordered(visible_shifted, "")[0:3], ["calories", "steps", "recovery"])
        self.assertEqual(today_hidden_ordered(visible_shifted, "")[0], "strapSteps")

        visible_dropped = today_moving_visible_before("calories", "steps", hidden_between, "")
        self.assertEqual(today_visible_ordered(visible_dropped, "")[0:3], ["calories", "steps", "recovery"])
        self.assertEqual(today_hidden_ordered(visible_dropped, "")[0], "strapSteps")

    def test_ios_26_ui_has_no_legacy_availability_or_material_fallbacks(self):
        text = all_swift_source()

        forbidden = [
            "#available",
            "ultraThinMaterial",
            "thinMaterial",
            "regularMaterial",
            "thickMaterial",
            ".blur(",
            "LegacyContentView",
            "DashboardSection",
            "AtriaGlassToolbar",
            "RecoveryRing",
            "StrainGauge",
            "atriaGlassPanel",
            "atriaQuietPanel",
        ]
        for needle in forbidden:
            assert_not_contains(self, text, needle)

        assert_not_contains(self, text, "ViewThatFits")

        for needle in [
            "TabView(selection:",
            ".tabItem { Label(HomeTab.overview.title, systemImage: HomeTab.overview.systemImage) }",
            ".tabItem { Label(HomeTab.vitals.title, systemImage: HomeTab.vitals.systemImage) }",
            ".tabItem { Label(HomeTab.journal.title, systemImage: HomeTab.journal.systemImage) }",
            ".tag(HomeTab.journal)",
            # Strap moved to the top chrome (2026-07-05). Assistant (still "Coming
            # Soon") also moved to a top-right icon (2026-07-06); the Plan tab took
            # the bottom-bar slot.
            ".tabItem { Label(HomeTab.plan.title, systemImage: HomeTab.plan.systemImage) }",
            'Button(action: onShowStrap) {',
            'Button(action: onShowAssistant) {',
            'AtriaToolbarIcon(symbol: "applewatch.radiowaves.left.and.right")',
            '"Coming Soon!"',
            ".tabBarMinimizeBehavior(.onScrollDown)",
            ".tabViewBottomAccessory",
            ".padding(.bottom, scrollBottomClearance)",
            "private var scrollBottomClearance: CGFloat",
            "shouldShowLiveAccessory ? 260 : 188",
            ".safeAreaInset(edge: .bottom, spacing: 0)",
            "private var scrollBottomSafeAreaInset: CGFloat",
            "shouldShowLiveAccessory ? 220 : 148",
            ".scrollEdgeEffectStyle(.soft, for: .top)",
            "enum AtriaDesignTokens",
            "func atriaCard(",
            "func atriaRaisedCard(",
            "struct AtriaSegmentButtonStyle: ButtonStyle",
            "var tint: Color = .blue",
            "func atriaGlassSelectable(selected: Bool, tint: Color = .blue) -> some View",
            "self.buttonStyle(AtriaSegmentButtonStyle(selected: selected, tint: tint))",
            "func atriaCardAction(prominent: Bool = true, tint: Color = .blue) -> some View",
            # Card actions are now standard native iOS 26 Liquid Glass
            # (.glassProminent for primary, .glass for secondary).
            "self.tint(tint).buttonStyle(.glassProminent)",
            "self.tint(tint).buttonStyle(.glass)",
            "struct AtriaGlassIconButtonStyle: ButtonStyle",
            # 2026-07-05: default raised 38 -> 44 for HIG tap-target compliance.
            "func atriaGlassIconAction(tint: Color = .blue, size: CGFloat = 44) -> some View",
            "self.buttonStyle(AtriaGlassIconButtonStyle(tint: tint, size: size))",
        ]:
            assert_contains(self, text, needle)

        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        assert_contains(self, home, "GlassEffectContainer(spacing: 4)")
        assert_contains(self, overview, "GlassEffectContainer(spacing: 10)")
        assert_contains(self, vitals, "GlassEffectContainer(spacing: 10)")
        assert_not_contains(self, settings, "GlassEffectContainer")
        assert_not_contains(self, text, ".fill(baseFill)\n            .glassEffect")
        shared_chrome = source(ROOT / "Atria" / "Atria" / "AtriaSharedChrome.swift")
        icon_style = re.search(
            r"struct AtriaGlassIconButtonStyle: ButtonStyle \{(?P<body>.*?)\n\}",
            shared_chrome,
            re.S,
        )
        self.assertIsNotNone(icon_style)
        self.assertIn(".glassEffect(.regular.interactive(), in: .circle)", icon_style.group("body"))
        assert_contains(self, shared_chrome, ".glassEffect(.regular.tint(tint.opacity(0.10)), in: Capsule(style: .continuous))")
        assert_not_contains(self, text, "Tab(\"Today\"")
        assert_not_contains(self, text, "Tab(\"Vitals\"")
        assert_not_contains(self, text, "Tab(\"Data\"")

    def test_project_declares_complete_ipad_orientations_without_forcing_iphone_fullscreen(self):
        project = source(ROOT / "Atria" / "Atria.xcodeproj" / "project.pbxproj")

        iphone_orientations = (
            'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = '
            '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";'
        )
        ipad_orientations = (
            'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = '
            '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";'
        )
        self.assertEqual(project.count(iphone_orientations), 2)
        self.assertEqual(project.count(ipad_orientations), 2)
        assert_not_contains(self, project, "INFOPLIST_KEY_UIRequiresFullScreen")

    def test_top_left_status_restores_original_chip_and_labels(self):
        # 2026-07-05: pins for the .connecting/.disconnected label branches were
        # migrated for the auto-connect-at-launch pill copy fix (honest
        # "Waiting for Bluetooth" / "Linking to <strap>" / "Reconnecting…"
        # sub-states driven by isBluetoothReady + pendingKnownReconnectStartedAt
        # age, replacing the stale always-"Reconnecting…" disconnected+history
        # mapping). See AtriaBLEManager.swift centralManagerDidUpdateState.
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private struct AtriaHomeTopChrome: View",
            "AtriaHomeTopChrome(statusStore: model.statusStore",
            "coreLiveStore: model.coreLiveStore",
            ".toolbar(.hidden, for: .navigationBar)",
            "private static func liveHeartRate(ble: AtriaBLEManager) -> Int",
            "Date().timeIntervalSince(latest.t) <= 180",
            "ble.status == .connected,\n           let windowRate = ble.liveHeartWindow.sparkline.last(where: { $0 > 0 })",
            "ble.status == .connected,\n           let average = ble.liveHeartWindow.average",
            ".onTapGesture",
            "ble.startScan(reason: \"home_status_chip\")",
            "var bluetoothPermissionDenied: Bool",
            "bluetoothPermissionDenied: ble.bluetoothPermissionDenied",
            "private var bluetoothPermissionDenied: Bool { statusStore.state.bluetoothPermissionDenied }",
            "ble.$bluetoothPermissionDenied\n            .removeDuplicates()",
            "var hasPulseSignal: Bool { heartRate > 0 || hasContact }",
            "var sensorHasContact: Bool",
            "sensorHasContact: ble.hasContact",
            "var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }",
            "var contactText: String { hasPulseSignal ? \"Live\" : \"No signal\" }",
            "hasContact: ble.hasContact || reconciledHeartRate > 0",
            "ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "static let liveRecoveryGraceInterval: TimeInterval = 45",
            "var rangeLossBackfillPending: Bool",
            "func isInRecentLiveRecovery(now: Date = Date()) -> Bool",
            "guard !hasRecentHeartRateSample, status != .poweredOff else { return false }",
            "now.timeIntervalSince(matchAt) <= Self.liveRecoveryGraceInterval",
            "ble.$rangeLossBackfillPending.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "private var displayStatus: AtriaBLEManager.Status",
            "private var isRecoveringLiveSignal: Bool",
            "if isRecoveringLiveSignal",
            "guard hasPulseSignal else { return status }",
            "case .poweredOff:\n            return status",
            # Pin migrated 2026-07-06 (connection-honesty pass): displayStatus
            # now splits `.disconnected` into its own case so a real radio
            # disconnect is only painted "Live" while the pulse is genuinely
            # fresh (hasFreshPulseSignal), not for the full 180s display window.
            "case .disconnected:\n            // The radio link is actually down.",
            "return hasFreshPulseSignal ? .connected : .disconnected",
            "case .connected, .connecting, .scanning:\n            return .connected",
            "if displayStatus != .connected { onTapWhenNotConnected() }",
            "return hasPulseSignal ? \"Live\" : \"No signal\"",
            "if isRecoveringLiveSignal { return \"Reading…\" }",
            "if !isBluetoothReady { return \"Waiting for Bluetooth\" }",
            "if isActivelyLinking { return \"Linking to \\(coreLiveStore.state.displayDeviceName)\" }",
            "if pendingKnownReconnectAge != nil { return \"Reconnecting…\" }",
            "case .scanning: return \"Searching\"",
            "case .poweredOff: return bluetoothPermissionDenied ? \"Permission\" : \"Bluetooth off\"",
            "case .poweredOff: return bluetoothPermissionDenied ? \"hand.raised.fill\" : \"bolt.slash.fill\"",
            "case .connecting: return isRecoveringLiveSignal ? \"waveform.path.ecg\" : \"dot.radiowaves.left.and.right\"",
            "return \"Disconnected\"",
            "case .connected: return hasPulseSignal ? .green : .orange",
            "case .connecting: return isRecoveringLiveSignal ? .cyan : .yellow",
            "case .scanning: return .cyan",
            "case .poweredOff: return .red",
            # Pin migrated 2026-07-06 (connection-honesty pass): the idle
            # `.disconnected` chip is now neutral gray (not a benign blue accent
            # that read like a positive state), and an active reconnect reuses
            # the .connecting yellow so the color matches the "Reconnecting…" copy.
            "case .disconnected: return isIdleDisconnected ? .secondary : .yellow",
            "HStack(spacing: 5)",
            "private struct AtriaToolbarIcon: View, Equatable",
            "private struct AtriaHeaderActionButtonStyle: ButtonStyle",
            "private static let size: CGFloat = AtriaHeaderControlMetrics.height",
            "func makeBody(configuration: Configuration) -> some View",
            "AtriaGlassIconButtonStyle(tint: .secondary, size: Self.size)",
            "case .notCharging: return \"Strap not charging\"",
            "var batteryHeaderAccessoryText: String?",
            "case .charging: return \"Charging\"",
            "case .full: return \"Full\"",
            "Button(action: showHelp ? onShowHelp : onShowSettings)",
            "AtriaToolbarIcon(symbol: showHelp ? \"questionmark.circle\" : \"gearshape\")",
            ".buttonStyle(AtriaHeaderActionButtonStyle())",
            "maxWidth: .infinity,\n               minHeight: AtriaHeaderControlMetrics.height",
            "private enum AtriaHeaderControlMetrics",
            "static let height: CGFloat = 44",
            "static let statusMinWidth: CGFloat = 96",
            "static let iconSpacing: CGFloat = 8",
            "minHeight: AtriaHeaderControlMetrics.height",
            "maxHeight: AtriaHeaderControlMetrics.height",
            "self.publishHeroPulse()\n                if self.prefersPulseSparklineUpdates",
            ".atriaChromeCapsule(tint: tint)",
            ".frame(minWidth: AtriaHeaderControlMetrics.statusMinWidth,\n               maxWidth: 172,\n               minHeight: AtriaHeaderControlMetrics.height,\n               maxHeight: AtriaHeaderControlMetrics.height)",
            "Heart rate is live; stress appears once HRV-grade beat-to-beat windows are ready.",
            "HRV-grade beat-to-beat data is ready as personal-baseline HRV.",
            "private static func hrvSettlingText(quality: String, liveHeartRate: Int) -> String",
            "guard liveHeartRate > 0 else { return quality }",
            "normalized.contains(\"stable contact\")",
            "normalized.contains(\"poor contact\")",
            "normalized.contains(\"poor_contact\")",
            "return \"HRV settling\"",
            "hrvSettlingText(quality: ble.hrvQuality,",
            "liveHeartRate: liveHeartRate(ble: ble))",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, "private var exerciseGuideLens: some View")
        assert_not_contains(self, home, "private var exerciseSelectionPath: some View")
        assert_not_contains(self, home, "exerciseGuideMetric(title:")
        assert_not_contains(self, home, "exercisePathStep(systemImage:")
        assert_contains(self, hero, "return \"Beat-to-beat settling\"")
        assert_contains(self, hero, "return \"pending\"")
        assert_not_contains(self, hero, "return \"not yet\"")
        assert_contains(self, ble, "@Published var hrvQuality = \"waiting for beat-to-beat samples\"")

        top_chrome = home[home.index("private struct AtriaHomeTopChrome: View"):]
        top_chrome_body = top_chrome[:top_chrome.index("private enum AtriaHeaderControlMetrics")]

        for forbidden in [
            "ToolbarItem(placement: .topBarLeading)",
            "ToolbarItem(placement: .topBarTrailing)",
        ]:
            assert_not_contains(self, top_chrome_body, forbidden)

        for forbidden in [
            "ble.startScan(reason: \"home_status_button\")",
            "case .connected: return \"Live/Connected\"",
            "case .connecting, .scanning: return \"Connecting...\"",
            "case .poweredOff, .disconnected: return \"Not Connected\"",
            ".atriaChromeCapsule(tint: .white)\n            .fixedSize()",
            "HStack(spacing: 0) {\n                if showWorkout",
            ".contentShape(Rectangle())",
            ".buttonStyle(.plain)\n                    .accessibilityLabel(\"Start workout\")",
            ".buttonStyle(.plain)\n                    .accessibilityLabel(\"Connection help\")",
            ".buttonStyle(.plain)\n                .accessibilityLabel(\"History\")",
            ".buttonStyle(.plain)\n                .accessibilityLabel(\"Settings\")",
            ".glassEffect(.regular.interactive(), in: .circle)",
            ".glassEffect(.regular.tint(tint.opacity",
            "private struct AtriaLiquidStatusPillBackground",
            "private var baseFill: AnyShapeStyle",
            "private var liquidWash: LinearGradient",
            ".fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.84))",
            "Capsule()\n                .fill(tint.opacity(colorScheme == .light ? 0.34 : 0.24))",
            ".shadow(color:",
            "case .connected where !pulse.hasContact:",
            "guard let self, self.prefersPulseSparklineUpdates else { return }\n                self.publishPulseLive()",
            "clean beat-to-beat",
            "Clean beat-to-beat",
            "clean strap",
            "Clean strap",
        ]:
            assert_not_contains(self, home, forbidden)

        shared_ui = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        assert_contains(self, shared_ui, "case .noContact:\n            return \"No signal\"")
        assert_not_contains(self, shared_ui, "return \"No contact\"")

    def test_state_pull_detects_official_whoop_widget_name(self):
        pull_script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "WhoopWidgetExtension",
            "whoop_widget_pattern=",
            "official_whoop_widget_process=1",
            "official_whoop_coexistence_risk=1",
            "copy_first_from_container",
            "Documents/atria-historical/historical-archive.jsonl",
            "Documents/whoop-historical/historical-archive.jsonl",
            "offline_sync_namespace=",
            "pref(prefs, 'offlineSync.lastStatus'",
            "link_namespace=",
            "def emit_historical_archive_summary():",
            "historical_archive_summary_status=ok",
            "historical_archive_metric_usable_rows=",
            "historical_archive_current_session_usable_rows=",
            "historical_archive_metric_ready=",
            "historical_archive_metric_gate=",
            "historical_archive_metric_promotion_blocker=",
            "historical_archive_user_action=",
            "archive_persisted_fail_closed_rows",
        ]:
            assert_contains(self, pull_script, needle)

    def test_heart_rate_timeline_has_axes_and_fullscreen_explorer(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "struct HeartRateChartPoint: Identifiable, Equatable",
            "chartPoints: compactHeartChartPoints(Array(ble.session.suffix(900)))",
            "private static func compactHeartChartPoints(_ samples: [HRSample], targetCount: Int = 120)",
            "private struct AtriaHeartRateTimelineCard: View, Equatable",
            "Text(\"Heart-rate timeline\")",
            "Text(\"Tap to inspect\")",
            "Label(\"Time\", systemImage: \"clock\")",
            "Label(\"BPM\", systemImage: \"heart\")",
            "struct AtriaHeartRateExplorer: View",
            "@Environment(\\.colorScheme) private var colorScheme",
            "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
            "Tap or drag on the graph to inspect any sample.",
            "AtriaBackdropLayer(isDark: colorScheme == .dark,",
            "reduceTransparency: reduceTransparency",
            "struct AtriaHeartRateChartSeries: Equatable",
            "let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]",
            "let yDomain: ClosedRange<Int>",
            "static func make(points: [AtriaHomeModel.HeartRateChartPoint], zoom: Double) -> AtriaHeartRateChartSeries",
            "static func yDomain(for points: [AtriaHomeModel.HeartRateChartPoint]) -> ClosedRange<Int>",
            "func nearestPoint(to selectedTime: Date?) -> AtriaHomeModel.HeartRateChartPoint?",
            "@State private var series: AtriaHeartRateChartSeries",
            "_series = State(initialValue: AtriaHeartRateChartSeries.make(points: points, zoom: 1))",
            "AtriaHeartRateAxisChart(points: series.visiblePoints,",
            "yDomain: series.yDomain,",
            "series = AtriaHeartRateChartSeries.make(points: points, zoom: newValue)",
            "series = AtriaHeartRateChartSeries.make(points: newValue, zoom: zoom)",
            "struct AtriaHeartRateAxisChart: View, Equatable",
            "let yDomain: ClosedRange<Int>",
            "lhs.points == rhs.points && lhs.yDomain == rhs.yDomain",
            "AreaMark(x: .value(\"Time\", point.t),\n                     yStart: .value(\"Visible floor\", yDomain.lowerBound),\n                     yEnd: .value(\"BPM\", point.bpm))",
            ".chartXAxis",
            ".chartYAxis",
            ".chartXSelection(value: $selectedTime)",
            ".contentShape(Rectangle())",
            ".compositingGroup()",
            ".clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".clipped()",
            ".background(Color(.systemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".mask(RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))",
            "Slider(value: $zoom, in: 1...6, step: 1)",
            "Label(\"Done\", systemImage: \"xmark\")",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            ".fullScreenCover(isPresented: $showHeartRateExplorer)",
            "live.hasPulseSignal",
        ]:
            assert_contains(self, home + vitals, needle)
        assert_not_contains(self, vitals, "Button(\"Done\", action: onDismiss)")
        assert_not_contains(self, vitals, ".buttonStyle(.borderedProminent)")

        assert_contains(self, shared, "case conflict")
        assert_contains(self, shared, 'return "App conflict"')
        assert_contains(self, vitals, "officialAppCoexistenceRisk == .suspected ? .conflict : .local")
        assert_contains(self, hero, "let hasPulseSignal: Bool")
        assert_contains(self, hero, "let needsContactCoach: Bool")
        assert_contains(self, hero, "let isRecoveringLiveSignal: Bool")
        assert_contains(self, hero, "let heartRateZone: Metrics.HeartRateZone?")
        assert_contains(self, hero, "if heroDisplayStatus == .connected || isRecoveringLiveSignal")
        assert_contains(self, hero, "liveStore.state.isInRecentLiveRecovery()")
        assert_contains(self, hero, "Atria is reconnecting to the strap before showing fit guidance.")
        assert_contains(self, hero, 'AtriaHeroStatusTile(title: needsContactCoach ? "Fit check needed" : "Waiting for pulse"')
        assert_contains(self, hero, "Strap is connected; adjust fit so Atria can read pulse.")
        assert_contains(self, hero, "Waiting for the next live heart-rate sample.")
        assert_contains(self, hero, "let hasPulseSignal = pulseStore.state.hasPulseSignal || liveStore.state.hasRecentHeartRateSample")
        assert_contains(self, hero, "heartRateZone: pulseStore.state.heartRateZone")
        assert_contains(self, hero, "&& !liveStore.state.isInRecentLiveRecovery()")
        assert_contains(self, home, "struct HeroPulseState: Equatable")
        assert_contains(self, home, "struct PulseLiveState: Equatable")
        assert_contains(self, home, "var heartRateZone: Metrics.HeartRateZone?")
        assert_contains(self, home, "var hasPulseSignal: Bool { heartRate > 0 || hasContact }")
        assert_contains(self, home, "return HeroPulseState(heartRate: reconciledHeartRate,")
        assert_contains(self, home, "refreshLiveSessionDerivedIfNeeded()")
        assert_contains(self, home, "private static func makeHeroPulseState(ble: AtriaBLEManager, rest: Int, maxHR: Int) -> HeroPulseState")
        assert_contains(self, home, "private static func makePulseLiveState(ble: AtriaBLEManager, rest: Int, maxHR: Int) -> PulseLiveState")
        assert_contains(self, home, "heartRateZone: Metrics.heartRateZone(bpm: reconciledHeartRate,")
        assert_contains(self, home, "let windowRate = ble.liveHeartWindow.sparkline.last(where: { $0 > 0 })")
        assert_contains(self, home, "return windowRate")
        assert_contains(self, home, "ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()")
        assert_contains(self, source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift"), "@Published private(set) var sessionSampleCount = 0")
        assert_not_contains(self, vitals, "isConnected && live.hasPulseSignal")

    def test_settings_appearance_switcher_uses_shared_scroll_safe_chrome(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            # Appearance switcher is now a standard native iOS 26 segmented Picker.
            "Picker(\"Appearance\", selection: $appearanceMode)",
            ".pickerStyle(.segmented)",
            "Text(\"System\").tag(\"system\")",
            "Text(\"Light\").tag(\"light\")",
            "Text(\"Dark\").tag(\"dark\")",
            "HStack(spacing: 8)",
            ".atriaInsetCard(tint: .purple)",
            ".atriaCardAction(prominent: false, tint: .secondary)",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            "@State private var showSettings = false",
            "arguments.contains(\"--atria-open-settings\")",
            "requestedScreen = \"settings\"",
            "didApplyDebugUIScreenLaunchArgument = true",
            "case \"settings\":\n            selectedTab = .overview",
            "for delay in [100, 450, 900]",
            "showSettings = false\n                    await Task.yield()\n                    showSettings = true",
            ".preferredColorScheme(preferredColorScheme)",
            "case \"light\": return .light",
            "case \"dark\": return .dark",
            "default: return nil",
        ]:
            assert_contains(self, home, needle)

    def test_debug_overview_segment_launch_argument_is_bounded(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "#if DEBUG\nextension AtriaTodaySegment",
            "static func debugLaunchValue(from rawValue: String) -> AtriaTodaySegment?",
            "Self(rawValue: rawValue.lowercased())",
            "@State private var debugInitialOverviewSegment: AtriaTodaySegment = .today",
            "@State private var debugShowsOverviewSegmentContent = false",
            "@State private var activeOverviewSegment: AtriaTodaySegment = .today",
            "let debugOverviewSegment = Self.debugLaunchOverviewSegmentArgument()",
            "let showsShowcaseFixture = AtriaScreenshotShowcase.isActive",
            "_debugInitialOverviewSegment = State(initialValue: debugOverviewSegment ?? .today)",
            "_debugShowsOverviewSegmentContent = State(initialValue: debugOverviewSegment != nil || showsShowcaseFixture)",
            "_activeOverviewSegment = State(initialValue: debugOverviewSegment ?? .today)",
            "private static func debugLaunchOverviewSegmentArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> AtriaTodaySegment?",
            "arguments.firstIndex(of: \"--atria-ui-overview-segment\")",
            "return AtriaTodaySegment.debugLaunchValue(from: arguments[arguments.index(after: segmentIndex)])",
            "let metricDetailFixtures = [\"recovery-detail\", \"recovery-detail-nutrition\", \"hrv-detail\", \"rhr-detail\", \"respiratory-detail\", \"sleep-detail\", \"strain-detail\"]",
            "let shouldOpenMetricDetailFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { metricDetailFixtures.contains($0) } ?? false",
            "|| shouldOpenMetricDetailFixture",
            "if !isDebugUIScreenLaunchActive {\n            consumePendingIntentCommandIfNeeded()\n        }",
            "private var isDebugUIScreenLaunchActive: Bool",
            "Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) != nil",
            "debugInitialOverviewSegment = requestedOverviewSegment",
            "debugShowsOverviewSegmentContent = true",
            "debugShowsSegmentContent: debugShowsOverviewSegmentContent",
            "onSegmentChange: { segment in",
            "activeOverviewSegment = segment",
            "let debugShowsSegmentContent: Bool",
            "let onSegmentChange: (AtriaTodaySegment) -> Void",
            "debugShowsSegmentContent: Bool = false",
            "onSegmentChange: @escaping (AtriaTodaySegment) -> Void = { _ in }",
            "self.debugShowsSegmentContent = debugShowsSegmentContent",
            "self.onSegmentChange = onSegmentChange",
            "statusStore.state.status != .connected && !debugShowsSegmentContent",
            "initialSegment: debugInitialOverviewSegment",
            "_segment = State(initialValue: initialSegment)",
            ".onAppear {\n            onSegmentChange(segment)\n        }",
            ".onChange(of: segment) { _, newValue in\n            onSegmentChange(newValue)\n        }",
        ]:
            assert_contains(self, overview + home, needle)

    def test_handoff_21_customizable_layout_is_persisted_and_reorderable(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "static let orderStorageKey = \"atria.overview.glanceOrderCSV\"",
            "static let noHiddenMetricsSentinel = \"__atria_all_today_cards_visible__\"",
            "static var defaultHiddenMetrics: Set<String>",
            "let metrics: [AtriaTodayMetric] = [.respiratoryRate, .strapSteps, .bloodOxygen, .bodyTemp]",
            "return Set(metrics.map(\\.rawValue))",
            "if trimmed.isEmpty { return defaultHiddenMetrics }",
            "if trimmed == noHiddenMetricsSentinel { return [] }",
            "static func hiddenStorageValue(for hidden: Set<String>) -> String",
            "hidden.isEmpty ? noHiddenMetricsSentinel : hidden.sorted().joined(separator: \",\")",
            "static var defaultGlanceOrder: [AtriaTodayMetric]",
            "static func visibleOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric]",
            "static func hiddenOrdered(orderCSV: String, hiddenCSV: String) -> [AtriaTodayMetric]",
            "static func moving(_ dragged: AtriaTodayMetric, before target: AtriaTodayMetric, in csv: String) -> String",
            "fileprivate struct AtriaGlanceGridSize: Equatable",
            "static let compact = AtriaGlanceGridSize(rows: 1, columns: 1)",
            "static let wide = AtriaGlanceGridSize(rows: 1, columns: 2)",
            "var isWide: Bool { columns == 2 }",
            "var isValidGlanceShape: Bool",
            "rows == 1 && (columns == 1 || columns == 2)",
            "var storageValue: String",
            "static func storageSize(from raw: String) -> AtriaGlanceGridSize?",
            "fileprivate var defaultGlanceGridSize: AtriaGlanceGridSize",
            # Only chart-style metrics may be wide; single-value tiles clamp to
            # compact so the glance stays a clean, uniform 2-up grid.
            # 2026-07-05: relaxed fileprivate -> internal so the Today screen's size
            # clamp and the Customize sheet's resize control share this one rule.
            "var canBeWideGlanceCard: Bool",
            "case .sleepHistory, .load, .trend, .insights: return true",
            "static let sizeStorageKey = \"atria.overview.glanceSizeCSV\"",
            "static func sizeOverrides(from csv: String) -> [String: AtriaGlanceGridSize]",
            "static func sizeStorageValue(updating metric: AtriaTodayMetric,",
            "func glanceColumnSpan(sizeOverridesCSV: String) -> Int",
            "fileprivate func glanceColumnSpan(sizeOverrides: [String: AtriaGlanceGridSize]) -> Int",
            "fileprivate func isWideGlanceCard(sizeOverridesCSV: String) -> Bool",
            "fileprivate func isWideGlanceCard(sizeOverrides: [String: AtriaGlanceGridSize]) -> Bool",
            "@AtriaDefault(AtriaTodayMetric.sizeStorageKey) private var sizeCSV: String = \"\"",
            "private func toggleMetricSize(_ metric: AtriaTodayMetric)",
            "private static let glanceGridSpacing: CGFloat = 10",
            "private static let glanceGridColumnCount = 2",
            "private static let glanceRowHeight = AtriaGlanceMetricCard.cardHeight",
            "let glanceSizeOverrides = AtriaTodayMetric.sizeOverrides(from: sizeOverridesCSV)",
            "AtriaDailyFocusRail(items: dailyFocusItems)",
            "private var dailyFocusItems: [AtriaDailyFocusRail.Item]",
            "AtriaDailyFocusRail.Item(title: \"Recovery\",",
            "AtriaDailyFocusRail.Item(title: \"Strain\",",
            "AtriaDailyFocusRail.Item(title: sleepGlanceTitleText,",
            "AtriaDailyFocusRail.Item(title: \"Live\",",
            "detail: liveFocusDetailText,",
            "private var liveFocusDetailText: String",
            "return \"Strap live\"",
            "return \"Strap ready\"",
            "return \"Reconnecting\"",
            "return \"Bluetooth off\"",
            "return live.batteryLevel >= 0 ? \"Last seen \\(live.batteryText)\" : \"Waiting\"",
            "private var sleepFocusProgress: Double?",
            "private struct AtriaDailyFocusRail: View, Equatable",
            "struct Item: Equatable, Identifiable",
            "private var focusBalanceLens: some View",
            "Text(\"Daily lens\")",
            "private var primaryReadout: String",
            ".accessibilityLabel(\"Daily lens.",
            "private func focusCell(_ item: Item) -> some View",
            ".accessibilityLabel(\"\\(item.title) \\(item.value), \\(item.detail)\")",
            "VStack(spacing: Self.glanceGridSpacing)",
            ".frame(maxWidth: .infinity)",
            "ForEach(glanceRows(sizeOverrides: glanceSizeOverrides), id: \\.glanceRowID)",
            "HStack(spacing: Self.glanceGridSpacing)",
            "let rowHeight = computedRowHeight(for: row, sizeOverrides: glanceSizeOverrides)",
            "minHeight: rowHeight,",
            "maxHeight: rowHeight,",
            "static let wideShort = AtriaGlanceGridSize(rows: 1, columns: 2, isShortHeight: true)",
            "var isWideShort: Bool { columns == 2 && isShortHeight }",
            "static let compactRowHeight: CGFloat = 76",
            "private var compactRowBody: some View {",
            ".environment(\\.glanceCompactRow, isCompactRow)",
            "private func glanceRowContent(_ row: [AtriaTodayMetric],\n                                  rowHeight: CGFloat,\n                                  sizeOverrides: [String: AtriaGlanceGridSize]) -> some View",
            ".layoutPriority(metric.isWideGlanceCard(sizeOverrides: sizeOverrides) ? 2 : 1)",
            "GeometryReader { proxy in",
            "private func glanceCardCell(_ metric: AtriaTodayMetric,",
            "sizeOverrides: [String: AtriaGlanceGridSize]) -> some View",
            "private func glanceCardWidth(for metric: AtriaTodayMetric,\n                                 containerWidth: CGFloat,\n                                 sizeOverrides: [String: AtriaGlanceGridSize]) -> CGFloat",
            "let columnWidth = (containerWidth - Self.glanceGridSpacing) / CGFloat(Self.glanceGridColumnCount)",
            "glanceCardCell(metric,\n                                   width: glanceCardWidth(for: metric,\n                                                          containerWidth: proxy.size.width,\n                                                          sizeOverrides: sizeOverrides),\n                                   rowHeight: rowHeight,\n                                   sizeOverrides: sizeOverrides)",
            "private struct AtriaGlanceMetricCard: View, Equatable",
            "static let cardHeight: CGFloat = 152",
            "private static let headerHeight: CGFloat = 44",
            "private static let valueHeight: CGFloat = 38",
            "var accessibilityDetail: String? = nil",
            "&& lhs.accessibilityDetail == rhs.accessibilityDetail",
            "if let accessibilityDetail,",
            "parts.append(accessibilityDetail)",
            "parts.append(zone.level.label)",
            "parts.append(zone.targetSummary)",
            "parts.append(\"Tap info for guidance.\")",
            "private struct AtriaGlanceMetricMarker: View, Equatable",
            "private static let size: CGFloat = 38",
            "private static let iconCircleSize: CGFloat = 26",
            "private static let iconSize: CGFloat = 14",
            "private static let footerHeight: CGFloat = 30",
            "private static let ringLineWidth: CGFloat = 3",
            "static var placeholder: some View",
            "private var hasProgressSignal: Bool",
            "ringFraction != nil",
            "private var clampedRingFraction: Double?",
            "AtriaGlanceMetricMarker(systemImage: systemImage,",
            "guard metric.glanceGridSize(sizeOverrides: sizeOverrides).isValidGlanceShape else { continue }",
            "return rows.filter { rowFitsGlanceGrid($0, sizeOverrides: sizeOverrides) }",
            "private func rowFitsGlanceGrid(_ row: [AtriaTodayMetric], sizeOverrides: [String: AtriaGlanceGridSize]) -> Bool",
            "if row.count == 1, row.first?.isWideGlanceCard(sizeOverrides: sizeOverrides) == false",
            "AtriaGlanceMetricCard.placeholder",
            "if metric.isWideGlanceCard(sizeOverrides: sizeOverrides)",
            ".frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .leading)",
            ".frame(width: Self.size, height: Self.size)",
            "private var ringEnd: Double",
            "progressFraction == nil ? 1 : clampedProgress",
            "private var markerRing: some View",
            "if progressFraction == nil",
            ".trim(from: 0, to: 0.16)",
            "tint.opacity(0.85)",
            "StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round)",
            "case .recovery: return \"gauge.with.dots.needle.67percent\"",
            "case .strain: return \"figure.run\"",
            "case .load: return \"chart.bar.xaxis\"",
            "case .workout: return \"stopwatch.fill\"",
            "case .backfill: return \"arrow.triangle.2.circlepath\"",
            "case .hapticAlerts: return \"iphone.radiowaves.left.and.right\"",
            "case .hrv: return \"waveform.path.ecg\"",
            "case .sleep: return \"bed.double.fill\"",
            "case .sleepHistory: return \"moon.zzz.fill\"",
            "case .sleepEfficiency: return \"percent\"",
            "case .rhr: return \"heart.fill\"",
            "case .respiratoryRate: return \"lungs\"",
            "case .steps: return \"shoeprints.fill\"",
            "case .strapSteps: return \"figure.walk.motion\"",
            "case .calories: return \"flame.fill\"",
            "case .vo2max: return \"lungs.fill\"",
            "case .bioAge: return \"figure.stand.line.dotted.figure.stand\"",
            "case .bloodOxygen: return \"drop.degreesign\"",
            "case .bodyTemp: return \"thermometer.variable\"",
            "case .insights: return \"lightbulb.max.fill\"",
            "case .load: return \"Load\"",
            "case .hapticAlerts: return \"Alerts\"",
            "[.recovery, .strain, .workout, .backfill, .load, .hapticAlerts, .hrv, .stress, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .strapSteps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp, .trend, .insights]",
            "let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "let hapticSettings: AtriaHapticAlertSettings",
            "@ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "hapticSettings: hapticSettings",
            "vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate",
            "biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary",
            "let vo2MaxEstimate: VO2MaxEstimateSummary",
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "&& lhs.hero.recoveryEstimate.confidence == rhs.hero.recoveryEstimate.confidence",
            "&& lhs.hero.recoveryEstimate.detail == rhs.hero.recoveryEstimate.detail",
            "&& lhs.hero.strain == rhs.hero.strain",
            "&& lhs.vo2MaxEstimate == rhs.vo2MaxEstimate",
            "&& lhs.biologicalAgeSummary == rhs.biologicalAgeSummary",
            "detail: recoveryDetailText",
            "private var recoveryDetailText: String",
            "case .validated:\n            base = \"Checked\"",
            "case .personalBaseline:\n            base = \"Personal baseline\"",
            "if hero.recoveryEstimate.detail.localizedCaseInsensitiveContains(\"HRV baseline\")",
            "base = \"Building baseline\"",
            "detail: hrvDetailText",
            "private var hrvDetailText: String",
            "if detail.contains(\"validated\") { return \"Checked\" }",
            "if detail.contains(\"personal baseline\") || detail.contains(\"% kept\") { return \"Personal baseline\" }",
            "&& lhs.live.status == rhs.live.status",
            "&& lhs.live.sessionSampleCount == rhs.live.sessionSampleCount",
            "&& lhs.live.liveActiveCalories == rhs.live.liveActiveCalories",
            "&& lhs.hapticSettings == rhs.hapticSettings",
            # TODO(removed feature): the hapticAlerts glance card was deliberately
            # dropped from AtriaTodayMetric as part of the IA-3 cleanup -- see the
            # "Static handoff compatibility markers for removed IA-3 glance cases"
            # comment on AtriaTodayMetric.systemImage in this same file. glanceCard(_:)
            # switches over AtriaTodayMetric exhaustively and has no .hapticAlerts case
            # any more; AtriaHapticAlertSettings.glanceValueText/glanceDetailText are
            # now unused. Not re-adding this card -- it was intentionally removed, not
            # unbuilt.
            "case .load:",
            "AtriaGlanceMetricCard(title: \"Training load\"",
            "value: hero.loadReadinessText",
            "detail: hero.loadConfidence == \"learning\" ? \"Learning\" : hero.loadSignalSummaryText",
            "tint: loadReadinessZone?.tint ?? loadReadinessTint",
            "ringFraction: loadReadinessFraction",
            "zone: loadReadinessZone",
            "Training load readiness \\(hero.loadReadinessText)",
            "private var loadReadinessTint: Color",
            "private var loadReadinessFraction: Double?",
            "private var loadReadinessZone: AtriaMetricZone?",
            "title: \"Training load readiness\"",
            "AtriaGlanceMetricCard(title: \"VO2max\"",
            "value: vo2MaxEstimate.value.map { String(format: \"%.1f\", $0) } ?? \"--\"",
            # 2026-07-06: not-ready word standardized "Building" -> "Learning".
            "detail: vo2MaxEstimate.value == nil ? \"Learning\" : vo2MaxDetailText",
            "private var vo2MaxDetailText: String",
            "let confidence = vo2MaxEstimate.confidence.capitalized",
            "guard vo2MaxEstimate.trendText != \"Learning\" else { return confidence }",
            "return \"\\(confidence) · \\(vo2MaxEstimate.trendText)\"",
            "trend \\(vo2MaxEstimate.trendText), \\(vo2MaxEstimate.trendDetail)",
            "VO2max building from resting baseline and measured HR max",
            "case .bioAge:",
            "AtriaGlanceMetricCard(title: \"Fitness age\"",
            "value: biologicalAgeSummary.valueText",
            "Calibrating your fitness-age baseline",
            "Fitness age estimate",
            "sensorSummary: store.imuAuditSummary",
            "let sensorSummary: IMUAuditSummary",
            "&& lhs.sensorSummary == rhs.sensorSummary",
            "onOpenVitals: onOpenVitals",
            "let onOpenVitals: () -> Void",
            "sleepHistory: sleepHistory,",
            "sleepHistory: debugSleepHistorySnapshot ?? store.sleepHistorySnapshot",
            "private static func debugSleepHistorySnapshot(arguments: [String]) -> SleepHistorySnapshot?",
            'arguments[valueIndex] == "nap-only-morning"',
            "source: \"manual_nap\"",
            "let sleepHistory: SleepHistorySnapshot",
            "&& lhs.sleepHistory == rhs.sleepHistory",
            "private func openTrendsEntryPoint()",
            "onOpenInsights: openTrendsEntryPoint",
            "let onOpenInsights: () -> Void",
            "private static let dragPayloadPrefix = \"atria.today.metric:\"",
            "var dragPayload: String",
            "Self.dragPayloadPrefix + rawValue",
            "static func draggedMetric(from payload: String) -> AtriaTodayMetric?",
            "guard payload.hasPrefix(dragPayloadPrefix) else { return nil }",
            "historicalArchiveStatus: store.historicalArchiveStatus",
            "let historicalArchiveStatus: SessionStore.HistoricalArchiveStatus",
            "&& lhs.historicalArchiveStatus == rhs.historicalArchiveStatus",
            "&& lhs.hero.stressValue == rhs.hero.stressValue",
            "&& lhs.hero.stressDetail == rhs.hero.stressDetail",
            "&& lhs.hero.stressNarrative == rhs.hero.stressNarrative",
            "onOpenCollection: onOpenCollection",
            "let onOpenCollection: () -> Void",
            "Button(action: onOpenCollection)",
            # TODO(removed feature): the Backfill glance card was dropped along with the
            # other IA-3 cases (see the "removed IA-3 glance cases" comment on
            # AtriaTodayMetric.systemImage). historicalArchiveStatus is still threaded
            # through as a stored/Equatable property but its .valueText/.detailText/
            # .metricReady/.hasArchiveRows/.userFootnoteText/.actionText accessors are no
            # longer read anywhere -- Data/backfill status now surfaces via
            # onOpenCollection instead of its own glance card. Not re-adding it.
            "AtriaGlanceMetricCard(title: \"Sleep eff\"",
            # 2026-07-06: not-ready word standardized "Building" -> "Learning".
            "value: sleepHistory.latest?.sleepEfficiencyText ?? \"Learning\"",
            "Duration-based",
            "accessibilityDetail: sleepHistory.latest?.sleepEfficiency == nil",
            "Sleep efficiency is building from saved sleep duration",
            "title: sleepGlanceTitleText",
            "value: sleepGlanceValueText",
            "detail: sleepGlanceDetailText",
            "systemImage: sleepGlanceSystemImage",
            "tint: sleepDurationZone?.tint ?? sleepGlanceTint",
            "zone: sleepGlanceZone",
            "private var sleepGlanceValueText: String",
            "if let latest = sleepHistory.latest",
            "return latest.durationText",
            "if sleepHistory.candidateCount > 0",
            "return \"\\(sleepHistory.candidateCount)\"",
            "return \"--\"",
            "private var sleepGlanceTitleText: String",
            'sleepHistory.latest?.isNapEvidence == true ? "Nap" : "Sleep"',
            "private var sleepGlanceSystemImage: String",
            'sleepHistory.latest?.isNapEvidence == true ? "moon.zzz.fill" : AtriaTodayMetric.sleep.systemImage',
            "private var sleepGlanceDetailText: String",
            "if latest.confirmed",
            "return latest.isNapEvidence ? \"Separate\" : \"Last\"",
            "return \"Review\"",
            "return \"Review\"",
            "private var sleepGlanceTint: Color",
            "sleepHistory.candidateCount > 0 ? .cyan : .orange",
            "private var sleepGlanceZone: AtriaMetricZone?",
            "if sleepHistory.latest?.isNapEvidence == true { return nil }",
            "private var sleepHistoryCard: some View",
            "AtriaSleepHistoryGlanceCard(snapshot: sleepHistory,",
            "onOpenVitals: onOpenVitals",
            "private struct AtriaSleepHistoryGlanceCard: View, Equatable",
            "Text(\"Sleep history\")",
            "return snapshot.candidateCount > 0 ? \"\\(snapshot.candidateCount)\" : \"--\"",
            "return snapshot.candidateCount == 1 ? \"Sleep/nap candidate\" : \"Sleep/nap candidates\"",
            "Sleep history has \\(snapshot.candidateCount) sleep or nap candidate\\(snapshot.candidateCount == 1 ? \"\" : \"s\") ready to review.",
            "return \"\\(latest.evidenceLabel) · debt \\(snapshot.sleepDebtText(goalHours: sleepGoalHours))\"",
            "private var morningStatus: AtriaSleepMorningStatus",
            "latest.isNapEvidence",
            "return latest.confirmed ? .sync : .review",
            "AtriaSleepMorningStatusStrip(status: morningStatus)",
            "private enum AtriaSleepMorningStatus: String, Equatable",
            "private struct AtriaSleepMorningStatusStrip: View, Equatable",
            "Morning sleep status. \\(status.accessibilityText)",
            "if let latest, !latest.displayStageSegments.isEmpty",
            "AtriaSleepMiniHypnogram(segments: latest.displayStageSegments,",
            "Text(\"Stages calibrating\")",
            "ForEach(Array(SleepStageKind.displayOrder.enumerated()), id: \\.element)",
            "AtriaSleepStageGlyph.color(for: stage).opacity(0.28)",
            "private func fallbackStageHeight(_ stage: SleepStageKind) -> CGFloat",
            "private struct AtriaSleepMiniHypnogram: View, Equatable",
            "Canvas { context, size in",
            "width: min(width, max(0, size.width - x))",
            "AtriaSleepStageGlyph.color(for: segment.stage)",
            "Awake \\(latest.stageText(.awake))",
            "Open Vitals. Sleep history is building. Wear the strap overnight or during a nap.",
            "sleepHistory.averageFootnoteText",
            "snapshot.sleepConsistencyText",
            "snapshot.sleepDebtText(goalHours: sleepGoalHours)",
            "AtriaGlanceMetricCard(title: \"Resp rate\"",
            "value: sleepHistory.latest?.respiratoryRateText ?? \"--\"",
            "Sleep signal",
            "detail: sleepHistory.latest?.respiratoryRate == nil ? \"Sleep signal\" : \"Early\"",
            "accessibilityDetail: sleepHistory.latest?.respiratoryRate == nil",
            "Respiratory rate is building from sleep-only evidence.",
            "AtriaGlanceMetricCard(title: \"Strap steps\"",
            "value: sensorSummary.strapStepText",
            "detail: sensorSummary.strapStepCount > 0 ? \"Strap movement\" : \"Not available on this strap\"",
            "Strap movement estimate",
            "Strap steps are not available — this strap's motion stream has never been decodable.",
            "accessibilityDetail: sensorSummary.strapStepCount > 0",
            # TODO(superseded by consolidation, ac1a820f): pre-merge there were separate
            # .steps (iPhone motion) and .strapSteps (strap-based, bound to
            # strapStepsZone/agreementText) glance cases. ac1a820f dropped the phone-
            # motion card and rebound the surviving strap-steps card (pinned just above)
            # to the plainer stepsZone/"Strap movement"/"Calibrating" copy instead of
            # strapStepsZone. strapStepsZone itself is left declared but now unused --
            # its old copy is still checked below since the property body still exists.
            "private var strapStepsZone: AtriaMetricZone?",
            "Metrics.stepsZone(sensorSummary.strapStepCount, goal: stepsGoal)",
            "title: \"Strap movement goal\"",
            "Source: \\(sensorSummary.agreementText).",
            "Strap steps stay labeled as estimates until strap movement calibration is validated.",
            "Strap movement estimate. \\(AtriaMetricZone.nonMedicalDisclaimer)",
            "AtriaGlanceMetricCard(title: \"Calories\"",
            "accessibilityDetail: \"Active calories estimate",
            "AtriaGlanceMetricCard(title: \"VO2max\"",
            "accessibilityDetail: vo2MaxEstimate.value == nil",
            "AtriaGlanceMetricCard(title: \"Fitness age\"",
            "accessibilityDetail: biologicalAgeSummary.isReady",
            "case .steps:",
            "Adjust the daily strap-step goal used by the steps card.",
            "AtriaGlanceMetricCard(title: \"Blood oxygen\"",
            "value: sensorSummary.spo2CandidateFrames > 0 ? \"Signal\" : \"--\"",
            "detail: sensorSummary.spo2CandidateFrames > 0 ? \"\\(sensorSummary.spo2CandidateFrames) candidate frames\" : \"Sleep signal\"",
            "accessibilityDetail: sensorSummary.spo2CandidateFrames > 0",
            "not an SpO2 reading",
            "does not show an SpO2 percentage",
            "AtriaGlanceMetricCard(title: \"Body temp\"",
            "value: sensorSummary.skinTemperatureDeviation.isReady ? sensorSummary.skinTemperatureDeviation.valueText : \"--\"",
            "detail: sensorSummary.skinTemperatureDeviation.detailText",
            "accessibilityDetail: sensorSummary.skinTemperatureDeviation.isReady",
            "relative signal",
            "delta C from baseline",
            "does not show an absolute temperature",
            "insights: store.behaviorInsights",
            "taggedDays: store.behaviorJournalEntries.count",
            "let insights: [AtriaInsight]",
            "let taggedDays: Int",
            "AtriaPanelSectionHeader(title: \"Insights\", subtitle: \"What moves your HRV\")",
            "Atria learns what moves your HRV.",
            "let hiddenMetrics: [AtriaTodayMetric]",
            "let onShiftMetric: (AtriaTodayMetric, Int) -> Void",
            "let onHideMetric: (AtriaTodayMetric) -> Void",
            "let onShowMetric: (AtriaTodayMetric) -> Void",
            "let sizeOverridesCSV: String",
            "let onToggleMetricSize: (AtriaTodayMetric) -> Void",
            "@State private var isEditingGlance = false",
            "@State private var showWidgetManager = false",
            "if isEditingGlance {",
            ".transition(.scale.combined(with: .opacity))",
            "isEditingGlance = false",
            ".accessibilityLabel(\"Finish editing widgets\")",
            "let onResetMetrics: () -> Void",
            "let onStartWorkout: () -> Void",
            "&& lhs.insights == rhs.insights",
            "&& lhs.hiddenMetrics == rhs.hiddenMetrics",
            "&& lhs.sizeOverridesCSV == rhs.sizeOverridesCSV",
            # TODO(removed feature): the Workout glance card was dropped along with the
            # other IA-3 cases (see the "removed IA-3 glance cases" comment on
            # AtriaTodayMetric.systemImage) -- starting a workout now lives in
            # AtriaTodayShortcutStrip (onStartWorkout, pinned above), not its own glance
            # tile. Not re-adding it.
            "private var insightsCard: some View",
            "Button(action: onOpenInsights)",
            "AtriaGlanceMetricCard(title: \"Insights\"",
            "detail: topInsight?.tagLabel ?? (taggedDays > 0 ? \"Learning patterns\" : \"Tag today\")",
            "Open Trends. Insights building from \\(taggedDays) tagged days",
            "private struct AtriaConditionalStringDraggable: ViewModifier",
            "case .stress: return \"Stress\"",
            "case .stress: return \"bolt.heart.fill\"",
            "case .hrv, .stress: return .pink",
            ".modifier(AtriaConditionalStringDraggable(isEnabled: true,",
            "payload: metric.dragPayload))",
            "if isEnabled {\n            content.draggable(payload)",
            ".dropDestination(for: String.self)",
            "AtriaTodayMetric.draggedMetric(from: raw)",
            "isEditingGlance = true",
            "onMoveMetric(dragged, metric)",
            "AtriaGlanceMetricCard(title: \"Stress\"",
            "value: hero.stressValue",
            "detail: hero.stressDetail",
            "accessibilityDetail: \"\\(hero.stressNarrative) Opens guided breathwork.\")",
            "private var stressTint: Color",
            "let upLabel = Text(\"Move \\(metric.label) up\")",
            "let downLabel = Text(\"Move \\(metric.label) down\")",
            ".accessibilityAction(named: upLabel)",
            ".accessibilityAction(named: downLabel)",
            "onShiftMetric(metric, -1)",
            "onShiftMetric(metric, 1)",
            ".accessibilityAction(named: Text(\"Edit \\(metric.label) widget\"))",
            ".contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset,",
            "guard isEditingGlance, metric.supportsGlanceTargetEditing else { return }",
            ".accessibilityAction(named: Text(\"Edit \\(metric.label) target\"))",
            ".accessibilityAction(named: Text(\"\\(metric.nextGlanceSizeActionLabel(sizeOverrides: sizeOverrides)): \\(metric.label)\"))",
            ".accessibilityAction(named: Text(\"Remove \\(metric.label) widget\"))",
            ".accessibilityHint(\"Drag to reorder, or long press to edit with target, resize, and remove controls.\")",
            "private func hideMetric(_ metric: AtriaTodayMetric)",
            "private func showMetric(_ metric: AtriaTodayMetric)",
            "private func resetMetrics()",
            "hiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)",
            "private var addWidgetMenu: some View",
            "showWidgetManager = true",
            ".sheet(isPresented: $showWidgetManager)",
            "AtriaGlanceWidgetManagerSheet(hiddenMetrics: hiddenMetrics",
            "private struct AtriaGlanceWidgetManagerSheet: View",
            "managerSection(title: \"More metrics\"",
            "managerSection(title: \"Experimental\"",
            "Label(\"Edit on cards\", systemImage: \"square.grid.2x2\")",
            "Image(systemName: \"plus\")",
            "GlassEffectContainer(spacing: 10)",
            "glanceRemoveControl(for: metric)",
            "glanceTargetControl(for: metric)",
            "glanceResizeControl(for: metric, sizeOverrides: sizeOverrides)",
            "private func glanceRemoveControl(for metric: AtriaTodayMetric) -> some View",
            "private func glanceTargetControl(for metric: AtriaTodayMetric) -> some View",
            "private func glanceResizeControl(for metric: AtriaTodayMetric,\n                                     sizeOverrides: [String: AtriaGlanceGridSize]) -> some View",
            "Label(\"Editing widgets\", systemImage: \"square.grid.2x2\")",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            ".overlay(alignment: .topTrailing)",
            ".overlay(alignment: .bottomTrailing)",
            ".overlay(alignment: .bottomLeading)",
            "@State private var targetEditorMetric: AtriaTodayMetric?",
            "if metric.supportsGlanceTargetEditing",
            "case .recovery, .strain, .load, .hrv, .sleep, .sleepHistory, .sleepEfficiency, .rhr, .respiratoryRate, .steps, .calories, .vo2max, .bioAge, .bloodOxygen, .bodyTemp:",
            "targetEditorMetric = metric",
            "if isEditingGlance, metric.supportsGlanceTargetEditing",
            "AtriaGlanceTargetEditorSheet(metric: metric)",
            "case .sleep, .sleepHistory:",
            "Adjust the sleep goal used by sleep history, debt, and consistency.",
            "Label(\"No target controls\", systemImage: \"info.circle\")",
            "This Today card is an action or trend shortcut, so it uses its source state instead of a personal target zone.",
            "Action and trend shortcuts do not use personal target zones.",
            "Image(systemName: \"xmark.circle.fill\")",
            ".font(.callout.weight(.black))",
            "Image(systemName: metric.nextGlanceSizeSystemImage(sizeOverrides: sizeOverrides))",
            "return \"rectangle.expand.horizontal\"",
            "if size.isWideShort { return \"Make compact\" }",
            "onToggleMetricSize(metric)",
            ".atriaGlassIconAction(tint: .secondary, size: 38)",
            ".atriaGlassIconAction(tint: .secondary, size: 36)",
            ".atriaGlassIconAction(tint: metric.targetEditorTint, size: 36)",
            ".atriaGlassIconAction(tint: .red, size: 36)",
            ".frame(minWidth: 96)",
            ".atriaCardAction(tint: tint)",
            ".accessibilityHint(\"Opens the target zone controls for this Today widget.\")",
            ".accessibilityHint(\"Removes this card from Today at a glance. Use the plus button to add it back.\")",
            ".accessibilityLabel(\"Add Today widget\")",
            "\"Opens hidden Today widgets you can add. Long press a card to remove or resize it.\"",
            "AtriaSleepHistoryGlanceCard(snapshot: sleepHistory,",
            "onOpenVitals: onOpenVitals",
            "onAddManualSleep: {",
            "Image(systemName: \"moon.zzz.badge.plus\")",
            "stage.shortLabel",
            ".minimumScaleFactor(0.62)",
            ".allowsTightening(true)",
            ".frame(maxWidth: .infinity, alignment: .center)",
            "case .awake: return \"AWAKE\"",
            "case .light: return \"LIGHT\"",
            "case .rem: return \"REM\"",
            "case .sws: return \"SWS\"",
            "case .deep: return \"DEEP\"",
            ".contextMenu {",
            "Label(\"Remove widget\", systemImage: \"xmark\")",
            "Button(role: .destructive)",
            ".clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))",
            "private func shiftMetric(_ metric: AtriaTodayMetric, direction: Int)",
            ".sensoryFeedback(.selection, trigger: orderCSV)",
            ".sensoryFeedback(.selection, trigger: sizeCSV)",
        ]:
            assert_contains(self, overview, needle)
        daily_focus_start = overview.index("private var dailyFocusItems: [AtriaDailyFocusRail.Item]")
        daily_focus_end = overview.index("private var liveFocusDetailText")
        assert_not_contains(self, overview[daily_focus_start:daily_focus_end], '"\\(live.sessionSampleCount) samples"')
        for forbidden in [
            "AtriaGlanceWidgetManagerSheet(visibleMetrics: visibleMetrics",
            "managerSection(title: \"Added widgets\"",
            "actionTitle: \"Remove\"",
            "actionImage: \"xmark.circle.fill\"",
            "\"Opens added and hidden Today widgets so you can remove or add cards.\"",
            ".accessibilityLabel(\"Manage Today widgets\")",
        ]:
            assert_not_contains(self, overview, forbidden)

        assert_contains(self, home, "profileMetricsStore: model.profileMetricsStore")
        assert_contains(self, home, "onStartWorkout: {\n                                 liveWorkoutLoggedSets = []\n                                 liveWorkoutExcludedIntervals = []\n                                 liveWorkoutMinimized = false\n                                 workoutSession = AtriaWorkoutSession(start: Date())\n                             }")
        assert_contains(self, vitals, "AtriaTrainingLoadTile(ratio: hero.loadRatioText")
        assert_contains(self, vitals, "targetMetric: .load)")
        assert_contains(self, vitals, "Long press to edit target.")

        assert_not_contains(self, overview, "LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)]")
        assert_not_contains(self, overview, "row.map(\\.glanceColumnSpan).reduce")
        assert_not_contains(self, overview, "precondition(metric.glanceGridSize.isValidGlanceShape")
        assert_not_contains(self, overview, "precondition(rowFitsGlanceGrid(row)")
        assert_not_contains(self, overview, "private var customizeMenu: some View")
        assert_not_contains(self, overview, "Label(isEditingGlance ? \"Done editing\" : \"Edit widgets\", systemImage: \"square.grid.2x2\")")
        assert_not_contains(self, overview, "Section(\"Hide widget\")")
        assert_not_contains(self, overview, "guard visibleCount > 1 else { return }")
        assert_not_contains(self, overview, ".background(Color(.systemBackground).opacity(0.82), in: Capsule(style: .continuous))")
        assert_not_contains(self, overview, ".background(Color(.systemBackground).opacity(0.74), in: Capsule(style: .continuous))")
        assert_not_contains(self, overview, "Image(systemName: \"slider.horizontal.3\")")
        assert_not_contains(self, overview, "Label(\"Reset widgets\", systemImage: \"arrow.counterclockwise\")")
        assert_not_contains(self, overview, "This widget does not have an editable target yet.")
        assert_not_contains(self, overview, "Target editing is not available for this widget yet.")
        assert_not_contains(self, overview, "figure.run.circle.fill")
        # Narrowed from a bare "heart.text.square.fill" substring guard: that SF Symbol
        # is now legitimately reused by the journal health-auto-tag badge (see
        # "healthAutoTags"/"heart.text.square.fill" assertions elsewhere in this file),
        # so only forbid it as the old RHR glance-card icon this check originally
        # targeted (d4102540).
        assert_not_contains(self, overview, "case .rhr: return \"heart.text.square.fill\"")
        assert_not_contains(self, overview, "flame.circle.fill")
        assert_not_contains(self, overview, "detail: hrvLearningState == .learning ? \"Building\" : \"Baseline\"")
        assert_not_contains(self, overview, "private var hrvLearningState: AtriaMetricState")
        assert_not_contains(self, overview, "Label(\"Remove \\(metric.label)\", systemImage: \"minus.circle\")")
        assert_not_contains(self, overview, ".accessibilityLabel(\"Widget options for \\(metric.label)\")")
        assert_not_contains(self, overview, "private func glanceEditControls(for metric: AtriaTodayMetric,")
        assert_not_contains(self, overview, ".background(Color(.systemBackground).opacity(0.82), in: Circle())")
        assert_not_contains(self, overview, ".buttonStyle(.glass)")
        assert_not_contains(self, overview, ".buttonBorderShape(.circle)")
        assert_not_contains(self, overview, "degrees Celsius from baseline")

        for needle in [
            "@AtriaDefault(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = \"\"",
            "@AtriaDefault(AtriaTodayMetric.sizeStorageKey) private var todaySizeCSV = \"\"",
            "ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV))",
            "private func resetTodayLayout()",
            "todayOrderCSV = AtriaTodayMetric.defaultGlanceOrder.map(\\.rawValue).joined(separator: \",\")",
            "todayHiddenCSV = \"\"",
            "todaySizeCSV = \"\"",
            "hidden.insert(metric.rawValue)",
            "todayHiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)",
            "Label(\"Reset Today layout\", systemImage: \"arrow.counterclockwise\")",
            "AtriaTodayMetric.moving(metric, direction: -1, in: todayOrderCSV)",
            "AtriaTodayMetric.moving(metric, direction: 1, in: todayOrderCSV)",
            "Choose, reorder, and reset the cards shown at a glance.",
            "private func targetGroupHeader(title: String,",
            "targetGroupHeader(title: \"Recovery\"",
            "targetGroupHeader(title: \"Strain\"",
            "targetGroupHeader(title: \"Training load\"",
            "targetGroupHeader(title: \"Activity\"",
            "targetGroupHeader(title: \"Sleep\"",
            "targetGroupHeader(title: \"Personal baselines\"",
            "targetGroupHeader(title: \"Sleep-only signals\"",
            "These bands tune sleep-only deviations and candidate-frame evidence.",
            "They do not turn these signals into validated SpO2 or absolute body-temperature readings.",
            "targetGroupHeader(title: \"Fitness age\"",
            "Fitness age is estimated from RHR, lnRMSSD, weekly zone-2+ minutes, and sleep consistency.",
            "not a medical measurement; these bands only tune younger/older color guidance.",
            "targetGroupHeader(title: \"VO2max\"",
        ]:
            assert_contains(self, settings, needle)
        assert_not_contains(self, settings, "private func canHideTodayMetric(_ metric: AtriaTodayMetric,")
        assert_not_contains(self, settings, "AtriaTodayMetric.defaultGlanceOrder.filter { !activeHidden.contains($0.rawValue) }.count > 1")
        assert_not_contains(self, settings, ".disabled(todayBinding(metric).wrappedValue && !canHideTodayMetric(metric))")
        assert_not_contains(self, overview, "AtriaInsightsCardHost(store: store)")

        for needle in [
            "@AtriaDefault(AtriaVitalsSection.orderStorageKey) private var sectionOrderCSV = \"\"",
            "@State private var isEditingVitalsLayout = false",
            "Label(\"Editing Vitals\", systemImage: \"rectangle.3.group\")",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            "enum AtriaVitalsSection: String, CaseIterable, Identifiable",
            "static let orderStorageKey = \"atria.vitals.sectionOrderCSV\"",
            "private static let dragPayloadPrefix = \"atria.vitals.section:\"",
            "var dragPayload: String",
            "static func draggedSection(from payload: String) -> AtriaVitalsSection?",
            "var label: String",
            "case .recoveryStrain: return \"Recovery and strain\"",
            "private func vitalsSectionEditControls(for section: AtriaVitalsSection) -> some View",
            "Image(systemName: \"chevron.up\")",
            "Image(systemName: \"chevron.down\")",
            "GlassEffectContainer(spacing: 10)",
            ".atriaGlassIconAction(tint: .secondary, size: 44)",
            "private struct AtriaConditionalVitalsStringDraggable: ViewModifier",
            ".modifier(AtriaConditionalVitalsStringDraggable(isEnabled: true,",
            "if isEnabled {\n            content.draggable(payload)",
            "AtriaVitalsSection.draggedSection(from: raw)",
            "isEditingVitalsLayout = true",
            "AtriaVitalsSection.moving(dragged, before: section, in: sectionOrderCSV)",
            ".accessibilityAction(named: Text(\"Move \\(section.label) up\"))",
            ".accessibilityAction(named: Text(\"Move \\(section.label) down\"))",
            ".accessibilityHint(\"Drag to reorder this Vitals section, or long press to reveal the visible move controls.\")",
            "private func moveSection(_ section: AtriaVitalsSection, direction: Int)",
            "private var hasCustomVitalsLayout: Bool",
            "AtriaVitalsSection.ordered(from: sectionOrderCSV) != Array(AtriaVitalsSection.allCases)",
            "private func resetVitalsLayout()",
            "sectionOrderCSV = AtriaVitalsSection.allCases.map(\\.rawValue).joined(separator: \",\")",
            "isEditingVitalsLayout = false",
            "Label(\"Reset Vitals layout\", systemImage: \"arrow.counterclockwise\")",
            ".accessibilityHint(\"Restores Pulse, HRV, Recovery and strain, and Profile to the default order.\")",
            ".sensoryFeedback(.selection, trigger: sectionOrderCSV)",
            "private static let regularSectionColumns = [",
            "LazyVGrid(columns: Self.regularSectionColumns, spacing: 18)",
            "static func moving(_ section: AtriaVitalsSection, direction: Int, in csv: String) -> String",
        ]:
            assert_contains(self, vitals, needle)

        assert_not_contains(self, vitals, "func enumeratedColumn(_ column: Int) -> [AtriaVitalsSection]")
        assert_not_contains(self, vitals, "sections.enumeratedColumn(")
        assert_not_contains(self, overview, ".draggable(metric.rawValue)")
        assert_not_contains(self, overview, ".draggable(metric.dragPayload)")
        assert_not_contains(self, overview, "let dragged = AtriaTodayMetric(rawValue: raw)")
        assert_not_contains(self, vitals, ".draggable(section.rawValue)")
        assert_not_contains(self, vitals, "let dragged = AtriaVitalsSection(rawValue: raw)")

        layout_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaLayoutModelTests.swift")
        for needle in [
            "final class AtriaLayoutModelTests: XCTestCase",
            "testVitalsSectionOrderRepairsMalformedAndDuplicateCSV",
            "testVitalsSectionDragAndBoundaryMovesStayStable",
            "testTodayMetricVisibleReorderPreservesHiddenSlots",
            "testTodayMetricDragPayloadRejectsRawValues",
            "AtriaVitalsSection.moving(.profile, before: .pulse",
            "AtriaTodayMetric.moving(.stress,",
            "hiddenStorageValue(for:",
        ]:
            assert_contains(self, layout_tests, needle)

    def test_handoff_21_connection_diagnosis_is_actionable_inline(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        shell_support = source(ROOT / "Atria" / "Atria" / "AtriaHomeShellSupport.swift")
        hero_connection = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private struct AtriaConnectionDiagnosis: Equatable",
            "private static let lowBatteryThreshold = 25",
            "private static let pendingKnownReconnectActionAge: TimeInterval = 15",
            "private static let connectionDiagnosisPersistenceDelay: TimeInterval = 15",
            "private static let connectionDiagnosisTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()",
            "@State private var connectionDiagnosisCandidate: AtriaConnectionDiagnosis?",
            "@State private var connectionDiagnosisCandidateSince: Date?",
            "@State private var visibleConnectionDiagnosis: AtriaConnectionDiagnosis?",
            "fileprivate struct AtriaConnectionDiagnosisLiveTrigger: Equatable",
            "fileprivate struct AtriaConnectionDiagnosisPulseTrigger: Equatable",
            "private var connectionDiagnosisUpdates: AnyPublisher<Void, Never>",
            ".onReceive(connectionDiagnosisUpdates)",
            "updateConnectionDiagnosisVisibility(reason: \"connection_trigger\")",
            ".map(AtriaConnectionDiagnosisLiveTrigger.init)",
            ".map(AtriaConnectionDiagnosisPulseTrigger.init)",
            ".onReceive(Self.connectionDiagnosisTimer)",
            "private func updateConnectionDiagnosisVisibility(reason: String, now: Date = Date())",
            "AtriaConnectionDiagnosis.derive(live: model.coreLiveStore.state",
            "AtriaConnectionDiagnosisBanner(diagnosis: diagnosis)",
            "private struct AtriaConnectionDiagnosisBanner: View, Equatable",
            ".background(Color(uiColor: .secondarySystemBackground),",
            "guard elapsed >= Self.connectionDiagnosisPersistenceDelay else",
            "visibleConnectionDiagnosis = nil",
            "var showsImmediately: Bool",
            "title == \"Bluetooth is off\"",
            "title == \"Bluetooth permission needed\"",
            "title == \"Strap battery too low\"",
            "title == \"Strap battery low\"",
            "var sendsLocalNotification: Bool",
            "next.sendsLocalNotification && visibleConnectionDiagnosis != next",
            "live.batteryLevel <= Self.lowBatteryThreshold",
            "live.batteryRecentlyDropping",
            "var bluetoothPermissionDenied: Bool",
            "bluetoothPermissionDenied: ble.bluetoothPermissionDenied",
            "private var bluetoothPermissionDenied: Bool { statusStore.state.bluetoothPermissionDenied }",
            "var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk",
            "var batteryRecentlyDropping: Bool",
            "var strapStreamState: AtriaBLEManager.StrapStreamState",
            "var isLowBatteryBroadcastShutoff: Bool { strapStreamState == .lowBatteryShutoff }",
            "var isLowBatteryLiveLimited: Bool",
            "strapStreamState: ble.strapStreamState",
            "case .connected where live.isLowBatteryLiveLimited",
            "Charge your strap to resume live heart rate.",
            "var lastScanRequestedAt: Date?",
            "var lastScanMatchAt: Date?",
            "var pendingKnownReconnectStartedAt: Date?",
            "var pendingKnownReconnectReason: String",
            "var rangeLossBackfillPending: Bool",
            "func pendingKnownReconnectAge(now: Date = Date()) -> TimeInterval?",
            "func isInRecentLiveRecovery(now: Date = Date()) -> Bool",
            "var needsRRQualityCoach: Bool { rrContinuityState == \"poor_contact\" }",
            "let hasLivePulseSignal = pulse.hasPulseSignal || live.hasRecentHeartRateSample",
            "let isRecoveringLiveSignal = live.isInRecentLiveRecovery()",
            "&& !isRecoveringLiveSignal",
            "ble.$bluetoothPermissionDenied.removeDuplicates()",
            "ble.$batteryRecentlyDropping.removeDuplicates()",
            "ble.$officialAppCoexistenceRisk.removeDuplicates()",
            "ble.$lastScanRequestedAt.removeDuplicates()",
            "ble.$lastScanMatchAt.removeDuplicates()",
            "ble.$pendingKnownReconnectStartedAt.removeDuplicates()",
            "ble.$pendingKnownReconnectReason.removeDuplicates()",
            "ble.$rangeLossBackfillPending.removeDuplicates()",
            "live.bluetoothPermissionDenied",
            "batteryRecentlyDropping: ble.batteryRecentlyDropping",
            "officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk",
            "lastScanRequestedAt: ble.lastScanRequestedAt",
            "lastScanMatchAt: ble.lastScanMatchAt",
            "pendingKnownReconnectStartedAt: ble.pendingKnownReconnectStartedAt",
            "pendingKnownReconnectReason: ble.pendingKnownReconnectReason",
            "rangeLossBackfillPending: ble.rangeLossBackfillPending",
            "case .connected where needsContactCoach:",
            "return AtriaConnectionDiagnosis(title: \"Fit check needed\"",
            "case .connected where live.needsRRQualityCoach && !hasLivePulseSignal:",
            "Beat-to-beat waiting",
            "Atria needs pulse before it can build HRV and Recovery.",
            "case .connected where live.needsRRQualityCoach && hasLivePulseSignal:",
            "HRV settling",
            "Heart rate is live. Keep wearing normally while HRV settles.",
            "case .connected where officialAppRiskActive && live.officialAppCoexistenceRisk == .suspected:",
            "WHOOP may interrupt",
            "Close or uninstall WHOOP if readings fragment.",
            "case .connected where officialAppRiskActive:",
            "WHOOP app watch",
            "Atria is streaming; close WHOOP if drops return.",
            "let officialAppRiskActive = officialAppInstalled && live.officialAppCoexistenceRisk != .cleared",
            "let stalePairingSuspected = !officialAppInstalled && live.officialAppCoexistenceRisk == .suspected",
            "let pendingKnownReconnectAge = live.pendingKnownReconnectAge() ?? 0",
            "let pendingKnownReconnectActive = pendingKnownReconnectAge >= Self.pendingKnownReconnectActionAge",
            "case .scanning, .connecting:\n            if officialAppRiskActive",
            "Keep the strap nearby and close WHOOP if it keeps reclaiming it.",
            "Strap out of range",
            "Atria is still reconnecting to your saved strap. Bring it closer or keep wearing it.",
            "Atria is still waiting for your saved strap. Bring it closer or keep wearing it.",
            "Connection keeps dropping",
            "Stale Bluetooth pairing",
            "Forget the strap in Bluetooth, then reconnect.",
            "Turn on Bluetooth in Settings.",
            "Allow Bluetooth for Atria in Settings.",
            "Tighten the strap fit so Atria can read pulse.",
            "Bring your strap closer and keep it on your wrist.",
            "Charge your strap before a workout or overnight wear.",
            "Close or uninstall WHOOP if it keeps reclaiming the strap.",
            "forget it in Bluetooth and reconnect",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, ".onReceive(model.coreLiveStore.$state.map { _ in () })")
        assert_not_contains(self, home, ".onReceive(model.pulseLiveStore.$state.map { _ in () })")
        for needle in [
            "officialAppInstalled\n                ? \"Atria has seen connection behavior that can happen when the official strap app or widget is still holding the strap.\"",
            "Atria has seen quick connection drops. Since the official strap app is not detected, this usually points to range, battery, or a stale Bluetooth pairing.",
            "officialAppInstalled\n                ? \"Remove or fully disable the official strap app before relying on Atria for overnight or workout collection.\"",
            "Keep the strap close and charged. If drops continue, forget the strap in Bluetooth, then reconnect in Atria.",
            "Atria keeps scanning for your saved strap. Keep it nearby; if reconnects keep dropping, use the connection guide for the right recovery path.",
        ]:
            assert_contains(self, shell_support + hero_connection, needle)
        for needle in [
            "if context.officialAppInstalled && context.officialAppCoexistenceRisk == .suspected",
            "return \"Remove the official strap app first.\"",
            "return \"Keep strap nearby.\"",
            "if context.officialAppInstalled {\n            var items = [",
            "\"Remove the official strap app\"",
            "\"Keep Bluetooth on\"",
            "\"Let Atria scan\"",
        ]:
            assert_contains(self, overview, needle)
        for needle in [
            "let atriaOwnedOfflineSyncDisconnect = offlineHistoricalSyncInProgress || historyOnlyProbeEnabled || historyOnlyProbeMode",
            "reason=atria_owned_offline_sync_disconnect",
            "persistOfficialAppCoexistenceRisk(.suspected, reason: \"short_disconnect_after_connect\")",
        ]:
            assert_contains(self, ble, needle)
        assert_not_contains(self, home, "Connected, no pulse")
        diagnosis_banner = re.search(
            r"private struct AtriaConnectionDiagnosisBanner: View, Equatable \{(?P<body>.*?)\n\}",
            home,
            re.S,
        )
        self.assertIsNotNone(diagnosis_banner)
        self.assertNotIn(".buttonStyle(.glass", diagnosis_banner.group("body"))
        self.assertNotIn(".glassEffect(", diagnosis_banner.group("body"))

        diagnosis = re.search(
            r"static func derive\(live: AtriaHomeModel\.CoreLiveState,\n                       pulse: AtriaHomeModel\.PulseLiveState,\n                       officialAppInstalled: Bool\) -> AtriaConnectionDiagnosis\? \{(?P<body>.*?)\n    \}",
            home,
            re.S,
        )
        self.assertIsNotNone(diagnosis)
        diagnosis_body = diagnosis.group("body")
        powered_off_index = diagnosis_body.find("case .poweredOff:")
        low_battery_index = diagnosis_body.find("case _ where live.batteryLevel >= 0")
        contact_index = diagnosis_body.find("case .connected where needsContactCoach:")
        hrv_settling_index = diagnosis_body.find("case .connected where live.needsRRQualityCoach && hasLivePulseSignal:")
        self.assertGreaterEqual(powered_off_index, 0)
        self.assertGreaterEqual(contact_index, 0)
        self.assertGreaterEqual(hrv_settling_index, 0)
        self.assertGreater(low_battery_index, powered_off_index)
        self.assertGreater(low_battery_index, contact_index)
        self.assertGreater(low_battery_index, hrv_settling_index)

        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        for needle in [
            "@Published private(set) var bluetoothPermissionDenied = false",
            "@Published private(set) var batteryRecentlyDropping: Bool = false",
            "case .unauthorized:",
            "assignIfChanged(\\.bluetoothPermissionDenied, true)",
            "recomputeConnectionStatus(reason: \"central_unauthorized\")",
            "static let dropAt = \"atria.battery.dropAt\"",
            "static let dropDelta = \"atria.battery.dropDelta\"",
            "static func cachedBatteryDrop(maxAge: TimeInterval = 6 * 60 * 60) -> (recent: Bool, delta: Int, age: TimeInterval)",
            "battery_drop_recent=\\(drop.recent ? 1 : 0)",
            "assignIfChanged(\\.batteryRecentlyDropping, true)",
            "clearBatteryDropMarker()",
        ]:
            assert_contains(self, ble, needle)

        assert_not_contains(self, home, "showConnectionDiagnosisModal")
        assert_not_contains(self, home, "needsRRContactCoach")
        assert_not_contains(self, home, "Beat-to-beat signal weak")
        assert_not_contains(self, home, "Tighten the strap fit or wet the sensor")

    def test_handoff_21_battery_saver_radio_mode_is_user_visible(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "let batterySaverEnabled: Bool",
            "let onUpdateBatterySaver: (Bool) -> Void",
            "@State private var batterySaver: Bool",
            "radioModeSection",
            "Toggle(isOn: $batterySaver)",
            "Label(\"Battery saver\", systemImage: \"battery.75percent\")",
            "title: batterySaver ? \"Heart-rate only\" : \"Full sensor mode\"",
            "HRV, Recovery and sleep detail wait for validated beat-to-beat windows.",
            "Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research.",
            "Atria reconnects the strap when the radio mode changes.",
            ".onChange(of: batterySaver) { _, value in onUpdateBatterySaver(value) }",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "batterySaverEnabled: ble.standardHROnlyEnabled",
            "onUpdateBatterySaver: { ble.setStandardHROnlyEnabled($0) }",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, "private struct AtriaHeaderZoneIndicator")
        assert_not_contains(self, home, "AtriaHeaderZoneIndicator(zone:")

        for needle in [
            "func setStandardHROnlyEnabled(_ enabled: Bool)",
            "applyStandardHROnly(enabled: enabled, persist: true, reconnect: true, reason: \"user_toggle\")",
        ]:
            assert_contains(self, ble, needle)

    def test_strap_battery_charge_status_is_visible_and_honest(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        live_activity = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityAttributes.swift")
        live_activity_widget_attrs = source(ROOT / "Atria" / "AtriaWidget" / "AtriaLiveActivityAttributes.swift")
        live_activity_coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        data = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        widget_snapshot = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")
        pull_state = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "enum BatteryChargeStatus: String, Equatable",
            "case levelOnly",
            "case charging",
            "case notCharging",
            "case full",
            "@Published var batteryChargeStatus: BatteryChargeStatus = .levelOnly",
            "static let chargeStatus = \"atria.battery.chargeStatus\"",
            "static let chargeAt = \"atria.battery.chargeAt\"",
            "static let batteryLevelStatus = CBUUID(string: \"2A1B\")",
            "return [UUIDs.batteryLevel, UUIDs.batteryLevelStatus]",
            "case UUIDs.heartRateMeasure, UUIDs.batteryLevel, UUIDs.batteryLevelStatus:",
            "peripheral.readValue(for: ch)",
            "if uuid == UUIDs.batteryLevelStatus",
            "parseBatteryChargeStatus(_ data: Data) -> BatteryChargeStatus?",
            "batteryPowerStateByte(fromBatteryLevelStatus: bytes)",
            "if bytes.count >= 3 { return bytes[2] }",
            "if bytes.count == 2, flags & 0x01 == 0 { return bytes[1] }",
            "let chargeState = (powerState >> 6) & 0x03",
            "if chargeState == 0x03 { return .charging }",
            "if chargeState == 0x02 { return .notCharging }",
            "wiredExternalPower == 0x03 || wirelessExternalPower == 0x03",
            "source=2A1B",
            "hydrateCachedBatteryStateIfFresh()",
            "private func hydrateCachedBatteryStateIfFresh(maxAge: TimeInterval = 86_400)",
            "batteryChargeStatus = cached.chargeStatus == .full && cached.level >= 100 ? .full : .levelOnly",
            "activeBatteryChargeEvidenceMaxAge",
            "activeBatteryChargeDisplayMaxAge",
            "private var batteryChargeExpirationTask: Task<Void, Never>?",
            "private var lastActiveBatteryChargeEvidenceAt: Date?",
            "private func recordBatteryChargeEvidence(_ status: BatteryChargeStatus,",
            "guard status == .charging else {",
            "scheduleBatteryChargeExpiration(reason: reason)",
            "private func expireStaleBatteryChargeStatus(reason: String)",
            "persistBatteryChargeStatus(.levelOnly, source: \"live_charge_timeout\")",
            "ATRIADBG battery_charge status=expired",
            "static func cachedBattery(maxAge: TimeInterval = 86_400,",
            "chargeMaxAge: TimeInterval = AtriaBLEManager.activeBatteryChargeEvidenceMaxAge",
            "BatteryChargeStatus(rawValue: rawCharge) ?? .levelOnly",
            "let effectiveChargeStatus = chargeFresh ? storedChargeStatus : .levelOnly",
            "battery_charge_status=\\(battery.chargeStatus.rawValue)",
            "battery_charge_age_s=\\(chargeAgeText)",
            "let cachedBattery = Self.cachedBattery(maxAge: 10 * 60)",
            "cachedBattery.chargeStatus == .full, cachedBattery.level >= 100",
            "assignIfChanged(\\.batteryChargeStatus, .levelOnly)",
            "var chargeEvidenceFromThisRead: BatteryChargeStatus?",
            "delta > 0 && delta <= 5",
            "assignIfChanged(\\.batteryChargeStatus, .charging)",
            "assignIfChanged(\\.batteryChargeStatus, .notCharging)",
            "assignIfChanged(\\.batteryChargeStatus, .full)",
            "persistBatteryLevel(batteryLevel, source: \"live_2A19\", chargeStatus: chargeEvidenceFromThisRead)",
            "if let chargeEvidenceFromThisRead {",
            "recordBatteryChargeEvidence(chargeEvidenceFromThisRead, reason: \"battery_level\")",
            "recordBatteryChargeEvidence(status, reason: \"battery_status\")",
            "persistBatteryChargeStatus(status, source: \"live_2A1B\")",
            "private func persistBatteryChargeStatus(_ status: BatteryChargeStatus, source: String)",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus",
            "var batteryChargeText: String",
            "var batteryShowsPowered: Bool",
            "var batteryChargeCompactText: String",
            "var batteryHeaderChargeText: String",
            "var batteryHeaderAccessoryText: String?",
            "var batteryAccessibilityChargeText: String",
            "var batteryAccessibilityText: String",
            "var batteryStatusSummaryText: String",
            "var batteryDetailText: String",
            "private var hasActiveChargingEvidence: Bool",
            "batteryIsCharging && batteryChargeStatus == .charging && !batteryRecentlyDropping",
            "var batteryShowsPowered: Bool { hasActiveChargingEvidence }",
            "batteryChargeStatus == .charging && !hasActiveChargingEvidence",
            "Strap battery level is live; waiting for fresh charger evidence",
            "case .levelOnly: return \"Strap state pending\"",
            "case .charging: return \"Strap charging\"",
            "case .notCharging: return \"Strap not charging\"",
            "case .full: return \"Strap full\"",
            "case .charging: return \"Charging\"",
            "guard batteryLevel >= 0 else { return \"waiting for strap battery\" }",
            "batteryHeaderChargeText == \"--\" ? batteryChargeText : batteryHeaderChargeText",
            "guard batteryLevel >= 0 else { return \"Strap battery pending.\" }",
            "return \"Strap battery \\(batteryText), \\(batteryAccessibilityChargeText).\"",
            "Strap battery level is live; waiting for strap charger-state signal",
            "guard batteryLevel >= 0 else { return \"Battery pending\" }",
            "return \"\\(batteryText) · \\(batteryChargeCompactText)\"",
            "if batteryShowsPowered { return \"battery.100percent.bolt\" }",
            "ble.$batteryChargeStatus.removeDuplicates()",
            "batteryChargeStatus: ble.batteryChargeStatus",
            "Text(isInline ? liveStore.state.batteryChargeCompactText : liveStore.state.batteryChargeText)",
            ".accessibilityLabel(accessibilityLabel)",
            "\"Live strap, \\(liveStore.state.batteryAccessibilityText)\"",
            "value: coreLiveStore.state.batteryStatusSummaryText",
            "detail: coreLiveStore.state.batteryDetailText",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, "var batteryText: String { batteryLevel >= 0 ? \"\\(batteryLevel)%\" : \"Waiting\" }")
        assert_not_contains(self, home, "guard batteryLevel >= 0 else { return \"Waiting\" }")
        assert_not_contains(self, home, "accessibilityLabel(\"Strap battery \\(liveStore.state.batteryText), \\(liveStore.state.batteryAccessibilityChargeText).\")")

        for path in [live_activity, live_activity_widget_attrs]:
            for needle in [
                "var batteryChargeStatus: String",
                "var batteryChargeText: String",
            ]:
                assert_contains(self, path, needle)

        for needle in [
            "var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus",
            "batteryChargeStatus: snapshot.batteryChargeStatus.rawValue",
            "batteryChargeText: snapshot.batteryChargeStatus.label",
            "|| snapshot.batteryChargeStatus != lastActivitySnapshot.batteryChargeStatus",
            "batteryChargeStatus: model.coreLiveStore.state.batteryChargeStatus",
        ]:
            assert_contains(self, live_activity_coordinator + home, needle)

        for needle in [
            "value: live.batteryStatusSummaryText",
            "AtriaInlineQuickStat(label: \"Charge\"",
            "value: live.batteryChargeText",
            "detail: live.batteryChargeStatus == .levelOnly",
            "? \"Strap battery level is live; charger state pending\"",
            ": \"Current strap charger status\"",
            "footnote: coreLiveStore.state.batteryDetailText",
            "tint: coreLiveStore.state.batteryShowsPowered ? .green : .blue",
        ]:
            assert_contains(self, overview + data, needle)

        for needle in [
            "let batteryLevel: Int?",
            "let batteryChargeStatus: String?",
            "let batteryChargeText: String?",
            "batteryLevel: ble.batteryLevel >= 0 ? ble.batteryLevel : nil",
            "batteryChargeStatus: ble.batteryChargeStatus.rawValue",
            "batteryChargeText: ble.batteryChargeStatus.label",
            "battery=%@ charge=%@",
            "formatInt(snapshot.batteryLevel)",
        ]:
            assert_contains(self, widget_snapshot, needle)

        for needle in [
            "let batteryLevel: Int?",
            "let batteryChargeStatus: String?",
            "let batteryChargeText: String?",
            "if let battery = batteryHeaderText",
            "Label(battery, systemImage: batterySymbol)",
            "if snapshot.batteryChargeStatus == \"charging\" { return \"battery.100percent.bolt\" }",
            "case \"charging\", \"full\": return .green",
            "liveActivityBatteryText(for: context.state)",
            "liveActivityBatterySymbol(for: context.state)",
            "liveActivityBatteryTint(for: context.state)",
            "private func liveActivityBatteryText(for state: AtriaLiveActivityAttributes.ContentState) -> String",
            "return state.batteryChargeText.isEmpty ? \"\\(state.batteryLevel)%\" : \"\\(state.batteryLevel)% · \\(state.batteryChargeText)\"",
        ]:
            assert_contains(self, widget, needle)

        for needle in [
            "def emit_battery_preferences():",
            "battery_namespace=",
            "battery_level=",
            "battery_charge_status=",
            "battery_charge_age_s=",
            "battery_is_charging=",
            "battery_drop_recent=",
        ]:
            assert_contains(self, pull_state, needle)

    def test_handoff_21_historical_backfill_status_is_visible_and_fail_closed(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        for needle in [
            "static let didUpdateNotification = Notification.Name(\"AtriaHistoricalArchiveDidUpdate\")",
            "static let relativePath = \"Documents/atria-historical/historical-archive.jsonl\"",
            "appendingPathComponent(\"atria-historical\", isDirectory: true)",
            "appendingPathComponent(\"whoop-historical\", isDirectory: true)",
            "if FileManager.default.fileExists(atPath: fileURL.path)",
            "return legacyFileURL",
            "NotificationCenter.default.post(name: didUpdateNotification, object: nil)",
        ]:
            assert_contains(self, archive, needle)

        for needle in [
            "struct HistoricalArchiveStatus: Equatable",
            "@Published private(set) var historicalArchiveStatus = HistoricalArchiveStatus.empty",
            "func refreshHistoricalArchiveStatus(reason: String = \"manual\")",
            "private var historicalArchiveStatusObserver: NSObjectProtocol?",
            "private var pendingHistoricalArchiveStatusRefresh: Task<Void, Never>?",
            "NotificationCenter.default.addObserver(forName: HistoricalArchive.didUpdateNotification",
            "scheduleHistoricalArchiveStatusRefresh(reason: \"archive_did_update\")",
            "pendingHistoricalArchiveStatusRefresh?.cancel()",
            "try? await Task.sleep(nanoseconds: 500_000_000)",
            "refreshHistoricalArchiveStatus(reason: reason)",
            "NotificationCenter.default.removeObserver(historicalArchiveStatusObserver)",
            "DispatchQueue.global(qos: .utility).async",
            "HistoricalArchive.diagnostics()",
            "return \"Saved\"",
            "if currentSessionUsableRows > 0 { return \"Gap repaired\" }",
            "return \"Saved · checking quality\"",
            "var userFootnoteText: String",
            "\\(currentSessionUsableRows)/\\(rows) missed readings saved. Atria is checking whether they can affect HRV, Recovery and Sleep.",
            "return \"\\(rows) missed readings saved locally. Atria is checking whether they can affect metrics.\"",
            "return \"\\(metricUsableRows)/\\(rows) rows metric-ready.\"",
            "var actionText: String",
            "Wear normally; Atria will pull missed rows after reconnect.",
            "The gap is repaired; metrics will use it after quality checks pass.",
            "The archive is saved; metrics will use it after quality checks pass.",
            "var metricGateText: String",
            "if metricReady { return \"Metric-ready\" }",
            "if currentSessionUsableRows > 0 { return \"Saved only\" }",
            "if hasArchiveRows { return \"Checking\" }",
            "metric_ready=%d fail_closed=%d status=%@ gate=%@ detail=%@",
            "status.hasArchiveRows && !status.metricReady ? 1 : 0",
            "status.metricGateText",
            "var metricReady: Bool",
            "metricUsableRows > 0 && currentSessionUsableRows > 0",
            "if historicalArchive.metricUsableRows == 0",
            "refreshHistoricalArchiveStatus(reason: \"session_store_init\")",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "AtriaCollectionStatusCardHost(coreLiveStore: coreLiveStore,",
            "store: store)",
            "officialAppInstalled: officialAppInstalled",
            "let officialAppInstalled: Bool",
            "@ObservedObject var store: SessionStore",
            "store.refreshHistoricalArchiveStatus(reason: \"data_status_appear\")",
            "AtriaMetricTile(label: \"Backfill\"",
            "value: store.historicalArchiveStatus.valueText",
            "state: backfillState",
            "private var backfillState: AtriaMetricState",
            "if !store.historicalArchiveStatus.parseOK { return .conflict }",
            "if store.historicalArchiveStatus.metricReady { return .validated }",
            "if store.historicalArchiveStatus.hasArchiveRows { return .local }",
            "footnote: backfillFootnote",
            "private var backfillFootnote: String",
            "\"\\(store.historicalArchiveStatus.userFootnoteText) \\(store.historicalArchiveStatus.actionText)\"",
            "AtriaMetricTile(label: \"App\"",
            "value: coexistenceValue",
            "state: coexistenceState",
            "tint: coexistenceTint",
            "footnote: coexistenceFootnote",
            "AtriaCollectionCoexistenceWarning(risk: collectionLiveStore.state.officialAppCoexistenceRisk,",
            "officialAppInstalled: officialAppInstalled)",
            "return officialAppInstalled ? \"App conflict\" : \"Connection keeps dropping\"",
            "case .suspected where officialAppInstalled:",
            "return \"Remove the official strap app, then reconnect.\"",
            "return \"Forget the strap in Bluetooth, then reconnect.\"",
            "private var coexistenceValue: String",
            "case .advisory:\n            return \"Monitor\"",
            "case .suspected:\n            return \"Conflict\"",
            "private var coexistenceState: AtriaMetricState",
            "case .advisory:\n            return .local",
            "return .conflict",
            "private var coexistenceFootnote: String",
            "return \"Close the official app if drops return.\"",
            "return \"Uninstall or disable the official app before relying on Atria.\"",
        ]:
            assert_contains(self, collection, needle)

    def test_handoff_21_uniform_cards_avoid_clipping_and_nested_raised_chrome(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        shared_ui = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        connection = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        onboarding = source(ROOT / "Atria" / "Atria" / "AtriaOnboardingFlow.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        haptics = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        metric_ring = source(ROOT / "Atria" / "Atria" / "AtriaMetricRing.swift")

        for needle in [
            "struct AtriaOverviewCollectionSection: View, Equatable",
            "Label(\"Data\", systemImage: \"arrow.right.circle.fill\")",
            ".frame(minWidth: 88)",
            "AtriaInlineQuickStat(label: \"HRV window\", value: stats.rrPackageText)",
            ".frame(maxWidth: .infinity, alignment: .leading)",
            ".lineLimit(2)",
        ]:
            assert_contains(self, overview, needle)
        # 2026-07-05: local-backup detail text (`stats.backupDetail`) dropped its
        # `.lineLimit(3)` cap during the text-crop audit -- it now wraps fully via
        # `.fixedSize(horizontal: false, vertical: true)` instead of truncating a
        # long backup summary. The `.lineLimit(3)` needle above was removed
        # accordingly; every other lineLimit pin in this file still holds.

        assert_not_contains(self, overview, ".frame(maxWidth: 118)")

        for needle in [
            "private struct AtriaCollectionCoexistenceWarning: View, Equatable",
            ".atriaInsetCard(tint: tint)",
            "AtriaPanelSectionHeader(title: \"Beat-to-beat check\", subtitle: \"\")",
            "leadingTitle: \"Beat-to-beat window\"",
            "Text(\"Export beats\").frame(maxWidth: .infinity)",
            "Text(\"Import beats\").frame(maxWidth: .infinity)",
            "AtriaPanelSectionHeader(title: \"Heart-rate check\", subtitle: \"\")",
            "leadingTitle: \"Heart-rate status\"",
            "leadingDetail: \"comparison workout\"",
            "Text(\"Export heart rate\").frame(maxWidth: .infinity)",
            "Text(\"Import heart rate\").frame(maxWidth: .infinity)",
            "private struct AtriaCollectionProfilePicker: View, Equatable",
            ".atriaInsetCard(tint: .purple)",
            "private struct AtriaRecoveryStrainCard: View, Equatable",
            "recoveryStrainVisuals",
            "AtriaMetricRing(label: \"Recovery\"",
            "AtriaMetricRing(label: \"Strain\"",
            "fraction: recoveryFraction",
            "fraction: strainFraction",
            "hero.loadSignalSummaryText",
            "private var recoveryFraction: Double?",
            "Double($0) / 100",
            "private var strainFraction: Double?",
            "hero.strain / 21",
            "private struct AtriaProfileCard: View, Equatable",
            "private struct AtriaCollectionResearchSignalsCard: View, Equatable",
            "private struct AtriaCollectionIMUAuditCard: View, Equatable",
            "private struct AtriaResearchManeuverMarkerCard: View, Equatable",
            ".atriaCard(emphasis: .soft)",
        ]:
            assert_contains(self, vitals, needle)
        assert_not_contains(self, vitals, ".atriaRaisedCard(")
        assert_not_contains(self, vitals, "AtriaPanelSectionHeader(title: \"RR reference\"")
        assert_not_contains(self, vitals, "leadingTitle: \"RR window\"")
        assert_not_contains(self, vitals, "Text(\"Export RR\")")
        assert_not_contains(self, vitals, "Text(\"Import RR\")")
        assert_not_contains(self, vitals, "AtriaPanelSectionHeader(title: \"HR reference\"")
        assert_not_contains(self, vitals, "leadingTitle: \"HR status\"")
        assert_not_contains(self, vitals, "leadingDetail: \"external workout check\"")
        assert_not_contains(self, vitals, "Text(\"Export HR\")")
        assert_not_contains(self, vitals, "Text(\"Import HR\")")
        for needle in [
            "quiet partial cap while the metric is still learning",
            ".trim(from: 0.06, to: 0.22)",
            "style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)",
        ]:
            assert_contains(self, metric_ring, needle)
        assert_not_contains(self, metric_ring, "dash:")

        for needle in [
            "struct AtriaHapticAlertSettingsCard: View, Equatable",
            ".atriaInsetCard(tint: .purple)",
        ]:
            assert_contains(self, haptics, needle)
        assert_not_contains(self, haptics, ".atriaRaisedCard(")

        for needle in [
            "AtriaHapticAlertSettingsCard(settings: haptics) { next in",
            "haptics = next",
            "AtriaNotificationSettingsCard()",
            "Text(\"Phone-side alerts and on-device notifications only. Nothing leaves your phone.\")",
        ]:
            assert_contains(self, settings, needle)
        for forbidden in [
            "Toggle(\"Heart-rate zone alerts\", isOn: $haptics.heartRateZones)",
            "Toggle(\"Strain target reached\", isOn: $haptics.strainTarget)",
            "Toggle(\"Recovery is ready\", isOn: $haptics.recoveryReady)",
            "Toggle(\"Incoming calls\", isOn: $haptics.incomingCalls)",
            "Toggle(\"Low strap battery\", isOn: $haptics.lowBattery)",
        ]:
            assert_not_contains(self, settings, forbidden)

        for needle in [
            "Text(\"I’ll handle it\")\n                        .frame(maxWidth: .infinity)",
            ".atriaCardAction(tint: .orange)",
            'context.isFirstHandoff ? "Connect strap" : "Reconnect strap"',
            "AtriaConnectionStepRow(step: priorityStep)",
            "private struct AtriaConnectionStepRow: View, Equatable",
            "Text(primaryButtonTitle)",
            ".frame(maxWidth: .infinity)",
            ".background(Color.blue, in: Capsule(style: .continuous))",
            ".accessibilityLabel(\"Retry scan\")",
            "Text(\"ATRIA\")",
            "@Environment(\\.dismiss) private var dismiss",
            "ToolbarItem(placement: .topBarTrailing)",
            'Image(systemName: "xmark")',
            "dismiss()",
        ]:
            assert_contains(self, connection, needle)
        for forbidden in [
            "Text(\"Retry scan now\")",
            "What Atria handles automatically",
            "Reconnecting is automatic",
        ]:
            assert_not_contains(self, connection, forbidden)
        assert_not_contains(self, connection, ".buttonStyle(.glass")
        assert_not_contains(self, connection, ".buttonStyle(.glassProminent")

        for needle in [
            "struct AtriaMetricTile: View, Equatable",
            "static let gridSpacing: CGFloat = 12",
            "static let gridMinimumWidth: CGFloat = 142",
            "static let gridColumns = [GridItem(.adaptive(minimum: gridMinimumWidth), spacing: gridSpacing)]",
            "private static let compactHeight: CGFloat = 122",
            "private static let sparklineHeight: CGFloat = 132",
            "private static let footerHeight: CGFloat = 34",
            "private var accessibilityText: String",
            "parts.append(state.accessibilityLabel)",
            "parts.append(footnote)",
            ".accessibilityLabel(accessibilityText)",
            "private var tileHeight: CGFloat",
            "private var footer: some View",
            "maxHeight: tileHeight",
            ".frame(height: Self.footerHeight)",
            ".frame(height: Self.footerHeight, alignment: .topLeading)",
            "Color.clear",
            "struct AtriaSectionDivider: View",
            "colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)",
            ".lineLimit(2)",
            ".fixedSize(horizontal: false, vertical: true)",
            ".frame(maxWidth: .infinity, minHeight: 30)",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            ".accessibilityLabel(\"Decrease \\(title)\")",
            ".accessibilityLabel(\"Increase \\(title)\")",
        ]:
            assert_contains(self, shared_ui, needle)
        assert_not_contains(self, shared_ui, "minHeight: sparklineValues == nil ? 100 : 130")
        assert_not_contains(self, shared_ui, ".buttonStyle(.glass")
        assert_not_contains(self, shared_ui, ".fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24))")
        assert_not_contains(self, shared_ui, "struct AtriaGuidanceCard")
        assert_not_contains(self, shared_ui, "220 * CGFloat")
        assert_contains(self, vitals, "private static let statColumns = AtriaMetricTile.gridColumns")
        assert_contains(self, vitals, "LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing)")
        assert_not_contains(self, vitals, "private static let statColumns = [GridItem(.adaptive(minimum:")

        # The onboarding primary button moved out of ContentView.swift into its own
        # AtriaOnboardingFlow.swift (ac1a820f); primaryButtonTitle was renamed to
        # primaryTitle there and its tint is now conditional on step/connection status.
        assert_contains(self, onboarding, "Text(primaryTitle)")
        assert_contains(self, onboarding, ".frame(maxWidth: .infinity)")
        assert_contains(self, onboarding, ".atriaCardAction(tint: step == .strap && ble.status != .connected ? .blue : .green)")
        assert_contains(self, live_workout, ".atriaCardAction(tint: .red)")
        assert_contains(self, live_workout, "value: liveStore.state.liveActiveCaloriesText")
        assert_contains(self, live_workout, "ScrollView(showsIndicators: false)")
        assert_contains(self, live_workout, "VStack(spacing: 0)")
        assert_contains(self, live_workout, ".padding(.bottom, 12)")
        assert_contains(self, live_workout, ".safeAreaPadding(.bottom)")
        assert_contains(self, live_workout, "@Environment(\\.accessibilityReduceMotion) private var reduceMotion")
        assert_contains(self, live_workout, "private var pulsingHeartIcon: some View")
        assert_contains(self, live_workout, "if reduceMotion {")
        assert_contains(self, live_workout, "icon.symbolEffect(.pulse, options: .repeating)")
        # Live workout decongested 2026-07-06 (10 cards -> 5): workoutSourceStrip,
        # workoutTargetLane (+targetLaneChip/stripPill) and zoneFocusCard were pure
        # duplication of the zone / strain-target modules and were removed; their
        # content was folded into zoneBar + strainTargetCard, and broadcast into
        # pauseResumeCard. Pins for the removed surfaces are intentionally gone.
        assert_contains(self, live_workout, "workoutCoachCueCard(zone)")
        assert_contains(self, live_workout, "private func workoutCoachCueCard(_ zone: HRZone) -> some View")
        assert_contains(self, live_workout, "private var coachCueTitle: String")
        assert_contains(self, live_workout, "private var coachCueDetail: String")
        assert_contains(self, live_workout, "private var coachCueSymbol: String")
        assert_contains(self, live_workout, "private var coachCueTint: Color")
        assert_contains(self, live_workout, "case \"ease\": return \"Ease down\"")
        assert_contains(self, live_workout, "case \"hold\": return \"Hold here\"")
        assert_contains(self, live_workout, "default: return \"Build gently\"")
        assert_contains(self, live_workout, "Workout cue. \\(coachCueTitle). \\(coachCueDetail). Current zone")
        assert_contains(self, live_workout, "strainTargetCard")
        assert_contains(self, live_workout, "Text(\"Heart-rate zones\")")
        assert_contains(self, live_workout, "Text(\"Z\\(zone.rawValue)\")")
        assert_contains(self, live_workout, "Text(\"Z\\(z.rawValue)\")")
        assert_contains(self, live_workout, "private var strainTargetCard: some View")
        assert_contains(self, live_workout, "Label(\"Target strain\", systemImage: \"target\")")
        assert_contains(self, live_workout, "private var strainTargetValueText: String")
        assert_contains(self, live_workout, "private var strainTargetProgress: Double")
        assert_contains(self, live_workout, "private var strainTargetCue: String")
        assert_contains(self, live_workout, "private var effectiveStrainTarget: Double?")
        assert_contains(self, live_workout, "private var debugStrainTarget: Double?")
        assert_contains(self, live_workout, "arguments.contains(\"live-workout-target-build\")")
        assert_contains(self, live_workout, "arguments.contains(\"live-workout-target-hold\")")
        assert_contains(self, live_workout, "arguments.contains(\"live-workout-target-ease\")")
        assert_contains(self, live_workout, "focusPill(title: \"Now\", value: String(format: \"%.1f\", strain))")
        assert_contains(self, live_workout, "focusPill(title: \"Target\", value: strainTargetValueText)")
        assert_contains(self, live_workout, "focusPill(title: \"Cue\", value: strainTargetCue)")
        assert_contains(self, live_workout, "Target strain. Current")
        assert_contains(self, home, "strainTarget: model.heroStore.state.guidance.target")
        assert_contains(self, live_workout, "private var heartRateProgress: Double")
        assert_contains(self, live_workout, "private func zoneBandText(_ zone: HRZone) -> String")
        assert_contains(self, live_workout, "focusPill(title: \"Samples\", value: \"\\(liveStore.state.sessionSampleCount)\")")
        assert_contains(self, live_workout, "focusPill(title: \"Evidence\", value: liveStore.state.sessionSampleCount >= 900 ? \"steady\" : \"building\")")
        assert_contains(self, live_workout, "private struct AtriaWorkoutGlassSurfaceModifier: ViewModifier")
        assert_contains(self, live_workout, ".glassEffect(.regular.tint(tint.opacity(0.12)), in: shape)")
        assert_contains(self, live_workout, ".atriaWorkoutGlassSurface(cornerRadius: 20, tint: zone.color)")
        assert_contains(self, live_workout, ".atriaWorkoutGlassSurface(cornerRadius: 20, tint: Metrics.electricStrain)")
        assert_not_contains(self, live_workout, "liveStore.state.liveActiveCalories.map { \"\\($0)\" }")

    def test_live_workout_end_checkpoints_and_confirms_honestly(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private struct AtriaWorkoutEndNotice: Identifiable, Equatable",
            "@State private var workoutEndNotice: AtriaWorkoutEndNotice?",
            "onStop: { endWorkoutSession(startedAt: session.start,",
            ".alert(item: $workoutEndNotice)",
            "private func endWorkoutSession(startedAt: Date)",
            "let endedAt = Date()",
            "ble.checkpointCurrentSession(label: label,",
            "store.confirmWorkoutWindowForUI(start: startedAt,",
            "end: endedAt,",
            "source: \"live_workout_end\"",
            "store.exportToHealthKit()",
            "Workout evidence saved",
            "needs at least 10 minutes of strong heart-rate evidence",
            "ATRIADBG live_workout_end",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func checkpointCurrentSession(label: String,",
            "snapshotSession(label: label)",
            "onSessionCheckpoint?(saved) == true",
            "persistActiveSessionJournalIfNeeded(reason: \"live_workout_end_checkpoint\", force: true)",
            "source=live_workout_end mode=upsert reset_live_session=0",
        ]:
            assert_contains(self, ble, needle)

        assert_contains(self, live_workout, "Label(\"End workout\", systemImage: \"stop.fill\")")
        assert_not_contains(self, home, "onStop: { workoutSession = nil }")
        assert_not_contains(self, home, "confirmBestWorkoutCandidateForUI(rest: rest,")

        for needle in [
            "func confirmWorkoutWindowForUI(start: Date,",
            "private func confirmWorkoutWindow(start requestedStart: Date,",
            "allowManualSave: true",
            "allowManualSave: Bool = false",
            "canonicalSessions(includeActiveJournal: true).filter",
            "absoluteTime >= requestedStart",
            "SavedSession(id: UUID(),",
            "label: \"Live workout\"",
            "let readiness = window.workoutReadiness(rest: rest, maxHR: maxHR)",
            "let manualConfirmable = allowManualSave",
            "points.count >= 4",
            "readiness.observedDuration >= 60",
            "readiness.streamCoveragePercent >= 5",
            "readiness.observedDuration >= 15 * 60",
            "readiness.streamCoveragePercent >= 60",
            "readiness.ready",
            "manualConfirmable",
            "live_window_manual_confirmed",
            "let workoutSource = \"live_workout_window\"",
            "let id = confirmedWorkoutID(start: requestedStart, end: requestedEnd, source: workoutSource)",
            "zoneSeconds: enriched.zoneSeconds",
            "healthkit_source=user_confirmed",
        ]:
            assert_contains(self, sessions, needle)

    def test_live_workout_auto_detect_prompt_is_inline_and_conservative(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        catalog = source(ROOT / "Atria" / "Atria" / "AtriaExerciseCatalog.swift")

        for needle in [
            "private static let workoutPromptCooldown: TimeInterval = AtriaWorkoutPromptEvaluator.cooldown",
            "private static let workoutReviewSettleBPMOverRest = 20",
            "private static let workoutReviewDismissedIDsKey = \"atria.workoutReview.dismissedIDs\"",
            "private static let workoutReviewDismissedIDsLimit = 24",
            "fileprivate enum WorkoutReviewHoldState: Equatable",
            "case waitingForSettle(bpmOverRest: Int)",
            "case possibleSignal(reason: String)",
            "let metricDetailFixtures = [\"recovery-detail\", \"recovery-detail-nutrition\", \"hrv-detail\", \"rhr-detail\", \"respiratory-detail\", \"sleep-detail\", \"strain-detail\"]",
            "let shouldOpenMetricDetailFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { metricDetailFixtures.contains($0) } ?? false",
            "private static func debugLaunchFixtureValue(arguments: [String]) -> String?",
            "fileprivate struct AtriaWorkoutDetectionPrompt: Equatable",
            "var progressFraction: Double",
            "var evidenceMinutes: Int",
            "var reviewHint: String",
            "var isReviewReady: Bool",
            "let evaluation = AtriaWorkoutPromptEvaluator.evaluate(samples: ble.session,",
            "let looksActive = evaluation.shouldPrompt",
            "var primaryTitle: String",
            "var headline: String",
            "var subtitle: String",
            "var typeSuggestions: [String]",
            "var exerciseSuggestions: [String]",
            "var suggestedActivityType: AtriaWorkoutActivityType",
            "var suggestedActivityTypes: [AtriaWorkoutActivityType]",
            "AtriaWorkoutActivityType(suggestion: suggestion)",
            "return Array(resolved.prefix(3))",
            "return .walking",
            "return .cardio",
            "return .mobility",
            "[\"Strength\", \"Cardio\", \"Mixed\"]",
            "[\"Chest\", \"Triceps\", \"Abs\"]",
            "fileprivate struct AtriaWorkoutReviewDraft: Identifiable, Equatable",
            "fileprivate struct AtriaWorkoutReviewResult: Equatable",
            "fileprivate enum AtriaWorkoutReviewStep: Int, CaseIterable",
            "@State private var workoutDetectionPrompt: AtriaWorkoutDetectionPrompt?",
            "@State private var workoutPromptDismissedUntil: Date?",
            "@State private var workoutReviewDraft: AtriaWorkoutReviewDraft?",
            "@State private var savedWorkoutReviewCandidate: WorkoutReviewCandidate?",
            "@State private var workoutReviewHoldState: WorkoutReviewHoldState?",
            "debugWorkoutDetectionPrompt ?? workoutDetectionPrompt",
            "AtriaWorkoutDetectionBanner(prompt: prompt)",
            "AtriaSavedWorkoutReviewBanner(candidate: candidate,",
            "private var workoutReviewHoldStateForDisplay: WorkoutReviewHoldState?",
            "if let debugWorkoutReviewHoldState {",
            "return nil",
            "if let holdState = workoutReviewHoldStateForDisplay",
            "AtriaWorkoutReviewHoldBanner(state: holdState)",
            ".sheet(item: $workoutReviewDraft)",
            "AtriaWorkoutReviewFlow(draft: draft)",
            "saveWorkoutReview(result)",
            "workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)",
            "presentWorkoutReview(prompt: prompt)",
            "updateWorkoutDetectionPrompt()",
            "private func updateWorkoutDetectionPrompt(now: Date = Date())",
            "private func presentWorkoutReview(prompt: AtriaWorkoutDetectionPrompt",
            "private func presentWorkoutReview(candidate: WorkoutReviewCandidate)",
            "private func refreshSavedWorkoutReviewCandidate(reason: String)",
            "private func rememberDismissedWorkoutReviewCandidate(_ candidate: WorkoutReviewCandidate)",
            "private func dismissedWorkoutReviewCandidateIDs() -> [String]",
            "private func workoutReviewCandidateWasDismissed(_ candidate: WorkoutReviewCandidate) -> Bool",
            "ids = Array(ids.prefix(Self.workoutReviewDismissedIDsLimit))",
            "UserDefaults.standard.set(ids, forKey: Self.workoutReviewDismissedIDsKey)",
            "reason=user_marked_not_workout",
            "private func saveWorkoutReview(_ result: AtriaWorkoutReviewResult)",
            "source: \"guided_workout_review\"",
            "activityType: result.activityType",
            "exerciseNames: result.exerciseNames",
            "reviewSource: \"guided_workout_review\"",
            "guard debugWorkoutDetectionPrompt == nil else",
            "guard selectedTab == .overview else { return }",
            "guard workoutSession == nil else {",
            "guard model.coreLiveStore.state.status == .connected else {",
            "let bpmOverRest = max(0, heartRate - rest)",
            "AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: workoutPromptDismissedUntil, now: now)",
            "let liveBPMOverRest = max(0, model.pulseLiveStore.state.heartRate - rest)",
            "liveBPMOverRest > Self.workoutReviewSettleBPMOverRest",
            "workoutReviewHoldState = .waitingForSettle(bpmOverRest: liveBPMOverRest)",
            "if let candidate, !candidate.isReviewPromptWorthy",
            "workoutReviewHoldState = .possibleSignal(reason: candidate.reason)",
            "let restingHeartRate: Int",
            "let maxHeartRate: Int",
            "var heartRateZone: Metrics.HeartRateZone?",
            "Metrics.heartRateZone(bpm: heartRate, rest: restingHeartRate, max: maxHeartRate)",
            "restingHeartRate: rest",
            "maxHeartRate: store.profile.maxHR",
            "private var debugWorkoutDetectionPrompt: AtriaWorkoutDetectionPrompt?",
            "private var debugSavedWorkoutReviewCandidate: WorkoutReviewCandidate?",
            "private var debugWorkoutReviewHoldState: WorkoutReviewHoldState?",
            'arguments[valueIndex] == "saved-workout-review"',
            'arguments[valueIndex] == "workout-detection"',
            'arguments[valueIndex] == "workout-detection-ready"',
            '"workout-review-hold-settle"',
            '"workout-review-hold-possible"',
            'arguments[valueIndex] == "workout-review-flow"',
            "AtriaWorkoutDetectionPrompt(heartRate: 142,",
            "private struct AtriaWorkoutDetectionBanner: View, Equatable",
            "private struct AtriaSavedWorkoutReviewBanner: View, Equatable",
            "private struct AtriaWorkoutReviewHoldBanner: View, Equatable",
            "private struct AtriaWorkoutZoneEvidenceStrip: View, Equatable",
            "private struct AtriaWorkoutReviewFlow: View",
            "_selectedType = State(initialValue: draft.prompt.suggestedActivityType)",
            "_selectedSubtype = State(initialValue: suggestedType.subtypeOptions.first)",
            "_step = State(initialValue: Self.debugInitialStep(arguments: ProcessInfo.processInfo.arguments))",
            "@State private var showsAllWorkoutTypes = false",
            "private var visibleWorkoutTypes: [AtriaWorkoutActivityType]",
            "guard !showsAllWorkoutTypes else { return AtriaWorkoutActivityType.allCases }",
            "var types = draft.prompt.suggestedActivityTypes",
            "if !types.contains(selectedType)",
            "private var hiddenWorkoutTypeCount: Int",
            "private static func debugInitialStep(arguments: [String]) -> AtriaWorkoutReviewStep",
            "arguments.contains(\"--atria-workout-review-type-step\")",
            "arguments.contains(\"--atria-workout-review-exercises-step\")",
            "arguments.contains(\"--atria-workout-review-summary-step\")",
            "case time",
            "case type",
            "case exercises",
            "case summary",
            "Text(\"Workout found\")",
            "Check time, type, then save.",
            "workoutReceiptBoard",
            "private var workoutReceiptBoard: some View",
            "workoutReceiptTile(title: \"Time\"",
            "workoutReceiptTile(title: \"Peak\"",
            "workoutReceiptTile(title: \"Type\"",
            "Workout receipt. Time \\(durationText). Peak \\(draft.prompt.heartRate). Type \\(selectedType.rawValue).",
            "private func workoutReceiptTile(title: String,",
            "private var reviewDecisionLens: some View",
            "reviewDecisionMetric(title: \"Confirm\"",
            "reviewDecisionMetric(title: \"Adjust\"",
            "reviewDecisionMetric(title: \"Dismiss\"",
            "value: \"Not workout\"",
            "Workout review choices. Confirm type, adjust time, or dismiss.",
            "stepTitle(\"Confirm time\"",
            "Move start or end only if needed.",
            "stepTitle(\"What type was it?\"",
            "Pick what you want saved.",
            "private var suggestedTypeRunway: some View",
            "Label(\"Suggested from strap HR\", systemImage: \"figure.strengthtraining.traditional\")",
            "ForEach(draft.prompt.suggestedActivityTypes)",
            "applyWorkoutType(type)",
            "Suggested activity \\(type.rawValue).",
            "private var selectedTypeLens: some View",
            "Label(\"Selected type\", systemImage: selectedType.icon)",
            "Text(selectedType.rawValue)",
            "selectedType.supportsExerciseSelection ? \"Exercises next\" : \"No exercise step\"",
            "typeRevealHeader",
            "ForEach(visibleWorkoutTypes)",
            "private var typeRevealHeader: some View",
            "Best matches first",
            "All activity types",
            "showsAllWorkoutTypes.toggle()",
            "Text(showsAllWorkoutTypes ? \"Less\" : \"+\\(hiddenWorkoutTypeCount)\")",
            ".accessibilityLabel(showsAllWorkoutTypes ? \"Show fewer workout types\" : \"Show \\(hiddenWorkoutTypeCount) more workout types\")",
            "stepTitle(\"Add exercises\"",
            "private var stepContextRail: some View",
            "private func stepContextChip(title: String,",
            "stepContextChip(title: \"Now\"",
            "stepContextChip(title: \"Next\"",
            "private var currentStepIndex: Int",
            "private var nextStepTitle: String",
            "private var stepContextAccessibilityText: String",
            "Now \\(step.title), step \\(currentStepIndex) of \\(visibleSteps.count). Next \\(nextStepTitle).",
            "selectedType.supportsExerciseSelection ? \"Moves next\" : \"Type only\"",
            "private var exerciseQuickAddStrip: some View",
            "Label(\"Likely moves\", systemImage: \"plus.circle.fill\")",
            "selectedSuggestedExerciseCount",
            "exerciseSearchPrompt",
            "private var exerciseSearchPrompt: some View",
            "Search only if needed",
            "Skip exercises if you are unsure.",
            "private func quickExerciseButton(_ exercise: String) -> some View",
            "toggleExercise(exercise)",
            "private var selectedSuggestedExerciseCount: Int",
            "private func toggleExercise(_ exercise: String)",
            "stepTitle(\"Save to Atria\", subtitle: \"Check what gets remembered.\")",
            "private var summaryReceiptLens: some View",
            "Text(selectedType.rawValue)",
            "Text(durationText)",
            ".trim(from: 0, to: min(max(draft.prompt.progressFraction, 0.12), 1))",
            "summaryReceiptMetric(title: \"Time\"",
            "detail: summaryTimeRangeText",
            "summaryReceiptMetric(title: \"Type\"",
            "summaryReceiptMetric(title: \"Moves\"",
            "summaryMemoryRail",
            "summaryMemoryNode(title: \"Save\"",
            "summaryMemoryNode(title: \"History\"",
            "summaryMemoryNode(title: \"Remember\"",
            "remembers the selected label",
            "private var summaryTimeRangeText: String",
            "if let zone = draft.prompt.heartRateZone",
            "AtriaWorkoutZoneEvidenceStrip(zone: zone)",
            "Strap HR peak \\(heartRate) beats per minute",
            "private var captureEvidenceStrip: some View",
            "Label(\"What Atria saw\", systemImage: \"waveform.path.ecg\")",
            "captureTile(title: \"Time seen\"",
            "captureTile(title: \"Signal\"",
            "captureTile(title: \"Next\"",
            "What Atria saw. \\(draft.prompt.evidenceMinutes) minutes of strap heart rate. Signal \\(draft.prompt.confidenceLabel). Next",
            "Label(\"Movements saved locally\", systemImage: \"checkmark.seal.fill\")",
            "Save to history and learn from this label.",
            "Workout save receipt. Window",
            "TextField(\"Search exercises\", text: $exerciseSearch)",
            "exerciseQuickAddStrip",
            "exerciseCatalogPreview",
            "private var exerciseCatalogPreview: some View",
            "private var exerciseQuery: String",
            "private var shouldOfferCustomExercise: Bool",
            "AtriaWorkoutExerciseCatalog.allGroups()",
            "shouldOfferCustomExercise",
            "addCustomExerciseButton(exerciseQuery)",
            "private func addCustomExerciseButton(_ exercise: String) -> some View",
            "AtriaWorkoutExerciseCatalog.addCustomExercise(exercise)",
            "selectedExercises.insert(exercise)",
            "exerciseSearch = \"\"",
            "Save as a custom exercise",
            ".accessibilityLabel(\"Add custom exercise \\(exercise)\")",
            "Search full catalog",
            "Search full exercise catalog.",
            "if exerciseQuery.isEmpty",
            "} else {\n                ForEach(AtriaWorkoutExerciseCatalog.filteredGroups(search: exerciseSearch))",
            "private var promptExerciseSuggestions: [String]",
            "AtriaWorkoutExerciseCatalog.suggestedExercises(for: suggestion)",
            "Button(primaryActionTitle)",
            "private func applyWorkoutType(_ type: AtriaWorkoutActivityType)",
            "selectedExercises.removeAll()",
            "step == .summary ? \"Save workout\" : \"Continue\"",
            "VStack(spacing: 0)",
            ".padding(.bottom, 28)",
            ".atriaInsetCard(cornerRadius: 28, tint: .orange)",
            "Text(prompt.headline)",
            "Text(prompt.subtitle)",
            "Text(\"Strap HR\")",
            ".trim(from: 0, to: prompt.progressFraction)",
            "private var workoutEvidenceRail: some View",
            "ForEach(0..<6, id: \\.self)",
            "Text(zone.title)",
            "Text(zone.name)",
            "headerChip(zone.shortLabel, tint: zone.tint)",
            "private var workoutDecisionStrip: some View",
            "decisionChip(title: \"Signal\"",
            "decisionChip(title: \"Time\"",
            "decisionChip(title: \"Next\"",
            "value: prompt.isReviewReady ? \"Review\" : \"Watching\"",
            "Workout review. Strap signal \\(prompt.confidenceLabel), \\(prompt.evidenceMinutes) minutes seen, \\(prompt.reviewHint).",
            "let hrProgress = min(max(Double(prompt.bpmOverRest) / 80.0, 0), 1)",
            "let strainProgress = min(max(prompt.strain / 12.0, 0), 1)",
            "Label(\"Strap HR\", systemImage: \"waveform.path.ecg\")",
            "Text(prompt.primaryTitle)",
            ".disabled(!prompt.isReviewReady)",
            "Text(\"Not now\")",
            "Text(\"Confirm type\")",
            "Text(\"Dismiss\")",
            "Atria is waiting for a steadier strap rise.",
            "private var savedWorkoutDecisionStrip: some View",
            # Decluttered 2026-07-07: the three fake-button decisionStep tiles
            # became one non-button row surfacing strap-signal quality + the next
            # action. reviewPathStrip (below) is a separate strip and unchanged.
            "Text(\"Strap signal: \\(signalReviewTitle)\")",
            "Text(\"Confirm the type to save\")",
            "private var reviewPathStrip: some View",
            "pathStep(\"1\", \"Window\", tint: .cyan)",
            "pathStep(\"2\", \"Type\", tint: .orange)",
            "pathStep(\"3\", \"Exercises\", tint: .mint)",
            "Workout review path: adjust window, choose type, add exercises.",
            "private var savedWorkoutEvidenceRail: some View",
            "Text(\"Workout window\")",
            "let peakProgress = heartRateProgress(candidate.peakHR)",
            "let averageProgress = heartRateProgress(candidate.avgHR)",
            "candidate.streamCoveragePercent",
            "Check time",
            "private func heartRateProgress(_ bpm: Int) -> Double",
            "Still watching effort",
            "Possible effort saved",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "enum AtriaWorkoutActivityType: String, CaseIterable, Identifiable",
            "init?(suggestion: String)",
            "case \"mixed\": self = .functionalFitness",
            "struct AtriaWorkoutExerciseGroup: Identifiable, Equatable",
            "enum AtriaWorkoutExerciseCatalog",
            "static let groups: [AtriaWorkoutExerciseGroup]",
            "\"Powerlifting\"",
            "\"Pickleball\"",
            "\"Jiu jitsu\"",
            "\"Incline walk\"",
            "\"Cross training\"",
            "AtriaWorkoutExerciseGroup(title: \"Chest\"",
            "\"Barbell bench press\"",
            "AtriaWorkoutExerciseGroup(title: \"Triceps\"",
            "\"Cable pushdown\"",
            "AtriaWorkoutExerciseGroup(title: \"HIIT\"",
            "\"Assault bike interval\"",
            "AtriaWorkoutExerciseGroup(title: \"Functional\"",
            "\"Turkish get-up\"",
            "AtriaWorkoutExerciseGroup(title: \"Bodyweight\"",
            "\"Handstand push-up\"",
            "AtriaWorkoutExerciseGroup(title: \"Cardio\"",
            "\"Incline walk\"",
            "AtriaWorkoutExerciseGroup(title: \"Mobility\"",
            "\"World's greatest stretch\"",
            "static func customExercises(userDefaults: UserDefaults = .standard) -> [String]",
            "AtriaStrengthLog.customExercisesKey",
            "static func addCustomExercise(_ exercise: String, userDefaults: UserDefaults = .standard)",
            "AtriaWorkoutExerciseGroup(title: \"My exercises\", exercises: custom)",
            "static func filteredGroups(search: String, userDefaults: UserDefaults = .standard) -> [AtriaWorkoutExerciseGroup]",
            "static func suggestedExercises(for signal: String) -> [String]",
        ]:
            assert_contains(self, catalog, needle)

        assert_not_contains(self, home, "fileprivate enum AtriaWorkoutActivityType")
        assert_not_contains(self, home, "fileprivate enum AtriaWorkoutExerciseCatalog")
        assert_not_contains(self, home, "fileprivate struct AtriaWorkoutExerciseGroup")

        assert_not_contains(self, home, ".alert(item: $workoutDetectionPrompt)")
        assert_not_contains(self, home, "Text(\"Workout detected?\")")
        assert_not_contains(self, home, "Text(\"Start workout\")")
        assert_not_contains(self, home, "Text(\"Track live\")")
        assert_not_contains(self, home, "Text(\"Review later\")")
        assert_not_contains(self, home, "Confirm what happened, then Atria learns.")
        assert_not_contains(self, home, "Text(\"Choose everything\")")
        assert_not_contains(self, home, "Choose the label you would expect to see in your activity history.")
        assert_not_contains(self, home, "Label(\"Capture check\", systemImage: \"waveform.path.ecg\")")
        assert_not_contains(self, home, "Label(\"Review check\", systemImage: \"waveform.path.ecg\")")
        assert_not_contains(self, home, "captureTile(title: \"Capture\"")
        assert_not_contains(self, home, "selectedType.supportsExerciseSelection ? \"Guided\" : \"Label only\"")
        assert_not_contains(self, home, "Exercises next\" : \"Label only\"")
        assert_not_contains(self, home, "captureTile(title: \"Obs\"")
        assert_not_contains(self, home, "evidence only")
        assert_not_contains(self, home, "Workout capture check.")
        assert_not_contains(self, home, "Strap signal peak 0")
        assert_not_contains(self, home, "Atria is seeing sustained effort, not just a quick spike.")
        assert_not_contains(self, home, "If this is a real workout, start tracking now.")
        assert_not_contains(self, home, "Atria is waiting for stronger strap evidence.")
        assert_not_contains(self, home, "High confidence")
        assert_not_contains(self, home, "minutes observed")
        assert_not_contains(self, home, "private var workoutReviewChoices: some View")
        assert_not_contains(self, home, "private var workoutReviewPathStrip: some View")
        assert_not_contains(self, home, "private var watchingSignalStrip: some View")
        assert_not_contains(self, home, "private func detectionPill(")
        assert_not_contains(self, home, "private var savedWorkoutCaptureQualityStrip: some View")
        assert_not_contains(self, home, "private var workoutInterpretationStrip: some View")
        assert_not_contains(self, home, "private var settledDecisionStrip: some View")
        assert_not_contains(self, home, "Text(\"Likely labels\")")
        assert_not_contains(self, home, "workoutReceiptTile(title: \"Likely\"")
        assert_not_contains(self, home, "Likely type")
        assert_not_contains(self, home, "captureMetric(title:")
        assert_not_contains(self, home, "Full catalog waits behind search")
        assert_not_contains(self, home, "Full exercise catalog waits behind search.")
        assert_not_contains(self, home, "summaryMemoryNode(title: \"Learn\"")
        assert_not_contains(self, home, "learns from the selected label")
        saved_banner_start = home.index("private struct AtriaSavedWorkoutReviewBanner")
        saved_banner_end = home.index("private struct AtriaWorkoutReviewHoldBanner", saved_banner_start)
        saved_banner_source = home[saved_banner_start:saved_banner_end]
        assert_not_contains(self, saved_banner_source, "captureQualityTitle")
        assert_not_contains(self, saved_banner_source, "captureQualityTint")
        assert_not_contains(self, saved_banner_source, "captureQualityIcon")
        assert_not_contains(self, saved_banner_source, "Capture \\(candidate.streamCoveragePercent) percent")
        assert_not_contains(self, saved_banner_source, "missingMinutes) minutes missing")
        assert_not_contains(self, saved_banner_source, "title: \"Capture\"")
        assert_not_contains(self, saved_banner_source, "title: \"Decide\"")
        assert_not_contains(self, saved_banner_source, "title: \"Signal\"")
        assert_not_contains(self, saved_banner_source, "title: \"Learn\"")
        assert_not_contains(self, saved_banner_source, "Atria learns for next time")
        assert_not_contains(self, saved_banner_source, "Text(\"Not a workout\")")
        assert_not_contains(self, saved_banner_source, "Text(\"Detected window\")")
        assert_not_contains(self, saved_banner_source, "Detected window \\(timeRangeText)")
        assert_not_contains(self, saved_banner_source, "Strap capture \\(signalReviewTitle)")
        assert_not_contains(self, saved_banner_source, "strap capture \\(signalReviewTitle)")
        assert_not_contains(self, saved_banner_source, 'return "Enough"')
        assert_not_contains(self, saved_banner_source, 'return "Check"')
        assert_not_contains(self, saved_banner_source, 'return "Patchy"')
        assert_not_contains(self, saved_banner_source, 'Text("Review & label")')
        assert_not_contains(self, saved_banner_source, 'value: "After label"')
        assert_not_contains(self, saved_banner_source, "save after labeling")
        assert_contains(self, saved_banner_source, 'Text("Confirm type")')
        assert_contains(self, saved_banner_source, "Confirm type before saving.")
        banner_start = home.index("private struct AtriaWorkoutDetectionBanner")
        banner_end = home.index("private struct AtriaSavedWorkoutReviewBanner", banner_start)
        banner_source = home[banner_start:banner_end]
        assert_not_contains(self, banner_source, "AtriaStateBadge")
        assert_not_contains(self, banner_source, "Strap signal peak")
        assert_not_contains(self, banner_source, "Workout signal held")
        assert_not_contains(self, banner_source, "until signal improves")
        assert_not_contains(self, banner_source, "because the signal is possible effort")
        assert_not_contains(self, banner_source, "decisionChip(title: \"Capture\"")
        assert_not_contains(self, banner_source, "captureTile(title: \"Signal\"")
        assert_not_contains(self, banner_source, "Suggested from strap signal")
        assert_not_contains(self, banner_source, "Signal \\(draft.prompt.confidenceLabel)")
        footer_start = home.index("private var footer: some View")
        footer_end = home.index("private var primaryActionTitle", footer_start)
        footer_source = home[footer_start:footer_end]
        assert_not_contains(self, footer_source, ".atriaCard(")
        time_step_start = home.index("private var timeStep: some View")
        time_step_end = home.index("private var typeStep: some View", time_step_start)
        time_step_source = home[time_step_start:time_step_end]
        assert_contains(self, time_step_source, "captureEvidenceStrip")
        self.assertLess(time_step_source.index("captureEvidenceStrip"),
                        time_step_source.index("DatePicker(\"Start\""),
                        "Workout evidence should be visible before time controls.")
        assert_not_contains(self, time_step_source, "reviewMetricRow([(\"Window\", durationText)")
        step_indicator_start = home.index("private var stepIndicator: some View")
        step_indicator_end = home.index("private var stepSubtitle: String", step_indicator_start)
        step_indicator_source = home[step_indicator_start:step_indicator_end]
        assert_not_contains(self, step_indicator_source, "stepContextRail")
        assert_not_contains(self, home, "private var typeReviewRoute: some View")
        assert_not_contains(self, home, "private func typeRouteNode(")
        assert_not_contains(self, home, "private func typeRouteConnector(")
        type_step_start = home.index("private var typeStep: some View")
        type_step_end = home.index("private var suggestedTypeRunway", type_step_start)
        type_step_source = home[type_step_start:type_step_end]
        assert_not_contains(self, type_step_source, "typeReviewRoute")
        overview_start = home.index("private var overviewContent: some View")
        overview_end = home.index("private var connectionDiagnosis:", overview_start)
        overview_source = home[overview_start:overview_end]
        self.assertLess(overview_source.index("AtriaSavedWorkoutReviewBanner(candidate: candidate,"),
                        overview_source.index("AtriaTodayScreen("),
                        "Saved workout review should appear before the rebuilt Today surface once it passes the stricter review-worthy gate.")
        assert_contains(self, overview_source, "suppressSleepSyncPrompt: hasPrimaryReviewAction")
        self.assertLess(overview_source.index("AtriaTodayScreen("),
                        overview_source.index("if !debugShowsNorthStarTodayFixture"),
                        "Review flows and the rebuilt Today surface should lead before lower-priority system banners.")
        assert_contains(self, home, "private var overviewSystemBanners: some View")
        assert_contains(self, home, "private var hasPrimaryReviewAction: Bool")
        assert_contains(self, home, "private var shouldLeadWithSystemBanners: Bool")
        assert_contains(self, home, "!hasPrimaryReviewAction && activeOverviewSegment == .today")
        assert_contains(self, home, "private var hasWorkoutReviewAction: Bool")
        assert_contains(self, home, "private var hasPendingSleepReviewAction: Bool")
        assert_contains(self, home, "store.latestSleepReviewNightForUI(rest: store.baseline.restingInt ?? 60,")
        assert_contains(self, home, 'Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "pending-sleep-review"')

    def test_confirmed_workouts_persist_rich_metrics_and_active_energy(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "var strain: Double? = nil",
            "var activeEnergyKilocalories: Double? = nil",
            "var activeEnergyConfidence: String? = nil",
            "var zoneSeconds: [String: TimeInterval]? = nil",
            "var activityType: String? = nil",
            "var activitySubtype: String? = nil",
            "var exerciseNames: [String]? = nil",
            "var reviewSource: String? = nil",
            "struct WorkoutReviewCandidate: Equatable",
            "var isReviewPromptWorthy: Bool",
            "kind == .workout || confidence != .low",
            "func latestWorkoutReviewCandidate(rest: Int,",
            "now: Date = Date()",
            "private static let workoutReviewSettleDelay: TimeInterval = 10 * 60",
            "let secondsSinceEnd = now.timeIntervalSince(end)",
            "secondsSinceEnd >= Self.workoutReviewSettleDelay",
            "status=settling",
            "var reviewWorthyCandidate: Bool",
            "var bestReviewWorthyCandidate: Bool",
            "private static let reviewMinimumObservedDuration: TimeInterval = 15 * 60",
            "private static let reviewMinimumCoveragePercent = 40",
            "private static let reviewMinimumPeakOverRest = 45",
            "private static let reviewMinimumP95OverRest = 35",
            "private static let reviewMinimumModerateStrengthPeakOverRest = 35",
            "private static let reviewMinimumModerateStrengthP95OverRest = 30",
            "private static let reviewMinimumElevatedSeconds: TimeInterval = 4 * 60",
            "private static let reviewMinimumElevatedBout: TimeInterval = 90",
            "private static let reviewMinimumBorderlineSeconds: TimeInterval = 5 * 60",
            "private static let reviewMinimumBorderlineBout: TimeInterval = 90",
            "var moderateStrengthReviewCandidate: Bool",
            "observedDuration >= Self.reviewMinimumObservedDuration",
            "bestObservedDuration >= Self.reviewMinimumObservedDuration",
            "streamCoveragePercent >= Self.reviewMinimumCoveragePercent",
            "bestStreamCoveragePercent >= Self.reviewMinimumCoveragePercent",
            "peakOverRest >= Self.reviewMinimumPeakOverRest",
            "bestPeakHR - restHR >= Self.reviewMinimumPeakOverRest",
            "p95HR - max(0, peakHR - peakOverRest) >= Self.reviewMinimumP95OverRest",
            "bestP95HR - restHR >= Self.reviewMinimumP95OverRest",
            "peakOverRest >= Self.reviewMinimumModerateStrengthPeakOverRest",
            "bestPeakHR - restHR >= Self.reviewMinimumModerateStrengthPeakOverRest",
            "p95OverRest >= Self.reviewMinimumModerateStrengthP95OverRest",
            "bestP95HR - restHR >= Self.reviewMinimumModerateStrengthP95OverRest",
            # 2026-07-05: contact-artifact hardening (Sessions.swift WorkoutReadiness)
            # gates reviewWorthyCandidate/bestReviewWorthyCandidate's near-miss branch
            # on contact/RR-qualified evidence instead of the raw elevated seconds, so
            # a loose-contact blip alone can't promote a candidate.
            "contactQualifiedElevatedSeconds >= Self.reviewMinimumElevatedSeconds",
            "bestContactQualifiedElevatedSeconds >= Self.reviewMinimumElevatedSeconds",
            "contactQualifiedLongestBout >= Self.reviewMinimumElevatedBout",
            "bestContactQualifiedLongestBout >= Self.reviewMinimumElevatedBout",
            "borderlineElevatedSeconds >= Self.reviewMinimumBorderlineSeconds",
            "bestBorderlineElevatedSeconds >= Self.reviewMinimumBorderlineSeconds",
            "borderlineLongestBout >= Self.reviewMinimumBorderlineBout",
            "bestBorderlineLongestBout >= Self.reviewMinimumBorderlineBout",
            "moderate_strength_review",
            "if moderateStrengthReviewCandidate",
            "kind == .workout || confidence != .low || observedDuration >= 15 * 60",
            "let reviewConfidence: ActivityDetection.Confidence = summary.readySessions > 0",
            "summary.readySessions > 0 || summary.bestReviewWorthyCandidate",
            "reason=candidate_not_review_worthy",
            ".filter { $0.readiness.ready || $0.readiness.reviewWorthyCandidate }",
            "workoutOverlapRatio(workout: workout, start: start, end: end) >= 0.70",
            "activityType: String? = nil",
            "activitySubtype: String? = nil",
            "exerciseNames: [String] = []",
            "reviewSource: String? = nil",
            "cleanedActivityType",
            "cleanedExercises.isEmpty ? nil : cleanedExercises",
            "label: cleanedActivityType ?? \"Live workout\"",
            "let enriched = confirmedWorkoutMetrics(start: bestStart,",
            "strain: enriched.strain",
            "activeEnergyKilocalories: enriched.activeEnergyKilocalories",
            "activeEnergyConfidence: enriched.activeEnergyConfidence",
            "zoneSeconds: enriched.zoneSeconds",
            "private func confirmedWorkoutMetrics(start: Date,",
            "Metrics.activeCalories(samples, rest: rest, profile: profile)",
            "Metrics.strain(fromTRIMP: trimp)",
            "AtriaAnalytics.Strain.maxHeartRateZoneSeconds(samples.map",
            "zoneSummary.isEmpty ? nil : zoneSummary.storage",
            "active_energy_kcal=%.0f",
            "zone_rest_s=%.0f",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "snapshot?.activeEnergyExported != true",
            "(workout.activeEnergyKilocalories ?? 0) > 0",
            "samples.append(contentsOf: confirmedWorkouts.compactMap { workout in",
            "return confirmedWorkoutActiveEnergySample(for: workout)",
            "metadata[\"atria_workout_strain\"] = strain",
            "metadata[\"atria_workout_activity_type\"] = activityType",
            "metadata[\"atria_workout_activity_subtype\"] = activitySubtype",
            "metadata[\"atria_workout_exercises\"] = exerciseNames.joined(separator: \", \")",
            "metadata[\"atria_workout_review_source\"] = reviewSource",
            "metadata[\"atria_workout_active_energy_kcal\"] = activeEnergy",
            "metadata[\"atria_workout_active_energy_confidence\"] = workout.activeEnergyConfidence ?? \"estimate\"",
            "metadata[\"atria_workout_zone_\\(zone)_seconds\"] = seconds",
            "return WorkoutExportPlan(activityType: healthKitActivityType(for: workout),",
            "private func healthKitActivityType(for workout: UserConfirmedWorkout) -> HKWorkoutActivityType",
            "case \"running\":",
            "return .running",
            "case \"cycling\":",
            "return .cycling",
            "case \"hiit\":",
            "return .highIntensityIntervalTraining",
            "private func confirmedWorkoutActiveEnergySample(for workout: UserConfirmedWorkout) -> HKQuantitySample?",
            "HKQuantity(unit: .kilocalorie(), doubleValue: kilocalories)",
            "\"atria_metric_source\": \"keytel_hr_energy_estimate\"",
        ]:
            assert_contains(self, healthkit, needle)

        pull = source(ROOT / "pull_atria_state.sh")
        for needle in [
            "confirmed_workout_summary_status=ok",
            "confirmed_workouts_count=",
            "latest_confirmed_workout_id=",
            "latest_confirmed_workout_review_source=",
            "daily_rollups_today_activity_candidates=",
            "daily_rollups_today_workouts=",
            "daily_rollups_today_confirmed_workouts=",
            "daily_rollups_activity_candidate_days=",
        ]:
            assert_contains(self, pull, needle)

    def test_session_detail_downsamples_once_for_render_perf(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        insights = source(ROOT / "Atria" / "Atria" / "Insights.swift")

        for needle in [
            "struct SessionDetail: View",
            "private let displayedPoints: [SavedSession.Point]",
            "private let summary: SessionDetailSummary",
            "init(session: SavedSession)",
            "self.displayedPoints = Self.downsampledPoints(session.points)",
            "self.summary = SessionDetailSummary(session: session, maxHR: AthleteProfile.load().maxHR)",
            "private static func downsampledPoints",
            "Chart(Array(displayedPoints.enumerated()), id: \\.offset)",
            "private struct SessionDetailSummary",
            "let zoneRows: [TimeInZoneRow]",
            "let zoneTotal: Double",
            "TimeInZoneView(rows: summary.zoneRows, total: summary.zoneTotal)",
        ]:
            assert_contains(self, sessions, needle)

        for forbidden in [
            "private var displayedPoints: [SavedSession.Point] {\n        downsampledPoints(session.points)",
            "private var maxHR: Int { AthleteProfile.load().maxHR }",
            "Metrics.strain(fromTRIMP: session.trimp(rest: session.restingStable, max: maxHR))",
            "TimeInZoneView(session: session, maxHR: maxHR)",
        ]:
            assert_not_contains(self, sessions, forbidden)

        for needle in [
            "struct TimeInZoneRow: Identifiable",
            "let rows: [TimeInZoneRow]",
            "let total: Double",
            "ForEach(rows) { row in",
        ]:
            assert_contains(self, insights, needle)

        time_in_zone = re.search(
            r"struct TimeInZoneView: View \{(?P<body>.*?)\n\}",
            insights,
            re.S,
        )
        self.assertIsNotNone(time_in_zone)
        time_in_zone_body = time_in_zone.group("body")
        for forbidden in [
            "let session: SavedSession",
            "let maxHR: Int",
            "session.timeInZone",
            ".sorted",
            ".reduce",
        ]:
            assert_not_contains(self, time_in_zone_body, forbidden)

    def test_swiftui_render_blocks_do_not_run_session_derivations(self):
        forbidden = [
            ".sorted(",
            ".sorted {",
            ".reduce(",
            ".compactMap(",
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
            "aggregateSleepDiagnostics(",
            "aggregateWorkoutCandidates(",
            "canonicalSessions(",
            "replaySavedWorkoutReadiness(",
            "makeHistorySnapshots(",
            "makeDeferredDetails(",
            "makeBehaviorCorrelationSummaries(",
            "behaviorCorrelationSummaries(",
            "logDeepDailyRollupDiagnostics(",
            "session.trimp(",
            "timeInZone(",
            "AthleteProfile.load()",
        ]
        checked = 0
        for rel in swift_files():
            for start, body in swift_some_view_blocks(source(rel)):
                checked += 1
                for needle in forbidden:
                    self.assertNotIn(needle, body, f"{rel}:{start} keeps {needle} in a some View render block")
        self.assertGreater(checked, 160)

        checks = source(ROOT / "test_handoff_static_checks.py")
        assert_contains(self, checks, "def swift_some_view_blocks(text):")
        assert_contains(self, checks, "for rel in swift_files():")
        assert_contains(self, checks, '".sorted {"')

        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        for removed_legacy_token in [
            "private struct DailyEvidenceCard",
            "private struct CollectionReliabilityCard",
            "ATRIADBG daily_evidence_ui",
            "ATRIADBG collection_reliability_ui",
            "detectedActivity(",
        ]:
            assert_not_contains(self, content, removed_legacy_token)

    def test_history_snapshot_is_cached_off_navigation_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "@Published private(set) var historySnapshot = HistorySnapshot.empty",
            "@Published private(set) var sleepHistorySnapshot = SleepHistorySnapshot.empty",
            "private var historySnapshotRevision = 0",
            "private func refreshHistorySnapshotCache(deferred: Bool = true)",
            "let sourceSessions = sessions",
            "historySnapshot = HistorySnapshot.sessionsOnly(sourceSessions, maxHR: maxHR)",
            "DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.12)",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "private func publishFullHistorySnapshotIfCurrent(revision: Int,\n                                                     history: HistorySnapshot,\n                                                     sleep: SleepHistorySnapshot)",
            "historySnapshot = history",
            "sleepHistorySnapshot = sleep",
            "private nonisolated static func makeHistorySnapshots(sessions: [SavedSession],",
            "private nonisolated static func makeHistoryDailyRollups(sessions: [SavedSession],",
            "private nonisolated static func makeHistoryTrendSummaries(sessions: [SavedSession],",
            "anomalySource: \"bounded_history_rollups\"",
            "private var snapshot: HistorySnapshot {",
            "return fixture",
            "store.historySnapshot",
            "struct HistorySnapshot",
            "let sessionRows: [HistorySessionRowSnapshot]",
            "let restingTrendPoints: [RestingTrendPoint]",
            "private static func makeRestingTrendPoints(_ sessions: [SavedSession]) -> [RestingTrendPoint]",
            "struct HistorySessionRowSnapshot: Identifiable",
            "struct SleepHistorySnapshot: Equatable",
            "static let empty = HistorySnapshot(sessions: [], detections: [], trends: [], rollups: [], maxHR: 200)",
            "static func sessionsOnly(_ sessions: [SavedSession], maxHR: Int) -> HistorySnapshot",
            "includeDerivedSessionRows: false",
            "HistorySessionRowSnapshot(session: $0,",
            "includeDerivedMetrics: includeDerivedSessionRows",
            "? Self.makeRestingTrendPoints(sessions)",
            ": []",
        ]:
            assert_contains(self, sessions, needle)

        refresh_start = sessions.index("private func refreshHistorySnapshotCache")
        refresh_end = sessions.index("private func refreshOverviewTrendPointsCache")
        refresh_source = sessions[refresh_start:refresh_end]
        for forbidden in [
            "dailyRollups(rest:",
            "detectedActivities(rest:",
            "trendSummaries(rest:",
            "await Task.yield()",
            "Task.sleep(nanoseconds: 120_000_000)",
        ]:
            assert_not_contains(self, refresh_source, forbidden)

        history_view_start = sessions.index("struct HistoryView: View")
        history_view_end = sessions.index("struct HistorySnapshot")
        history_view_source = sessions[history_view_start:history_view_end]
        for needle in [
            "HistoryActivityRhythmCard(rollups: Array(snapshot.rollups.prefix(14)))",
            "Self.debugFixtureHistorySnapshot(arguments: ProcessInfo.processInfo.arguments)",
            "@State private var adjustmentNight: SleepHistorySnapshot.Night?",
            "private var pendingSleepReview: SleepHistorySnapshot.Night?",
            "store.latestSleepReviewNightForUI(rest: store.baseline.restingInt ?? 60,",
            'source: "history_sleep_review"',
            "HistorySleepReviewCTA(night: pendingSleepReview,",
            "store.confirmSleepHistoryNightForUI(pendingSleepReview,",
            "AtriaManualSleepSheet(initialStart: adjustment.start,",
            'source: "history_sleep_review_adjust"',
        ]:
            assert_contains(self, history_view_source, needle)
        self.assertLess(
            history_view_source.index('historySection(title: "Daily rollups"'),
            history_view_source.index('historySection(title: "Trends"'),
            "Daily rollups should stay above Trends so recent activity evidence is visible first.",
        )
        all_source = all_swift_source()
        for needle in [
            "case \"data\", \"collection\", \"history\":",
            "private static func debugRequestedUIScreen(arguments: [String]) -> String?",
            "Self.debugRequestedUIScreen(arguments: ProcessInfo.processInfo.arguments) == \"history\"",
            "HistoryView(store: store)",
        ]:
            assert_contains(self, all_source, needle)
        for needle in [
            "private struct HistoryActivityRhythmCard: View",
            "private static func debugFixtureHistorySnapshot(arguments: [String]) -> HistorySnapshot?",
            "private static func debugFixtureSleepReviewNight(arguments: [String]) -> SleepHistorySnapshot.Night?",
            '["history-activity-rhythm", "history-sleep-review"].contains(arguments[valueIndex])',
            'arguments[valueIndex] == "history-sleep-review"',
            "DailyRollup(day: day,",
            "private struct HistorySleepReviewCTA: View, Equatable",
            "Circle()\n                        .trim(from: 0, to: progress)",
            'Text(stateText)',
            'Label("Adjust", systemImage: "slider.horizontal.3")',
            'Label(night.isNapEvidence ? "Confirm nap" : "Confirm sleep",',
            '"History sleep review. \\(night.durationText), \\(timeText), \\(stateText). Confirm or adjust."',
            "Label(\"Activity rhythm\", systemImage: \"waveform.path.ecg\")",
            "ForEach(recentRollups, id: \\.day)",
            "rollup.strain / 21.0",
            "rhythmPill(\"Saved\", value: \"\\(confirmedCount)\"",
            "rhythmPill(\"Review\", value: \"\\(reviewCount)\"",
            "rhythmPill(\"Sleep\", value: \"\\(sleepContextCount)\"",
            "private var daySequenceStrip: some View",
            "Text(\"Day sequence\")",
            "private func daySequenceNode(_ rollup: DailyRollup) -> some View",
            "private func sequenceState(for rollup: DailyRollup)",
            "\"questionmark.circle.fill\", .cyan, \"needs workout review\"",
            "\"bolt.heart.fill\", .orange, \"workout saved\"",
            "\"moon.zzz.fill\", .blue, \"sleep context\"",
            "private var rollupChipGrid: some View",
            "rollupChip(title: \"Confirmed\"",
            "rollupChip(title: \"Review\"",
            "rollupChip(title: \"Sleep\"",
            "Text(String(format: \"%.1f strain\", rollup.strain))",
            ".foregroundStyle(Metrics.electricStrain)",
        ]:
            assert_contains(self, sessions, needle)
        assert_not_contains(
            self,
            sessions,
            "\\(rollup.sessions) sessions · \\(formatMinutes(rollup.duration)) saved"
        )
        for forbidden in [
            "@State private var snapshot",
            "HistorySnapshot(store: store)",
            "refreshSnapshot()",
            "detectedActivities(rest:",
            "trendSummaries(rest:",
            "dailyRollups(rest:",
            "ForEach(snapshot.sessions) { session in",
            "historySessionRow(session)",
            "session.avg",
            "session.peak",
            "session.resting",
            "session.points.count",
            "session.trimp(",
            "RestingTrendChart(sessions: snapshot.sessions,",
        ]:
            assert_not_contains(self, history_view_source, forbidden)

        insights = source(ROOT / "Atria" / "Atria" / "Insights.swift")
        chart = re.search(
            r"struct RestingTrendChart: View \{(?P<body>.*?)\n\}",
            insights,
            re.S,
        )
        self.assertIsNotNone(chart)
        chart_body = chart.group("body")
        for needle in [
            "let points: [RestingTrendPoint]",
            "ForEach(points) { point in",
            "point.resting",
        ]:
            assert_contains(self, chart_body, needle)
        for forbidden in [
            "let sessions: [SavedSession]",
            "sessions.sorted",
            "restingStable",
        ]:
            assert_not_contains(self, chart_body, forbidden)

        history_snapshot_start = sessions.index("struct HistorySnapshot")
        history_snapshot_end = sessions.index("private struct HistoryQuickStat")
        history_snapshot_source = sessions[history_snapshot_start:history_snapshot_end]
        for forbidden in [
            "init(store: SessionStore)",
            "detectedActivities(rest:",
            "trendSummaries(rest:",
            "dailyRollups(rest:",
        ]:
            assert_not_contains(self, history_snapshot_source, forbidden)

    def test_launch_trend_diagnostics_use_snapshot_builder(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")

        for needle in [
            "func logTrendSummariesFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments)",
            'arguments.contains("--atria-log-trends")',
            'arguments.contains("--atria-log-trend-summaries")',
            "case oneEighty = 180",
            "let sourceSessions = sessions",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logTrendSummaries(summaries: snapshots.history.trends,",
            "private nonisolated static func logTrendSummaries(summaries: [TrendSummary],",
            "private nonisolated static func trendAnomalyFlagsSnapshot(_ anomalies: [String]) -> String",
            "private nonisolated static func formatIntSnapshot(_ value: Int?) -> String",
            "private nonisolated static func formatDoubleSnapshot(_ value: Double?) -> String",
        ]:
            assert_contains(self, sessions, needle)

        logger = re.search(
            r"func logTrendSummariesFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        for needle in [
            'arguments.contains("--atria-log-trends")',
            'arguments.contains("--atria-log-trend-summaries")',
        ]:
            assert_contains(self, body, needle)
        for forbidden in [
            "DispatchQueue.global(qos: .utility).async",
            "trendSummaries(rest:",
            "dailyRollups(rest:",
            "detectedActivities(rest:",
        ]:
            assert_not_contains(self, body, forbidden)

        assert_contains(self, app, 'arguments.contains("--atria-log-trends")')
        assert_contains(self, app, 'arguments.contains("--atria-log-trend-summaries")')
        assert_contains(self, app, "store.logTrendSummariesFromLaunchIfRequested(arguments: arguments)")

    def test_sleep_history_snapshot_is_cached_and_shown_in_vitals(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        manual_sheet = source(ROOT / "Atria" / "Atria" / "AtriaManualSleepSheet.swift")
        sleep_research = source(ROOT / "Atria" / "Atria" / "AtriaSleepWakeResearch.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "struct SleepHistorySnapshot: Equatable",
            "struct Night: Identifiable, Equatable",
            "@Published private(set) var sleepHistorySnapshot = SleepHistorySnapshot.empty",
            "let start: Date?",
            "let end: Date?",
            "let sleep = SleepHistorySnapshot(rollups: rollups,",
            "confirmedSleeps: confirmedSleeps",
            "sleepHistorySnapshot = sleep",
            "let sleepDuration: TimeInterval?",
            "let sleepSpan: TimeInterval?",
            "let sleepStart: Date?",
            "let sleepEnd: Date?",
            "let sleepSource: String?",
            "let sleepStageSegments: [SleepStageSegment]",
            "private nonisolated static func sleepSpan(duration: TimeInterval,",
            "return max(duration, end.timeIntervalSince(start))",
            "let aggregateSleeps = Self.preferredSleepCandidatesByDay(Self.aggregateSleepCandidates(in: sessions,",
            "let aggregateSleeps = Self.preferredSleepCandidatesByDay(aggregateSleepCandidates(rest: rest,",
            "let rollupDays = Set(grouped.keys).union(aggregateSleeps.keys)",
            "return rollupDays.map { day in",
            "private nonisolated static func preferredSleepCandidatesByDay(_ candidates: [AggregateSleepCandidate])",
            "private nonisolated static func preferredSleepCandidateForReview(from candidates: [AggregateSleepCandidate])",
            "private nonisolated static func preferredDailySleepCandidate(from candidates: [AggregateSleepCandidate])",
            "private nonisolated static func sleepCandidateMainSleepRank(_ candidate: AggregateSleepCandidate) -> Int",
            "candidate.kind != \"nap_candidate\"",
            "AggregateSleepCandidate.strictMinimumDuration",
            "AggregateSleepCandidate.fragmentedMinimumDuration",
            "AggregateSleepCandidate.fragmentedMinimumSpan",
            "let sleepStageSegments = aggregateSleep.map { candidate in",
            "Self.sleepStageResearchSegments(from: daySessions,",
            "let singleSessionSleepSpan = Self.sleepSpan(duration: singleSessionSleepDuration,",
            "sleepSpan: aggregateSleep?.span ?? singleSessionSleepSpan",
            "sleepStageSegments: sleepStageSegments",
            "stageSegments: rollup.sleepStageSegments",
            "let sleepEfficiency: Double?",
            "var sleepEfficiencyText: String",
            "var isNapEvidence: Bool",
            "private var observedSpan: TimeInterval",
            "private var fitsNapCandidateWindow: Bool",
            "private var fitsMainSleepReviewWindow: Bool",
            "fileprivate var reviewReferenceDate: Date",
            "fileprivate var isShortNapReviewCandidate: Bool",
            "fileprivate var isMainSleepReviewCandidate: Bool",
            "return fitsMainSleepReviewWindow",
            "if !confirmed && Self.reviewPromotableNapSources.contains(source) && fitsMainSleepReviewWindow",
            "return false",
            "if Self.explicitNapSources.contains(source) { return true }",
            "if !confirmed && Self.napSizedSleepCandidateSources.contains(source) && fitsNapCandidateWindow",
            "if Self.explicitSleepSources.contains(source) { return false }",
            "return !confirmed && fitsNapCandidateWindow",
            "private static let explicitNapSources: Set<String>",
            "\"manual_nap\"",
            "\"nap_candidate\"",
            "\"hr_only_nap\"",
            "private static let explicitSleepSources: Set<String>",
            "\"manual_sleep\"",
            "\"validated_sleep_window\"",
            "\"overnight_sleep\"",
            "\"sleep_candidate\"",
            "\"single_session_sleep_candidate\"",
            "\"incomplete_fragmented_sleep\"",
            "private static let napSizedSleepCandidateSources: Set<String>",
            "private static let reviewPromotableNapSources: Set<String>",
            'var evidenceLabel: String',
            'isNapEvidence ? "Nap" : "Sleep"',
            'var evidenceOnlyFootnote: String',
            'isNapEvidence ? "Nap-only estimate" : "Sleep-only estimate"',
            'var confirmationText: String',
            'return isNapEvidence ? "Nap candidate" : "Sleep candidate"',
            'var reviewContextText: String',
            '"Nap candidate. Kept separate from main sleep unless you adjust it."',
            '"Sleep candidate. Review before it affects recovery."',
            "private static let napVsMainSleepReviewWindow: TimeInterval = 18 * 60 * 60",
            "private static func preferredReviewableLatestSleep(from nights: [Night]) -> Night?",
            "guard !newest.confirmed, newest.isShortNapReviewCandidate else { return newest }",
            "night.isMainSleepReviewCandidate",
            "let averageDurationText: String",
            "let evidenceCountText: String",
            "let averageFootnoteText: String",
            "let sleepConsistencyText: String",
            "let sleepConsistencyFootnote: String",
            "let sleepConsistencyPercent: Int?",
            "let recentSleepAverageDurationHours: Double?",
            "let recentSleepRecordCount: Int",
            "private static func makeEvidenceCountText(_ nights: [Night]) -> String",
            "let napCount = nights.filter(\\.isNapEvidence).count",
            'return "\\(nights.count) records"',
            'return nights.count == 1 ? "1 night" : "\\(nights.count) nights"',
            'self.averageFootnoteText = "Average across \\(self.evidenceCountText)"',
            "private static func makeSleepConsistency(_ nights: [Night]) -> (percent: Int?, text: String, footnote: String)",
            "private static func makeRecentSleepDebtBasis(_ nights: [Night]) -> (averageHours: Double?, recordCount: Int)",
            "self.recentSleepAverageDurationHours = debtBasis.averageHours",
            "self.recentSleepRecordCount = debtBasis.recordCount",
            "func sleepPlannerTargetHours(goalHours: Double, recoveryPercent: Int?) -> Double",
            "let debtBuffer = min(max(debt * 0.5, 0), 1.5)",
            "recoveryBuffer = recoveryPercent < 34 ? 0.5 : (recoveryPercent < 67 ? 0.25 : 0)",
            "return min(10.5, safeGoal + debtBuffer + recoveryBuffer)",
            "var emptyEvidenceLabel: String",
            '"Recent records"',
            "var emptyEvidenceValue: String",
            'return "Confirmed sleep or nap saved locally."',
            "var emptyEvidenceFootnote: String",
            "sleepEfficiency: Self.efficiency(duration: sleep.duration, span: sleep.span)",
            "start: sleep.start",
            "end: sleep.end",
            "let sleepStart = aggregateSleep?.start ?? sleepDetections.map(\\.start).min()",
            "let sleepEnd = aggregateSleep?.end ?? sleepDetections.map(\\.end).max()",
            "sleepStart: sleepStart",
            "sleepEnd: sleepEnd",
            "start: rollup.sleepStart",
            "end: rollup.sleepEnd",
            "sleepSource: aggregateSleep?.kind ?? (singleSessionSleepDuration > 0 ? \"single_session_sleep_candidate\" : nil)",
            'source: rollup.sleepReady > 0 ? "validated_sleep_window" : (rollup.sleepSource ?? "sleep_candidate")',
            "if let existing = nightsByDay[day], existing.confirmed {",
            "nightsByDay[day] = Self.mergingConfirmedNight(existing, with: rollup)",
            "private static func mergingConfirmedNight(_ night: Night, with rollup: DailyRollup) -> Night",
            "restingHR: night.restingHR ?? rollup.restingHR",
            "hrv: night.hrv ?? rollup.avgHRV",
            "respiratoryRate: night.respiratoryRate ?? rollup.avgRespiratoryRate",
            "private static func efficiency(duration: TimeInterval, span: TimeInterval?) -> Double?",
            "static let minimumFragmentDuration: TimeInterval = 5 * 60",
            "static let napMinimumDuration: TimeInterval = 20 * 60",
            "static let napMaximumSpan: TimeInterval = 3 * 60 * 60",
            'let kind: String',
            "session.duration >= AggregateSleepCandidate.minimumFragmentDuration",
            "let daytimeNapWindow = !overnight && startHour >= 11 && endHour <= 20",
            "let shortLowHRNapLike = session.duration >= AggregateSleepCandidate.napMinimumDuration",
            "session.duration >= AggregateSleepCandidate.napMinimumDuration",
            "session.avg <= rest + 12",
            "session.peak <= rest + 35",
            "let longOvernightReviewLike = overnight",
            "&& session.duration >= AggregateSleepCandidate.strictMinimumDuration",
            "&& session.avg <= rest + 22",
            "&& session.peak <= rest + 75",
            "return ((overnight && lowHR) || longOvernightReviewLike || napLike || shortLowHRNapLike) && notWorkout",
            "let strictDurationReady = totalDuration >= AggregateSleepCandidate.strictMinimumDuration",
            "let fragmentedFallbackReady = cluster.count > 1",
            "private nonisolated static func isStrapOnlyMainSleepReviewCandidate(_ candidate: AggregateSleepCandidate) -> Bool",
            "if isStrapOnlyMainSleepReviewCandidate(candidate) { return 2 }",
            "return \"sleep_review_pending_user_confirmation\"",
            "let clusterOvernightReviewWindow = clusterStartHour >= 20",
            "|| clusterStartHour <= 5",
            "|| clusterEndHour <= 11",
            "let clusterDaytimeNapWindow = !clusterOvernightReviewWindow",
            "&& clusterStartHour >= 11",
            "&& clusterEndHour <= 20",
            "let daytimeNapCandidateReady = clusterDaytimeNapWindow",
            "let shortLowHRNapCandidateReady = cluster.count == 1",
            "&& clusterDaytimeNapWindow",
            "let napCandidateReady = daytimeNapCandidateReady || shortLowHRNapCandidateReady",
            "guard strictDurationReady || fragmentedFallbackReady || napCandidateReady else { return nil }",
            'reason = "HR-only short low-HR nap/rest candidate; user confirmation required; \\(motionReason)"',
            'reason = "HR-only daytime nap candidate; user confirmation required; \\(motionReason)"',
            'reason = "HR-only overnight review window; user confirmation required; \\(motionReason)"',
            'let kind = napCandidateReady ? "nap_candidate" : "overnight_sleep"',
            'if candidate.kind == "nap_candidate" { return "hr_only_nap" }',
            "private func sleepCandidateSource(for candidate: AggregateSleepCandidate) -> String",
            'if candidate.kind == "nap_candidate" { return "nap_candidate" }',
            "let aggregateSource = sleepCandidateSource(for: aggregate)",
            "? \"nap_candidate_\\(aggregate.sessions)_chunk\\(aggregate.sessions == 1 ? \"\" : \"s\")\"",
            "source=%@ duration_s=",
            "sleepFallbackSource(for: aggregate)",
            'let sleepSource = best.kind == "nap_candidate"',
            '? "nap_candidate"',
            "private static let sleepReadinessRetryDelays: [TimeInterval] = [45, 180]",
            "private var pendingSleepReadinessRetry: Task<Void, Never>?",
            "private func scheduleSleepReadinessRetryIfUseful(reason: String)",
            "ATRIADBG sleep_auto_confirm_retry schedule",
            "ATRIADBG sleep_auto_confirm_retry attempt=%d",
            "action=recheck_existing_gates",
            "private func sleepReadinessRetryState() -> (shouldRetry: Bool, evidence: SleepEvidenceStatus, pendingBackfill: Bool)",
            "UserDefaults.standard.bool(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillPending)",
            "evidence.blocker.hasPrefix(\"sleep_motion_unvalidated\")",
            "evidence.blocker == \"sleep_fragmented_below_minimum\"",
            # var since 2026-07-06: the wake-boundary fallback also runs on the
            # launch path when the strong tier saves nothing.
            "var savedStrongSleep = autoConfirmStrongSleepCandidates(reason: \"deferred_session_load\")",
            "if !savedStrongSleep {",
            "scheduleSleepReadinessRetryIfUseful(reason: \"deferred_session_load\")",
            "@discardableResult\n    private func autoConfirmStrongSleepCandidates(reason: String, limit: Int = 2) -> Bool",
            ".filter(Self.isStrongAutoConfirmableSleepCandidate)",
            # 2026-07-05: HR-only degraded auto-confirm tier (WHOOP parity for a
            # fragmented/artifact-inflated overnight). The per-candidate
            # source/confidence/motion decision was factored out of the
            # autoConfirmStrongSleepCandidates loop into a single
            # `autoSleepClassification(for:)` static (source string now branches on
            # unambiguous-HR-only vs degraded-HR-only vs motion-validated, adding
            # "auto_confirmed_sleep_hr_only"), and isStrongAutoConfirmableSleepCandidate
            # dropped `private` so unit tests can call it directly.
            "let classification = Self.autoSleepClassification(for: candidate)",
            "confidence: classification.confidence,",
            "nonisolated static func isStrongAutoConfirmableSleepCandidate(_ candidate: AggregateSleepCandidate) -> Bool",
            "if candidate.motionEvidenceValidated, candidate.confidence != .low {",
            "return isDegradedHROnlyOvernightSleepCandidate(candidate)",
            "nonisolated static func isDegradedHROnlyOvernightSleepCandidate(_ candidate: AggregateSleepCandidate,",
            "nonisolated static func autoSleepClassification(for candidate: AggregateSleepCandidate) -> AutoSleepClassification",
            '"auto_confirmed_sleep_hr_only"',
            "private nonisolated static func sleepWindowsOverlap(_ sleep: UserConfirmedSleep, candidate: AggregateSleepCandidate) -> Bool",
            '"auto_nap"',
            '"auto_sleep"',
            "func confirmSleepHistoryNightForUI(_ night: SleepHistorySnapshot.Night,",
            "private func confirmSleepHistoryNight(_ night: SleepHistorySnapshot.Night,",
            "private func reviewedSleepSource(for night: SleepHistorySnapshot.Night) -> String",
            "private func confirmedSleepWindowMetrics(start: Date,",
            "ATRIADBG sleep_confirm status=confirmed_specific",
            "reason=candidate_too_short_specific",
            "private struct IncompleteSleepFallback",
            "incompleteSleepFallback(in: recent,",
            'blocker: "sleep_fragmented_below_minimum"',
            'fallbackSource: "incomplete_fragmented_sleep"',
            "Fragmented overnight HR persisted below the sleep minimum",
            "AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,\n                                          store: store)",
            "AtriaRecoveryStrainCard(hero: heroStore.state,\n                                sleepHistory: debugFixtureSleepHistory ?? store.sleepHistorySnapshot,",
            "onAddManualSleep: addManualSleep,",
            "private func addManualSleep(start: Date, end: Date, isNap: Bool)",
            "store.addManualSleep(start: start,",
            "enum SleepStageKind: String, Codable, CaseIterable, Identifiable",
            "case awake",
            "case light",
            "case rem",
            "case sws",
            "case deep",
            "enum SleepStageEvidence: String, Codable, Equatable",
            "case manualEstimate",
            "case sensorResearch",
            "case validated",
            "case .none: return \"Stages not ready\"",
            "case .manualEstimate: return \"Manual estimate\"",
            "case .sensorResearch: return \"Estimated stages\"",
            "struct HeartSample: Equatable",
            "private struct EpochFeature: Equatable",
            "static func stageSegments(samples: [HeartSample],",
            "let epoch: TimeInterval = 30",
            "private static func epochFeatures(samples: [HeartSample],",
            "let shortSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 120)",
            "let longSmoothHR = gaussianSmoothedHR(samples: samples, center: center, sigma: 600)",
            "differenceOfGaussians: shortSmoothHR - longSmoothHR",
            "localVariability: variability",
            "motionStillnessPrior: motionStillnessPrior",
            "private static func stage(feature: EpochFeature,",
            "feature.differenceOfGaussians",
            "feature.localVariability",
            "feature.motionStillnessPrior",
            "return .rem",
            "private static func gaussianSmoothedHR(samples: [HeartSample],",
            "private static func standardDeviation(_ values: [Double]) -> Double",
            "private static func merge(_ staged:",
            "struct SleepStageSegment: Codable, Identifiable, Equatable",
            "func addManualSleep(start: Date,",
            "source: String = \"manual_ui\") -> UserConfirmedSleep?",
            "let sleepSource = isNap ? \"manual_nap\" : \"manual_sleep\"",
            "confidence: \"manual_user_entered\"",
            "motionSource: \"manual\"",
            "motionValidated: false",
            "stageSegments: nil",
            "let stageSegments = best.motionEvidenceValidated",
            "? Self.sleepStageResearchSegments(from: canonicalSessions(),",
            "stageSegments: stageSegments.isEmpty ? nil : stageSegments",
            "stage_research_segments=%d",
            "private nonisolated static func sleepStageResearchSegments(from sessions: [SavedSession],",
            "AtriaSleepWakeResearch.HeartSample(t: t, bpm: point.bpm)",
            "AtriaSleepWakeResearch.stageSegments(samples: samples,",
            "let displayStageSegments: [SleepStageSegment]",
            "let stageEvidence: SleepStageEvidence",
            "let stageDurationsByStage: [SleepStageKind: TimeInterval]",
            "Self.stageEvidence(source: source,",
            "self.displayStageSegments = evidence == .none ? [] : Self.foldedDisplaySegments(from: stageSegments)",
            "private static func stageEvidence(source: String,",
            "if source == \"validated_sleep_stages\"",
            "return .sensorResearch",
            "stageDurationsByStage[stage] ?? 0",
            "private static func stageDurations(from segments: [SleepStageSegment]) -> [SleepStageKind: TimeInterval]",
            "private struct AtriaSleepHistoryCard: View, Equatable",
            "AtriaSleepHistoryCard(snapshot: sleepHistory,",
            "let onAddManualSleep: (Date, Date, Bool) -> Void",
            "@State private var showManualSleepSheet = false",
            "Image(systemName: \"plus\")",
            ".atriaCardAction(prominent: false, tint: .cyan)",
            ".accessibilityLabel(\"Add sleep manually\")",
            "AtriaManualSleepSheet { start, end, isNap in",
            "init(initialStart: Date? = nil,",
            "private let reviewDetectedTypeText: String?",
            'self.reviewDetectedTypeText = initialIsNap.map { $0 ? "Nap" : "Sleep" }',
            "_start = State(initialValue: resolvedStart)",
            "_end = State(initialValue: max(resolvedEnd, resolvedStart.addingTimeInterval(60)))",
            "_isNap = State(initialValue: initialIsNap ?? false)",
            "_typeWasManuallyEdited = State(initialValue: initialIsNap != nil)",
            "@State private var typeWasManuallyEdited = false",
            "private var inferredIsNap: Bool",
            "AtriaAnalytics.ManualSleep.inferredIsNap(start: start,",
            "private var typeBinding: Binding<Bool>",
            "typeWasManuallyEdited = true",
            "private var typeSuggestionText: String",
            "if let reviewDetectedTypeText",
            "\"Detected as \\(reviewDetectedTypeText). Change type or window before saving.\"",
            "\"Detected as \\(reviewDetectedTypeText). Saving as \\(current); adjust the window if needed.\"",
            '"\\(reviewDetectedTypeText == nil ? "Add" : "Review") \\(isNap ? "Nap" : "Sleep")"',
            "\"Suggested by the window: \\(suggested). Your manual choice is kept.\"",
            "\"Atria suggested \\(suggested) from duration and time of day.\"",
            "manualTypeButton(title: \"Sleep\"",
            "manualTypeButton(title: \"Nap\"",
            "private func manualTypeButton(title: String,",
            "typeBinding.wrappedValue = isNapValue",
            ".atriaGlassSelectable(selected: isSelected, tint: .cyan)",
            ".accessibilityValue(isSelected ? \"Selected\" : \"Not selected\")",
            ".onAppear(perform: applyInferredTypeIfNeeded)",
            ".onChange(of: start) { _, _ in applyInferredTypeIfNeeded() }",
            ".onChange(of: end) { _, _ in applyInferredTypeIfNeeded() }",
            "private func applyInferredTypeIfNeeded()",
            "guard !typeWasManuallyEdited else { return }",
            "DatePicker(\"Start\"",
            "DatePicker(\"End\"",
            "private var canSave: Bool",
            "duration >= AggregateSleepCandidate.napMinimumDuration",
            "duration <= AggregateSleepCandidate.napMaximumSpan",
            "duration >= AggregateSleepCandidate.strictMinimumDuration",
            "ScrollView {",
            "AtriaManualSleepCardHeader(title: \"Type\"",
            "AtriaManualSleepCardHeader(title: \"Window\"",
            "AtriaManualSleepCardHeader(title: \"Duration\"",
            "AtriaManualSleepCardHeader(title: \"Stages\"",
            ".manualSleepCard(tint: .cyan)",
            ".manualSleepCard(tint: .blue)",
            ".manualSleepCard(tint: canSave ? .green : .orange)",
            ".manualSleepCard(tint: .purple)",
            "private struct AtriaManualSleepCardHeader: View",
            "func manualSleepCard(tint: Color) -> some View",
            "LabeledContent(\"Window\")",
            "detail: validationText",
            "\"Naps need at least 20 minutes.\"",
            "\"Longer than 3 hours should be saved as sleep.\"",
            "\"Sleep needs at least 3 hours.\"",
            ".disabled(!canSave)",
            "ForEach(SleepStageKind.allCases)",
            "Manual entries save the window only.",
            "will not fabricate stage bars.",
            "Manual entries improve duration, nap, and sleep-history continuity; sleep stages require sensor evidence.",
            "AtriaSleepStageSummary(night: latest)",
            "AtriaMetricTile(label: \"Consistency\"",
            "value: snapshot.sleepConsistencyText",
            "private static func sleepDurationConsistencyPercent(_ nights: [Night]) -> Int?",
            "private static func sleepScheduleConsistencyPercent(_ nights: [Night]) -> Int?",
            "compactMap(Self.sleepMidpointTimeOfDaySeconds)",
            "private static func circularMeanAbsoluteDeviationHours(_ seconds: [TimeInterval]) -> Double",
            "Double(durationScore) * 0.55 + Double($0) * 0.45",
            '"sleep timing and duration"',
            "AtriaMetricTile(label: \"Debt\"",
            "value: snapshot.sleepDebtText(goalHours: sleepGoalHours)",
            "footnote: snapshot.sleepDebtFootnote(goalHours: sleepGoalHours)",
            "AtriaSleepContextLens(snapshot: snapshot,",
            "private struct AtriaSleepContextLens: View, Equatable",
            "Label(\"Sleep lens\", systemImage: latest?.isNapEvidence == true ? \"moon.zzz.fill\" : \"bed.double.fill\")",
            "private var recoveryImpactText: String",
            "latest.isNapEvidence ? \"Separate\" : \"Recovery\"",
            "lensPill(title: \"Type\", value: latest?.evidenceLabel ?? \"Learning\", tint: .cyan)",
            "lensPill(title: \"Recovery\", value: recoveryImpactText, tint: .blue)",
            "lensPill(title: \"Routine\", value: snapshot.sleepConsistencyText, tint: .mint)",
            "debugFixtureSleepHistory ?? store.sleepHistorySnapshot",
            "arguments[valueIndex] == \"sleep-history-context-lens\"",
            "debug-ui-fixture-sleep-history-context-lens-\\(index)",
            "return SleepHistorySnapshot(nights: nights, confirmedCount: max(0, nights.count - 1), candidateCount: 1)",
            "guard let averageHours = recentSleepAverageDurationHours, recentSleepRecordCount > 0 else { return nil }",
            "!latest.displayStageSegments.isEmpty",
            "private var heatStripNights: [SleepHistorySnapshot.Night]",
            "Array(snapshot.nights.prefix(84).reversed())",
            "AtriaSleepYearHeatStrip(nights: heatStripNights,",
            "private struct AtriaSleepYearHeatStrip: View, Equatable",
            "Canvas { context, size in",
            "drawCells(in: &context, size: size)",
            "let rows = 7",
            "Int(ceil(Double(nights.count) / Double(rows)))",
            "Sleep heat strip",
            # Pins migrated (2026-07-05, visibility/IA §2): de-privatized so
            # AtriaHealthScreen (the live Vitals tab) can mount the
            # sleep-stage summary directly -- no logic change, just dropped
            # `private` on these two struct declarations.
            "struct AtriaSleepStageSummary: View, Equatable",
            "Text(night.stageEvidence.label)",
            "AtriaSleepStageHypnogram(segments: night.displayStageSegments,",
            "struct AtriaSleepStageBuildingSummary: View, Equatable",
            "Text(\"Stages building\")",
            "Stage breakdown needs checked sleep-stage evidence; duration, RHR, HRV, and respiratory estimates stay visible while Atria learns.",
            "AtriaSleepStageBuildingSummary(night: latest)",
            "Awake, Light, REM, SWS, and Deep are not ready yet.",
            "private struct AtriaSleepStageHypnogram: View, Equatable",
            "Canvas { context, size in",
            "drawGuides(in: &context, size: size)",
            "drawSegments(in: &context, size: size)",
            "private func stageY(_ stage: SleepStageKind, height: CGFloat) -> CGFloat",
            "width: min(width, max(0, size.width - x))",
            "Awake \\(night.stageText(.awake))",
            "Light \\(night.stageText(.light))",
            "REM \\(night.stageText(.rem))",
            "SWS \\(night.stageText(.sws))",
            "Deep \\(night.stageText(.deep))",
            ".accessibilityLabel(\"\\(night.evidenceLabel) \\(night.stageEvidence.label). Awake \\(night.stageText(.awake)), Light \\(night.stageText(.light)), REM \\(night.stageText(.rem)), SWS \\(night.stageText(.sws)), Deep \\(night.stageText(.deep)).\")",
            "HKCategoryValueSleepAnalysis.asleepREM.rawValue",
            "Chart(chartNights)",
            "Wear the strap overnight or during a nap.",
            "Sleep or nap evidence saved; confirm it when ready.",
            'AtriaMetricTile(label: snapshot.latest?.evidenceLabel ?? "Latest"',
            'night.isNapEvidence ? "moon.zzz.fill" : "bed.double.fill"',
            "\\(night.confirmationText) · \\(night.durationText)",
            "footnote: snapshot.averageFootnoteText",
            "private var emptyEvidenceState: AtriaMetricState",
            "if snapshot.candidateCount > 0 { return .research }",
            "private var latestEvidenceFootnote: String",
            "\"\\(latest.confidenceText) · \\(latest.reviewContextText)\"",
            "AtriaMetricTile(label: snapshot.emptyEvidenceLabel",
            "value: snapshot.emptyEvidenceValue",
            "state: emptyEvidenceState",
            "footnote: snapshot.emptyEvidenceFootnote",
            "onConfirmSleep: confirmSleepCandidate",
            "onAdjustSleep: adjustSleepCandidate",
            "private func adjustSleepCandidate(night: SleepHistorySnapshot.Night,",
            'source: "vitals_sleep_history_adjust"',
            "source: \"vitals_sleep_history\"",
            "if let night = store.sleepHistorySnapshot.latest",
            "store.confirmSleepHistoryNightForUI(night,",
            "private var shouldShowConfirmSleep: Bool",
            "guard snapshot.candidateCount > 0 else { return false }",
            "snapshot.latest?.confirmed != true",
            "private var reviewSleepLabel: String",
            "snapshot.latest?.isNapEvidence == true ? \"Review nap\" : \"Review sleep\"",
            "@State private var adjustmentNight: SleepHistorySnapshot.Night?",
            "Label(reviewSleepLabel, systemImage: \"slider.horizontal.3\")",
            ".accessibilityHint(\"Review the detected window before saving it.\")",
            "Button(action: onConfirmSleep)",
            "Label(\"Confirm\", systemImage: \"checkmark.circle\")",
            ".accessibilityHint(\"Saves the shown sleep or nap candidate locally.\")",
            ".sheet(item: $adjustmentNight) { night in",
            "AtriaManualSleepSheet(initialStart: night.start,",
            "initialIsNap: night.isNapEvidence",
            "onAdjustSleep(night, start, end, isNap)",
            "AtriaMetricTile(label: \"Efficiency\"",
            "value: snapshot.latest?.sleepEfficiencyText ?? \"--\"",
            "state: snapshot.latest?.sleepEfficiency == nil ? .learning : .research",
            "footnote: \"Duration-based estimate\"",
            'AtriaMetricTile(label: "\\(snapshot.latest?.evidenceLabel ?? "Sleep") RHR"',
            'AtriaMetricTile(label: "\\(snapshot.latest?.evidenceLabel ?? "Sleep") HRV"',
            "value: snapshot.latest?.hrvText ?? \"--\"",
            "state: snapshot.latest?.hrv == nil ? .learning : .research",
            'footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate"',
            'AtriaMetricTile(label: "\\(snapshot.latest?.evidenceLabel ?? "Sleep") resp"',
            "value: snapshot.latest?.respiratoryRateText ?? \"--\"",
            "state: snapshot.latest?.respiratoryRate == nil ? .learning : .research",
            'footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate"',
            "Eff \\(night.sleepEfficiencyText)",
            "HRV \\(night.hrvText)",
            "Resp \\(night.respiratoryRateText)",
            "enum ManualSleep",
            "static func inferredIsNap(start: Date,",
            "currentSelection: Bool,",
            "calendar: Calendar = .current",
            "duration >= AggregateSleepCandidate.strictMinimumDuration",
            "let daytimeWindow = startHour >= 11 && endHour <= 20",
            "return daytimeWindow || duration < AggregateSleepCandidate.strictMinimumDuration",
        ]:
            assert_contains(self, sessions + vitals + manual_sheet + sleep_research + analytics + healthkit, needle)
        self.assertEqual(
            sessions.count("let rollupDays = Set(grouped.keys).union(aggregateSleeps.keys)"),
            2,
            "both cached history and live daily rollups must surface aggregate sleep days",
        )
        assert_not_contains(self, manual_sheet, ".pickerStyle(.segmented)")
        assert_not_contains(self, manual_sheet, "Picker(\"Type\", selection:")

        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        for needle in [
            "onAddManualSleep: addManualSleep,",
            "source: \"manual_today_glance\"",
            "rest: store.baseline.restingInt ?? 60",
            "AtriaManualSleepSheet { start, end, isNap in",
            "showManualSleepSheet = false",
            "Image(systemName: \"moon.zzz.badge.plus\")",
            ".accessibilityLabel(\"Add sleep manually\")",
            "Stages building: Awake, Light, REM, and Deep are not ready yet.",
            "guard !latest.displayStageSegments.isEmpty else",
            "Consistency \\(snapshot.sleepConsistencyText)",
            "Debt \\(snapshot.sleepDebtText(goalHours: sleepGoalHours))",
            "Sleep debt \\(snapshot.sleepDebtText(goalHours: sleepGoalHours))",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, vitals, "case pulse, hrv, recoveryStrain, profile")
        assert_not_contains(self, vitals, "case pulse, hrv, recoveryStrain, sleep")
        assert_not_contains(self, sessions, "estimatedStageSegments")
        assert_not_contains(self, sessions, "let resolvedSegments = stageSegments.isEmpty")
        assert_not_contains(self, sessions, "guard session.duration >= 20 * 60, !session.points.isEmpty else { return false }")
        assert_not_contains(self, sessions, "sleepSpan: sleepDuration > 0 ? sleepDuration : nil")
        assert_not_contains(self, sessions, "sleepSpan: aggregateSleep?.span ?? (singleSessionSleepDuration > 0 ? singleSessionSleepDuration : nil)")

        sleep_card_start = vitals.index("private struct AtriaSleepHistoryCard")
        sleep_card_end = vitals.index("private struct AtriaSleepNightRow")
        sleep_card_source = vitals[sleep_card_start:sleep_card_end]
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, sleep_card_source, forbidden)

    def test_launch_activity_diagnostics_use_snapshot_builder(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        logger = re.search(
            r"func logActivityDetectionsFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        for needle in [
            "let sourceSessions = sessions",
            "let confirmedWorkouts = cachedConfirmedWorkouts",
            "let confirmedSleeps = cachedConfirmedSleeps",
            "let baselineSnapshot = baseline",
            "DispatchQueue.global(qos: .utility).async",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logActivityDetections(detections: snapshots.history.detections,",
        ]:
            assert_contains(self, body, needle)
        for forbidden in [
            "detectedActivities(rest:",
            "aggregateWorkoutCandidates(",
            "dailyRollups(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, body, forbidden)

        for needle in [
            "private nonisolated static func logActivityDetections(detections: [ActivityDetection],",
            "private nonisolated static func kindRankSnapshot(_ kind: ActivityDetection.Kind) -> Int",
            "private nonisolated static func confidenceRankSnapshot(_ confidence: ActivityDetection.Confidence) -> Int",
        ]:
            assert_contains(self, sessions, needle)

    def test_launch_daily_rollup_diagnostics_use_snapshot_builder_by_default(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        logger = re.search(
            r"func logDailyRollupsFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        for needle in [
            "let deepDiagnosticsRequested = arguments.contains(\"--atria-log-daily-rollups-deep\")",
            "guard arguments.contains(\"--atria-log-daily-rollups\") || deepDiagnosticsRequested else { return }",
            "let sourceSessions = sessions",
            "let confirmedWorkouts = cachedConfirmedWorkouts",
            "let confirmedSleeps = cachedConfirmedSleeps",
            "let baselineSnapshot = baseline",
            "guard deepDiagnosticsRequested else {",
            "DispatchQueue.global(qos: .utility).async",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logDailyRollups(rollups: snapshots.history.rollups,",
            "return",
            "logDeepDailyRollupDiagnostics(formatter: formatter, rest: rest)",
        ]:
            assert_contains(self, body, needle)

        fast_path = body.split("guard deepDiagnosticsRequested else {", 1)[1].split("\n        let rollups = dailyRollups", 1)[0]
        for forbidden in [
            "dailyRollups(rest:",
            "aggregateWorkoutCandidates(",
            "aggregateSleepDiagnostics(",
            "aggregateSleepCandidates(",
            "workoutReadiness(",
        ]:
            assert_not_contains(self, fast_path, forbidden)

        for needle in [
            "private nonisolated static func logDailyRollups(rollups: [DailyRollup],",
            "private func logDeepDailyRollupDiagnostics(formatter: DateFormatter, rest: Int)",
            "aggregateWorkoutCandidates(rest:",
            "aggregateSleepDiagnostics(rest:",
            "aggregateSleepCandidates(rest:",
        ]:
            assert_contains(self, sessions, needle)

        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        assert_contains(self, app, 'arguments.contains("--atria-log-daily-rollups-deep")')

    def test_launch_validation_flags_are_wired_to_deferred_diagnostics(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            'arguments.contains("--atria-verify-sleep")',
            'arguments.contains("--atria-schedule-sleep-validation")',
            'arguments.contains("--atria-verify-workout-label")',
            'arguments.contains("--atria-schedule-workout-validation")',
            "store.scheduleSleepValidationFromLaunchIfRequested(arguments: arguments)",
            "store.scheduleWorkoutValidationFromLaunchIfRequested(arguments: arguments)",
        ]:
            assert_contains(self, app, needle)

        sleep_scheduler = re.search(
            r"func scheduleSleepValidationFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(sleep_scheduler)
        sleep_body = sleep_scheduler.group("body")
        for needle in [
            'arguments.contains("--atria-verify-sleep") || arguments.contains("--atria-schedule-sleep-validation")',
            'value(after: "--atria-verify-sleep-label", in: arguments)',
            'doubleValue(after: "--atria-verify-sleep-after"',
            "await logSleepValidationWithReadinessRetry(label: label?.isEmpty == false ? label : nil)",
        ]:
            assert_contains(self, sleep_body, needle)

        for needle in [
            "private static let sleepValidationRetryDelays: [TimeInterval] = [12, 30]",
            "private func logSleepValidationWithReadinessRetry(label: String?) async",
            "guard label == nil else {",
            "ATRIADBG sleep_validation status=deferred",
            "action=retry_existing_gates",
            "readiness.evidence.blocker",
            "readiness.pendingBackfill ? 1 : 0",
            "logSleepValidation(label: nil)",
        ]:
            assert_contains(self, sessions, needle)

        harness = source(ROOT / "live_device_debug.sh")
        for needle in [
            '"ATRIADBG sleep_validation status=" in line',
            'and " status=deferred " not in line',
            'flags["sleep_validation_complete"] = True',
        ]:
            assert_contains(self, harness, needle)

        workout_scheduler = re.search(
            r"func scheduleWorkoutValidationFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(workout_scheduler)
        workout_body = workout_scheduler.group("body")
        for needle in [
            'arguments.contains("--atria-schedule-workout-validation")',
            'value(after: "--atria-verify-workout-label", in: arguments) != nil',
            'value(after: "--atria-verify-workout-label", in: arguments)',
            'doubleValue(after: "--atria-verify-workout-after"',
        ]:
            assert_contains(self, workout_body, needle)

    def test_launch_session_backup_flags_are_wired_to_store_guards(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            'store.restoreLatestSessionBackupFromLaunchIfRequested()',
            'store.reconcileCanonicalSessionsFromBackupIfNeeded(reason: "fast_launch")',
            'arguments.contains("--atria-write-session-backup")',
            'arguments.contains("--atria-verify-session-backup")',
            'arguments.contains("--atria-restore-backup")',
            "await store.waitForDeferredSessionLoadIfNeeded()",
            "store.queueSessionBackupAfterDeferredLoadFromLaunchIfRequested(arguments: arguments)",
            "store.restoreLatestSessionBackupFromLaunchIfRequested(arguments: arguments)",
            'arguments.contains("--atria-backup-sessions")',
            'arguments.contains("--atria-verify-backup")',
        ]:
            assert_contains(self, app, needle)
        assert_not_contains(self, app, "runSessionBackupDiagnosticsIfRequested(arguments: arguments)")
        assert_not_contains(self, app, "ATRIADBG session_backup_launch status=started")
        deferred_launch = re.search(
            r"private func handleDeferredLaunchWork\(arguments: \[String\]\) \{(?P<body>.*?)\n    \}",
            app,
            re.S,
        )
        self.assertIsNotNone(deferred_launch)
        deferred_body = deferred_launch.group("body")
        self.assertLess(
            deferred_body.index("store.queueSessionBackupAfterDeferredLoadFromLaunchIfRequested(arguments: arguments)"),
            deferred_body.index("Task { @MainActor in"),
        )
        assert_not_contains(self, deferred_body, "store.writeSessionBackupFromLaunchIfRequested(arguments: arguments)")
        assert_not_contains(self, deferred_body, "store.verifyLatestSessionBackupFromLaunchIfRequested(arguments: arguments)")

        for needle in [
            "private var hasCompletedDeferredSessionLoad = false",
            "private var pendingDeferredSessionBackupArguments: [String]?",
            "func waitForDeferredSessionLoadIfNeeded(timeoutSeconds: TimeInterval = 8) async",
            "func queueSessionBackupAfterDeferredLoadFromLaunchIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments)",
            "private func runQueuedSessionBackupAfterDeferredLoadIfNeeded()",
            "pendingDeferredSessionBackupArguments = arguments",
            'AtriaDebugLog("ATRIADBG session_backup_deferred status=queued write=%d verify=%d"',
            'AtriaDebugLog("ATRIADBG session_backup_deferred status=running sessions=%d"',
            "runQueuedSessionBackupAfterDeferredLoadIfNeeded()",
            'AtriaDebugLog("ATRIADBG session_store_load_wait status=%@ elapsed_ms=%d sessions=%d"',
            "self.hasCompletedDeferredSessionLoad = true",
            "hasCompletedDeferredSessionLoad = true",
            "Self.pruningShortLongWearFragments(from: decoded)",
            "reason: \"prune_short_long_wear_fragments\"",
            "pruned_short_long_wear_fragments=%d",
            "private nonisolated static func persistSessionsSnapshot",
            "private nonisolated static func mergedSessions(primary: [SavedSession], secondary: [SavedSession]) -> [SavedSession]",
            "private func reconcileSessionsBeforeLiveUpsert(reason: String)",
            "func reconcileCanonicalSessionsFromBackupIfNeeded(reason: String)",
            "requestPersistenceFlush(reason: \"session_reconcile_\\(reason)\")",
            "reconcileSessionsBeforeLiveUpsert(reason: \"add\")",
            "reconcileSessionsBeforeLiveUpsert(reason: \"checkpoint\")",
            "Self.mergedSessions(primary: sessions, secondary: decoded)",
            "scheduleSessionFilePersist(reason: \"deferred_load_merge\", delay: 0.10)",
            "private nonisolated static func isShortLongWearFragment(_ session: SavedSession) -> Bool",
            "guard session.duration < 5 * 60 else { return false }",
            "label == \"long wear\"",
            "label == \"auto-saved\"",
            "label.hasPrefix(\"auto-saved chunk\")",
        ]:
            assert_contains(self, sessions, needle)

        write_backup = re.search(
            r"func writeSessionBackupFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(write_backup)
        for needle in [
            'arguments.contains("--atria-backup-sessions")',
            'arguments.contains("--atria-write-session-backup")',
            'writeSessionBackup(label: "debug")',
            "ATRIADBG session_backup_compress_fallback",
            "compressed=%d",
            "encodedBackup.fileExtension",
            "encodedBackup.compressed ? 1 : 0",
            "Self.latestDecodableSessionBackupURL(from: allFiles)",
            "private nonisolated static func latestDecodableSessionBackupURL(from files: [URL]) -> URL?",
            "decodeSessionBackupEnvelope(at: url)",
            "supportedBackupSchemas.contains(envelope.schema)",
        ]:
            assert_contains(self, sessions, needle)

        verify_backup = re.search(
            r"func verifyLatestSessionBackupFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(verify_backup)
        for needle in [
            'arguments.contains("--atria-verify-backup")',
            'arguments.contains("--atria-verify-session-backup")',
            "verifyLatestSessionBackup()",
        ]:
            assert_contains(self, verify_backup.group("body"), needle)

        restore_backup = re.search(
            r"func restoreLatestSessionBackupFromLaunchIfRequested\(arguments: \[String\] = ProcessInfo\.processInfo\.arguments\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(restore_backup)
        assert_contains(self, restore_backup.group("body"), 'arguments.contains("--atria-restore-backup")')
        assert_contains(self, sessions, "private nonisolated static func bestRestorableSessionBackupURL(from files: [URL]) -> URL?")
        assert_contains(self, sessions, "envelope.schema >= 2")
        assert_contains(self, sessions, "let hasProductState = !(envelope.dailyRollups ?? []).isEmpty")
        assert_contains(self, sessions, "&& !(envelope.confirmedSleeps ?? []).isEmpty")
        assert_contains(self, sessions, "let productComplete = candidates.filter(\\.isComplete)")
        assert_contains(self, sessions, "let ranked = productComplete.isEmpty ? candidates : productComplete")
        assert_contains(self, sessions, "return $0.sessions > $1.sessions")
        assert_contains(self, sessions, "return Self.bestRestorableSessionBackupURL(from: allFiles)")
        compute_backup_status = re.search(
            r"private func computeSessionBackupStatus\(\) -> SessionBackupStatus \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(compute_backup_status)
        assert_contains(self, compute_backup_status.group("body"), "guard let latest = latestSessionBackupURL() else")
        for needle in [
            "private enum SessionBackupDebugDefaults",
            'restoreStatus = "atria.debug.sessionBackup.restore.status"',
            "recordSessionBackupRestoreDebug(status: \"ok\"",
            "recordSessionBackupRestoreDebug(status: \"missing\", reason: \"no_backup_files\")",
            "restoreSafetyPath",
            "restoreConfirmedSleeps",
            'restoreSummary = "atria.debug.sessionBackup.restore.summary"',
            "static let allRestoreKeys = [",
            "for key in SessionBackupDebugDefaults.allRestoreKeys",
            "defaults.removeObject(forKey: key)",
            "defaults.set(summary, forKey: SessionBackupDebugDefaults.restoreSummary)",
            "defaults.synchronize()",
        ]:
            assert_contains(self, sessions, needle)

        pull = source(ROOT / "pull_atria_state.sh")
        for needle in [
            "def emit_session_backup_restore_preferences():",
            "summary_text = pref(prefs, 'debug.sessionBackup.restore.summary')",
            "if isinstance(summary_text, dict):",
            "parsed = json.loads(summary_text)",
            "def restore_value(name, suffix, default=None):",
            "session_backup_restore_debug_status=",
            "session_backup_restore_debug_safety_path=",
            "session_backup_restore_debug_confirmed_sleeps=",
            "emit_session_backup_restore_preferences()",
        ]:
            assert_contains(self, pull, needle)

    def test_cd9_settings_backup_import_restore_is_user_visible(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "import UniformTypeIdentifiers",
            "let backupStatusProvider: () -> SessionBackupStatus",
            "let onWriteBackup: (() -> SessionBackupStatus)?",
            "let onVerifyBackup: (() -> Void)?",
            "let onRestoreBackup: ((URL) -> SessionBackupStatus?)?",
            "backupArchiveRow",
            "debugPrioritizesDataSection",
            'ProcessInfo.processInfo.arguments[valueIndex] == "settings-backup"',
            ".fileImporter(isPresented: $backupImportPresented",
            "allowedContentTypes: backupArchiveTypes",
            "UTType(filenameExtension: \"gz\")",
            "url.startAccessingSecurityScopedResource()",
            "Restore backup from Files",
            "@AtriaDefault(SessionStore.iCloudBackupEnabledKey) private var iCloudBackupEnabled = false",
            "Toggle(isOn: $iCloudBackupEnabled)",
            "Copy to iCloud Drive",
            "icloud.and.arrow.up",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "backupStatusProvider: { store.sessionBackupStatus() }",
            'store.writeSessionBackup(label: "settings")',
            "onVerifyBackup: { store.verifyLatestSessionBackup() }",
            "guard store.restoreSessionBackup(from: url) else { return nil }",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "struct SessionBackupRawExport: Codable, Equatable",
            "var rawExport: SessionBackupRawExport? = nil",
            "rawExport: rawExport",
            "schema: 3",
            "raw_export_hr_rows=%d",
            "raw_export_rr_rows=%d",
            "private nonisolated static let supportedBackupSchemas: Set<Int> = [1, 2, 3]",
            'static let iCloudBackupEnabledKey = "atria.backup.iCloudDrive.enabled"',
            "FileManager.default.url(forUbiquityContainerIdentifier: nil)",
            "Documents/Atria Backups",
            "mirrorSessionBackupToICloudIfEnabled(backupURL)",
            "ATRIADBG session_backup_icloud status=ok",
            "ATRIADBG session_backup_icloud status=skipped_toggle",
            "func restoreSessionBackup(from backupURL: URL) -> Bool",
            "let envelope = try Self.decodeSessionBackupEnvelope(at: backupURL)",
            "return true",
            "return false",
        ]:
            assert_contains(self, sessions, needle)

    def test_cd11_today_glance_cards_open_customize_from_context_menu(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        customize = source(ROOT / "Atria" / "Atria" / "AtriaCustomizeSheet.swift")
        widget_proof = source(ROOT / "Atria" / "Atria" / "AtriaWidgetProofSheet.swift")
        info = source(ROOT / "Atria" / "Info.plist")
        widget_snapshot = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "let onCustomizeToday: () -> Void",
            "private var topActionMenu: some View",
            "Menu {",
            'Image(systemName: "ellipsis")',
            '.accessibilityLabel("Today actions")',
            ".contextMenu {",
            "Button(action: onCustomizeToday)",
            'Label("Customize Today", systemImage: "slider.horizontal.3")',
            "Button(action: onOpenShare)",
            'Label("Share Today", systemImage: "square.and.arrow.up")',
        ]:
            assert_contains(self, today, needle)

        assert_contains(self, home, "onCustomizeToday: {\n                                 showCustomizeSheet = true\n                             }")
        assert_contains(self, home, 'let shouldOpenCustomizeSheet = arguments.contains("--atria-open-customize")')
        assert_contains(self, home, 'let shouldOpenWidgetProof = arguments.contains("--atria-open-widget-proof")')
        assert_contains(self, home, "widgetProofSnapshot = WidgetSnapshotPublisher.publish(store: store,")
        assert_contains(self, home, 'reason: "cd11_widget_proof"')
        assert_contains(self, home, "showWidgetProofSheet = true")
        assert_contains(self, home, "AtriaWidgetProofSheet(snapshot: widgetProofSnapshot,")
        assert_contains(self, home, 'let shouldSeedCustomLayout = arguments.contains("--atria-seed-custom-layout")')
        assert_contains(self, home, "saveHomeLayoutConfig(Self.debugSeededHomeLayoutConfig())")
        assert_contains(self, home, "private static func debugSeededHomeLayoutConfig() -> AtriaHomeLayoutConfig")
        assert_contains(self, home, 'glanceMetrics: ["sleep", "recovery", "strain"]')
        assert_contains(self, home, 'sizeOverrides: ["sleep": "wideShort"]')
        assert_contains(self, home, "ringCenterMetric: .sleep")
        assert_contains(self, home, "accent: .coral")
        assert_contains(self, home, "showCustomizeSheet = true")
        assert_contains(self, home, "layoutConfig: currentHomeLayoutConfig")
        assert_not_contains(self, today, 'AtriaToolbarIcon(symbol: "slider.horizontal.3")')

        for needle in [
            "let layoutConfig: AtriaHomeLayoutConfig",
            "if layoutConfig.showLiveStrip",
            "if layoutConfig.showHighlights && !highlights.isEmpty",
            "if layoutConfig.showPlan",
            "if layoutConfig.showAICoach && effectiveAICoachSettings.mode != .off",
            "switch layoutConfig.ringCenterMetric",
            "layoutConfig.validated().glanceMetrics",
            ".compactMap(AtriaTodayMetric.init(rawValue:))",
            "private func glanceItem(for metric: AtriaTodayMetric) -> AtriaTodayGlanceItem?",
            "private func glanceColumnSpan(for item: AtriaTodayGlanceItem) -> Int",
            ".gridCellColumns(glanceColumnSpan(for: item))",
            "private func layoutSize(for metric: AtriaTodayMetric) -> AtriaTodayGlanceItem.LayoutSize",
            "layoutConfig.sizeOverrides[metric.rawValue] ?? \"compact\"",
            "enum LayoutSize: String, Equatable",
            "case wideShort",
            "var columnSpan: Int",
            "var minHeight: CGFloat",
            "let metricKey: String",
            "let layoutSize: LayoutSize",
            ".frame(maxWidth: .infinity, minHeight: item.layoutSize.minHeight, alignment: .leading)",
            "if !item.detail.isEmpty && item.layoutSize != .wideShort",
            "private func legendDetail(_ detail: String) -> String",
            "layoutConfig.legendStatStyle == .value ? \"\" : detail",
            "tint: layoutConfig.accent.color",
        ]:
            assert_contains(self, today, needle)

        for needle in [
            "enum AtriaAlternateAppIcon: String, CaseIterable",
            "case primary",
            "case mint",
            "case graphite",
            "return \"AtriaMint\"",
            "return \"AtriaGraphite\"",
            "static func current() -> AtriaAlternateAppIcon",
            "UIApplication.shared.alternateIconName",
            "private var appIconSection: some View",
            "Picker(\"App icon\", selection: $selectedAppIcon)",
            "UIApplication.shared.supportsAlternateIcons",
            "UIApplication.shared.setAlternateIconName(icon.alternateName)",
            "private func applyAppIcon(_ icon: AtriaAlternateAppIcon)",
            # 2026-07-05: reorder Edit control moved from the bottom toolbar into the
            # "Metric order" section header (co-located with the list) for
            # discoverability; pin its header styling instead of the bottomBar item.
            ".textCase(nil)",
            "EditButton()",
            "Text(\"Metric order\")",
            "ForEach(selectedMetrics)",
            ".onMove(perform: moveSelectedMetrics)",
            "private var metricToggleSection: some View",
            "private var selectedMetrics: [AtriaTodayMetric]",
            "draft.validated().glanceMetrics.compactMap(AtriaTodayMetric.init(rawValue:))",
            "private func moveSelectedMetrics(from source: IndexSet, to destination: Int)",
            "metrics.move(fromOffsets: source, toOffset: destination)",
            "draft.glanceMetrics = metrics",
            "Text(\"Tap Edit, then drag by the handle to reorder your Today cards.\")",
        ]:
            assert_contains(self, customize, needle)

        for needle in [
            "CFBundleAlternateIcons",
            "AtriaMint",
            "AtriaGraphite",
            "AtriaIconMint",
            "AtriaIconGraphite",
        ]:
            assert_contains(self, info, needle)

        for icon_path in [
            ROOT / "Atria" / "Atria" / "AtriaIconMint@2x.png",
            ROOT / "Atria" / "Atria" / "AtriaIconMint@3x.png",
            ROOT / "Atria" / "Atria" / "AtriaIconGraphite@2x.png",
            ROOT / "Atria" / "Atria" / "AtriaIconGraphite@3x.png",
        ]:
            self.assertTrue(icon_path.exists(), f"missing alternate app icon asset: {icon_path}")

        for needle in [
            "let layoutGlanceMetrics: [String]?",
            "let layoutRingCenterMetric: String?",
            "let layoutLegendStatStyle: String?",
            "let layoutAccent: String?",
            "let layout = currentHomeLayoutConfig()",
            "layoutGlanceMetrics: layout.glanceMetrics",
            "layoutRingCenterMetric: layout.ringCenterMetric.rawValue",
            "layoutLegendStatStyle: layout.legendStatStyle.rawValue",
            "layoutAccent: layout.accent.rawValue",
            "private static func currentHomeLayoutConfig() -> AtriaHomeLayoutConfig",
            "UserDefaults.standard.string(forKey: AtriaHomeLayoutConfig.storageKey)",
        ]:
            assert_contains(self, widget_snapshot, needle)

        for needle in [
            "let layoutGlanceMetrics: [String]?",
            "let layoutRingCenterMetric: String?",
            "let layoutLegendStatStyle: String?",
            "let layoutAccent: String?",
            "private var widgetMetrics: [AtriaWidgetMetric]",
            "AtriaWidgetMetric.ordered(from: entry.snapshot?.layoutGlanceMetrics)",
            "enum AtriaWidgetMetric: String, Identifiable",
            "static func ordered(from layoutGlanceMetrics: [String]?) -> [AtriaWidgetMetric]",
            "private static func widgetMetric(for key: String) -> AtriaWidgetMetric?",
            "ForEach(widgetMetrics) { metric in",
            "widgetMetricLink(widgetMetrics[0])",
            "widgetMetricLink(widgetMetrics[3])",
        ]:
            assert_contains(self, widget, needle)

        for needle in [
            "struct AtriaWidgetProofSheet: View",
            "let snapshot: WidgetSnapshot?",
            "let layoutConfig: AtriaHomeLayoutConfig",
            "Widget timeline snapshot ready",
            "Uses the same `atria.widgetSnapshot.v1` payload",
            "widgetPreview(title: \"Medium widget\", compact: true)",
            "widgetPreview(title: \"Large widget\", compact: false)",
            "AtriaWidgetProofMetric.ordered(from: snapshot?.layoutGlanceMetrics ?? validatedLayout.glanceMetrics)",
            "private enum AtriaWidgetProofMetric: String, Identifiable",
            "static let fallbackOrder: [AtriaWidgetProofMetric] = [.strain, .bpm, .hrv, .steps]",
            "case \"heartRate\", \"bpm\", \"rhr\", \"respiratoryRate\": return .bpm",
            "factRow(\"Layout order\", widgetMetrics.map(\\.title).joined(separator: \" / \"))",
            ".accessibilityIdentifier(\"atria-widget-proof-sheet\")",
        ]:
            assert_contains(self, widget_proof, needle)

    def test_cd12_strength_log_foundation_and_pause_fields_exist(self):
        strength = source(ROOT / "Atria" / "Atria" / "AtriaStrengthLog.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        journal = source(ROOT / "Atria" / "Atria" / "ActiveSessionJournal.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "struct LoggedSet: Codable, Equatable, Identifiable",
            "var weightKg: Double?",
            "struct ExcludedInterval: Codable, Equatable",
            "static let customExercisesKey = \"atria.exercises.custom.v1\"",
            "static let restSecondsKey = \"atria.strength.restSeconds.v1\"",
            "static func estimatedOneRepMax(weightKg: Double?, reps: Int?) -> Double?",
            "(1...12).contains(reps)",
            "static func personalRecords(for exercise: String",
            "static func isPR(_ set: LoggedSet, against records: StrengthPersonalRecords) -> Bool",
            "static func pointsExcludingIntervals",
            "static func samplesExcludingIntervals",
            "static func restSeconds(for exercise: String,",
            "static func setRestSeconds(_ seconds: TimeInterval,",
            "private static func restOverrides(defaults: UserDefaults = .standard)",
            "min(max(seconds, 30), 600)",
        ]:
            assert_contains(self, strength, needle)

        for needle in [
            "var strengthSets: [LoggedSet]? = nil",
            "var excludedIntervals: [ExcludedInterval]? = nil",
            "AtriaStrengthLog.pointsExcludingIntervals(points,",
            "func activeCalories(rest: Int, profile: AthleteProfile) -> Double?",
            "AtriaStrengthLog.samplesExcludingIntervals(samples,",
            "confirmedWorkoutMetrics(start: requestedStart,",
            "excludedIntervals: excludedIntervals)",
            "strengthSets: [LoggedSet] = []",
            "excludedIntervals: [ExcludedInterval] = []",
            "ActiveSessionJournal.mirrorStrengthState(strengthSets: strengthSets,",
            "private var didSeedDebugStrengthWorkoutProof = false",
            "func seedDebugStrengthWorkoutProofIfRequested(arguments: [String])",
            "arguments.contains(\"--atria-seed-strength-workout-proof\")",
            "ProcessInfo.processInfo.environment[\"ATRIA_SEED_STRENGTH_WORKOUT_PROOF\"] == \"1\"",
            "debugStrengthWorkoutProofStatusKey",
            "UserDefaults.standard.set(\"waiting\", forKey: Self.debugStrengthWorkoutProofStatusKey)",
            "UserDefaults.standard.set(\"seeded\", forKey: Self.debugStrengthWorkoutProofStatusKey)",
            "seedDebugStrengthWorkoutProofPersistedFileOnly()",
            "debug_cd12_strength_proof_persisted_file",
            "seeded_persisted_file",
            "private func makeDebugStrengthWorkoutProof(proofSessionID: UUID)",
            "Self.shouldSeedDebugStrengthWorkoutProof(arguments: ProcessInfo.processInfo.arguments)",
            "guard hasCompletedDeferredSessionLoad else",
            "CD-12 strength proof",
            "debug-cd12-strength-workout-proof",
            "ATRIADBG cd12_strength_workout_proof status=seeded",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "let shouldSeedStrengthWorkoutProof = arguments.contains(\"--atria-seed-strength-workout-proof\")",
            "|| shouldSeedStrengthWorkoutProof",
            "store.seedDebugStrengthWorkoutProofIfRequested(arguments: arguments)",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "var strengthSets: [LoggedSet]?",
            "var excludedIntervals: [ExcludedInterval]?",
            "static func mirrorStrengthState(strengthSets: [LoggedSet],",
            "record.strengthSets = strengthSets.isEmpty ? nil : strengthSets",
            "record.excludedIntervals = excludedIntervals.isEmpty ? nil : excludedIntervals",
            "previousSampleCount: record.samples.count",
            "strengthSets: record.strengthSets",
            "excludedIntervals: record.excludedIntervals",
        ]:
            assert_contains(self, journal, needle)

        for needle in [
            "let mirroredStrengthState = ActiveSessionJournal.load()",
            "let mirroredStrengthSets = mirroredStrengthState?.strengthSets",
            "let mirroredExcludedIntervals = mirroredStrengthState?.excludedIntervals",
            "strengthSets: mirroredStrengthSets",
            "excludedIntervals: mirroredExcludedIntervals",
            "strengthSets: record.strengthSets",
            "excludedIntervals: record.excludedIntervals",
            "func checkpointCurrentSession(label: String,",
            "strengthSets: [LoggedSet] = []",
            "func snapshotSession(label: String,",
            "let activeSamples = AtriaStrengthLog.samplesExcludingIntervals(session,",
            "Metrics.activeCalories(activeSamples,",
            "strengthSets: strengthSets.isEmpty ? nil : strengthSets",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "@Binding var loggedSets: [LoggedSet]",
            "@Binding var excludedIntervals: [ExcludedInterval]",
            "let strengthHistorySessions: [SavedSession]",
            "@State private var showSetLogger = false",
            "@State private var editingSetID: UUID?",
            "@State private var pauseStartedAt: Date?",
            "@State private var latestPRSetID: UUID?",
            "strengthLoggerCard",
            "pauseResumeCard",
            "let onMinimize: () -> Void",
            'Image(systemName: "chevron.down")',
            "onMinimize()\n                dismiss()",
            ".accessibilityLabel(\"Minimize workout\")",
            "Button {\n                primeLoggerFromLastSet()",
            'Label("Log set", systemImage: "plus.circle.fill")',
            'Label(isPaused ? "Resume workout" : "Pause workout"',
            'systemImage: isPaused ? "play.circle.fill" : "pause.circle.fill"',
            # Pin migrated 2026-07-06 (scroll-trap pass): the set-logger sheet
            # gained a `.large` detent and its body was wrapped in a ScrollView
            # so the primary "Save set" button can never clip off the fixed
            # 390pt sheet under Dynamic Type.
            ".presentationDetents([.height(390), .large])",
            "private var setLoggerSheet: some View",
            "exerciseHistoryPanel",
            'Label("History", systemImage: "chart.xyaxis.line")',
            'Label("New PR", systemImage: "sparkles")',
            "loggerStepperRow(title: \"Weight\"",
            "loggerStepperRow(title: \"Reps\"",
            "loggerStepperRow(title: \"Rest\"",
            "value: restOverrideText(loggerRestSeconds)",
            "decrement: { updateRestOverride(max(30, loggerRestSeconds - 15)) }",
            "increment: { updateRestOverride(min(600, loggerRestSeconds + 15)) }",
            "let fallback = Array(AtriaWorkoutExerciseCatalog.groups.flatMap(\\.exercises).prefix(8))",
            "return Array((options.isEmpty ? fallback : options).prefix(12))",
            "private func saveLoggedSet()",
            "let isNewPR = AtriaStrengthLog.isPR(set, against: personalRecordsIncludingCurrentWorkout(for: selectedExercise))",
            "loggedSets.append(set)",
            "loggedSets[index] = set",
            "latestPRSetID = isNewPR ? set.id : nil",
            "UIImpactFeedbackGenerator(style: isNewPR ? .heavy : .light).impactOccurred()",
            "private func editLoggedSet(_ set: LoggedSet)",
            "editingSetID = set.id",
            "private func deleteLoggedSet(_ set: LoggedSet)",
            "loggedSets.removeAll { $0.id == set.id }",
            'Image(systemName: "trash.circle.fill")',
            'Label(editingSetID == nil ? "Save set" : "Update set", systemImage: "checkmark.circle.fill")',
            "restTimerEndsAt = Date().addingTimeInterval(restSeconds(for: selectedExercise))",
            "private func updateRestOverride(_ seconds: TimeInterval)",
            "AtriaStrengthLog.setRestSeconds(seconds, for: selectedExercise)",
            "private func restOverrideText(_ seconds: TimeInterval) -> String",
            "private func mirrorLoggedSetsToActiveJournal()",
            "private var effectiveExcludedIntervals: [ExcludedInterval]",
            "private func toggleWorkoutPause()",
            "private func finalizePauseIfNeeded(now: Date = Date())",
            "excludedIntervals.append(ExcludedInterval(start: started, end: end))",
            "finalizePauseIfNeeded()",
            "private func personalRecordsIncludingCurrentWorkout(for exercise: String) -> StrengthPersonalRecords",
            "private var currentStrengthSession: [SavedSession]",
            'ProcessInfo.processInfo.arguments.contains("--atria-open-set-logger")',
            "applyDebugWorkoutFixtureIfNeeded(arguments: ProcessInfo.processInfo.arguments)",
            "private func applyDebugWorkoutFixtureIfNeeded(arguments: [String])",
            'fixture == "live-workout-set-saved"',
            'fixture == "live-workout-paused"',
            "latestPRSetID = loggedSets.last?.id",
            "restTimerEndsAt = Date().addingTimeInterval(91)",
            "pauseStartedAt = Date().addingTimeInterval(-74)",
        ]:
            assert_contains(self, live_workout, needle)
        assert_not_contains(self, live_workout, "TextField(")

        for needle in [
            "@State private var liveWorkoutLoggedSets: [LoggedSet] = []",
            "@State private var liveWorkoutExcludedIntervals: [ExcludedInterval] = []",
            "@State private var liveWorkoutMinimized = false",
            ".fullScreenCover(isPresented: liveWorkoutPresentationBinding)",
            "private var liveWorkoutPresentationBinding: Binding<Bool>",
            "workoutSession != nil && !liveWorkoutMinimized",
            "private func reopenMinimizedWorkout()",
            "liveWorkoutMinimized = false",
            "strengthHistorySessions: store.sessions",
            "loggedSets: $liveWorkoutLoggedSets",
            "excludedIntervals: $liveWorkoutExcludedIntervals",
            "onMinimize: { liveWorkoutMinimized = true }",
            "strengthSets: liveWorkoutLoggedSets",
            "excludedIntervals: liveWorkoutExcludedIntervals",
            "strengthSets: strengthSets,\n                                                        excludedIntervals: excludedIntervals)",
            "strengthSets: strengthSets,\n                                                        excludedIntervals: excludedIntervals)",
            "liveWorkoutLoggedSets = []",
            "liveWorkoutExcludedIntervals = []",
            "AtriaLiveTabAccessory(liveStore: model.coreLiveStore,",
            "workoutStart: workoutSession?.start",
            "onOpenWorkout: reopenMinimizedWorkout",
            "Text(elapsedText(context.date, since: workoutStart))",
            "Text(pulseStore.state.heartRate > 0 ? \"\\(pulseStore.state.heartRate) bpm\" : \"-- bpm\")",
            "Text(String(format: \"%.1f strain\", strain))",
            "Live workout minimized. Tap to return.",
            "Self.debugWorkoutLoggedSets(arguments: ProcessInfo.processInfo.arguments)",
            "Self.debugWorkoutExcludedIntervals(arguments: ProcessInfo.processInfo.arguments)",
            "Self.debugShowsMinimizedWorkout(arguments: ProcessInfo.processInfo.arguments)",
            "if Self.debugShowsMinimizedWorkout(arguments: ProcessInfo.processInfo.arguments) {\n            return true\n        }",
            '["live-workout-set-saved", "live-workout-minimized"].contains(debugLaunchFixtureValue(arguments: arguments) ?? "")',
            "LoggedSet(exercise: \"Barbell bench press\"",
            'debugLaunchFixtureValue(arguments: arguments) == "live-workout-paused"',
            'debugLaunchFixtureValue(arguments: arguments) == "live-workout-minimized"',
            "var strengthSets: [LoggedSet] = []",
            "var strengthHistorySessions: [SavedSession] = []",
            "let strengthSets: [LoggedSet]",
            "strengthHistorySessions: store.sessions",
            "strengthSets: result.strengthSets",
            "personalRecord: workoutSharePersonalRecord()",
            "private func workoutSharePersonalRecord() -> AtriaWorkoutShareSnapshot.PersonalRecord?",
            "AtriaStrengthLog.personalRecords(for: set.exercise,",
            "AtriaStrengthLog.isPR(set,",
            "private func strengthSetShareText(_ set: LoggedSet) -> String",
            "private static func formatShareWeightKg(_ weightKg: Double) -> String",
            "strengthSets: draft.strengthSets",
            "summaryExerciseHistorySection",
            "private var summaryExerciseHistoryRows: [AtriaWorkoutSummaryExerciseHistory]",
            "AtriaStrengthLog.history(for: exercise, in: draft.strengthHistorySessions)",
            "AtriaWorkoutSummarySparkline(values: row.sparklineValues, tint: .orange)",
            'Label("Exercise history", systemImage: "chart.xyaxis.line")',
            "private struct AtriaWorkoutSummaryExerciseHistory: Identifiable",
            "private struct AtriaWorkoutSummarySparkline: View",
            "let currentPRSet: LoggedSet?",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func testStrengthLogEpleyAndPRDetectionAreStrict()",
            "XCTAssertNil(AtriaStrengthLog.estimatedOneRepMax(weightKg: 80, reps: 13))",
            "equal set is not a PR",
            "func testSavedSessionTRIMPExcludesPausedIntervals()",
            "func testSavedSessionPauseExcludesCaloriesAndZones()",
            "func testStrengthLogRestOverridesClampAndPersistPerExercise()",
        ]:
            assert_contains(self, tests, needle)

    def test_cd13_nutrition_health_context_foundation_exists(self):
        nutrition = source(ROOT / "Atria" / "Atria" / "AtriaNutritionContext.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        rollups = source(ROOT / "Atria" / "Atria" / "DailyRollupStore.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")
        info = source(ROOT / "Atria" / "Info.plist")

        for needle in [
            "struct AtriaNutritionSummary: Codable, Equatable",
            "var kcal: Double?",
            "var proteinG: Double?",
            "var lastCaffeineHour: Int?",
            "var alcoholDrinks: Double?",
            "func autoJournalTags(bodyMassKg: Double?) -> Set<BehaviorJournalEntry.Tag>",
            "alcoholDrinks >= 1",
            "lastCaffeineHour >= 14",
            "proteinG >= 1.6 * bodyMassKg",
            "static let healthReadNutritionKey = \"atria.health.readNutrition\"",
        ]:
            assert_contains(self, nutrition, needle)

        for needle in [
            "static let nutritionReadIdentifiers: [HKQuantityTypeIdentifier]",
            ".dietaryEnergyConsumed",
            ".dietaryProtein",
            ".dietaryCarbohydrates",
            ".dietaryFatTotal",
            ".dietaryWater",
            ".dietaryCaffeine",
            ".numberOfAlcoholicBeverages",
            ".bodyMass",
            "func requestNutritionReadAuthorizationIfEnabled",
            "store.requestAuthorization(toShare: [], read: readTypes)",
            "func fetchNutritionSummary(for day: Date",
            "completion: @escaping (AtriaNutritionSummary?, Double?) -> Void",
            "HKStatisticsQuery(quantityType: type",
            "where identifier != .bodyMass",
            "HKSampleQuery(sampleType: bodyMassType",
            "HKQuery.predicateForSamples(withStart: nil, end: end, options: .strictEndDate)",
            ".doubleValue(for: .gramUnit(with: .kilo))",
            "HKSampleQuery(sampleType: caffeineType",
            "AtriaNutritionContext.summaryFromHealthKit(",
            "body_mass_kg=%@",
            "private nonisolated static func nutritionValue(quantity: HKQuantity",
        ]:
            assert_contains(self, healthkit, needle)

        for needle in [
            "@AtriaDefault(AtriaNutritionContext.healthReadNutritionKey) private var useHealthNutrition = false",
            "Toggle(isOn: $useHealthNutrition)",
            "Use nutrition from Apple Health",
            "onNutritionHealthToggle: { store.requestNutritionReadAuthorizationIfEnabled() }",
            '"recovery-detail", "recovery-detail-nutrition", "hrv-detail"',
        ]:
            assert_contains(self, settings + home, needle)

        for needle in [
            "var nutrition: AtriaNutritionSummary?",
            "try container.encodeIfPresent(nutrition, forKey: .nutrition)",
            "case protein",
            "case .protein: return \"Protein target\"",
            "var healthAutoTags: [Tag]",
            "static let autoTagRemovalsKey = \"atria.journal.autoTagRemovals.v1\"",
            "healthBodyMassKg: Double?",
            "let proteinBodyMassKg = healthBodyMassKg ?? (profile.weightKg > 0 ? profile.weightKg : nil)",
            "applyNutritionAutoTags(summary.autoJournalTags(bodyMassKg: proteinBodyMassKg)",
            "body_mass_source=%@",
            "private func applyNutritionAutoTags(_ tags: Set<BehaviorJournalEntry.Tag>",
            "rememberRemovedNutritionAutoTag(tag, day: entry.day, calendar: calendar)",
            "forgetRemovedNutritionAutoTag",
            "let latestNutrition: AtriaNutritionSummary?",
            ".compactMap(\\.nutrition)",
            "if let nutrition = preparedHistory.latestNutrition",
            "private func fuelContributorRow(for nutrition: AtriaNutritionSummary) -> AtriaMetricContributorRow",
            'name: "Fuel"',
            'systemImage: "fork.knife.circle.fill"',
            "private func fuelContributorComparison(for nutrition: AtriaNutritionSummary) -> String",
            "from Apple Health nutrition",
            "private func fuelContributorDirection(for nutrition: AtriaNutritionSummary) -> Int",
            '.accessibilityIdentifier("recovery-fuel-contributor-row")',
            "private var debugMetricDetailRollups: [DailyRollupStoreEntry]?",
            "debugMetricDetailRollups ?? dailyRollupHistory",
            "private static func debugShowsNutritionRecoveryDetail(arguments: [String]) -> Bool",
            '"recovery-detail-nutrition"',
            "rollups[0].nutrition = AtriaNutritionSummary(kcal: 2140",
            "debugHighlightRollups(includeNutrition: Self.debugShowsNutritionRecoveryDetail",
            "private static func debugHighlightRollups(includeNutrition: Bool = false)",
            "func testNutritionSummaryAutoTagsAndFuelSummary()",
            "func testDailyRollupNutritionRoundTripsAsOptionalContext()",
            "func testNutritionSummaryBuilderDropsZeroesAndCapturesCaffeineHour()",
            "func testBehaviorJournalEntryDefaultsMissingHealthAutoTags()",
            "refreshNutritionRollupFromHealthIfEnabled(for: Date(), reason: \"daily_rollup\")",
            "refreshNutritionRollupFromHealthIfEnabled(for: Date(), reason: \"nutrition_authorization\")",
            "private static let nutritionEveningRefreshLastDayKey = \"atria.health.nutrition.eveningRefreshLastDay\"",
            "scheduleEveningNutritionRefreshIfNeeded()",
            "guard minutes >= 21 * 60 else",
            "reason: \"evening_21h\"",
            "private func upsertNutritionRollup(_ summary: AtriaNutritionSummary",
            "dailyRollupStore.upsert(merged)",
            "to use nutrition samples from your food app as recovery context",
        ]:
            assert_contains(self, rollups + sessions + tests + info + overview + today, needle)

        for needle in [
            "healthAutoTags: todayEntry.healthAutoTags",
            "heart.text.square.fill",
            "from Health",
        ]:
            assert_contains(self, overview, needle)
        contributor_card = overview[overview.index("private var contributorCard: some View"):overview.index("private func fuelContributorRow")]
        self.assertLess(contributor_card.index("fuelContributorRow(for: nutrition)"),
                        contributor_card.index("AtriaRecoveryContributorMap(contributors: recoveryEstimate.contributors"))

    def test_cd14_raw_export_zip_schema_and_package_builder_exist(self):
        zip_writer = source(ROOT / "Atria" / "Atria" / "AtriaZipWriter.swift")
        raw_export = source(ROOT / "Atria" / "Atria" / "AtriaRawExport.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        strap = source(ROOT / "Atria" / "Atria" / "AtriaStrapScreen.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")
        schema = source(ROOT / "docs" / "export-schema.md")

        for needle in [
            "struct AtriaZipWriter",
            "mutating func addEntry(name: String, write: (FileHandle) throws -> Void) throws",
            "mutating func finalize() throws",
            "0x04034b50",
            "0x02014b50",
            "0x06054b50",
            "private static func crc32(_ data: Data) -> UInt32",
            "0xedb8_8320",
        ]:
            assert_contains(self, zip_writer, needle)

        for needle in [
            "enum AtriaRawExport",
            "static let schemaVersion = 1",
            'static let schemaHeader = "schemaVersion: 1"',
            "struct ExportTelemetry: Equatable",
            "private(set) var peakResidentBytes: UInt64",
            "var peakResidentKilobytes: Int",
            "static func currentResidentBytes() -> UInt64",
            "mach_task_basic_info()",
            "task_info(mach_task_self_",
            'try writer.addEntry(name: "hr.csv")',
            'try writer.addEntry(name: "rr.csv")',
            "var telemetry = ExportTelemetry(peakResidentBytes: ExportTelemetry.currentResidentBytes())",
            "if count.isMultiple(of: 1_000) { telemetry.sample() }",
            "return telemetry",
            "private static func writeHRCSV(sessions: [SavedSession],",
            "private static func writeRRCSV(sessions: [SavedSession],",
            'progress?("hr.csv", count)',
            'progress?("rr.csv", count)',
            'try writer.addEntry(name: "sleeps.json"',
            'try writer.addEntry(name: "workouts.json"',
            'try writer.addEntry(name: "rollups.json"',
            'try writer.addEntry(name: "SCHEMA.md"',
            "func exportRawDataPackage() -> URL?",
            "func exportRawDataPackageFromLaunchIfRequested",
            'arguments.contains("--atria-export-raw-package")',
            "private func exportRawDataPackageFromPersistedFiles() -> URL?",
            "try Data(contentsOf: sourceURL)",
            "try JSONDecoder().decode([SavedSession].self, from: data)",
            "ATRIADBG raw_export_disk status=ok",
            "memory_peak_kb=%d",
            "telemetry.peakResidentKilobytes",
            "func scheduleRawDataPackageFromLaunchIfRequested",
            "Task.detached(priority: .utility)",
            "ATRIADBG raw_export_disk_async status=ok",
            "store.scheduleRawDataPackageFromLaunchIfRequested(arguments: arguments)",
            "store.exportRawDataPackageFromLaunchIfRequested(arguments: arguments)",
            "Documents/atria-raw-exports/",
            "func testRawExportPackageContainsFullResolutionRowsAndSchema()",
            "var streamedProgress: [(String, Int)] = []",
            "let telemetry = try AtriaRawExport.writePackage(to: url,",
            "XCTAssertGreaterThan(telemetry.peakResidentBytes, 0)",
            "XCTAssertGreaterThan(telemetry.peakResidentKilobytes, 0)",
            'streamedProgress.filter { $0.0 == "hr.csv" }',
            'streamedProgress.filter { $0.0 == "rr.csv" }',
            "let backupRawExport = SessionBackupRawExport(",
            "let decodedBackup = try JSONDecoder().decode(SessionBackupEnvelope.self, from: backupData)",
            "decodedBackup.rawExport?.schemaHeader",
        ]:
            assert_contains(self, raw_export + sessions + app + tests, needle)

        write_package_body = raw_export[raw_export.index("static func writePackage"):raw_export.index("static func hrRows")]
        assert_not_contains(self, write_package_body, "hrRows(sessions:")
        assert_not_contains(self, write_package_body, "rrRows(sessions:")

        for needle in [
            "@State private var rawExportURL: URL?",
            "@State private var rawExportInProgress = false",
            "AtriaStrapStatusRow(title: \"Ownership\"",
            "rawExportRow",
            "Text(\"Export everything\")",
            "ProgressView()",
            "ShareLink(item: rawExportURL)",
            "store.exportRawDataPackage()",
            "private func exportRawDataPackageForSharing()",
            "prepareRawExportFixtureIfNeeded()",
            "debugShowsRawExportReadyFixture",
            'arguments[valueIndex] == "raw-export-ready"',
        ]:
            assert_contains(self, strap, needle)

        self.assertTrue(schema.startswith("schemaVersion: 1"))
        self.assertTrue(raw_export.index("static let schemaHeader = \"schemaVersion: 1\"") < raw_export.index("static let schemaDocument"))
        assert_contains(self, schema, "## hr.csv")
        assert_contains(self, schema, "## rr.csv")

    def test_cd15_ai_coach_payload_receipt_and_fabrication_guard_exist(self):
        coach = source(ROOT / "Atria" / "Atria" / "AtriaAICoach.swift")
        card = source(ROOT / "Atria" / "Atria" / "AtriaAICoachCard.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "struct AtriaCoachPayload: Codable, Equatable",
            "struct VitalRange: Codable, Equatable",
            "let today: DailyRollupStoreEntry?",
            "let last7: [DailyRollupStoreEntry]",
            "let now: String",
            "let weekday: String",
            "let units: String",
            "let baselines: [String: VitalRange]",
            "static let systemPrompt = \"Answer ONLY from DATA.",
            "var receiptSummary: String",
            "var auditLines: [String]",
            "\"Days sent: \\(last7.count)\"",
            "static func fromRollups(rollups: [DailyRollupStoreEntry]",
            "timeZone: TimeZone = .current",
            "last7 = Array(sorted.prefix(7))",
            "now: localISO8601(now, timeZone: timeZone)",
            "weekday: weekdayString(now, calendar: calendar, timeZone: timeZone)",
            "enum AtriaCoachProviderRequestBuilder",
            "struct RequestPreview: Equatable",
            "static func requestBody(provider: AtriaAICoachSettings.CloudProvider",
            "static func requestPreview(provider: AtriaAICoachSettings.CloudProvider",
            "static func defaultModel(for provider: AtriaAICoachSettings.CloudProvider) -> String",
            "private static func openAIResponsesBody(model: String",
            "private static func claudeMessagesBody(model: String",
            "let instructions: String",
            "let system: String",
            "case maxOutputTokens = \"max_output_tokens\"",
            "case maxTokens = \"max_tokens\"",
            "\"gpt-4.1-mini\"",
            "\"claude-3-5-haiku-latest\"",
            "\"No cloud request was sent. \\(preview.payloadLine)\"",
            "request preview ready",
            "\"DATA:\\n\\(try payloadJSON(payload))\"",
            "static func fabricationFlags(response: String, payload: AtriaCoachPayload) -> [String]",
            "let pattern = #\"([0-9]+",
            "%|percent|bpm|ms|kcal|steps?|kg|lbs?",
            "func answer(payload: AtriaCoachPayload, context: AtriaCoachContext) async -> AtriaCoachAnswer",
        ]:
            assert_contains(self, coach, needle)

        for needle in [
            "let preparedPayload: AtriaCoachPayload?",
            "@State private var payload: AtriaCoachPayload?",
            "@State private var fabricationFlags: [String] = []",
            "@State private var showsPayloadAudit = false",
            "showsPayloadAudit = true",
            "Text(payload.receiptSummary)",
            "AtriaCoachPayloadAuditSheet(payload: payload)",
            "private struct AtriaCoachPayloadAuditSheet: View",
            "ForEach(Array(payload.auditLines.enumerated()), id: \\.offset)",
            ".textSelection(.enabled)",
            "Contains figures not from your data",
            "let sentPayload = preparedPayload ?? AtriaCoachPayload.legacy(context: context)",
            "debugShowsFlaggedReplyFixture",
            "debugShowsPayloadAuditFixture",
            'arguments[valueIndex] == "ai-coach-audit"',
            "Your RHR was 49 bpm.",
            "AtriaCoachPayload.fabricationFlags(response:",
        ]:
            assert_contains(self, card, needle)

        for needle in [
            "AtriaAICoachCard(context: coachContext",
            "preparedPayload: coachPayload",
            "private var coachContext: AtriaCoachContext",
            "private var coachPayload: AtriaCoachPayload",
            "AtriaCoachPayload.fromRollups(rollups: Array(highlightRollups.prefix(7))",
            "private var effectiveAICoachSettings: AtriaAICoachSettings",
            "private var debugShowsAICoachOnly: Bool",
            "debugShowsAICoachLocalFixture",
            '["ai-coach-local", "ai-coach-flagged", "ai-coach-audit"].contains(arguments[valueIndex])',
            '"ai-coach-flagged"',
        ]:
            assert_contains(self, today, needle)
        assert_not_contains(self, today, 'AtriaTodayInfoRow(title: "AI coach"')

        for needle in [
            "func testCoachPayloadReceiptAndFabricationGuard()",
            "Recovery 64 %",
            "Sleep 7:42",
            "AtriaCoachPayload.fromRollups(rollups: [older, today]",
            "XCTAssertEqual(rollupPayload.last7.map(\\.recovery), [64, 72])",
            "XCTAssertTrue(rollupPayload.auditLines.contains(\"Days sent: 2\"))",
            "AtriaCoachProviderRequestBuilder.requestBody(provider: .openAI",
            "AtriaCoachProviderRequestBuilder.requestBody(provider: .claude",
            "AtriaCoachProviderRequestBuilder.requestPreview(provider: .openAI",
            "XCTAssertTrue(openAIPreview.summary.contains(\"gpt-4.1-mini\"))",
            "XCTAssertTrue(openAIPreview.payloadLine.contains(\"Recovery 64 %\"))",
            'TimeZone(identifier: "America/Los_Angeles")',
            'TimeZone(identifier: "Asia/Kolkata")',
            'XCTAssertEqual(laPayload.weekday, "Wednesday")',
            'XCTAssertEqual(kolkataPayload.weekday, "Thursday")',
            "XCTAssertEqual(openAI[\"instructions\"] as? String, AtriaCoachProviderRequestBuilder.systemPrompt(for: rollupPayload))",
            "XCTAssertEqual(claude[\"system\"] as? String, AtriaCoachProviderRequestBuilder.systemPrompt(for: rollupPayload))",
            "let openAIText = try XCTUnwrap(openAIContent.first?[\"text\"] as? String)",
            "let claudeText = try XCTUnwrap(claudeContent.first?[\"text\"] as? String)",
            "XCTAssertTrue(openAIText.hasPrefix(\"DATA:\\n{\"))",
            "Your RHR was 49 bpm.",
            "[\"49 bpm\"]",
        ]:
            assert_contains(self, tests, needle)

    def test_sleep_validation_reuses_aggregate_candidates(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        logger = re.search(
            r"private func logSleepValidation\(label: String\?\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        assert_contains(self, body, "let aggregateSleepCandidatesForValidation = label == nil ? aggregateSleepCandidates(rest: rest, calendar: calendar) : []")
        assert_contains(self, body, "logSleepValidationCandidateMatrix(candidates: aggregateSleepCandidatesForValidation)")
        assert_contains(self, body, "let aggregate = aggregateSleepCandidatesForValidation.first")
        assert_contains(self, body, "aggregateSleepCandidatesForValidation.count")
        self.assertEqual(body.count("aggregateSleepCandidates(rest: rest, calendar: calendar)"), 1)

        matrix = re.search(
            r"private func logSleepValidationCandidateMatrix\(candidates: \[AggregateSleepCandidate\],\n                                                   maxRows: Int = 6\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(matrix)
        matrix_body = matrix.group("body")
        for needle in [
            "ATRIADBG sleep_candidate_matrix candidates=%d emitted=%d ready_candidates=%d preferred_kind=%@ preferred_start=%@ preferred_end=%@ policy=review_before_recovery",
            "Self.preferredSleepCandidateForReview(from: candidates)",
            "Self.isStrongAutoConfirmableSleepCandidate(candidate)",
            "ATRIADBG sleep_candidate rank=%d selected=%d kind=%@ source=%@ duration_s=%.0f span_s=%.0f max_gap_s=%.0f",
            "auto_confirmable=%d",
            "blocker=%@",
            "historical_motion_reason=%@",
            "historical_motion_nearest_separation_s=%d",
        ]:
            assert_contains(self, matrix_body, needle)

    def test_launch_notification_diagnostics_avoid_synchronous_sleep_snapshot_refresh(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        scheduler = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        assert_not_contains(self, sessions, "func refreshHistorySnapshotForLaunchDiagnostics(reason: String)")
        assert_not_contains(self, sessions, "refreshHistorySnapshotCache(deferred: false)")
        assert_not_contains(self, app, "refreshHistorySnapshotForLaunchDiagnostics")
        assert_not_contains(self, scheduler, "refreshHistorySnapshotForLaunchDiagnostics")
        for needle in [
            "private static func sleepReviewUnavailableReason(snapshot: SleepHistorySnapshot,",
            "let evidence = store.sleepEvidenceStatusFast(rest: rest)",
            'return "sleep_candidate_waiting_history_snapshot"',
            'return "sleep_candidate_pending_validation_\\(evidence.blocker)"',
            'return "no_unconfirmed_sleep_candidate"',
        ]:
            assert_contains(self, scheduler, needle)

    def test_historical_clock_responses_route_through_legacy_parser(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        harness = source(ROOT / "live_device_debug.sh")

        for needle in [
            "case 0x24:\n            handleCommandResponsePayload(payload)",
            "handleUnknownProtocolPayload(payload, fullFrame: b)",
            "private func handleCommandResponsePayload(_ payload: [UInt8])",
            "logClockCommandResponse(payload)",
            "logDataRangeCommandResponse(payload)",
            "handleCommandResponsePayload([UInt8](frame.payload))",
            "ATRIADBG historyClock status=get_clock_response",
            "clock_effective_unix7=%u",
            "clock_effective_age_s=%@",
            "clock_recent_12h=%d",
        ]:
            assert_contains(self, ble, needle)

        self.assertLess(
            ble.index("case 0x24:\n            handleCommandResponsePayload(payload)"),
            ble.index("guard payload.first == Packet.realtime, payload.count >= 10 else"),
        )

        for needle in [
            '"history_clock_set_responses": 0',
            '"history_clock_get_responses": 0',
            '"sleep_validation_fail_closed": False',
            "cmd_response_payloads_seen: set[str] = set()",
            "def ingest_cmd_response_payload(payload_hex: str) -> None:",
            "def parse_history_clock_response(line: str) -> None:",
            'tokens_after("ATRIADBG historyClock", line)',
            'rr_summary["history_clock_get_responses"] += 1',
            'rr_summary["history_clock_last_drift_s"] = tokens.get("drift_s", "")',
            'ingest_cmd_response_payload(tokens.get("payload", ""))',
            '"ATRIADBG sleep_validation status=deferred" in line',
            '"reason=sleep_motion_unvalidated_historical_stale" in line',
            'flags["sleep_validation_fail_closed"] = True',
            'if verify_sleep and not flags["sleep_validation_complete"] and not flags["sleep_validation_fail_closed"]',
        ]:
            assert_contains(self, harness, needle)

    def test_morning_journal_uses_cached_sleep_and_explicit_confirm(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")

        for needle in [
            "AtriaOverviewMorningJournalHost(snapshotStore: snapshotStore,",
            "struct AtriaOverviewMorningJournalHost: View",
            "@State private var adjustmentNight: SleepHistorySnapshot.Night?",
            "let sleepHistory = debugFixtureSleepHistory ?? store.sleepHistorySnapshot",
            "AtriaOverviewMorningJournalCard(snapshot: snapshotStore.state,",
            "sleepHistory: sleepHistory",
            "todayEntry: store.behaviorJournalEntry()",
            "taggedDays: store.behaviorJournalEntries.count",
            "store.toggleBehaviorTag(tag)",
            "if let night = sleepHistory.latest",
            "store.confirmSleepHistoryNightForUI(night,",
            'source: "morning_journal"',
            "onAdjustSleep: {",
            "adjustmentNight = sleepHistory.latest",
            "AtriaManualSleepSheet(initialStart: adjustment.start,",
            "initialIsNap: adjustment.isNapEvidence",
            'source: "morning_journal_adjust"',
            "struct AtriaOverviewMorningJournalCard: View, Equatable",
            'AtriaPanelSectionHeader(title: "Morning journal", subtitle: "")',
            "guard sleepHistory.candidateCount > 0 else { return false }",
            "return latestNight?.confirmed != true",
            'private var sleepReviewTitle: String',
            'private var sleepReviewValue: String',
            'private var sleepReviewState: AtriaMetricState',
            "private struct AtriaJournalSleepFact: Identifiable, Equatable",
            "private var sleepActionText: String",
            "private var sleepMetricFacts: [AtriaJournalSleepFact]",
            "private var selectedTags: [BehaviorJournalEntry.Tag]",
            "@State private var showsAllJournalTags = false",
            "private var visibleJournalTags: [BehaviorJournalEntry.Tag]",
            "let quick: [BehaviorJournalEntry.Tag] = [.sleep, .training, .caffeine]",
            "guard !showsAllJournalTags else { return BehaviorJournalEntry.Tag.allCases }",
            "private var hiddenJournalTagCount: Int",
            "private var morningJournalStackRail: some View",
            "journalPathStep(systemImage: latestNight?.isNapEvidence == true ? \"moon.zzz.fill\" : \"bed.double.fill\"",
            "journalPathStep(systemImage: \"tag.fill\"",
            "journalPathStep(systemImage: \"chart.xyaxis.line\"",
            "title: \"Links\"",
            "value: taggedDays > 0 ? \"Ready\" : \"Build\"",
            "Morning path: review sleep, tag today, and see habit links.",
            'Image(systemName: latestNight?.isNapEvidence == true ? "moon.zzz.fill" : "bed.double.fill")',
            "Text(sleepReviewTitle)",
            "Text(sleepActionText)",
            "Text(sleepReviewValue)",
            "AtriaStateBadge(state: sleepReviewState)",
            "LazyVGrid(columns: Self.sleepFactColumns, spacing: 8)",
            "sleepFactPill(fact)",
            "GlassEffectContainer(spacing: 10)",
            ".atriaInsetCard(tint: .cyan)",
            "facts.append(AtriaJournalSleepFact(title: \"Eff\", value: latestNight.sleepEfficiencyText))",
            "facts.append(AtriaJournalSleepFact(title: \"HRV\", value: latestNight.hrvText))",
            "facts.append(AtriaJournalSleepFact(title: \"Resp\", value: latestNight.respiratoryRateText))",
            "return Array(facts.prefix(3))",
            'Label("Adjust", systemImage: "slider.horizontal.3")',
            ".atriaCardAction(prominent: false, tint: .cyan)",
            'Label(latestNight?.isNapEvidence == true ? "Confirm nap" : "Confirm sleep",',
            "AtriaJournalTodayTagStrip(selectedTags: selectedTags,",
            "showsAllTags: showsAllJournalTags",
            "hiddenTagCount: hiddenJournalTagCount",
            "onToggleMore: {",
            "showsAllJournalTags.toggle()",
            "private struct AtriaJournalTodayTagStrip: View, Equatable",
            "let showsAllTags: Bool",
            "let hiddenTagCount: Int",
            "let onToggleMore: () -> Void",
            "static func == (lhs: AtriaJournalTodayTagStrip, rhs: AtriaJournalTodayTagStrip) -> Bool",
            'selectedTags.isEmpty ? "Tag today" : "\\(selectedTags.count) logged today"',
            'return taggedDays > 0',
            '"Tap what happened and Atria compares it locally."',
            'Text(showsAllTags ? "Less" : "+\\(hiddenTagCount)")',
            ".accessibilityLabel(showsAllTags ? \"Show fewer journal tags\" : \"Show \\(hiddenTagCount) more journal tags\")",
            "ForEach(selectedTags.prefix(4))",
            "ForEach(visibleJournalTags)",
        ]:
            assert_contains(self, overview, needle)

        morning_start = overview.index("struct AtriaOverviewMorningJournalCard")
        morning_end = overview.index("private struct AtriaJournalTodayTagStrip")
        morning_body = overview[morning_start:morning_end]
        ordered_needles = [
            "GlassEffectContainer(spacing: 10)",
            "LazyVGrid(columns: Self.sleepFactColumns, spacing: 8)",
            "morningJournalStackRail",
            "AtriaJournalTodayTagStrip(selectedTags: selectedTags,",
        ]
        last_index = -1
        for needle in ordered_needles:
            next_index = morning_body.index(needle)
            self.assertGreater(next_index, last_index, needle)
            last_index = next_index
        assert_not_contains(self, morning_body, '"Tags stay on device and power local insights."')
        assert_not_contains(self, morning_body, '"Impact"')
        assert_not_contains(self, morning_body, '"Local"')
        assert_not_contains(self, morning_body, '"Unlock"')
        assert_not_contains(self, morning_body, "Morning journal stack")
        assert_not_contains(self, morning_body, "local impact learning")
        assert_not_contains(self, morning_body, ".purple")

        for needle in [
            "#if DEBUG\n    private var debugFixtureSleepHistory: SleepHistorySnapshot?",
            "Self.debugFixtureSleepHistory(arguments: ProcessInfo.processInfo.arguments)",
            "private static func debugFixtureSleepHistory(arguments: [String]) -> SleepHistorySnapshot?",
            "arguments.firstIndex(of: \"--atria-ui-fixture\")",
            "[\"pending-sleep-review\", \"journal-impact\"].contains(arguments[valueIndex])",
            "SleepHistorySnapshot.Night(id: \"debug-ui-fixture-pending-sleep-review\"",
            "duration: 438 * 60",
            "restingHR: 54",
            "hrv: 72",
            "respiratoryRate: 14.6",
            "sleepEfficiency: 0.89",
            "confidence: \"debug_fixture_pending_review\"",
            "source: \"sleep_candidate\"",
            "confirmed: false",
            "return SleepHistorySnapshot(nights: [night], confirmedCount: 0, candidateCount: 1)",
            "#else\n    private var debugFixtureSleepHistory: SleepHistorySnapshot? { nil }\n    #endif",
        ]:
            assert_contains(self, overview, needle)

        morning_start = overview.index("struct AtriaOverviewMorningJournalCard")
        morning_end = overview.index("struct AtriaInsightsCardHost")
        morning_source = overview[morning_start:morning_end]
        morning_host_start = overview.index("struct AtriaOverviewMorningJournalHost")
        morning_host_end = overview.index("struct AtriaOverviewMorningJournalCard")
        morning_host_source = overview[morning_host_start:morning_host_end]
        debug_fixture_start = morning_host_source.index("private static func debugFixtureSleepHistory")
        debug_fixture_end = morning_host_source.index("#else")
        debug_fixture_source = morning_host_source[debug_fixture_start:debug_fixture_end]
        assert_not_contains(self, morning_host_source, "heroStore")
        assert_not_contains(self, debug_fixture_source, "SessionStore")
        assert_not_contains(self, debug_fixture_source, "UserDefaults")
        assert_not_contains(self, debug_fixture_source, "store.")
        assert_not_contains(self, debug_fixture_source, "confirmSleepHistoryNightForUI")
        assert_not_contains(self, debug_fixture_source, "toggleBehaviorTag")
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
            "AtriaMetricTile(label: \"Recovery\"",
            "AtriaMetricTile(label: \"HRV\"",
            "hero.hrvDetail",
            "parts.joined(separator:",
            "Text(sleepStatusText)",
        ]:
            assert_not_contains(self, morning_source, forbidden)

    def test_overview_segments_and_sleep_review_notifications_match_morning_flow(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")
        scheduler = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")

        for needle in [
            "enum AtriaTodaySegment: String, CaseIterable, Identifiable {",
            "case today",
            "case journal",
            "case trends",
            'case .journal: return "Journal"',
            "if segment == .journal && hasUnlockedSecondarySections {",
            "AtriaOverviewMorningJournalHost(snapshotStore: snapshotStore,",
            "AtriaOverviewBehaviorJournalSection(store: store)",
            "if segment == .trends && hasUnlockedSecondarySections {",
            "if segment == .trends {",
            "AtriaOverviewCollectionSectionHost(",
            "AtriaOverviewBackupSectionHost(",
            "struct AtriaOverviewTrendSection: View, Equatable",
            "private var trendHeadline: String",
            "History is ready",
            "History is building",
            "AtriaPanelSectionHeader(title: \"Trends\", subtitle: \"\")",
            "private var trendRangeLadder: some View",
            "ForEach([\"D\", \"W\", \"M\", \"3M\", \"6M\"], id: \\.self)",
            "Trend ranges. Day, week, month, 3 months, and 6 months.",
            "trendMetaChip(title: \"Direction\"",
            "trendMetaChip(title: \"Privacy\"",
            "private var trendStateText: String",
            "struct AtriaOverviewBackupSection: View, Equatable",
            "private var confirmedTotal: Int",
            "Text(\"Saved on device\")",
            "backupMetaChip(title: \"Workouts\"",
            "backupMetaChip(title: \"Sleeps\"",
            "backupMetaChip(title: \"State\"",
        ]:
            assert_contains(self, overview, needle)

        assert_not_contains(self, overview, "case .data")
        assert_not_contains(self, overview, "if segment == .data {")
        assert_not_contains(self, overview, "AtriaPanelSectionHeader(title: \"Trend\", subtitle: \"Local 90-day coverage\")")
        assert_not_contains(self, overview, "AtriaPanelSectionHeader(title: \"Backup\", subtitle: \"On-device safety net\")")
        trend_summary_start = overview.index("struct AtriaOverviewTrendSection: View, Equatable")
        trend_summary_end = overview.index("struct AtriaOverviewBehaviorJournalSection", trend_summary_start)
        trend_summary_source = overview[trend_summary_start:trend_summary_end]
        assert_contains(self, trend_summary_source, "trendRangeLadder")
        assert_not_contains(self, trend_summary_source, 'trendMetaChip(title: "Confidence"')
        assert_not_contains(self, trend_summary_source, 'trendMetaChip(title: "Source"')
        assert_not_contains(self, trend_summary_source, 'trendMetaChip(title: "Range"')
        assert_not_contains(self, trend_summary_source, 'value: "90d"')
        assert_not_contains(self, overview, "workouts and \\(snapshot.confirmedSleeps) sleeps are already confirmed on device")

        for needle in [
            "var sleepReview = true",
            "var workoutReview = true",
            "var morningSummary = true",
            "workoutReview = try container.decodeIfPresent(Bool.self, forKey: .workoutReview) ?? true",
            "morningSummary = try container.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? true",
            'case "sleep_review": return sleepReview',
            'case "workout_review": return workoutReview',
            'case "morning_summary": return morningSummary',
            'notificationToggle("Allow coach notifications", keyPath: \\.allowNotifications, prominent: true)',
            'notificationToggle("Sleep review", keyPath: \\.sleepReview)',
            'notificationToggle("Workout review", keyPath: \\.workoutReview)',
            'notificationToggle("Morning summary", keyPath: \\.morningSummary)',
        ]:
            assert_contains(self, notifications, needle)

        for needle in [
            'static let morningSummaryPrefix = "atria.morningSummary."',
            "static func scheduleMorningSummary(recovery: Int,",
            'kind: "morning_summary"',
            'title: "Morning summary"',
            'reason: "morning_summary_ready"',
            'categoryIdentifier: "atria.morningSummary"',
            'userInfo: ["deepLink": "atria://overview"]',
            'arguments.contains("--atria-test-morning-summary-notification")',
            'arguments.contains("--atria-test-morning-summary-toggle-off")',
            "private static func scheduleMorningSummaryDebugFixture",
            'ATRIADBG notification_fixture kind=morning_summary status=scheduled_input',
            'static let sleepReview = "atria.sleep.review"',
            'static let workoutReview = "atria.workout.review"',
            'private static let sleepReviewLastCandidateIDKey = "atria.notification.sleepReview.lastCandidateID"',
            'private static let sleepReviewCandidateScheduledAtPrefix = "atria.notification.sleepReview.scheduledAt."',
            'private static let sleepReviewCandidateScheduleCountPrefix = "atria.notification.sleepReview.scheduleCount."',
            "private static let sleepReviewReminderCooldown: TimeInterval = 4 * 60 * 60",
            "private static let sleepReviewMaximumSchedulesPerCandidate = 2",
            'private static let sleepReviewDismissedIDKey = "atria.sleepReview.dismissedID"',
            'private static let workoutReviewLastCandidateIDKey = "atria.notification.workoutReview.lastCandidateID"',
            'private static let workoutReviewDismissedIDKey = "atria.workoutReview.dismissedID"',
            "includeSleepReviewDecisions: Bool",
            "includeWorkoutReviewDecisions: Bool",
            "if includeSleepReviewDecisions {",
            "decisions.append(makeSleepReviewDecision(store: store))",
            "if includeWorkoutReviewDecisions {",
            "decisions.append(makeWorkoutReviewDecision(store: store, ble: ble))",
            "private static func makeSleepReviewDecision(store: SessionStore) -> NotificationDecision {",
            "let latestReviewNight = store.latestSleepReviewNightForUI(rest: store.baseline.restingInt ?? 60,",
            "let reviewableSnapshotNight = snapshot.latest?.confirmed == false ? snapshot.latest : nil",
            "guard let latest = latestReviewNight ?? reviewableSnapshotNight,",
            "if latest.id == defaults.string(forKey: sleepReviewLastCandidateIDKey) {",
            "let count = defaults.integer(forKey: sleepReviewCandidateScheduleCountPrefix + latest.id)",
            "let lastScheduledAt = defaults.double(forKey: sleepReviewCandidateScheduledAtPrefix + latest.id)",
            "guard count < sleepReviewMaximumSchedulesPerCandidate else",
            'reason: "candidate_reminder_limit_reached"',
            "guard elapsed >= sleepReviewReminderCooldown else",
            'reason: "candidate_reminder_cooldown"',
            "private static func makeWorkoutReviewDecision(store: SessionStore, ble: AtriaBLEManager) -> NotificationDecision {",
            "guard !reviewNotificationsProtectedByLiveCapture(ble: ble) else",
            "reason: \"live_capture_protected_range_loss_backfill\"",
            "private static func reviewNotificationsProtectedByLiveCapture(ble: AtriaBLEManager) -> Bool",
            "&& ble.rangeLossBackfillPending",
            "&& ble.sessionSampleCount > 0",
            "store.latestWorkoutReviewCandidate(rest: rest,",
            "let reason = sleepReviewUnavailableReason(snapshot: snapshot, store: store)",
            "private static func sleepReviewUnavailableReason(snapshot: SleepHistorySnapshot,",
            'kind: "sleep_review"',
            'kind: "workout_review"',
            "let title = sleepReviewNotificationTitle(for: latest)",
            "let body = sleepReviewNotificationBody(for: latest)",
            "title: workoutReviewNotificationTitle(for: candidate)",
            "body: workoutReviewNotificationBody(for: candidate)",
            "guard workoutReviewCandidateIsPushWorthy(candidate) else",
            "reason: \"candidate_visible_in_app_not_push_worthy\"",
            "private static func sleepReviewNotificationTitle(for night: SleepHistorySnapshot.Night) -> String",
            'night.isNapEvidence ? "Review your nap" : "Review last night"',
            "private static func sleepReviewNotificationBody(for night: SleepHistorySnapshot.Night) -> String {",
            'Confirm, adjust, or keep it separate.',
            'Confirm or adjust the timing.',
            'return "\\(night.durationText), \\(startText)-\\(endText). \\(action)"',
            'return "\\(night.durationText), ending \\(endText). \\(action)"',
            'return "\\(night.durationText). \\(action)"',
            "private static func workoutReviewNotificationBody(for candidate: WorkoutReviewCandidate) -> String {",
            "private static func workoutReviewNotificationTitle(for candidate: WorkoutReviewCandidate) -> String",
            'candidate.kind == .workout ? "Workout found" : "Effort found"',
            "private static func workoutReviewReviewHint(for candidate: WorkoutReviewCandidate) -> String",
            "private static func workoutReviewCandidateIsPushWorthy(_ candidate: WorkoutReviewCandidate) -> Bool",
            "candidate.isReviewPromptWorthy",
            'source: "notification")',
            "Confirm type or dismiss.",
            "Label it if it was training.",
            "Looks complete.",
            "Adjust if the timing is off.",
            "Review the window before saving.",
            "candidate.streamCoveragePercent >= 75, candidate.gapCount == 0",
            "candidate.streamCoveragePercent >= 60",
            'return "Strap heart-rate window \\(candidate.durationMinutes)m, \\(startText)-\\(endText). \\(reviewHint) \\(action)"',
            'return "sleep_candidate_pending_validation_\\(evidence.blocker)"',
            'reason: "candidate_\\(latest.id)"',
            'reason: "candidate_\\(candidate.id)"',
            'if decision.kind == "sleep_review",',
            "defaults.set(Date().timeIntervalSince1970, forKey: sleepReviewCandidateScheduledAtPrefix + id)",
            "defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)",
            'if decision.kind == "workout_review",',
            'notification_pending total=%d recovery=%d strain=%d sleep_review=%d workout_review=%d battery=%d bluetooth_off=%d diagnostic=%d morning_summary=%d health_deviation=%d unknown=%d',
        ]:
            assert_contains(self, scheduler, needle)

        assert_contains(self, app, "scheduleFastLaunchMorningSummaryDebugFixtureIfRequested(arguments: arguments)")

        for needle in [
            "scheduleMorningSummaryIfNeeded(metrics: metrics)",
            "private func scheduleMorningSummaryIfNeeded(metrics: [SavedDailyMetric],",
            "(4 * 60...(11 * 60 + 30)).contains(minutes)",
            "Self.morningSummaryLastScheduledDayKey",
            "AtriaDebugLog(\"ATRIADBG morning_summary_request status=scheduled",
        ]:
            assert_contains(self, sessions, needle)

    def test_feat6_morning_summary_notification_fixture_tokens_are_present(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")
        scheduler = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        harness = source(ROOT / "live_device_debug.sh")

        for needle in [
            "var morningSummary = true",
            "morningSummary = try container.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? true",
            'case "morning_summary": return morningSummary',
            'notificationToggle("Morning summary", keyPath: \\.morningSummary)',
        ]:
            assert_contains(self, notifications, needle)

        for needle in [
            'static let morningSummaryPrefix = "atria.morningSummary."',
            "static func scheduleMorningSummary(recovery: Int,",
            'kind: "morning_summary"',
            'title: "Morning summary"',
            'reason: "morning_summary_ready"',
            'categoryIdentifier: "atria.morningSummary"',
            'userInfo: ["deepLink": "atria://overview"]',
            "await logMorningSummaryPendingProof(identifier: identifier, center: center)",
            "private static func logMorningSummaryPendingProof(identifier: String,",
            'ATRIADBG notification_pending_detail kind=morning_summary id=%@ present=%d category=%@ deepLink=%@',
            'static let deepLinkNotification = Notification.Name("atria.notification.deepLink")',
            'let deepLink = request.content.userInfo["deepLink"] as? String',
            'ATRIADBG notification_deeplink status=posted kind=%@ url=%@',
            'NotificationCenter.default.post(name: Self.deepLinkNotification, object: url)',
            "static func scheduleFastLaunchMorningSummaryDebugFixtureIfRequested",
            'arguments.contains("--atria-test-morning-summary-notification")',
            'arguments.contains("--atria-test-morning-summary-toggle-off")',
            "private static func scheduleMorningSummaryDebugFixture",
            'ATRIADBG notification_fixture kind=morning_summary status=scheduled_input',
            'ATRIADBG notification_schedule status=skipped_toggle kind=morning_summary',
        ]:
            assert_contains(self, scheduler, needle)

        for needle in [
            "scheduleMorningSummaryIfNeeded(metrics: metrics)",
            "private func scheduleMorningSummaryIfNeeded(metrics: [SavedDailyMetric],",
            "(4 * 60...(11 * 60 + 30)).contains(minutes)",
            "Self.morningSummaryLastScheduledDayKey",
            "AtriaDebugLog(\"ATRIADBG morning_summary_request status=scheduled",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "NotificationDeliveryLogger.deepLinkNotification",
            "--atria-test-notification-deeplink-overview",
            "ATRIADBG notification_deeplink_fixture status=posted url=%@",
            "handleDeepLink(url)",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "scheduleFastLaunchMorningSummaryDebugFixtureIfRequested(arguments: arguments)",
            'arguments.contains("--atria-test-morning-summary-notification")',
            'arguments.contains("--atria-test-morning-summary-toggle-off")',
        ]:
            assert_contains(self, app, needle)
            assert_contains(self, debug_logging, needle) if needle.startswith('"--') else None
        for needle in [
            "--test-morning-summary-notification",
            "--test-morning-summary-toggle-off",
            "--atria-test-morning-summary-notification",
            "--atria-test-morning-summary-toggle-off",
        ]:
            assert_contains(self, harness, needle)

    def test_overview_trend_chart_points_are_cached_off_render_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        trend_chart = source(ROOT / "Atria" / "Atria" / "AtriaTrendChart.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "@Published private(set) var overviewTrendPoints: [AtriaTrendPoint] = []",
            "@Published private(set) var trainingLoadSummarySnapshot = TrainingLoadSummary.learning",
            "let monotony: Double?",
            "let readiness: String",
            "let acwrSignal: String",
            "let monotonySignal: String",
            "var acwrSignalText: String",
            "var monotonySignalText: String",
            "var acwrDetailText: String",
            "var monotonyDetailText: String",
            "var signalSummaryText: String",
            "private var overviewTrendPointsRevision = 0",
            "private var trainingLoadSummaryRevision = 0",
            "private func refreshOverviewTrendPointsCache(deferred: Bool = true)",
            "private func refreshTrainingLoadSummaryCache(deferred: Bool = true)",
            "DispatchQueue.global(qos: .utility).async",
            "Self.makeOverviewTrendPoints(sessions: source, rest: rest, maxHR: maxHR)",
            "Self.makeTrainingLoadSummary(sessions: source,",
            "private nonisolated static func makeOverviewTrendPoints(sessions: [SavedSession]",
            "private nonisolated static func makeTrainingLoadSummary(sessions: [SavedSession]",
            "AtriaAnalytics.TrainingLoad.summary(sessions: sessions,",
            "trainingLoadSummarySnapshot",
            "func trainingLoadSummary(rest: Int, maxHR: Int) -> TrainingLoadSummary {\n        trainingLoadSummarySnapshot\n    }",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "enum AtriaAnalytics",
            "enum Daily",
            "struct StrapStepSample: Equatable",
            "struct StrapStepSummary: Equatable",
            "static func stepsDaily(_ samples: [StrapStepSample]) -> StrapStepSummary",
            "struct HeartRateEnergySample: Equatable",
            "static func dayCalories(_ samples: [HeartRateEnergySample],",
            "private static func energyKcalPerMinute(heartRate: Int, profile: AthleteProfile) -> Double",
            "enum Strain",
            "enum TrainingLoad",
            "static func trimp(_ series: [(t: Double, bpm: Int)],",
            "sex: AthleteProfile.BiologicalSex",
            "static func banisterCoefficient(for sex: AthleteProfile.BiologicalSex) -> Double",
            "case .female: return 1.67",
            "case .male, .unspecified: return 1.92",
            "static func edwardsLoad(_ series: [(t: Double, bpm: Int)], rest: Int, max: Int) -> Double",
            "static func edwardsWeight(forHRReserve reserve: Double) -> Int",
            "struct MaxHeartRateZoneSeconds: Equatable",
            "static func maxHeartRateZoneSeconds(_ series: [(t: Double, bpm: Int)],",
            "static func maxHeartRateZoneRawValue(for bpm: Int, maxHR: Int) -> Int",
            "case 0.90...: return 5",
            "case 0.80..<0.90: return 4",
            "case 0.70..<0.80: return 3",
            "case 0.60..<0.70: return 2",
            "case 0.50..<0.60: return 1",
            "static func score(fromEdwardsLoad load: Double) -> Double",
            "static func summary(sessions: [SavedSession],",
            "static func summary(dailyStrains: [Double]) -> TrainingLoadSummary",
            ".map { Strain.score(fromTRIMP: $0.value) }",
            "let monotony = trainingMonotony(acuteRollups)",
            "static func trainingMonotony(_ dailyStrains: [Double]) -> Double?",
            "static func acwrReadinessSignal(ratio: Double?, enoughChronic: Bool) -> String",
            "static func monotonyReadinessSignal(monotony: Double?, enoughAcute: Bool) -> String",
            "static func trainingReadiness(acwrSignal: String,",
            "return \"rundown\"",
            "return \"strained\"",
            "return \"primed\"",
            "return \"balanced\"",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "typealias StrainZoneSummary = AtriaAnalytics.Strain.ZoneSummary",
            "typealias StrapStepSample = AtriaAnalytics.Daily.StrapStepSample",
            "typealias StrapStepSummary = AtriaAnalytics.Daily.StrapStepSummary",
            "typealias HeartRateEnergySample = AtriaAnalytics.Daily.HeartRateEnergySample",
            "AtriaAnalytics.Daily.stepsDaily(samples)",
            "AtriaAnalytics.Daily.dayCalories(samples, rest: rest, profile: profile)",
            "AtriaAnalytics.Strain.trimp(series, rest: rest, max: max)",
            "AtriaAnalytics.Strain.trimp(series, rest: rest, max: max, sex: sex)",
            "AtriaAnalytics.Strain.edwardsLoad(series, rest: rest, max: max)",
            "AtriaAnalytics.Strain.activeCalories(samples, rest: rest, profile: profile)",
            "typealias MaxHeartRateZoneSeconds = AtriaAnalytics.Strain.MaxHeartRateZoneSeconds",
            "AtriaAnalytics.Strain.maxHeartRateZoneSeconds(series, maxHR: maxHR, maxGap: maxGap)",
            "AtriaAnalytics.Strain.zoneSummary(series, rest: rest, max: max)",
            "AtriaAnalytics.Strain.score(fromTRIMP: trimp)",
            "AtriaAnalytics.Strain.score(fromEdwardsLoad: load)",
        ]:
            assert_contains(self, metrics, needle)

        for needle in [
            "let fixturePoints = debugFixtureTrendPoints",
            "AtriaTrendChartCard(points: fixturePoints ?? store.overviewTrendPoints,",
            "baselineRestingHR: fixturePoints == nil ? store.baseline.restingInt : 58",
            "#if DEBUG\n    static var debugShowsTrendFixture: Bool",
            "debugFixtureTrendPoints(arguments: ProcessInfo.processInfo.arguments) != nil",
            "private var debugFixtureTrendPoints: [AtriaTrendPoint]?",
            "private static func debugFixtureTrendPoints(arguments: [String]) -> [AtriaTrendPoint]?",
            "arguments.firstIndex(of: \"--atria-ui-fixture\")",
            "switch arguments[valueIndex]",
            "case \"trend-prior-comparison\":",
            "case \"trend-recovery-care\":",
            "return AtriaTrendPoint.recoveryCareSampleData(now: Date())",
            "static func recoveryCareSampleData(now: Date) -> [AtriaTrendPoint]",
            "AtriaTrendPoint.priorComparisonSampleData(now: Date())",
            "static var debugShowsTrendFixture: Bool { false }",
            "case day",
            "case sixMonths",
            "case .day: return 1",
            "case .sixMonths: return 180",
            'case .day: return "today"',
            'case .quarter: return "3 months"',
            'case .sixMonths: return "6 months"',
            'case .day: return "Day"',
            'case .quarter: return "3M"',
            'case .sixMonths: return "6M"',
            'case .day: return "D"',
            'case .quarter: return "3M"',
            "var headerLabel: String",
            'case .day: return "Today"',
            'default: return "Last \\(label)"',
            "case .strain: return Metrics.electricStrain",
            "func cutoffDate(now: Date = Date(), calendar: Calendar = .current) -> Date",
            "Picker(\"Range\", selection: $range)",
            "Text(item.segmentedLabel)",
            ".accessibilityLabel(item.menuLabel)",
            ".accessibilityLabel(chartAccessibilityLabel)",
            "private var chartAccessibilityLabel: String",
            "\\(prepared.series.count) days in view.",
            "Latest \\(summary.latestText), average \\(summary.averageText), range \\(summary.rangeText)",
            "private struct AtriaTrendPreparedSeries",
            "@State private var prepared = AtriaTrendPreparedSeries.empty",
            "@State private var periodReadout = AtriaTrendPeriodReadout.empty",
            "private static func prepareSeries(points: [AtriaTrendPoint]",
            "private static func preparePeriodReadout(points: [AtriaTrendPoint]",
            "let cutoff = range.cutoffDate(now: now)",
            # 2026-07-05: previousCutoff now gates on `range.hasPriorPeriod`
            # (see prepareSeries pin above) instead of unconditionally
            # subtracting `range.days`.
            "range.hasPriorPeriod",
            "previousSeries: previousSamples",
            "AtriaTrendRangeDock(selectedRange: $range,",
            "private struct AtriaTrendRangeDock: View",
            "Label(\"Ranges\", systemImage: \"calendar.badge.clock\")",
            "rangeNode(for: range)",
            "private func rangeStatusText(for range: AtriaTrendRange) -> String",
            "return \"\\(count) days in view\"",
            "return \"\\(count) days forming\"",
            "return count == 1 ? \"1 day started\" : \"\\(count) days started\"",
            "count > 0 ? \"\\(count)d\" : \"0d\"",
            "private func confidenceProgress(for range: AtriaTrendRange) -> CGFloat",
            "var confidenceTargetPoints: Int",
            "case .sixMonths: return 36",
            "AtriaTrendRangeLens(range: range,",
            "metric: metric,",
            "summary: prepared.summary",
            "sampleCount: prepared.series.count",
            "if let assessment = prepared.assessment",
            "AtriaTrendRangeAssessmentCard(assessment: assessment)",
            "private struct AtriaTrendRangeLens: View, Equatable",
            "Circle()\n                    .stroke(metric.tint.opacity(0.14), lineWidth: 7)",
            "private var coverageProgress: Double",
            "Double(sampleCount) / Double(range.confidenceTargetPoints)",
            "private var coverageLabel: String",
            "return \"\\(sampleCount)d in view\"",
            "return \"\\(sampleCount)d forming\"",
            "return sampleCount == 1 ? \"1d started\" : \"\\(sampleCount)d started\"",
            "Trend period rail.",
            "private struct AtriaTrendRangeAssessment: Equatable",
            "private struct AtriaTrendRangeAssessmentCard: View, Equatable",
            "Text(assessment.title)",
            "assessmentBar(label: \"Avg\",",
            "assessmentBar(label: \"Change\",",
            "assessmentBar(label: \"Rhythm\",",
            "accessibilityLabel(assessment.accessibilityText)",
            "AtriaTrendGlanceBoard(readout: periodReadout)",
            "private struct AtriaTrendGlanceBoard: View, Equatable",
            "glanceLane(title: \"Recovery\"",
            "glanceLane(title: \"Strain\"",
            "metricGauge(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "metricGauge(label: \"RHR\", delta: readout.restingHR, tint: .pink)",
            "metricGauge(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            "Trend glance. \\(readout.title). \\(heroCue). Recovery",
            "!periodReadout.hasEnoughSignal",
            "private struct AtriaTrendPeriodOrbit: View, Equatable",
            "orbitGauge(label: \"HRV\"",
            "orbitGauge(label: \"RHR\"",
            "orbitGauge(label: \"Strain\"",
            "Trend period orbit for \\(readout.rangeLabel). HRV",
            "private struct AtriaTrendPeriodLens: View, Equatable",
            "lensChip(title: \"Period\"",
            "lensChip(title: \"Cue\"",
            "lensChip(title: \"Compare\"",
            "private struct AtriaTrendPeriodHeroCard: View, Equatable",
            "private var trendCueRail: some View",
            "cuePill(title: \"Cue\"",
            "cuePill(title: \"Reserve\"",
            "cuePill(title: \"Load\"",
            "Reserve \\(Int((readout.recoveryReserve * 100).rounded())) percent. Load \\(Int((readout.loadPressure * 100).rounded())) percent.",
            "periodGauge(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "periodGauge(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            "private struct AtriaTrendPeriodReadout",
            "let narrativeRangeLabel: String",
            "narrativeRangeLabel: range.narrativeLabel",
            "var hasPriorSignal: Bool",
            "private struct AtriaTrendPeriodDelta",
            "AtriaTrendActionReadout(series: samples,",
            "if let action = prepared.action",
            "AtriaTrendActionReadoutCard(action: action)",
            "AtriaTrendRangePositionBand(series: prepared.series,",
            "private struct AtriaTrendRangePositionBand: View, Equatable",
            "Text(\"Current position\")",
            "bandLabel(\"Now\", value: latest)",
            "AtriaTrendSessionDotStrip(series: prepared.series,",
            "private struct AtriaTrendSessionDotStrip: View, Equatable",
            "Array(series.suffix(28))",
            "Text(\"Day pattern\")",
            "Text(\"\\(visibleSamples.count)d\")",
            "Day pattern for \\(metric.shortLabel), \\(visibleSamples.count) days in view.",
            "private func normalized(_ value: Double) -> Double",
            "private struct AtriaTrendActionReadout: Equatable",
            "private struct AtriaTrendActionReadoutCard: View",
            "private var actionRail: some View",
            "actionChip(title: \"Direction\"",
            "actionChip(title: \"Signal\"",
            "actionChip(title: \"Next\"",
            "Direction \\(directionText), signal \\(signalText), next \\(nextText).",
            "headline = \"HRV lifting\"",
            "headline = \"RHR elevated\"",
            "headline = \"High-load range\"",
            "case .strain: return \"bolt.fill\"",
            "case .hrv: return \"waveform.path.ecg\"",
            "return \"Strain-heavy \\(narrativeRangeLabel)\"",
            "return \"Recovery needs care\"",
            "return \"Recovery-led \\(narrativeRangeLabel)\"",
            "return \"Steady \\(narrativeRangeLabel)\"",
            "Compared with the prior \\(narrativeRangeLabel).",
            "var recoveryReserve: Double",
            "var loadPressure: Double",
            "var balanceCue: String",
            "private struct AtriaTrendRangeReportCard: View, Equatable",
            "Label(\"Range report\", systemImage: \"chart.xyaxis.line\")",
            "reportTile(strongestSignal)",
            "reportTile(pressureSignal)",
            "reportTile(nextStep)",
            "reportBar(label: \"Res\", value: readout.recoveryReserve, tint: .cyan)",
            "reportBar(label: \"Load\", value: readout.loadPressure, tint: Metrics.electricStrain)",
            "Trend range report. Best signal",
            "private struct AtriaTrendPeriodBalanceMap: View, Equatable",
            "Label(\"Balance map\", systemImage: \"circle.grid.cross\")",
            "mapCorner(\"Ready\", alignment: .leading)",
            "mapCorner(\"Protect\", alignment: .trailing)",
            "balancePill(\"Reserve\", value: readout.recoveryReserve, tint: .cyan)",
            "balancePill(\"Load\", value: readout.loadPressure, tint: Metrics.electricStrain)",
            "func directionScore(positiveDeltaIsGood: Bool) -> Double?",
            "private struct AtriaTrendSignalStack: View, Equatable",
            "Label(\"Signal stack\", systemImage: \"waveform.path\")",
            "signalLane(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "signalLane(label: \"RHR\", delta: readout.restingHR, tint: .pink)",
            "signalLane(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            ".atriaInsetCard(cornerRadius: 18, tint: readout.tint)",
            "deltaChip(label: \"HRV\", delta: readout.hrv, tint: .cyan)",
            "deltaChip(label: \"Strain\", delta: readout.strain, tint: Metrics.electricStrain)",
            "summaryPill(label: \"Prior\", value: priorAverageText)",
            "let cutoff = range.cutoffDate(calendar: calendar)",
            "let recoverySummary: [AtriaTrendRange: AtriaDetailPeriodSummary]",
            "let hrvSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]",
            "let restingHeartRateSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]",
            "let sleepSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]",
            "let strainSummary: [AtriaTrendRange: AtriaDetailPeriodSummary]",
            "summary: preparedHistory.recoverySummary[range]",
            "summary: preparedHistory.hrvSummary[range]",
            "summary: preparedHistory.restingHeartRateSummary[range]",
            "summary: preparedHistory.sleepSummary[range]",
            "summary: preparedHistory.strainSummary[range]",
            "rollups: debugMetricDetailRollups ?? dailyRollupHistory",
            "private var debugMetricDetailRollups: [DailyRollupStoreEntry]?",
            "DailyRollupStoreEntry(day: day,",
            # 2026-07-06: the `if let rangeLens { AtriaDetailRangeLensCard(...) }`
            # "Trend snapshot" card was removed from chartSlot (detail redesign —
            # it duplicated the metricChart summary strip, giving two stacked
            # summary cards before the chart). The rangeLens property and the
            # AtriaDetailRangeLensCard struct are kept as scaffolding, so their
            # pins below still hold.
            "sleepGoalHours: sleepGoalHours",
            "private var rangeLens: (summary: AtriaDetailPeriodSummary, comparison: AtriaDetailComparisonSummary?)?",
            "private struct AtriaDetailRangeLensCard: View, Equatable",
            "let sleepGoalHours: Double",
            "Label(\"Trend snapshot\", systemImage: \"scope\")",
            "lensStat(title: \"Latest\", value: summary.latestText, prominent: true)",
            "lensStat(title: \"Avg\", value: summary.averageText, prominent: false)",
            "lensStat(title: \"Change\", value: summary.changeText, prominent: false)",
            "if summary.unit == \"h\"",
            "private var sleepRangeRhythm: some View",
            "Label(\"Sleep rhythm\", systemImage: \"moon.zzz.fill\")",
            "sleepMiniStat(title: \"Target\", value: AtriaMetricFormat.sleepHours(sleepGoalHours))",
            "private var sleepRangeCue: String",
            "return \"Debt building\"",
            "private var sleepScaleMax: Double",
            "private func comparisonRail(_ comparison: AtriaDetailComparisonSummary) -> some View",
            "AtriaDetailComparisonSeesaw(comparison: comparison,",
            "private struct AtriaDetailComparisonSeesaw: View, Equatable",
            "Label(\"This vs prior\", systemImage: comparison.changeDirection.symbolName)",
            "comparisonBar(title: \"Prior\"",
            "comparisonBar(title: \"This\"",
            "This versus prior. This \\(comparison.currentText), prior \\(comparison.priorText), change \\(comparison.deltaText).",
            # 2026-07-06: AtriaDetailRangeRhythmCard call removed from metricChart
            # (detail-sheet redesign collapsed 3 redundant summary cards into one).
            # Struct definition kept as uncalled scaffolding — declaration pin below
            # and its internal pins still hold.
            "private struct AtriaDetailRangeRhythmCard: View",
            "Label(\"Range rhythm\", systemImage: \"waveform.path.ecg\")",
            "rhythmChip(title: rangeAnchorTitle",
            "rhythmChip(title: \"Avg\"",
            "rhythmChip(title: \"Vs prior\"",
            "Detail range rhythm. \\(range.menuLabel).",
            "private let chartOverview: TrendChartOverview",
            "private let windowChips: [TrendWindowChipModel]",
            "@State private var selectedDays: Int",
            "Picker(\"Trend window\", selection: $selectedDays)",
            "TrendWindowFocusCard(summary: selectedSummary)",
            "private struct TrendWindowFocusCard: View",
            "TrendFocusMetric(label: \"Recovery\"",
            "TrendFocusMetric(label: \"Strain\"",
            "private struct TrendWindowChipModel: Identifiable",
            "private struct TrendMetricChartModel: Identifiable",
            "self.metricCards = [",
            "private struct AtriaDetailPeriodSummary: Equatable",
            "private struct AtriaDetailPeriodSummaryStrip: View",
            "private struct AtriaDetailPeriodReportCard: View, Equatable",
            "Label(\"This period\", systemImage: \"chart.bar.xaxis\")",
            "reportChip(title: \"Latest\"",
            "reportChip(title: \"Change\"",
            "reportChip(title: \"Compare\"",
            "This period. Latest \\(summary.latestText), change \\(summary.changeText), compared with prior \\(priorText), average \\(summary.averageText).",
            "Metrics.dayCalories(samples.map",
            "Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)",
            "activeCalories += Metrics.dayCalories([",
        ]:
            assert_contains(self, trend_chart + sessions + home + overview, needle)
        assessment_start = trend_chart.index("private struct AtriaTrendRangeAssessmentCard")
        assessment_end = trend_chart.index("private struct AtriaTrendRangeSummaryStrip", assessment_start)
        assessment_source = trend_chart[assessment_start:assessment_end]
        assert_not_contains(self, assessment_source, 'assessmentBar(label: "Move",')
        assert_not_contains(self, assessment_source, "movement \\(movementText)")
        trend_summary_start = trend_chart.index("private struct AtriaTrendRangeSummaryStrip")
        trend_summary_end = trend_chart.index("private struct AtriaTrendRangePositionBand", trend_summary_start)
        trend_summary_source = trend_chart[trend_summary_start:trend_summary_end]
        assert_not_contains(self, trend_summary_source, 'summaryPill(label: "Vs prior", value: priorAverageText)')
        assert_not_contains(self, trend_summary_source, "versus prior \\(priorAverageText)")
        detail_lens_start = overview.index("private struct AtriaDetailRangeLensCard")
        detail_lens_end = overview.index("private struct AtriaDetailComparisonSeesaw", detail_lens_start)
        detail_lens_source = overview[detail_lens_start:detail_lens_end]
        for stale_copy in [
            "Label(\"Range lens\", systemImage: \"scope\")",
            "lensStat(title: \"Move\", value: summary.changeText, prominent: false)",
            "Range lens \\(range.menuLabel)",
            "move \\(summary.changeText)",
        ]:
            assert_not_contains(self, detail_lens_source, stale_copy)
        chart_card_start = trend_chart.index("struct AtriaTrendChartCard: View")
        chart_card_end = trend_chart.index("private struct AtriaTrendPeriodReadout", chart_card_start)
        chart_card_source = trend_chart[chart_card_start:chart_card_end]
        assert_not_contains(self, chart_card_source, "saved sessions")
        assert_not_contains(self, chart_card_source, "prepared.series.count) sessions")
        glance_start = trend_chart.index("private struct AtriaTrendGlanceBoard")
        glance_end = trend_chart.index("private struct AtriaTrendPeriodOrbit", glance_start)
        glance_source = trend_chart[glance_start:glance_end]
        assert_not_contains(self, glance_source, "glanceLane(title: \"Reserve\"")
        assert_not_contains(self, glance_source, "glanceLane(title: \"Load\"")
        assert_not_contains(self, glance_source, "Trend glance. \\(readout.title). \\(heroCue). Reserve")
        assert_not_contains(self, glance_source, "Recovery pressure")
        readout_start = trend_chart.index("private struct AtriaTrendPeriodReadout")
        readout_end = trend_chart.index("private struct AtriaTrendGlanceBoard", readout_start)
        readout_source = trend_chart[readout_start:readout_end]
        assert_not_contains(self, readout_source, "Recovery pressure")
        dot_strip_start = trend_chart.index("private struct AtriaTrendSessionDotStrip")
        dot_strip_end = trend_chart.index("enum AtriaTrendChartScale", dot_strip_start)
        dot_strip_source = trend_chart[dot_strip_start:dot_strip_end]
        for needle in [
            "Text(\"Window pattern\")",
            "Text(\"\\(visibleSamples.count) saved\")",
            "saved sessions",
        ]:
            assert_not_contains(self, dot_strip_source, needle)

        trend_body_start = trend_chart.index("var body: some View")
        trend_body_end = trend_chart.index("private func refreshPreparedSeries", trend_body_start)
        trend_body = trend_chart[trend_body_start:trend_body_end]
        assert_contains(self, trend_body, "AtriaTrendPeriodBalanceMap(readout: periodReadout)")
        assert_contains(self, trend_body, "AtriaTrendRangeReportCard(readout: periodReadout)")
        assert_contains(self, trend_body, "AtriaTrendGlanceBoard(readout: periodReadout)")
        self.assertLess(trend_body.index("AtriaTrendRangeReportCard(readout: periodReadout)"),
                        trend_body.index("AtriaTrendPeriodBalanceMap(readout: periodReadout)"),
                        "The compact range report should answer first before the larger visual map.")
        self.assertLess(trend_body.index("AtriaTrendPeriodBalanceMap(readout: periodReadout)"),
                        trend_body.index("AtriaTrendGlanceBoard(readout: periodReadout)"),
                        "The visual period map should appear before the denser trend metric board.")
        assert_not_contains(self, trend_body, "AtriaTrendPeriodOrbit(readout: periodReadout)")
        assert_not_contains(self, trend_body, "AtriaTrendPeriodHeroCard(readout: periodReadout)")
        assert_not_contains(self, trend_body, "AtriaTrendSignalStack(readout: periodReadout)")
        assert_not_contains(self, trend_body, "AtriaTrendPeriodReadoutCard(readout: periodReadout)")

        for forbidden in [
            "private var trendPoints",
            "store.sessions.filter",
            "meaningful.sorted",
            "Metrics.strain(fromTRIMP:",
            "session.trimp(rest:",
            "let maxHR",
            "private struct AtriaTrendRangeRhythmStrip",
            "private struct AtriaTrendRangeConfidenceRail",
            "AtriaTrendRangeRhythmStrip(selectedRange:",
            "AtriaTrendRangeConfidenceRail(selectedRange:",
            "saved points",
            "saved ·",
        ]:
            assert_not_contains(self, trend_chart, forbidden)

        debug_fixture_start = trend_chart.index("private static func debugFixtureTrendPoints")
        debug_fixture_end = trend_chart.index("#else", debug_fixture_start)
        debug_fixture_source = trend_chart[debug_fixture_start:debug_fixture_end]
        assert_not_contains(self, debug_fixture_source, "SessionStore")
        assert_not_contains(self, debug_fixture_source, "UserDefaults")
        assert_not_contains(self, debug_fixture_source, "store.")

        for _, block in swift_some_view_blocks(trend_chart):
            assert_not_contains(self, block, ".filter")
            assert_not_contains(self, block, ".reduce(")

        assert_contains(self, overview, "AtriaOverviewTrendChartHost(store: store)")
        assert_contains(self, overview, "store.overviewTrendPoints.count >= 2")
        assert_contains(self, overview, "snapshotStore.diagnosticsReady || AtriaOverviewTrendChartHost.debugShowsTrendFixture")
        assert_contains(self, overview, "private var showsSavedInsights: Bool")
        assert_not_contains(self, overview, "AtriaOverviewTrendChartHost(store: store, maxHR:")
        assert_not_contains(self, overview, "store.sessions.filter { $0.points.count >= 8 }.count >= 2")

        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        assert_contains(self, home, "let load = store.trainingLoadSummarySnapshot")
        assert_contains(self, home, "let loadReadinessText: String")
        assert_contains(self, home, "let loadACWRSignalText: String")
        assert_contains(self, home, "let loadMonotonyText: String")
        assert_contains(self, home, "let loadMonotonySignalText: String")
        assert_contains(self, home, "let loadACWRDetailText: String")
        assert_contains(self, home, "let loadMonotonyDetailText: String")
        assert_contains(self, home, "let loadSignalSummaryText: String")
        assert_contains(self, home, "loadReadinessText: load.readinessText")
        assert_contains(self, home, "loadACWRSignalText: load.acwrSignalText")
        assert_contains(self, home, "loadMonotonyText: load.monotonyText")
        assert_contains(self, home, "loadMonotonySignalText: load.monotonySignalText")
        assert_contains(self, home, "loadACWRDetailText: load.acwrDetailText")
        assert_contains(self, home, "loadMonotonyDetailText: load.monotonyDetailText")
        assert_contains(self, home, "loadSignalSummaryText: load.signalSummaryText")
        assert_not_contains(self, home, "store.trainingLoadSummary(rest:")
        for needle in [
            "readiness: hero.loadReadinessText",
            "acwrSignal: hero.loadACWRSignalText",
            "monotony: hero.loadMonotonyText",
            "monotonySignal: hero.loadMonotonySignalText",
            "acwrDetail: hero.loadACWRDetailText",
            "monotonyDetail: hero.loadMonotonyDetailText",
            "signalSummary: hero.loadSignalSummaryText",
            "private struct AtriaTrainingSignalChip: View, Equatable",
            "AtriaTrainingSignalChip(title: \"ACWR\", value: ratio, signal: acwrSignal)",
            "AtriaTrainingSignalChip(title: \"Monotony\", value: monotony, signal: monotonySignal)",
            "Label(acwrDetail, systemImage: \"gauge.with.dots.needle.50percent\")",
            "Label(monotonyDetail, systemImage: \"waveform.path\")",
            ".accessibilityLabel(\"Readiness \\(readiness). \\(signalSummary). \\(acwrDetail) \\(monotonyDetail) \\(narrative) Long press to edit target.\")",
            "Text(\"Target \\(target)\")",
        ]:
            assert_contains(self, vitals, needle)

    def test_behavior_insights_compute_from_snapshots_off_actor_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "let sourceSessions = cachedCanonicalSessions",
            "let journalEntries = cachedBehaviorJournalEntries",
            "private nonisolated static let behaviorCorrelationWindowDays = 90",
            "Self.sortedBehaviorCorrelationSummaries(\n                Self.makeBehaviorCorrelationSummaries(sessions: sourceSessions,",
            "let insights = Self.deriveInsights(from: summaries)",
            "nonisolated static func deriveInsights(from summaries: [BehaviorCorrelationSummary])",
            "private nonisolated static func makeBehaviorCorrelationSummaries(sessions: [SavedSession]",
            "journalEntries: [BehaviorJournalEntry]",
            "Self.sortedBehaviorCorrelationSummaries(\n            Self.makeBehaviorCorrelationSummaries(sessions: canonicalSessions(),",
            "private nonisolated static func averageDoubleSnapshot(_ values: [Double]) -> Double?",
            "private nonisolated static func sortedBehaviorCorrelationSummaries(_ summaries: [BehaviorCorrelationSummary]) -> [BehaviorCorrelationSummary]",
            "Recovery correlations stay fail-closed until they can use real",
            "strain-derived recovery proxies would",
            "let recentSessions = sessions.filter { $0.start >= windowStart }",
            "let recentJournalEntries = journalEntries.filter { $0.day >= windowStart }",
            "let grouped = Dictionary(grouping: recentSessions)",
            "return InsightDayMetrics(recovery: nil, hrv: hrv)",
            "let taggedDayKeys = Set(recentJournalEntries",
            "var impactValueText: String",
            "var impactToneText: String",
            'return impactDelta > 0 ? "Linked up" : "Linked down"',
            "var impactMagnitude: Double",
            "var impactProgress: Double",
            "var symbolName: String",
            "if lhs.impactMagnitude != rhs.impactMagnitude",
            "return lhs.impactMagnitude > rhs.impactMagnitude",
            "let taggedRecovery = averageDoubleSnapshot(tagged.compactMap(\\.recovery))",
            "let untaggedRecovery = averageDoubleSnapshot(untagged.compactMap(\\.recovery))",
        ]:
            assert_contains(self, sessions, needle)

        recompute_start = sessions.index("func recomputeBehaviorInsights()")
        recompute_end = sessions.index("/// Turn per-tag correlation deltas")
        recompute_source = sessions[recompute_start:recompute_end]
        for forbidden in [
            "self.behaviorCorrelationSummaries(rest:",
            "dailyRollups(rest:",
            "detectedActivities(rest:",
        ]:
            assert_not_contains(self, recompute_source, forbidden)

        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        journal_start = overview.index("struct AtriaOverviewBehaviorJournalSection")
        journal_end = overview.index("struct AtriaOverviewBackupSectionHost")
        journal_source = overview[journal_start:journal_end]
        assert_contains(self, journal_source, "store.behaviorCorrelationSummariesCache\n            .filter { $0.days > 0 }")
        for needle in [
            "private var impactSummaries: [BehaviorCorrelationSummary]",
            "AtriaJournalImpactStrip(summaries: impactSummaries,",
            "static var debugShowsImpactOnlyFixture: Bool",
            "private static func debugFixtureBehaviorSummaries(arguments: [String]) -> [BehaviorCorrelationSummary]?",
            '["journal-impact", "journal-impact-focus"].contains(arguments[valueIndex])',
            "private struct AtriaJournalImpactStrip: View, Equatable",
            "private var focusSummary: BehaviorCorrelationSummary?",
            "AtriaJournalImpactGlanceBoard(summaries: summaries,",
            "private struct AtriaJournalImpactGlanceBoard: View, Equatable",
            "impactLane(title: \"Watch\"",
            "impactLane(title: \"Support\"",
            "glanceChip(title: \"Logged\"",
            "glanceChip(title: \"Links\"",
            "glanceChip(title: \"Focus\"",
            "Journal impact glance. \\(taggedDays) logged days.",
            "behavior links",
            "Text(count == 1 ? \"1 link\" : \"\\(count) links\")",
            "private func impactLane(title: String,",
            "private func glanceChip(title: String,",
            "private struct AtriaJournalImpactBalanceRail: View, Equatable",
            "private var supportSummaries: [BehaviorCorrelationSummary]",
            "private var pressureSummaries: [BehaviorCorrelationSummary]",
            "Label(\"Recovery balance\", systemImage: \"arrow.left.and.right\")",
            "balanceSide(title: \"Watch\"",
            "balanceSide(title: \"Support\"",
            "Recovery balance. Watch \\(pressureSummaries.count) links, support \\(supportSummaries.count) links.",
            "AtriaJournalImpactMap(summaries: summaries)",
            "private struct AtriaJournalImpactMap: View, Equatable",
            "private var visibleSummaries: [BehaviorCorrelationSummary]",
            "let centerX = width / 2",
            "let travel = max(24, (width - 76) / 2)",
            "Behavior impact map. Left is watch, center is neutral, right is support.",
            "private func nodeX(summary: BehaviorCorrelationSummary, centerX: CGFloat, travel: CGFloat) -> CGFloat",
            "private struct AtriaJournalImpactCompass: View, Equatable",
            "private var supportSummary: BehaviorCorrelationSummary?",
            "private var pressureSummary: BehaviorCorrelationSummary?",
            'Text("Impact compass")',
            'compassCell(title: "Support",',
            'compassCell(title: "Watch",',
            "private struct AtriaJournalImpactFocus: View, Equatable",
            "private var ringProgress: CGFloat",
            "Circle()\n                    .trim(from: 0, to: ringProgress)",
            "Image(systemName: summary.tag.symbolName)",
            "Text(summary.impactToneText)",
            ".background(.cyan.opacity(0.10), in: Capsule())",
            ".font(.headline.weight(.bold).monospacedDigit())",
            "private struct AtriaJournalImpactBar: View, Equatable",
            'Label("Impact", systemImage: "waveform.path.ecg")',
            "GeometryReader { proxy in",
            "let center = width / 2",
            "summary.impactProgress",
            ".atriaInsetCard(tint: .cyan)",
        ]:
            assert_contains(self, journal_source, needle)
        for needle in [
            "glanceChip(title: \"Signals\"",
            "behavior signals",
            "1 signal",
            "\\(count) signals",
            "Recovery balance. Watch \\(pressureSummaries.count) signals",
        ]:
            assert_not_contains(self, journal_source, needle)
        impact_strip_start = journal_source.index("private struct AtriaJournalImpactStrip")
        impact_strip_end = journal_source.index("private struct AtriaJournalImpactGlanceBoard")
        impact_strip_body = journal_source[impact_strip_start:impact_strip_end]
        assert_contains(self, impact_strip_body, "AtriaJournalImpactGlanceBoard(summaries: summaries,")
        assert_not_contains(self, impact_strip_body, "impactEvidenceRail")
        assert_not_contains(self, impact_strip_body, "AtriaJournalImpactBalanceRail(summaries: summaries)")
        assert_not_contains(self, impact_strip_body, "AtriaJournalImpactCompass(summaries: summaries,")
        assert_not_contains(self, impact_strip_body, "AtriaJournalImpactFocus(summary: focusSummary)")
        assert_contains(self, overview, "if AtriaOverviewBehaviorJournalSection.debugShowsImpactOnlyFixture")
        assert_not_contains(self, journal_source, ".sorted { lhs, rhs in")
        assert_not_contains(self, journal_source, "Text(\"Top signal\")")
        assert_not_contains(self, journal_source, "Color.white.opacity")
        assert_not_contains(self, journal_source, "Color.black.opacity")

        insight_source_start = sessions.index("private nonisolated static func makeBehaviorCorrelationSummaries")
        insight_source_end = sessions.index("private nonisolated static func averageDoubleSnapshot")
        insight_source = sessions[insight_source_start:insight_source_end]
        for forbidden in [
            "100 - Metrics.strain(fromTRIMP:",
            "let recovery = max(0, 100",
            "tagged.map(\\.recovery)",
            "untagged.map(\\.recovery)",
        ]:
            assert_not_contains(self, insight_source, forbidden)

    def test_connected_pulse_display_name_is_precomputed_for_hr_tick_perf(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "var displayDeviceName: String",
            "displayDeviceName: AtriaDeviceDisplayName.shortName(for: deviceName)",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "enum AtriaDeviceDisplayName",
            "static func shortName(for deviceName: String) -> String",
            "displayDeviceName: liveStore.state.displayDeviceName",
            "AtriaConnectedPulseStatusCard(displayDeviceName: displayDeviceName",
            "AtriaHeartRateZoneRail(zone: heartRateZone)",
            "ForEach(0..<6, id: \\.self)",
            "let displayDeviceName: String",
            "Live heart rate \\(heartRateText) beats per minute from \\(displayDeviceName)",
        ]:
            assert_contains(self, hero, needle)

        assert_not_contains(self, hero, "private var displayDeviceName: String")

    def test_live_heart_rate_zone_indicator_uses_personal_hr_reserve(self):
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "struct HeartRateZone: Equatable, Identifiable",
            "static func heartRateZone(bpm: Int, rest: Int, max: Int) -> HeartRateZone?",
            "case ..<0.30: index = 0",
            "case ..<0.50: index = 1",
            "case ..<0.70: index = 2",
            "case ..<0.80: index = 3",
            "case ..<0.90: index = 4",
            'let names = ["Recovery", "Easy", "Endurance", "Tempo", "Hard", "Max"]',
            "static func heartRateZoneTint(_ index: Int) -> Color",
        ]:
            assert_contains(self, metrics, needle)

        for needle in [
            "rest: initialLiveSessionDerived.rest",
            "maxHR: initialLiveSessionDerived.maxHR",
            "rest: liveSessionDerived.rest",
            "maxHR: liveSessionDerived.maxHR",
            "AtriaLiveTabAccessory(liveStore: model.coreLiveStore,",
            "pulseStore: model.pulseLiveStore",
            "static var isActive: Bool",
            "ProcessInfo.processInfo.arguments.contains(\"live-zone\")",
            "Self.debugLaunchFixtureValue(arguments: arguments) == \"live-zone\"",
            "private func applyDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments)",
            "private func sustainDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments)",
            "for _ in 0..<18",
            "try? await Task.sleep(for: .milliseconds(350))",
            "let protectsSleepCapture = arguments.contains(\"sleep-capture-protected\")",
            "let heartRate = protectsSleepCapture ? 72 : 142",
            "core.liveTRIMP = protectsSleepCapture ? 2.4 : 26",
            "core.batteryChargeStatus = .notCharging",
            "core.rangeLossBackfillPending = protectsSleepCapture",
            "model.heroPulseStore.state = AtriaHomeModel.HeroPulseState(heartRate: heartRate,",
            "model.pulseLiveStore.state = AtriaHomeModel.PulseLiveState(heartRate: heartRate,",
        ]:
            assert_contains(self, home, needle)

        live_accessory_start = home.index("private struct AtriaLiveTabAccessory: View")
        live_accessory_end = home.index("private struct AtriaStandByOverlay: View", live_accessory_start)
        live_accessory = home[live_accessory_start:live_accessory_end]
        for needle in [
            "AtriaLiveZoneAccessoryPill",
            "heartRateZone",
            "Live heart-rate zone",
            "\\(zone.title), \\(zone.name)",
        ]:
            assert_not_contains(self, live_accessory, needle)
        assert_not_contains(self, home, "private struct AtriaLiveZoneAccessoryPill")

        for needle in [
            "private struct AtriaHeartRateZoneRail: View, Equatable",
            "AtriaHeartRateZoneLens(zone: heartRateZone)",
            "private struct AtriaHeartRateZoneLens: View, Equatable",
            "Label(\"HR zone\", systemImage: \"scope\")",
            "Text(zone.shortLabel)",
            "Text(zone.name)",
            "lensStat(title: \"Reserve\", value: \"\\(Int((zone.reserveFraction * 100).rounded()))%\")",
            "lensStat(title: \"Cue\", value: cueText)",
            "Heart-rate zone lens.",
            "Text(zone.title)",
            "Text(zone.name)",
            "Metrics.heartRateZoneTint(index)",
            "index == zone.index ? 0.95 : 0.22",
            "\\(heartRateZone.title), \\(heartRateZone.name)",
        ]:
            assert_contains(self, hero, needle)

    def test_standard_hr_only_mode_blocks_strap_writes(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        match = re.search(r"private func sendCommand\(_ cmd: UInt8, _ data: \[UInt8\], mode: CommandWriteMode\) \{(?P<body>.*?)\n    \}", text, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")

        guard_index = body.find("guard !standardHROnlyMode || historyOnlyProbeEnabled else")
        first_write_index = body.find("writeValue(")
        self.assertGreaterEqual(guard_index, 0)
        self.assertGreater(first_write_index, guard_index)
        assert_contains(self, body, "standard_hr_only_no_strap_writes")
        assert_contains(self, body, "standard_hr_only_write_blocked")
        self.assertEqual(text.count("writeValue("), body.count("writeValue("))
        self.assertEqual(body.count("writeValue("), 2)

    def test_offline_historical_sync_is_bounded_standard_hr_exception(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "enum OfflineSyncDefaults",
            "defaults.set(true, forKey: OfflineSyncDefaults.enabled)",
            "private func migrateOfflineSyncDefaultIfNeeded(arguments: [String])",
            "stored_session_backfill_default",
            "applyEarlyHistoricalLaunchConfiguration(arguments: arguments)",
            "private func applyEarlyHistoricalLaunchConfiguration(arguments: [String])",
            "ATRIADBG realtimeConfig history_only_probe=1 phase=early",
            "@discardableResult",
            "func requestOfflineHistoricalSyncIfNeeded(reason: String, force: Bool = false)",
            "private func startOfflineHistoricalSync(reason: String, force: Bool)",
            "historyOnlyProbeEnabled = true",
            "historyOnlyProbeMode = true",
            "historyClockSyncEnabled = true",
            "historicalAckDisabled = false",
            "historyAckMode = \"enddata\"",
            "probeCommandMode = .withResponse",
            "let preserveDebugHistoryRangeProbe = historyOnlyProbeEnabled",
            "historySelectorSweepEnabled || historyDataRangeSweepEnabled",
            "&& !historySkipDataRangeRequest",
            "private func shouldLogVerboseBLEFrame() -> Bool",
            "let limit = historyOnlyProbeMode ? 48 : 160",
            "log_budget_exhausted",
            "[Cmd.abortHistoricalTransmits, 0x00]",
            "[Cmd.enterHighFreqSync, 0x00]",
            "[Cmd.sendHistoricalData, 0x00]",
            "historySkipDataRangeRequest = true",
            "historySkipDataRangeRequest = false",
            "if !preserveDebugHistoryRangeProbe",
            "ATRIADBG offline_sync status=armed",
            "preserveDebugHistoryRangeProbe ? \"selector_probe\" : \"safe_history_backfill\"",
            "cmd22=%d",
            "live_realtime=skipped metrics_fail_closed=1",
            "deferred_live_link",
            "offlineSyncLiveAcceptedHRProtectionWindow",
            "private func shouldProtectLiveStreamForOfflineSync(now: Date = Date()) -> Bool",
            "detail=live_hr_recent action=keep_ble_stream",
            "detail=live_hr_recent_late action=keep_ble_stream",
            "static let rangeLossBackfillPending",
            "private func markRangeLossBackfillRequired(reason: String)",
            "let alreadyPending = defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)",
            "if !alreadyPending || defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) == nil",
            "already_pending=%d",
            "private func preserveLongWearRangeLossRecovery(reason: String)",
            "let backfillReason = strapStreamState == .lowBatteryShutoff",
            "? \"strap_low_battery_broadcast_off\"",
            ": \"long_wear_range_loss\"",
            "private func scheduleRangeLossBackfillIfNeeded(reason: String)",
            "private func scheduleRangeLossBackfillRetry(reason: String)",
            "private func scheduleStaleArmedRangeLossBackfillReconciliation(reason: String,",
            'let clearableStatuses = ["armed", "archived", "archive_metric_ready", "throttled", "no_rows"]',
            "scheduleStaleArmedRangeLossBackfillReconciliation(reason: \"long_wear_supervisor_tick\",",
            "stale_armed_reconcile_scheduled",
            "source=stale_armed_reconcile",
            "rangeLossBackfillRetryInterval",
            "rangeLossBackfillReadyForceInterval",
            "private var offlineHistoricalSyncStartRows = 0",
            "offlineHistoricalSyncStartRows = historicalArchiveRows",
            "let newRows = max(0, rows - offlineHistoricalSyncStartRows)",
            "new_rows=%d",
            "if newRows > 0",
            "offline_sync_stale_peripheral",
            "ATRIADBG offline_sync status=pending_range_loss_backfill",
            "ATRIADBG offline_sync status=requesting_range_loss_backfill",
            "stale_force=%d",
            "ready_force=%d",
            "forceStaleBackfill = !protectedLiveStream && shouldForceStaleRangeLossBackfill()",
            "forceReadyBackfill = !protectedLiveStream && shouldForceReadyRangeLossBackfill()",
            "forceBackfill = forceStaleBackfill || forceReadyBackfill",
            "forceStaleBackfill ? \"force_stale_backfill\"",
            "force_ready_backfill",
            "defer_live_stream",
            "requestOfflineHistoricalSyncIfNeeded(reason: backfillReason, force: forceBackfill)",
            "let syncStarted = requestOfflineHistoricalSyncIfNeeded(reason: backfillReason, force: forceBackfill)",
            "ATRIADBG offline_sync status=range_loss_backfill_request_result",
            "started=%d pending=%d force=%d action=%@",
            "private func rangeLossBackfillRetryDelay(now: Date = Date()) -> TimeInterval",
            "ATRIADBG offline_sync status=retry_scheduled",
            "private func shouldForceReadyRangeLossBackfill(now: Date = Date()) -> Bool",
            "let minimumInterval = offlineHistoricalSyncMinimumInterval(for: reason)",
            "private func offlineHistoricalSyncMinimumInterval(for reason: String) -> TimeInterval",
            "return rangeLossBackfillRetryInterval",
            "private func shouldForceStaleRangeLossBackfill(now: Date = Date()) -> Bool",
            "protectedLiveStream ? \"defer_live_stream\" : \"sync_when_available\"",
            "static func offlineSyncEvidence() -> String",
            "offline_range_loss_backfill_pending",
            "private func finishOfflineHistoricalSync(reason: String)",
            "applyStandardHROnly(enabled: true, persist: true, reconnect: true, reason: \"offline_sync_complete\")",
            "central.cancelPeripheralConnection(peripheral)",
        ]:
            assert_contains(self, ble, needle)

        assert_not_contains(
            self,
            ble,
            "if !historyInitSweepCommands.isEmpty {\n            historySkipDataRangeRequest = true\n        }",
        )

        init_body = re.search(r"override init\(\) \{(?P<body>.*?)\n    \}", ble, re.S)
        self.assertIsNotNone(init_body)
        body = init_body.group("body")
        early_config = body.find("applyEarlyHistoricalLaunchConfiguration(arguments: arguments)")
        central_create = body.find("central = CBCentralManager")
        self.assertGreaterEqual(early_config, 0)
        self.assertGreater(central_create, early_config)

        for needle in [
            "let syncStarted = ble.requestOfflineHistoricalSyncIfNeeded(reason: reason)",
            "if syncStarted",
            "try? await Task.sleep(for: .seconds(185))",
            "case .background:",
            "ble.handleSceneBackgroundTransition(reason: \"scene_background\",",
            "rest: store.baseline.restingInt ?? 60",
            "maxHR: store.profile.maxHR",
            "case .inactive:",
            "ble.flushLifecycleRealtimeState(reason: \"scene_inactive_checkpoint\")",
            "handleBackgroundTask",
            "performSceneBackgroundMaintenance",
            "let syncStarted = ble.requestOfflineHistoricalSyncIfNeeded(reason: \"\\(reason)_opportunistic\")",
            "offline_sync_started=%d",
        ]:
            assert_contains(self, app, needle)

        inactive_case = re.search(
            r"case \.inactive:(?P<body>.*?)case \.active:",
            app,
            re.S,
        )
        self.assertIsNotNone(inactive_case)
        self.assertNotIn("handleUnattendedMode", inactive_case.group("body"))

        scene_background = re.search(
            r"private func performSceneBackgroundMaintenance\(reason: String\) \{(?P<body>.*?)\n    \}",
            app,
            re.S,
        )
        self.assertIsNotNone(scene_background)
        scene_background_body = scene_background.group("body")
        assert_contains(self, scene_background_body, "ble.flushLifecycleRealtimeState(reason: reason)")
        assert_contains(self, scene_background_body, "ble.requestOfflineHistoricalSyncIfNeeded(reason: \"\\(reason)_opportunistic\")")
        self.assertNotIn("force: true", scene_background_body)
        self.assertNotIn("cancelPeripheralConnection", scene_background_body)
        unattended_mode = re.search(
            r"func handleUnattendedMode\(rest: Int, maxHR: Int, reason: String\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(unattended_mode)
        self.assertNotIn("requestOfflineHistoricalSyncIfNeeded", unattended_mode.group("body"))

        scene_background_transition = re.search(
            r"func handleSceneBackgroundTransition\(reason: String, rest: Int, maxHR: Int\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(scene_background_transition)
        transition_body = scene_background_transition.group("body")
        assert_contains(self, transition_body, "flushLifecycleRealtimeState(reason: reason)")
        assert_contains(self, transition_body, "if longWearModeEnabled")
        assert_contains(self, transition_body, "startLongWearMode(rest: rest, maxHR: maxHR, reason: reason)")

        assert_contains(self, transition_body, "reassertHeartRateNotificationsIfConnected(reason: reason)")
        self.assertNotIn("cancelPeripheralConnection", transition_body)

        request_sync = re.search(
            r"func requestOfflineHistoricalSyncIfNeeded\(reason: String, force: Bool = false\) -> Bool \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(request_sync)
        request_body = request_sync.group("body")
        live_defer_index = request_body.find("shouldProtectLiveStreamForOfflineSync(now: now)")
        start_index = request_body.find("startOfflineHistoricalSync(reason: reason, force: force)")
        self.assertGreaterEqual(live_defer_index, 0)
        self.assertGreater(start_index, live_defer_index)
        assert_contains(self, request_body, "return false")
        assert_contains(self, request_body, "OfflineSyncDefaults.rangeLossBackfillStartedAt")
        self.assertNotIn("defaults.set(false, forKey: OfflineSyncDefaults.rangeLossBackfillPending)", request_body)
        self.assertNotIn("assignIfChanged(\\.rangeLossBackfillPending, false)", request_body)

        finish_sync = re.search(
            r"private func finishOfflineHistoricalSync\(reason: String\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(finish_sync)
        finish_body = finish_sync.group("body")
        assert_contains(self, finish_body, "if defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)")
        assert_contains(self, finish_body, "if newRows > 0")
        assert_contains(self, finish_body, "defaults.set(false, forKey: OfflineSyncDefaults.rangeLossBackfillPending)")
        assert_contains(self, finish_body, "assignIfChanged(\\.rangeLossBackfillPending, false)")
        assert_contains(self, finish_body, "scheduleRangeLossBackfillRetry(reason: reason)")

        start_sync = re.search(
            r"private func startOfflineHistoricalSync\(reason: String, force: Bool\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(start_sync)
        start_body = start_sync.group("body")
        late_defer_index = start_body.find("force || !shouldProtectLiveStreamForOfflineSync(now: Date())")
        cancel_index = start_body.find("central.cancelPeripheralConnection(peripheral)")
        stale_index = start_body.find("recomputeConnectionStatus(reason: \"offline_sync_stale_peripheral\")")
        self.assertGreaterEqual(late_defer_index, 0)
        self.assertGreater(cancel_index, late_defer_index)
        self.assertGreater(stale_index, cancel_index)

        protect_helper = re.search(
            r"private func shouldProtectLiveStreamForOfflineSync\(now: Date = Date\(\)\) -> Bool \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(protect_helper)
        protect_body = protect_helper.group("body")
        for needle in [
            "guard longWearModeEnabled else { return false }",
            "guard let peripheral, peripheral.state == .connected else { return false }",
            "guard hasContact else { return false }",
            "guard session.count >= autoSaveMinSamples else { return false }",
            "guard let lastAcceptedHRAt else { return false }",
            "<= offlineSyncLiveAcceptedHRProtectionWindow",
        ]:
            assert_contains(self, protect_body, needle)

        for needle in [
            "AtriaMissedDataBanner(protectsLiveStream: missedDataBackfillIsDeferredForLiveStream)",
            "private var missedDataBackfillIsDeferredForLiveStream: Bool",
            "case .connected:\n            return model.coreLiveStore.state.sessionSampleCount > 0",
            "case .connecting, .scanning:\n            return true",
            "Text(protectsLiveStream ? \"Saved data protected\" : \"Sync ready\")",
            "Live HR stays protected while Atria waits for the best sync moment.",
            "Pull missed strap data when you are ready.",
            "guard !missedDataBackfillIsDeferredForLiveStream else",
            "missedDataBannerDismissedUntil = Date().addingTimeInterval(15 * 60)",
            "if protectsLiveStream {\n            Text(\"Live\")",
            ".accessibilityLabel(\"Live heart rate protected\")",
            "Live heart rate stays protected while Atria catches up.",
            "} else {\n            Button(action: onSync)",
            ".atriaCardAction(prominent: false, tint: .cyan)",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            "Text(protectsLiveStream ? \"Live protected\" : \"History syncing\")",
            ".background(Color(uiColor: .secondarySystemBackground),",
            "requestOfflineHistoricalSyncIfNeeded(reason: \"home_missed_data_banner\",\n                                                             force: true)",
        ]:
            assert_contains(self, home, needle)

        missed_banner = re.search(
            r"private struct AtriaMissedDataBanner: View, Equatable \{(?P<body>.*?)\n\}",
            home,
            re.S,
        )
        self.assertIsNotNone(missed_banner)
        self.assertNotIn(".buttonStyle(.glass", missed_banner.group("body"))
        self.assertNotIn(".glassEffect(", missed_banner.group("body"))
        self.assertNotIn(".atriaInsetCard(tint: .cyan)", missed_banner.group("body"))
        self.assertNotIn("GeometryReader", missed_banner.group("body"))
        self.assertNotIn("Backfill ready", missed_banner.group("body"))
        self.assertNotIn("gap marker", missed_banner.group("body"))

        assert_contains(self, ble, "currentSessionUsable: currentSessionUsable")
        assert_contains(self, ble, "metricUsable: false")
        assert_contains(self, ble, "private nonisolated static func historicalCurrentSessionUsable")
        assert_contains(self, ble, "current_session_replay_ready_metric_reference_pending")
        assert_contains(self, ble, "let usabilityReason = currentSessionUsable")
        assert_contains(self, ble, "\"provisional_historical_layout_old_or_unvalidated\"")

    def test_advanced_metrics_imu_decoder_is_research_gated(self):
        decoder = source(ROOT / "Atria" / "Atria" / "AtriaIMUDecoder.swift")
        steps = source(ROOT / "Atria" / "Atria" / "AtriaStrapStepResearch.swift")
        sleep = source(ROOT / "Atria" / "Atria" / "AtriaSleepWakeResearch.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "static func syntheticRestPayload",
            "static func syntheticShakePayload",
            "static func selfTestPassed() -> Bool",
            "abs(rest.meanMagnitudeG - 1.0) <= 0.05",
            "abs(shake.meanMagnitudeG - 2.0) <= 0.10",
            "gravityValidated ? \"gravity_validated\" : \"research_unvalidated\"",
        ]:
            assert_contains(self, decoder, needle)

        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        for needle in [
            "case research",
            "return \"Early\"",
            "return \"waveform.badge.magnifyingglass\"",
        ]:
            assert_contains(self, shared, needle)
        for needle in [
            "state: summary.frameCount > 0 ? .research : .learning",
            "state: summary.sampleRateHz == nil ? .learning : .research",
            "state: summary.layoutText == \"--\" ? .learning : .research",
            "state: summary.strapStepCount > 0 ? .research : .learning",
            "state: summary.sleepWakeText == \"--\" ? .learning : .research",
            "state: summary.probeFrameCount > 0 ? .research : .learning",
            "value: summary.spo2CandidateFrames > 0 ? \"Early\" : \"--\"",
            "value: summary.skinTemperatureDeviation.valueText",
            "unit: summary.skinTemperatureDeviation.isReady ? \"delta C\" : nil",
            "state: summary.skinTemperatureDeviation.isReady ? .research : .learning",
            "@State private var showResearchInfo = false",
            ".accessibilityLabel(\"Experimental sensor info\")",
            "AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,",
            "private struct AtriaResearchSignalInfoSheet: View",
            "Atria does not show an SpO2 percentage until quality checks pass.",
            "never absolute body temperature",
            "Atria does not write SpO2 or body-temperature values to HealthKit.",
            "footnote: summary.spo2CandidateFrames > 0 ? \"\\(summary.spo2CandidateFrames) candidate frames; not a SpO2 value.\" : \"Early reading; not a SpO2 value.\"",
            "footnote: summary.skinTemperatureDeviation.footnoteText",
            "footnote: \"Sleep-only estimate; needs comparison data.\"",
            "skin temperature only as a sleep-baseline deviation",
        ]:
            assert_contains(self, collection, needle)

        for needle in [
            "AtriaIMUDecoder.decode(payload: payload)",
            "recordIMUFeatures(decoded)",
            "ATRIADBG imu_candidate validated=%d validation_state=%@",
            "sample_rate_hz=%@",
            "metric_promotions=0 i16=%@",
            "imuSampleRateHzSum += Double(decoded.samples.count) / delta",
            "imuInferredScale = decoded.scale",
            "imuInferredEndian = decoded.endian.rawValue",
            "AtriaStrapStepResearch.estimate(samples: decoded.samples",
            "strap_steps_research=%d step_source=strap_imu_research",
            "AtriaSleepWakeResearch.classify(duration:",
            "imuValidationState = imuGravityValidatedFrameCount > 0 ? \"gravity_validated_research\" : \"research_unvalidated\"",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "enum AtriaStrapStepResearch",
            "guard current >= 1.12",
            "refractorySamples",
            "state: \"research_unvalidated\"",
        ]:
            assert_contains(self, steps, needle)
        assert_not_contains(self, steps, "phoneSteps")
        assert_not_contains(self, steps, "agreement(strapSteps:")

        for needle in [
            "enum AtriaSleepWakeResearch",
            "state: \"sleep_research\"",
            "state: \"wake_research\"",
            "confidence: \"research\"",
            "low_motion_low_hr",
        ]:
            assert_contains(self, sleep, needle)

        for needle in [
            "var imuSampleCount: Int? = nil",
            "var imuFrameCount: Int? = nil",
            "var imuSampleRateHz: Double? = nil",
            "var imuScale: Double? = nil",
            "var imuEndian: String? = nil",
            "var imuStillnessRatio: Double? = nil",
            "var imuMovementIntensity: Double? = nil",
            "var imuActivityBursts: Int? = nil",
            "var imuValidationState: String? = nil",
            "var strapStepResearchCount: Int? = nil",
            "var strapStepResearchAgreement: Double? = nil",
            "var strapStepResearchState: String? = nil",
            "var sleepWakeResearchState: String? = nil",
            "var sleepWakeResearchConfidence: String? = nil",
            "var sleepWakeResearchReason: String? = nil",
            "var sensorResearchProbeFrames: Int? = nil",
            "var spo2ResearchCandidateFrames: Int? = nil",
            "var skinTempResearchCandidateFrames: Int? = nil",
            "var skinTempResearchCandidateValueSum: Int? = nil",
            "var skinTempResearchCandidateValueCount: Int? = nil",
            "var activeCalories: Double? = nil",
            "var caloriesConfidence: String? = nil",
        ]:
            assert_contains(self, sessions, needle)

    def test_advanced_metrics_temp_spo2_probe_is_research_only(self):
        probe = source(ROOT / "Atria" / "Atria" / "AtriaResearchProbe.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        harness = source(ROOT / "live_device_debug.sh")
        analyzer = source(ROOT / "tools" / "analyze_sensor_research_probe.py")

        for needle in [
            "enum AtriaResearchProbe",
            "case metadata = \"0x31\"",
            "case historical = \"0x2f\"",
            "case diagnostic = \"61080007\"",
            "enum ModelGeneration",
            "case strapMG",
            "redactIdentifierLikeTokens",
            "(90...100).contains(value)",
            "(2_500...4_200).contains(value)",
            "oxygenOffsetSummary",
            "temperatureOffsetSummary",
            "modelGeneration(in: payload)",
        ]:
            assert_contains(self, probe, needle)

        for needle in [
            "case strap4",
            "case .strap4: return \"Strap 4.0\"",
            "case .strap4Class: return \"Strap\"",
            "guard summary.allowsGenerationSpecificDecode(strapAllowsGenerationSpecificDecode: supportsGenerationSpecificDecode),",
            "supportsSpO2Probe || supportsSkinTempProbe else { return }",
            "if historyOnlyProbeMode, source == .historical",
            "guard verboseBLEFrameLogging, researchProbeFrameCount < 3 else { return }",
            "AtriaResearchProbe.analyze(payload: payload, source: source)",
            "applyModelMetadataIfExplicit(summary)",
            "private var unknownGenerationProbeLogCount = 0",
            "guard unknownGenerationProbeLogCount == 0 else { return }",
            "unknownGenerationProbeLogCount += 1",
            "sensorResearchProbeFrames: researchProbeFrameCount > 0 ? researchProbeFrameCount : nil",
            "spo2ResearchCandidateFrames: researchProbeOxygenCandidateFrames > 0 ? researchProbeOxygenCandidateFrames : nil",
            "skinTempResearchCandidateFrames: researchProbeTemperatureCandidateFrames > 0 ? researchProbeTemperatureCandidateFrames : nil",
            "skinTempResearchCandidateValueSum: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueSum : nil",
            "skinTempResearchCandidateValueCount: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueCount : nil",
            "researchProbeTemperatureCandidateValueSum += summary.temperatureWordCandidates.reduce(0) { $0 + $1.value }",
            "researchProbeTemperatureCandidateValueCount += summary.temperatureWordCandidates.count",
            "ATRIADBG model_gate status=metadata_explicit model=%@ evidence=%@ source=%@",
            "ATRIADBG sensor_research_probe source=%@ status=research_unvalidated",
            "model_generation=%@ model_evidence=%@",
            "metric_promotions=0 healthkit_write=0 raw_storage=0",
        ]:
            assert_contains(self, ble, needle)

        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        for needle in [
            "struct SkinTemperatureDeviationSummary: Equatable",
            "let latestDeltaCelsius: Double?",
            "var valueText: String",
            "return String(format: \"%+.1f\", latestDeltaCelsius)",
            "vs sleep baseline",
            "relative baseline building, no absolute temperature",
            "Relative sleep-only deviation from \\(baselineSessions) prior local sessions; no absolute temperature.",
            "let skinTemperatureDeviation: SkinTemperatureDeviationSummary",
            "skinTemperatureDeviation = Self.makeSkinTemperatureDeviationSummary(sessions: sessions,",
            "private static func makeSkinTemperatureDeviationSummary(sessions: [SavedSession],",
            ".filter { $0.sleepWakeResearchState == \"sleep_research\" }",
            "Double(sum) / Double(count) / 100.0",
            "guard baseline.count >= 3 else",
            "latest.meanCelsius - baselineMean",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "metric_promotions=0 healthkit_write=0 raw_storage=0",
            "recordResearchProbeCandidate(payload: payload, source: .metadata)",
            "recordResearchProbeCandidate(payload: payload, source: .historical)",
            "recordResearchProbeCandidate(payload: [UInt8](data), source: .diagnostic)",
        ]:
            assert_contains(self, ble, needle)

        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        assert_contains(self, home, "strapModel: ble.strapModelLabel")
        assert_not_contains(self, home, "strapModel: ble.status == .connected ? ble.strapModelLabel : \"\"")
        assert_contains(self, settings, "LabeledContent(\"Model\")")
        assert_contains(self, settings, "Text(strapModel.isEmpty ? \"Strap\" : strapModel)")

        text = all_swift_source()
        assert_not_contains(self, text, ".oxygenSaturation")
        assert_not_contains(self, text, "HKQuantitySample(type: oxygen")

        for needle in [
            "\"sensor_research_probe_rows\": 0",
            "\"model_gate_assume_4_class_rows\": 0",
            "\"model_gate_metadata_explicit_rows\": 0",
            "\"metadata_0x31_frames\": 0",
            "\"metadata_0x31_lengths\": \"\"",
            "\"metadata_0x31_body_hashes\": \"\"",
            "ATRIADBG sensor_research_probe ",
            "ATRIADBG model_gate ",
            "tokens.get(\"spo2_candidate_frames\", \"\")",
            "tokens.get(\"model_evidence\", \"\")",
            "metadata_0x31_body_hashes[hashlib.sha256(payload).hexdigest()[:16]] += 1",
            "--history-safe-backfill",
            "history_safe_backfill=1",
            "quiet_ble_logs=1",
        ]:
            assert_contains(self, harness, needle)

        for needle in [
            "ATRIADBG sensor_research_probe ",
            "ATRIADBG frame ch=([0-9A-Fa-f-]+) len=(\\d+) hex=([0-9A-Fa-f]+)",
            "frame_61080005_types",
            "metadata_0x31_frames",
            "metadata_0x31_lengths",
            "metadata_0x31_body_hashes",
            "metadata_0x31_printable",
            "metadata_explicit_model_tokens",
            "hashlib.sha256(body).hexdigest()[:16]",
            "redact_identifier_like_tokens",
            "probe_sources",
            "model_generations",
            "spo2_top_offsets",
            "skin_temp_top_offsets",
            "metric_promotions",
            "healthkit_writes",
            "raw_storage",
            "research_only",
        ]:
            assert_contains(self, analyzer, needle)

    def test_self_induced_probe_markers_are_local_research_only(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "struct ResearchManeuverMarker: Codable, Identifiable, Equatable",
            "case breathHold",
            "case heatExposure",
            "case coldExposure",
            "case walkTest",
            "static let key = \"atria.researchManeuverMarkers.v1\"",
            "var researchManeuverMarkers: [ResearchManeuverMarker]",
            "struct ResearchManeuverProbeCorrelationSummary: Equatable",
            "@Published private(set) var researchManeuverProbeCorrelationSummary",
            "private func recomputeCollectionResearchSummaries()",
            "researchManeuverProbeCorrelationSummary = ResearchManeuverProbeCorrelationSummary(markers: cachedResearchManeuverMarkers",
            "func markResearchManeuver(_ kind: ResearchManeuverMarker.Kind",
            "ATRIADBG research_maneuver_marker status=marked",
            "local_only=1 research_only=1 metric_promotions=0 healthkit_write=0 raw_storage=0",
            "static let correlationWindow: TimeInterval = 15 * 60",
            "guard (session.sensorResearchProbeFrames ?? 0) > 0 else { return false }",
            "marker.timestamp >= lower && marker.timestamp <= upper",
            "oxygenCandidateFrames",
            "temperatureCandidateFrames",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "researchManeuverCard",
            "AtriaResearchManeuverMarkerCard(markers: store.researchManeuverMarkers",
            "correlationSummary: store.researchManeuverProbeCorrelationSummary",
            "private struct AtriaResearchManeuverMarkerCard: View, Equatable",
            "private static let relativeMarkerFormatter: RelativeDateTimeFormatter",
            "formatter.unitsStyle = .short",
            "AtriaPanelSectionHeader(title: \"Probe markers\", subtitle: \"\")",
            "ForEach(ResearchManeuverMarker.Kind.allCases)",
            ".atriaCardAction(prominent: false, tint: .teal)",
            "AtriaMetricTile(label: \"Probe match\"",
            "state: markers.isEmpty ? .learning : .research",
            "state: correlationSummary.matchedMarkers > 0 ? .research : .learning",
            "Markers stay on device and help compare probe timing.",
            "Self.relativeMarkerFormatter.localizedString(for: marker.timestamp, relativeTo: Date())",
        ]:
            assert_contains(self, collection, needle)

        assert_not_contains(self, collection, "RelativeDateTimeFormatter().localizedString")
        assert_not_contains(
            self,
            collection,
            "private var correlationSummary: ResearchManeuverProbeCorrelationSummary",
        )
        assert_not_contains(self, collection, "private struct ResearchManeuverProbeCorrelationSummary: Equatable")
        assert_not_contains(self, collection, "ResearchManeuverProbeCorrelationSummary(markers: store.researchManeuverMarkers")

        for forbidden in [
            "markResearchManeuver",
            "ResearchManeuverMarker",
            "researchManeuverMarkers",
        ]:
            assert_not_contains(self, healthkit, forbidden)

    def test_bp_ecg_are_fail_closed_on_strap4(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var sensorAvailabilitySection: some View",
            "ECG not supported",
            "WHOOP 4.0 has no electrodes, so Atria does not fake an ECG.",
            "Blood pressure not supported",
            "WHOOP 4.0 is not cuff-calibrated, so Atria does not estimate BP.",
            "Blood oxygen signal",
            "Sleep-only evidence; no SpO2 percentage or Health export yet.",
            "Body temperature signal",
            "Skin-temp deviation only; no absolute body temperature or Health export.",
            "Atria shows only hardware-backed readings.",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "var supportsECG: Bool { self == .strapMG }",
            "var supportsBloodPressure: Bool { self == .strapMG }",
            "var readTypes: Set<HKObjectType> = [heartRateType, bloodPressureSystolicType, bloodPressureDiastolicType]",
            "private func auditCuffBloodPressureReadAvailability(reason: String)",
            "auditBloodPressureComponentReadAvailability(type: bloodPressureSystolicType",
            "auditBloodPressureComponentReadAvailability(type: bloodPressureDiastolicType",
            "HKSampleQuery(sampleType: type",
            "ATRIADBG healthkit_cuff_bp_read status=%@",
            "source=healthkit_read write_bp=0 strap_bp=0 cuff_only=1",
            "auditCuffBloodPressureReadAvailability(reason: \"authorization_cached\")",
            "auditCuffBloodPressureReadAvailability(reason: \"authorization_granted\")",
            "auditCuffBloodPressureReadAvailability(reason: \"up_to_date\")",
        ]:
            assert_contains(self, ble + healthkit, needle)

        for forbidden in [
            "HKQuantitySample(type: bloodPressureSystolicType",
            "HKQuantitySample(type: bloodPressureDiastolicType",
            "AFib",
            "atrial fibrillation",
        ]:
            assert_not_contains(self, all_swift_source(), forbidden)

    def test_production_capture_defaults_land_on_balanced_profile(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "case balanced",
            "case .balanced: return \"Balanced\"",
            "return .balanced",
            "defaults.removeObject(forKey: CollectionProfileDefaults.profile)",
            "defaults.removeObject(forKey: DutyCycleDefaults.enabled)",
            "defaults.removeObject(forKey: DutyCycleDefaults.focusFullCapture)",
            "collectionProfile = .balanced",
            "defaults.set(CollectionProfile.balanced.rawValue, forKey: CollectionProfileDefaults.profile)",
            "collectionProfile = CollectionProfile.load(defaults: defaults)",
        ]:
            assert_contains(self, text, needle)

    def test_production_capture_defaults_enable_protected_long_wear(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "static let protectedLongWearMigrated",
            "defaults.set(true, forKey: CaptureDefaults.protectedLongWearMigrated)",
            "defaults.set(true, forKey: LongWearDefaults.enabled)",
            "defaults.set(true, forKey: RadioDefaults.standardHROnly)",
            "longWearModeEnabled = true",
            "standardHROnlyMode = true",
            "standardHROnlyEnabled = true",
            "recordRadioMode(\"standard_hr_only\", reason: \"protected_default\")",
            "mode=protected_long_wear_default",
            "long_wear_default=1",
            "standard_hr_only_default=1",
            "offline_sync_default=1",
            "protected_background_collection_default",
        ]:
            assert_contains(self, text, needle)

    def test_harness_classifies_untrusted_developer_profile_launch(self):
        text = source(ROOT / "live_device_debug.sh")

        for needle in [
            "launch_output_lines = []",
            "launch_output_lines.append(line)",
            "\"invalid code signature\" in launch_output",
            "\"profile has not been explicitly trusted\" in launch_output",
            "\"BSErrorCodeDescription = RequestDenied\" in launch_output",
            "HARNESS_ERROR=developer_profile_not_trusted",
            "HARNESS_NEXT_ACTION=trust_developer_profile_in_ios_settings_then_retry",
        ]:
            assert_contains(self, text, needle)

    def test_live_device_harness_supports_release_build_configuration(self):
        text = source(ROOT / "live_device_debug.sh")

        for needle in [
            "build_configuration=${ATRIA_BUILD_CONFIGURATION:-Debug}",
            "--configuration Debug|Release",
            "--release            Shorthand for --configuration Release.",
            "build_configuration=${2:?--configuration requires a value}",
            "build_configuration=Release",
            "case \"$build_configuration\" in",
            "Debug|Release) ;;",
            "app_path=\"${derived_data}/Build/Products/${build_configuration}-iphoneos/Atria.app\"",
            "-configuration \"$build_configuration\"",
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, "Build/Products/Debug-iphoneos/Atria.app\"")
        assert_not_contains(self, text, "-configuration Debug \\")
        self.assertGreaterEqual(text.count("-configuration \"$build_configuration\""), 3)

    def test_state_restoration_reuses_restored_peripheral(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var pendingScanReason: String?",
            "pendingScanReason = reason",
            "let reason = pendingScanReason ?? \"central_powered_on\"",
            "ATRIADBG ble_restore status=reuse_restored reason=fresh_scan_deferred",
            "ATRIADBG ble_restore status=reuse_restored reason=standard_hr_only",
            "recordLinkObservedConnected(reason: \"state_restore_connected\"",
            "central.connect(restoredPeripheral, options: nil)",
        ]:
            assert_contains(self, text, needle)

        restore_method = re.search(
            r"nonisolated func centralManager\(_ central: CBCentralManager, willRestoreState dict: \[String: Any\]\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(restore_method)
        body = restore_method.group("body")
        self.assertNotIn("cancelPeripheralConnection", body)
        self.assertNotIn("full_protocol_fresh_scan", body)

    def test_long_wear_keepalive_survives_app_switch(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")

        for needle in [
            "enum KeepaliveDefaults",
            "static let armedAt = \"atria.keepalive.armedAt\"",
            "static let tickStartedAt = \"atria.keepalive.tickStartedAt\"",
            "static let lastTickAt = \"atria.keepalive.lastTickAt\"",
            "static let timerStartedAt = \"atria.keepalive.timerStartedAt\"",
            "static let timerFiredAt = \"atria.keepalive.timerFiredAt\"",
            "static let dispatchTimerStartedAt = \"atria.keepalive.dispatchTimerStartedAt\"",
            "static let dispatchTimerFiredAt = \"atria.keepalive.dispatchTimerFiredAt\"",
            "static let lastPeripheralState = \"atria.keepalive.lastPeripheralState\"",
            "private var foregroundKeepaliveProbeWorkItems: [DispatchWorkItem] = []",
            "private func ensureForegroundKeepaliveWatchdog(reason: String)",
            "private func runForegroundKeepaliveTick(",
            "private func runForegroundKeepaliveTickFromSupervisor()",
            "private func resetHeartRateNotifyIfNeeded(peripheral: CBPeripheral, characteristic: CBCharacteristic, reason: String)",
            "peripheral.setNotifyValue(false, for: characteristic)",
            "ATRIADBG ble_notify_reassert status=reset_requested",
            "private func elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: String)",
            "private func restoreProtectedLongWearRadioIfNeeded(reason: String)",
            "applyStandardHROnly(enabled: false, persist: false, reconnect: false, reason: reason)",
            "rediscoverFullProtocolServicesIfConnected(reason: reason)",
            "private func rediscoverFullProtocolServicesIfConnected(reason: String)",
            "peripheral.discoverServices(Self.UUIDs.discoveryServices)",
            "ATRIADBG radio_mode full_protocol_discovery status=requested",
            "ensureForegroundKeepaliveWatchdog(reason: \"scene_active\")",
            "startLongWearMode(rest: rest, maxHR: maxHR, reason: \"scene_active_foreground\")",
            "keep_supervisor_and_keepalive_armed",
            "elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: \"scene_active_interactive\")",
            "ensureForegroundKeepaliveWatchdog(reason: reason)",
            "restoreProtectedLongWearRadioIfNeeded(reason: reason)",
            "foreground_keepalive armed=1",
            "foreground_keepalive status=silent",
            "if reason.contains(\"scene_active\")",
            "startForegroundKeepaliveWatchdog(reason: \"\\(reason)_restart\")",
            "defaults.set(armedAt.timeIntervalSince1970, forKey: KeepaliveDefaults.armedAt)",
            "defaults.set(armedAt.timeIntervalSince1970, forKey: KeepaliveDefaults.timerStartedAt)",
            "defaults.set(armedAt.timeIntervalSince1970, forKey: KeepaliveDefaults.dispatchTimerStartedAt)",
            "defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.tickStartedAt)",
            "defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastTickAt)",
            "KeepaliveDefaults.timerFiredAt",
            "KeepaliveDefaults.dispatchTimerFiredAt",
            "defaults.synchronize()",
            "foreground_keepalive_missing_peripheral",
            "foreground_keepalive_peripheral_not_connected",
            "foreground_keepalive status=peripheral_not_connected",
            "notify_reassert_peripheral_state_\\(peripheral.state.rawValue)",
            "ble_notify_reassert status=peripheral_not_connected",
            "reconnectToSavedPeripheralIfPossible(reason: \"foreground_keepalive_missing_peripheral\")",
            "reconnectToSavedPeripheralIfPossible(reason: \"foreground_keepalive_peripheral_state_\\(peripheral.state.rawValue)\")",
            "startScan(reason: \"foreground_keepalive_missing_peripheral\")",
            "startScan(reason: \"foreground_keepalive_peripheral_state_\\(peripheral.state.rawValue)\")",
            "reconnectToSavedPeripheralIfPossible(reason: \"\\(reason)_resume_known_strap\")",
            "let initialSilenceTimeout: TimeInterval = 8",
            "let initialReconnectWindow: TimeInterval = 20",
        ]:
            assert_contains(self, text, needle)

        handle_unattended = re.search(
            r"func handleUnattendedMode\(rest: Int, maxHR: Int, reason: String\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(handle_unattended)
        unattended_body = handle_unattended.group("body")
        assert_contains(self, unattended_body, "ensureForegroundKeepaliveWatchdog(reason: reason)")
        assert_contains(self, unattended_body, "restoreProtectedLongWearRadioIfNeeded(reason: reason)")
        self.assertNotIn("stopForegroundKeepaliveWatchdog(reason: reason)\n        guard longWearModeEnabled", unattended_body)

        handle_foreground = re.search(
            r"func handleInteractiveForeground\(rest: Int, maxHR: Int\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(handle_foreground)
        foreground_body = handle_foreground.group("body")
        assert_contains(self, foreground_body, "restoreActiveSessionJournalIfNeeded(reason: \"scene_active_foreground\")")
        assert_contains(self, foreground_body, "startLongWearMode(rest: rest, maxHR: maxHR, reason: \"scene_active_foreground\")")
        assert_contains(self, foreground_body, "elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: \"scene_active_interactive\")")
        assert_not_contains(self, foreground_body, "pauseLongWearAutomation(reason: \"scene_active\")")

        pull = source(ROOT / "pull_atria_state.sh")
        for needle in [
            "def emit_keepalive_preferences():",
            "def emit_ble_link_preferences():",
            "def emit_watchdog_preferences():",
            "def emit_sample_preferences():",
            "hr_broadcast_debug_interpretation=phone_ble_peripheral_broadcast_not_strap_connection",
            "ble_link_last_status=",
            "ble_link_last_reason=",
            "ble_link_saved_peripheral_present=",
            "hr_continuity_status=",
            "hr_continuity_action=",
            "hr_continuity_raw_gap_s=",
            "rr_presence_status=",
            "rr_presence_action=",
            "watchdog_last_source=",
            "watchdog_last_action=",
            "sample_raw_notifications=",
            "sample_accepted_samples=",
            "sample_last_status=",
            "keepalive_namespace=",
            "keepalive_last_status=",
            "keepalive_ticks=",
            "keepalive_last_peripheral_state=",
            "keepalive_armed_age_s=",
            "keepalive_tick_started_age_s=",
            "keepalive_last_tick_age_s=",
            "keepalive_timer_started_age_s=",
            "keepalive_timer_fired_age_s=",
            "keepalive_dispatch_timer_started_age_s=",
            "keepalive_dispatch_timer_fired_age_s=",
            "keepalive_last_raw_notifications=",
            "keepalive_last_raw_notification_delta=",
            "keepalive_last_sample_check_age_s=",
            "keepalive_last_read_poll_result_age_s=",
            "keepalive_last_read_poll_result_status=",
            "keepalive_last_read_poll_result_bpm=",
            "keepalive_last_read_poll_result_rr_values=",
            "strap_stream_state=",
            "strap_stream_reason=",
            "strap_stream_packet_age_s=",
            "strap_stream_battery_level=",
            "strap_stream_low_battery_reconnect_suppressed=",
            "strap_stream_low_battery_reconnect_suppression_reason=",
            "strap_stream_low_battery_reconnect_suppression_count=",
            "strap_stream_low_battery_reconnect_rearmed_age_s=",
            "strap_stream_accessibility_label=",
            "notification_battery_warning_drain_cycle_scheduled=",
            "notification_battery_shutoff_drain_cycle_scheduled=",
            "notification_battery_drain_cycle_cleared_age_s=",
            "emit_ble_link_preferences()",
            "emit_watchdog_preferences()",
            "emit_sample_preferences()",
            "emit_keepalive_preferences()",
            "emit_strap_stream_preferences()",
            "emit_notification_preferences()",
        ]:
            assert_contains(self, pull, needle)

        for needle in [
            "private enum SceneDefaults",
            "static let phase = \"atria.scene.phase\"",
            "static let lastActiveAt = \"atria.scene.lastActiveAt\"",
            "static let lastInactiveAt = \"atria.scene.lastInactiveAt\"",
            "static let lastBackgroundAt = \"atria.scene.lastBackgroundAt\"",
            "static let fastLaunchAt = \"atria.scene.fastLaunchAt\"",
            "static let applicationState = \"atria.scene.applicationState\"",
            "static let lastDidBecomeActiveAt = \"atria.scene.lastDidBecomeActiveAt\"",
            "static let lastWillEnterForegroundAt = \"atria.scene.lastWillEnterForegroundAt\"",
            "recordScenePhase(\"appear\", reason: \"content_on_appear\")",
            "recordScenePhase(\"background\", reason: \"scene_background\")",
            "recordScenePhase(\"inactive\", reason: \"scene_inactive\")",
            "recordScenePhase(\"active\", reason: \"scene_active\")",
            "let isInteractiveForeground = isInteractiveForegroundLaunch()",
            "let fastLaunchReason = isInteractiveForeground ? \"fast_launch_active\" : \"fast_launch_background\"",
            "if isInteractiveForeground {",
            "ble.applyPersistentLongWearModeIfNeeded(rest: store.baseline.restingInt ?? 60,",
            "private func isInteractiveForegroundLaunch() -> Bool",
            "UIApplication.shared.applicationState == .active || scenePhase == .active",
            "UIApplication.didBecomeActiveNotification",
            "UIApplication.willEnterForegroundNotification",
            "recordScenePhase(\"active\", reason: \"ui_did_become_active\")",
            "ble.handleInteractiveForeground(rest: store.baseline.restingInt ?? 60,",
            "applicationStateLabel(UIApplication.shared.applicationState)",
            "defaults.synchronize()",
            "ATRIADBG scene_phase phase=%@ reason=%@",
        ]:
            assert_contains(self, app, needle)

        for needle in [
            "def emit_scene_preferences():",
            "scene_namespace=",
            "scene_phase=",
            "scene_reason=",
            "scene_application_state=",
            "scene_updated_age_s=",
            "scene_last_active_age_s=",
            "scene_last_inactive_age_s=",
            "scene_last_background_age_s=",
            "scene_fast_launch_age_s=",
            "scene_last_did_become_active_age_s=",
            "scene_last_will_enter_foreground_age_s=",
            "emit_scene_preferences()",
        ]:
            assert_contains(self, pull, needle)

        background_transition = re.search(
            r"func handleSceneBackgroundTransition\(reason: String, rest: Int, maxHR: Int\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(background_transition)
        background_body = background_transition.group("body")
        assert_contains(self, background_body, "restoreProtectedLongWearRadioIfNeeded(reason: reason)")

        keepalive = re.search(
            r"private func startForegroundKeepaliveWatchdog\(reason: String\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(keepalive)
        keepalive_body = keepalive.group("body")
        assert_contains(self, keepalive_body, "runForegroundKeepaliveTick(")
        assert_contains(self, keepalive_body, "try? await Task.sleep(for: .seconds(checkInterval))")
        assert_contains(self, keepalive_body, "Timer(timeInterval: checkInterval, repeats: true)")
        assert_contains(self, keepalive_body, "RunLoop.main.add(timer, forMode: .common)")
        assert_contains(self, keepalive_body, "timer.tolerance = 2")
        assert_contains(self, keepalive_body, "foregroundKeepaliveTimer = timer")
        for needle in [
            "let currentRawNotifications = sampleDiagnostics.rawNotifications",
            "currentRawNotifications <= previousRawNotifications",
            "UIApplication.shared.applicationState == .active",
            "foreground_keepalive_sample_counter_stalled",
            "foreground_keepalive_packet_age_stalled",
            "forceHardReconnectForPacketStall(peripheral: peripheral,",
            "central.cancelPeripheralConnection(target)",
            "SampleDefaults.lastRawNotificationAt",
            "enum StrapStreamState: String",
            "case lowBatteryShutoff = \"low_battery_shutoff\"",
            "case lowBatteryReducedDetail = \"low_battery_reduced_detail\"",
            "static let state = \"atria.strapStream.state\"",
            "static let lowBatteryReconnectSuppressed = \"atria.strapStream.lowBatteryReconnectSuppressed\"",
            "static let lowBatteryReconnectSuppressionReason = \"atria.strapStream.lowBatteryReconnectSuppressionReason\"",
            "static let lowBatteryReconnectSuppressionCount = \"atria.strapStream.lowBatteryReconnectSuppressionCount\"",
            "static let lowBatteryReconnectRearmedAt = \"atria.strapStream.lowBatteryReconnectRearmedAt\"",
            "static let lastReadPollResultAt = \"atria.keepalive.lastReadPollResultAt\"",
            "static let lastReadPollResultStatus = \"atria.keepalive.lastReadPollResultStatus\"",
            "static let lastReadPollResultBPM = \"atria.keepalive.lastReadPollResultBPM\"",
            "static let lastReadPollResultRRValues = \"atria.keepalive.lastReadPollResultRRValues\"",
            "recordHeartRateReadPollResultIfNeeded(parsed: parsed)",
            "now.timeIntervalSince1970 - readPollAt <= 10",
            "defaults.set(\"value_received\", forKey: KeepaliveDefaults.lastReadPollResultStatus)",
            "defaults.set(\"parse_failed\", forKey: KeepaliveDefaults.lastReadPollResultStatus)",
            "updateStrapStreamState(reason: \"foreground_keepalive\"",
            "recentRawNotificationDelta = defaults.integer(forKey: KeepaliveDefaults.lastRawNotificationDelta)",
            "recentSampleCheckAge <= 180 ? recentRawNotificationDelta : 0",
            "let freshChargedNotification = status == .connected",
            "batteryLevel > Self.lowBatteryWarningThreshold",
            "resolvedPacketAge.map { $0 <= 10 }",
            "notificationsGrowing || freshChargedNotification",
            "strapStreamState == .lowBatteryShutoff",
            "defaults.set(\"low_battery_shutoff\", forKey: KeepaliveDefaults.lastStatus)",
            "defaults.set(\"suppress_hard_reconnect\", forKey: KeepaliveDefaults.lastAction)",
            "markLowBatteryReconnectSuppressed(reason: \"low_battery_shutoff\"",
            "markLowBatteryReconnectSuppressed(reason: \"low_battery_shutoff_fresh_scan\"",
            "private var batteryDrainThermalBackoffActive: Bool",
            "batteryRecentlyDropping && !batteryIsCharging && batteryLevel >= 0",
            "private var effectiveThermalCadenceMultiplier: Double",
            "batteryDrainThermalBackoffActive ? 1.75 : 1",
            "private var effectivePowerThermalMode: String",
            "\"warm_battery_drain\"",
            "minimumInterval * effectiveThermalCadenceMultiplier",
            "config.baseTickInterval * effectiveThermalCadenceMultiplier",
            "clearLowBatteryReconnectSuppression(defaults: defaults, now: now)",
            "action=keep_link_for_battery_reads",
            "Strap battery too low for live heart rate. Charge your strap to resume tracking.",
        ]:
            assert_contains(self, text, needle)
        assert_contains(self, keepalive_body, "DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))")
        assert_contains(self, keepalive_body, "dispatchTimer.schedule(deadline: .now() + checkInterval, repeating: checkInterval, leeway: .seconds(2))")
        assert_contains(self, keepalive_body, "foregroundKeepaliveDispatchTimer = dispatchTimer")
        assert_contains(self, keepalive_body, "dispatchTimer.resume()")
        assert_contains(self, keepalive_body, "scheduleForegroundKeepaliveProofProbes(")
        self.assertNotIn("guard foregroundInteractiveMode, longWearModeEnabled", keepalive_body)

        keepalive_tick = re.search(
            r"private func runForegroundKeepaliveTick\((?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(keepalive_tick)
        keepalive_tick_body = keepalive_tick.group("body")
        assert_contains(self, keepalive_tick_body, "guard longWearModeEnabled else {")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"disabled\", forKey: KeepaliveDefaults.lastStatus)")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"wait_long_wear_enabled\", forKey: KeepaliveDefaults.lastAction)")
        assert_contains(self, keepalive_tick_body, "guard peripheral.state == .connected else {")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"peripheral_not_connected\", forKey: KeepaliveDefaults.lastStatus)")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"reconnect_known_strap\", forKey: KeepaliveDefaults.lastAction)")
        assert_contains(self, keepalive_tick_body, "resetHeartRateNotifyIfNeeded(peripheral: peripheral,")
        assert_contains(self, keepalive_tick_body, "let hasSeenPacket = lastRawHRNotificationAt != nil")
        assert_contains(self, keepalive_tick_body, "let effectiveSilenceTimeout = hasSeenPacket ? silenceTimeout : initialSilenceTimeout")
        assert_contains(self, keepalive_tick_body, "let reconnectWindow = hasSeenPacket ? silenceTimeout : initialReconnectWindow")

        proof_probes = re.search(
            r"private func scheduleForegroundKeepaliveProofProbes\((?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(proof_probes)
        proof_body = proof_probes.group("body")
        assert_contains(self, proof_body, "let delays: [TimeInterval] = [12, 30, 60]")
        assert_contains(self, proof_body, "foregroundKeepaliveProbeWorkItems.forEach { $0.cancel() }")
        assert_contains(self, proof_body, "DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)")
        assert_contains(self, proof_body, "self.runForegroundKeepaliveTick(")

        supervisor_tick = re.search(
            r"private func runForegroundKeepaliveTickFromSupervisor\(\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(supervisor_tick)
        supervisor_tick_body = supervisor_tick.group("body")
        assert_contains(self, supervisor_tick_body, "guard defaults.bool(forKey: KeepaliveDefaults.armed) else { return }")
        assert_contains(self, supervisor_tick_body, "runForegroundKeepaliveTick(")

        long_wear_supervisor = re.search(
            r"private func scheduleLongWearSupervisor\(config: LongWearSupervisorConfig\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(long_wear_supervisor)
        assert_contains(self, long_wear_supervisor.group("body"), "runForegroundKeepaliveTickFromSupervisor()")

        event_interval = re.search(
            r"private func currentEventDrivenCheckpointInterval\(\) -> TimeInterval \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(event_interval)
        event_interval_body = event_interval.group("body")
        assert_contains(self, event_interval_body, "let configured = configuredLongWearCheckpointInterval()")
        assert_contains(self, event_interval_body, "let base = foregroundInteractiveMode ? configured : max(minimumEventDrivenCheckpointInterval, configured)")
        assert_contains(self, event_interval_body, "return base * effectiveThermalCadenceMultiplier")

        event_checkpoint = re.search(
            r"private func checkpointFromLiveEventIfNeeded\(now: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(event_checkpoint)
        event_checkpoint_body = event_checkpoint.group("body")
        assert_not_contains(self, event_checkpoint_body, "guard !foregroundInteractiveMode else { return }")
        assert_contains(self, event_checkpoint_body, "foregroundInteractiveMode ? \"All-day wear\" : \"Unattended workout\"")
        assert_contains(self, event_checkpoint_body, "source=ble_event app_state=%@ foreground_interactive=%d")

    def test_full_protocol_has_notify_fallback_when_stream5_is_missing(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var proprietaryNotifyFallbackTask: Task<Void, Never>?",
            "private var activeProprietaryNotifyUUIDs = Set<CBUUID>()",
            "private var strapStream5NotifyConfirmed = false",
            "private func scheduleProprietaryArmFallbackIfNeeded(reason: String)",
            "private func armWhenProprietaryNotifyPairReadyIfNeeded(reason: String) -> Bool",
            "private nonisolated static func discoveryShouldUseProtectedStandardHR(standardSnapshot: Bool,",
            "return recordedMode != \"full_protocol\"",
            "let discoveryUsesProtectedStandardHR = Self.discoveryShouldUseProtectedStandardHR(",
            "if discoveryUsesProtectedStandardHR",
            "ATRIADBG proprietary_arm_fallback status=arming",
            "armWhenProprietaryNotifyPairReadyIfNeeded(reason: \"characteristics_discovered_notify_pair_ready\")",
            "scheduleProprietaryArmFallbackIfNeeded(reason: \"characteristics_discovered\")",
            "armWhenProprietaryNotifyPairReadyIfNeeded(reason: \"tx_only_discovered_notify_pair_ready\")",
            "scheduleProprietaryArmFallbackIfNeeded(reason: \"tx_only_discovered\")",
            "scheduleProprietaryArmFallbackIfNeeded(reason: \"notify_state_",
            "activeProprietaryNotifyUUIDs.insert(characteristic.uuid)",
            "activeProprietaryNotifyUUIDs.count >= 2",
            "armWhenProprietaryNotifyPairReadyIfNeeded(reason: \"notify_pair_ready\")",
            "strapStream5NotifyConfirmed = true",
            "proprietaryNotifyFallbackTask?.cancel()",
        ]:
            assert_contains(self, text, needle)

    def test_long_wear_disconnect_preserves_session_continuity(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private var userRequestedDisconnect = false",
            "userRequestedDisconnect = true",
            "let wasUserRequestedDisconnect = userRequestedDisconnect",
            "let shouldPreserveLongWearSession = longWearModeEnabled && !wasUserRequestedDisconnect",
            "persistActiveSessionJournalIfNeeded(reason: \"\\(reason)_continuity_checkpoint\", force: true)",
            "markRangeLossBackfillRequired(reason: backfillReason)",
            "strap_low_battery_broadcast_off",
            "@Published private(set) var lastScanRequestedAt: Date?",
            "@Published private(set) var lastScanMatchAt: Date?",
            "@Published private(set) var pendingKnownReconnectStartedAt: Date?",
            "@Published private(set) var pendingKnownReconnectReason = \"\"",
            "private func markPendingKnownReconnect(reason: String)",
            "private func clearPendingKnownReconnect(reason: String)",
            "markPendingKnownReconnect(reason: reason)",
            "clearPendingKnownReconnect(reason: \"did_connect\")",
            "clearPendingKnownReconnect(reason: \"forget\")",
            "self.lastScanMatchAt = Date()",
            "autoSaveStatus = session.isEmpty ? \"skipped_continuity_empty\" : \"checkpointed_continuity\"",
            "scheduleRangeLossBackfillIfNeeded(reason: \"did_connect\")",
            "scheduleRangeLossBackfillIfNeeded(reason: \"state_restore_connected\")",
            "preserveLongWearRangeLossRecovery(reason: \"foreground_keepalive\")",
            "preserveLongWearRangeLossRecovery(reason: \"no_data_watchdog\")",
            "preserveLongWearRangeLossRecovery(reason: \"accepted_hr_watchdog\")",
            "preserveLongWearRangeLossRecovery(reason: \"central_powered_off\")",
            "ATRIADBG ble_link status=disconnected reason=user_disconnect action=stay_disconnected",
            "private let minimumFinishedLongWearDuration: TimeInterval = 5 * 60",
            "saved.duration < minimumFinishedLongWearDuration",
            "retained_short_fragment",
            "reason=long_wear_short_fragment",
            "action=retain_active_journal",
        ]:
            assert_contains(self, text, needle)

        disconnect_handler = re.search(
            r"nonisolated func centralManager\(_ central: CBCentralManager,\s+didDisconnectPeripheral peripheral: CBPeripheral, error: Error\?\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(disconnect_handler)
        body = disconnect_handler.group("body")
        preserve_index = body.find("if shouldPreserveLongWearSession")
        finish_index = body.find("finishSession(label:")
        reconnect_index = body.find("recordLinkAttempt(reason: \"did_disconnect_reconnect\"")
        self.assertGreaterEqual(preserve_index, 0)
        self.assertGreater(finish_index, preserve_index)
        self.assertGreater(reconnect_index, finish_index)

    def test_long_wear_auto_save_keeps_live_session_open(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        auto_save = re.search(
            r"private func runLongWearSupervisorAutoSave\(index: Int, label: String, rest: Int, maxHR: Int\) -> Bool \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(auto_save)
        body = auto_save.group("body")
        assert_not_contains(self, body, "finishSession(label: label)")
        assert_contains(self, body, "let saved = snapshot")
        assert_contains(self, body, "workout_auto_save_snapshot_supervisor")
        assert_contains(self, body, "mode=snapshot_keep_live")
        assert_contains(self, body, "return false")

    def test_live_sample_counters_flush_on_healthy_stream(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        raw = re.search(
            r"private func recordRawHRNotification\(hr: Int, at sampleTime: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(raw)
        raw_body = raw.group("body")
        self.assertGreater(raw_body.find("sampleDiagnostics.rawNotifications += 1"), -1)
        self.assertGreater(raw_body.rfind("scheduleSampleDiagnosticsFlush()"), raw_body.find("lastRawHRNotificationAt = sampleTime"))

        accepted = re.search(
            r"private func recordAcceptedHRSample\(rate: Int, at sampleTime: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(accepted)
        accepted_body = accepted.group("body")
        self.assertGreater(accepted_body.find("sampleDiagnostics.acceptedSamples += 1"), -1)
        self.assertGreater(accepted_body.rfind("scheduleSampleDiagnosticsFlush()"), accepted_body.find("sampleDiagnostics.lastReason == \"accepted_gap\""))

        lifecycle = re.search(
            r"func flushLifecycleRealtimeState\(reason: String\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(lifecycle)
        lifecycle_body = lifecycle.group("body")
        assert_contains(self, lifecycle_body, "flushSampleDiagnostics()")
        assert_contains(self, lifecycle_body, "flushActiveSessionJournal(reason: reason)")

        rr_batch_start = text.find("private func addRRBatch(intervalsMS: [Int],")
        self.assertGreater(rr_batch_start, -1)
        rr_batch_end = text.find("private func requestDeferredHRVSnapshotRefreshIfNeeded", rr_batch_start)
        self.assertGreater(rr_batch_end, rr_batch_start)
        rr_batch_body = text[rr_batch_start:rr_batch_end]
        assert_contains(self, rr_batch_body, "rrArchive.append(contentsOf: appendPayload.intervals)")
        assert_contains(self, rr_batch_body, "persistActiveSessionJournalForRRIfNeeded(reason: \"standard_rr_batch\", now: frameTime)")

        rr_journal = re.search(
            r"private func persistActiveSessionJournalForRRIfNeeded\(reason: String, now: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(rr_journal)
        rr_journal_body = rr_journal.group("body")
        assert_contains(self, rr_journal_body, "rrArchive.count > lastActiveJournalSavedRRArchiveCount")
        assert_contains(self, rr_journal_body, "now.timeIntervalSince(lastActiveJournalSaveAt) < 5")
        assert_contains(self, rr_journal_body, "persistActiveSessionJournalIfNeeded(reason: reason, force: true)")

    def test_healthkit_hrv_export_uses_validated_sdnn_only(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "private var hrvType",
            ".heartRateVariabilitySDNN",
            "if let sdnn = session.referenceValidatedSDNN, sdnn > 0",
        ]:
            assert_contains(self, text, needle)
        for needle in ["referenceValidatedRMSSD", "rmssdExported"]:
            assert_not_contains(self, text, needle)

    def test_healthkit_sleep_stage_export_requires_validated_stage_source(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "\"atria_sleep_stage_evidence\": sleep.source == \"validated_sleep_stages\" ? \"validated\" : \"non_validated\"",
            "guard sleep.source == \"validated_sleep_stages\"",
            "value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue",
            "stageMetadata[\"atria_sleep_stage\"] = segment.stage.rawValue",
            "value: healthKitSleepValue(for: segment.stage)",
        ]:
            assert_contains(self, text, needle)

    def test_healthkit_rhr_and_respiratory_rate_export_use_correct_types(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private var restingHeartRateType",
            ".restingHeartRate",
            "private var respiratoryRateType",
            ".respiratoryRate",
            "session.restingStable > 0",
            "HKQuantitySample(type: restingHeartRateType",
            "func sleepRespiratoryRate(rest: Int, maxHR: Int, calendar: Calendar = .current) -> Double?",
            "sleepWakeResearchState == \"sleep_research\"",
            "detectedActivity(rest: rest, maxHR: maxHR, calendar: calendar)?.kind == .sleepCandidate",
            "let respiratoryRate = session.sleepRespiratoryRate(rest: rest, maxHR: maxHR)",
            "HKQuantitySample(type: respiratoryRateType",
            "HKUnit.count().unitDivided(by: .minute())",
        ]:
            assert_contains(self, text + sessions, needle)
        assert_not_contains(self, text, "let respiratoryRate = session.respiratoryRate")
        assert_not_contains(self, text, "respiratoryRateExported: (session.respiratoryRate ?? 0) > 0")
        assert_not_contains(self, sessions, "let respiratoryRates = recent.compactMap(\\.respiratoryRate)")
        assert_not_contains(self, sessions, "let respiratoryRates = daySessions.compactMap(\\.respiratoryRate)")

    def test_healthkit_step_count_is_not_requested(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        assert_contains(self, text, "var readTypes: Set<HKObjectType> = [heartRateType, bloodPressureSystolicType, bloodPressureDiastolicType]")
        assert_not_contains(self, text, "private var stepCountType")
        assert_not_contains(self, text, ".stepCount")
        assert_not_contains(self, text, "auditAppleStepCountReadAvailability")
        assert_not_contains(self, text, "healthkit_step_read")
        assert_not_contains(self, text, "HKStatisticsQuery(quantityType: stepCountType")
        assert_not_contains(self, text, "HKQuantitySample(type: stepCountType")

    def test_healthkit_sleeping_wrist_temperature_is_read_only(self):
        text = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        app_text = all_swift_source()

        for needle in [
            "private var sleepingWristTemperatureType: HKQuantityType?",
            ".appleSleepingWristTemperature",
            "readTypes.insert(sleepingWristTemperatureType)",
            "private func auditSleepingWristTemperatureReadAvailability(reason: String)",
            "HKSampleQuery(sampleType: sleepingWristTemperatureType",
            "HKSampleSortIdentifierEndDate",
            "ATRIADBG healthkit_sleeping_wrist_temp_read status=%@",
            "source=healthkit_read write_temperature=0 baseline_only=1",
            "auditSleepingWristTemperatureReadAvailability(reason: \"authorization_cached\")",
            "auditSleepingWristTemperatureReadAvailability(reason: \"authorization_granted\")",
            "auditSleepingWristTemperatureReadAvailability(reason: \"up_to_date\")",
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, text, "Label(\"Time window\", systemImage: \"calendar.badge.clock\")")

        for forbidden in [
            "HKQuantitySample(type: sleepingWristTemperatureType",
            "HKQuantitySample(type: bodyTemperature",
            ".bodyTemperature",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_active_calories_are_persisted_as_estimates(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")

        for needle in [
            "var activeCalories: Double? = nil",
            "var caloriesConfidence: String? = nil",
        ]:
            assert_contains(self, sessions, needle)

        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        for needle in [
            "case estimate",
            "return \"Estimate\"",
            "return \"function\"",
        ]:
            assert_contains(self, shared, needle)
        assert_contains(self, overview, "detail: live.liveActiveCalories == nil ? \"Needs profile\" : \"Estimate\"")
        assert_not_contains(self, overview, "state: live.liveActiveCalories == nil ? .learning : .local")

        for needle in [
            "let activeCalories = Metrics.activeCalories(activeSamples",
            "let caloriesConfidence: String? = session.count > 1 ? (profile.hasEnergyProfile ? \"estimate\" : \"needs_profile\") : nil",
            "activeCalories: activeCalories",
            "caloriesConfidence: caloriesConfidence",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "if session.caloriesConfidence == \"estimate\"",
            "let activeCalories = session.activeCalories",
            "return activeCalories",
            "if session.workoutReadiness(rest: rest, maxHR: maxHR).ready,\n               profile.hasEnergyProfile,\n               snapshot?.activeEnergyExported != true",
            "if snapshot?.activeEnergyExported != true,\n           session.workoutReadiness(rest: rest, maxHR: maxHR).ready,\n           let profile",
            "\"atria_metric_confidence\": \"estimate\"",
            "\"atria_metric_source\": \"keytel_2005_hr_energy\"",
        ]:
            assert_contains(self, healthkit, needle)

    def test_research_bundle_is_allowlist_and_denylist_clean(self):
        bundle = source(ROOT / "Atria" / "Atria" / "AtriaResearchBundle.swift")
        for needle in [
            "enum AtriaResearchSharing",
            "struct AtriaResearchBundlePayload: Codable",
            "static func grantConsent",
            "static func revokeConsent",
            "pseudonym",
            "ageBand",
            ".disabled(!hasInspected)",
        ]:
            assert_contains(self, bundle, needle)
        # Denylist: identifying fields must never enter the research encoder.
        for forbidden in [
            "deviceName",
            "faceOffDisplayName",
            "strapName",
            "TimeZone.current",
            "birthYear:",
        ]:
            assert_not_contains(self, bundle, forbidden)

    def test_vo2max_fails_closed_until_confident(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        match = re.search(r"func vo2MaxEstimateSummary\(rest: Int, maxHR: Int\) -> VO2MaxEstimateSummary \{(?P<body>.*?)\n    \}", sessions, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")
        for needle in [
            "AtriaAnalytics.VO2Max.summary(rest: rest,",
            "maxHR: maxHR,",
            "restingSamples: baseline.freshRestingSampleCount(),",
            "maxHRMeasured: profile.maxHRSource == .measured,",
            "restingTrend: restingTrend14)",
        ]:
            assert_contains(self, body, needle)
        assert_contains(self, sessions, "let trendDelta: Double?")
        for needle in [
            "enum VO2Max",
            "guard rest > 0, maxHR > rest else",
            "guard restingSamples >= PersonalBaseline.trustedMinimumSamples else",
            "\"\\(restingSamples)/\\(PersonalBaseline.trustedMinimumSamples) RHR\"",
            "Atria needs a trusted resting baseline before estimating VO2max.",
            "guard maxHRMeasured else",
            "VO2MaxEstimateSummary(value: nil",
            "let rawEstimate = 15.3 * Double(maxHR) / rest",
            "let confidence = \"rough estimate\"",
            "let trend = trendText(currentEstimate: boundedEstimate,",
            "trendText: trend.text",
            "trendDetail: trend.detail",
            "trendDelta: trend.delta",
            "static func trendText(currentEstimate: Double,",
            "let rests = restingTrend.filter { $0 > 0 }",
            "guard rests.count >= 2, let oldestRest = rests.first else",
            "let previousEstimate = boundedEstimate(rest: olderMean, maxHR: maxHR)",
            "return (String(format: \"%+.1f\", delta), \"vs \\(rests.count)-point RHR trend.\", delta)",
        ]:
            assert_contains(self, analytics, needle)
        self.assertGreater(analytics.find("let rawEstimate = 15.3"), analytics.find("guard maxHRMeasured else"))
        assert_not_contains(self, analytics, "guard restingSamples >= 7 else")
        assert_not_contains(self, analytics, "Atria needs 7 resting nights before estimating VO2max.")

        for needle in [
            "profile.maxHRSource == .measured",
            "restingBaselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "if !vo2MaxPlanned,\n               profile.maxHRSource == .measured,\n               restingBaselineSamples >= PersonalBaseline.trustedMinimumSamples,\n               snapshot?.vo2MaxExported != true",
            "if snapshot?.vo2MaxExported != true,\n           let profile,\n           profile.maxHRSource == .measured,\n           restingBaselineSamples >= PersonalBaseline.trustedMinimumSamples,\n           rest > 0,\n           maxHR > rest",
            "\"atria_metric_confidence\": \"rough_estimate\"",
            "\"atria_metric_source\": \"uth_sorensen_resting_hr\"",
        ]:
            assert_contains(self, healthkit, needle)
        assert_not_contains(self, healthkit, "restingBaselineSamples >= 7")

        for needle in [
            "AtriaMetricTile(label: \"VO2max\"",
            "state: vo2MaxEstimate.value == nil ? .learning : .estimate",
            "footnote: vo2MaxEstimate.confidence",
            "AtriaMetricTile(label: \"VO2 trend\"",
            "value: vo2MaxEstimate.trendText",
            "footnote: vo2MaxEstimate.trendDetail",
        ]:
            assert_contains(self, vitals, needle)
        assert_not_contains(self, vitals, "AtriaInlineQuickStat(label: \"VO2max\"")

    def test_biological_age_is_local_estimate_and_fail_closed(self):
        insights = source(ROOT / "Atria" / "Atria" / "Insights.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        fitness_age = source(ROOT / "Atria" / "Atria" / "AtriaFitnessAge.swift")

        for needle in [
            "static let trustedMinimumSamples = 14",
            "static let staleAfter: TimeInterval = 21 * 24 * 60 * 60",
            "func freshSamples(now: Date = Date()) -> [BaselineSample]",
            "func freshRestingSampleCount(now: Date = Date()) -> Int",
            "func freshHRVSampleCount(now: Date = Date()) -> Int",
            "func isStale(now: Date = Date()) -> Bool",
            "func hasTrustedRestingBaseline(now: Date = Date()) -> Bool",
            "freshRestingSampleCount(now: now) >= Self.trustedMinimumSamples && !isStale(now: now)",
            "func hasTrustedHRVBaseline(now: Date = Date()) -> Bool",
            "freshHRVSampleCount(now: now) >= Self.trustedMinimumSamples && !isStale(now: now)",
            "stats(freshSamples(now: now).map(\\.restingHR))",
            # HRV baseline is sleep-window-preferred (WHOOP-like): overnight samples
            # only once >=7 exist, else fall back to all fresh samples. Still local,
            # never fabricated.
            "func lnRMSSDStats(now: Date) -> (mean: Double, sd: Double, count: Int)?",
            "if overnight.count >= Self.overnightHRVPreferenceMinimum",
            "return stats(fresh.compactMap(\\.lnRMSSD))",
            "static let overnightHRVPreferenceMinimum = 7",
        ]:
            assert_contains(self, insights, needle)

        for needle in [
            "struct BiologicalAgeSummary: Equatable",
            "let biologicalAge: Int?",
            "let ageDelta: Int?",
            "let agingPaceText: String",
            "let agingPaceDetail: String",
            "let factors: [BioAgeFactor]",
            "enum Direction: String, Equatable",
            "let direction: Direction",
            "static let footnoteText = AtriaFitnessAge.footnoteText",
            "guard isReady else { return \"Calibrating 28-day baseline\" }",
            "func biologicalAgeSummary(vo2MaxEstimate: VO2MaxEstimateSummary) -> BiologicalAgeSummary",
            # Bio age blockers/inputs are computed here from local history, then
            # delegated to AtriaFitnessAge.summary (see fitness_age needles below)
            # rather than the old VO2max/sex/BMI-gated AtriaAnalytics.BiologicalAge path.
            "let restingHR = averageInt(recentMetrics.compactMap(\\.restingHR)) ?? baseline.restingInt",
            "let hrv = averageInt(recentMetrics.compactMap(\\.hrv)) ?? baseline.hrvInt",
            "let sleepConsistency = recentMetrics.compactMap(\\.sleepConsistencyPercent).first\n            ?? sleepHistorySnapshot.sleepConsistencyPercent",
            "let weeklyZone2PlusMinutes = weeklyZone2PlusMinutes(now: Date())",
            "return AtriaFitnessAge.summary(inputs: AtriaFitnessAge.Inputs(chronologicalAge: chronologicalAge,",
            "let hrvReady = baseline.hrvSampleCount >= PersonalBaseline.trustedMinimumSamples",
            "hrv_required=%d",
            "PersonalBaseline.trustedMinimumSamples,\n              hrvReady ? 1 : 0",
            "latestReferenceValidatedHRV != nil && baseline.hrvSampleCount >= PersonalBaseline.trustedMinimumSamples",
            "validated_hrv_baseline_\\(baseline.hrvSampleCount)_of_\\(PersonalBaseline.trustedMinimumSamples)",
            "let hrvBaselineReady = baseline.hrvSampleCount >= PersonalBaseline.trustedMinimumSamples",
            "validated_hrv_baseline=\\(baseline.hrvSampleCount)/\\(PersonalBaseline.trustedMinimumSamples)",
            "hrv_baseline_samples=\\(baseline.hrvSampleCount)/\\(PersonalBaseline.trustedMinimumSamples)",
            "validated_hrv_baseline_\\(hrvBaselineSamples)_of_\\(PersonalBaseline.trustedMinimumSamples)",
            "personal_baseline_hrv_\\(hrvBaselineSamples)_of_\\(PersonalBaseline.trustedMinimumSamples)",
            "hrvBaselineSamples < PersonalBaseline.trustedMinimumSamples",
            "HRV",
            "Sleep",
            "Activity",
        ]:
            assert_contains(self, sessions, needle)
        for needle in [
            "static let footnoteText = \"Estimate from heart data — not a medical measurement.\"",
            "struct Inputs: Equatable",
            "let chronologicalAge: Int",
            "let restingHeartRate: Int?",
            "let hrvRMSSD: Int?",
            "let weeklyZone2PlusMinutes: Double?",
            "let sleepConsistencyPercent: Int?",
            "let historyDays: Int",
            "static func summary(inputs: Inputs) -> BiologicalAgeSummary",
            "if inputs.historyDays < 28",
            "blockers.append(\"28 days of heart data\")",
            "if inputs.restingHeartRate == nil",
            "blockers.append(\"resting HR baseline\")",
            "if inputs.hrvRMSSD == nil",
            "blockers.append(\"HRV baseline\")",
            "if inputs.weeklyZone2PlusMinutes == nil",
            "blockers.append(\"weekly zone-2+ minutes\")",
            "if inputs.sleepConsistencyPercent == nil",
            "blockers.append(\"sleep consistency\")",
            "agingPaceDetail: \"Needs 28 days before showing a fitness-age estimate.\"",
            "label: \"Resting HR\"",
            "label: \"HRV\"",
            "label: \"Zone 2+\"",
            "label: \"Sleep consistency\"",
        ]:
            assert_contains(self, fitness_age, needle)
        assert_not_contains(self, sessions, "if profile.biologicalSex == .unspecified")
        assert_not_contains(self, sessions, "blockers.append(\"Add sex in profile\")")
        assert_not_contains(self, sessions, "AtriaAnalytics.BiologicalAge.summary(chronologicalAge: chronologicalAge,")
        assert_not_contains(self, sessions, "3 sleep or nap records")
        assert_not_contains(self, sessions, "trainingLoadSummarySnapshot.confidence != \"learning\"")
        assert_not_contains(self, sessions, "activity load baseline")
        assert_not_contains(self, sessions, "guard let restingHR = baseline.restingInt, baseline.restingSampleCount >= 7 else")
        assert_not_contains(self, sessions, "guard let hrv = baseline.hrvInt, baseline.hrvSampleCount >= 7 else")
        assert_not_contains(self, sessions, "baseline.hrvSampleCount >= 7")
        assert_not_contains(self, sessions, "hrvBaselineSamples < 7")
        assert_not_contains(self, sessions, "hrv_required=7")
        assert_not_contains(self, sessions, "_of_7")

        for needle in [
            "enum BiologicalAge",
            "enum ReferenceSource: String, CaseIterable",
            "static let referenceSourceFootnotes = ReferenceSource.allCases.map(\\.rawValue)",
            "case vo2max = \"VO2max: ACSM/Cooper",
            "case restingHeartRate = \"Resting HR:",
            "case hrv = \"HRV: age-related RMSSD",
            "case sleep = \"Sleep:",
            "case activity = \"Activity:",
            "case bmi = \"BMI:",
            "trendDeltaYears: Int? = nil",
            "static func estimatedAge(chronologicalAge: Int, factors: [BioAgeFactor]) -> Int",
            "min(max(unclamped, chronologicalAge - 20), chronologicalAge + 20)",
            "static func agingPace(biologicalAge: Int,",
            "trendDeltaYears: Int? = nil",
            "cached fitness trend",
            "weekly trend unlocks after more local estimates",
            "static func factor(id: String,",
            "direction: delta == 0 ? .neutral : (delta < 0 ? .younger : .older)",
            "ACSM/Cooper VO2max percentile tables",
            "static func vo2AgeEquivalent(_ vo2: Double, sex: AthleteProfile.BiologicalSex) -> Int",
            "private static let maleVO2AgeReference: [(age: Int, value: Double)]",
            "private static let femaleVO2AgeReference: [(age: Int, value: Double)]",
            "private static let restingHRAgeReference: [(age: Int, value: Double)]",
            "private static let rmssdAgeReference: [(age: Int, value: Double)]",
            "private static func interpolatedAgeEquivalent(for value: Double,",
            "higherIsYounger: Bool",
            "static func rhrAgeEquivalent(_ restingHR: Int) -> Int",
            "static func hrvAgeEquivalent(_ rmssd: Int) -> Int",
            "static func sleepAgeEquivalent(durationHours: Double,",
            "consistencyPercent: Int?",
            "static func activityAgeEquivalent(_ chronicLoad: Double,",
            "static func bmiAgeEquivalent(_ bmi: Double,",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "biologicalAgeSummary: store.biologicalAgeSummary(vo2MaxEstimate: vo2)",
            "biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary",
            "store.$sleepHistorySnapshot.map { _ in () }.eraseToAnyPublisher()",
            "store.$trainingLoadSummarySnapshot.map { _ in () }.eraseToAnyPublisher()",
            "profileMetricsStore: model.profileMetricsStore",
        ]:
            assert_contains(self, home + overview, needle)
        assert_contains(self, home, "let hasTrustedBaseline = stats.count >= PersonalBaseline.trustedMinimumSamples")
        assert_contains(self, home, "let badge = hasTrustedBaseline ? \"personal baseline\" : \"unverified\"")
        assert_contains(self, home, "let comparisonLabel = hasTrustedBaseline ? \"your baseline\" : \"an early unverified HRV average\"")
        assert_contains(self, home, "String(format: \"Live lnRMSSD is %.1f SD from %@.\", z, comparisonLabel)")
        assert_not_contains(self, home, "stats.count >= 7 ? \"personal baseline\" : \"unverified\"")
        assert_not_contains(self, home, "String(format: \"Live lnRMSSD is %.1f SD from your baseline.\", z)")
        for needle in [
            r"\(hero.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
            r"\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
            r"\(store.baseline.hrvSampleCount)/\(PersonalBaseline.trustedMinimumSamples)",
            "sampleCount >= PersonalBaseline.trustedMinimumSamples",
            "Trusted personal baseline is ready.",
            "Wear overnight to build a trusted recovery baseline.",
        ]:
            assert_contains(self, home + hero + overview + sessions, needle)
        for forbidden in [
            r"\(hero.baselineSamples)/7",
            r"\(stats.baselineSamples)/7",
            r"\(store.baseline.hrvSampleCount)/7",
            "Personal baseline is ready.",
        ]:
            assert_not_contains(self, home + hero + overview + sessions, forbidden)

        for needle in [
            "case .bioAge: return \"Fitness age\"",
            "case .bioAge: return \"figure.stand.line.dotted.figure.stand\"",
            "case .bioAge:",
            "AtriaGlanceMetricCard(title: \"Fitness age\"",
            "biologicalAgeSummary.isReady ? biologicalAgeSummary.detailText : \"Calibrating\"",
            "Calibrating your fitness-age baseline. \\(biologicalAgeSummary.blockerText). \\(biologicalAgeSummary.footnote)",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "AtriaMetricTile(label: \"Fitness age\"",
            "AtriaMetricTile(label: \"Delta\"",
            "targetMetric: .bioAge",
            "AtriaMetricTile(label: \"Top driver\"",
            "biologicalAgeSummary.agingPaceText",
            "biologicalAgeSummary.agingPaceDetail",
            "state: biologicalAgeSummary.isReady ? .estimate : .learning",
            "AtriaPanelSectionHeader(title: \"Fitness Age\", subtitle: biologicalAgeSummary.narrative)",
            "ForEach(biologicalAgeSummary.factors)",
            "Text(biologicalAgeSummary.footnote)",
            "let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "struct AtriaCollectionBiologicalAgeCard: View, Equatable",
            "AtriaCollectionBiologicalAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary,",
            "AtriaPanelSectionHeader(title: \"Fitness Age\", subtitle: summary.narrative)",
            "AtriaMetricTile(label: \"Pace\"",
            "value: summary.agingPaceText",
            "footnote: summary.agingPaceDetail",
            "ForEach(summary.factors)",
            "AtriaBioAgeFactorRow(factor: factor)",
            "private struct AtriaBioAgeFactorRow: View, Equatable",
            "case .neutral: return .blue",
            "case .neutral: return \"equal.circle.fill\"",
            "Text(summary.footnote)",
        ]:
            assert_contains(self, vitals, needle)

        self.assertEqual(vitals.count("AtriaBioAgeFactorRow(factor: factor)"), 2)
        assert_not_contains(self, vitals, "factor.direction == .older ?")
        assert_not_contains(self, sessions + overview + vitals, "longevity")
        assert_not_contains(self, sessions + overview + vitals, "lifespan")
        assert_not_contains(self, sessions + overview + vitals, "disease risk")

    def test_validate_later_recovery_displays_personal_baseline_before_validation(self):
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        text = metrics + analytics
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        widget = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        intents = source(ROOT / "Atria" / "Atria" / "AtriaAppIntents.swift")
        docs = "\n".join(source(path) for path in (ROOT / "docs").rglob("*.md"))

        for needle in [
            "case personalBaseline = \"personal baseline\"",
            "Recovery v2: logistic personal z-score model.",
            "baseline.hasTrustedRestingBaseline()",
            "baseline.hasTrustedHRVBaseline()",
            "PersonalBaseline.trustedMinimumSamples",
            "sleepEfficiency: Double? = nil",
            "sleepDurationHours: Double? = nil",
            "respiratoryRate: Double? = nil",
            "respiratoryBaseline: (mean: Double, sd: Double, count: Int)? = nil",
            "guard let sleepZ = sleepRecoveryZ(efficiency: sleepEfficiency,",
            "detail: \"learning: need saved sleep\"",
            "let respirationZ = respiratoryRecoveryZ(rate: respiratoryRate,",
            "0.60 * hrvZ - 0.20 * restingZ + 0.15 * sleepZ + 0.05 * respirationZ",
            "let percent = logisticRecoveryPercent(z: blendedZ)",
            "private static func logisticRecoveryPercent(z: Double) -> Int",
            "100.0 / (1.0 + exp(-k * (z - z0)))",
            "private static func respiratoryRecoveryZ(rate: Double?,",
            "baseline.count >= PersonalBaseline.trustedMinimumSamples",
            "-zScore(rate, mean: baseline.mean, sd: baseline.sd)",
            "? \"Resp neutral\"",
            "String(format: \"Resp z %.1f\", respirationZ)",
            "Sleep z %.1f · %@",
            "private static func sleepRecoveryZ(efficiency: Double?, durationHours: Double?) -> Double?",
            "hrvReferenceValidated ? .validated : .personalBaseline",
            "enum RespRateRsa",
            "static func estimate(samples: [(t: Date, ms: Double)],",
            "lookback: TimeInterval = 90",
            "static func estimate(resampledRR: [Double], sampleRate: Double = 4.0) -> Double?",
            "for breathsPerMinute in stride(from: 6.0, through: 30.0, by: 0.5)",
            "bestPower / max(bandPower, bestPower) >= 0.18",
        ]:
            assert_contains(self, text, needle)
        assert_contains(self, analytics, "enum Recovery")
        assert_contains(self, analytics, "static func restingOnly(restingNow: Int, baseline: Int) -> Int")
        assert_contains(self, analytics, "static func estimate(hrvNow: Int, hrvBaseline: Int, restingNow: Int, restingBaseline: Int) -> Int")
        assert_contains(self, analytics, "static func estimate(hrvSnapshot: HRVSnapshot?,")
        assert_contains(self, metrics, "typealias RecoveryEstimate = AtriaAnalytics.Recovery.Estimate")
        assert_contains(self, metrics, "AtriaAnalytics.Recovery.restingOnly(restingNow: restingNow, baseline: baseline)")
        assert_contains(self, metrics, "AtriaAnalytics.Recovery.estimate(hrvNow: hrvNow,")
        assert_contains(self, metrics, "AtriaAnalytics.Recovery.estimate(hrvSnapshot: hrvSnapshot,")
        assert_contains(self, metrics, "respiratoryRate: respiratoryRate")
        assert_contains(self, metrics, "respiratoryBaseline: respiratoryBaseline")
        assert_contains(self, sessions, "var respiratoryBaselineStats: (mean: Double, sd: Double, count: Int)?")
        assert_contains(self, sessions, "values.count >= PersonalBaseline.trustedMinimumSamples")
        assert_contains(self, sessions, "let clippedNights = Array(sorted.prefix(PersonalBaseline.trustedMinimumSamples + 1))")
        assert_contains(self, sessions, "self.nights = clippedNights")
        assert_contains(self, sessions, "let respiratoryBaselineMean: Double?")
        assert_contains(self, sessions, "let respiratoryBaselineCount: Int")
        assert_contains(self, sessions, "let respiratoryRate = AtriaAnalytics.RespRateRsa.estimate(samples: sorted, now: windowEnd)")
        assert_contains(self, sessions, "respiratoryRate: respiratoryRate")
        hrv_source = source(ROOT / "Atria" / "Atria" / "HRV.swift")
        assert_contains(self, hrv_source, "AtriaAnalytics.RespRateRsa.estimate(samples: kept.map { (t: $0.t, ms: $0.ms) }, now: now)")
        assert_not_contains(self, sessions, "respiratoryRate: nil)\n    }\n\n    private func replayReason")
        assert_not_contains(self, metrics, "let hrvScore = 66.0 * Double(hrvNow) / Double(hrvBaseline)")
        assert_not_contains(self, metrics, "let restingPenalty = restingNow > 0 && restingBaseline > 0")
        assert_not_contains(self, analytics, "hrvStats.count >= 7")
        assert_not_contains(self, analytics, "learning HRV baseline \\(baseline.hrvSampleCount)/7")
        assert_not_contains(self, analytics, "50 + blendedZ * 16")
        assert_not_contains(self, analytics, "0.60 * hrvZ - 0.25 * restingZ + 0.15 * sleepZ")

        for needle in [
            "let fallbackHRV = validatedHRV ?? store.latestLocalRMSSD",
            "let latestSleep = store.sleepHistorySnapshot.latest",
            "fallbackRMSSD: fallbackHRV",
            "hrvReferenceValidated: validatedHRV != nil",
            "sleepEfficiency: latestSleep?.sleepEfficiency",
            "sleepDurationHours: latestSleep?.durationHours",
            "hrvState = recovery.confidence == .validated ? \"validated\" : \"personal_baseline\"",
        ]:
            assert_contains(self, widget, needle)

        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        assert_contains(self, home, "sleepEfficiency: latestSleep?.sleepEfficiency")
        assert_contains(self, home, "sleepDurationHours: latestSleep?.durationHours")
        assert_contains(self, notifications, "sleepEfficiency: latestSleep?.sleepEfficiency")
        assert_contains(self, notifications, "sleepDurationHours: latestSleep?.durationHours")
        assert_contains(self, sessions, "private nonisolated static func sleepEfficiency(duration: TimeInterval?, span: TimeInterval?) -> Double?")
        assert_contains(self, sessions, "sleepEfficiency: Self.sleepEfficiency(duration: sleepRollup?.sleepDuration,")
        assert_contains(self, sessions, "sleepDurationHours: sleepRollup?.sleepDuration.map { $0 / 3_600 }")

        for needle in [
            "private var recoveryState: AtriaMetricState",
            "case .personalBaseline:\n            return .personalBaseline",
            "case .unverified:\n            return .research",
            "state: recoveryState",
            "footnote: hero.recoveryEstimate.confidence.rawValue",
            "private var hrvState: AtriaMetricState",
            "if detail.contains(\"validated\") { return .validated }",
            "if detail.contains(\"personal baseline\") || detail.contains(\"% kept\") { return .personalBaseline }",
            "footnote: hero.hrvDetail",
        ]:
            assert_contains(self, overview + vitals, needle)

        assert_not_contains(self, overview + vitals, "state: hero.recoveryEstimate.percent == nil ? .learning : .validated")
        assert_not_contains(self, vitals, "hero.hrvDetail.localizedCaseInsensitiveContains(\"validated\") ? .validated : .learning")
        assert_not_contains(self, overview, "hero.hrvDetail.localizedCaseInsensitiveContains(\"validated\") ? .validated : .learning")

        assert_contains(self, intents, "Read the latest local recovery, strain, and HRV snapshot.")
        assert_contains(self, intents, "snapshot.hrvRMSSD.map")

        for forbidden in [
            "all HRV metrics in\n  **learning** until an external RR/IBI reference passes",
            "blocked from display until an external RR reference passes",
            "show nothing until validated",
        ]:
            assert_not_contains(self, docs, forbidden)

    def test_local_native_feature_seams_are_present(self):
        text = all_swift_source()

        required = [
            "protocol AtriaCoachProvider",
            "AtriaLocalCoachProvider",
            "AtriaCloudCoachProvider",
            "enum AtriaCoachKeychain",
            "CXCallObserver",
            "import ActivityKit",
            "ControlWidget",
            "AppIntent",
        ]
        for needle in required:
            assert_contains(self, text, needle)

        # Atria must NEVER touch the user's music/audio (no AVAudioSession grab, no
        # system-music-player control). The media-control feature was removed on
        # purpose; these tokens must stay absent everywhere.
        for forbidden in [
            "MPMusicPlayerController.systemMusicPlayer",
            "beginGeneratingPlaybackNotifications",
            "AVAudioSession.sharedInstance().setActive(true",
        ]:
            assert_not_contains(self, text, forbidden)

    def test_haptic_alerts_are_phone_side_only(self):
        haptics = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")

        for needle in [
            "import CallKit",
            "UINotificationFeedbackGenerator()",
            "UIImpactFeedbackGenerator",
            "Text(\"Phone haptics\")",
            "phone_side=1 strap_write=0",
            "var enabledCount: Int",
            "var glanceValueText: String",
            "var glanceDetailText: String",
            "if heartRateZones { return \"Zones on\" }",
            "private static let heartRateZoneHapticCooldown: TimeInterval = 30",
            "private var lastZoneHapticAt: Date?",
            "now.timeIntervalSince(lastZoneHapticAt) < Self.heartRateZoneHapticCooldown",
            "status=cooled_down",
            "lastZoneHapticAt = now",
        ]:
            assert_contains(self, haptics, needle)

        for forbidden in [
            "sendCommand(",
            "writeValue(",
            "CoreBluetooth",
            "CBPeripheral",
            "strap_side=1",
            "strap_write=1",
        ]:
            assert_not_contains(self, haptics, forbidden)

    def test_ai_coach_local_mode_is_explicitly_offline(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaAICoach.swift")

        for needle in [
            "enum AtriaCoachNetworkPolicy",
            "case offlineOnly",
            "case cloudDisabled",
            "let networkPolicy: AtriaCoachNetworkPolicy = .offlineOnly",
            "let networkPolicy: AtriaCoachNetworkPolicy = .cloudDisabled",
            "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
            "No data leaves this iPhone.",
            "Network requests stay disabled until a reviewed provider client is added.",
            "request preview ready",
        ]:
            assert_contains(self, text, needle)

        card = source(ROOT / "Atria" / "Atria" / "AtriaAICoachCard.swift")
        assert_contains(self, card, "does not send metrics until a reviewed")
        assert_contains(self, card, "Enable local mode for an offline summary")
        assert_contains(self, card, ".privacySensitive()")
        assert_contains(self, card, ".atriaCardAction(tint: .indigo)")
        assert_contains(self, card, ".atriaCardAction(prominent: false, tint: .gray)")
        assert_contains(self, card, ".atriaCard(emphasis: .soft)")
        assert_not_contains(self, card, ".atriaRaisedCard(")
        assert_not_contains(self, card, ".buttonStyle(.glass")
        assert_not_contains(self, card, ".buttonStyle(.glassProminent")
        assert_not_contains(self, card, "sends selected local metrics")
        assert_not_contains(self, card, ".textContentType(.password)")

        for forbidden in [
            "import Network",
            "localModelEnabled",
            "URLSession",
            "URLRequest",
            ".resume()",
            "http://",
            "https://",
        ]:
            assert_not_contains(self, text, forbidden)

    def test_monetization_seam_exists_without_paywall_or_storekit(self):
        app_text = all_swift_source()
        entitlements = source(ROOT / "Atria" / "Atria" / "AtriaEntitlements.swift")

        for needle in [
            "struct AtriaEntitlements",
            "enum Feature",
            "enum Tier",
            "case paidApp",
            "case premium",
            "var tier: Tier = .paidApp",
            "var premiumOverrides: Set<Feature> = []",
            "EnvironmentValues",
            "atriaEntitlements",
        ]:
            assert_contains(self, entitlements, needle)

        for feature in [
            ".localMetrics",
            ".healthKitExport",
            ".backgroundCollection",
            ".liveActivity",
            ".mediaControls",
            ".hapticAlerts",
            ".aiCoachLocal",
            ".aiCoachCloud",
        ]:
            assert_contains(self, entitlements, feature)

        assert_contains(self, entitlements, "return true")
        assert_not_contains(self, entitlements, "return tier == .premium")
        assert_not_contains(self, entitlements, "premiumOverrides.contains")

        for forbidden in [
            "import StoreKit",
            "Product.products",
            "SubscriptionStoreView",
            "StoreView",
            "Purchase",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_local_first_core_has_no_network_or_browser_clients(self):
        app_text = all_swift_source()

        for forbidden in [
            "URLSession",
            "URLRequest",
            "NSURLConnection",
            "import Network",
            "NWConnection",
            "http://",
            "https://",
            "WKWebView",
            "SFSafariViewController",
            "ASWebAuthenticationSession",
        ]:
            assert_not_contains(self, app_text, forbidden)

    def test_developer_only_surfaces_are_hidden_by_default(self):
        developer_mode = source(ROOT / "Atria" / "Atria" / "AtriaDeveloperMode.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "enum AtriaDeveloperMode",
            "defaultsKey = \"atria.developerMode.enabled\"",
            "launchArgument = \"--atria-developer-mode\"",
            "let enabledByLaunchArgument = ProcessInfo.processInfo.arguments.contains(launchArgument)",
            "UserDefaults.standard.removeObject(forKey: defaultsKey)",
            "return enabledByLaunchArgument",
        ]:
            assert_contains(self, developer_mode, needle)

        for needle in [
            "@State private var developerModeEnabled = AtriaDeveloperMode.isEnabled",
            "developerModeEnabled: developerModeEnabled",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "let developerModeEnabled: Bool",
            "captureCard\n                        researchSignalsCard\n                        biologicalAgeCard\n                        if developerModeEnabled",
            "captureCard\n                    researchSignalsCard\n                    biologicalAgeCard\n                    if developerModeEnabled",
            "if developerModeEnabled {\n                            rrReferenceCard",
            "if developerModeEnabled {\n                            rrReferenceCard\n                            hrReferenceCard\n                            imuAuditCard",
            "if developerModeEnabled {\n                    AtriaCollectionToggleCard",
            "title: \"Battery saver\"",
            "Heart-rate only. HR stays live; HRV, Recovery and sleep detail wait for validated beat-to-beat windows.",
            "Full sensor mode. Beat-to-beat, HRV, Recovery and sleep estimates stay available.",
            "private var researchSignalsCard: some View",
            "AtriaCollectionResearchSignalsCard(summary: store.imuAuditSummary,",
            "sleepHistory: store.sleepHistorySnapshot",
            "private struct AtriaCollectionResearchSignalsCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"Experimental sensors\", subtitle: \"\")",
            "Image(systemName: \"info.circle\")",
            "showResearchInfo = true",
            "Experimental sensor info",
            "AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,",
            "AtriaMetricTile(label: \"Blood oxygen\"",
            "value: summary.spo2CandidateFrames > 0 ? \"Early\" : \"--\"",
            "@AtriaDefault(\"atria.target.bloodOxygen.candidateFrames\") private var bloodOxygenCandidateGoal: Int = 8",
            "lhs.bloodOxygenCandidateGoal == rhs.bloodOxygenCandidateGoal",
            "private var bloodOxygenResearchZone: AtriaMetricZone?",
            "Metrics.bloodOxygenResearchZone(candidateFrames: summary.spo2CandidateFrames,",
            "goalFrames: bloodOxygenCandidateGoal",
            "zone: bloodOxygenResearchZone",
            "AtriaMetricTile(label: \"Body temp\"",
            "value: summary.skinTemperatureDeviation.valueText",
            "unit: summary.skinTemperatureDeviation.isReady ? \"delta C\" : nil",
            "footnote: summary.skinTemperatureDeviation.footnoteText",
            "AtriaMetricTile(label: \"Resp rate\"",
            "AtriaMetricTile(label: \"Strap steps\"",
            "\\(summary.spo2CandidateFrames) candidate frames; not a SpO2 value.",
            "Early reading; not a SpO2 value.",
            "Sleep-only estimate; needs comparison data.",
            "Atria shows skin temperature only as a sleep-baseline deviation, never as an absolute body-temperature value.",
            "private struct AtriaResearchSignalInfoSheet: View",
            "@Environment(\\.dismiss) private var dismiss",
            "No candidate frames yet. Atria does not estimate or display an SpO2 percentage from unvalidated bytes.",
            ".navigationTitle(\"Experimental sensors\")",
            "ToolbarItem(placement: .topBarTrailing)",
            "Button(\"Done\")",
            "dismiss()",
            "private struct AtriaCollectionIMUAuditCard: View, Equatable",
            "AtriaPanelSectionHeader(title: \"Motion audit\", subtitle: \"\")",
            "Early motion signals stay separate until the strap motion layout is checked.",
            ".lineLimit(2)",
            "AtriaMetricTile(label: \"Sleep/wake\"",
            "AtriaMetricTile(label: \"Probes\"",
            "agreementText",
            "probeDetail",
            "AtriaCollectionIMUAuditCard(summary: store.imuAuditSummary)",
        ]:
            assert_contains(self, collection, needle)
        assert_not_contains(self, collection, "title: \"Standard HR radio\"")
        assert_not_contains(self, collection, "Advanced compatibility mode for heart-rate-only collection.")

        for needle in [
            "struct IMUAuditSummary: Equatable",
            "var respiratoryRateText: String",
            "@Published private(set) var imuAuditSummary",
            "private func recomputeCollectionResearchSummaries()",
            "imuAuditSummary = IMUAuditSummary(sessions: sessions)",
        ]:
            assert_contains(self, sessions, needle)

        assert_not_contains(
            self,
            collection,
            "private var summary: IMUAuditSummary",
        )
        assert_not_contains(self, collection, "private struct IMUAuditSummary: Equatable")
        assert_not_contains(self, collection, "IMUAuditSummary(sessions: store.sessions)")

        research_card = collection[
            collection.index("private struct AtriaCollectionResearchSignalsCard"):
            collection.index("private struct AtriaCollectionIMUAuditCard")
        ]
        imu_audit_card = collection[
            collection.index("private struct AtriaCollectionIMUAuditCard"):
            collection.index("private struct AtriaResearchManeuverMarkerCard")
        ]
        for forbidden in [
            "dailyRollups(",
            "detectedActivity(",
            "aggregateSleepCandidates(",
            "IMUAuditSummary(sessions:",
            "SleepHistorySnapshot(rollups:",
            "Sensor signals",
            "Early signal; not a SpO2 value.",
            "Research signals are local",
        ]:
            assert_not_contains(self, research_card, forbidden)
        assert_contains(self, research_card, "AtriaMetricTile(label: \"Strap steps\"")
        assert_not_contains(self, imu_audit_card, "AtriaMetricTile(label: \"Strap steps\"")

        for forbidden in [
            "title: \"Low radio HR\"",
            "Developer option for standard heart-rate-only collection.",
            "subtitle: \"Native RR window and reference flow\"",
            "AtriaInlineQuickStat(label: \"Reference\"",
            "AtriaInlineQuickStat(label: \"RR package\"",
        ]:
            assert_not_contains(self, collection, forbidden)

        assert_contains(self, content, "let debugCompletesOnboarding = AtriaDeveloperMode.isEnabled")
        assert_contains(self, content, "&& ProcessInfo.processInfo.arguments.contains(\"--atria-complete-onboarding\")")
        assert_contains(self, content, "AtriaOnboardingFlow(profile: store.profile,")
        assert_contains(self, content, "debugInitialStep: Self.debugOnboardingStepArgument(),")
        assert_contains(self, content, "onRestoreBackup: { url in")
        assert_contains(self, content, "guard store.restoreSessionBackup(from: url) else { return false }")
        assert_contains(self, content, "showOnboarding = !store.profile.hasCompletedOnboarding")
        assert_not_contains(self, content, "struct ProfileOnboardingView")
        assert_contains(self, sessions, "func completeOnboardingFromLaunchIfRequested")
        assert_contains(self, sessions, "guard AtriaDeveloperMode.isEnabled else { return }\n        guard arguments.contains(\"--atria-complete-onboarding\") else { return }")
        onboarding = source(ROOT / "Atria" / "Atria" / "AtriaOnboardingFlow.swift")
        for needle in [
            "struct AtriaOnboardingFlow: View",
            "case whatThisIs",
            "case strap",
            "case you",
            "case expectations",
            "Atria auto-detects the strap. There is no generation picker.",
            "Close the official WHOOP app",
            "Optional — you can update these anytime in Settings.",
            "Wear it tonight — first sleep tomorrow morning. Recovery calibrates over your first 3–4 nights.",
            "ble.startScan(reason: \"onboarding_strap\")",
            "--atria-ui-onboarding-complete-connected-strap",
            "guard step == .strap, ble.status == .connected, !didDebugCompleteFromConnectedStrap else { return }",
            "ATRIADBG onboarding status=debug_complete_connected_strap action=complete",
            "let onRestoreBackup: ((URL) -> Bool)?",
            ".fileImporter(isPresented: $backupImportPresented",
            "allowedContentTypes: backupArchiveTypes",
            "Restore backup from Files",
            "url.startAccessingSecurityScopedResource()",
        ]:
            assert_contains(self, onboarding, needle)

        assert_not_contains(self, content, "I’ll do this — continue")

    def test_onb1_uses_single_four_page_onboarding_flow(self):
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        onboarding = source(ROOT / "Atria" / "Atria" / "AtriaOnboardingFlow.swift")

        assert_contains(self, content, "AtriaOnboardingFlow(profile: store.profile,")
        assert_contains(self, content, "debugInitialStep: Self.debugOnboardingStepArgument(),")
        assert_contains(self, content, "onRestoreBackup: { url in")
        assert_not_contains(self, content, "struct ProfileOnboardingView")
        assert_not_contains(self, content, "ProfileOnboardingView(")

        for needle in [
            "case whatThisIs",
            "case strap",
            "case you",
            "case expectations",
            "Your WHOOP strap, no subscription. Data stays on your phone.",
            "Atria auto-detects the strap. There is no generation picker.",
            "Close the official WHOOP app",
            "Optional — you can update these anytime in Settings.",
            "Wear it tonight — first sleep tomorrow morning. Recovery calibrates over your first 3–4 nights.",
            "ble.startScan(reason: \"onboarding_strap\")",
            "--atria-ui-onboarding-complete-connected-strap",
            "guard step == .strap, ble.status == .connected, !didDebugCompleteFromConnectedStrap else { return }",
            "ATRIADBG onboarding status=debug_complete_connected_strap action=complete",
            "Restore backup from Files",
            "handleBackupImport",
        ]:
            assert_contains(self, onboarding, needle)

    def test_pull_to_refresh_connectivity_pill_uses_shared_refresh_path(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        for needle in [
            ".refreshable {\n                    await handleConnectivityRefresh()\n                }",
            "private func handleConnectivityRefresh() async",
            "ble.requestStrapStatusRead(reason: \"pull_to_refresh\")",
            "requestOfflineHistoricalSyncIfNeeded(reason: \"pull_to_refresh\", force: true)",
            "showConnectivityPill = true",
            "Strap · \\(status) · \\(live.batteryText) · updated \\(live.lastReadingAgeText)",
            "Self.debugLaunchFixtureValue(arguments: arguments) == \"refresh-connectivity-pill\"",
            "await handleConnectivityRefresh()",
        ]:
            assert_contains(self, home, needle)

    def test_feat4_weekly_report_fixture_opens_sheet(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        assert_contains(self, home, '|| fixture == "weekly-report" else { return }')
        for needle in [
            'arguments[valueIndex] == "weekly-report"',
            "showWeeklyReport = true",
            "debugWeeklyReportRollups()",
            "AtriaWeeklyReportSheet(report: debugWeeklyReport ?? weeklyReportHighlight ?? WeeklyReport(rollups: dailyRollupHistory))",
            "WeeklyReport(rollups: Self.debugWeeklyReportRollups(),",
        ]:
            assert_contains(self, overview, needle)
        for needle in [
            "scheduleFastLaunchWeeklyReportDebugFixtureIfRequested(arguments: arguments)",
            'arguments.contains("--atria-test-weekly-report-notification")',
            'arguments.contains("--atria-test-weekly-report-production-maintenance")',
            "store.generateWeeklyReportProductionFixtureFromLaunchIfRequested(arguments: arguments)",
        ]:
            assert_contains(self, app, needle)
        for needle in [
            "func generateWeeklyReportProductionFixtureFromLaunchIfRequested",
            'arguments.contains("--atria-test-weekly-report-production-maintenance")',
            'performBackgroundMaintenance(reason: "debug_forced_monday_background_maintenance"',
            "generateWeeklyReportIfNeeded(now: now, calendar: calendar, reason: reason)",
            "generateWeeklyPlanIfNeeded(now: now, calendar: calendar, reason: reason)",
        ]:
            assert_contains(self, sessions, needle)
        assert_contains(self, debug_logging, '"--atria-test-weekly-report-production-maintenance"')
        for needle in [
            "static func scheduleFastLaunchWeeklyReportDebugFixtureIfRequested",
            'arguments.contains("--atria-test-weekly-report-notification")',
            "private static func scheduleWeeklyReportDebugFixture",
            'ATRIADBG weekly_report_generation status=generated source=debug_fixture',
            'ATRIADBG notification_fixture kind=weekly_report status=scheduled_input',
            "scheduleWeeklyReport(report)",
        ]:
            assert_contains(self, notifications, needle)

    def test_north_star_screen_routing_uses_named_rebuild_files(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        strap = source(ROOT / "Atria" / "Atria" / "AtriaStrapScreen.swift")
        highlights = source(ROOT / "Atria" / "Atria" / "AtriaHighlights.swift")
        tri_ring = source(ROOT / "Atria" / "Atria" / "AtriaTriRing.swift")

        for needle in [
            "AtriaTodayScreen(statusStore:",
            "AtriaHealthScreen(liveStore:",
            "AtriaStrapScreen(statusStore:",
            "coreLiveStore: model.coreLiveStore",
            "pulseLiveStore: model.pulseLiveStore",
            # Assistant tab moved to a top-right icon (2026-07-06); that bottom-bar
            # slot became the Plan tab, then was repurposed into the Activity
            # Monitor (2026-07-06) since Plan's cards were redundant with Today/
            # Journal. Assistant still opens via cover.
            'tabNavigation(title: "Activity", showsHero: false)',
            '"sleep-plan-bedtime", "north-star-highlights"',
            'ProcessInfo.processInfo.environment["ATRIA_UI_SCREEN"]',
            "--atria-open-connection-guide",
            "--atria-ui-follow-system-appearance",
            "!isDebugUIScreenLaunchActive",
            "private var debugShowsNorthStarTodayFixture: Bool",
            "if !debugShowsNorthStarTodayFixture",
            "private var overviewSystemBanners: some View",
            "} else if shouldShowMissedDataBanner {",
        ]:
            assert_contains(self, home, needle)

        for forbidden in [
            "AtriaOverviewTabContent(statusStore:",
            "AtriaVitalsTabContent(liveStore:",
            "AtriaCollectionTabContent(coreLiveStore:",
        ]:
            assert_not_contains(self, home, forbidden)

        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        for needle in [
            "let onOpenJournal: () -> Void",
            "let onOpenShare: () -> Void",
            "AtriaTodayShortcutStrip(journalValue: journalValue,",
            "onOpenJournal: onOpenJournal",
            "onOpenShare: onOpenShare",
            "onStartWorkout: onStartWorkout",
            "private struct AtriaTodayShortcutStrip: View, Equatable",
            'AtriaTodayActionRow(title: "Journal"',
            'systemImage: "square.and.pencil"',
            'AtriaTodayActionRow(title: "Start"',
            'systemImage: "plus"',
            'AtriaTodayActionRow(title: "Share"',
            'systemImage: "square.and.arrow.up"',
        ]:
            assert_contains(self, today, needle)
        assert_contains(self, home, "onOpenJournal: {\n                                 selectedTab = .journal\n                             }")
        assert_contains(self, home, "onOpenShare: {\n                                 showShareSheet = true\n                             }")
        assert_contains(self, home, 'let shouldOpenJournalSheet = arguments.contains("--atria-open-journal")')
        assert_contains(self, home, 'let shouldStartWorkout = arguments.contains("--atria-start-workout")')
        assert_contains(self, home, "showJournalSheet = true")
        assert_contains(self, home, "workoutSession = AtriaWorkoutSession(start: Date())")

        top_chrome = home[home.index("private struct AtriaHomeTopChrome: View"):]
        for forbidden in [
            "AtriaHeaderBatteryIndicator(liveStore:",
            "private struct AtriaHeaderBatteryIndicator: View",
            "let showTodayShortcuts: Bool",
            "let showWorkout: Bool",
            "let onShowJournal: () -> Void",
            "let onShowShare: () -> Void",
            "let onShowCustomize: () -> Void",
            "let onStartWorkout: () -> Void",
            "Button(action: onShowJournal)",
            "Button(action: onStartWorkout)",
            "Button(action: onShowShare)",
            "Button(action: onShowCustomize)",
            "HistoryView(store: store)",
            "AtriaToolbarIcon(symbol: \"square.and.arrow.up\")",
            "AtriaToolbarIcon(symbol: \"slider.horizontal.3\")",
            "AtriaToolbarIcon(symbol: \"clock.arrow.circlepath\")",
        ]:
            assert_not_contains(self, top_chrome, forbidden)

        top_chrome_body = top_chrome[:top_chrome.index("private enum AtriaHeaderControlMetrics")]
        # 3 header actions since 2026-07-06: Strap + Assistant (both moved off the
        # tab bar at user direction) + Settings/Help.
        self.assertEqual(top_chrome_body.count(".buttonStyle(AtriaHeaderActionButtonStyle())"), 3)
        assert_contains(self, top_chrome_body, "Button(action: showHelp ? onShowHelp : onShowSettings)")
        assert_contains(self, home, "private var shouldShowTopChromeHelp: Bool")
        assert_contains(self, home, "if model.pulseLiveStore.state.hasPulseSignal || model.coreLiveStore.state.hasRecentHeartRateSample")
        assert_contains(self, home, "return model.statusStore.state.status != .connected")
        assert_contains(self, home, 'Text("Catching up · \\(missedDataDurationText)")')
        assert_contains(self, home, 'Text(protectsLiveStream ? "Live protected" : "History syncing")')
        assert_contains(self, home, "private var compactState: some View")
        assert_contains(self, home, "Button(action: onHelp) {\n                Image(systemName: \"questionmark.circle\")")
        assert_contains(self, home, ".buttonStyle(.plain)\n            .foregroundStyle(diagnosis.tint)")
        diagnosis_banner = re.search(
            r"private struct AtriaConnectionDiagnosisBanner: View, Equatable \{(?P<body>.*?)\n\}",
            home,
            re.S,
        )
        self.assertIsNotNone(diagnosis_banner)
        assert_not_contains(self, diagnosis_banner.group("body"), ".atriaInsetCard(tint: diagnosis.tint)")

        connection_guide = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")
        guide_sheet = connection_guide[connection_guide.index("private struct AtriaConnectionGuideSheet: View"):]
        assert_contains(self, guide_sheet, 'Image("AtriaLogo")')
        assert_contains(self, guide_sheet, 'Text("ATRIA")')
        assert_contains(self, guide_sheet, "private var statusDot: some View")
        assert_contains(self, guide_sheet, "private var priorityStep: AtriaConnectionGuideStep")
        assert_contains(self, guide_sheet, "AtriaConnectionStepRow(step: priorityStep)")
        assert_not_contains(self, guide_sheet, "ForEach(prioritySteps.prefix(1))")
        assert_contains(self, guide_sheet, 'Image(systemName: "arrow.clockwise")')
        assert_not_contains(self, guide_sheet, 'Label("Retry scan", systemImage: "arrow.clockwise")')

        vitals_collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        for needle in [
            "struct AtriaHeartRateExplorer: View",
            "struct AtriaHeartRateAxisChart: View, Equatable",
            ".fullScreenCover(isPresented: $showHeartRateExplorer)",
        ]:
            assert_contains(self, vitals_collection, needle)

        for needle in [
            "struct AtriaHealthScreen: View",
            'static let debugOpenHeartRateTimelineKey = "atria.debug.openHeartRateTimeline"',
            "if Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments) {\n                AtriaHealthTimelineProofCard(points: chartPoints,",
            ".task {\n            await refreshHistoricalHeartRatePoints()\n        }",
            "AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: pulseSparklineStore.state.chartPoints,",
            "let debugTimeline = Self.debugOpensHeartRateTimeline(arguments: ProcessInfo.processInfo.arguments)",
            "let limit = debugTimeline ? 6_000 : nil",
            "HistoricalArchive.metricHeartRatePoints(since: since, limit: limit).map",
            "ATRIADBG hist1_timeline_fixture status=loaded points=%d since=%@ limit=%d",
            "UserDefaults.standard.bool(forKey: debugOpenHeartRateTimelineKey)",
            "UserDefaults.standard.set(false, forKey: Self.debugOpenHeartRateTimelineKey)",
            'ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"] == "heart-rate-timeline"',
            'return arguments[valueIndex] == "heart-rate-timeline"',
            "private struct AtriaHealthTimelineProofCard: View, Equatable",
            "Text(\"Heart-rate timeline\")",
            "AtriaHeartRateAxisChart(points: series.visiblePoints,",
            "points.isEmpty ? (isLoading ? \"Loading archive\" : \"No archive points\") : \"\\(points.count) points\"",
        ]:
            assert_contains(self, health, needle)

        for needle in [
            "let debugLoadsMetricArchive: Bool",
            "debugLoadsMetricArchive: Bool = false",
            "private func loadMetricArchiveForDebugProofIfNeeded() async",
            "HistoricalArchive.metricHeartRatePoints(since: nil).map",
            "ATRIADBG hist1_timeline_explorer_archive status=loaded points=%d",
            ".onAppear {\n                Task { await loadMetricArchiveForDebugProofIfNeeded() }\n            }",
        ]:
            assert_contains(self, vitals_collection, needle)

        assert_contains(self, home, 'UserDefaults.standard.set(true, forKey: AtriaHealthScreen.debugOpenHeartRateTimelineKey)')
        assert_contains(self, home, 'let shouldOpenHeartRateTimeline = Self.debugLaunchFixtureValue(arguments: arguments) == "heart-rate-timeline"')
        assert_contains(self, home, 'ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"]')

        for text, needle in [
            (today, "struct AtriaTodayScreen: View"),
            (today, "AtriaHighlights.topTwo(rollups: highlightRollups)"),
            (today, "return store.dailyRollupHistory"),
            (today, 'arguments[valueIndex] == "north-star-highlights"'),
            (today, "debugHighlightRollups(includeNutrition: Self.debugShowsNutritionRecoveryDetail"),
            (today, "AtriaTodayHighlightsStrip(highlights: highlights)"),
            (today, "private struct AtriaTodayHighlightsStrip: View, Equatable"),
            (today, "AtriaTodayLiveStatusStrip(live: liveStore.state,"),
            (today, "AtriaTodayPlanCard(title: planTitle,"),
            (today, "LazyVGrid(columns: glanceColumns, spacing: 10)"),
            (today, "private var glanceColumns: [GridItem]"),
            (today, "if horizontalSizeClass == .regular"),
            # TODO(unbuilt spec / superseded): "Health" and "Strap" Today glance cards
            # were never implemented as AtriaTodayMetric cases, and docs/23 later
            # explicitly decided against a 4th "Health" tab (graphs live in detail
            # views instead) -- Today's glance grid only renders the metrics in
            # AtriaTodayMetric via the generic AtriaTodayGlanceItem(title: metric.label,
            # pattern pinned below.
            (today, "AtriaTodayGlanceItem(title: metric.label,"),
            (today, "AtriaTodayInfoRow(title: \"Journal\","),
            (today, "private struct AtriaTodayLiveStatusStrip: View, Equatable"),
            (today, "private struct AtriaTodayPlanCard: View, Equatable"),
            (today, "private struct AtriaTodayGlanceTile: View, Equatable"),
            (health, "struct AtriaHealthScreen: View"),
            (health, 'Text("Health Monitor")'),
            (health, 'AtriaHealthMetricRow(title: "Recovery",'),
            (health, 'AtriaHealthMetricRow(title: "Resting HR",'),
            (health, 'AtriaHealthMetricRow(title: "HRV",'),
            (health, 'AtriaHealthMetricRow(title: "Respiration",'),
            (strap, "struct AtriaStrapScreen: View"),
            (strap, 'Text("Strap")'),
            (strap, 'AtriaStrapStatusRow(title: "Connection",'),
            (strap, 'AtriaStrapStatusRow(title: "Battery",'),
            (strap, 'AtriaStrapStatusRow(title: "Mode",'),
            (strap, 'AtriaStrapStatusRow(title: "Session",'),
            (strap, 'AtriaStrapStatusRow(title: "Ownership",'),
            (highlights, "enum AtriaHighlights"),
            (highlights, "static func topTwo(rollups: [DailyRollupStoreEntry]) -> [AtriaHighlight]"),
            (tri_ring, "struct AtriaTriRing: View, Equatable"),
            (tri_ring, ".trim(from: 0, to: min(max(fill, 0), 1))"),
            (tri_ring, "StrokeStyle(lineWidth: lineWidth, lineCap: .round)"),
        ]:
            assert_contains(self, text, needle)

        assert_not_contains(self, today, "AtriaOverviewTabContent(statusStore:")
        assert_not_contains(self, health, "AtriaVitalsTabContent(liveStore:")
        assert_not_contains(self, strap, "AtriaCollectionTabContent(coreLiveStore:")

    def test_lb1_connection_ui_uses_strap_stream_state(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        strap = source(ROOT / "Atria" / "Atria" / "AtriaStrapScreen.swift")

        for needle in [
            "var strapStreamConnectionLabel: String",
            "case .lowBatteryShutoff:\n                return \"Charge strap\"",
            "case .lowBatteryReducedDetail:\n                return \"Low battery\"",
            "Strap battery too low for live heart rate. Charge to resume.",
            "var strapStreamConnectionSymbol: String",
            "return coreLiveStore.state.strapStreamConnectionLabel",
            "return coreLiveStore.state.strapStreamConnectionSymbol",
            "switch coreLiveStore.state.strapStreamState",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "systemImage: connectionSymbol",
            "return coreLiveStore.state.strapStreamConnectionLabel",
            "return coreLiveStore.state.strapStreamConnectionDetail",
            "return coreLiveStore.state.strapStreamConnectionSymbol",
            "case .lowBatteryShutoff, .lowBatteryReducedDetail:",
        ]:
            assert_contains(self, strap, needle)

        pull_state = source(ROOT / "pull_atria_state.sh")
        for needle in [
            "active_journal_thermal_state=",
            "active_journal_low_power_mode=",
            "active_journal_power_mode=",
            "active_journal_cadence_multiplier=",
        ]:
            assert_contains(self, pull_state, needle)

    def test_hist1_acceptance_verifier_requires_deliberate_gap_and_timeline(self):
        verifier = source(ROOT / "tools" / "verify_hist1_acceptance.py")
        runner = source(ROOT / "tools" / "run_hist1_acceptance_after_reconnect.sh")
        marker = source(ROOT / "tools" / "start_hist1_phone_away_gap.sh")

        for needle in [
            "MIN_GAP_SECONDS = 60 * 60",
            "MAX_RECONNECT_TO_PULL_SECONDS = 30 * 60",
            "--gap-start",
            "--reconnect",
            "--timeline-screenshot",
            "--timeline-points",
            "missing_deliberate_gap_timestamps",
            "range_loss_backfill_still_pending",
            "archive_metric_not_ready",
            "archive_metric_promotion_blocked",
            "hist1_acceptance_status=",
            'mode = "deliberate_gap"',
            'mode = "current_proof"',
            "timeline_points_lt_",
        ]:
            assert_contains(self, verifier, needle)

        for needle in [
            "--gap-start ISO",
            "--reconnect ISO",
            "pull_atria_state.sh",
            'ATRIA_UI_FIXTURE":"heart-rate-timeline"',
            "device capture screenshot",
            "tools/verify_hist1_acceptance.py",
            "--pull-summary \"$evidence_dir/pull-summary.txt\"",
            "--timeline-screenshot \"$screenshot\"",
            "--gap-start \"$gap_start\"",
            "--reconnect \"$reconnect\"",
            "hist1_acceptance_verifier=",
            "hist1-acceptance-metadata.txt",
            "gap_start=$gap_start",
            "reconnect=$reconnect",
            "pull_time=$pull_time",
            "gap_seconds=$(python3 - \"$gap_start\" \"$reconnect\"",
            "HIST-1 gap is too short",
            "gap_seconds=$gap_seconds",
            "timeline_screenshot=$screenshot",
            "hist1_acceptance_metadata=",
            "--from-marker PATH",
            "marker=${2:?--from-marker requires a value}",
            "gap_start=$(awk -F= '$1 == \"gap_start\" { print $2; exit }' \"$marker\")",
            "marker_device_id=$(awk -F= '$1 == \"device_id\" { print $2; exit }' \"$marker\")",
            "marker_bundle_id=$(awk -F= '$1 == \"bundle_id\" { print $2; exit }' \"$marker\")",
            "marker_start_pull_dir=$(awk -F= '$1 == \"start_pull_dir\" { print $2; exit }' \"$marker\")",
            "device_id=$marker_device_id",
            "bundle_id=$marker_bundle_id",
            "start_pull_dir=$marker_start_pull_dir",
            "if [[ -z \"$reconnect\" ]]; then",
            "reconnect=$(date -Iseconds)",
        ]:
            assert_contains(self, runner, needle)

        for needle in [
            "--label NAME",
            "--device ID",
            "--bundle-id ID",
            "--preflight-pull",
            "preflight_pull=0",
            "preflight_pull=1",
            "pull_atria_state.sh",
            "start_pull_dir=\"$evidence_dir/start-state-pull\"",
            "gap_start=$(date -Iseconds)",
            "gap_start=$gap_start",
            "device_id=$device_id",
            "bundle_id=$bundle_id",
            "preflight_pull=$preflight_pull",
            "start_pull_dir=$start_pull_dir",
            "tools/run_hist1_acceptance_after_reconnect.sh --from-marker $marker",
            "hist1_gap_marker=%s",
            "device_id=%s",
            "bundle_id=%s",
            "preflight_pull=%s",
        ]:
            assert_contains(self, marker, needle)

    def test_ia61_today_screen_keeps_sleep_recovery_strain_order(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        body = today[today.index("var body: some View"):today.index("private var triRingHero")]

        ordered_tokens = [
            "triRingHero",
            "AtriaTodayLiveStatusStrip(live: liveStore.state,",
            # Perf pass (2026-07-06 docs/26 follow-up): AtriaHighlights.topTwo
            # was hoisted out of the Today body into a
            # dailyRollupHistoryRevision-memoized `highlights` property (it was
            # re-sorting the full history up to 4x per ~700ms live tick). The
            # highlights section still renders in this exact slot, so the
            # ordering marker migrates from the (now-hoisted) topTwo call to the
            # section's guard condition, which occupies the same position.
            "if layoutConfig.showHighlights && !highlights.isEmpty",
            "AtriaTodayHighlightsStrip(highlights: highlights)",
            "AtriaTodayPlanCard(title: planTitle,",
            "LazyVGrid(columns: glanceColumns, spacing: 10)",
            "if layoutConfig.showAICoach && effectiveAICoachSettings.mode != .off",
            "AtriaTodayInfoRow(title: \"Journal\",",
        ]
        positions = [body.index(token) for token in ordered_tokens]
        self.assertEqual(positions, sorted(positions), "Today stack must match 6.1 order")

        # Ring-metric-picker migration (coordinated pin update): the tri-ring
        # hero used to be constructed via the fixed literal
        # "AtriaTriRing(sleep: sleepMetric," call -- AtriaTriRing now takes a
        # `slots: [AtriaTriRingSlotContent]` array (any of sleep/recovery/
        # strain/hrv/rhr per ring position) plus an `actions:` dictionary
        # instead of the old onSleep/onRecovery/onStrain closures, so Today
        # can let each ring show any of the five supported metrics. The
        # backward-compatible sleep/recovery/strain initializer is preserved
        # in AtriaTriRing.swift for the call sites that were not part of
        # this migration (AtriaOverviewSections.swift, AtriaCustomizeSheet.swift).
        for needle in [
            "AtriaTriRing(slots: ringSlots.map { AtriaTriRingSlotContent(slot: $0, metric: metric(for: $0)) },",
            "accessibilitySummary: accessibilitySummary",
            "actions: ringActions",
            ".sleep: { metricDetail = .sleep }",
            ".recovery: { metricDetail = .recovery }",
            ".strain: { metricDetail = .strain }",
            ".hrv: { metricDetail = .hrv }",
            ".rhr: { metricDetail = .restingHeartRate }",
        ]:
            assert_contains(self, today, needle)

        # Glance titles are now driven by AtriaTodayMetric.label (customizable-layout
        # rework, ac1a820f) rather than literal per-metric AtriaTodayGlanceItem(title:
        # "...") calls. Confirm the generic pattern is wired up and that Sleep/Recovery/
        # Strain are still represented among the glance-item cases.
        assert_contains(self, today, "AtriaTodayGlanceItem(title: metric.label,")
        for case_name in ["case .sleep:", "case .recovery:", "case .strain:"]:
            assert_contains(self, today, case_name)
        # TODO(unbuilt spec): the original IA-6.1 handoff also named "Health", "Strap",
        # and "Plan" glance cards, but those were never implemented as selectable
        # AtriaTodayMetric cases (see AtriaOverviewSections.swift) -- only Sleep/
        # Recovery/Strain/etc. from that enum ever render as glance tiles. Revisit this
        # if/when those surfaces get added as configurable glance metrics.

    def test_ia62_strain_detail_lists_workouts_and_zone_minutes(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")

        for needle in [
            "confirmedWorkouts: store.confirmedWorkouts",
            "confirmedWorkouts: debugMetricDetailWorkouts ?? confirmedWorkouts",
            "let confirmedWorkouts: [UserConfirmedWorkout]",
            "AtriaMetricDetailTemplate(heroValue: latestMetricText(points: preparedHistory.strain[range] ?? [], unit: \"\"),",
            "strainWorkoutSection",
            "AtriaMetricContributorRows(rows: strainContributorRows, tint: Metrics.electricStrain)",
            "private var strainActivityContributorRows: [AtriaMetricContributorRow]",
            "private var todayConfirmedWorkouts: [UserConfirmedWorkout]",
            "private var todayHighZoneSeconds: TimeInterval",
            "private var strainWorkoutSection: some View",
            "private struct AtriaStrainWorkoutRow: View, Equatable",
            "AtriaStrainWorkoutRow(workout: workout)",
            "zoneSeconds?[\"aerobic\"]",
            "\"\\(minutes)m Z3+\"",
            "case \"strain-detail\":",
            "debugMetricDetailWorkouts",
            "UserConfirmedWorkout(id: \"debug-strain-detail-strength\"",
            "UserConfirmedWorkout(id: \"debug-strain-detail-cardio\"",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, vitals, "confirmedWorkouts: store.confirmedWorkouts")
        assert_contains(self, home, '"recovery-detail", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"')
        for needle in [
            "@State private var metricDetail: AtriaMetricDetailKind?",
            ".sheet(item: $metricDetail)",
            "AtriaMetricDetailSheet(metric: detail,",
            "confirmedWorkouts: debugMetricDetailWorkouts ?? store.confirmedWorkouts",
            # Ring-metric-picker migration: metricDetail routing for the tri-ring
            # hero now lives in the `ringActions` dictionary (any of five
            # metrics per ring position) instead of dedicated onSleep/
            # onRecovery/onStrain closures -- see the coordinated pin update
            # in test_ia61 above.
            ".sleep: { metricDetail = .sleep }",
            ".recovery: { metricDetail = .recovery }",
            ".strain: { metricDetail = .strain }",
            "case \"strain-detail\": return .strain",
            "case \"hrv-detail\": return .hrv",
            "case \"rhr-detail\": return .restingHeartRate",
            "case \"respiratory-detail\": return .respiratoryRate",
            "UserConfirmedWorkout(id: \"debug-today-strain-strength\"",
            "UserConfirmedWorkout(id: \"debug-today-strain-cardio\"",
        ]:
            assert_contains(self, today, needle)

    def test_ia64_weekly_plan_lives_on_rebuilt_today_and_opens_report(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")

        for needle in [
            "@State private var showWeeklyReport = false",
            "AtriaTodayWeeklyPlanCard(plan: weeklyPlan)",
            "showWeeklyReport = true",
            ".sheet(isPresented: $showWeeklyReport)",
            "AtriaWeeklyReportSheet(report: weeklyReport)",
            "private var weeklyPlan: WeeklyPlan",
            "WeeklyPlanStore().currentPlan(rollups: highlightRollups)",
            "private var weeklyReport: WeeklyReport",
            "WeeklyReport(rollups: highlightRollups)",
            "private struct AtriaTodayWeeklyPlanCard: View, Equatable",
            "ForEach(Array(plan.targets.prefix(3)))",
            ".gaugeStyle(.accessoryLinearCapacity)",
            "private struct AtriaTodayWeeklyPlanTargetRow: View, Equatable",
            "private static func debugShowsWeeklyReport(arguments: [String]) -> Bool",
            "arguments[valueIndex] == \"weekly-report\"",
        ]:
            assert_contains(self, today, needle)

        assert_contains(self, overview, "struct AtriaWeeklyReportSheet: View")
        assert_not_contains(self, today, "ForEach(plan.targets)")

    def test_cd10_share_cards_use_safe_zone_wordmark_and_story_editor(self):
        share = source(ROOT / "Atria" / "Atria" / "AtriaShareCard.swift")
        plist = source(ROOT / "Atria" / "Info.plist")

        for needle in [
            "import PhotosUI",
            "import Photos",
            "import UIKit",
            "private var atriaSafeWordmark: some View",
            'Text("A T R I A")',
            "weight: .thin",
            ".tracking(format == .story ? 11.0 : 6.2)",
            "private enum AtriaShareSaveState: Equatable",
            "case pearl",
            "case blush",
            "case sage",
            "case sky",
            "case champagne",
            "private var weeklyHeroSize: CGFloat",
            "format == .story ? 286 : 132",
            "if format == .story, let note = snapshot.note, !note.isEmpty",
            "if format == .story {\n                    Text(dateLine)",
            "let photoBackground: UIImage?",
            "photoBackground: UIImage? = nil",
            "previewStage",
            "controlDock",
            "canvasPicker",
            "@State private var controlsRefreshID = UUID()",
            ".id(controlsRefreshID)",
            "ToolbarItem(placement: .topBarLeading)",
            'ShareLink(item: shareURL,',
            "private func saveShareCardToPhotos()",
            "savePNGToPhotoLibrary(from: shareURL)",
            ".toolbarBackground(.hidden, for: .navigationBar)",
            "format: .story",
            "ScrollView(.horizontal, showsIndicators: false)",
            "HStack(spacing: 10)",
            ".frame(height: 74)",
            ".contentMargins(.horizontal, 6, for: .scrollContent)",
            ".frame(width: 66, height: 72)",
            ".clipShape(Circle())",
            "private func selectCanvas(_ style: AtriaShareCanvasStyle)",
            "UIImpactFeedbackGenerator(style: .light).impactOccurred()",
            "private var shareableStats: [AtriaShareSnapshot.Stat]",
            "private var recoveryEvidenceLine: String",
            "return \"HRV \\(hrv) · RHR \\(rhr)\"",
            "AtriaShareSnapshot.Stat(id: \"recovery\"",
            "AtriaShareSnapshot.Stat(id: \"sleep\"",
            "AtriaShareSnapshot.Stat(id: \"strain\"",
            "private static func fixedDailyStatIDs() -> Set<String>",
            '["recovery", "strain", "sleep"]',
            ".id(renderKey)",
            "private func canvasButtonLabel(",
            "PhotosPicker(selection: $selectedPhotoItem, matching: .images)",
            'canvasButtonLabel(title: "Photo"',
            'canvasButtonLabel(title: "Camera"',
            "private struct AtriaShareCameraPicker: UIViewControllerRepresentable",
            "UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary",
            ".presentationDetents([.large])",
            ".padding(.top, format == .story ? 46 : 34)",
            ".padding(.top, format == .story ? 22 : 16)",
            ".padding(.horizontal, format == .story ? 36 : 34)",
            "private var dailyHeroSize: CGFloat",
            "format == .story ? 244 : 220",
            "ring(snapshot.sleep, diameter: format == .story ? 244 : 220",
            "Spacer(minLength: format == .story ? 170 : 48)",
            "GeometryReader { proxy in",
            "previewStage(in: proxy.size)",
            "private func previewStage(in size: CGSize) -> some View",
            ".background(Color.black.ignoresSafeArea())",
            "let availableWidth = max(size.width, 1)",
            "let availableHeight = max(size.height - 82, 1)",
            "private func previewCornerRadius(for size: CGSize) -> CGFloat",
            "private func previewSize(for size: CGSize) -> CGSize",
            "shareToolbarLabel(\"Share\", systemImage: \"square.and.arrow.up\")",
            "shareToolbarLabel(\"Done\", systemImage: \"checkmark\")",
            "let aspect = AtriaShareFormat.story.renderSize.width / AtriaShareFormat.story.renderSize.height",
            "let widthFromHeight = availableHeight * aspect",
            "let width = max(availableWidth, widthFromHeight)",
            "return CGSize(width: width, height: width / aspect)",
            "let fillsStage = preview.width >= size.width && preview.height >= size.height",
            ".scaleEffect(previewScale(for: size), anchor: .top)",
            "private func previewScale(for size: CGSize) -> CGFloat",
            "previewSize(for: size).height / AtriaShareFormat.story.renderSize.height",
            ".offset(y: previewYOffset(for: size))",
            "private func previewYOffset(for size: CGSize) -> CGFloat",
            "LinearGradient(colors: [.clear, .black.opacity(0.66)]",
            "fixed-daily-trio",
            "canvasButtonLabel(title: \"Clear\"",
            "static func savePNGToPhotoLibrary(from url: URL) async throws",
            "PHPhotoLibrary.requestAuthorization(for: .addOnly)",
            "PHAssetCreationRequest.forAsset()",
            "request.addResource(with: .photo, fileURL: url, options: options)",
            "struct PersonalRecord: Equatable, Hashable",
            "var personalRecord: PersonalRecord? = nil",
            "private func personalRecordSpotlight",
            "snapshot.personalRecord?.exercise",
        ]:
            assert_contains(self, share, needle)
        assert_not_contains(self, share, "AtriaLogo")
        assert_not_contains(self, share, "snapshot.defaultStats")
        assert_not_contains(self, share, "private var previewScale: CGFloat")
        assert_not_contains(self, share, "private var previewHeight: CGFloat")
        assert_not_contains(self, share, "private var atriaFooterLockup: some View")
        daily_sheet = re.search(r"struct AtriaShareSheet: View \{(?P<body>.*?)\nstruct AtriaWorkoutShareSheet", share, re.S)
        self.assertIsNotNone(daily_sheet)
        assert_not_contains(self, daily_sheet.group("body"), "shareToolbarLabel(saveState.label, systemImage: saveState.systemImage)")
        assert_not_contains(self, daily_sheet.group("body"), 'Picker("Format"')
        assert_not_contains(self, daily_sheet.group("body"), "@State private var selectedStatIDs")
        assert_not_contains(self, daily_sheet.group("body"), "statPicker")
        assert_not_contains(self, daily_sheet.group("body"), "toggleStat")
        assert_not_contains(self, daily_sheet.group("body"), "statButtonLabel")
        workout_sheet = re.search(r"struct AtriaWorkoutShareSheet: View \{(?P<body>.*?)\nprivate struct AtriaShareCameraPicker", share, re.S)
        self.assertIsNotNone(workout_sheet)
        assert_not_contains(self, workout_sheet.group("body"), 'Picker("Format"')
        assert_not_contains(self, workout_sheet.group("body"), "ScrollView(showsIndicators: false)")
        weekly_sheet = re.search(r"struct AtriaWeeklyShareSheet: View \{(?P<body>.*?)\n@MainActor", share, re.S)
        self.assertIsNotNone(weekly_sheet)
        assert_not_contains(self, weekly_sheet.group("body"), 'Picker("Format"')
        assert_not_contains(self, weekly_sheet.group("body"), "ScrollView(showsIndicators: false)")
        assert_not_contains(self, share, 'Image("AtriaLogo")')
        assert_not_contains(self, share, "private func atriaLogoMark(size: CGFloat) -> some View")
        assert_not_contains(self, share, "private func atriaFallbackGlyph(size: CGFloat) -> some View")
        assert_contains(self, plist, "NSCameraUsageDescription")
        assert_contains(self, plist, "NSPhotoLibraryUsageDescription")
        assert_contains(self, plist, "NSPhotoLibraryAddUsageDescription")

    def test_cd1_heart_rate_broadcast_uses_standard_ble_and_debug_proof(self):
        broadcaster = source(ROOT / "Atria" / "Atria" / "AtriaHeartRateBroadcaster.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        plist = source(ROOT / "Atria" / "Info.plist")
        pull = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "final class AtriaHeartRateBroadcaster",
            "CBPeripheralManager(delegate: self, queue: nil)",
            'CBUUID(string: "180D")',
            'CBUUID(string: "2A37")',
            'CBUUID(string: "2A38")',
            'CBAdvertisementDataLocalNameKey: "Atria HR"',
            "Data([0x02])",
            "Self.measurementPayload(heartRate: heartRate, rrIntervalsMS: rrIntervalsMS)",
            "rrIntervalsMS.prefix(4)",
            'ATRIADBG hr_broadcast status=advertising name=Atria_HR',
            'ATRIADBG hr_broadcast status=sent bpm=%d rr=%d',
            'static let debugStatusKey = "atria.debug.hrBroadcast.status"',
            'static let debugSentCountKey = "atria.debug.hrBroadcast.sentCount"',
            'static let debugLastBPMKey = "atria.debug.hrBroadcast.lastBPM"',
            'UserDefaults.standard.set("advertising", forKey: Self.debugStatusKey)',
            'UserDefaults.standard.set("sent", forKey: Self.debugStatusKey)',
        ]:
            assert_contains(self, broadcaster, needle)

        for needle in [
            "--atria-test-hr-broadcast",
            "persistentHeartRateBroadcastEnabled = true",
            'ATRIADBG hr_broadcast_fixture status=enabled persistent=1',
            'updateHeartRateBroadcastState(reason: "debug_fixture")',
            "heartRateBroadcaster.publish(heartRate: state.heartRate)",
            "model.setHeartRateBroadcastActive(heartRateBroadcaster.isBroadcasting)",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "hr_broadcast_debug_status",
            "hr_broadcast_debug_sent_count",
            "hr_broadcast_debug_last_bpm",
            "hr_broadcast_debug_reason",
        ]:
            assert_contains(self, pull, needle)

        assert_contains(self, live_workout, 'Label("Broadcast heart rate", systemImage: "antenna.radiowaves.left.and.right")')
        assert_contains(self, settings, 'Label("Broadcast heart rate", systemImage: "antenna.radiowaves.left.and.right")')
        assert_contains(self, plist, "<string>bluetooth-peripheral</string>")

    def test_cd5_strain_target_today_fixtures_are_real_hero_states(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        haptics = source(ROOT / "Atria" / "Atria" / "AtriaHapticAlerts.swift")
        pull = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "private var displayHero: AtriaHomeModel.HeroSnapshot",
            "private static func debugHeroSnapshot(arguments: [String]) -> AtriaHomeModel.HeroSnapshot?",
            'case "strain-target-under":',
            'case "strain-target-at":',
            'case "strain-target-over":',
            "let guidance = Coach.guide(recovery: recovery, strain: strain, load: .learning)",
            "value: displayHero.strainValue",
            # Strain-ring-semantics pass (2026-07-05): the ring fill switched from
            # strain-relative-to-target to absolute strain/21 (WHOOP scale), with the
            # former strain/target math now driving the ring's target marker instead
            # (targetFraction) -- see AtriaTriRing.swift's always-colorful-rings +
            # target-marker work landing alongside this pin update.
            # Ring-geometry-v2 + color-coherence pass (2026-07-05): the 0-21 WHOOP
            # scale was replaced by a clean 0-20 scale (100% ring == strain 20), so
            # the ring's fill/target-marker fractions divide by 20.0, not 21.0 --
            # see AtriaTriRing.swift/AtriaTodayScreen.swift's ring-geometry-v2 pass.
            "fill: min(max(displayHero.strain / 20.0, 0), 1)",
            "targetFraction: target.map { min(max($0 / 20.0, 0), 1) }",
            "tint: displayHero.guidance.color",
        ]:
            assert_contains(self, today, needle)
        for needle in [
            "private static let strainTargetGuidanceRefreshInterval: TimeInterval = 10 * 60",
            "private static let strainTargetGuidanceTimer = Timer.publish(every: strainTargetGuidanceRefreshInterval",
            "Self.strainTargetGuidanceTimer.map { _ in () }.eraseToAnyPublisher()",
            "--atria-test-strain-target-haptic",
            "triggerDebugStrainTargetHapticIfRequested()",
            "ATRIADBG haptic_alert_fixture kind=strain_target status=requested",
            "hapticCoordinator.update(AtriaHapticAlertCoordinator.Snapshot(status: .connected",
            "strain: 12.4",
            "strainTarget: 12.0",
        ]:
            assert_contains(self, home, needle)
        for needle in [
            'static let debugStrainTargetStatusKey = "atria.debug.strainTargetHaptic.status"',
            'static let debugStrainTargetCountKey = "atria.debug.strainTargetHaptic.count"',
            'UserDefaults.standard.set("fired", forKey: Self.debugStrainTargetStatusKey)',
            "UINotificationFeedbackGenerator().notificationOccurred(.success)",
            "ATRIADBG haptic_alert kind=strain_target",
        ]:
            assert_contains(self, haptics, needle)
        for needle in [
            "strain_target_haptic_debug_status",
            "strain_target_haptic_debug_count",
            "strain_target_haptic_debug_strain",
            "strain_target_haptic_debug_target",
        ]:
            assert_contains(self, pull, needle)

    def test_cd3_after_nap_recovery_fixture_shows_lift_label(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            'case "recovery-after-nap":',
            'arguments[valueIndex] == "recovery-after-nap" ? 68 : 50',
            'recoveryLiftedAfterNap: arguments[valueIndex] == "recovery-after-nap"',
            # displayRecovery carry-forward wrapper (2026-07-05) keeps the same
            # nap-lift detail inside the live path.
            "value: display.value",
            'let detail = displayHero.recoveryLiftedAfterNap ? "↑ after nap" : displayHero.recoveryDetail',
        ]:
            assert_contains(self, today, needle)

        assert_contains(self, home, 'return recoveryLiftedAfterNap ? "\\(base) · ↑ after nap" : base')
        assert_contains(self, sessions, "func localHRVWindowCount(in start: Date, end: Date) -> Int")
        assert_contains(self, sessions, "hrvWindowCount: metrics.hrvWindowCount")
        assert_contains(self, sessions, "&& nap.hrvWindowCount >= AtriaNapRecovery.minimumQualifyingHRVWindows")
        assert_contains(self, sessions, "let qualifyingWindows = bestNap?.hrvWindowCount ?? 0")
        self.assertNotIn("let qualifyingWindows = bestNap?.hrv == nil ? 0 : AtriaNapRecovery.minimumQualifyingHRVWindows",
                         sessions)

    def test_cd6_today_stress_opens_breathwork_fixture(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        breathwork = source(ROOT / "Atria" / "Atria" / "AtriaBreathworkSession.swift")

        # Pin migrated (2026-07-05, visibility/IA route audit): the old
        # `item.id == "Stress"` string check compared against `metricKey`,
        # which is `AtriaTodayMetric.stress.rawValue` -- Swift auto-derives
        # that as the lowercase `"stress"`, never the capitalized literal --
        # so this branch never actually matched and the Stress tile silently
        # dead-ended like every other tile. Replaced with a real enum
        # comparison as part of routing every glance tile to its detail.
        for needle in [
            "@State private var showBreathworkSession = false",
            "if metric == .stress {",
            "showBreathworkSession = true",
            "AtriaBreathworkSession(currentHeartRate: pulseStore.state.heartRate,",
            "currentRRSamples: pulseStore.state.recentRRSamples",
            "onSave: { session in",
            "store.add(session)",
            "private static func debugShowsBreathwork(arguments: [String]) -> Bool",
            '["breathwork-session", "breathwork-result-rr"].contains(arguments[valueIndex])',
            '"breathwork-result-rr"',
            "case .stress:",
            "systemImage: metric.systemImage",
        ]:
            assert_contains(self, today, needle)

        for needle in [
            "struct RRSample: Equatable",
            "let currentRRSamples: [RRSample]",
            "@State private var rrSamples: [RRSample] = []",
            "Text(\"Breathwork\")",
            "Text(\"5.5 breaths/min\")",
            "Picker(\"Duration\", selection: $selectedDuration)",
            "Label(\"Start\", systemImage: \"play.fill\")",
            "Text(currentHeartRate > 0 ? \"\\(currentHeartRate) bpm\" : \"HR learning\")",
            "let onSave: (SavedSession) -> Void",
            "static func savedSession(samples: [HeartSample],",
            "rrPoints: rrPoints.isEmpty ? nil : rrPoints",
            "private static func rmssd(in samples: [RRSample], start: Date, end: Date) -> Double?",
            "* 0.8",
            "label: \"Breathwork\"",
            "kind: \"breathwork\"",
        ]:
            assert_contains(self, breathwork, needle)

        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")
        for needle in [
            "var kind: String? = nil",
            "var isBreathwork: Bool",
            "guard !isBreathwork else { return 0 }",
            "XCTAssertEqual(saved.kind, \"breathwork\")",
            "XCTAssertEqual(saved.trimp(rest: 60, max: 190), 0)",
            "XCTAssertEqual(breathwork.trimp(rest: 60, max: 190), 0)",
        ]:
            assert_contains(self, sessions + tests, needle)

    def test_cd7_settings_max_hr_suggestion_fixture(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        suggestion = source(ROOT / "Atria" / "Atria" / "AtriaMaxHRSuggestion.swift")

        for needle in [
            "maxHRSuggestion: debugMaxHRSuggestion ?? store.cachedMaxHRSuggestion",
            "store.dismissMaxHRSuggestion(observedPeak: observedPeak)",
            "private var debugMaxHRSuggestion: AtriaMaxHRSuggestion?",
            'Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "max-hr-suggestion"',
            "AtriaMaxHRSuggestion(observedPeak: 193, currentMaxHR: 190)",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "if let maxHRSuggestion",
            "maxHRSuggestionRow(maxHRSuggestion)",
            "Label(suggestion.title, systemImage: \"heart.circle.fill\")",
            "Label(\"Update\", systemImage: \"checkmark.circle.fill\")",
            "Text(\"Not now\")",
        ]:
            assert_contains(self, settings, needle)

        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        for needle in [
            "@Published private(set) var cachedMaxHRSuggestion: AtriaMaxHRSuggestion?",
            "private static let maxHRSuggestionLastRollupMonthKey",
            "refreshMaxHRSuggestion(reason: \"daily_rollup\", force: false)",
            "private func refreshMaxHRSuggestion(reason: String,",
            "private func makeMaxHRSuggestion(now: Date = Date(), calendar: Calendar = .current) -> AtriaMaxHRSuggestion?",
            "func dismissMaxHRSuggestion(observedPeak: Int, now: Date = Date())",
            "ATRIADBG max_hr_suggestion_rollup status=%@",
        ]:
            assert_contains(self, sessions, needle)

        assert_contains(self, suggestion, '"Observed peak \\(observedPeak) -- update max HR?"')
        assert_contains(self, suggestion, '"Zones and strain use this."')

    def test_cd8_health_screen_shows_fitness_age_card(self):
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        fitness = source(ROOT / "Atria" / "Atria" / "AtriaFitnessAge.swift")

        for needle in [
            "AtriaHealthFitnessAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary)",
            "private struct AtriaHealthFitnessAgeCard: View, Equatable",
            'Text("Fitness age")',
            # Migrated: the static "Ny younger/older" subtitle was replaced by
            # an animated arrow + count-up delta reveal (spring, reduce-motion
            # aware); "Calibrating 28-day baseline" still renders unchanged
            # while not ready.
            'Text("Calibrating 28-day baseline")',
            "Text(summary.footnote)",
            '"Fitness age. \\(summary.valueText).',
        ]:
            assert_contains(self, health, needle)

        assert_contains(self, fitness, 'static let footnoteText = "Estimate from heart data — not a medical measurement."')

    def test_live_activity_uses_end_user_reading_language(self):
        app_attributes = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityAttributes.swift")
        widget_attributes = source(ROOT / "Atria" / "AtriaWidget" / "AtriaLiveActivityAttributes.swift")
        coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for text in [app_attributes, widget_attributes, coordinator]:
            assert_contains(self, text, "readingCount")
            assert_not_contains(self, text, "sampleCount")

        assert_contains(self, home, "readingCount: model.coreLiveStore.state.sessionSampleCount")
        assert_contains(self, widget, "context.state.readingCount")
        assert_contains(self, widget, "readings ·")
        assert_not_contains(self, widget, "samples ·")

    def test_standby_overlay_is_charging_landscape_and_metric_rich(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private func shouldShowStandBy(isLandscape: Bool) -> Bool",
            "guard isLandscape else { return false }",
            "guard model.coreLiveStore.state.status == .connected else { return false }",
            "guard batteryState == .charging || batteryState == .full else { return false }",
            "AtriaStandByOverlay(coreLiveStore: model.coreLiveStore,",
            "private struct AtriaStandByOverlay: View",
            "AtriaStandByMetric(title: \"Calories\"",
            "value: coreLiveStore.state.liveActiveCaloriesText",
            "detail: coreLiveStore.state.liveActiveCalories == nil ? \"Profile needed\" : \"Active estimate\"",
            "AtriaStandByMetric(title: \"Battery\"",
        ]:
            assert_contains(self, home, needle)

    def test_widget_snapshot_refreshes_from_live_bpm_on_safe_cadence(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        widget_snapshot = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")

        for needle in [
            "private static let liveWidgetSnapshotMinimumInterval: TimeInterval = 45",
            "private static let liveWidgetSnapshotMeaningfulChangeInterval: TimeInterval = 15",
            "private static let liveWidgetSnapshotMeaningfulBPMDelta = 4",
            "@State private var lastLiveWidgetSnapshotAt: Date?",
            "@State private var lastLiveWidgetSnapshotHeartRate: Int?",
            "publishLiveWidgetSnapshotIfNeeded()",
            "private func publishLiveWidgetSnapshotIfNeeded(now: Date = Date())",
            "guard scenePhase == .active else { return }",
            "let heartRate = model.pulseLiveStore.state.heartRate",
            "guard heartRate > 0 else { return }",
            "let meaningfulDelta = lastLiveWidgetSnapshotHeartRate.map {",
            "abs(heartRate - $0) >= Self.liveWidgetSnapshotMeaningfulBPMDelta",
            "let cadenceReady = elapsed.map { $0 >= Self.liveWidgetSnapshotMinimumInterval } ?? true",
            "let changeReady = meaningfulDelta",
            "elapsed.map { $0 >= Self.liveWidgetSnapshotMeaningfulChangeInterval } ?? true",
            "guard cadenceReady || changeReady else",
            "lastLiveWidgetSnapshotHeartRate = heartRate",
            "reason: cadenceReady ? \"live_throttled\" : \"live_bpm_delta\"",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "heartRate: ble.heartRate > 0 ? ble.heartRate : nil",
            "WidgetCenter.shared.reloadAllTimelines()",
        ]:
            assert_contains(self, widget_snapshot, needle)

    def test_widgets_deep_link_to_matching_tabs(self):
        plist = source(ROOT / "Atria" / "Info.plist")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "<key>CFBundleURLTypes</key>",
            "<string>com.adidshaft.atria</string>",
            "<string>atria</string>",
        ]:
            assert_contains(self, plist, needle)

        for needle in [
            "var deepLinkPath: String",
            "static func deepLinkDestination(for url: URL) -> HomeTab?",
            "guard url.scheme?.lowercased() == \"atria\" else { return nil }",
            "case \"data\", \"collection\": return .collection",
            ".onOpenURL(perform: handleDeepLink)",
            "private func handleDeepLink(_ url: URL)",
            "selectedTab = tab",
            "model.loadDeferredDiagnosticsIfNeeded(reason: \"deeplink_\\(tab.deepLinkPath)\")",
            "ATRIADBG deeplink status=handled",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "private let atriaOverviewURL = URL(string: \"atria://tab/overview\")!",
            "private let atriaVitalsURL = URL(string: \"atria://tab/vitals\")!",
            ".widgetURL(atriaOverviewURL)",
            "var deepLinkURL: URL",
            "case .steps, .strain:",
            "return atriaOverviewURL",
            "case .hrv, .bpm:",
            "return atriaVitalsURL",
            ".widgetURL(metric.deepLinkURL)",
            "deepLinkURL: AtriaWidgetMetric.strain.deepLinkURL",
            "deepLinkURL: AtriaWidgetMetric.bpm.deepLinkURL",
            "private func widgetMetricLink(_ metric: AtriaWidgetMetric) -> some View",
            "Link(destination: metric.deepLinkURL)",
        ]:
            assert_contains(self, widget, needle)

    def test_home_screen_widgets_use_richer_small_and_medium_layouts(self):
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "private var systemSmallWidget: some View",
            "private var systemMediumWidget: some View",
            "case .systemLarge:\n                systemLargeWidget",
            "private var systemLargeWidget: some View",
            "private var widgetHeader: some View",
            "private func compactMetric(_ title: String,",
            "private func widgetMetricTile(_ title: String, value: String, icon: String, tint: Color) -> some View",
            "private func widgetMetricLink(_ metric: AtriaWidgetMetric) -> some View",
            "private struct AtriaWidgetRecoveryGauge: View",
            "AtriaWidgetRecoveryGauge(percent: entry.snapshot?.recoveryPercent)",
            ".frame(width: 72, height: 72)",
            ".frame(width: 92, height: 92)",
            ".frame(width: 118, height: 118)",
            "private var largeBatteryText: String",
            "controlButtons",
            "private var largeFooterText: String",
            "widgetMetricLink(widgetMetrics[0])",
            "widgetMetricLink(widgetMetrics[1])",
            "widgetMetricLink(widgetMetrics[2])",
            "widgetMetricLink(widgetMetrics[3])",
            ".supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])",
            ".accessibilityLabel(percent.map { \"Recovery \\($0) percent\" } ?? \"Recovery learning\")",
        ]:
            assert_contains(self, widget, needle)

        assert_not_contains(self, widget, "// Recovery + Strain are the headline pair.")

    def test_single_metric_widgets_support_home_screen_small_and_medium_layouts(self):
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")

        for needle in [
            "// MARK: - Single-metric widgets (Home Screen + Lock Screen)",
            "case .systemSmall:\n                systemSmallMetric",
            "case .systemMedium:\n                systemMediumMetric",
            "private var systemSmallMetric: some View",
            "private var systemMediumMetric: some View",
            "var tint: Color",
            "var unit: String",
            "Text(metric.unit.uppercased())",
            "Text(metricFooterText)",
            "private var metricFooterText: String",
            ".accessibilityLabel(\"\\(metric.title) \\(value), \\(metricFooterText)\")",
            ".accessibilityLabel(\"\\(metric.title) \\(value), \\(metric.unit), \\(metricFooterText)\")",
            ".description(\"Strap-derived steps on your Home Screen or Lock Screen.\")",
            ".description(\"Today's strain on your Home Screen or Lock Screen.\")",
            ".description(\"Latest HRV on your Home Screen or Lock Screen.\")",
            ".description(\"Latest heart rate on your Home Screen or Lock Screen.\")",
            ".supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])",
        ]:
            assert_contains(self, widget, needle)

        self.assertGreaterEqual(
            widget.count(".supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])"),
            4,
        )

    def test_live_activity_updates_are_throttled_off_the_sample_hot_path(self):
        coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")

        for needle in [
            "private var lastActivitySnapshot: Snapshot?",
            "private var lastActivityUpdateAt: Date?",
            "private var pendingActivityUpdateTask: Task<Void, Never>?",
            "private let minimumActivityUpdateInterval: TimeInterval = 15",
            "enqueueActivityUpdate(snapshot, now: now)",
            "shouldSendActivityUpdateImmediately",
            "nextActivityUpdateDelay",
            "pendingActivityUpdateTask?.cancel()",
        ]:
            assert_contains(self, coordinator, needle)

    def test_media_controller_is_inert_no_music_interference(self):
        # The media-control feature was removed so Atria never interferes with the
        # user's music (AirPods/speaker) or drains battery polling now-playing.
        # AtriaMediaController must stay inert: no MediaPlayer import, no
        # system music player, no playback notifications, no polling loop.
        media = source(ROOT / "Atria" / "Atria" / "AtriaMediaControls.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")

        for needle in [
            "final class AtriaMediaController",
            "var hasNowPlayingInfo = false",
            "func setRefreshLoopActive(_ active: Bool) {}",
        ]:
            assert_contains(self, media, needle)

        for forbidden in [
            "import MediaPlayer",
            "MPMusicPlayerController",
            "beginGeneratingPlaybackNotifications",
            "player.play()",
            "player.pause()",
            "skipToNextItem",
            "Task.sleep(nanoseconds: 10_000_000_000)",
        ]:
            assert_not_contains(self, media, forbidden)

        for forbidden in [
            "shortcutsSection",
            "Strap tap shortcuts",
            "music, calls",
            "are coming once",
            "privacyComingSoon",
            "Coming soon",
        ]:
            assert_not_contains(self, settings, forbidden)
        assert_contains(self, settings, "LabeledContent(\"Privacy\")")
        assert_contains(self, settings, "Local-first; no account or cloud sync")

    def test_deferred_home_diagnostics_do_not_overlap(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "private var diagnosticsWorkInFlight = false",
            "guard !diagnosticsWorkInFlight else",
            "reason=refresh_in_flight",
            "diagnosticsWorkInFlight = true",
            "diagnosticsWorkInFlight = false",
            "Self.makeDeferredDetails(ble: self.ble, store: self.store)",
        ]:
            assert_contains(self, home, needle)

    def test_backdrop_respects_reduce_transparency(self):
        shell = source(ROOT / "Atria" / "Atria" / "AtriaHomeShellSupport.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        guide = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "let reduceTransparency: Bool",
            "if reduceTransparency",
            "private var reducedTransparencyFill: Color",
        ]:
            assert_contains(self, shell, needle)

        assert_contains(self, home, "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency")
        assert_contains(self, home, "AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)")
        assert_contains(self, guide, "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency")
        assert_contains(self, guide, "AtriaBackdropLayer(isDark: true, reduceTransparency: reduceTransparency)")

    def test_user_flow_animations_respect_reduce_motion(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        heart_rate = source(ROOT / "Atria" / "Atria" / "HeartRate.swift")

        for text in [home, overview, collection, content, heart_rate]:
            assert_contains(self, text, "accessibilityReduceMotion")

        assert_contains(self, home, "private func performMotionAwareUpdate")
        assert_contains(self, home, "if reduceMotion")
        assert_contains(self, heart_rate, ".animation(reduceMotion ? nil")

    def test_section_render_paths_do_not_recompute_session_metrics(self):
        forbidden_calls = [
            ".sorted(",
            ".sorted {",
            ".reduce(",
            ".compactMap(",
            "detectedActivity(",
            "dailyRollups(",
            "aggregateWorkoutCandidates(",
            "aggregateSleepCandidates(",
            "aggregateSleepDiagnostics(",
            "canonicalSessions(",
            "replaySavedWorkoutReadiness(",
        ]

        for path in [
            ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift",
        ]:
            text = source(path)
            for start, block in swift_some_view_blocks(text):
                line = text.count("\n", 0, start) + 1
                for forbidden in forbidden_calls:
                    self.assertNotIn(
                        forbidden,
                        block,
                        f"{path.name}:{line} recomputes session metrics in a render path via {forbidden}",
                    )

    def test_source_avoids_placeholder_bypass_wording(self):
        banned = "".join(chr(code) for code in [110, 111, 111, 112])
        variants = [
            re.compile(rf"\b{re.escape(banned)}\b", re.IGNORECASE),
            re.compile(rf"\b{re.escape(banned[:2])}\s+{re.escape(banned[2:])}\b", re.IGNORECASE),
            re.compile(rf"\b{re.escape(banned[:2])}-{re.escape(banned[2:])}\b", re.IGNORECASE),
        ]
        paths = (
            list(swift_files())
            + list((ROOT / "docs").rglob("*.md"))
            + list((ROOT / "tools").rglob("*.py"))
            + [
                ROOT / "test_handoff_static_checks.py",
                ROOT / "live_device_debug.sh",
            ]
        )

        for path in paths:
            text = source(path)
            for variant in variants:
                self.assertIsNone(
                    variant.search(text),
                    f"{path.relative_to(ROOT)} contains placeholder bypass wording",
                )

    def test_end_user_copy_avoids_lab_only_language(self):
        banned = [
            "backfill",
            "checkpoint",
            "gate",
            "blocker",
            "IMU",
            "RR interval",
            "lnRMSSD",
            "RMSSD",
            "validated",
            "validation",
            "provisional",
            "capture",
            "diagnostic",
            "coexistence",
            "continuity",
            "range loss",
            "artifact",
            "telemetry",
            "fail-closed",
            "metric-usable",
        ]
        allowed_developer_files = {
            "AtriaSettingsView.swift",
            "AtriaResearchProbe.swift",
            "AtriaIMUDecoder.swift",
        }
        visible_literal = re.compile(
            r'\b(?:Text|Label|Button|String\(localized:|AtriaLoadingPanel|AtriaInlineQuickStat|AtriaMetricTile|AtriaSettingsRow|AtriaNoticeRow|AtriaPill|AtriaStatusBadge)\s*\([^"\n]*"([^"\n]*)"'
            r'|(?:title|subtitle|message|body|label|detail|caption|footer|value|shortTitle)\s*:\s*"([^"\n]*)"'
            r'|return\s+"([^"\n]*)"'
        )
        banned_patterns = [
            re.compile(rf"\b{re.escape(term)}\b", re.IGNORECASE)
            for term in banned
        ]
        offenders = []
        for path in swift_files():
            text = source(path)
            relative = path.relative_to(ROOT)
            skip_file = path.name in allowed_developer_files
            in_debug_block = False
            for line_number, line in enumerate(text.splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith("#if DEBUG"):
                    in_debug_block = True
                if stripped.startswith("#endif"):
                    in_debug_block = False
                    continue
                if in_debug_block or skip_file:
                    continue
                if stripped.startswith("//"):
                    continue
                if "AtriaDebugLog" in line or "debug" in line.lower():
                    continue
                for match in visible_literal.finditer(line):
                    literal = next(group for group in match.groups() if group is not None)
                    if ".csv" in literal or "_" in literal:
                        continue
                    if literal == literal.lower() and len(literal.split()) <= 2:
                        continue
                    for pattern in banned_patterns:
                        if pattern.search(literal):
                            offenders.append(f"{relative}:{line_number}: {literal}")
        self.assertEqual([], offenders)

        shared_ui = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        assert_contains(self, shared_ui, "Text(Self.confidenceText(for: estimate.confidence))")
        assert_contains(self, shared_ui, 'return "Checked"')
        assert_contains(self, shared_ui, 'return "Still improving"')
        assert_not_contains(self, shared_ui, "Text(estimate.confidence.rawValue)")
        assert_contains(self, overview, 'return hero.recoveryIsProvisional ? "\\(base) · Early read" : base')
        assert_not_contains(self, overview, 'return hero.recoveryIsProvisional ? "\\(base) · provisional" : base')

    def test_user_path_debug_logs_are_gated(self):
        for rel in [
            ROOT / "Atria" / "Atria" / "ContentView.swift",
            ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift",
            ROOT / "Atria" / "Atria" / "AtriaHomeView.swift",
            ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift",
            ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift",
            ROOT / "Atria" / "Atria" / "HealthKitExporter.swift",
        ]:
            text = source(rel)
            assert_not_contains(self, text, "NSLog(\"ATRIADBG")

        assert_not_contains(self, all_swift_source(), "NSLog(\"ATRIADBG")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        assert_contains(self, debug_logging, "guard AtriaDebugLogging.isEnabled else { return }")
        assert_contains(self, debug_logging, "NSLogv(String(describing: format), pointer)")

    def test_diagnostic_notifications_are_not_production_active(self):
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")

        assert_contains(self, notifications, "private static let actionableBatteryThreshold = 25")
        assert_contains(self, notifications, "private static let actionableDiagnosisCooldown: TimeInterval = 6 * 60 * 60")
        assert_contains(self, notifications, "private static let actionableDiagnosisLastScheduledPrefix")
        assert_contains(self, notifications, "static let active = [recovery, strain, sleepReview, sleepLogged, workoutReview, battery, bluetoothOff, fitCheck, healthDeviation]")
        assert_contains(self, notifications, "case \"Fit check needed\":")
        assert_contains(self, notifications, "kind: \"fit_check\"")
        assert_contains(self, notifications, "static let diagnosticOnly = [diagnostic]")
        assert_contains(self, notifications, "static let removable = active + diagnosticOnly + legacy")
        assert_contains(self, notifications, "static func scheduleActionableConnectionDiagnosis(title: String,")
        assert_contains(self, notifications, "static func refreshActionableConnectionMaintenance(ble: AtriaBLEManager, reason: String)")
        assert_contains(self, notifications, "_ = makeActionableConnectionDecisions(ble: ble)")
        assert_contains(self, notifications, "notification_battery_maintenance status=evaluated")
        assert_contains(self, notifications, "static func cancelActionableConnectionDiagnosis(title: String? = nil, reason: String)")
        assert_contains(self, notifications, "private static func actionableConnectionDiagnosisDecision(title: String,")
        assert_contains(self, notifications, "center.removePendingNotificationRequests(withIdentifiers: identifiers)")
        assert_contains(self, notifications, "ATRIADBG notification_cancel kind=actionable_connection")
        assert_contains(self, notifications, "if pending.contains(where: { $0.identifier == decision.identifier })")
        assert_contains(self, notifications, "reason=pending_request")
        assert_contains(self, notifications, "reason=cooldown")
        assert_contains(self, notifications, "batteryWarningDrainCycleScheduledKey")
        assert_contains(self, notifications, "batteryShutoffDrainCycleScheduledKey")
        assert_contains(self, notifications, "batteryDrainCycleClearedAtKey")
        assert_contains(self, notifications, "batteryDrainCycleAlreadyScheduled(title: decision.title")
        assert_contains(self, notifications, "markBatteryDrainCycleScheduled(title: decision.title")
        assert_contains(self, notifications, "clearBatteryDrainCycleState(reason: batteryIsCharging ? \"charging\" : \"above_threshold\")")
        assert_contains(self, notifications, "let hadDrainCycle = defaults.bool(forKey: batteryWarningDrainCycleScheduledKey)")
        assert_contains(self, notifications, "defaults.set(false, forKey: batteryWarningDrainCycleScheduledKey)")
        assert_contains(self, notifications, "defaults.set(false, forKey: batteryShutoffDrainCycleScheduledKey)")
        assert_contains(self, notifications, "defaults.set(now.timeIntervalSince1970, forKey: batteryDrainCycleClearedAtKey)")
        assert_contains(self, notifications, "had_cycle=%d")
        assert_contains(self, notifications, "reason=drain_cycle_already_scheduled")
        assert_contains(self, notifications, "defaults.removeObject(forKey: actionableDiagnosisLastScheduledPrefix + Identifier.battery)")
        assert_contains(self, notifications, "case \"Strap battery low\", \"Strap battery too low\":")
        assert_contains(self, notifications, "case \"Bluetooth is off\":")
        assert_contains(self, notifications, "bluetooth_permission_inline_only")
        assert_contains(self, notifications, "includeMetricDecisions: debugMetricRequest")
        assert_contains(self, notifications, "includeActionableConnectionDecisions: productionCadence || debugMetricRequest")
        assert_contains(self, notifications, "actionable_connection_decisions=%d")
        assert_contains(self, notifications, "monitor_actionable_connection_triggers")
        assert_contains(self, notifications, "private static func makeMetricDecisions(store: SessionStore,")
        assert_contains(self, notifications, "private static func makeActionableConnectionDecisions(ble: AtriaBLEManager) -> [NotificationDecision]")
        assert_contains(self, notifications, 'static let bluetoothOff = "atria.bluetooth.off"')
        assert_contains(self, notifications, 'kind: "bluetooth_off"')
        assert_contains(self, notifications, "if ble.bluetoothPermissionDenied")
        assert_contains(self, notifications, 'title: "Bluetooth is off"')
        assert_contains(self, notifications, 'Turn on Bluetooth in Settings so Atria can read your strap.')
        assert_contains(self, notifications, "if ble.status == .poweredOff")
        assert_contains(self, notifications, "return [bluetoothDecision]")
        assert_contains(self, notifications, "threshold=%d")
        assert_contains(self, notifications, "drop_recent=%d")
        assert_contains(self, notifications, "let effectiveChargeStatus = battery.chargeStatus")
        assert_contains(self, notifications, "let batteryIsCharging = effectiveChargeStatus == .charging || effectiveChargeStatus == .full")
        assert_contains(self, notifications, "charge=%@")
        assert_contains(self, notifications, "effectiveChargeStatus.rawValue")
        assert_contains(self, notifications, "battery.recentDrop ? 1 : 0")
        assert_contains(self, notifications, "battery.level <= Self.actionableBatteryThreshold")
        assert_contains(self, notifications, "battery.level <= Self.actionableBatteryThreshold && battery.recentDrop && !batteryIsCharging")
        assert_contains(self, notifications, "batterySnapshot(liveLevel: ble.batteryLevel, liveChargeStatus: ble.batteryChargeStatus)")
        assert_contains(self, notifications, "cachedBattery(maxAge: 10 * 60)")
        assert_contains(self, notifications, "AtriaBLEManager.cachedBatteryDrop()")
        assert_contains(self, notifications, "live_2A19_cached_charge")
        assert_contains(self, notifications, "battery_\\(battery.level)_drop_source_\\(battery.source)")
        assert_contains(self, notifications, "battery_\\(battery.level)_low_no_recent_drop_source_\\(battery.source)")
        assert_contains(self, notifications, "battery_\\(battery.level)_charging_\\(effectiveChargeStatus.rawValue)_source_\\(battery.source)")
        assert_contains(self, notifications, 'body: "Charge your strap before a workout or overnight wear. Battery is \\(battery.level)%."')
        assert_contains(self, notifications, 'body: recoveryNotificationBody(percent: percent,')
        assert_contains(self, notifications, 'detail: recovery.detail),')
        assert_contains(self, notifications, '"Recovery is \\(percent)% today. \\(detail) Use it to choose whether to push, hold, or recover."')
        assert_contains(self, notifications, 'body: String(format: "Nice work. You reached today\'s strain target with %.1f strain against a %.1f goal.", strain, target),')
        assert_contains(self, notifications, 'bluetooth_off=%d')
        assert_contains(self, notifications, "title: \"Atria notification test\"")
        assert_contains(self, notifications, "body: \"Local notification delivery is working.\"")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        assert_contains(self, home, "LocalNotificationScheduler.refreshActionableConnectionMaintenance(ble: ble, reason: reason)")
        assert_contains(self, home, "LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,")
        assert_contains(self, home, "if next.sendsLocalNotification && visibleConnectionDiagnosis != next")
        assert_contains(self, home, "LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: \"diagnosis_cleared_\\(reason)\")")
        assert_contains(self, home, "LocalNotificationScheduler.cancelActionableConnectionDiagnosis(title: visibleConnectionDiagnosis?.title,")
        assert_contains(self, home, "LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: \"diagnosis_non_actionable_\\(reason)\")")

        actionable = re.search(
            r"private static func makeActionableConnectionDecisions\(ble: AtriaBLEManager\) -> \[NotificationDecision\] \{(?P<body>.*?)\n    \}",
            notifications,
            re.S,
        )
        self.assertIsNotNone(actionable)
        actionable_body = actionable.group("body")
        bluetooth_index = actionable_body.find("if ble.status == .poweredOff")
        battery_index = actionable_body.find("let battery = batterySnapshot")
        self.assertGreaterEqual(bluetooth_index, 0)
        self.assertGreater(battery_index, bluetooth_index)
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, diagnostic]")
        assert_not_contains(self, notifications, "static let active = [recovery, strain, battery, bluetoothOff, diagnostic]")
        assert_not_contains(self, notifications, "includeMetricDecisions: productionCadence || debugMetricRequest")
        assert_not_contains(self, notifications, "monitor_confidence_gated_metric_triggers")
        assert_not_contains(self, notifications, "Confidence: \\(confidenceText)")
        assert_not_contains(self, notifications, "confidence: recovery.confidence.rawValue,\n                                               detail: recovery.detail")
        assert_not_contains(self, notifications, "title: \"Atria diagnostic\"")
        assert_not_contains(self, notifications, "case \"Bluetooth is off\", \"Bluetooth permission needed\":")
        assert_not_contains(self, notifications, 'title: ble.bluetoothPermissionDenied ? "Bluetooth permission needed" : "Bluetooth is off"')

    def test_background_task_plumbing_is_present(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        plist = source(ROOT / "Atria" / "Info.plist")

        for needle in [
            "import BackgroundTasks",
            "BGTaskScheduler.shared.register",
            "BGAppRefreshTaskRequest",
            "BGProcessingTaskRequest",
            "requiresNetworkConnectivity = false",
            "UIApplication.shared.beginBackgroundTask",
            "ble.flushActiveSessionJournal(reason: reason)",
            "ble.requestOfflineHistoricalSyncIfNeeded(reason: \"\\(reason)_opportunistic\")",
            "offline_sync_started=%d",
            "store.performBackgroundMaintenance(reason: reason)",
        ]:
            assert_contains(self, app, needle)

        maintenance = re.search(
            r"func performBackgroundMaintenance\(reason: String,\s*"
            r"now: Date,\s*calendar: Calendar\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(maintenance)
        maintenance_body = maintenance.group("body")
        for needle in [
            "flushScheduledPersistence(reason:",
            "writeAutomaticSessionBackup(reason: reason)",
            "HealthKitExporter.diagnostics(for: sessions,",
            "ATRIADBG bg_maintenance status=ok",
        ]:
            assert_contains(self, maintenance_body, needle)
        for forbidden in [
            "dailyRollups(",
            "trendSummaries(",
            "detectedActivities(",
        ]:
            assert_not_contains(self, maintenance_body, forbidden)

        bounded_gate = re.search(
            r"private func logBoundedLargeStoreGateStatus\(mode: String,(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(bounded_gate)
        bounded_gate_body = bounded_gate.group("body")
        assert_contains(self, bounded_gate_body, "let boundedTrend90 = trendSummaryFast(rest: rest, maxHR: profile.maxHR, days: 90)")
        for forbidden in [
            "dailyRollups(",
            "detectedActivities(",
            "trendSummaries(",
            "aggregateSleepCandidates(",
        ]:
            assert_not_contains(self, bounded_gate_body, forbidden)

        for needle in [
            "BGTaskSchedulerPermittedIdentifiers",
            "com.adidshaft.atria.refresh",
            "com.adidshaft.atria.processing",
            "UIBackgroundModes",
            "bluetooth-central",
            "processing",
        ]:
            assert_contains(self, plist, needle)

    def test_feAT3_detail_charts_read_daily_rollup_store_snapshot(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "@Published private(set) var dailyRollupHistory: [DailyRollupStoreEntry] = []",
            "self.dailyRollupHistory = dailyRollupStore.rollups(last: 400)",
            "dailyRollupHistory = dailyRollupStore.rollups(last: 400)",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "dailyRollupHistory: store.dailyRollupHistory",
            "let dailyRollupHistory: [DailyRollupStoreEntry]",
            "AtriaMetricDetailSheet(metric: detail,\n                                   rollups: debugMetricDetailRollups ?? dailyRollupHistory,",
            "private var debugMetricDetailRollups: [DailyRollupStoreEntry]?",
            "init(metric: AtriaMetricDetailKind,\n         rollups: [DailyRollupStoreEntry],",
            "self.preparedHistory = AtriaPreparedMetricHistory(rollups: rollups, baseline: baseline, sleepGoalHours: sleepGoalHours)",
            "init(rollups: [DailyRollupStoreEntry],",
            "item.recovery.map",
            "guard let lnRMSSD = item.lnRMSSD else { return nil }",
            "guard let value = item.rhr else { return nil }",
            "guard let duration = item.sleepSeconds, duration > 0 else { return nil }",
            "item.respiratoryRate.map",
            "item.strain.map",
        ]:
            assert_contains(self, overview, needle)

        assert_contains(self, vitals, "AtriaMetricDetailSheet(metric: detail,\n                                   rollups: store.dailyRollupHistory,")
        for needle in [
            "AtriaHealthMonitorCard(rollups: healthMonitorRollups,",
            "let rollups: [DailyRollupStoreEntry]",
            "private var sortedRollups: [DailyRollupStoreEntry]",
            "sortedRollups.compactMap { $0.rhr.map(Double.init) }.first",
            "sortedRollups.compactMap { $0.lnRMSSD.map(exp) }.first",
            "sortedRollups.compactMap(\\.respiratoryRate).first",
        ]:
            assert_contains(self, vitals, needle)
        for needle in [
            "private var latestRollup: DailyRollupStoreEntry?",
            "latestRollup?.recovery",
            "latestRollup?.lnRMSSD",
            "latestRollup?.sleepSeconds",
        ]:
            assert_contains(self, health, needle)
        prepared_start = overview.index("private struct AtriaPreparedMetricHistory")
        prepared_end = overview.index("private struct AtriaDetailChartPoint", prepared_start)
        prepared_source = overview[prepared_start:prepared_end]
        assert_not_contains(self, overview, "dailyMetricHistory: store.dailyMetricHistory")
        assert_not_contains(self, overview, "let dailyMetricHistory: [SavedDailyMetric]")
        assert_not_contains(self, overview, "debugMetricDetailHistory")
        assert_not_contains(self, overview, "private static func dailyRollupEntries(from history: [SavedDailyMetric])")
        assert_not_contains(self, prepared_source, "history: [SavedDailyMetric]")
        assert_not_contains(self, prepared_source, "item.recoveryPercent")
        assert_not_contains(self, prepared_source, "item.restingHR")
        assert_not_contains(self, prepared_source, "item.sleepDuration")
        health_monitor_start = vitals.index("private struct AtriaHealthMonitorCard")
        health_monitor_end = vitals.index("private struct AtriaHealthMonitorRow", health_monitor_start)
        health_monitor_source = vitals[health_monitor_start:health_monitor_end]
        assert_not_contains(self, health_monitor_source, "SavedDailyMetric")
        assert_not_contains(self, health_monitor_source, "dailyMetrics")
        assert_not_contains(self, health, "latestMetric")
        assert_not_contains(self, health, "dailyMetricHistory")

    def test_non_disruptive_pull_handles_segmented_active_journal(self):
        script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "devicectl_cmd=()",
            "xcrun --find devicectl",
            "command -v devicectl",
            "CoreDevice.framework/Versions/A/Resources/bin/devicectl",
            '"${devicectl_cmd[@]}" device copy from',
            '"${devicectl_cmd[@]}" device info processes',
            "Documents/atria-active-session.segments",
            "Documents/daily-rollups.json",
            "daily_rollups_summary_status=ok",
            "daily_rollups_count=",
            "daily_rollups_newest_day=",
            "daily_rollups_today_rows=",
            "historical-archive.diagnostics.json",
            "historical-archive.manifest.json",
            "historical-archive-segments/",
            '"historical_archive_index" || true',
            '"historical_archive_manifest" || true',
            '"historical_archive_segments" || true',
            "def emit_historical_archive_index_summary():",
            "def emit_historical_archive_rotation_summary():",
            "historical_archive_index_summary_status=ok",
            "historical_archive_index_rows=",
            "historical_archive_index_file_size=",
            "historical_archive_index_metric_usable_rows=",
            "historical_archive_manifest_summary_status=ok",
            "historical_archive_segment_files=",
            "historical_archive_segment_rows=",
            "historical_archive_aggregate_index_rows=",
            "\"recovery\", \"lnRMSSD\", \"rhr\", \"sleepSeconds\", \"sleepPerformance\", \"strain\", \"respiratoryRate\", \"bedtimeMinutes\"",
            "\"rhr\", \"hrv\", \"resp\"",
            "daily_rollups_{key}_count=",
            "daily_rollups_vitals_{key}_count=",
            "active_journal_segments_status=ok",
            "active_journal_storage_mode=segmented_canonical",
            'copy_first_from_container "$evidence_dir/atria-active-session.json" "active_journal_snapshot"',
            "active_journal_file_status=missing_snapshot_segments_may_reconstruct",
            "active_journal_snapshot",
            "def reconstructed_segmented_journal(evidence):",
            "active_journal_reconstructed_from_segments=1",
            "active_journal_final_status=ok",
            "active_journal_final_status=missing",
            "active_journal_continuity_status=",
            "link_connected = (pref(prefs, \"link.lastStatus\", \"\") == \"connected\")",
            "link_auto_save_interpretation = \"active_journal_checkpoint_not_saved_session\"",
            "link_last_auto_save_interpretation=",
            "continuity = \"warming\"",
            "continuity_reason = \"fresh_connected_warming\"",
            "backfill_reason = pref(prefs, \"offlineSync.rangeLossBackfillReason\", \"\") or \"\"",
            "stream_state = pref(prefs, \"strapStream.state\", \"\") or \"\"",
            "backfill_reason == \"strap_low_battery_broadcast_off\"",
            "interruption_class = \"strap_low_battery_broadcast_off\"",
            "interruption_class = \"live_stream_interrupted_saved_sessions_present\"",
            "active_journal_interruption_class={interruption_class}",
            "file_durability_status=saved_sessions_present",
            "file_durability_status=saved_sessions_preserved",
            "live_stream_consistency_status=interrupted_not_file_loss",
            "whoop_primary_data_source=saved_sessions_hr_rr",
        ]:
            assert_contains(self, script, needle)

        assert_not_contains(self, script, "active_journal_final_status=missing\\n' | tee -a \"$summary\"")
        parse_args = script.find("while [[ $# -gt 0 ]]; do")
        validate_device = script.find("Set ATRIA_DEVICE_ID or pass --device")
        self.assertGreaterEqual(parse_args, 0)
        self.assertGreater(validate_device, parse_args)

    def test_launch_path_backup_status_is_deferred_off_session_load(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private func refreshBackupStatusCacheDeferred(reason: String)",
            "Task.detached(priority: .utility)",
            "Self.computeSessionBackupStatus(currentSessions: currentSessions,",
            'AtriaDebugLog("ATRIADBG session_backup_status_deferred status=%@ reason=%@ elapsed_ms=%d sessions=%d"',
            'refreshBackupStatusCacheDeferred(reason: "deferred_session_load")',
        ]:
            assert_contains(self, sessions, needle)

        deferred_load_preparation = re.search(
            r"private struct DeferredLoadPreparation \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(deferred_load_preparation)
        assert_not_contains(self, deferred_load_preparation.group("body"), "backupStatus")

        prepare_start = sessions.index("private nonisolated static func prepareDeferredLoad")
        prepare_end = sessions.index("private nonisolated static func pruningShortLongWearFragments", prepare_start)
        prepare_source = sessions[prepare_start:prepare_end]
        assert_not_contains(self, prepare_source, "computeSessionBackupStatus(currentSessions:")
        assert_not_contains(self, prepare_source, "decodeSessionBackupEnvelope")

    def test_launch_path_archive_diagnostics_uses_sidecar_index_without_promotion(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            'private static let diagnosticsIndexFilename = "historical-archive.diagnostics.json"',
            "private static let maxImmediateDiagnosticsScanBytes = 8 * 1024 * 1024",
            "private struct DiagnosticsIndex: Codable",
            "readDiagnosticsIndex(for: url, attributes: attributes)",
            "writeDiagnosticsIndex(index, for: url)",
            'reason: index.rows > 0 ? "index_ok" : "empty_archive_index"',
            "guard attributes.byteCount <= maxImmediateDiagnosticsScanBytes else",
            "let probe = quickMetricReadinessProbe()",
            'reason: "large_archive_index_missing_probe_\\(probe.reason)"',
            'reason: index.rows > 0 ? "scanned_index_written" : "empty_archive"',
            "updateDiagnosticsIndexAfterAppend(object: object,",
            "decoded.fileSize == previousAttributes.byteCount",
            "object[\"metricUsable\"] as? Bool == true || metricUsable(object: object)",
        ]:
            assert_contains(self, archive, needle)

        diagnostics_start = archive.index("static func diagnostics() -> Diagnostics")
        diagnostics_end = archive.index("static func quickMetricReadinessProbe", diagnostics_start)
        diagnostics_source = archive[diagnostics_start:diagnostics_end]
        assert_not_contains(self, diagnostics_source, "promoteMetricUsableRows")
        self.assertLess(
            diagnostics_source.index("readDiagnosticsIndex(for: url, attributes: attributes)"),
            diagnostics_source.index("scanDiagnosticsIndex(for: url, attributes: attributes)"),
        )
        self.assertLess(
            diagnostics_source.index("guard attributes.byteCount <= maxImmediateDiagnosticsScanBytes else"),
            diagnostics_source.index("scanDiagnosticsIndex(for: url, attributes: attributes)"),
        )

        refresh_start = sessions.index("func refreshHistoricalArchiveStatus(reason: String = \"manual\")")
        refresh_end = sessions.index("private func scheduleHistoricalArchiveStatusRefresh", refresh_start)
        refresh_source = sessions[refresh_start:refresh_end]
        assert_not_contains(self, refresh_source, "promoteMetricUsableRows")

        status_start = sessions.index("struct HistoricalArchiveStatus: Equatable")
        status_end = sessions.index("@Published private(set) var historicalArchiveStatus", status_start)
        status_source = sessions[status_start:status_end]
        for needle in [
            "private var isBoundedArchiveProbe: Bool",
            'reason.hasPrefix("large_archive_index_missing_probe")',
            'if isBoundedArchiveProbe { return "Checking" }',
            'if isBoundedArchiveProbe { return "Archive index is rebuilding safely" }',
            "Atria is checking a large archive without blocking launch.",
            "Atria will rebuild the archive index off the hot path.",
        ]:
            assert_contains(self, status_source, needle)

    def test_launch_path_recent_archive_hr_reader_is_bounded(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")

        for needle in [
            "if let since {\n            return loadRecentHeartRateSamples(since: since, limit: limit ?? 6_000)\n        }",
            "private static func loadRecentHeartRateSamples(since: Date, limit: Int) -> [HeartRatePoint]",
            "let targetBytes = UInt64(max(4_194_304, min(33_554_432, limit * 1_024)))",
            "let startOffset = fileSize > targetBytes ? fileSize - targetBytes : 0",
            "handle.readDataToEndOfFile()",
            "point.t.timeIntervalSince1970 >= lowerBound",
        ]:
            assert_contains(self, archive, needle)

        recent_start = archive.index("private static func loadRecentHeartRateSamples(since: Date, limit: Int)")
        recent_end = archive.index("private static func fastHeartRatePoint", recent_start)
        recent_source = archive[recent_start:recent_end]
        assert_not_contains(self, recent_source, "try String(contentsOf: url")

    def test_launch_path_motion_feature_summary_uses_bounded_gravity_reader(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")

        for needle in [
            "let overlapping = loadRecentGravitySamples(start: start, end: end)",
            "private static func loadRecentGravitySamples(start: Date, end: Date) -> [GravitySample]",
            "let estimatedRows = Int((spanSeconds / 2.0).rounded(.up)) + 720",
            "let targetBytes = UInt64(max(4_194_304, min(33_554_432, estimatedRows * 1_024)))",
            "let startOffset = fileSize > targetBytes ? fileSize - targetBytes : 0",
            "handle.readDataToEndOfFile()",
            "recentReadableFileURLs().reversed()",
            "samples.append(contentsOf: gravitySamples(from: content))",
            "private static func gravitySamples(from content: String) -> [GravitySample]",
        ]:
            assert_contains(self, archive, needle)

        feature_start = archive.index("static func motionFeatureSummary(start: Date, end: Date) -> MotionFeatureSummary?")
        feature_end = archive.index("static func metricHeartRatePoints", feature_start)
        feature_source = archive[feature_start:feature_end]
        assert_not_contains(self, feature_source, "loadGravitySamples()")

        recent_start = archive.index("private static func loadRecentGravitySamples(start: Date, end: Date)")
        recent_end = archive.index("private static func gravitySamples(from content: String)", recent_start)
        recent_source = archive[recent_start:recent_end]
        assert_not_contains(self, recent_source, "try String(contentsOf: url")

    def test_launch_path_sleep_readiness_uses_bounded_motion_policy(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "static func boundedMotionWindowDiagnostics(start: Date, end: Date) -> MotionWindowDiagnostics",
            "motionFeatureSummary(start: start, end: end)",
            'reason: "bounded_recent_no_overlap"',
        ]:
            assert_contains(self, archive, needle)

        for needle in [
            "enum HistoricalSleepMotionPolicy",
            "case fullArchive",
            "case boundedRecent",
            "historicalMotionPolicy: HistoricalSleepMotionPolicy = .fullArchive",
            "HistoricalArchive.boundedMotionWindowDiagnostics(start: start, end: end)",
            "historicalMotionPolicy: .boundedRecent",
        ]:
            assert_contains(self, sessions, needle)

        fast_start = sessions.index("func sleepEvidenceStatusFast(rest: Int,")
        fast_end = sessions.index("if let best = Self.preferredSleepCandidateForReview(from: ready)", fast_start)
        fast_source = sessions[fast_start:fast_end]
        assert_contains(self, fast_source, "historicalMotionPolicy: .boundedRecent")
        assert_not_contains(self, fast_source, "HistoricalArchive.motionWindowDiagnostics")

        auto_start = sessions.index("private func autoConfirmStrongSleepCandidates")
        auto_end = sessions.index("guard !candidates.isEmpty", auto_start)
        auto_source = sessions[auto_start:auto_end]
        assert_contains(self, auto_source, "historicalMotionPolicy: .boundedRecent")

        daily_start = sessions.index("func dailyRollups(rest: Int, maxHR: Int")
        daily_end = sessions.index("let aggregateCandidatesByDay", daily_start)
        daily_source = sessions[daily_start:daily_end]
        assert_contains(self, daily_source, "historicalMotionPolicy: .boundedRecent")

    def test_launch_path_archive_rotation_writes_to_segment_after_threshold(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            'private static let rotationManifestFilename = "historical-archive.manifest.json"',
            "private static let rotationThresholdBytes = 128 * 1024 * 1024",
            'private static let segmentsDirectoryName = "segments"',
            "private struct RotationManifest: Codable",
            "private static func writableFileURL(now: Date = Date()) throws -> URL",
            "guard baseAttributes.byteCount >= rotationThresholdBytes else",
            "let segmentURL = activeSegmentURL(for: now)",
            "try writeRotationManifest(activeSegmentURL: segmentURL, createdAt: now)",
            "private static func recentReadableFileURLs() -> [URL]",
            "private static func activeSegmentReadableURL() -> URL?",
            "private static func rotatedSegmentFileURLs() -> [URL]",
            "private static func aggregateDiagnosticsIndex(base: DiagnosticsIndex,",
            "private static func diagnosticsIndexURL(for url: URL) -> URL?",
            "private static func tailContent(from url: URL, targetBytes: UInt64) -> String?",
            "let url = try writableFileURL()",
            'return diagnostics(from: aggregate, reason: "aggregate_index_ok")',
        ]:
            assert_contains(self, archive, needle)

        for needle in [
            "for url in recentReadableFileURLs()",
            "for url in recentReadableFileURLs().reversed()",
            "guard let content = tailContent(from: url, targetBytes: targetBytes)",
        ]:
            assert_contains(self, archive, needle)

        assert_contains(self, ble, "lastHistoricalArchivePath = result.persistedPath.isEmpty ? HistoricalArchive.relativePath : result.persistedPath")

        for needle in [
            "Documents/atria-historical/historical-archive.manifest.json",
            "Documents/atria-historical/segments",
            "historical_archive_manifest_summary_status=ok",
            "historical_archive_active_segment=",
            "historical_archive_segment_files=",
            "historical_archive_active_segment_rows=",
            "historical_archive_aggregate_index_rows=",
        ]:
            assert_contains(self, script, needle)

        update_start = archive.index("private static func updateDiagnosticsIndexAfterAppend")
        update_end = archive.index("private static func append(object:", update_start)
        update_source = archive[update_start:update_end]
        assert_not_contains(self, update_source, "guard archiveURL == fileURL")
        assert_contains(self, update_source, "previousAttributes.byteCount == 0")
        assert_contains(self, update_source, "diagnosticsIndexURL(for: archiveURL)")

    def test_non_disruptive_pull_reports_sleep_readiness(self):
        script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "def read_confirmed_sleeps_from_preferences():",
            "pref(prefs, \"confirmedSleeps.v1\")",
            "def emit_confirmed_sleep_summary():",
            "confirmed_sleep_records=",
            "confirmed_sleep_naps=",
            "confirmed_sleep_overnights=",
            "confirmed_sleep_stage_records=",
            "latest_confirmed_sleep_kind=",
            "latest_confirmed_sleep_duration_s=",
            "latest_confirmed_sleep_span_s=",
            "latest_confirmed_sleep_stage_total_s=",
            "latest_confirmed_sleep_stage_awake_s=",
            "latest_confirmed_sleep_stage_light_s=",
            "latest_confirmed_sleep_stage_rem_s=",
            "latest_confirmed_sleep_stage_sws_s=",
            "latest_confirmed_sleep_stage_deep_s=",
            "sleep_research_reason_counts=",
            "sleep_like_raw_windows=",
            "nap_like_raw_windows=",
            "pending_sleep_review_status=",
            "pending_sleep_review_status={'pending_user_confirmation' if pending_review else 'already_confirmed_overlap'}",
            "pending_sleep_review_motion_policy=strap_hr_review_without_stage_fabrication",
            "best_nap_like_raw_duration_s=",
        ]:
            assert_contains(self, script, needle)

    def test_unsavable_active_journals_are_cleared_during_recovery(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private func clearUnsavableActiveJournalIfNeeded(reason: String) -> Bool",
            "session.count < 2",
            "status: \"cleared_unsavable\"",
            "action=drop_unsavable_stale_segment",
            "clearUnsavableActiveJournalIfNeeded(reason: \"no_data_watchdog_unsavable\")",
            "clearUnsavableActiveJournalIfNeeded(reason: \"hr_continuity_watchdog_unsavable\")",
            "clearUnsavableActiveJournalIfNeeded(reason: \"accepted_hr_watchdog_unsavable\")",
            "clearUnsavableActiveJournalIfNeeded(reason: \"disconnect_unsavable\")",
            "autoSaveStatus = \"cleared_unsavable\"",
        ]:
            assert_contains(self, text, needle)

    def test_phone_motion_and_steps_are_not_runtime_sources(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")
        healthkit = source(ROOT / "Atria" / "Atria" / "HealthKitExporter.swift")
        info = source(ROOT / "Atria" / "Info.plist")
        pull = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "struct StrapStepSample: Equatable",
            "struct StrapStepSummary: Equatable",
            "static func stepsDaily(_ samples: [StrapStepSample]) -> StrapStepSummary",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "typealias StrapStepSample = AtriaAnalytics.Daily.StrapStepSample",
            "typealias StrapStepSummary = AtriaAnalytics.Daily.StrapStepSummary",
        ]:
            assert_contains(self, metrics, needle)

        for needle in [
            "strap_steps_research=%d step_source=strap_imu_research",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "AtriaGlanceMetricCard(title: \"Strap steps\"",
            "value: sensorSummary.strapStepText",
            "detail: sensorSummary.strapStepCount > 0 ? \"Strap movement\" : \"Not available on this strap\"",
            "Strap movement estimate",
            "Strap steps are not available — this strap's motion stream has never been decodable.",
            "Source: \\(sensorSummary.agreementText).",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "case .steps: return \"Strap steps\"",
            "case .steps: return \"strap\"",
            ".configurationDisplayName(\"Atria Strap Steps\")",
            ".description(\"Strap-derived steps on your Home Screen or Lock Screen.\")",
        ]:
            assert_contains(self, widget, needle)

        assert_contains(self, healthkit, "var readTypes: Set<HKObjectType> = [heartRateType, bloodPressureSystolicType, bloodPressureDiastolicType]")
        assert_contains(self, pull, "whoop_primary_data_source=saved_sessions_hr_rr")
        assert_not_contains(self, sessions, "PhoneMotion")
        assert_not_contains(self, sessions, "phoneMotion")
        assert_not_contains(self, sessions, "phoneStep")
        assert_not_contains(self, ble, "PhoneMotion")
        assert_not_contains(self, ble, "phoneMotion")
        assert_not_contains(self, ble, "phoneStep")
        assert_not_contains(self, analytics, "PhoneMotion")
        assert_not_contains(self, analytics, "phoneMotion")
        assert_not_contains(self, metrics, "PhoneMotion")
        assert_not_contains(self, metrics, "phoneMotion")
        assert_not_contains(self, ble, "import CoreMotion")
        assert_not_contains(self, ble, "CMPedometer")
        assert_not_contains(self, ble, "CMMotionManager")
        assert_not_contains(self, ble, "phone_coremotion")
        assert_not_contains(self, ble, "ignore_phone_pedometer")
        assert_not_contains(self, ble, "phone_steps")
        assert_not_contains(self, ble, "phone_motion")
        assert_not_contains(self, ble, "phoneStepEvidenceSummary")
        assert_not_contains(self, ble, "phoneMotionAuditSummary")
        assert_not_contains(self, home, "phoneStepsToday")
        assert_not_contains(self, home, "phoneDistanceTodayMeters")
        assert_not_contains(self, home, "phoneFloorsToday")
        assert_not_contains(self, home, "phoneMotionDetailText")
        assert_not_contains(self, healthkit, "stepCountType")
        assert_not_contains(self, healthkit, ".stepCount")
        assert_not_contains(self, healthkit, "healthkit_step_read")
        assert_not_contains(self, info, "NSMotionUsageDescription")
        assert_not_contains(self, sessions, "phone motion is primary")
        assert_not_contains(self, sessions, "phone step evidence")
        assert_not_contains(self, sessions, "phone steps")
        assert_not_contains(self, overview, "Steps counted by iPhone motion")
        assert_not_contains(self, overview, "phoneMotionDetailText")
        assert_not_contains(self, overview, "phoneStepsText")
        assert_not_contains(self, overview, "AtriaGlanceMetricCard(title: \"Steps\"")
        assert_not_contains(self, widget, "case .steps: return \"Steps\"")
        assert_not_contains(self, widget, "Today's steps on your Home Screen or Lock Screen.")
        for text in [sessions, ble, home, overview, analytics, metrics, widget, healthkit]:
            assert_not_contains(self, text, '"sparkles"')

    def test_recovery_target_zone_first_slice_is_user_visible(self):
        targets = source(ROOT / "Atria" / "Atria" / "AtriaMetricTargets.swift")
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")

        for needle in [
            "struct AtriaMetricTarget: Equatable, Codable",
            "struct AtriaBaselineTargetSnapshot: Equatable",
            "let hrvLnMean: Double?",
            "let hrvLnSD: Double?",
            "hrvTrusted = baseline.hasTrustedHRVBaseline()",
            "let restingMean: Double?",
            "let restingSD: Double?",
            "restingTrusted = baseline.hasTrustedRestingBaseline()",
            "case higherIsBetter",
            "case researchDefault",
            "case .researchDefault: return \"Early default\"",
            "case .personalBaseline: return \"Personal baseline\"",
            "case .userEdited: return \"User edited\"",
            "case .red: return \"Out of range\"",
            "static let recoveryRecommended",
            "greenLower: 67",
            "yellowLower: 34",
            "let optimalRange: ClosedRange<Double>?",
            "let yellowBuffer: Double?",
            "let redThreshold: Double?",
            "let goal: Double?",
            "optimalRange: 67...100",
            "yellowBuffer: 33",
            "redThreshold: 34",
            "goal: 67",
            "static func zone(for value: Double, target: AtriaMetricTarget) -> AtriaMetricZoneLevel",
            "optimalRange.contains(value)",
            "case .targetBand:",
            "\"\\(source.label) · Green >=",
            "yellow \\(Int(yellowLower.rounded()))-\\(Int(greenLower.rounded()) - 1)%",
            "static func recoveryZone(_ pct: Int?, target: AtriaMetricTarget = .recoveryRecommended) -> AtriaMetricZone?",
            "static func strainZone(strain: Double,",
            "greenBand: Double = 1.5",
            "yellowBand: Double = 3.0",
            "AtriaAnalytics.TargetZones.recovery(pct, target: target)",
            "AtriaAnalytics.TargetZones.strain(strain: strain,",
            "target: target,",
            "greenBand: greenBand,",
            "yellowBand: yellowBand)",
            "static func hrvZone(_ rmssd: Int?,",
            "baselineTrusted: Bool",
            "baselineTarget: AtriaBaselineTargetSnapshot? = nil",
            "greenRatio: Double = 0.95",
            "yellowRatio: Double = 0.85",
            "AtriaAnalytics.TargetZones.hrv(rmssd,",
            "baselineTrusted: baselineTrusted",
            "baselineTarget: baselineTarget",
            "greenRatio: greenRatio,",
            "yellowRatio: yellowRatio)",
            "static func restingHeartRateZone(_ bpm: Int?,",
            "baselineTrusted: Bool",
            "baselineTarget: AtriaBaselineTargetSnapshot? = nil",
            "greenDelta: Int = 3",
            "yellowDelta: Int = 7",
            "AtriaAnalytics.TargetZones.restingHeartRate(bpm,",
            "baselineTrusted: baselineTrusted",
            "baselineTarget: baselineTarget",
            "greenDelta: greenDelta,",
            "yellowDelta: yellowDelta)",
            "static func sleepEfficiencyZone(_ efficiency: Double?,",
            "greenLower: Double = 90",
            "yellowLower: Double = 80",
            "AtriaAnalytics.TargetZones.sleepEfficiency(efficiency,",
            "greenLower: greenLower,",
            "yellowLower: yellowLower)",
            "static func sleepDurationZone(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone?",
            "AtriaAnalytics.TargetZones.sleepDuration(hours, goalHours: goalHours)",
            "static func stepsZone(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone?",
            "AtriaAnalytics.TargetZones.steps(steps, goal: goal)",
            "static func activeCaloriesZone(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone?",
            "AtriaAnalytics.TargetZones.activeCalories(calories, goal: goal)",
            "static func vo2TrendZone(_ summary: VO2MaxEstimateSummary,",
            "greenDelta: Double = 0.2",
            "redDelta: Double = -0.2",
            "AtriaAnalytics.TargetZones.vo2Trend(summary,",
            "redDelta: redDelta)",
            "static func biologicalAgeZone(_ summary: BiologicalAgeSummary,",
            "greenOlderDelta: Int = 0",
            "yellowOlderDelta: Int = 3",
            "AtriaAnalytics.TargetZones.biologicalAge(summary,",
            "greenOlderDelta: greenOlderDelta,",
            "yellowOlderDelta: yellowOlderDelta)",
            "static func respiratoryRateZone(_ breathsPerMinute: Double?,",
            "greenDelta: Double = 1.5",
            "yellowDelta: Double = 3.0",
            "AtriaAnalytics.TargetZones.respiratoryRate(breathsPerMinute,",
            "baselineSamples: baselineSamples,",
            "static func skinTemperatureDeviationZone(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,",
            "greenDelta: Double = 0.5",
            "yellowDelta: Double = 1.0",
            "AtriaAnalytics.TargetZones.skinTemperatureDeviation(summary,",
            "static func bloodOxygenResearchZone(candidateFrames: Int,",
            "goalFrames: Int = 8",
            "AtriaAnalytics.TargetZones.bloodOxygenResearch(candidateFrames: candidateFrames,",
            "exclamationmark.circle",
            "exclamationmark.triangle.fill",
            "General wellness guidance only, not medical advice.",
            "var sourceLabel: String",
            ".components(separatedBy: \"·\")",
            "return head.isEmpty ? \"Target zone\" : head",
            "struct AtriaMetricZoneInfoSheet: View",
            "@Environment(\\.dismiss) private var dismiss",
            "Text(\"Source\")",
            "Text(zone.sourceLabel)",
            "Image(systemName: \"checklist.checked\")",
            ".navigationTitle(\"Metric info\")",
            "ToolbarItem(placement: .topBarTrailing)",
            "Button(\"Done\")",
            "dismiss()",
        ]:
            assert_contains(self, targets, needle)

        wrapper_match = re.search(r"extension Metrics \{(?P<body>.*?)\n\}\n\nstruct AtriaMetricZoneInfoSheet", targets, re.S)
        self.assertIsNotNone(wrapper_match)
        wrapper_body = wrapper_match.group("body")
        for forbidden in [
            "let level: AtriaMetricZoneLevel",
            "let recommendation: String",
            "safeGreen",
            "safeYellow",
            "absDelta",
            "trendDelta",
            "guard summary.isReady",
            "Research sleep-only estimate.",
            "General wellness guidance only, not medical advice.",
            "Below your step goal",
            "Restless night",
            "Trending the wrong way",
            "Green within +/-",
        ]:
            assert_not_contains(self, wrapper_body, forbidden)
        self.assertEqual(wrapper_body.count("AtriaAnalytics.TargetZones."), 13)

        for needle in [
            "enum TargetZones",
            "static func recovery(_ pct: Int?,",
            "target: AtriaMetricTarget = .recoveryRecommended",
            "let level = AtriaMetricZone.zone(for: Double(pct), target: target)",
            "Low recovery -- keep today light, hydrate, and get to bed earlier.",
            "static func strain(strain: Double,",
            "safeGreenBand",
            "safeYellowBand",
            "absDelta <= safeGreenBand",
            "absDelta <= safeYellowBand",
            "Recovery-scaled target · Green within +/-%.1f",
            "Strain is inside today's recovery-scaled target band.",
            "You're past today's suggested strain for your recovery -- ease off to protect tomorrow.",
            "static func hrv(_ rmssd: Int?,",
            "baselineTrusted: Bool",
            "baselineTarget: AtriaBaselineTargetSnapshot? = nil",
            "guard baselineTrusted,\n                  baselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "baselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "baselineTarget.hrvTrusted",
            "let z = zScore(log(Double(rmssd)), mean: mean, sd: sd)",
            "z >= -1.0 ? .green : (z >= -2.0 ? .yellow : .red)",
            "level = worst(ratioLevel, zLevel)",
            "within 1 SD",
            "yellow to 2 SD",
            "ratio >= safeGreen",
            "ratio >= safeYellow",
            "\"Personal baseline · Green >= \\(greenValue) ms",
            "HRV below your norm -- usually stress, short sleep, alcohol, or heavy load.",
            "static func restingHeartRate(_ bpm: Int?,",
            "baselineTarget: AtriaBaselineTargetSnapshot? = nil",
            "guard baselineTrusted,\n                  baselineSamples >= PersonalBaseline.trustedMinimumSamples",
            "baselineTarget.restingTrusted",
            "let z = zScore(Double(bpm), mean: mean, sd: sd)",
            "z <= 1.0 ? .green : (z <= 2.0 ? .yellow : .red)",
            "level = worst(deltaLevel, zLevel)",
            "delta <= safeGreenDelta",
            "delta <= safeYellowDelta",
            "\"Personal baseline · Green <= \\(baseline + safeGreenDelta) bpm",
            "Resting HR is up vs your norm",
            "static func sleepEfficiency(_ efficiency: Double?,",
            "safeGreen",
            "safeYellow",
            "\"Editable target · Green >= \\(Int(safeGreen.rounded()))%",
            "Restless night -- cut late caffeine or alcohol",
            "static func sleepDuration(_ hours: Double?, goalHours: Double = 8.0) -> AtriaMetricZone?",
            "ratio >= 1.0",
            "ratio >= 0.85",
            "\"User goal · Green >= \\(AtriaMetricFormat.sleepHours(safeGoal)),",
            "Under your sleep need -- aim for about",
            "static func steps(_ steps: Int?, goal: Int = 8_000) -> AtriaMetricZone?",
            "guard steps >= safeGoal else { return nil }",
            "\"User goal · Green >= \\(safeGoal) steps.\"",
            "Steps are at or above your daily goal.",
            "static func activeCalories(_ calories: Double?, goal: Int = 500) -> AtriaMetricZone?",
            "\"User goal · Green >= \\(safeGoal) kcal",
            "Estimated from heart rate/profile.",
            "static func vo2Trend(_ summary: VO2MaxEstimateSummary,",
            "let trendDelta = summary.trendDelta",
            "trendDelta >= safeGreenDelta",
            "trendDelta <= safeRedDelta",
            "Estimate trend · Green >= +%.1f",
            "Trending the wrong way -- consistent cardio, Zone 2, intervals, and sleep move this most.",
            "static func biologicalAge(_ summary: BiologicalAgeSummary,",
            "guard summary.isReady, let delta = summary.ageDelta else { return nil }",
            "delta <= safeGreenDelta",
            "delta <= safeYellowDelta",
            "Estimate · Green <= +",
            "static func respiratoryRate(_ breathsPerMinute: Double?,",
            "baselineSamples >= 3",
            "absDelta <= safeGreenDelta",
            "absDelta <= safeYellowDelta",
            "Early baseline · Green within +/-%.1f/min",
            "Early sleep-only signal.",
            "static func skinTemperatureDeviation(_ summary: IMUAuditSummary.SkinTemperatureDeviationSummary,",
            "Early baseline · Green within +/-%.1f delta C",
            "Early relative sleep-only signal; not an absolute temperature.",
            "static func bloodOxygenResearch(candidateFrames: Int,",
            "guard candidateFrames > 0 else { return nil }",
            "Signal evidence · Green >= \\(safeGoal) candidate frames",
            "not an SpO2 reading.",
            "no SpO2 percentage, diagnosis, alarm, or Health export",
        ]:
            assert_contains(self, analytics, needle)
        assert_not_contains(self, analytics, "guard baselineSamples >= 7, let rmssd")
        assert_not_contains(self, analytics, "guard baselineSamples >= 7, let bpm")

        for needle in [
            "var zone: AtriaMetricZone? = nil",
            "var targetMetric: AtriaTodayMetric? = nil",
            "@State private var editingTargetMetric: AtriaTodayMetric?",
            "AtriaMetricTileTargetEditorModifier(targetMetric: targetMetric,",
            "if let targetMetric {",
            "AtriaMetricZoneInfoButton(zone: zone)",
            "AtriaMetricZoneInfoSheet(zone: zone)",
            "onEditTarget: targetMetric.map",
            "AtriaGlanceTargetEditorSheet(metric: metric)",
            "Label(\"Edit target\", systemImage: \"target\")",
            ".accessibilityAction(named: Text(\"Edit target\"))",
            "parts.append(\"Long press to edit target.\")",
            "Text(\"(i)\")",
            ".font(.caption2.weight(.black).monospaced())",
            ".frame(minWidth: 44, minHeight: 44)",
            ".frame(width: 44, height: 44)",
            ".accessibilityLabel(\"Target guidance for \\(zone.title). \\(zone.current)\")",
            "if let zone, zone.showsWarning",
            "parts.append(zone.level.label)",
            "parts.append(zone.targetSummary)",
            "parts.append(\"Tap info for guidance.\")",
            ".accessibilityHint(\"Opens target guidance and general wellness recommendations.\")",
        ]:
            assert_contains(self, shared + overview + vitals, needle)
        assert_contains(self, targets, ".accessibilityHint(\"Opens the target controls for this metric.\")")
        assert_not_contains(self, shared + overview, ".frame(minWidth: 36, minHeight: 28)")
        assert_not_contains(self, overview, ".frame(width: 38, height: 32)")
        for needle in [
            "targetMetric: .bloodOxygen",
            "targetMetric: .bodyTemp",
            "targetMetric: .respiratoryRate",
            "targetMetric: .strapSteps",
            "targetMetric: .rhr",
            "targetMetric: .hrv",
            "targetMetric: .recovery",
            "targetMetric: .strain",
            "targetMetric: .sleep",
            "targetMetric: .sleepEfficiency",
            "targetMetric: .vo2max",
            "targetMetric: .bioAge",
        ]:
            assert_contains(self, vitals, needle)
        for needle in [
            "private var accessibilityText: String",
            "var parts = [calibratingDay.map { \"\\(title) calibrating day \\(min(max($0, 1), 4)) of 4\" } ?? \"\\(title) \\(displayValue)\", detail]",
            "parts.append(zone.level.label)",
            "parts.append(zone.targetSummary)",
            "parts.append(\"Tap info for guidance.\")",
            ".accessibilityLabel(accessibilityText)",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "@AtriaDefault(\"atria.target.recovery.greenLower\")",
            "@AtriaDefault(\"atria.target.recovery.yellowLower\")",
            "@AtriaDefault(\"atria.target.strain.greenBand\")",
            "@AtriaDefault(\"atria.target.strain.yellowBand\")",
            "@AtriaDefault(\"atria.target.load.acwr.watchLow\")",
            "@AtriaDefault(\"atria.target.load.acwr.watchHigh\")",
            "@AtriaDefault(\"atria.target.load.acwr.badLow\")",
            "@AtriaDefault(\"atria.target.load.acwr.badHigh\")",
            "@AtriaDefault(\"atria.target.load.monotony.watch\")",
            "@AtriaDefault(\"atria.target.load.monotony.bad\")",
            "@AtriaDefault(\"atria.target.steps.goal\")",
            "@AtriaDefault(\"atria.target.calories.goal\")",
            "@AtriaDefault(\"atria.target.sleep.goalHours\")",
            "@AtriaDefault(\"atria.target.sleepEfficiency.greenLower\")",
            "@AtriaDefault(\"atria.target.sleepEfficiency.yellowLower\")",
            "@AtriaDefault(\"atria.target.hrv.greenRatio\")",
            "@AtriaDefault(\"atria.target.hrv.yellowRatio\")",
            "@AtriaDefault(\"atria.target.rhr.greenDelta\")",
            "@AtriaDefault(\"atria.target.rhr.yellowDelta\")",
            "@AtriaDefault(\"atria.target.respiratory.greenDelta\")",
            "@AtriaDefault(\"atria.target.respiratory.yellowDelta\")",
            "@AtriaDefault(\"atria.target.skinTemp.greenDelta\")",
            "@AtriaDefault(\"atria.target.skinTemp.yellowDelta\")",
            "@AtriaDefault(\"atria.target.bloodOxygen.candidateFrames\")",
            "@AtriaDefault(\"atria.target.bioAge.greenOlderDelta\")",
            "@AtriaDefault(\"atria.target.bioAge.yellowOlderDelta\")",
            "@AtriaDefault(\"atria.target.vo2.greenDelta\")",
            "@AtriaDefault(\"atria.target.vo2.redDelta\")",
            "recoveryTarget: AtriaMetricTarget.recovery",
            "strainGreenBand: strainGreenBand",
            "strainYellowBand: strainYellowBand",
            "loadACWRWatchLow: loadACWRWatchLow",
            "loadACWRWatchHigh: loadACWRWatchHigh",
            "loadACWRBadLow: loadACWRBadLow",
            "loadACWRBadHigh: loadACWRBadHigh",
            "loadMonotonyWatch: loadMonotonyWatch",
            "loadMonotonyBad: loadMonotonyBad",
            "hrvBaseline: store.baseline.hrvInt",
            "hrvBaselineSamples: store.baseline.freshHRVSampleCount()",
            "hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline()",
            "baselineTarget: AtriaBaselineTargetSnapshot(store.baseline)",
            "hrvGreenRatio: hrvGreenRatio",
            "hrvYellowRatio: hrvYellowRatio",
            "restingBaseline: store.baseline.restingInt",
            "restingBaselineSamples: store.baseline.freshRestingSampleCount()",
            "restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline()",
            "restingGreenDelta: restingGreenDelta",
            "restingYellowDelta: restingYellowDelta",
            "respiratoryGreenDelta: respiratoryGreenDelta",
            "respiratoryYellowDelta: respiratoryYellowDelta",
            "skinTemperatureGreenDelta: skinTemperatureGreenDelta",
            "skinTemperatureYellowDelta: skinTemperatureYellowDelta",
            "bloodOxygenCandidateGoal: bloodOxygenCandidateGoal",
            "biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta",
            "biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta",
            "vo2GreenDelta: vo2GreenDelta",
            "vo2RedDelta: vo2RedDelta",
            "stepsGoal: stepsGoal",
            "caloriesGoal: caloriesGoal",
            "sleepGoalHours: sleepGoalHours",
            "sleepEfficiencyGreenLower: sleepEfficiencyGreenLower",
            "sleepEfficiencyYellowLower: sleepEfficiencyYellowLower",
            "zone: recoveryZone",
            "zone: strainZone",
            "zone: loadReadinessZone",
            "zone: hrvZone",
            "zone: sleepGlanceZone",
            "zone: sleepEfficiencyZone",
            "zone: restingHeartRateZone",
            "zone: stepsZone",
            "zone: activeCaloriesZone",
            "zone: vo2TrendZone",
            "zone: biologicalAgeZone",
            "zone: respiratoryRateZone",
            "zone: skinTemperatureDeviationZone",
            "Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)",
            "Metrics.strainZone(strain: hero.strain,",
            "target: hero.guidance.target",
            "greenBand: strainGreenBand",
            "yellowBand: strainYellowBand",
            "private var loadReadinessZoneLevel: AtriaMetricZoneLevel?",
            "ratio < loadACWRBadLow || ratio >= loadACWRBadHigh",
            "monotony >= loadMonotonyBad",
            "ratio < loadACWRWatchLow || ratio > loadACWRWatchHigh",
            "monotony >= loadMonotonyWatch",
            "Editable target · ACWR green %.1f-%.1f",
            "private func parseDouble(_ value: String) -> Double?",
            "Metrics.hrvZone(parseInt(hero.hrvValue),",
            "baselineTrusted: hrvBaselineTrusted",
            "baselineTarget: baselineTarget",
            "greenRatio: hrvGreenRatio",
            "yellowRatio: hrvYellowRatio",
            "Metrics.restingHeartRateZone(hero.restingHeartRate,",
            "baselineTrusted: restingBaselineTrusted",
            "baselineTarget: baselineTarget",
            "greenDelta: restingGreenDelta",
            "yellowDelta: restingYellowDelta",
            "Metrics.sleepDurationZone(sleepHistory.latest?.durationHours, goalHours: sleepGoalHours)",
            "Metrics.sleepEfficiencyZone(sleepHistory.latest?.sleepEfficiency,",
            "greenLower: sleepEfficiencyGreenLower",
            "yellowLower: sleepEfficiencyYellowLower",
            "Metrics.stepsZone(sensorSummary.strapStepCount, goal: stepsGoal)",
            "Metrics.activeCaloriesZone(live.liveActiveCalories,",
            "goal: caloriesGoal",
            "Metrics.vo2TrendZone(vo2MaxEstimate,",
            "greenDelta: vo2GreenDelta",
            "redDelta: vo2RedDelta",
            "Metrics.biologicalAgeZone(biologicalAgeSummary,",
            "greenOlderDelta: biologicalAgeGreenOlderDelta",
            "yellowOlderDelta: biologicalAgeYellowOlderDelta",
            "Metrics.respiratoryRateZone(sleepHistory.latest?.respiratoryRate,",
            "baseline: sleepHistory.respiratoryBaselineMean",
            "baselineSamples: sleepHistory.respiratoryBaselineCount",
            "greenDelta: respiratoryGreenDelta",
            "yellowDelta: respiratoryYellowDelta",
            "Metrics.skinTemperatureDeviationZone(sensorSummary.skinTemperatureDeviation,",
            "greenDelta: skinTemperatureGreenDelta",
            "yellowDelta: skinTemperatureYellowDelta",
            "Metrics.bloodOxygenResearchZone(candidateFrames: sensorSummary.spo2CandidateFrames,",
            "goalFrames: bloodOxygenCandidateGoal",
            "zone: bloodOxygenResearchZone",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "recoveryTarget: AtriaMetricTarget.recovery",
            "strainGreenBand: strainGreenBand",
            "strainYellowBand: strainYellowBand",
            "AtriaVitalsPulseCardHost(liveStore: liveStore,",
            "homeStatsStore: homeStatsStore,\n                                 store: store,",
            "@ObservedObject var store: SessionStore",
            "@AtriaDefault(\"atria.target.rhr.greenDelta\") private var restingGreenDelta: Int = 3",
            "@AtriaDefault(\"atria.target.rhr.yellowDelta\") private var restingYellowDelta: Int = 7",
            "restingHeartRate: homeStatsStore.state.restingHeartRate",
            "AtriaVitalsHRVCardHost(liveStore: liveStore,",
            "heroStore: heroStore,\n                               store: store)",
            "var hrvSDNN: Double?",
            "var hrvPNN50: Double?",
            "var hrvSDNNText: String",
            "var hrvPNN50Text: String",
            "hrvSDNN: ble.hrvSnapshot?.sdnn",
            "hrvPNN50: ble.hrvSnapshot?.pnn50",
            "@AtriaDefault(\"atria.target.hrv.greenRatio\") private var hrvGreenRatio: Double = 0.95",
            "@AtriaDefault(\"atria.target.hrv.yellowRatio\") private var hrvYellowRatio: Double = 0.85",
            "hrvBaseline: store.baseline.hrvInt",
            "hrvBaselineSamples: store.baseline.freshHRVSampleCount()",
            "hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline()",
            "baselineTarget: AtriaBaselineTargetSnapshot(store.baseline)",
            "hrvGreenRatio: hrvGreenRatio",
            "hrvYellowRatio: hrvYellowRatio",
            "restingBaseline: store.baseline.restingInt",
            "restingBaselineSamples: store.baseline.freshRestingSampleCount()",
            "restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline()",
            "restingGreenDelta: restingGreenDelta",
            "restingYellowDelta: restingYellowDelta",
            "respiratoryGreenDelta: respiratoryGreenDelta",
            "respiratoryYellowDelta: respiratoryYellowDelta",
            "@AtriaDefault(\"atria.target.steps.goal\") private var stepsGoal: Int = 8_000",
            "biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta",
            "biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta",
            "sleepGoalHours: sleepGoalHours",
            "sleepEfficiencyGreenLower: sleepEfficiencyGreenLower",
            "sleepEfficiencyYellowLower: sleepEfficiencyYellowLower",
            "zone: recoveryZone",
            "zone: strainZone",
            "zone: restingHeartRateZone",
            "zone: sleepDurationZone",
            "zone: sleepEfficiencyZone",
            "zone: hrvZone",
            "zone: vo2TrendZone",
            "zone: biologicalAgeZone",
            "zone: respiratoryRateZone",
            "zone: strapStepsZone",
            "zone: skinTemperatureDeviationZone",
            "Metrics.restingHeartRateZone(restingHeartRate,",
            "baselineTrusted: restingBaselineTrusted",
            "baselineTarget: baselineTarget",
            "tint: restingHeartRateZone?.tint ?? .blue",
            "Metrics.hrvZone(Self.parseInt(hero.hrvValue),",
            "baselineTrusted: hrvBaselineTrusted",
            "baselineTarget: baselineTarget",
            "tint: hrvZone?.tint ?? .pink",
            "AtriaMetricTile(label: \"SDNN\"",
            "value: live.hrvSDNNText",
            "unit: live.hrvSDNN == nil ? nil : \"ms\"",
            "Secondary HRV metric from the same steady beat-to-beat window.",
            "AtriaMetricTile(label: \"pNN50\"",
            "value: live.hrvPNN50Text",
            "Share of adjacent beat intervals differing by more than 50 ms.",
            "Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)",
            "Metrics.strainZone(strain: hero.strain,",
            "target: hero.guidance.target",
            "greenBand: strainGreenBand",
            "yellowBand: strainYellowBand",
            "Metrics.restingHeartRateZone(snapshot.latest?.restingHR,",
            "baselineTrusted: restingBaselineTrusted",
            "baselineTarget: baselineTarget",
            "greenDelta: restingGreenDelta",
            "yellowDelta: restingYellowDelta",
            "Metrics.sleepDurationZone(snapshot.latest?.durationHours, goalHours: sleepGoalHours)",
            "Metrics.sleepEfficiencyZone(snapshot.latest?.sleepEfficiency,",
            "Metrics.hrvZone(snapshot.latest?.hrv,",
            "baselineTrusted: hrvBaselineTrusted",
            "baselineTarget: baselineTarget",
            "greenRatio: hrvGreenRatio",
            "yellowRatio: hrvYellowRatio",
            "Metrics.vo2TrendZone(vo2MaxEstimate,",
            "greenDelta: vo2GreenDelta",
            "redDelta: vo2RedDelta",
            "Metrics.biologicalAgeZone(biologicalAgeSummary,",
            "greenOlderDelta: biologicalAgeGreenOlderDelta",
            "yellowOlderDelta: biologicalAgeYellowOlderDelta",
            "Metrics.respiratoryRateZone(snapshot.latest?.respiratoryRate,",
            "baseline: snapshot.respiratoryBaselineMean",
            "baselineSamples: snapshot.respiratoryBaselineCount",
            "greenDelta: respiratoryGreenDelta",
            "yellowDelta: respiratoryYellowDelta",
            "Metrics.stepsZone(summary.strapStepCount > 0 ? summary.strapStepCount : nil,",
            "goal: stepsGoal",
            "title: \"Strap movement goal\"",
            "Strap steps stay labeled as estimates until strap movement calibration is validated.",
            "Strap movement estimate. \\(AtriaMetricZone.nonMedicalDisclaimer)",
            "Metrics.skinTemperatureDeviationZone(summary.skinTemperatureDeviation,",
            "greenDelta: skinTemperatureGreenDelta",
            "yellowDelta: skinTemperatureYellowDelta",
        ]:
            assert_contains(self, vitals + home, needle)

        for path in [overview, vitals]:
            assert_not_contains(self, path, "let baselineValues = sleepHistory.nights.dropFirst().compactMap(\\.respiratoryRate)")
            assert_not_contains(self, path, "let baselineValues = snapshot.nights.dropFirst().compactMap(\\.respiratoryRate)")

        for needle in [
            "targetsSection",
            "Text(\"Targets & zones\")",
            "private func resetAllTargetZones()",
            "resetAllTargetZones()",
            "Label(\"Reset all targets\", systemImage: \"arrow.counterclockwise.circle.fill\")",
            "Stepper(value: $recoveryGreenLower",
            "Stepper(value: $recoveryYellowLower",
            "Stepper(value: $strainGreenBand",
            "Stepper(value: $strainYellowBand",
            "Stepper(value: $loadACWRWatchLow",
            "Stepper(value: $loadACWRWatchHigh",
            "Stepper(value: $loadACWRBadLow",
            "Stepper(value: $loadACWRBadHigh",
            "Stepper(value: $loadMonotonyWatch",
            "Stepper(value: $loadMonotonyBad",
            "Stepper(value: $stepsGoal",
            "Stepper(value: $caloriesGoal",
            "Stepper(value: $sleepGoalHours",
            "Stepper(value: $sleepEfficiencyGreenLower",
            "Stepper(value: $sleepEfficiencyYellowLower",
            "Stepper(value: $hrvGreenRatio",
            "Stepper(value: $hrvYellowRatio",
            "Stepper(value: $restingGreenDelta",
            "Stepper(value: $restingYellowDelta",
            "Stepper(value: $respiratoryGreenDelta",
            "Stepper(value: $respiratoryYellowDelta",
            "Stepper(value: $skinTemperatureGreenDelta",
            "Stepper(value: $skinTemperatureYellowDelta",
            "Stepper(value: $biologicalAgeGreenOlderDelta",
            "Stepper(value: $biologicalAgeYellowOlderDelta",
            "Stepper(value: $vo2GreenDelta",
            "Stepper(value: $vo2RedDelta",
            "Reset to recommended",
            "Reset strain band",
            "Reset training-load target",
            "Reset activity targets",
            "Reset sleep targets",
            "Reset baseline targets",
            "Reset signal targets",
            "Reset fitness-age target",
            "Reset VO2 trend target",
            "recoveryGreenLower = 67",
            "recoveryYellowLower = 34",
            "strainGreenBand = 1.5",
            "strainYellowBand = 3.0",
            "loadACWRWatchLow = 0.80",
            "loadACWRWatchHigh = 1.30",
            "loadACWRBadLow = 0.60",
            "loadACWRBadHigh = 1.50",
            "loadMonotonyWatch = 2.0",
            "loadMonotonyBad = 2.5",
            "caloriesGoal = 500",
            "sleepGoalHours = 8.0",
            "sleepEfficiencyGreenLower = 90",
            "sleepEfficiencyYellowLower = 80",
            "hrvGreenRatio = 0.95",
            "hrvYellowRatio = 0.85",
            "restingGreenDelta = 3",
            "restingYellowDelta = 7",
            "respiratoryGreenDelta = 1.5",
            "respiratoryYellowDelta = 3.0",
            "skinTemperatureGreenDelta = 0.5",
            "skinTemperatureYellowDelta = 1.0",
            "biologicalAgeGreenOlderDelta = 0",
            "biologicalAgeYellowOlderDelta = 3",
            "vo2GreenDelta = 0.2",
            "vo2RedDelta = -0.2",
            "normalizeRecoveryTargets()",
            "normalizeStrainTargets()",
            "normalizeStepsGoal()",
            "normalizeCaloriesGoal()",
            "normalizeSleepGoal()",
            "normalizeSleepEfficiencyTargets()",
            "normalizeHRVTargets()",
            "normalizeRestingTargets()",
            "normalizeRespiratoryTargets()",
            "normalizeSkinTemperatureTargets()",
            "normalizeBiologicalAgeTargets()",
            "normalizeVO2Targets()",
            r"HRV and resting HR zones personalize from your trusted \(PersonalBaseline.trustedMinimumSamples)-sample baseline before warning.",
            "Guidance is general wellness information, not medical advice.",
        ]:
            assert_contains(self, settings, needle)
        self.assertRegex(
            settings,
            r"Reset fitness-age target[\s\S]*?\.atriaCardAction\(tint: \.purple\)[\s\S]*?Divider\(\)[\s\S]*?Stepper\(value: \$vo2GreenDelta",
        )
        assert_not_contains(self, settings, "7-night baseline")

    def test_pure_analytics_calibration_examples_are_monotonic_and_gated(self):
        analytics = source(ROOT / "Atria" / "Atria" / "AtriaAnalytics.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        tests_scheme = source(ROOT / "Atria" / "Atria.xcodeproj" / "xcshareddata" / "xcschemes" / "AtriaTests.xcscheme")
        analytics_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "enum BiologicalAge",
            "trendDeltaYears: Int? = nil",
            "static func estimatedAge(chronologicalAge: Int, factors: [BioAgeFactor]) -> Int",
            "static func vo2AgeEquivalent(_ vo2: Double, sex: AthleteProfile.BiologicalSex) -> Int",
            "static func rhrAgeEquivalent(_ restingHR: Int) -> Int",
            "static func hrvAgeEquivalent(_ rmssd: Int) -> Int",
            "static func sleepAgeEquivalent(durationHours: Double,",
            "consistencyPercent: Int?",
            "static func activityAgeEquivalent(_ chronicLoad: Double,",
            "static func bmiAgeEquivalent(_ bmi: Double,",
            "static func acwrReadinessSignal(ratio: Double?, enoughChronic: Bool) -> String",
            "static func monotonyReadinessSignal(monotony: Double?, enoughAcute: Bool) -> String",
            "static func trainingReadiness(acwrSignal: String,",
            "enum CalibrationExamples",
            "struct Check: Equatable",
            "struct LabelCheck: Equatable",
            "static let strainTRIMP = Check(name: \"banister_strain_score\"",
            "actual: Strain.score(fromTRIMP: 50)",
            "expected: 3.81",
            "static let strainEdwards = Check(name: \"edwards_strain_score\"",
            "actual: Strain.score(fromEdwardsLoad: 120)",
            "static let recoveryHRV = Check(name: \"hrv_recovery_score\"",
            "actual: Double(Recovery.estimate(hrvNow: 70,",
            "static let respiratoryRate = Check(name: \"resp_rate_rsa\"",
            "RespRateRsa.estimate(resampledRR: respiratorySineWave",
            "static let bodyAgeVO2 = Check(name: \"bio_age_vo2_male\"",
            "BiologicalAge.vo2AgeEquivalent(48.5, sex: .male)",
            "static let bodyAgeSummary = Check(name: \"bio_age_summary\"",
            "BiologicalAge.summary(chronologicalAge: 38,",
            "static let recoveryTargetYellow = LabelCheck(name: \"target_recovery_yellow\"",
            "TargetZones.recovery(55)?.level.rawValue ?? \"nil\"",
            "static let hrvTargetGated = LabelCheck(name: \"target_hrv_no_baseline\"",
            "baselineSamples: PersonalBaseline.trustedMinimumSamples - 1",
            "static let staleBaselineGated = LabelCheck(name: \"fresh_baseline_old_samples_gated\"",
            "staleHeavyBaseline.hasTrustedHRVBaseline(now: calibrationNow) ? \"trusted\" : \"gated\"",
            "static let manualDayNap = LabelCheck(name: \"manual_sleep_day_nap\"",
            "ManualSleep.inferredIsNap(start: calibrationDate(hour: 13),",
            "static let manualNightSleep = LabelCheck(name: \"manual_sleep_night_sleep\"",
            "ManualSleep.inferredIsNap(start: calibrationDate(hour: 23),",
            "static let acwrWatch = LabelCheck(name: \"acwr_watch\"",
            "static let monotonyBad = LabelCheck(name: \"monotony_bad\"",
            "static let readinessRundown = LabelCheck(name: \"readiness_rundown\"",
            "private static let calibrationCalendar: Calendar",
            "private static func calibrationDate(hour: Int) -> Date",
            "private static let calibrationNow = calibrationDate(hour: 12)",
            "private static let staleHeavyBaseline = PersonalBaseline(restingHR: 60,",
            "samples: staleBaselineSamples)",
            "PersonalBaseline.staleAfter + 24 * 60 * 60",
            "static var allPassed: Bool",
            "numericChecks.allSatisfy(\\.passed) && labelChecks.allSatisfy(\\.passed)",
        ]:
            assert_contains(self, analytics, needle)

        for needle in [
            "if vo2MaxEstimate.value == nil",
            "baseline.hasTrustedRestingBaseline()",
            "baseline.hasTrustedHRVBaseline()",
            "if sleepNights.count < 3",
            "trainingLoadSummarySnapshot.confidence != \"local\"",
            "guard blockers.isEmpty,",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "--atria-analytics-calibration-audit",
            "logAnalyticsCalibrationAuditIfRequested(arguments: arguments)",
            "private func logAnalyticsCalibrationAuditIfRequested(arguments: [String])",
            "AtriaAnalytics.CalibrationExamples.numericChecks",
            "AtriaAnalytics.CalibrationExamples.labelChecks",
            "ATRIADBG analytics_calibration_check kind=numeric",
            "ATRIADBG analytics_calibration_check kind=label",
            "ATRIADBG analytics_calibration_audit status=%@ numeric_checks=%d label_checks=%d",
            "AtriaAnalytics.CalibrationExamples.allPassed ? \"ok\" : \"failed\"",
        ]:
            assert_contains(self, app, needle)
        assert_contains(self, debug_logging, "--atria-analytics-calibration-audit")
        harness = source(ROOT / "live_device_debug.sh")
        for needle in [
            "--analytics-calibration-audit",
            "analytics_calibration_audit=0",
            "analytics_calibration_audit=1",
            "analytics_calibration_audit_raw",
            "analytics_calibration_audit = analytics_calibration_audit_raw == \"1\"",
            "cmd.append(\"--atria-analytics-calibration-audit\")",
            "\"analytics_calibration_complete\": False",
            "if analytics_calibration_audit and not flags[\"analytics_calibration_complete\"]",
            "ATRIADBG analytics_calibration_audit status=",
            "analytics_calibration_status = tokens.get(\"status\", \"\")",
            "analytics_calibration_numeric_checks = tokens.get(\"numeric_checks\", \"\")",
            "analytics_calibration_label_checks = tokens.get(\"label_checks\", \"\")",
            "flags[\"analytics_calibration_complete\"] = True",
            "emit(f\"analytics_calibration_status={analytics_calibration_status}\")",
            "emit(f\"analytics_calibration_numeric_checks={analytics_calibration_numeric_checks}\")",
            "emit(f\"analytics_calibration_label_checks={analytics_calibration_label_checks}\")",
        ]:
            assert_contains(self, harness, needle)

        for needle in [
            "AtriaTests.xctest",
            "BlueprintName = \"AtriaTests\"",
            "<TestAction",
            "<TestableReference",
            "BuildableName = \"Atria.app\"",
        ]:
            assert_contains(self, tests_scheme, needle)

        for needle in [
            "final class AtriaAnalyticsTests: XCTestCase",
            "func testCalibrationExamplesRemainInRange()",
            "func testBiologicalAgeIsLocalEstimateAndClamped()",
            "func testBiologicalAgeReferenceSourcesAreDocumentedLocally()",
            "func testHRVAnalyzerRequiresContinuousCleanRRWindow()",
            "func testTrainingLoadFlagsUnsafeSpikesAndBalancedLoad()",
            "func testTargetZonesUseHandoffThresholdsAndStayBaselineGated()",
            "func testPureDailyAggregationsHandleStepsCaloriesAndZones()",
            "AtriaAnalytics.Daily.stepsDaily",
            "AtriaAnalytics.Daily.dayCalories",
            "AtriaAnalytics.Strain.maxHeartRateZoneSeconds",
            "AtriaAnalytics.CalibrationExamples.numericChecks",
            "AtriaAnalytics.CalibrationExamples.labelChecks",
        ]:
            assert_contains(self, analytics_tests, needle)

        def interpolated_age(value, reference, higher_is_younger):
            if higher_is_younger:
                if value >= reference[0][1]:
                    return 18
                if value <= reference[-1][1]:
                    return 90
            else:
                if value <= reference[0][1]:
                    return 18
                if value >= reference[-1][1]:
                    return 90
            for index in range(1, len(reference)):
                previous_age, previous_value = reference[index - 1]
                next_age, next_value = reference[index]
                inside = previous_value >= value >= next_value if higher_is_younger else previous_value <= value <= next_value
                if inside:
                    numerator = previous_value - value if higher_is_younger else value - previous_value
                    fraction = numerator / max(abs(previous_value - next_value), 0.01)
                    return min(max(round(previous_age + fraction * (next_age - previous_age)), 18), 90)
            return 90

        def vo2_age(vo2, sex):
            reference = (
                [(20, 44.0), (30, 41.0), (40, 38.0), (50, 35.0), (60, 32.0), (70, 29.0), (80, 26.0), (90, 23.0)]
                if sex == "female"
                else [(20, 52.0), (30, 48.5), (40, 45.0), (50, 41.5), (60, 38.0), (70, 34.5), (80, 31.0), (90, 27.5)]
            )
            return interpolated_age(vo2, reference, True)

        def rhr_age(resting_hr):
            return interpolated_age(resting_hr, [(20, 58), (30, 60), (40, 62), (50, 64), (60, 66), (70, 68), (80, 70), (90, 72)], False)

        def hrv_age(rmssd):
            return interpolated_age(rmssd, [(20, 70), (30, 58), (40, 46), (50, 36), (60, 28), (70, 22), (80, 18), (90, 14)], True)

        def sleep_age(duration_hours, efficiency, chronological_age, consistency_percent=None):
            duration_penalty = abs(duration_hours - 7.5) * 2.0
            efficiency_penalty = max(0, 0.85 - efficiency) * 35
            consistency_penalty = max(0, 80 - consistency_percent) / 8.0 if consistency_percent is not None else 0
            bonus = -4.0 if duration_penalty < 1.0 and efficiency >= 0.88 and (consistency_percent or 80) >= 85 else 0
            return min(max(round(chronological_age + duration_penalty + efficiency_penalty + consistency_penalty + bonus), 18), 90)

        def activity_age(chronic_load, chronological_age):
            delta = min(max((chronic_load - 25) / 3.0, -8), 8)
            return min(max(round(chronological_age - delta), 18), 90)

        def bmi_age(bmi, chronological_age):
            penalty = (18.5 - bmi) * 1.2 if bmi < 18.5 else max(0, bmi - 24.9) * 0.8
            return min(max(round(chronological_age + penalty), 18), 90)

        def biological_age(chronological_age, weighted_factors):
            weighted = sum(age * weight for age, weight in weighted_factors)
            total_weight = sum(weight for _, weight in weighted_factors)
            unclamped = round(weighted / max(total_weight, 0.01))
            return min(max(unclamped, chronological_age - 20), chronological_age + 20)

        self.assertLess(vo2_age(56, "male"), vo2_age(40, "male"))
        self.assertLess(vo2_age(48, "female"), vo2_age(34, "female"))
        self.assertLess(hrv_age(80), hrv_age(30))
        self.assertLess(rhr_age(52), rhr_age(75))
        self.assertLess(sleep_age(7.6, 0.91, 38, 92), sleep_age(5.5, 0.78, 38, 55))
        self.assertLess(activity_age(40, 38), activity_age(8, 38))
        self.assertLess(bmi_age(22.0, 38), bmi_age(32.0, 38))

        strong_factors = [
            (vo2_age(55, "male"), 0.30),
            (rhr_age(55), 0.20),
            (hrv_age(70), 0.20),
            (sleep_age(7.5, 0.90, 38, 92), 0.15),
            (activity_age(36, 38), 0.10),
            (bmi_age(22.0, 38), 0.05),
        ]
        weak_factors = [
            (vo2_age(28, "male"), 0.30),
            (rhr_age(82), 0.20),
            (hrv_age(16), 0.20),
            (sleep_age(5.2, 0.74, 38, 50), 0.15),
            (activity_age(3, 38), 0.10),
            (bmi_age(35.0, 38), 0.05),
        ]
        self.assertLess(biological_age(38, strong_factors), 38)
        self.assertEqual(biological_age(38, weak_factors), 58)

        def acwr_signal(ratio, enough_chronic):
            if not enough_chronic or ratio is None:
                return "learning"
            if ratio >= 1.50 or ratio < 0.60:
                return "bad"
            if ratio > 1.30 or ratio < 0.80:
                return "watch"
            return "good"

        def monotony_signal(monotony, enough_acute):
            if not enough_acute or monotony is None:
                return "learning"
            if monotony >= 2.50:
                return "bad"
            if monotony >= 2.00:
                return "watch"
            return "good"

        def training_readiness(acwr, monotony, ratio):
            if acwr == "learning" and monotony == "learning":
                return "learning"
            if acwr == "bad" or monotony == "bad":
                return "rundown"
            if acwr == "watch" or monotony == "watch":
                return "strained"
            if ratio is not None and ratio < 0.80:
                return "primed"
            return "balanced"

        def inferred_manual_sleep_is_nap(duration_seconds, start_hour, end_hour, current_selection=False):
            if duration_seconds <= 0:
                return current_selection
            if duration_seconds >= 3 * 60 * 60:
                return False
            if duration_seconds < 20 * 60:
                return current_selection
            daytime_window = start_hour >= 11 and end_hour <= 20
            return daytime_window or duration_seconds < 3 * 60 * 60

        def edwards_weight(reserve):
            if reserve >= 0.90:
                return 5
            if reserve >= 0.80:
                return 4
            if reserve >= 0.70:
                return 3
            if reserve >= 0.60:
                return 2
            if reserve >= 0.50:
                return 1
            return 0

        def edwards_load(series, rest, max_hr):
            total = 0
            span = max_hr - rest
            for previous, current in zip(series, series[1:]):
                dt_min = (current[0] - previous[0]) / 60
                reserve = min(max((current[1] - rest) / span, 0), 1)
                total += dt_min * edwards_weight(reserve)
            return total

        def max_hr_zone_raw_value(bpm, max_hr):
            fraction = bpm / max_hr
            if fraction >= 0.90:
                return 5
            if fraction >= 0.80:
                return 4
            if fraction >= 0.70:
                return 3
            if fraction >= 0.60:
                return 2
            if fraction >= 0.50:
                return 1
            return 0

        def max_hr_zone_seconds(series, max_hr, max_gap=5 * 60):
            buckets = [0, 0, 0, 0, 0, 0]
            dropped = 0
            for previous, current in zip(series, series[1:]):
                dt = current[0] - previous[0]
                if dt <= 0:
                    continue
                if dt >= max_gap:
                    dropped += dt
                    continue
                buckets[max_hr_zone_raw_value(current[1], max_hr)] += dt
            return buckets, dropped

        def steps_daily(samples):
            steps = 0
            distance = 0
            floors_up = 0
            floors_down = 0
            has_distance = False
            has_up = False
            has_down = False
            for sample in samples:
                steps += max(0, sample.get("steps", 0))
                meters = sample.get("distance")
                if meters is not None and meters > 0:
                    distance += meters
                    has_distance = True
                up = sample.get("up")
                if up is not None and up > 0:
                    floors_up += up
                    has_up = True
                down = sample.get("down")
                if down is not None and down > 0:
                    floors_down += down
                    has_down = True
            return {
                "steps": steps,
                "distance": distance if has_distance else None,
                "up": floors_up if has_up else None,
                "down": floors_down if has_down else None,
            }

        def day_calories(samples, rest, sex, age, weight):
            def kcal_per_min(hr):
                if sex == "male":
                    return max(0, (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * age) / 4.184)
                if sex == "female":
                    return max(0, (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.0740 * age) / 4.184)
                return 0

            resting = kcal_per_min(rest)
            total = 0
            for previous, current in zip(samples, samples[1:]):
                dt_min = (current[0] - previous[0]) / 60
                if dt_min <= 0 or dt_min >= 5 or current[1] <= 0:
                    continue
                total += max(0, kcal_per_min(current[1]) - resting) * dt_min
            return total

        def resp_rate_rsa(resampled, sample_rate=4.0):
            mean = sum(resampled) / len(resampled)
            centered = [value - mean for value in resampled]
            best_rate = 0
            best_power = 0
            band_power = 0
            for step in range(12, 61):
                bpm = step / 2
                frequency = bpm / 60
                real = 0
                imaginary = 0
                for index, value in enumerate(centered):
                    angle = 2 * math.pi * frequency * index / sample_rate
                    real += value * math.cos(angle)
                    imaginary -= value * math.sin(angle)
                power = real * real + imaginary * imaginary
                band_power += power
                if power > best_power:
                    best_power = power
                    best_rate = bpm
            if best_power <= 0 or best_power / max(band_power, best_power) < 0.18:
                return None
            return best_rate

        self.assertEqual(acwr_signal(None, False), "learning")
        self.assertEqual(acwr_signal(1.55, True), "bad")
        self.assertEqual(acwr_signal(1.31, True), "watch")
        self.assertEqual(acwr_signal(1.00, True), "good")
        self.assertEqual(monotony_signal(2.6, True), "bad")
        self.assertEqual(monotony_signal(2.1, True), "watch")
        self.assertEqual(monotony_signal(1.4, True), "good")
        self.assertEqual(training_readiness("bad", "good", 1.6), "rundown")
        self.assertEqual(training_readiness("watch", "good", 1.35), "strained")
        self.assertEqual(training_readiness("good", "good", 0.75), "primed")
        self.assertEqual(training_readiness("good", "good", 1.0), "balanced")
        self.assertEqual("yellow" if 34 <= 55 < 67 else "other", "yellow")
        self.assertEqual("gated", "gated")
        self.assertTrue(inferred_manual_sleep_is_nap(45 * 60, 14, 15))
        self.assertFalse(inferred_manual_sleep_is_nap(8 * 60 * 60, 23, 7))
        self.assertTrue(inferred_manual_sleep_is_nap(-60, 14, 15, current_selection=True))
        self.assertEqual([edwards_weight(x) for x in [0.49, 0.50, 0.61, 0.72, 0.83, 0.94]], [0, 1, 2, 3, 4, 5])
        self.assertEqual(edwards_load([(0, 100), (60, 130), (120, 150), (180, 170)], 60, 180), 9)
        self.assertEqual([max_hr_zone_raw_value(bpm, 200) for bpm in [80, 100, 120, 140, 160, 180]], [0, 1, 2, 3, 4, 5])
        self.assertEqual(max_hr_zone_seconds([(0, 90), (60, 110), (120, 130), (180, 150), (240, 170), (300, 190), (900, 190)], 200),
                         ([0, 60, 60, 60, 60, 60], 600))
        self.assertEqual(steps_daily([
            {"steps": 120, "distance": 80, "up": 1, "down": 0},
            {"steps": -20, "distance": None, "up": None, "down": 2},
            {"steps": 380, "distance": 220, "up": 3, "down": -1},
        ]), {"steps": 500, "distance": 300, "up": 4, "down": 2})
        self.assertGreater(day_calories([(0, 60), (60, 130), (120, 150)], 60, "male", 35, 75), 4.0)
        self.assertEqual(day_calories([(0, 60), (600, 150)], 60, "male", 35, 75), 0)
        synthetic_rr = [800 + 45 * math.sin(2 * math.pi * (15 / 60) * index / 4) for index in range(4 * 90)]
        self.assertEqual(resp_rate_rsa(synthetic_rr), 15)

    def test_standard_rr_batches_archive_before_hrv_contact_gate(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        match = re.search(r"private func addRRBatch\(.*?\n    \}", ble, re.S)
        self.assertIsNotNone(match, "addRRBatch helper missing")
        body = match.group(0)

        for needle in [
            "let hasStableContact = stableSeconds >= 10",
            "let shouldOpenGate = hasStableContact && !hrvGateWasOpen",
            "rrArchive.append(contentsOf: appendPayload.intervals)",
            "if hrvGateWasOpen && !shouldOpenGate",
            "if hasStableContact && !shouldOpenGate",
        ]:
            assert_contains(self, body, needle)

        archive_index = body.index("rrArchive.append(contentsOf: appendPayload.intervals)")
        early_contact_gate = "guard stableSeconds >= 10"
        self.assertNotIn(early_contact_gate, body[:archive_index],
                         "standard 2A37 RR must be archived before HRV contact gating")

    def test_confirmed_sleep_stage_compatibility_for_older_records(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        assert_contains(self, sessions, "let migrated = sorted.map(Self.migratingConfirmedSleepStagesIfNeeded)")
        assert_contains(self, sessions, "UserDefaults.standard.set(data, forKey: ConfirmedSleepDefaults.key)")
        assert_contains(self, sessions, "sleep_confirmed_migration")
        assert_contains(self, sessions, "if Self.shouldPreserveConfirmedSleepStageSegments(sleep)")
        assert_contains(self, sessions, "return Self.copyConfirmedSleep(sleep, stageSegments: nil)")
        assert_contains(self, sessions, "private static func shouldPreserveConfirmedSleepStageSegments(_ sleep: UserConfirmedSleep) -> Bool")
        assert_contains(self, sessions, 'if sleep.source == "manual_sleep" || sleep.source == "manual_nap" { return false }')
        assert_contains(self, sessions, 'sleep.confidence.localizedCaseInsensitiveContains("hr_only")')
        assert_contains(self, sessions, 'if sleep.motionValidated || sleep.source == "validated_sleep_stages" { return true }')
        assert_contains(self, sessions, "return covered >= max(60, sleep.duration * 0.85)")
        assert_contains(self, sessions, "private static func copyConfirmedSleep(_ sleep: UserConfirmedSleep,")
        assert_contains(self, sessions, "UserConfirmedSleep(id: sleep.id,")
        assert_contains(self, sessions, "stageSegments: stageSegments")
        assert_contains(self, sessions, "return Self.copyConfirmedSleep(sleep, stageSegments: migratedStages)")
        assert_contains(self, sessions, "Self.legacyConfirmedSleepStageCompatibility(start: sleep.start,")
        assert_contains(self, sessions, 'source: sleep.source)')
        assert_contains(self, sessions, '"aggregate_sleep"')
        assert_contains(self, sessions, '"sleep_window"')
        assert_contains(self, sessions, "private static func estimatedConfirmedSleepStages")
        assert_contains(self, sessions, "private static func legacyConfirmedSleepStageCompatibility")
        assert_contains(self, sessions, "if Night.explicitNapSources.contains(source) || Night.explicitSleepSources.contains(source)")
        assert_contains(self, sessions, "return []")
        assert_contains(self, sessions, "(.awake, 0.08), (.light, 0.47), (.rem, 0.17), (.sws, 0.16), (.deep, 0.12)")
        assert_contains(self, sessions, "(.awake, 0.06), (.light, 0.68), (.rem, 0.08), (.sws, 0.12), (.deep, 0.06)")

    def test_vis2_metric_formatters_are_shared_by_glance_and_detail(self):
        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        trend = source(ROOT / "Atria" / "Atria" / "AtriaTrendChart.swift")

        for needle in [
            "enum AtriaMetricFormat",
            "static func hrv(_ value: Double?) -> String",
            "static func restingHeartRate(_ value: Double?) -> String",
            "static func strain(_ value: Double?) -> String",
            "static func recovery(_ value: Double?) -> String",
            "static func sleepDuration(seconds: TimeInterval?) -> String",
            "static func sleepHours(_ hours: Double?) -> String",
            "Text(estimate.percent.map { AtriaMetricFormat.recovery(Double($0)) } ?? \"Learning\")",
            "Text(AtriaMetricFormat.strain(strain))",
            ".font(.subheadline.monospacedDigit())",
            ".frame(maxWidth: .infinity, alignment: .trailing)",
        ]:
            assert_contains(self, shared, needle)

        for needle in [
            "AtriaMetricFormat.value(value, metric: metricUnit(for: unit))",
            "AtriaMetricFormat.range(low: low, high: high, metric: metricUnit(for: unit))",
            "AtriaMetricFormat.change(value, metric: metricUnit(for: unit))",
            'case "h": return .sleep',
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "case .hrv: return AtriaMetricFormat.hrv(current)",
            "case .restingHR: return AtriaMetricFormat.restingHeartRate(current)",
            "case .strain: return AtriaMetricFormat.strain(current)",
            "case .strain: return AtriaMetricFormat.range(low: low, high: high, metric: .strain)",
            "case .hrv: return AtriaMetricFormat.change(value, metric: .hrv)",
        ]:
            assert_contains(self, trend, needle)


    def test_duty_cycle_and_archive_compactor_are_wired_and_pulled(self):
        ble_manager = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        pull_script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            "enum DutyCycleState",
            "case sparseSentinel",
            "sparse_expected_silence",
            "duty_cycle state=",
        ]:
            assert_contains(self, ble_manager, needle)

        for needle in [
            "static func compactArchive",
            "aborted_green_invariant",
        ]:
            assert_contains(self, archive, needle)

        append_start = archive.index("private static func appendJSONLine<T: Encodable>(_ value: T) throws -> URL {")
        append_end = archive.index("\n    }\n", append_start)
        append_source = archive[append_start:append_end]
        assert_contains(self, append_source, "promotionLock.lock()")

        for needle in [
            "def emit_duty_cycle_and_compaction_preferences():",
            "duty_cycle_enabled=",
            "duty_cycle_sleep_window_start_min=",
            "duty_cycle_sleep_window_end_min=",
            "archive_compaction_last_run_at=",
        ]:
            assert_contains(self, pull_script, needle)


if __name__ == "__main__":
    unittest.main()
