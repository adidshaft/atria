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
            "static let minimumSustainedSamples = 8 * 60",
            "static let minimumBPMOverRest = 25",
            "static let zoneLookbackSeconds: TimeInterval = 6 * 60",
            "static let zoneMinimumSamples = 4 * 60",
            "static let minimumContinuousElevatedSamples = 90",
            "static let recentConfirmationSamples = 30",
            "static let maximumPacketGap: TimeInterval = SavedSession.workoutContinuityGapLimit",
            "static let maximumSampleAge: TimeInterval = 5",
            "static let zoneMinimumIndex = 3",
            "static let cooldown: TimeInterval = 45 * 60",
            # 2026-07-09: decoupled the sustained window (480s) from the required
            # elevated-sample count (was 480 = ~100% of samples, unreachable with
            # real BLE dropout -> "no detection"); count is now minimumSustainedElevatedSamples.
            "&& elevatedSeconds >= minimumSustainedElevatedSamples",
            "&& longestElevatedSeconds >= minimumSustainedElevatedSamples",
            "&& recentElevatedSeconds >= recentConfirmationSamples",
            "&& zoneSeconds >= zoneMinimumSamples",
            "&& longestZoneSeconds >= zoneMinimumSamples",
            "&& recentZoneSeconds >= recentConfirmationSamples",
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
        perf_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")

        for needle in [
            "AtriaOverviewGuidanceSectionHost(heroStore: heroStore,",
            "private var sleepDebtValueText: String",
            # 2026-07-12: overnight graphs must never let a confirmed nap
            # replace the main sleep record.
            "if let latest = sleepHistory.latestMainSleep, !latest.confirmed",
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
            "private struct AtriaStrainScoreHero: View",
            "AtriaStrainTargetPresentation.progress(for: score)",
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
            "@StateObject private var projectionStore: AtriaSleepSyncProjectionStore",
            "guard !projectionStore.state.hasLatestSleep else { return false }",
            "guard projectionStore.state.candidateCount == 0 else { return false }",
            "return !projectionStore.state.hasPendingReview",
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
            'Text(protectsLiveStream ? "Sleep tracking continues" : "Sleep data gap")',
            "Live data continues; missing time stays excluded.",
            "Check the strap for recoverable history.",
            'title: protectsLiveStream ? "Live" : "History"',
            'value: protectsLiveStream ? "On" : "Check"',
            'title: "Gap"',
            'value: "Excluded"',
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
            'return isNap ? "Possible nap" : "Possible sleep"',
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
            # 2026-07-07: domain also covers the dashed prior-average rule
            # added by the design-handoff chart-language pass.
            # 2026-07-07 (loop 3): domain also covers the dashed
            # prior-period ghost series.
            ".chartYScale(domain: prepared.domain)",
            # 2026-07-07: signature gained the optional comparison param (same
            # chart-language pass as the .chartYScale pin above).
            "struct AtriaMetricChartPreparedData",
            "AtriaTrendChartScale.domain(low: low, high: $0)",
            "private let pointTimes: [TimeInterval]",
            "while lower < upper",
            "private let companionIndicesByDay: [[Date: Int]]",
            "let match = prepared.companionPointIndex(at: index, on: selectedPoint.day)",
            "private struct AtriaMetricContributorRow: Identifiable, Equatable",
            "var id: String { \"\\(systemImage)|\\(name)\" }",
        ]:
            assert_contains(self, overview, needle)

        metric_chart_start = overview.index("private func metricChart(title: String,")
        metric_chart_end = overview.index("private struct AtriaPreparedMetricChart", metric_chart_start)
        metric_chart_source = overview[metric_chart_start:metric_chart_end]
        assert_not_contains(self, metric_chart_source, "@State private var scrubbedDay")
        assert_not_contains(self, metric_chart_source, "points.min(by:")
        assert_not_contains(self, metric_chart_source, "Calendar.current.isDate($0.day, inSameDayAs: target)")
        chart_domain_start = overview.index("struct AtriaMetricChartPreparedData")
        chart_domain_end = overview.index("private struct AtriaPreparedMetricChart", chart_domain_start)
        chart_domain_source = overview[chart_domain_start:chart_domain_end]
        assert_not_contains(self, chart_domain_source, "points.map(\\.value)")
        assert_not_contains(self, chart_domain_source, "priorPointsForDomain.map(\\.value)")
        assert_not_contains(self, chart_domain_source, "points.compactMap(\\.bandLower)")
        contributor_row_start = overview.index("private struct AtriaMetricContributorRow")
        contributor_row_end = overview.index("private struct AtriaMetricContributorRows", contributor_row_start)
        assert_not_contains(self, overview[contributor_row_start:contributor_row_end], "UUID()")

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
        guidance_start = overview.index("struct AtriaOverviewGuidanceSectionHost: View")
        guidance_end = overview.index("private struct AtriaDayPlanLane", guidance_start)
        guidance_source = overview[guidance_start:guidance_end]
        for needle in [
            "@StateObject private var projectionStore: AtriaOverviewGuidanceProjectionStore",
            "let projection = projectionStore.state",
            "sleepHistoryRevision: projection.sleepHistoryRevision",
            "dailyRollupHistoryRevision: projection.dailyRollupHistoryRevision",
            "weeklyPlan: projection.weeklyPlan",
            "final class AtriaOverviewGuidanceProjectionStore: ObservableObject",
            "store.$sleepHistorySnapshot",
            "store.$dailyRollupHistory",
            "let sleepHistoryRevision: Int",
            "let dailyRollupHistoryRevision: Int",
            "&& lhs.sleepHistoryRevision == rhs.sleepHistoryRevision",
            "&& lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision",
            "let weeklyPlan: WeeklyPlan",
            "&& lhs.weeklyPlan == rhs.weeklyPlan",
        ]:
            assert_contains(self, overview, needle)
        for forbidden in [
            "lhs.sleepHistory == rhs.sleepHistory",
            "lhs.dailyRollupHistory == rhs.dailyRollupHistory",
            "private final class AtriaOverviewWeeklyPlanMemo",
            "WeeklyPlanStore().currentPlan(rollups: rollups, now: now, calendar: calendar)",
        ]:
            assert_not_contains(self, guidance_source, forbidden)
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
        assert_not_contains(self, guidance_source, "WeeklyPlanStore().currentPlan")
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
            # 2026-07-07 dedup audit: the dock (a second control bound to
            # the same $range as the segmented picker) is unmounted; its
            # struct remains.
            "if periodReadout.hasEnoughSignal",
            "AtriaTrendPeriodBalanceMap(readout: periodReadout)",
            "AtriaTrendGlanceBoard(readout: periodReadout)",
            "AtriaTrendRangeReportCard(readout: periodReadout)",
            "private struct AtriaTrendGlanceBoard: View, Equatable",
            # 2026-07-07 dedup audit: the Recovery/Strain glance lanes were
            # the third rendering of the reserve/load pair — the balance map
            # owns it now; the board keeps its per-metric delta gauges.
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
            # 2026-07-07 dedup audit: the dock (a second control bound to
            # the same $range as the segmented picker) is unmounted; its
            # struct remains.
            "private struct AtriaTrendRangeDock: View",
            "@Binding var selectedRange: AtriaTrendRange",
            "ForEach(AtriaTrendRange.allCases) { range in",
            "withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard))",
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
            # 2026-07-07 dedup audit: Range pill removed (position band
            # states low/high with position context).
            "summaryPill(label: \"Avg\", value: summary.averageText)",
            "summaryPill(label: \"Prior\", value: priorAverageText)",
            "AtriaTrendRangePositionBand(series: prepared.series,",
            "private struct AtriaTrendRangePositionBand: View, Equatable",
            "private struct RangeStats",
            "private static func rangeStats(for series: [AtriaTrendPoint.Sample]) -> RangeStats",
            "let stats = Self.rangeStats(for: series)",
            "let positionText = positionText(for: stats.latestPosition)",
            "Text(\"Current position\")",
            "return metric.lowPositionText",
            "return \"middle of range\"",
            "return metric.highPositionText",
            "bandLabel(\"Low\", value: stats.low)",
            "bandLabel(\"Now\", value: stats.latest)",
            "bandLabel(\"High\", value: stats.high)",
            "var lowPositionText: String",
            "var highPositionText: String",
            "func rangeText(low: Double, high: Double) -> String",
            "enum AtriaTrendChartScale",
            "static func domain(values: [Double], paddingRatio: Double = 0.16) -> ClosedRange<Double>",
            "static func domain(low: Double, high: Double, paddingRatio: Double = 0.16) -> ClosedRange<Double>",
            ".chartYScale(domain: prepared.yDomain)",
        ]:
            assert_contains(self, trend_chart, needle)
        assert_not_contains(self, trend_chart, "private var rangedPoints")
        assert_not_contains(self, trend_chart, "private var series")
        assert_not_contains(self, trend_chart, "Menu {")
        assert_not_contains(self, trend_chart, 'return "sparkles"')
        range_band_start = trend_chart.index("private struct AtriaTrendRangePositionBand")
        range_band_end = trend_chart.index("private struct AtriaTrendSessionDotStrip", range_band_start)
        range_band_source = trend_chart[range_band_start:range_band_end]
        for forbidden in [
            "private var values",
            "private var low",
            "private var high",
            "private var latest",
            "private var latestPosition",
        ]:
            assert_not_contains(self, range_band_source, forbidden)

        for needle in [
            "@Published private(set) var dailyMetricHistory: [SavedDailyMetric] = []",
            "@Published private(set) var dailyMetricSparklines = DailyMetricSparklineCache.empty",
            "let skinTemperatureDeviationCelsius: Double?",
            "nonisolated static func finalizedSkinTemperatureDeviationByMorningDay(sessions: [SavedSession],",
            "var baselineMeanSum = 0.0",
            "var baselineDayCount = 0",
            "if baselineDayCount >= 3",
            "baselineMeanSum += dayMean.meanCelsius",
            "nonisolated static func morningSkinTemperatureDeviation(",
            "skinTemperatureDeviationByDay: [Date: Double]? = nil",
            "let skinTemperatureDeviationByDay = finalizedSkinTemperatureDeviationByMorningDay(sessions: history.sessions,",
            "resolvedSkinTemperatureDeviationByDay",
            "nonisolated static func makeSavedDailyMetrics(",
            "private nonisolated static func makeDailyMetricSparklines(from history: [SavedDailyMetric]) -> DailyMetricSparklineCache",
            # 2026-07-05: mergeDailyMetricHistory and makeMorningFrozenDailyMetric
            # dropped `private` (now plain `nonisolated static func`) so the
            # HR-only-sleep + today-rollup-from-wear unit tests can call them
            # directly, matching the existing partitionSessionsForPersist
            # pure-static-testing pattern.
            "nonisolated static func mergeDailyMetricHistory(",
            "nonisolated static func makeMorningFrozenDailyMetric(",
            "private nonisolated static func morningMetricDay(for night: SleepHistorySnapshot.Night,",
            "nonisolated static func morningMetricDay(for session: SavedSession,",
            "merged.removeValue(forKey: today)",
        ]:
            assert_contains(self, sessions, needle)
        skin_temp_start = sessions.index("nonisolated static func finalizedSkinTemperatureDeviationByMorningDay")
        skin_temp_end = sessions.index("nonisolated static func makeSavedDailyMetrics", skin_temp_start)
        skin_temp_source = sessions[skin_temp_start:skin_temp_end]
        assert_not_contains(self, skin_temp_source, "dayMeans[..<index]")
        assert_not_contains(self, skin_temp_source, "baseline.reduce")
        morning_freeze_start = sessions.index("nonisolated static func makeMorningFrozenDailyMetric(")
        morning_freeze_end = sessions.index("private nonisolated static func morningMetricDay(for night:", morning_freeze_start)
        morning_freeze_source = sessions[morning_freeze_start:morning_freeze_end]
        assert_contains(self, morning_freeze_source, "morningSkinTemperatureDeviation(")
        assert_not_contains(self, morning_freeze_source, "finalizedSkinTemperatureDeviationByMorningDay(")
        assert_contains(self, perf_tests, "testMorningFrozenMetricRejectsUnvalidatedSkinTemperatureMap")

        gate_e_start = sessions.index("func gateETrainingSummary(rest: Int, maxHR: Int)")
        gate_e_end = sessions.index("private static func profileMaxHRForHRR50Threshold", gate_e_start)
        gate_e_source = sessions[gate_e_start:gate_e_end]
        assert_contains(self, gate_e_source, "confirmedWorkouts.max(by: { $0.start < $1.start })")
        assert_contains(self, gate_e_source, "confirmedSleeps.max(by: { $0.start < $1.start })")
        assert_not_contains(self, gate_e_source, "confirmedWorkouts.sorted")
        assert_not_contains(self, gate_e_source, "confirmedSleeps.sorted")

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
            "struct RecoveryRing",
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
            'onTapWhenConnected: onShowStrap',
            'Button(action: onShowAssistant) {',
            'case .strap: "Strap"',
            # 2026-07-08 user-directed: the Assistant is implemented
            # (AtriaAssistantScreen — deterministic Q&A + opt-in coach card);
            # the Coming Soon placeholder is gone.
            'AtriaAssistantScreen(store: store,',
            ".tabBarMinimizeBehavior(.onScrollDown)",
            ".tabViewBottomAccessory",
            ".padding(.bottom, scrollBottomClearance)",
            "private var scrollBottomClearance: CGFloat",
            "shouldShowLiveAccessory ? 260 : 188",
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
        self.assertIn("let hitSize = max(size, 44)", icon_style.group("body"))
        self.assertIn(".frame(width: hitSize, height: hitSize)", icon_style.group("body"))
        assert_contains(self, shared_chrome, ".glassEffect(.regular.tint(tint.opacity(0.10)).interactive(interactive),")
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
        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEEvidence.swift")
        )

        for needle in [
            "private struct AtriaHomeTopChrome: View",
            "AtriaHomeTopChrome(statusStore: model.statusStore",
            "coreLiveStore: model.coreLiveStore",
            ".toolbar(.hidden, for: .navigationBar)",
            "private static func liveHeartRate(ble: AtriaBLEManager) -> Int",
            "sampleAge <= liveHeartRateFreshnessInterval",
            "latestSampleHeartRate: ble.session.last?.bpm,",
            "averageHeartRate: ble.liveHeartWindow.average,",
            "Button(action: presentation.isConnected ? onTapWhenConnected : onTapWhenNotConnected)",
            "ble.startScan(reason: \"home_status_chip\")",
            "var bluetoothPermissionDenied: Bool",
            "bluetoothPermissionDenied: ble.bluetoothPermissionDenied",
            "bluetoothPermissionDenied: status.bluetoothPermissionDenied",
            "ble.$bluetoothPermissionDenied\n            .removeDuplicates()",
            "var hasPulseSignal: Bool { heartRate > 0 || hasContact }",
            "var sensorHasContact: Bool",
            "sensorHasContact: ble.hasContact",
            "var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }",
            "var contactText: String { hasPulseSignal ? \"Live\" : \"No signal\" }",
            "hasContact: reconciledHeartRate > 0,",
            "ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "static let liveRecoveryGraceInterval: TimeInterval = 45",
            "var rangeLossBackfillPending: Bool",
            "func isInRecentLiveRecovery(now: Date = Date()) -> Bool",
            "guard !hasRecentHeartRateSample, status != .poweredOff else { return false }",
            "now.timeIntervalSince(matchAt) <= Self.liveRecoveryGraceInterval",
            "ble.$rangeLossBackfillPending.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "let displayStatus: AtriaBLEManager.Status",
            "let recovering = isRecovering(input: input, now: now)",
            "if recovering, input.status != .poweredOff",
            "} else if hasPulseSignal {",
            "case .poweredOff:\n                displayStatus = .poweredOff",
            # Pin migrated 2026-07-06 (connection-honesty pass): displayStatus
            # now splits `.disconnected` into its own case so a real radio
            # disconnect is only painted "Live" while the pulse is genuinely
            # fresh (hasFreshPulseSignal), not for the full 180s display window.
            "case .disconnected:\n                displayStatus = freshPulse ? .connected : .disconnected",
            "case .connected, .connecting, .scanning:\n                displayStatus = .connected",
            'label = "Live · Battery pending"',
            'accessorySymbol = "bolt.fill"',
            "struct AtriaHeaderBatterySnapshot: Equatable",
            'return "Strap battery \\(batteryText), \\(batteryAccessibilityChargeText)."',
            'label = "\\(batteryLevel)% · Low"',
            'accessibilityLabel = "Live strap, \\(batteryLevel)%, charger status unavailable"',
            "var batteryLastVerifiedAt: Date?",
            "batteryLastVerifiedAt: ble.lastVerifiedBatteryLevelAt",
            "label = hasPulseSignal ? \"Live\" : \"No signal\"",
            "if recovering {\n                    label = \"Reading…\"",
            "} else if !input.isBluetoothReady {\n                    label = \"Waiting for Bluetooth\"",
            "} else if activelyLinking {\n                    label = \"Linking to \\(input.displayDeviceName)\"",
            "} else if reconnectAge != nil {\n                    label = \"Reconnecting…\"",
            "case .scanning:\n                label = \"Searching\"",
            "label = input.bluetoothPermissionDenied ? \"Permission\" : \"Bluetooth off\"",
            "case .poweredOff: symbol = input.bluetoothPermissionDenied ? \"hand.raised.fill\" : \"bolt.slash.fill\"",
            "case .connecting: symbol = recovering ? \"waveform.path.ecg\" : \"dot.radiowaves.left.and.right\"",
            "label = \"Disconnected\"",
            "case .connected: tone = hasPulseSignal ? .green : .orange",
            "case .connecting: tone = recovering ? .cyan : .yellow",
            "case .scanning: tone = .cyan",
            "case .poweredOff: tone = .red",
            # Pin migrated 2026-07-06 (connection-honesty pass): the idle
            # `.disconnected` chip is now neutral gray (not a benign blue accent
            # that read like a positive state), and an active reconnect reuses
            # the .connecting yellow so the color matches the "Reconnecting…" copy.
            "case .disconnected: tone = input.hasEverConnected ? .yellow : .secondary",
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
            "Button(action: onShowSettings)",
            "AtriaToolbarIcon(symbol: \"gearshape\")",
            ".buttonStyle(AtriaHeaderActionButtonStyle())",
            "maxWidth: .infinity,\n               minHeight: AtriaHeaderControlMetrics.height",
            "private enum AtriaHeaderControlMetrics",
            "static let height: CGFloat = 44",
            "static let statusMinWidth: CGFloat = 96",
            "static let iconSpacing: CGFloat = 8",
            "minHeight: AtriaHeaderControlMetrics.height",
            "maxHeight: AtriaHeaderControlMetrics.height",
            "self.publishHeroPulse()\n                if self.prefersPulseSparklineUpdates",
            ".interactive()",
            ".frame(minWidth: AtriaHeaderControlMetrics.statusMinWidth,\n               maxWidth: 172,\n               minHeight: AtriaHeaderControlMetrics.height,\n               maxHeight: AtriaHeaderControlMetrics.height)",
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

        for needle in [
            "let statusStore: AtriaHomeModel.StatusStore",
            "let coreLiveStore: AtriaHomeModel.CoreLiveStore",
            "let pulseLiveStore: AtriaHomeModel.PulseLiveStore",
            "AtriaTopStatusChipHost(statusStore: statusStore,",
        ]:
            assert_contains(self, top_chrome_body, needle)
        assert_not_contains(self, top_chrome_body, "@ObservedObject")

        status_host_start = home.index("struct AtriaTopStatusChipHost: View")
        status_host_end = home.index("private struct AtriaTopStatusChip: View, Equatable", status_host_start)
        status_host = home[status_host_start:status_host_end]
        assert_contains(self, status_host, "@StateObject private var projectionStore: AtriaTopStatusProjectionStore")
        assert_contains(self, status_host, "projectionStore.presentation")
        assert_contains(self, status_host, ".equatable()")
        assert_not_contains(self, status_host, "@ObservedObject")
        assert_not_contains(self, status_host, "UserDefaults")
        assert_not_contains(self, status_host, "Date()")

        projection_start = home.index("final class AtriaTopStatusProjectionStore: ObservableObject")
        projection_end = home.index("struct AtriaTopStatusChipHost: View", projection_start)
        projection = home[projection_start:projection_end]
        assert_contains(self, projection, ".map { AtriaTopStatusPulseTrigger(hasPulseSignal: $0.hasPulseSignal) }")
        assert_contains(self, projection, ".removeDuplicates()")
        assert_contains(self, projection, "AtriaTopStatusCoreTrigger")

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
            "historical_archive_summary_status=",
            "historical_archive_metric_usable_rows=",
            "historical_archive_current_session_usable_rows=",
            "historical_archive_validated_metric_layouts=",
            "historical_archive_metric_ready=",
            "historical_archive_metric_gate=",
            "historical_archive_metric_promotion_blocker=",
            "historical_archive_user_action=",
            "archive_persisted_fail_closed_rows",
            "layout_not_reference_validated",
            "capture_synchronized_live_hr_rr_reference_before_metric_use",
        ]:
            assert_contains(self, pull_script, needle)

    def test_heart_rate_timeline_has_axes_and_fullscreen_explorer(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        shared = source(ROOT / "Atria" / "Atria" / "AtriaSharedUIComponents.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore",
            "@State private var sparkline: AtriaHomeModel.PulseSparklineState",
            "private struct AtriaPulseStatRail: View",
            "struct SeriesKey: Equatable",
            "var miniSeriesKey: SeriesKey?",
            "var miniSeries: AtriaHeartRateChartSeries?",
            "private var miniTimelineSeries: AtriaHeartRateChartSeries",
            "if mergeCache.miniSeriesKey == key, let cached = mergeCache.miniSeries",
            "AtriaHeartRateTimelineCard(series: miniTimelineSeries,",
            "let miniTimelineSeries: AtriaHeartRateChartSeries",
            "&& lhs.miniTimelineSeries == rhs.miniTimelineSeries",
            "let series: AtriaHeartRateChartSeries",
            "AtriaHeartRateAxisChart(points: series.visiblePoints,\n                                        yDomain: series.yDomain,",
            "buckets: series.buckets",
        ]:
            assert_contains(self, vitals, needle)
        assert_not_contains(self, vitals, "@ObservedObject var sparklineStore: AtriaHomeModel.PulseSparklineStore")
        assert_not_contains(self, vitals, "AtriaHeartRateTimelineCard(points:")
        assert_not_contains(self, vitals, "yDomain: AtriaHeartRateChartSeries.yDomain(for: points)")

        for needle in [
            "struct HeartRateChartPoint: Identifiable, Equatable",
            "chartPoints: compactHeartChartPoints(Array(ble.session.suffix(900)))",
            "private static func compactHeartChartPoints(_ samples: [HRSample], targetCount: Int = 120)",
            "private struct AtriaHeartRateTimelineCard: View, Equatable",
            "Text(\"Heart-rate timeline\")",
            "Text(\"Last 6 hr\")",
            "let showsXAxis: Bool",
            "showsXAxis: true",
            "struct AtriaHeartRateExplorer: View",
            "@Environment(\\.colorScheme) private var colorScheme",
            "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
            "Tap or drag to inspect a sample.",
            "AtriaBackdropLayer(isDark: colorScheme == .dark,",
            "reduceTransparency: reduceTransparency",
            "struct AtriaHeartRateChartSeries: Equatable",
            "let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]",
            "let yDomain: ClosedRange<Int>",
            "let buckets: [AtriaHeartRateBucket]?",
            "static func make(points: [AtriaHomeModel.HeartRateChartPoint], zoom: Double) -> AtriaHeartRateChartSeries",
            "buckets: smoothedBuckets(points: visiblePoints)",
            "static func yDomain(for points: [AtriaHomeModel.HeartRateChartPoint]) -> ClosedRange<Int>",
            "func nearestPoint(to selectedTime: Date?) -> AtriaHomeModel.HeartRateChartPoint?",
            "static func smoothedBuckets(points: [AtriaHomeModel.HeartRateChartPoint],",
            "var buckets = Array(repeating: AtriaHeartRateBucketAccumulator(), count: targetBuckets)",
            "private struct AtriaHeartRateBucketAccumulator",
            "@State private var series: AtriaHeartRateChartSeries",
            # 2026-07-07: HR-timeline explorer switched from point-count zoom
            # to a six-hour visible window over a pannable 24-hour series.
            "AtriaHeartRateChartSeries.make(",
            "AtriaHeartRateAxisChart(points: series.visiblePoints,",
            "yDomain: series.yDomain,",
            "buckets: series.buckets",
            "AtriaVitalsHeartRateTimeline.windowed(points, window: .hour24, displayBudget: 1_200)",
            "struct AtriaHeartRateAxisChart: View, Equatable",
            "let yDomain: ClosedRange<Int>",
            "lhs.points == rhs.points && lhs.yDomain == rhs.yDomain && lhs.buckets == rhs.buckets",
            # 2026-07-07: the raw-line marks moved inside the smoothed/raw
            # branch (HR smoothing, user feedback) — indentation deepened.
            "AreaMark(x: .value(\"Time\", point.t),\n                             yStart: .value(\"Visible floor\", yDomain.lowerBound),\n                             yEnd: .value(\"BPM\", point.bpm))",
            ".chartXAxis",
            ".chartYAxis",
            ".chartXSelection(value: $selectedTime)",
            ".chartXSelection(range: $selectedRange)",
            ".chartScrollableAxes(.horizontal)",
            ".chartXVisibleDomain(length: visibleDomain)",
            "override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {",
            "AtriaHeartRateExplorerOrientationPolicy.preferredOrientation",
            ".contentShape(Rectangle())",
            ".compositingGroup()",
            ".clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".clipped()",
            ".background(Color(.systemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".mask(RoundedRectangle(cornerRadius: 12, style: .continuous))",
            ".clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))",
            # 2026-07-07: time-window zoom slider (1 min .. 24 hr) replaces
            # the old 1...6 point-count zoom.
            "Slider(value: $windowIndex,",
            "AtriaHeartRateExplorerStageLayout(",
            "AtriaHeartRateExplorerLayout(size: stage.stageSize)",
            "case .rotatedLandscapeFallback:",
            ".accessibilityLabel(\"Close heart-rate monitor\")",
            "@StateObject private var heartRateExplorerPresenter = AtriaHeartRateExplorerPresentationController()",
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
        assert_contains(self, home, "let initialRRSamples = ble.recentBreathworkRRSamples()")
        assert_contains(self, home, "recentRRSamples = heroPulseStore.state.recentRRSamples")
        assert_contains(self, home, "recentRRSamples = pulseLiveStore.state.recentRRSamples")
        assert_contains(self, home, "private static func makeHeroPulseState(ble: AtriaBLEManager,\n                                           rest: Int,\n                                           maxHR: Int,\n                                           recentRRSamples: [AtriaBreathworkSession.RRSample]) -> HeroPulseState")
        assert_contains(self, home, "private static func makePulseLiveState(ble: AtriaBLEManager,\n                                           rest: Int,\n                                           maxHR: Int,\n                                           recentRRSamples: [AtriaBreathworkSession.RRSample]) -> PulseLiveState")
        assert_contains(self, home, "heartRateZone: Metrics.heartRateZone(bpm: reconciledHeartRate,")
        assert_contains(self, home, "let latestSampleHeartRate,")
        assert_contains(self, home, "return latestSampleHeartRate")
        assert_contains(self, home, "ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        assert_contains(self, ble, "@Published private(set) var sessionSampleCount = 0")

        for needle in [
            "private var lastSessionSampleCountPublishedAt: Date?",
            "static let sessionSampleCountPublishMinimumInterval: TimeInterval = 5",
            "static let sessionSampleCountPublishMinimumDelta = 10",
            "static let liveSessionSampleCountSemanticThresholds: [Int] = [1, 60, 720, 900]",
            "static func shouldPublishLiveSessionSampleCount(currentCount: Int,",
            "liveSessionSampleCountSemanticThresholds.contains(where: { publishedCount < $0 && currentCount >= $0 })",
            "publishSessionSampleCountIfNeeded(now: sampleTime)",
            "publishSessionSampleCountIfNeeded(now: now, force: true)",
            "publishSessionSampleCountIfNeeded(now: start, force: true)",
            "lastSessionSampleCountPublishedAt = nil",
        ]:
            assert_contains(self, ble, needle)
        assert_not_contains(self, ble, "session.append(HRSample(t: sampleTime, bpm: rate))\n        sessionSampleCount = session.count")
        perf_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")
        assert_contains(self, perf_tests, "testLiveSessionSampleCountPublishCadenceKeepsDetectionExactButUIBounded")
        assert_contains(self, perf_tests, "currentCount: 720")
        assert_contains(self, perf_tests, "currentCount: 900")
        pulse_builder_start = home.index("private static func makePulseLiveState")
        pulse_builder_end = home.index("private static func makePulseSparklineState", pulse_builder_start)
        pulse_builders = home[pulse_builder_start:pulse_builder_end]
        assert_not_contains(self, pulse_builders, "ble.recentBreathworkRRSamples()")
        assert_not_contains(self, vitals, "isConnected && live.hasPulseSignal")

    def test_live_heart_rate_freshness_uses_coalesced_expiry_not_permanent_timer(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        for needle in [
            "private var liveHeartRateFreshnessTask: Task<Void, Never>?",
            "private func ensureLiveHeartRateFreshnessExpiryScheduled()",
            "latestSampleAt.addingTimeInterval(Self.liveHeartRateFreshnessInterval)",
            "self.liveHeartRateFreshnessTask = nil",
            "if Self.hasRecentHeartRateSample(ble: self.ble)",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, "Timer.publish(every: 1, on: .main, in: .common)")

    def test_app_scene_owns_services_without_observing_every_publish(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        for needle in [
            "private final class AtriaAppDependencies",
            "let ble: AtriaBLEManager",
            "let store: SessionStore",
            "@State private var dependencies: AtriaAppDependencies",
            "private var ble: AtriaBLEManager { dependencies.ble }",
            "private var store: SessionStore { dependencies.store }",
            "_dependencies = State(initialValue: dependencies)",
        ]:
            assert_contains(self, app, needle)
        assert_not_contains(self, app, "@StateObject private var ble: AtriaBLEManager")
        assert_not_contains(self, app, "@StateObject private var store: SessionStore")

    def test_live_checkpoints_bound_slow_session_derivations(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")
        for needle in [
            "private static let liveCheckpointSlowDerivedRefreshInterval: TimeInterval = 15 * 60",
            "lastCheckpointRestingTrendRefreshAt",
            "lastCheckpointResearchSummaryRefreshAt",
            "static func shouldRefreshLiveCheckpointDerivedState(",
            "minimumInterval: Self.liveCheckpointSlowDerivedRefreshInterval",
        ]:
            assert_contains(self, sessions, needle)
        assert_contains(self, tests, "testLiveCheckpointSlowDerivationsAreBoundedButRecoverFromClockChanges")

    def test_widget_uses_fresh_pulse_and_today_scoped_strap_steps(self):
        widget = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")
        extension = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        for needle in [
            "AtriaHomeModel.resolvedLiveHeartRate(",
            "AtriaHomeModel.mergedStrapStepResearchCount(",
            "activeSessionID: ble.currentLiveSessionID",
            "let publishedSteps = dailySteps.count",
            "AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers()",
            ".mergingCurrentCycleReceipt(",
            "steps: publishedSteps",
            "stepsCapturedAt: stepsCapturedAt",
            "heartRateCapturedAt: liveHeartRateCapturedAt",
            '|| state == "r10_live_validated"',
            "heartRate: liveHeartRate > 0 ? liveHeartRate : nil",
        ]:
            assert_contains(self, widget, needle)
        assert_not_contains(self, widget, "steps: store.imuAuditSummary.strapStepCount")
        assert_not_contains(self, widget, "heartRate: ble.heartRate > 0")
        for needle in [
            "let stepsCapturedAt: Date?",
            "let heartRateCapturedAt: Date?",
            "age <= freshness",
            "private let atriaHeartRateFreshness: TimeInterval = 90",
            "private let atriaStaticStepFreshness: TimeInterval = 90",
            "private let atriaLiveActivityStepFreshness: TimeInterval = 15",
            "capturedAt: snapshot.stepsCapturedAt",
            "capturedAt: s.heartRateCapturedAt",
            "capturedAt.addingTimeInterval(freshness + 0.001)",
        ]:
            assert_contains(self, extension, needle)
        assert_not_contains(self, extension, "case .bpm:\n            return s.heartRate.map(String.init)")
        for needle in [
            "reason: \"live_signal_cleared\"",
            "lastLiveWidgetSnapshotHeartRate = nil",
            "private var batteryWidgetUpdates: AnyPublisher<Void, Never>",
            "ble.$batteryLevel.removeDuplicates()",
            "ble.$batteryChargeStatus.removeDuplicates()",
            "reason: \"strap_battery_update\"",
        ]:
            assert_contains(self, home, needle)

    def test_live_stress_rejects_old_or_persisted_hrv(self):
        hrv = source(ROOT / "Atria" / "Atria" / "HRV.swift")
        stress = source(ROOT / "Atria" / "Atria" / "AtriaStressMonitor.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaBLERecoveryCadenceTests.swift")
        for needle in [
            "func isLiveStressEligible(on now: Date = Date(),",
            "provenance == .localRRWindow",
            "age >= -5 && age <= maximumAge",
        ]:
            assert_contains(self, hrv, needle)
        assert_contains(self, stress, "hrvSnapshot?.isLiveStressEligible(on: now)")
        assert_contains(self, tests, "testLiveStressRejectsPersistedOrOldReadyHRV")

    def test_background_refresh_settles_first_and_completes_exactly_once(self):
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        info = source(ROOT / "Atria" / "Info.plist")
        for needle in [
            "private final class AtriaBackgroundTaskCompletionGate",
            "private var completed = false",
            "success: backupSucceeded",
            "&& historicalRecoverySucceeded",
            "&& recoveredPublicationSucceeded",
            "completion.complete(task, success: false)",
            "store.performBackgroundMaintenanceAsynchronously(reason: reason) { succeeded in",
            "continuation.resume(returning: succeeded)",
            'if reason == "bg_processing"',
        ]:
            assert_contains(self, app, needle)
        assert_not_contains(self, app, "Task.sleep(for: .seconds(185))")
        assert_contains(self, sessions, 'autoConfirmSleepOnForegroundIfUseful(reason: "\\(reason)_overnight_settlement", now: now)')
        assert_contains(self, info, "<string>fetch</string>")

    def test_daytime_naps_are_review_only_until_classifier_validation(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaSleepAuditRegressionTests.swift")
        assert_contains(self, sessions, 'guard candidate.kind != "nap_candidate" else { return false }')
        assert_not_contains(self, sessions, 'if candidate.kind == "nap_candidate" {\n                return candidate.duration >= AggregateSleepCandidate.napMinimumDuration')
        assert_contains(self, tests, "testDaytimeNapWithValidatedStillnessRemainsReviewOnly")

    def test_recovery_stays_on_one_canonical_morning_score(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        cadence_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaRecoveryProjectionCadenceTests.swift")
        hero_start = home.index("private static func makeHeroSnapshot")
        hero_end = home.index("private static func makeDisconnectedHeroSnapshot", hero_start)
        hero = home[hero_start:hero_end]
        assert_contains(self, hero, "let recovery = store.recoveryProjectionForPresentation(")
        assert_contains(self, hero, "recoveryLiftedAfterNap: false")
        assert_not_contains(self, hero, "napAdjustedRecovery(")
        assert_not_contains(self, hero, "nap_lift")
        assert_contains(self, sessions, "let frozen = Self.numericFrozenRecovery(")
        assert_contains(self, sessions, "DailyRecoveryResolver.summary(rollups: dailyRollupHistory,")
        assert_contains(self, sessions, "if frozen != nil {")
        assert_contains(self, sessions, "provisional: DailyRecoveryResolver.noSleepEstimate")
        assert_contains(self, cadence_tests, "testFrozenPhysiologicalDayNeverEvaluatesProvisionalAutoclosure")

    def test_effort_review_requires_sustained_moderate_hr_not_one_peak(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")
        assert_contains(self, sessions, "borderlineElevatedSeconds >= Self.reviewMinimumBorderlineSeconds\n            && borderlineLongestBout >= Self.reviewMinimumBorderlineBout")
        assert_not_contains(self, sessions, "|| (hasStrengthEffort && thresholdGapBPM <= 10)")
        assert_contains(self, tests, "testLongQuietWindowWithOneModestPeakIsNotReviewWorthy")

    def test_settings_appearance_switcher_uses_shared_scroll_safe_chrome(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            # Appearance switcher is now a standard native iOS 26 segmented Picker.
            "private struct AtriaPersonalSettingsDefaultsScope<Content: View>: View",
            "Picker(\"Appearance\", selection: appearanceMode)",
            ".pickerStyle(.segmented)",
            "Text(\"System\").tag(\"system\")",
            "Text(\"Light\").tag(\"light\")",
            "Text(\"Dark\").tag(\"dark\")",
            ".atriaCardAction(prominent: false, tint: .secondary)",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "@AppStorage(\"atriaAppearanceMode\") private var appearanceMode = \"system\"",
            "@State private var settingsPresentation = AtriaSettingsPresentationCoordinator()",
            "arguments.contains(\"--atria-open-settings\")",
            "requestedScreen = \"settings\"",
            "didApplyDebugUIScreenLaunchArgument = true",
            "case \"settings\":\n            selectedTab = .overview",
            "for delay in [100, 450, 900]",
            "settingsPresentation.isPresented = false\n                    await Task.yield()\n                    settingsPresentation.isPresented = true",
            ".preferredColorScheme(preferredColorScheme)",
            "case \"light\": return .light",
            "case \"dark\": return .dark",
            "default: return nil",
        ]:
            assert_contains(self, home, needle)

    def test_settings_first_frame_isolated_from_live_sensor_churn(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private struct AtriaSettingsPresentationRevision: Equatable",
            "private struct AtriaSettingsPresentationHost: View, Equatable",
            "private struct AtriaDeferredSettingsSheet: View",
            "private let content: () -> AnyView",
            "Task.sleep(for: .milliseconds(34))",
            "revision: settingsPresentationRevision",
            "lhs.coordinator === rhs.coordinator && lhs.revision == rhs.revision",
            ".equatable()",
            "researchValidationContent: developerModeEnabled ? {",
            "myWeeklyRecovery: store.currentWeeklyRecovery()",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "func currentWeeklyRecovery(now: Date = Date()) -> Int?",
            "cachedWeeklyRecoveryRevision == revision",
            "cachedWeeklyRecoveryWeekStart == weekStart",
            "WeeklyReport(rollups: dailyRollupHistory,",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "private enum Destination: String, CaseIterable, Hashable, Identifiable",
            "NavigationStack(path: $navigationPath)",
            ".navigationDestination(for: Destination.self)",
            "ForEach(visibleDestinations)",
            "NavigationLink(value: destination)",
            "let researchValidationContent: (() -> AnyView)?",
            "makeResearchValidationContent()",
            "_backupStatus = State(initialValue: .missing)",
            "await Task.yield()",
            "backupStatus = backupStatusProvider()",
        ]:
            assert_contains(self, settings, needle)

        assert_not_contains(self, home, "researchValidationContent: developerModeEnabled ? AnyView(")
        assert_not_contains(self, home, "myWeeklyRecovery: WeeklyReport(rollups:")
        assert_not_contains(self, settings, "_backupStatus = State(initialValue: backupStatusProvider())")

    def test_healthspan_open_reads_weekly_cached_detail_projection(self):
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        fitness = source(ROOT / "Atria" / "Atria" / "AtriaFitnessAge.swift")

        assert_contains(self, health, "projection: store.biologicalAgeHealthspanDetailProjection")
        assert_not_contains(self, health, "AtriaFitnessAge.weeklyObservations(")
        assert_not_contains(self, health, "AtriaFitnessAge.paceOfAging(")
        assert_contains(self, sessions, "var biologicalAgeHealthspanDetailProjection: AtriaFitnessAge.DetailProjection?")
        assert_contains(self, sessions, "detailProjection: output.detailProjection")
        assert_contains(self, fitness, "static func detailProjection(deltas: [DailyDelta]")

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
            "connectionProjection.status != .connected && !debugShowsSegmentContent",
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
            "return live.batteryLevel >= 0 ? \"Last seen \\(live.batteryText)\" : \"Unavailable\"",
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
            "case .strain: return \"bolt.fill\"",
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
            "dailyRollupHistoryRevision: store.dailyRollupHistoryRevision",
            "confirmedWorkoutsRevision: projection.confirmedWorkoutsRevision",
            "dailyMetricHistoryRevision: store.dailyMetricHistoryRevision",
            "sleepHistoryRevision: store.sleepHistorySnapshotRevision",
            "let dailyRollupHistoryRevision: Int",
            "let confirmedWorkoutsRevision: Int",
            "let dailyMetricHistoryRevision: Int",
            "let sleepHistoryRevision: Int",
            "&& lhs.dailyRollupHistoryRevision == rhs.dailyRollupHistoryRevision",
            "&& lhs.confirmedWorkoutsRevision == rhs.confirmedWorkoutsRevision",
            "&& lhs.dailyMetricHistoryRevision == rhs.dailyMetricHistoryRevision",
            "&& lhs.sleepHistoryRevision == rhs.sleepHistoryRevision",
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
            # 2026-07-08: HRV/RHR cards show the real baseline value + a "Calibrating ·
            # night N of 14" detail during calibration (user "start showing something
            # when we can"), with the zone judgment suppressed; else hrvDetailText/hrvZone.
            "detail: hrvCalibratingValue != nil ? calibratingProgressDetail(samples: hrvBaselineSamples) : hrvDetailText",
            "private var hrvDetailText: String",
            "if detail.contains(\"validated\") { return \"Checked\" }",
            "if detail.contains(\"personal baseline\") || detail.contains(\"% kept\") { return \"Personal baseline\" }",
            "struct AtriaOverviewLiveProjectionState: Equatable",
            "static func sessionProgressBucket(_ sampleCount: Int) -> Int",
            "@StateObject private var liveProjectionStore: AtriaOverviewLiveProjectionStore",
            "let live = liveProjectionStore.state.live",
            "&& lhs.live.status == rhs.live.status",
            "AtriaOverviewLiveProjectionState.sessionProgressBucket(lhs.live.sessionSampleCount)",
            "&& lhs.live.liveActiveCaloriesText == rhs.live.liveActiveCaloriesText",
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
            "detail: vo2MaxEstimate.value == nil\n                                    ? vo2MaxEstimate.compactStatusText\n                                    : vo2MaxDetailText",
            "private var vo2MaxDetailText: String",
            "let confidence = vo2MaxEstimate.confidence.capitalized",
            "guard vo2MaxEstimate.trendText != \"Learning\" else { return confidence }",
            "return \"\\(confidence) · \\(vo2MaxEstimate.trendText)\"",
            "trend \\(vo2MaxEstimate.trendText), \\(vo2MaxEstimate.trendDetail)",
            "VO2max unavailable. \\(vo2MaxEstimate.compactStatusText). \\(vo2MaxEstimate.narrative)",
            "case .bioAge:",
            "AtriaGlanceMetricCard(title: \"Fitness age\"",
            "value: biologicalAgeSummary.valueText",
            "Calibrating your fitness-age baseline",
            "Fitness age estimate",
            "private let strainCompareMemo = AtriaOverviewStrainCompareMemo()",
            "strainCompareMedian: strainCompareMemo.median(revision: rollupRevision, rollups: rollups)",
            "strainCompareMedian: projection.strainCompareMedian",
            "private final class AtriaOverviewStrainCompareMemo",
            ".drop { $0.day >= today }",
            "let strainCompareMedian: Double?",
            "&& lhs.strainCompareMedian == rhs.strainCompareMedian",
            "AtriaGlanceMetricCard(title: \"Strain vs typical\"",
            "private let workoutsMemo = AtriaOverviewWorkoutsMemo()",
            "workoutsSummary: workoutsMemo.summary(revision: workoutRevision, workouts: workouts)",
            "workoutsSummary: projection.workoutsSummary",
            "struct AtriaOverviewWorkoutsSummary: Equatable",
            "private final class AtriaOverviewWorkoutsMemo",
            "workouts.prefix(while: { $0.start >= currentWeekStart }).count",
            "let workoutsSummary: AtriaOverviewWorkoutsSummary",
            "&& lhs.workoutsSummary == rhs.workoutsSummary",
            "AtriaGlanceMetricCard(title: \"Workouts\"",
            "value: \"\\(workoutsSummary.weekCount)\"",
            "detail: workoutsSummary.latestOneLiner",
            "sensorSummary: projection.sensorSummary",
            "skinTemperatureSummary: projection.skinTemperatureSummary",
            "let sensorSummary: IMUAuditSummary",
            "let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary",
            "&& lhs.sensorSummary == rhs.sensorSummary",
            "&& lhs.skinTemperatureSummary == rhs.skinTemperatureSummary",
            "onOpenVitals: onOpenVitals",
            "let onOpenVitals: () -> Void",
            "sleepHistory: sleepHistory,",
            "sleepHistory: debugSleepHistorySnapshot ?? projection.sleepHistory",
            "private static func debugSleepHistorySnapshot(arguments: [String]) -> SleepHistorySnapshot?",
            'arguments[valueIndex] == "nap-only-morning"',
            "source: \"manual_nap\"",
            "let sleepHistory: SleepHistorySnapshot",
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
            # Glance values use the shared no-value token; the reason belongs
            # on the detail line.
            "value: currentMainSleep?.sleepEfficiencyText",
            "?? AtriaCompactMetricPresentation.noValue",
            "Duration-based",
            # 2026-07-12: accessibility copy follows the main-night metric.
            "accessibilityDetail: currentMainSleep?.sleepEfficiency == nil",
            "Sleep efficiency is building from saved sleep duration",
            "title: sleepGlanceTitleText",
            "value: sleepGlanceValueText",
            "detail: sleepGlanceDetailText",
            "systemImage: sleepGlanceSystemImage",
            "tint: sleepDurationZone?.tint ?? sleepGlanceTint",
            "zone: sleepGlanceZone",
            "private var sleepGlanceValueText: String",
            # 2026-07-12: the glance is always the main night; naps stay in review.
            "if let latest = currentMainSleep",
            "return latest.durationText",
            "if sleepHistory.candidateCount > 0",
            "return \"\\(sleepHistory.candidateCount)\"",
            "return \"--\"",
            "private var sleepGlanceTitleText: String",
            'private var sleepGlanceTitleText: String {\n        "Sleep"',
            "private var sleepGlanceSystemImage: String",
            'private var sleepGlanceSystemImage: String {\n        AtriaTodayMetric.sleep.systemImage',
            "private var sleepGlanceDetailText: String",
            "if latest.confirmed",
            "return \"Last\"",
            "return \"Review\"",
            "return \"Review\"",
            "private var sleepGlanceTint: Color",
            "sleepHistory.candidateCount > 0 ? .cyan : .orange",
            "private var sleepGlanceZone: AtriaMetricZone?",
            # 2026-07-12: nap exclusion now happens in the canonical
            # sleepDurationZone main-night guard, not in the glance wrapper.
            "return sleepDurationZone",
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
            "sleepHistory.latestDisplayEvidence.map",
            "snapshot.sleepConsistencyText",
            "snapshot.sleepDebtText(goalHours: sleepGoalHours)",
            "AtriaGlanceMetricCard(title: \"Resp rate\"",
            "value: currentMainSleep?.respiratoryRateText",
            "?? AtriaCompactMetricPresentation.noValue",
            "detail: currentMainSleep?.respiratoryRate == nil",
            "? \"Needs qualified sleep\" : \"Early\"",
            "accessibilityDetail: currentMainSleep?.respiratoryRate == nil",
            "Respiratory rate needs qualified sleep evidence.",
            "AtriaGlanceMetricCard(title: \"Strap steps\"",
            "value: steps.valueText",
            "detail: steps.detailText",
            "AtriaStrapStepLiveStatus.persistedMotionDate()",
            "accessibilityDetail: \"\\(steps.accessibilityText) Goal \\(stepsGoal).\"",
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
            "detail: \"Not available yet\"",
            "Blood oxygen is not available yet. Atria does not estimate a percentage.",
            "AtriaGlanceMetricCard(title: \"Wrist temp\"",
            "value: AtriaExperimentalSensorCopy.skinTemperatureValue(",
            "detail: AtriaExperimentalSensorCopy.skinTemperatureStatus(",
            "accessibilityDetail: AtriaExperimentalSensorCopy.skinTemperatureAccessibilityDetail(",
            "decoderAvailable: decoderAvailable",
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
        assert_not_contains(self, overview, "private var strainCompareWindowStrains")
        assert_not_contains(self, overview, "private var strainCompareMedian")
        assert_not_contains(self, overview, "private var thisWeekConfirmedWorkouts")
        assert_not_contains(self, overview, "private var latestConfirmedWorkout")
        assert_not_contains(self, overview, "private var workoutsGlanceDetailText")
        readiness_host_start = overview.index("struct AtriaOverviewReadinessSectionHost: View")
        readiness_host_end = overview.index("struct AtriaOverviewReadinessSection: View", readiness_host_start)
        readiness_host_source = overview[readiness_host_start:readiness_host_end]
        assert_contains(self, readiness_host_source, "let pulseStore: AtriaHomeModel.HeroPulseStore")
        assert_not_contains(self, readiness_host_source, "@ObservedObject var pulseStore")
        assert_not_contains(self, readiness_host_source, "pulseStore.state")

        readiness_eq_start = overview.index("static func == (lhs: AtriaOverviewReadinessSection")
        readiness_eq_end = overview.index("\n    }\n\n    var body: some View", readiness_eq_start)
        readiness_eq_source = overview[readiness_eq_start:readiness_eq_end]
        for needle in [
            "let pulseStore: AtriaHomeModel.HeroPulseStore",
            "AtriaTriRingLiveStatusHost(live: live, pulseStore: pulseStore)",
            "AtriaOverviewBreathworkSessionHost(pulseStore: pulseStore)",
            "private struct AtriaTriRingLiveStatusHost: View",
            "@ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore",
            "AtriaTriRingLiveStatusStrip(live: live, pulse: pulseStore.state)",
            "private struct AtriaOverviewBreathworkSessionHost: View",
            "currentHeartRate: pulseStore.state.heartRate",
            "currentRRSamples: pulseStore.state.recentRRSamples",
        ]:
            assert_contains(self, overview, needle)
        for forbidden in [
            "lhs.dailyRollupHistory == rhs.dailyRollupHistory",
            "lhs.confirmedWorkouts == rhs.confirmedWorkouts",
            "lhs.dailyMetricSparklines == rhs.dailyMetricSparklines",
            "lhs.sleepHistory == rhs.sleepHistory",
            "lhs.pulse == rhs.pulse",
            "displayedPulseStateEquals",
            "recentRRSamples",
        ]:
            assert_not_contains(self, readiness_eq_source, forbidden)
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
        assert_contains(self, home, "onStartWorkout: {\n                                 showWorkoutStartSheet = true\n                             }")
        assert_contains(self, home, "AtriaWorkoutStartSheet(onPrepare:")
        assert_contains(self, home, "beginWorkoutSession(configuration: configuration)")
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
            "ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV.wrappedValue))",
            "private func resetTodayLayout(todayHiddenCSV: Binding<String>,",
            "todayOrderCSV.wrappedValue = AtriaTodayMetric.defaultGlanceOrder.map(\\.rawValue).joined(separator: \",\")",
            "todayHiddenCSV.wrappedValue = \"\"",
            "todaySizeCSV.wrappedValue = \"\"",
            "hidden.insert(metric.rawValue)",
            "todayHiddenCSV.wrappedValue = AtriaTodayMetric.hiddenStorageValue(for: hidden)",
            "Image(systemName: \"arrow.counterclockwise\")",
            ".accessibilityLabel(\"Reset Today layout\")",
            ".accessibilityHint(\"Restores the default cards, order, and sizes\")",
            "direction: -1,\n                                    in: todayOrderCSV.wrappedValue",
            "direction: 1,\n                                    in: todayOrderCSV.wrappedValue",
            "private func targetGroupHeader(title: String,",
            "private func targetGroupResetMenu(title: String,",
            "resetTitle: String,",
            "onReset: @escaping () -> Void",
            "Menu {",
            "Button(action: onReset)",
            ".accessibilityLabel(resetTitle)",
            ".accessibilityHint(\"Restores the recommended \\(title.lowercased()) values\")",
            "targetGroupHeader(title: \"Recovery\"",
            "targetGroupHeader(title: \"Strain\"",
            "targetGroupHeader(title: \"Training load\"",
            "targetGroupHeader(title: \"Activity\"",
            "targetGroupHeader(title: \"Sleep\"",
            "targetGroupHeader(title: \"Personal baselines\"",
            "targetGroupHeader(title: \"Sleep-only signals\"",
            "Tunes sleep-baseline colors and evidence thresholds; it does not certify SpO2 or absolute temperature.",
            "targetGroupHeader(title: \"Fitness age\"",
            "Uses RHR, lnRMSSD, zone 2+, and sleep consistency. These bands only tune guidance colors.",
            "targetGroupHeader(title: \"VO2max\"",
            ".overlay(alignment: .topTrailing)",
            ".padding(.trailing, 48)",
        ]:
            assert_contains(self, settings, needle)
        target_header_start = settings.index("private func targetGroupHeader(title: String,")
        target_menu_start = settings.index("private func targetGroupResetMenu(title: String,", target_header_start)
        assert_not_contains(self, settings[target_header_start:target_menu_start], "Menu {")
        self.assertEqual(settings.count(".overlay(alignment: .topTrailing)"), 9)
        self.assertEqual(settings.count(".padding(.trailing, 48)"), 9)
        for redundant_footer in [
            "Open only when you want to tune how Atria feels and scores your day.",
            "Connection tools stay together so device troubleshooting is one stop.",
            "Haptic alerts and on-device notification preferences.",
            "Local backups, Apple Health export and sync, and on-device storage.",
            "Research bundle sharing, app version, and support contact.",
            "Internal validation tools, visible only in developer mode.",
            "Native theme controls.",
            "Choose, reorder, and reset the cards shown at a glance.",
        ]:
            assert_not_contains(self, settings, redundant_footer)
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
        axis_init_start = vitals.index("init(points: [AtriaHomeModel.HeartRateChartPoint],\n         yDomain: ClosedRange<Int>,\n         buckets: [AtriaHeartRateBucket]? = nil,")
        axis_init_end = vitals.index("static func == (lhs: AtriaHeartRateAxisChart", axis_init_start)
        assert_not_contains(self, vitals[axis_init_start:axis_init_end], "smoothedBuckets(points:")

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
        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEEvidence.swift")
        )

        for needle in [
            "private struct AtriaConnectionDiagnosis: Equatable",
            "private static let lowBatteryThreshold = 25",
            "private static let pendingKnownReconnectActionAge: TimeInterval = 15",
            "private static let connectionDiagnosisPersistenceDelay: TimeInterval = 15",
            "@State private var connectionDiagnosisCandidate: AtriaConnectionDiagnosis?",
            "@State private var connectionDiagnosisCandidateSince: Date?",
            "@State private var connectionDiagnosisPromotionTask: Task<Void, Never>?",
            "@State private var visibleConnectionDiagnosis: AtriaConnectionDiagnosis?",
            "fileprivate struct AtriaConnectionDiagnosisLiveTrigger: Equatable",
            "fileprivate struct AtriaConnectionDiagnosisPulseTrigger: Equatable",
            "private var connectionDiagnosisUpdates: AnyPublisher<Void, Never>",
            ".onReceive(connectionDiagnosisUpdates)",
            "updateConnectionDiagnosisVisibility(reason: \"connection_trigger\")",
            ".map(AtriaConnectionDiagnosisLiveTrigger.init)",
            ".map(AtriaConnectionDiagnosisPulseTrigger.init)",
            "Task.sleep(for: .seconds(Self.connectionDiagnosisPersistenceDelay))",
            "updateConnectionDiagnosisVisibility(reason: \"candidate_deadline\")",
            "updateConnectionDiagnosisVisibility(reason: \"scene_foreground_deferred\")",
            "private func updateConnectionDiagnosisVisibility(reason: String, now: Date = Date())",
            "AtriaConnectionDiagnosis.derive(live: model.coreLiveStore.state",
            "AtriaConnectionDiagnosisBanner(diagnosis: diagnosis)",
            "private struct AtriaConnectionDiagnosisBanner: View, Equatable",
            ".background(Color(uiColor: .secondarySystemBackground),",
            "guard elapsed >= Self.connectionDiagnosisPersistenceDelay else",
            "setVisibleConnectionDiagnosis(nil)",
            "private func resetConnectionDiagnosisCandidate()",
            "private func startConnectionDiagnosisCandidate(_ diagnosis: AtriaConnectionDiagnosis, now: Date)",
            "guard connectionDiagnosisCandidate != diagnosis else { return }",
            "private func setVisibleConnectionDiagnosis(_ diagnosis: AtriaConnectionDiagnosis?)",
            "guard visibleConnectionDiagnosis != diagnosis else { return }",
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
            "bluetoothPermissionDenied: status.bluetoothPermissionDenied",
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
            "let batteryRecentlyDropping = displayableBatteryLevel != nil && ble.batteryRecentlyDropping",
            "officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk",
            "lastScanRequestedAt: ble.lastScanRequestedAt",
            "lastScanMatchAt: ble.lastScanMatchAt",
            "pendingKnownReconnectStartedAt: ble.pendingKnownReconnectStartedAt",
            "pendingKnownReconnectReason: ble.pendingKnownReconnectReason",
            "rangeLossBackfillPending: ble.rangeLossBackfillPending",
            "case .connected where needsContactCoach:",
            "return AtriaConnectionDiagnosis(title: \"Fit check needed\"",
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
        diagnosis_start = home.index("private struct AtriaConnectionDiagnosis: Equatable")
        diagnosis_end = home.index(
            "private struct AtriaConnectionDiagnosisBanner: View, Equatable",
            diagnosis_start,
        )
        diagnosis_source = home[diagnosis_start:diagnosis_end]
        assert_not_contains(self, diagnosis_source, "title: \"HRV settling\"")
        assert_not_contains(self, diagnosis_source, "title: \"Beat-to-beat waiting\"")
        assert_not_contains(self, diagnosis_source, "live.needsRRQualityCoach")
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
            "let atriaOwnedOfflineSyncDisconnect = offlineHistoricalSyncInProgress",
            "|| historyOnlyProbeEnabled",
            "|| historyOnlyProbeMode",
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
        self.assertGreaterEqual(powered_off_index, 0)
        self.assertGreaterEqual(contact_index, 0)
        self.assertGreater(low_battery_index, powered_off_index)
        self.assertGreater(low_battery_index, contact_index)
        self.assertNotIn("live.needsRRQualityCoach", diagnosis_body)
        self.assertNotIn("title: \"HRV settling\"", diagnosis_body)
        self.assertNotIn("title: \"Beat-to-beat waiting\"", diagnosis_body)

        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEEvidence.swift")
        )
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

    def test_handoff_21_stable_r10_radio_mode_is_user_visible(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "let batterySaverEnabled: Bool",
            "let onUpdateBatterySaver: (Bool) -> Void",
            "@State private var batterySaver: Bool",
            "radioModeSection",
            "Toggle(isOn: $batterySaver)",
            "Label(\"Stable sensor mode\", systemImage: \"antenna.radiowaves.left.and.right\")",
            "title: batterySaver ? \"Heart rate + strap motion\" : \"Diagnostic full protocol\"",
            "Atria marks them unavailable rather than substituting phone steps.",
            "Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research.",
            ".accessibilityHint(\"Changing mode reconnects the strap.\")",
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
        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEEvidence.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaStrapPowerPolicy.swift")
        )
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
            "maxAge: TimeInterval = activeBatterySubscriptionBaselineMaximumAge",
            "reconnectBatteryBaselineMaximumAge: TimeInterval = 6 * 60 * 60",
            "activeBatterySubscriptionBaselineMaximumAge: TimeInterval = 36 * 60 * 60",
            "batteryRestoredNotificationConfirmationMaximumAge: TimeInterval = 60 * 60",
            "previousIsCached: self.displayedBatteryLevelIsCached",
            "if previousIsCached {",
            "batteryLevel = -1",
            "freshBatteryConfirmationMinimumSpan",
            "static func freshBatteryMinimumConfirmationSpan(",
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
            "let age = at.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1",
            "BatteryChargeStatus(rawValue: rawCharge) ?? .levelOnly",
            "let effectiveChargeStatus = chargeFresh ? storedChargeStatus : .levelOnly",
            "battery_charge_status=\\(battery.chargeStatus.rawValue)",
            "battery_charge_age_s=\\(chargeAgeText)",
            "let reconnectLevel = Self.reconnectBatteryDisplayLevel(",
            "defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)",
            "BatteryDefaults.requiresFreshConfirmation",
            "assignIfChanged(\\.batteryChargeStatus, .levelOnly)",
            "static func chargeEvidenceFromBatteryLevelChange(",
            "small rise can be quantization/correction and must never claim",
            "if batteryChargeStatus != .charging",
            "assignIfChanged(\\.batteryChargeStatus, .notCharging)",
            "assignIfChanged(\\.batteryChargeStatus, .full)",
            "persistBatteryLevel(batteryLevel, source: \"live_2A19\", chargeStatus: chargeEvidenceFromThisRead)",
            "if let chargeEvidenceFromThisRead {",
            "recordBatteryChargeEvidence(chargeEvidenceFromThisRead,",
            "reason: \"battery_level\",",
            "recordBatteryChargeEvidence(status,",
            "reason: \"battery_status\",",
            "observedAt: receivedAt)",
            "persistBatteryChargeStatus(status,",
            "source: \"live_2A1B\",",
            "private func persistBatteryChargeStatus(_ status: BatteryChargeStatus,",
            "source: String,",
            "observedAt: Date = Date())",
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
            "if batteryShowsPowered || batteryChargeStatus == .full",
            "var batteryDetailText: String",
            "private var hasActiveChargingEvidence: Bool",
            "batteryIsCharging && batteryChargeStatus == .charging && !batteryRecentlyDropping",
            "var batteryShowsPowered: Bool { hasActiveChargingEvidence }",
            "batteryChargeStatus == .charging && !hasActiveChargingEvidence",
            "return \"Charge unavailable\"",
            "case .levelOnly: return \"Charge unavailable\"",
            "case .charging: return \"Strap charging\"",
            "case .notCharging: return \"Strap not charging\"",
            "case .full: return \"Strap full\"",
            "case .charging: return \"Charging\"",
            "guard batteryLevel >= 0 else { return \"no fresh reading\" }",
            "batteryHeaderChargeText == \"--\" ? batteryChargeText : batteryHeaderChargeText",
            "guard batteryLevel >= 0 else { return \"Strap battery unavailable.\" }",
            "return \"Strap battery \\(batteryText), \\(batteryAccessibilityChargeText).\"",
            "guard batteryLevel >= 0 else { return \"—\" }",
            "batteryChargeStatus == .levelOnly",
            "if batteryShowsPowered || batteryChargeStatus == .full",
            "ble.$batteryChargeStatus.removeDuplicates()",
            "batteryChargeStatus: batteryChargeProjection.status",
            ".accessibilityLabel(presentation.accessibilityLabel)",
            "guard batteryLevel >= 0 else { return \"questionmark.circle\" }",
            "value: coreLiveStore.state.batteryStatusSummaryText",
            "detail: coreLiveStore.state.batteryDetailText",
            "let displayableBatteryLevel = ble.displayableBatteryLevel()",
            "batteryLevel: displayableBatteryLevel",
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
            "|| current.batteryChargeStatus != previous.batteryChargeStatus",
            "batteryChargeStatus: model.coreLiveStore.state.batteryChargeStatus",
        ]:
            assert_contains(self, live_activity_coordinator + home, needle)

        for needle in [
            "value: live.batteryStatusSummaryText",
            "if live.batteryLevel >= 0",
            "? projectionStore.state.batteryDetailText : \"Unavailable\"",
            "tint: projectionStore.state.batteryShowsPowered ? .green : .blue",
        ]:
            assert_contains(self, overview + data, needle)

        for needle in [
            "let batteryLevel: Int?",
            "let batteryChargeStatus: String?",
            "let batteryChargeText: String?",
            "batteryLevel: displayableBatteryLevel",
            "let displayableBatteryLevel = ble.displayableBatteryLevel()",
            "batteryChargeStatus: displayableChargeStatus.rawValue",
            "batteryChargeText: displayableChargeStatus.label",
            "battery=%@ charge=%@",
            "formatInt(snapshot.batteryLevel)",
        ]:
            assert_contains(self, widget_snapshot, needle)
        assert_not_contains(self, ble, "let effectiveAt = [at, leaseAt].compactMap { $0 }.max()")

        for needle in [
            "let batteryLevel: Int?",
            "let batteryChargeStatus: String?",
            "let batteryChargeText: String?",
            "if let battery = batteryHeaderText",
            "Label(battery, systemImage: batterySymbol)",
            "if atriaFreshBatteryChargeStatus(snapshot, now: entry.date) == \"charging\"",
            "capturedAt: snapshot.batteryChargeCapturedAt",
            "case \"charging\", \"full\": return .green",
            "liveActivityBatteryText(for: context.state)",
            "liveActivityBatterySymbol(for: context.state)",
            "liveActivityBatteryTint(for: context.state)",
            "private func liveActivityBatteryText(",
            "private func liveActivityBatteryAvailability(",
            "private func liveActivityChargeIsFresh(",
            "return \"\\(state.batteryLevel)% · Charging\"",
            "? \"\\(state.batteryLevel)% · Low\"",
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
            "func refreshHistoricalArchiveStatus(",
            "reason: String = \"manual\",",
            "deferDerivedPublication: Bool = false,",
            "completion: ((Bool) -> Void)? = nil",
            "private var historicalArchiveStatusObserver: NSObjectProtocol?",
            "NotificationCenter.default.addObserver(forName: HistoricalArchive.didUpdateNotification",
            "requestRecoveredDataRecomputation(reason: \"archive_did_update\")",
            "if reason.hasPrefix(\"archive_did_update\")",
            "scheduleConfirmedWorkoutArchiveRehydration(reason: reason)",
            "historicalArchiveStatusRevision &+= 1",
            "revision == self.historicalArchiveStatusRevision",
            "refreshHistoricalTodayHeartRateCache(",
            "NotificationCenter.default.removeObserver(historicalArchiveStatusObserver)",
            "DispatchQueue.global(qos: .utility).async",
            "HistoricalArchive.diagnostics()",
            "return \"Saved\"",
            "if currentSessionUsableRows > 0 { return \"Raw history saved\" }",
            "return \"Raw rows saved\"",
            "var userFootnoteText: String",
            "\\(currentSessionUsableRows)/\\(rows) raw history rows saved. Missing time stays excluded until those strap readings are verified.",
            "return \"\\(rows) raw history rows saved locally. They are not used for metrics.\"",
            "return \"\\(metricUsableRows)/\\(rows) rows metric-ready.\"",
            "var actionText: String",
            "Wear normally; Atria will pull missed rows after reconnect.",
            "Keep the raw history; the gap remains excluded until Atria can verify those missed readings.",
            "The raw archive is saved and remains outside metrics.",
            "var metricGateText: String",
            "if metricReady { return \"Metric-ready\" }",
            "if currentSessionUsableRows > 0 { return \"Raw only\" }",
            "if hasArchiveRows { return \"Not metric-ready\" }",
            "metric_ready=%d fail_closed=%d status=%@ gate=%@ detail=%@",
            "status.hasArchiveRows && !status.metricReady ? 1 : 0",
            "status.metricGateText",
            "var metricReady: Bool",
            "metricUsableRows > 0 && currentSessionUsableRows > 0",
            "if historicalArchive.metricUsableRows == 0",
            "requestRecoveredDataRecomputation(reason: \"deferred_session_load\")",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "AtriaCollectionStatusCardHost(coreLiveStore: coreLiveStore,",
            "store: store)",
            "officialAppInstalled: officialAppInstalled",
            "let officialAppInstalled: Bool",
            "@ObservedObject var vitalsStore: AtriaVitalsSessionProjectionStore",
            "store.refreshHistoricalArchiveStatus(reason: \"data_status_appear\")",
            "AtriaMetricTile(label: \"Backfill\"",
            "value: projectionStore.state.historicalArchiveStatus.valueText",
            "state: backfillState",
            "private var backfillState: AtriaMetricState",
            "if !projectionStore.state.historicalArchiveStatus.parseOK { return .conflict }",
            "if projectionStore.state.historicalArchiveStatus.metricReady { return .validated }",
            "if projectionStore.state.historicalArchiveStatus.hasArchiveRows { return .local }",
            "footnote: backfillFootnote",
            "private var backfillFootnote: String",
            "\"\\(projectionStore.state.historicalArchiveStatus.userFootnoteText) \\(projectionStore.state.historicalArchiveStatus.actionText)\"",
            "AtriaMetricTile(label: \"App\"",
            "value: coexistenceValue",
            "state: coexistenceState",
            "tint: coexistenceTint",
            "footnote: coexistenceFootnote",
            "AtriaCollectionCoexistenceWarning(risk: projectionStore.state.officialAppCoexistenceRisk,",
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
            "AtriaCollectionReferenceActionLabel(title: \"Export beats\"",
            "AtriaCollectionReferenceActionLabel(title: \"Import beats\"",
            "AtriaPanelSectionHeader(title: \"Heart-rate check\", subtitle: \"\")",
            "leadingTitle: \"Heart-rate status\"",
            "leadingDetail: \"comparison workout\"",
            "AtriaCollectionReferenceActionLabel(title: \"Export heart rate\"",
            "AtriaCollectionReferenceActionLabel(title: \"Import heart rate\"",
            "private struct AtriaCollectionReferenceActionLabel: View",
            "private struct AtriaCollectionReferenceSummaryCard: View, Equatable",
            ".buttonBorderShape(.roundedRectangle(radius: 14))",
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
            ".accessibilityLabel(\"Notifications. Choose coaching nudges Atria can send on this phone. Nothing leaves your device.\")",
        ]:
            assert_contains(self, haptics, needle)
        assert_not_contains(self, haptics, ".atriaRaisedCard(")

        for needle in [
            "AtriaHapticAlertSettingsCard(settings: haptics) { next in",
            "haptics = next",
            "AtriaNotificationSettingsCard()",
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

        # Connection updates are isolated to the primary action leaf instead of
        # invalidating the entire onboarding hierarchy on every BLE publish.
        assert_contains(self, onboarding, "private struct PrimaryActionButton: View")
        assert_contains(self, onboarding, "Text(title)")
        assert_contains(self, onboarding, "let ble: AtriaBLEManager")
        assert_contains(self, onboarding, ".frame(maxWidth: .infinity)")
        assert_contains(self, onboarding, ".atriaCardAction(tint: step == .strap && !strapIsReady ? .blue : .green)")
        assert_contains(self, onboarding, ".disabled(step == .strap && historyBootstrap.isWorking)")
        assert_contains(self, live_workout, ".atriaCardAction(tint: .red)")
        assert_contains(self, live_workout, "metricProjection.activeCalories.map")
        assert_contains(self, live_workout, "ScrollView(showsIndicators: false)")
        assert_contains(self, live_workout, "VStack(spacing: 0)")
        assert_contains(self, live_workout, ".padding(.bottom, 12)")
        assert_contains(self, live_workout, ".safeAreaPadding(.bottom)")
        assert_contains(self, live_workout, "@Environment(\\.accessibilityReduceMotion) private var reduceMotion")
        assert_contains(self, live_workout, "private var pulsingHeartIcon: some View")
        # Pin migrated 2026-07-22 (design-handoff UI pass): the live-heart motion
        # moved out of this view into the shared `AtriaPulsingHeart`, which
        # replaces the old `icon.symbolEffect(.pulse, options: .repeating)` with
        # the handoff's `atria-heart` scale keyframe. Both live HR surfaces now
        # render that one component; the Reduce Motion guard travelled with it,
        # so it is asserted against shared_ui below instead of here.
        assert_contains(self, live_workout, "AtriaPulsingHeart(font: .title2)")
        assert_contains(self, live_workout, "AtriaPulsingHeart(font: .headline.weight(.black))")
        assert_not_contains(self, live_workout, "icon.symbolEffect(.pulse, options: .repeating)")
        assert_contains(self, shared_ui, "struct AtriaPulsingHeart: View, Equatable")
        assert_contains(self, shared_ui, "if reduceMotion {")
        assert_contains(self, shared_ui, "CubicKeyframe(1.28, duration: Self.contract)")
        # Live workout uses two purpose-built, narrowly observed performance
        # surfaces. The superseded parent-level cue/target cards must not remain
        # as dead SwiftUI implementations beside them.
        assert_contains(self, live_workout, "AtriaLiveWorkoutHeartBlock(pulseStore: pulseStore,")
        assert_contains(self, live_workout, "AtriaLiveWorkoutStrainGuidanceHost(metricStore: metricStore,")
        assert_contains(self, live_workout, "private struct AtriaLiveWorkoutHeartBlock: View")
        assert_contains(self, live_workout, "private struct AtriaLiveWorkoutStrainGuidance: View")
        assert_not_contains(self, live_workout, "private var workoutCoachCueCard: some View")
        assert_not_contains(self, live_workout, "private var strainTargetCard: some View")
        assert_not_contains(self, live_workout, "private func focusPill(title:")
        assert_contains(self, live_workout, "private var cueTitle: String")
        assert_contains(self, live_workout, "private var cueDetail: String")
        assert_contains(self, live_workout, "private var cueSymbol: String")
        assert_contains(self, live_workout, "private var cueTint: Color")
        assert_contains(self, live_workout, "case \"ease\": return \"Ease down\"")
        assert_contains(self, live_workout, "case \"hold\": return \"Hold here\"")
        assert_contains(self, live_workout, "default: return \"Build gently\"")
        assert_contains(self, live_workout, "Workout cue. \\(cueTitle). \\(cueDetail).")
        assert_contains(self, live_workout, "Text(zone.rawValue == 0 ? \"Below Z1\" : \"Z\\(zone.rawValue) · \\(zone.name)\")")
        assert_contains(self, live_workout, "Text(\"Z\\(candidate.rawValue)\")")
        assert_contains(self, live_workout, "private var targetText: String")
        assert_contains(self, live_workout, "private var progress: Double")
        assert_contains(self, live_workout, "AtriaWorkoutTargetMath.cue(strain: strain, target: target)")
        assert_contains(self, home, "strainTarget: model.heroStore.state.guidance.target")
        assert_not_contains(self, live_workout, "private func heartRateProgress(_ heartRate: Int) -> Double")
        assert_contains(self, live_workout, "private func zoneBandText(_ zone: HRZone) -> String")
        assert_not_contains(self, live_workout, "focusPill(title: \"Samples\"")
        assert_not_contains(self, live_workout, "focusPill(title: \"Evidence\"")
        assert_contains(self, live_workout, "private struct AtriaWorkoutGlassSurfaceModifier: ViewModifier")
        assert_contains(self, live_workout, ".glassEffect(.regular.tint(tint.opacity(0.12)), in: shape)")
        assert_contains(self, live_workout, ".atriaWorkoutContentSurface(cornerRadius: 22, tint: zone.color)")
        assert_contains(self, live_workout, ".atriaWorkoutContentSurface(cornerRadius: 20, tint: cueTint)")
        assert_not_contains(self, live_workout, "liveStore.state.liveActiveCalories.map { \"\\($0)\" }")

    def test_live_workout_end_checkpoints_and_confirms_honestly(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        live_workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private struct AtriaWorkoutEndNotice: Identifiable, Equatable",
            "@State private var workoutEndNotice: AtriaWorkoutEndNotice?",
            "onStop: { await endWorkoutSession(startedAt: session.start,",
            ".sheet(item: $workoutEndNotice, onDismiss: presentQueuedWorkoutShareIfNeeded)",
            "private struct AtriaWorkoutEndRecapSheet: View",
            "guard case .persisted(_, let snapshot, _) = outcome else { return nil }",
            "private func endWorkoutSession(startedAt: Date) async -> Bool",
            "endedAt: Date = Date(),",
            "let checkpointed = await ble.checkpointCurrentSession(",
            "await store.confirmWorkoutWindowForUIAsync(start: startedAt,",
            "end: endedAt,",
            "source: \"live_workout_end\"",
            "store.exportToHealthKit()",
            "guard let finalIntent = await finalIntent.persistTerminal() else",
            "store.flushScheduledPersistenceAsync(reason: \"live_workout_end_confirmed\")",
            "Workout safely retained",
            "AtriaPendingWorkoutIntent.clearIfUnchanged(finalIntent)",
            "ATRIADBG live_workout_end",
        ]:
            assert_contains(self, home, needle)

        assert_not_contains(self, home, ".alert(item: $workoutEndNotice)")
        assert_not_contains(self, home, "retainedWorkoutShareSnapshot")

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
        assert_not_contains(self, home, "store.flushScheduledPersistence(reason: \"live_workout_end\")")
        assert_not_contains(self, home, "confirmBestWorkoutCandidateForUI(rest: rest,")

        end_start = home.index("private func endWorkoutSession(startedAt: Date,")
        end_finish = home.index("private func workoutShareSnapshot(for workout:", end_start)
        end_body = home[end_start:end_finish]
        assert_contains(self, end_body, "await store.confirmWorkoutWindowForUIAsync(start: startedAt,")
        assert_not_contains(self, end_body, "store.confirmWorkoutWindowForUI(start: startedAt,")
        self.assertLess(end_body.index("await finalIntent.persistTerminal()"),
                        end_body.index("await store.confirmWorkoutWindowForUIAsync"))
        self.assertLess(end_body.index("await store.confirmWorkoutWindowForUIAsync"),
                        end_body.index("workoutEndNotice = .persisted"))

        for needle in [
            "func confirmWorkoutWindowForUI(start: Date,",
            "func confirmWorkoutWindowForUIAsync(",
            "let prepared = await Task.detached(priority: .utility)",
            "let activeJournalSession = Self.loadActiveJournalSessionIfFresh",
            "return await commitPreparedWorkoutWindowConfirmation(prepared)",
            "nonisolated static func prepareWorkoutWindowConfirmation(",
            "private func commitPreparedWorkoutWindowConfirmation(",
            "private func confirmWorkoutWindow(start requestedStart: Date,",
            "allowManualSave: true",
            "allowManualSave: Bool = false",
            "canonicalSessions(includeActiveJournal: true).filter",
            "absoluteTime >= requestedStart",
            "SavedSession(id: UUID(),",
            "label: \"Live workout\"",
            "let readiness = window.workoutReadiness(rest: rest, maxHR: maxHR)",
            "let manualConfirmable = allowManualSave",
            "explicitWorkoutSaveIsConfirmable(sampleCount: points.count",
            "sampleCount >= 2 && requestedDuration > 0",
            "readiness.observedDuration >= 15 * 60",
            "readiness.streamCoveragePercent >= 60",
            "readiness.ready",
            "manualConfirmable",
            "live_window_manual_confirmed",
            "live_window_manual_sparse_hr",
            "let workoutSource = \"live_workout_window\"",
            "let id = confirmedWorkoutID(start: requestedStart, end: requestedEnd, source: workoutSource)",
            "zoneSeconds: enriched.zoneSeconds",
            "healthkit_source=user_confirmed",
        ]:
            assert_contains(self, sessions, needle)

        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        assert_contains(self, app, 'arguments.contains("--atria-confirm-workout-window")')
        assert_contains(self, app, "store.confirmWorkoutWindowFromLaunchIfRequested(arguments: arguments)")

    def test_live_workout_auto_detect_prompt_is_inline_and_conservative(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        catalog = source(ROOT / "Atria" / "Atria" / "AtriaExerciseCatalog.swift")
        motion = source(ROOT / "Atria" / "Atria" / "AtriaMotionActivityContext.swift")

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
            "let nextPrompt = evaluation.shouldPrompt",
            "setWorkoutDetectionPromptIfChanged(nextPrompt)",
            "private func setWorkoutDetectionPromptIfChanged(_ nextPrompt: AtriaWorkoutDetectionPrompt?)",
            "guard workoutDetectionPrompt != nextPrompt else { return }",
            "var primaryTitle: String",
            "var headline: String",
            "var subtitle: String",
            "var typeSuggestions: [String]",
            "var exerciseSuggestions: [String]",
            "var suggestedActivityType: AtriaWorkoutActivityType",
            "var suggestedActivityTypes: [AtriaWorkoutActivityType]",
            "AtriaWorkoutActivityType(suggestion: suggestion)",
            "return Array(resolved.prefix(3))",
            "return [AtriaWorkoutActivityType.other.rawValue]",
            "// Heart rate establishes exertion, not the kind of movement.",
            ".other",
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
            "settlingCandidateWindow: (draft.suggestedStart, draft.suggestedEnd)",
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
            "private func saveWorkoutReview(",
            "settlingCandidateWindow: (start: Date, end: Date)",
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
            "_selectedSubtype = State(initialValue: nil)",
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
            "Label(\"Review effort\", systemImage: \"waveform.path.ecg\")",
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
            "stepTitle(\"Time\", subtitle: \"Adjust only if needed.\")",
            "stepTitle(\"Activity\", subtitle: \"Choose the closest match.\")",
            "private var suggestedTypeRunway: some View",
            "Label(\"Activity type\", systemImage: \"figure.strengthtraining.traditional\")",
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
            "stepTitle(\"Exercises\", subtitle: \"Optional\")",
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
            "stepTitle(\"Ready to save\", subtitle: \"Time, activity, and exercises save together.\")",
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
            "@State private var exerciseGroups: [AtriaWorkoutExerciseGroup]",
            "@State private var exerciseNameKeys: Set<String>",
            "@State private var filteredExerciseGroups: [AtriaWorkoutExerciseGroup]",
            ".onChange(of: exerciseSearch)",
            "exerciseQuickAddStrip",
            "exerciseCatalogPreview",
            "private var exerciseCatalogPreview: some View",
            "private var exerciseQuery: String",
            "private var shouldOfferCustomExercise: Bool",
            "AtriaWorkoutExerciseCatalog.allGroups()",
            "AtriaWorkoutExerciseCatalog.filteredGroups(search: exerciseSearch, groups: exerciseGroups)",
            "private func reloadExerciseGroups(search: String? = nil)",
            "private func refreshFilteredExerciseGroups()",
            "private static func exerciseNameKey(_ exercise: String) -> String",
            "shouldOfferCustomExercise",
            "addCustomExerciseButton(exerciseQuery)",
            "private func addCustomExerciseButton(_ exercise: String) -> some View",
            "AtriaWorkoutExerciseCatalog.addCustomExercise(exercise)",
            "selectedExercises.insert(exercise)",
            "reloadExerciseGroups(search: \"\")",
            "exerciseSearch = \"\"",
            "Save as a custom exercise",
            ".accessibilityLabel(\"Add custom exercise \\(exercise)\")",
            "Search full catalog",
            "Search full exercise catalog.",
            "if exerciseQuery.isEmpty, !promptExerciseSuggestions.isEmpty",
            "if !exerciseQuery.isEmpty {\n                ForEach(filteredExerciseGroups)",
            "private var promptExerciseSuggestions: [String]",
            "AtriaWorkoutExerciseCatalog.suggestedExercises(for: suggestion)",
            'Button(isSaving ? "Saving…" : primaryActionTitle)',
            "private func applyWorkoutType(_ type: AtriaWorkoutActivityType)",
            "selectedExercises.removeAll()",
            "step == .summary ? \"Save\" : \"Continue\"",
            "VStack(spacing: 0)",
            ".padding(.bottom, 16)",
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
            "enum AtriaMotionActivityGate",
            "static let minimumSuggestionDuration: TimeInterval = 2 * 60",
            "static let maximumEvidenceAge: TimeInterval = 45",
            "context.kind == .automotive, context.confidence >= .medium",
            "enum AtriaActivitySubtypeClassifier",
            "case .walking: type = .walking",
            "case .running: type = .running",
            "case .cycling: type = .cycling",
            "shadowCandidate: .walking",
        ]:
            assert_contains(self, motion, needle)
        assert_not_contains(self, motion, "suggestion = .dance")

        for needle in [
            "enum AtriaWorkoutActivityType: String, CaseIterable, Identifiable",
            "init?(suggestion: String)",
            "case \"mixed\": self = .functionalFitness",
            "struct AtriaWorkoutExerciseGroup: Identifiable, Equatable",
            "enum AtriaWorkoutExerciseCatalog",
            "private static let customExerciseCacheLock = NSLock()",
            "private static var customExerciseCache: (data: Data?, exercises: [String])?",
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
            "static func filteredGroups(search: String, groups sourceGroups: [AtriaWorkoutExerciseGroup]) -> [AtriaWorkoutExerciseGroup]",
            "private static func cachedCustomExercises(for data: Data?) -> [String]?",
            "private static func cacheCustomExercises(data: Data?, exercises: [String])",
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
        home_without_comments = "\n".join(
            line for line in home.splitlines()
            if not line.lstrip().startswith("//")
        )
        assert_not_contains(self, home_without_comments, "evidence only")
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
        assert_not_contains(self, time_step_source, "captureEvidenceStrip")
        assert_not_contains(self, time_step_source, "reviewDecisionLens")
        assert_not_contains(self, time_step_source, "reviewMetricRow([(\"Window\", durationText)")
        step_indicator_start = home.index("private var stepIndicator: some View")
        step_indicator_end = home.index("private var stepSubtitle: String", step_indicator_start)
        step_indicator_source = home[step_indicator_start:step_indicator_end]
        assert_not_contains(self, step_indicator_source, "stepContextRail")
        review_body_start = home.index("var body: some View", home.index("private struct AtriaWorkoutReviewFlow"))
        review_body_end = home.index("private var header: some View", review_body_start)
        review_body_source = home[review_body_start:review_body_end]
        assert_not_contains(self, review_body_source, "stepIndicator")
        assert_not_contains(self, review_body_source, "workoutReceiptBoard")
        assert_not_contains(self, review_body_source, "captureEvidenceStrip")
        assert_not_contains(self, review_body_source, "reviewDecisionLens")
        assert_not_contains(self, home, "private var typeReviewRoute: some View")
        assert_not_contains(self, home, "private func typeRouteNode(")
        assert_not_contains(self, home, "private func typeRouteConnector(")
        type_step_start = home.index("private var typeStep: some View")
        type_step_end = home.index("private var suggestedTypeRunway", type_step_start)
        type_step_source = home[type_step_start:type_step_end]
        assert_not_contains(self, type_step_source, "typeReviewRoute")
        assert_not_contains(self, type_step_source, "suggestedTypeRunway")
        assert_not_contains(self, type_step_source, "selectedTypeLens")
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
        assert_contains(self, home, "store.sleepReviewResolutionForUI(rest: store.baseline.restingInt ?? 60,")
        assert_contains(self, home, "@State private var pendingSleepReviewDeepLink = false")
        assert_contains(self, home, ".onReceive(store.$pendingSleepReviewNightForUI)")
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
            "private nonisolated static let workoutReviewSettleDelay: TimeInterval = 10 * 60",
            "let secondsSinceEnd = now.timeIntervalSince(candidate.end)",
            "secondsSinceEnd >= workoutReviewSettleDelay",
            "scheduleWorkoutReviewCacheRefresh(rest: rest,",
            "DispatchQueue.global(qos: .utility).async(execute: workItem)",
            "workoutReviewSessionsWithinHorizon(reviewSessions, now: now)",
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
            "workoutOverlapRatioForReview(workout: workout, start: start, end: end) >= 0.70",
            "activityType: String? = nil",
            "activitySubtype: String? = nil",
            "exerciseNames: [String] = []",
            "reviewSource: String? = nil",
            "cleanedActivityType",
            "cleanedExercises.isEmpty ? nil : cleanedExercises",
            "label: cleanedActivityLabel ?? cleanedActivityType ?? \"Live workout\"",
            # 2026-07-07: enriched metrics now computed over the onset-trimmed
            # displayStart (getting-ready lead-in removed); id/readiness stay
            # on the untrimmed bestStart.
            "let enriched = confirmedWorkoutMetrics(start: displayStart,",
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
            # 2026-07-08: SessionDetailSummary now takes the baseline `rest`
            # (matching the rollups) so a workout's strain reconciles everywhere.
            "self.summary = SessionDetailSummary(session: session,",
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
            "private var dailyRollupPreparationRevision = 0",
            "private struct DailyMetricRollupPreparation",
            "private func refreshHistorySnapshotCache(",
            "deferred: Bool = true,",
            "completion: ((Bool) -> Void)? = nil",
            "let sourceSessions = canonicalSessions(includeActiveJournal: true)",
            "historySnapshot = HistorySnapshot.sessionsOnly(\n            sourceSessions,\n            verifiedHistoricalStepEvidenceDays: preservedStepEvidenceDays,",
            "Self.historySnapshotProjectionQueue.asyncAfter(deadline: .now() + 0.12)",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "private func publishFullHistorySnapshotIfCurrent(revision: Int,",
            "history: HistorySnapshot,",
            "sleep: SleepHistorySnapshot,",
            "completion: ((Bool) -> Void)? = nil",
            "historySnapshot = history",
            "sleepHistorySnapshot = sleep",
            "prepareDailyMetricRollupPreparationIfCurrent(revision: revision,",
            "private func prepareDailyMetricRollupPreparationIfCurrent(revision: Int,",
            "let existingDailyMetricRevision = dailyMetricHistoryRevision",
            "let preparation = Self.makeDailyHistoryMetricRollupPreparation(history: history,",
            "private func publishPreparedDailyMetricsAndRollupsIfCurrent(revision: Int,",
            "sourceDailyMetricRevision != dailyMetricHistoryRevision",
            "persistPreparedDailyRollups(preparation)",
            "private nonisolated static func makeDailyHistoryMetricRollupPreparation(history: HistorySnapshot,",
            "private nonisolated static func makeDailyMetricRollupPreparation(metrics: [SavedDailyMetric],",
            "private nonisolated static func makeHistorySnapshots(sessions: [SavedSession],",
            "nonisolated static func makeHistoryDailyRollups(sessions: [SavedSession],",
            "private nonisolated static func makeHistoryTrendSummaries(sessions: [SavedSession],",
            "anomalySource: \"bounded_history_rollups\"",
            "let detectionsBySessionID = Dictionary(detections.map { ($0.id, $0) },",
            "guard detectionsBySessionID[session.id]?.kind == .sleepCandidate else {",
            "private var snapshot: HistorySnapshot {",
            "return fixture",
            "store.historySnapshot",
            "struct HistorySnapshot",
            "let sessionRows: [HistorySessionRowSnapshot]",
            "let restingTrendPoints: [RestingTrendPoint]",
            "private static func makeRestingTrendPoints(_ sessions: [SavedSession]) -> [RestingTrendPoint]",
            "struct HistorySessionRowSnapshot: Identifiable",
            "struct SleepHistorySnapshot: Equatable",
            "static let empty = HistorySnapshot(sessions: [], detections: [], trends: [], rollups: [], rest: 60, maxHR: 200)",
            "static func sessionsOnly(\n        _ sessions: [SavedSession],\n        verifiedHistoricalStepEvidenceDays:",
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

        history_rollup_start = sessions.index("nonisolated static func makeHistoryDailyRollups")
        history_rollup_end = sessions.index("/// Per-DAY strain values", history_rollup_start)
        history_rollup_source = sessions[history_rollup_start:history_rollup_end]
        instance_rollup_start = sessions.index("func dailyRollups(rest: Int, maxHR: Int")
        instance_rollup_end = sessions.index("func aggregateWorkoutCandidates(rest: Int,", instance_rollup_start)
        instance_rollup_source = sessions[instance_rollup_start:instance_rollup_end]
        # The cached history builder receives its already-computed detections
        # and groups them once by civil day. It must not rerun per-session
        # detection on the navigation path. The live builder still derives one
        # detection table per day and reuses its ID lookup for sleep-only RHR.
        assert_contains(self, history_rollup_source, "let detectionsByDay = Dictionary(grouping: detections) { detection in")
        assert_contains(self, history_rollup_source, "let dayDetections = detectionsByDay[day] ?? []")
        assert_not_contains(self, history_rollup_source, ".detectedActivity(rest:")

        assert_contains(self, instance_rollup_source, "let detectionsBySessionID = Dictionary(detections.map { ($0.id, $0) },")
        assert_contains(self, instance_rollup_source, "guard detectionsBySessionID[session.id]?.kind == .sleepCandidate else {")
        assert_not_contains(self,
                            instance_rollup_source,
                            "guard session.detectedActivity(rest: rest, maxHR: maxHR, calendar: calendar)?.kind == .sleepCandidate")

        publish_start = sessions.index("private func publishFullHistorySnapshotIfCurrent")
        publish_end = sessions.index("private func prepareDailyMetricRollupPreparationIfCurrent")
        publish_source = sessions[publish_start:publish_end]
        for forbidden in [
            "makeSavedDailyMetrics(",
            "mergeDailyMetricHistory(",
            "makeDailyRollupStoreEntries(",
            "persistPreparedDailyRollups(",
        ]:
            assert_not_contains(self, publish_source, forbidden)

        history_view_start = sessions.index("struct HistoryView: View")
        history_view_end = sessions.index("struct HistorySnapshot")
        history_view_source = sessions[history_view_start:history_view_end]
        for needle in [
            "HistoryActivityRhythmCard(rollups: Array(snapshot.rollups.prefix(14)))",
            "Self.debugFixtureHistorySnapshot(arguments: ProcessInfo.processInfo.arguments)",
            "@State private var adjustmentNight: SleepHistorySnapshot.Night?",
            "private var pendingSleepReview: SleepHistorySnapshot.Night?",
            "guard let latest = projectionStore.pendingSleepReview,",
            "@StateObject private var projectionStore: AtriaHistoryProjectionStore",
            "HistorySleepReviewCTA(night: pendingSleepReview,",
            "store.confirmSleepHistoryNightForUI(\n                                                    pendingSleepReview,",
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
            "let aggregateSleeps = Self.preferredSleepCandidatesByDay(\n            Self.aggregateSleepCandidates(in: sessions,",
            ".filter(Self.isReviewWorthySleepCandidate)",
            "let aggregateSleeps = Self.preferredSleepCandidatesByDay(\n            aggregateSleepCandidates(",
            # 2026-07-12: metadata-only confirmed workouts mint a rollup day
            # even without a canonical HR session.
            "let rollupDays = Set(grouped.keys)",
            ".union(aggregateSleeps.keys)",
            ".union(confirmedWorkoutsByDay.keys)",
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
            "var reviewReferenceDate: Date",
            "fileprivate var isShortNapReviewCandidate: Bool",
            "fileprivate var isMainSleepReviewCandidate: Bool",
            "return fitsMainSleepReviewWindow",
            "if !confirmed && Self.reviewPromotableNapSources.contains(source) && fitsMainSleepReviewWindow",
            "return false",
            "if Self.explicitNapSources.contains(source) { return true }",
            "if !confirmed && Self.napSizedSleepCandidateSources.contains(source) && fitsInferredDaytimeNapWindow",
            "if Self.explicitSleepSources.contains(source) { return false }",
            "return !confirmed && fitsInferredDaytimeNapWindow",
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
            "if newest.isMainSleepReviewCandidate { return newest }",
            "guard newest.isShortNapReviewCandidate else {",
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
            "sleepEfficiency: Self.efficiency(duration: sleep.duration,",
            "span: sleep.span,",
            "source: sleep.source)",
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
            "private static func efficiency(duration: TimeInterval,",
            'if source == "manual_sleep" || source == "manual_nap" { return nil }',
            "static let minimumFragmentDuration: TimeInterval = 5 * 60",
            "static let napMinimumDuration: TimeInterval = 20 * 60",
            "static let napMaximumSpan: TimeInterval = 3 * 60 * 60",
            'let kind: String',
            "session.duration >= AggregateSleepCandidate.minimumFragmentDuration",
            "let daytimeNapWindow = !overnight && startHour >= 11 && endHour <= 20",
            "let shortLowHRNapLike = session.duration >= AggregateSleepCandidate.napMinimumDuration",
            "session.duration >= AggregateSleepCandidate.napMinimumDuration",
            "session.avg <= rest + 12",
            "sessionP90 <= rest + 30",
            "elevatedFraction <= 0.08",
            "let longOvernightReviewLike = overnight",
            "&& session.duration >= AggregateSleepCandidate.strictMinimumDuration",
            "&& session.avg <= rest + 22",
            "&& sessionP90 <= rest + 45",
            "&& elevatedFraction <= 0.18",
            "let longStableHROnlyMainSleepLike = session.duration >= AggregateSleepCandidate.minimumAutoConfirmMainSleepDuration",
            "|| longStableHROnlyMainSleepLike",
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
            "let napPhysiologyReady = daytimeNapCandidateReady || shortLowHRNapCandidateReady",
            "let napCandidateReady = napPhysiologyReady && motionValidated",
            "guard napCandidateReady\n                        || motionValidatedMainSleepReady\n                        || stableHROnlyMainSleepReady\n                        || degradedHROnlyMainSleepReviewReady\n                        || denseMorningHROnlyReviewReady\n                        || denseLongHROnlyReviewReady else {",
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
            # Launch and foreground settlement share one off-main immutable
            # proposal path; stale workers cannot mutate a newer store.
            "autoConfirmSleepOnForegroundIfUseful(reason: \"deferred_session_load\")",
            "struct ForegroundSleepSettlementProposal: @unchecked Sendable",
            "nonisolated static func shouldCommitForegroundSleepSettlement(",
            "let activeJournalSession = SessionStore.loadResidentJournalSessionForSleepEvaluation(",
            "DispatchQueue.global(qos: .utility).async(execute: workItem)",
            "precomputedStrongCandidates: proposal.strongCandidates",
            "commitPreparedWakeBoundarySleepIfUseful(",
            "private func autoConfirmStrongSleepCandidates(reason: String,\n                                                   limit: Int = 2,\n                                                   sourceSessions: [SavedSession]? = nil,\n                                                   precomputedStrongCandidates: [AggregateSleepCandidate]? = nil,",
            ".filter(Self.isAutoConfirmableMainSleepCandidate)",
            # 2026-07-18: automatic persistence accepts validated motion or the
            # narrow physiological HR-only main-sleep gate; degraded stays review-only.
            "let classification = Self.autoSleepClassification(for: candidate)",
            "confidence: classification.confidence,",
            "nonisolated static func isStrongAutoConfirmableSleepCandidate(_ candidate: AggregateSleepCandidate) -> Bool",
            "candidate.motionEvidenceValidated,",
            "candidate.confidence != .low,",
            "nonisolated static func isAutoConfirmableMainSleepCandidate(_ candidate: AggregateSleepCandidate) -> Bool",
            "baselineRestingIsTrusted: Bool",
            "|| (baselineRestingIsTrusted && isUnambiguousHROnlyMainSleepCandidate(candidate))",
            "nonisolated static func isDegradedHROnlyOvernightSleepCandidate(_ candidate: AggregateSleepCandidate,",
            "nonisolated static func autoSleepClassification(for candidate: AggregateSleepCandidate) -> AutoSleepClassification",
            'source = "sleep_review_hr_only"',
            'source: "auto_confirmed_sleep_hr_only"',
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
            "AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,\n                                          vitalsStore: vitalsStore,\n                                          store: store)",
            "let fixtureSleepHistory = debugFixtureSleepHistory",
            "let sleepHistory = fixtureSleepHistory ?? vitals.sleepHistorySnapshot",
            "let sleepHistoryRevision = fixtureSleepHistory == nil ? vitals.sleepHistorySnapshotRevision : -1",
            "AtriaRecoveryStrainCard(hero: heroStore.state,\n                                sleepHistory: sleepHistory,",
            "sleepHistoryRevision: sleepHistoryRevision",
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
            "source: String = \"manual_ui\") async -> UserConfirmedSleep?",
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
            "self.displayStageSegments = evidence == .none || !stagesPassIntegrity",
            "private static func stageEvidence(source: String,",
            "if source == \"validated_sleep_stages\"",
            "return .sensorResearch",
            "stageDurationsByStage[stage] ?? 0",
            "private static func stageDurations(from segments: [SleepStageSegment]) -> [SleepStageKind: TimeInterval]",
            "private struct AtriaSleepHistoryCard: View, Equatable",
            "AtriaSleepHistoryCard(snapshot: sleepHistory,",
            "let onAddManualSleep: (Date, Date, Bool) async -> Bool",
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
            'navigationTitle("\\(navigationVerb) \\(isNap ? "Nap" : "Sleep")")',
            "\"Suggested by the window: \\(suggested). Your manual choice is kept.\"",
            "\"Atria suggested \\(suggested) from duration and time of day.\"",
            "manualTypeButton(title: \"Sleep\"",
            "manualTypeButton(title: \"Nap\"",
            "private func manualTypeButton(title: String,",
            "typeBinding.wrappedValue = isNapValue",
            ".atriaGlassSelectable(selected: isSelected, tint: .cyan)",
            ".accessibilityValue(isSelected ? \"Selected\" : \"Not selected\")",
            ".onAppear(perform: applyInferredTypeIfNeeded)",
            # 2026-07-07: the onChange handlers also clear the new inline
            # save-failure state, so the literal is now multi-line.
            ".onChange(of: start) { _, _ in",
            "applyInferredTypeIfNeeded()",
            ".onChange(of: end) { _, _ in",
            "private func applyInferredTypeIfNeeded()",
            "guard !typeWasManuallyEdited else { return }",
            "DatePicker(\"Start\"",
            "DatePicker(\"End\"",
            "private var canSave: Bool",
            "duration >= AggregateSleepCandidate.napMinimumDuration",
            "duration <= AggregateSleepCandidate.napMaximumSpan",
            "duration >= AggregateSleepCandidate.strictMinimumDuration",
            "ScrollView {",
            "@State private var showsStageMethodology = false",
            "private var editorCard: some View",
            "Text(\"Sleep details\")",
            "Text(durationText)",
            ".contentTransition(.numericText())",
            ".manualSleepCard(tint: canSave ? .cyan : .orange)",
            "DisclosureGroup(isExpanded: $showsStageMethodology)",
            "private var stageMethodologyText: String",
            ".manualSleepCard(tint: .purple)",
            "private struct AtriaManualSleepCardHeader: View",
            "func manualSleepCard(tint: Color) -> some View",
            ".accessibilityLabel(\"Duration \\(durationText). \\(validationText)\")",
            ".accessibilityValue(preservesSensorStages",
            ".accessibilityHint(showsStageMethodology",
            "\"Naps need at least 20 minutes.\"",
            "\"Longer than 3 hours should be saved as sleep.\"",
            "\"Sleep needs at least 3 hours.\"",
            ".disabled(!canSave || isSaving)",
            "ForEach(SleepStageKind.allCases)",
            "Not estimated from manual entry",
            "Stage bars stay blank until sensor evidence is available.",
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
            "let sleepHistory = fixtureSleepHistory ?? vitals.sleepHistorySnapshot",
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
            "Stages need checked evidence. Duration and overnight vitals remain available while Atria learns.",
            "AtriaSleepStageBuildingSummary(night: latest)",
            "Awake, Light, REM, SWS, and Deep are not ready yet.",
            # 2026-07-08: de-privatized so the broader-lane sizing (user request)
            # is render-testable.
            "struct AtriaSleepStageHypnogram: View, Equatable",
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
            # 2026-07-19: first-night review evidence is numeric but remains research-only.
            'AtriaMetricTile(label: latestEvidence?.evidenceLabel ?? "Latest"',
            "private var zonedLatestEvidence: SleepHistorySnapshot.Night?",
            "latestEvidence.confirmed,",
            "!latestEvidence.isNapEvidence",
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
            "private func confirmSleepCandidate(_ night: SleepHistorySnapshot.Night)",
            "await store.confirmSleepHistoryNightForUI(",
            "private var shouldShowConfirmSleep: Bool",
            "guard snapshot.candidateCount > 0 else { return false }",
            "snapshot.latestReviewable?.confirmed != true",
            "private var reviewSleepLabel: String",
            "snapshot.latestReviewable?.isNapEvidence == true ? \"Review nap\" : \"Review sleep\"",
            "@State private var adjustmentNight: SleepHistorySnapshot.Night?",
            "Label(reviewSleepLabel, systemImage: \"slider.horizontal.3\")",
            ".accessibilityHint(\"Review the detected window before saving it.\")",
            "onConfirmSleep(latest)",
            "Label(\"Confirm\", systemImage: \"checkmark.circle\")",
            ".accessibilityHint(\"Saves the shown sleep or nap candidate locally.\")",
            ".sheet(item: $adjustmentNight) { night in",
            "AtriaManualSleepSheet(initialStart: night.start,",
            "initialIsNap: night.isNapEvidence",
            "onAdjustSleep(night, start, end, isNap)",
            "AtriaMetricTile(label: \"Efficiency\"",
            # 2026-07-19: review evidence shows numbers, while zones above stay confirmed-main-only.
            "value: latestEvidence?.sleepEfficiencyText ?? \"--\"",
            "state: latestEvidence?.sleepEfficiency == nil ? .learning : .research",
            "footnote: \"Duration-based estimate\"",
            'AtriaMetricTile(label: "\\(latestEvidence?.evidenceLabel ?? "Sleep") RHR"',
            'AtriaMetricTile(label: "\\(latestEvidence?.evidenceLabel ?? "Sleep") HRV"',
            "value: latestEvidence?.hrvText ?? \"--\"",
            "state: latestEvidence?.hrv == nil ? .learning : .research",
            'footnote: latestEvidence?.evidenceOnlyFootnote ?? "Sleep-only estimate"',
            'AtriaMetricTile(label: "\\(latestEvidence?.evidenceLabel ?? "Sleep") resp"',
            "value: latestEvidence?.respiratoryRateText ?? \"--\"",
            "state: latestEvidence?.respiratoryRate == nil ? .learning : .research",
            "Eff \\(night.sleepEfficiencyText)",
            "HRV \\(night.hrvText)",
            "Resp \\(night.respiratoryRateText)",
            "enum ManualSleep",
            "static func inferredIsNap(start: Date,",
            "currentSelection: Bool,",
            "eventTimeZoneIdentifier: String? = nil,",
            "calendar: Calendar = .current",
            "duration >= AggregateSleepCandidate.strictMinimumDuration",
            "let daytimeWindow = startHour >= 11 && endHour <= 20",
            "return daytimeWindow",
            # 2026-07-18: five-hour trusted HR-only admission is physiological,
            # so shift-worker sleep is not discarded by the candidate builder.
            "let longStableHROnlyMainSleepLike = session.duration >= AggregateSleepCandidate.minimumAutoConfirmMainSleepDuration",
            "|| longStableHROnlyMainSleepLike",
        ]:
            assert_contains(self, sessions + vitals + manual_sheet + sleep_research + analytics + healthkit, needle)
        self.assertEqual(
            sessions.count("let rollupDays = Set(grouped.keys)"),
            2,
            "both cached history and live daily rollups must surface confirmed-workout-only days",
        )
        assert_not_contains(self, manual_sheet, ".pickerStyle(.segmented)")
        assert_not_contains(self, manual_sheet, "Picker(\"Type\", selection:")
        assert_not_contains(self, manual_sheet, "private var typeCard: some View")
        assert_not_contains(self, manual_sheet, "private var timeCard: some View")
        assert_not_contains(self, manual_sheet, "private var durationCard: some View")
        assert_not_contains(self, manual_sheet, "private var stageFooterNote: some View")
        recovery_card_start = vitals.index("private struct AtriaRecoveryStrainCard")
        recovery_card_end = vitals.index("private struct AtriaProfileCard", recovery_card_start)
        recovery_card_source = vitals[recovery_card_start:recovery_card_end]
        assert_contains(self, recovery_card_source, "let sleepHistoryRevision: Int")
        assert_contains(self, recovery_card_source, "&& lhs.sleepHistoryRevision == rhs.sleepHistoryRevision")
        assert_not_contains(self, recovery_card_source, "lhs.sleepHistory == rhs.sleepHistory")

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

    def test_launch_daily_rollup_diagnostics_use_off_main_snapshot_builder(self):
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
            "DispatchQueue.global(qos: .utility).async",
            "let snapshots = Self.makeHistorySnapshots(sessions: sourceSessions,",
            "Self.logDailyRollups(rollups: snapshots.history.rollups,",
            "guard deepDiagnosticsRequested else { return }",
            "Self.logDeepDailyRollupDiagnostics(formatter: formatter,",
            "sourceSessions: sourceSessions)",
        ]:
            assert_contains(self, body, needle)

        for forbidden in [
            "dailyRollups(rest:",
            "aggregateWorkoutCandidates(",
            "aggregateSleepDiagnostics(",
            "aggregateSleepCandidates(",
            "workoutReadiness(",
        ]:
            assert_not_contains(self, body, forbidden)

        for needle in [
            "private nonisolated static func logDailyRollups(rollups: [DailyRollup],",
            "private nonisolated static func logDeepDailyRollupDiagnostics(formatter: DateFormatter,",
            "aggregateWorkoutCandidates(in: sourceSessions,",
            "aggregateSleepDiagnostics(in: sourceSessions,",
            "aggregateSleepCandidates(in: sourceSessions,",
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
        assert_not_contains(self, app, 'reconcileCanonicalSessionsFromBackupIfNeeded(reason: "fast_launch")')
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

        launch_load_start = sessions.index("private func loadPersistedSessionsDeferred()")
        launch_load_end = sessions.index("private struct ArchivedSessionQueryResult", launch_load_start)
        launch_load = sessions[launch_load_start:launch_load_end]
        assert_contains(self, launch_load, "fullStore.adoptStreamingSources(")
        assert_not_contains(self, launch_load, "Data(contentsOf: sourceURL)")
        assert_not_contains(self, launch_load, "JSONDecoder().decode([SavedSession].self")

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
            "pruned_short_long_wear_fragments=%d",
            "private nonisolated static func persistSessionsSnapshot",
            "private nonisolated static func mergedSessions(primary: [SavedSession], secondary: [SavedSession]) -> [SavedSession]",
            "nonisolated static func sessionsAfterBackupRestore(current: [SavedSession]",
            "let restoredSessions = sessionsAfterBackupRestore(current: snapshot.sessions,",
            "private func reconcileSessionsBeforeLiveUpsert(reason: String)",
            "Self.shouldReconcileSessionsBeforeLiveUpsert(",
            "hasCompletedDeferredSessionLoad: hasCompletedDeferredSessionLoad",
            "nonisolated static func shouldReconcileSessionsBeforeLiveUpsert(",
            "guard hasCompletedDeferredSessionLoad else { return false }",
            'return reason != "add" && reason != "checkpoint" && reason != "fast_launch"',
            "Self.canonicalSessionsAfterUpsert(",
            "nonisolated static func canonicalSessionsAfterUpsert(",
            "private nonisolated static func canonicalInsertionIndex(",
            "struct LatestSessionMetricSource: Equatable",
            "setLatestReferenceValidatedHRVSource(Self.latestReferenceValidatedHRVSourceAfterUpsert(",
            "setLatestLocalRMSSDSource(Self.latestLocalRMSSDSourceAfterUpsert(",
            "nonisolated static func latestLocalRMSSDSourceAfterUpsert(",
            "private nonisolated static func latestSessionMetricSourceAfterUpsert(",
            "struct DailyRespiratoryRatePreparation: Equatable",
            "let respiratoryPreparation = makeDailyRespiratoryRatePreparation(sessions: sessions,",
            "respiratoryRateByMorningDay: respiratoryPreparation.respiratoryRateByMorningDay",
            "let resolvedRespiratoryRates = sorted.map",
            "resp: welfordStat(priorAndCurrentRespiratoryRates)",
            "nonisolated static func makeDailyRespiratoryRatePreparation(sessions: [SavedSession],",
            "func reconcileCanonicalSessionsFromBackupIfNeeded(reason: String)",
            "requestPersistenceFlush(reason: \"session_reconcile_\\(reason)\")",
            "reconcileSessionsBeforeLiveUpsert(reason: \"add\")",
            "reconcileSessionsBeforeLiveUpsert(reason: \"checkpoint\")",
            "Self.mergedSessions(primary: sessions, secondary: decoded)",
            "scheduleSessionFilePersist(reason: \"deferred_load_merge\", delay: 0.10)",
        ]:
            assert_contains(self, sessions, needle)

        # Launch must never destructively discard short autosave fragments.
        # Analytics can canonicalize overlaps in memory; persisted sensor
        # evidence remains lossless until the user explicitly deletes it.
        assert_not_contains(self, sessions, "pruningShortLongWearFragments")
        assert_not_contains(self, sessions, "prune_short_long_wear_fragments")
        perf_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")
        assert_contains(self, perf_tests, "testCheckpointReconcilePolicySkipsDiskScanAfterDeferredLoad")
        assert_contains(self, perf_tests, "testCanonicalSessionsAfterUpsertPreservesNewestOrderAndPreferredReplacement")
        assert_contains(self, perf_tests, "testLatestLocalRMSSDSourceAfterUpsertKeepsOvernightRecoveryPreference")
        assert_contains(self, perf_tests, "testLatestLocalRMSSDSourceAfterUpsertRecomputesWhenCachedSourceIsRemoved")
        assert_contains(self, perf_tests, "testDailyRespiratoryRatePreparationAveragesByMorningDay")

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
            "AtriaBackupCompression.compressedArchiveData(from: data)",
            'let filename = "atria-sessions-\\(timestamp())-\\(safeLabel).json.gz"',
            "compressed=1",
            "ATRIADBG session_backup_error",
            "Self.latestDecodableSessionBackupURL(from: allFiles)",
            "private nonisolated static func latestDecodableSessionBackupURL(from files: [URL]) -> URL?",
            "decodeSessionBackupEnvelope(at: url)",
            "supportedBackupSchemas.contains(envelope.schema)",
        ]:
            assert_contains(self, sessions, needle)
        assert_not_contains(self, sessions, "ATRIADBG session_backup_compress_fallback")

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
            'let status = failure.reason == "no_backup_files" ? "missing" : "error"',
            "restoreSafetyPath",
            "restoreConfirmedSleeps",
            'restoreSummary = "atria.debug.sessionBackup.restore.summary"',
            "static let allRestoreKeys = [",
            "for key in SessionBackupDebugDefaults.allRestoreKeys",
            "defaults.removeObject(forKey: key)",
            "defaults.set(summary, forKey: SessionBackupDebugDefaults.restoreSummary)",
        ]:
            assert_contains(self, sessions, needle)
        assert_not_contains(self, sessions, "defaults.synchronize()")
        for needle in [
            "private let sessionBackupIOWorker",
            "com.adidshaft.atria.session-store.backup-read",
            "await sessionBackupIOWorker.performAsync",
            "private nonisolated static func performSessionBackupIO",
            "SessionBackupWriter.write(snapshot.safetyWriteRequest)",
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
            "let onWriteBackup: ((@escaping @MainActor (SessionBackupStatus) -> Void) -> Void)?",
            "let onVerifyBackup: (() async -> SessionBackupStatus)?",
            "let onRestoreBackup: ((URL) async -> SessionBackupStatus?)?",
            "backupArchiveRow",
            "debugPrioritizesDataSection",
            'ProcessInfo.processInfo.arguments[valueIndex] == "settings-backup"',
            ".fileImporter(isPresented: $backupImportPresented",
            "allowedContentTypes: backupArchiveTypes",
            "UTType(filenameExtension: \"gz\")",
            "url.startAccessingSecurityScopedResource()",
            "Restore backup from Files",
            "@AtriaDefault(SessionStore.iCloudBackupEnabledKey) private var iCloudBackupEnabled = false",
            "private struct AtriaDataSettingsDefaultsScope<Content: View>: View",
            "Toggle(isOn: iCloudBackupEnabled)",
            "Copy to iCloud Drive",
            "icloud.and.arrow.up",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "backupStatusProvider: { store.sessionBackupStatus() }",
            'store.writeSessionBackupAsync(label: "settings", completion: completion)',
            "onVerifyBackup: { await store.verifyLatestSessionBackup() }",
            "guard await store.restoreSessionBackup(from: url) else { return nil }",
        ]:
            assert_contains(self, home, needle)

        assert_not_contains(self, home, 'store.writeSessionBackup(label: "settings")')

        for needle in [
            "struct SessionBackupRawExport: Codable, Equatable",
            "var rawExport: SessionBackupRawExport? = nil",
            "rawExport: nil",
            # 2026-07-12: schema 4 adds confirmed-workout durability.
            "schema: 4",
            "raw_export_embedded=0",
            "private nonisolated static let supportedBackupSchemas: Set<Int> = [1, 2, 3, 4]",
            'static let iCloudBackupEnabledKey = "atria.backup.iCloudDrive.enabled"',
            "FileManager.default.url(forUbiquityContainerIdentifier: nil)",
            "Documents/Atria Backups",
            "mirrorToICloud(backupURL)",
            "ATRIADBG session_backup_icloud status=ok",
            "ATRIADBG session_backup_icloud status=skipped_toggle",
            "func restoreSessionBackup(from backupURL: URL) async -> Bool",
            "let envelope = try decodeSessionBackupEnvelope(at: sourceURL)",
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
            "private var todayHeader: some View",
            "GlassEffectContainer(spacing: 4)",
            "Menu {",
            'Image(systemName: "ellipsis")',
            '.accessibilityLabel("Today actions")',
            ".onLongPressGesture(minimumDuration: 0.45)",
            "isEditingGlance = true",
            ".draggable(metric.dragPayload)",
        ]:
            assert_contains(self, today, needle)

        # Sharing remains in the one-line shortcut strip and the ring image
        # control; duplicating it inside the ellipsis menu added no capability.
        assert_not_contains(self, today, 'Label("Share Today", systemImage: "square.and.arrow.up")')

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
            "private func glanceColumnSpan(for metric: AtriaTodayMetric) -> Int",
            ".gridCellColumns(glanceColumnSpan(for: metric))",
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
            "Text(\"Tap Edit and drag by the handle. VoiceOver also offers Move Up and Move Down actions.\")",
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
            "widgetPreview(title: \"Home Screen · medium\", compact: true)",
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
        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaActiveSessionRestorePreparer.swift")
        )
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
            "pendingMirroredStrengthState = state",
            "strengthMirrorIOQueue.async",
            "record.strengthSets = state.strengthSets",
            "record.excludedIntervals = state.excludedIntervals",
            "previousSampleCount: record.samples.count",
            "strengthSets: record.strengthSets",
            "excludedIntervals: record.excludedIntervals",
        ]:
            assert_contains(self, journal, needle)

        for needle in [
            "let mirroredStrengthState = ActiveSessionJournal.latestMirroredStrengthState()",
            "let mirroredStrengthSets = mirroredStrengthState?.strengthSets",
            "let mirroredExcludedIntervals = mirroredStrengthState?.excludedIntervals",
            "strengthSets: mirroredStrengthSets",
            "excludedIntervals: mirroredExcludedIntervals",
            "strengthSets: record.strengthSets",
            "excludedIntervals: record.excludedIntervals",
            "func checkpointCurrentSession(label: String,",
            "strengthSets: [LoggedSet] = []",
            "func snapshotSession(label: String,",
            "let activeCalories = activeCaloriesForSnapshot(rest: restingHeartRate,",
            "let activeSamples = AtriaStrengthLog.samplesExcludingIntervals(",
            "return Metrics.activeCalories(activeSamples, rest: rest, profile: profile)",
            "strengthSets: strengthSets.isEmpty ? nil : strengthSets",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "@Binding var loggedSets: [LoggedSet]",
            "@Binding var excludedIntervals: [ExcludedInterval]",
            "let strengthHistory: StrengthHistoryProjection",
            "@State private var showSetLogger = false",
            "@State private var editingSetID: UUID?",
            "@Binding var pauseStartedAt: Date?",
            "@State private var latestPRSetID: UUID?",
            "workoutActionsCard",
            "let onMinimize: () -> Void",
            'Image(systemName: "chevron.down")',
            "onMinimize()\n                dismiss()",
            ".accessibilityLabel(\"Minimize workout\")",
            "primeLoggerFromLastSet()\n                            showSetLogger = true",
            'Label("Log set", systemImage: "plus.circle.fill")',
            'Label(isPaused ? "Resume" : "Pause"',
            'systemImage: isPaused ? "play.fill" : "pause.fill"',
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
            "private func finalizePauseIfNeeded()",
            "onTogglePause()",
            "finalizePauseIfNeeded()",
            "let summary = strengthHistorySummary(for: selectedExercise)",
            "let records = summary.records",
            "let history = summary.history",
            "private func strengthHistorySummary(for exercise: String) -> AtriaLiveWorkoutStrengthHistorySummary",
            "private struct AtriaLiveWorkoutStrengthHistorySummary",
            "strengthHistory.records(for: exercise)",
            "strengthHistory.history(for: exercise)",
            "private func personalRecordsIncludingCurrentWorkout(for exercise: String) -> StrengthPersonalRecords",
            ".including(loggedSets, exercise: exercise)",
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

        for removed_copy in [
            'Text("Log sets without leaving the workout.")',
            '"HR keeps recording. This span is excluded when saved."',
            '"Use for rest, setup, or interruptions."',
            'private var strengthLoggerCard: some View',
            'private var pauseResumeCard: some View',
        ]:
            assert_not_contains(self, live_workout, removed_copy)
        assert_not_contains(self, live_workout, "TextField(")
        history_panel_start = live_workout.index("private var exerciseHistoryPanel: some View")
        history_panel_end = live_workout.index("private func historyMetric", history_panel_start)
        history_panel_source = live_workout[history_panel_start:history_panel_end]
        assert_not_contains(self, history_panel_source, "AtriaStrengthLog.history(for:")
        personal_records_start = live_workout.index("private func personalRecords(for exercise: String)")
        personal_records_end = live_workout.index("private func personalRecordsIncludingCurrentWorkout", personal_records_start)
        personal_records_source = live_workout[personal_records_start:personal_records_end]
        assert_not_contains(self, personal_records_source, "AtriaStrengthLog.personalRecords(for:")

        for needle in [
            "@State private var liveWorkoutLoggedSets: [LoggedSet] = []",
            "@State private var liveWorkoutExcludedIntervals: [ExcludedInterval] = []",
            "@State private var liveWorkoutMinimized = false",
            ".fullScreenCover(isPresented: liveWorkoutPresentationBinding)",
            "private var liveWorkoutPresentationBinding: Binding<Bool>",
            "workoutSession != nil && !liveWorkoutMinimized",
            "private func reopenMinimizedWorkout()",
            "liveWorkoutMinimized = false",
            "strengthHistory: liveWorkoutStrengthHistory",
            "loggedSets: $liveWorkoutLoggedSets",
            "excludedIntervals: $liveWorkoutExcludedIntervals",
            "onMinimize: { liveWorkoutMinimized = true }",
            "strengthSets: liveWorkoutLoggedSets",
            "excludedIntervals: liveWorkoutExcludedIntervals",
            "strengthSets: finalIntent.strengthSets,",
            "excludedIntervals: finalizedExcludedIntervals",
            "liveWorkoutLoggedSets = []",
            "liveWorkoutExcludedIntervals = []",
            "AtriaLiveTabAccessoryHost(pulseStore: model.pulseLiveStore,",
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
            "var strengthHistory: StrengthHistoryProjection = .empty",
            "let strengthSets: [LoggedSet]",
            "strengthHistory: liveWorkoutStrengthHistory",
            "AtriaStrengthLog.historyProjection(in: store.sessions)",
            "strengthSets: result.strengthSets",
            "settlingCandidateWindow: settlingCandidateWindow",
            "scheduleSavedWorkoutReviewNotice(confirmed,",
            ".loadPreparedShareArtifactAsync(workoutID: workoutID)",
            "routeArtifact: routeArtifact",
            "draft.strengthHistory.records(for: exercise)",
            "AtriaStrengthLog.isPR($0, against: records)",
            "private func strengthSetShareText(_ set: LoggedSet) -> String",
            "private static func formatShareWeightKg(_ weightKg: Double) -> String",
            "strengthSets: draft.strengthSets",
            "summaryExerciseHistorySection",
            "@State private var summaryExerciseHistoryMemo = AtriaWorkoutSummaryExerciseHistoryMemo()",
            "private var summaryExerciseHistoryRows: [AtriaWorkoutSummaryExerciseHistory]",
            "summaryExerciseHistoryMemo.rows(key: key)",
            "private func makeSummaryExerciseHistoryRows(exercises: [String]) -> [AtriaWorkoutSummaryExerciseHistory]",
            "draft.strengthHistory.history(for: exercise)",
            "AtriaWorkoutSummaryExerciseHistory(id: normalizedExercise(exercise),",
            "AtriaWorkoutSummarySparkline(values: row.sparklineValues, tint: .orange)",
            'Label("Exercise history", systemImage: "chart.xyaxis.line")',
            "private final class AtriaWorkoutSummaryExerciseHistoryMemo",
            "let history: StrengthHistoryProjection",
            "private struct AtriaWorkoutSummaryExerciseHistory: Identifiable, Equatable",
            "let id: String",
            "private struct AtriaWorkoutSummarySparkline: View",
            "let currentPRSet: LoggedSet?",
        ]:
            assert_contains(self, home, needle)
        workout_history_model_start = home.index("private final class AtriaWorkoutSummaryExerciseHistoryMemo")
        workout_history_model_end = home.index("private struct AtriaWorkoutSummarySparkline", workout_history_model_start)
        assert_not_contains(self, home[workout_history_model_start:workout_history_model_end], "UUID()")
        assert_not_contains(self, home, "personalRecord: workoutSharePersonalRecord()")
        assert_not_contains(self, home, "private func workoutSharePersonalRecord()")
        assert_not_contains(self, home, "averageHeartRate: draft.prompt.heartRate")

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
            "Toggle(isOn: useHealthNutrition)",
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
            "self.latestNutrition = rollups.first(where: { $0.nutrition != nil })?.nutrition",
            "if let nutrition = latestNutrition",
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
            "refreshNutritionRollupFromHealthIfEnabled(for: preparation.preparedAt, reason: \"daily_rollup\")",
            "refreshNutritionRollupFromHealthIfEnabled(for: Date(), reason: \"nutrition_authorization\")",
            "private static let nutritionEveningRefreshLastDayKey = \"atria.health.nutrition.eveningRefreshLastDay\"",
            "scheduleEveningNutritionRefreshIfNeeded(now: preparation.preparedAt)",
            "guard minutes >= 21 * 60 else",
            "reason: \"evening_21h\"",
            "private func upsertNutritionRollup(_ summary: AtriaNutritionSummary",
            "dailyRollupStore.upsert(merged)",
            "let preparedAt: Date",
            "var existingNutritionByDay: [Date: AtriaNutritionSummary] = [:]",
            "entry.nutrition = existingNutritionByDay[entryDay]",
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
            "func exportRawDataPackageAsync() async -> URL?",
            "DispatchQueue.global(qos: .utility).async",
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
            "store.exportRawDataPackageAsync()",
            "private func exportRawDataPackageForSharing()",
            "prepareRawExportFixtureIfNeeded()",
            "debugShowsRawExportReadyFixture",
            'arguments[valueIndex] == "raw-export-ready"',
        ]:
            assert_contains(self, strap, needle)

        sharing_body = strap[strap.index("private func exportRawDataPackageForSharing()"):strap.index("    @MainActor")]
        assert_not_contains(self, sharing_body, "store.exportRawDataPackage()")
        assert_not_contains(self, sharing_body, "Task { @MainActor")

        self.assertTrue(schema.startswith("schemaVersion: 1"))
        self.assertTrue(raw_export.index("static let schemaHeader = \"schemaVersion: 1\"") < raw_export.index("static let schemaDocument"))
        assert_contains(self, schema, "## hr.csv")
        assert_contains(self, schema, "## rr.csv")

    def test_cd15_ai_coach_payload_receipt_and_fabrication_guard_exist(self):
        coach = source(ROOT / "Atria" / "Atria" / "AtriaAICoach.swift")
        card = source(ROOT / "Atria" / "Atria" / "AtriaAICoachCard.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "struct AtriaCoachPayload: Codable, Equatable",
            "struct VitalRange: Codable, Equatable",
            "struct DailyMetrics: Codable, Equatable",
            "let today: DailyMetrics?",
            "let last7: [DailyMetrics]",
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
            "last7 = Array(sanitized.prefix(7))",
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
            ".accessibilityLabel(payload.receiptSummary)",
            "AtriaCoachPayloadAuditSheet(payload: payload)",
            "private struct AtriaCoachPayloadAuditSheet: View",
            "ForEach(Array(payload.auditLines.enumerated()), id: \\.offset)",
            ".textSelection(.enabled)",
            'Label("Check figures", systemImage: "exclamationmark.triangle.fill")',
            'Label("Sources", systemImage: "checkmark.shield")',
            "let sentPayload = preparedPayload ?? AtriaCoachPayload.legacy(context: context)",
            "debugShowsFlaggedReplyFixture",
            "debugShowsPayloadAuditFixture",
            'arguments[valueIndex] == "ai-coach-audit"',
            "Your RHR was 49 bpm.",
            "AtriaCoachPayload.fabricationFlags(response:",
        ]:
            assert_contains(self, card, needle)

        for needle in [
            "private var coachSettingsPage: some View",
            'Picker("Mode", selection: coachModeBinding)',
            'Picker("Service", selection: coachProviderBinding)',
            'SecureField(coachHasAPIKey ? "Replace saved API key" : "API key"',
            'LabeledContent("Network", value: coachNetworkLabel)',
        ]:
            assert_contains(self, settings, needle)
        assert_not_contains(self, card, "SecureField")
        assert_not_contains(self, card, 'Picker("Coach mode"')

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
            r"private func logSleepValidation\(label: String\?,\n\s+preparedAggregateCandidates: \[AggregateSleepCandidate\]\? = nil\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(logger)
        body = logger.group("body")
        assert_contains(self, body, "if label == nil, preparedAggregateCandidates == nil, Thread.isMainThread")
        assert_contains(self, body, "DispatchQueue.global(qos: .utility).async")
        assert_contains(self, body, "Self.aggregateSleepCandidates(in: sourceSessions,")
        assert_contains(self, body, "let aggregateSleepCandidatesForValidation = label == nil")
        assert_contains(self, body, "historicalMotionPolicy: .fullArchive")
        assert_contains(self, body, "? (preparedAggregateCandidates ?? [])")
        assert_contains(self, body, "logSleepValidationCandidateMatrix(candidates: aggregateSleepCandidatesForValidation)")
        assert_contains(self, body, "let aggregate = aggregateSleepCandidatesForValidation.first")
        assert_contains(self, body, "aggregateSleepCandidatesForValidation.count")
        self.assertEqual(body.count("historicalMotionPolicy: .fullArchive"), 1)

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
            "Self.isAutoConfirmableMainSleepCandidate(candidate)",
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
            "case 0x24:\n            handleCommandResponsePayload(payload, historyPhase: historyPhase)",
            "handleUnknownProtocolPayload(payload, fullFrame: b, sourceUUID: sourceUUID)",
            "private func handleCommandResponsePayload(\n        _ payload: [UInt8],\n        historyPhase: AtriaBLEHistoryTransportPhaseFence.Snapshot",
            "logClockCommandResponse(payload)",
            "logDataRangeCommandResponse(payload)",
            "handleCommandResponsePayload(\n            [UInt8](frame.payload),\n            historyPhase: historyPhase",
            "ATRIADBG historyClock status=get_clock_response",
            "device=%u",
            "wall=%u",
            "drift_s=%d",
            "stale=%d",
            "status_len=%d",
        ]:
            assert_contains(self, ble, needle)

        self.assertLess(
            ble.index("case 0x24:\n            handleCommandResponsePayload(payload, historyPhase: historyPhase)"),
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
            "@StateObject private var projectionStore: AtriaOverviewMorningJournalProjectionStore",
            "let projection = projectionStore.state",
            "let sleepHistory = debugFixtureSleepHistory ?? projection.sleepHistory",
            "AtriaOverviewMorningJournalCard(snapshot: snapshotStore.state,",
            "sleepHistory: sleepHistory",
            "sleepHistoryRevision: projection.sleepHistoryRevision",
            "todayEntry: projection.todayEntry",
            "taggedDays: projection.taggedDays",
            "final class AtriaOverviewMorningJournalProjectionStore: ObservableObject",
            "store.toggleBehaviorTag(tag)",
            "guard let night = sleepHistory.latest else { return false }",
            "await store.confirmSleepHistoryNightForUI(",
            'source: "morning_journal"',
            "sleepConfirmationFailed = !(await onConfirmSleep())",
            "The suggestion is still here",
            "onAdjustSleep: {",
            "adjustmentNight = sleepHistory.latest",
            "AtriaManualSleepSheet(initialStart: adjustment.start,",
            "initialIsNap: adjustment.isNapEvidence",
            'source: "morning_journal_adjust"',
            "struct AtriaOverviewMorningJournalCard: View, Equatable",
            "let sleepHistoryRevision: Int",
            "&& lhs.sleepHistoryRevision == rhs.sleepHistoryRevision",
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
        assert_not_contains(self, morning_body, "lhs.sleepHistory == rhs.sleepHistory")

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

    def test_journal_checkin_uses_day_answer_lookup_not_per_card_scans(self):
        journal_tab = source(ROOT / "Atria" / "Atria" / "AtriaJournalTab.swift")
        journal_store = source(ROOT / "Atria" / "Atria" / "AtriaJournalStore.swift")
        journal_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaJournalStoreTests.swift")

        for needle in [
            "@State private var entryMemo = AtriaJournalEntryMemo()",
            "@State private var answerMemo = AtriaJournalTodayAnswerMemo()",
            "private var journalEntrySnapshot: AtriaJournalEntrySnapshot",
            "entryMemo.snapshot(revision: projection.behaviorJournalRevision,",
            "private var todayAnswersByQuestion: [String: AtriaJournalAnswer]",
            "answerMemo.answers(revision: projection.journalAnswersRevision,",
            "let answers = todayAnswersByQuestion",
            "answers[$0.rawValue] != nil",
            "todayAnswersByQuestion[question.rawValue] == nil",
            "todayAnswersByQuestion[Self.booleanQuestionID(for: tag)] != nil",
            "pendingCaffeineMinutes = existing.timeOfDayMinutes ?? pendingCaffeineMinutes",
            "pendingDrinks = existing.quantityValue ?? pendingDrinks",
            "todayAnswersByQuestion[question.rawValue]?.value.scaleValue",
            "private struct AtriaJournalEntrySnapshot",
            "private final class AtriaJournalEntryMemo",
            "@MainActor\n    func snapshot(revision: Int,",
            "store.behaviorJournalEntry(for: today, calendar: calendar)",
            "store.behaviorJournalEntry(for: yesterday, calendar: calendar)",
            "private final class AtriaJournalTodayAnswerMemo",
            "store.answersByQuestion(for: today, calendar: calendar)",
        ]:
            assert_contains(self, journal_tab, needle)

        checkin_start = journal_tab.index("private struct AtriaJournalCheckInDeck: View")
        checkin_end = journal_tab.index("private struct AtriaJournalEntrySnapshot", checkin_start)
        checkin_source = journal_tab[checkin_start:checkin_end]
        assert_not_contains(self, checkin_source, "store.behaviorJournalEntry(for:")
        assert_not_contains(self, checkin_source, "store.journalAnswers.answer(questionID:")

        for needle in [
            "func answersByQuestion(for day: Date, calendar: Calendar = .current) -> [String: AtriaJournalAnswer]",
            "if result[answer.questionID] == nil",
        ]:
            assert_contains(self, journal_store, needle)
        assert_contains(self, journal_tests, "func testAnswersByQuestionReturnsOnlyRequestedDay()")

    def test_journal_cycle_phase_patterns_are_memoized(self):
        journal_tab = source(ROOT / "Atria" / "Atria" / "AtriaJournalTab.swift")
        cycle_tracking = source(ROOT / "Atria" / "Atria" / "AtriaCycleTracking.swift")

        for needle in [
            "@State private var phasePatternMemo = AtriaJournalPhasePatternMemo()",
            "phasePatternMemo.patterns(rollupRevision: sessionStore.dailyRollupHistoryRevision,",
            "localDay: localDay",
            "cycleEntriesRevision: store.entriesRevision",
            "private final class AtriaJournalPhasePatternMemo",
            "private var rollupRevision: Int?",
            "private var localDay: Date?",
            "private var cycleEntriesRevision: Int?",
            "prefix { $0.day >= windowStart }",
            "cycleStore.recoveryPatternsByPhase(days: trailingDays,",
        ]:
            assert_contains(self, journal_tab, needle)
        for needle in [
            "private(set) var entriesRevision = 0",
            "entriesRevision &+= 1",
        ]:
            assert_contains(self, cycle_tracking, needle)

        phase_rows_start = journal_tab.index("private var phasePatternRows: some View")
        phase_rows_end = journal_tab.index("var body: some View", phase_rows_start)
        phase_rows_source = journal_tab[phase_rows_start:phase_rows_end]
        assert_not_contains(self, phase_rows_source, "sessionStore.dailyRollupHistory.map")
        assert_not_contains(self, phase_rows_source, "store.recoveryPatternsByPhase(")
        assert_not_contains(self, phase_rows_source, "entriesSignature")
        assert_not_contains(self, journal_tab, "static func entriesSignature")

    def test_journal_heat_strip_is_revision_keyed(self):
        journal_tab = source(ROOT / "Atria" / "Atria" / "AtriaJournalTab.swift")

        for needle in [
            "let localDay = projection.localDay",
            "AtriaJournalHeatStrip(entries: store.behaviorJournalEntries,",
            "revision: projection.behaviorJournalRevision",
            "localDay: localDay",
            ".equatable()",
            "let revision: Int",
            "let localDay: Date",
            "@State private var heatMemo = HeatMemo()",
            "lhs.revision == rhs.revision",
            "&& lhs.localDay == rhs.localDay",
            "private struct HeatKey: Equatable",
            "private final class HeatMemo",
            "func model(entries: [BehaviorJournalEntry],",
            "if self.key == key, let cached",
            "let model = HeatModel(countsByDay: counts,",
            "let model = heatMemo.model(entries: entries, revision: revision, localDay: localDay)",
        ]:
            assert_contains(self, journal_tab, needle)

        heat_start = journal_tab.index("struct AtriaJournalHeatStrip: View, Equatable")
        heat_body = journal_tab[heat_start:journal_tab.index("private func cellColor", heat_start)]
        assert_not_contains(self, heat_body, "private var countsByDay")
        assert_not_contains(self, heat_body, "private var loggedDayCount")
        assert_not_contains(self, heat_body, "entries.map({ Calendar.current.startOfDay")

    def test_overview_report_highlights_are_memoized(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")

        for needle in [
            "private let reportHighlightMemo = AtriaOverviewReportHighlightMemo()",
            "let reportHighlights = reportHighlightMemo.highlights(revision: rollupRevision,",
            "weeklyReportHighlight: reportHighlights.weekly",
            "monthlyReportHighlight: reportHighlights.monthly",
            "private final class AtriaOverviewReportHighlightMemo",
            "private var revision: Int?",
            "private var day: Date?",
            "func highlights(revision: Int,",
            "if self.revision == revision, day == today",
            "WeeklyReport(rollups: rollups, calendar: calendar)",
            "MonthlyReport(rollups: rollups, now: priorMonthDate, calendar: calendar)",
            "let weeklyReportHighlight: WeeklyReport?",
            "let monthlyReportHighlight: MonthlyReport?",
            "&& lhs.weeklyReportHighlight == rhs.weeklyReportHighlight",
            "&& lhs.monthlyReportHighlight == rhs.monthlyReportHighlight",
        ]:
            assert_contains(self, overview, needle)

        section_start = overview.index("struct AtriaOverviewReadinessSection: View")
        section_end = overview.index("private var triRingSleepMetric", section_start)
        section_source = overview[section_start:section_end]
        assert_not_contains(self, section_source, "private var weeklyReportHighlight")
        assert_not_contains(self, section_source, "private var monthlyReportHighlight")

        derivation_start = overview.index("private static let glanceGridSpacing", section_start)
        derivation_source = overview[derivation_start:section_end]
        assert_not_contains(self, derivation_source, "WeeklyReport(rollups: dailyRollupHistory")
        assert_not_contains(self, derivation_source, "MonthlyReport(rollups: dailyRollupHistory")

    def test_activity_monitor_caches_sections_and_timeline_by_store_revisions(self):
        activity = source(ROOT / "Atria" / "Atria" / "AtriaActivityMonitor.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private(set) var sleepHistorySnapshotRevision = 0",
            "sleepHistorySnapshotRevision &+= 1",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "LazyVStack(alignment: .leading, spacing: 14)",
            "@ObservedObject var activityStore: AtriaHomeModel.ActivityStore",
            "let activity = activityStore.state",
            "@State private var activityMemo = AtriaActivityMonitorMemo()",
            "@State private var daySectionsCache = AtriaActivitySectionsCache<[DaySection]>()",
            "AtriaActivitySectionsRequestKey(",
            "workoutsRevision: activity.confirmedWorkoutsRevision,",
            "sleepSnapshot: activity.sleepHistorySnapshot,",
            "workouts: activity.confirmedWorkouts,",
            ".task(id: requestKey)",
            "Task.detached(priority: .utility)",
            "daySectionsCache.publish(result.sections, for: request)",
            "nonisolated private static func makeDaySections(",
            "activityMemo.timelineSpans(sleepRevision: activity.sleepHistorySnapshotRevision,",
            "displayWindow: window,",
            "private final class AtriaActivityMonitorMemo",
            "private struct SourceKey: Equatable",
            "let selectedDayStart: Date",
            "if timelineKey == key",
            "enum AtriaActivitySelectedDaySleeps",
            "static func canonical(snapshot: SleepHistorySnapshot,",
            "static func overlapping(snapshot: SleepHistorySnapshot,",
            "pendingReview: source.pendingSleepReview,",
            "AtriaActivitySelectedDayWorkouts.overlapping(",
            "pendingReview: pendingSleepReview,",
            ").compactMap { night -> (SleepHistorySnapshot.Night, Date, Date)? in",
            "AtriaActivityTimelineLanePacker.assignments(for: visibleSleeps.map",
            "for (night, start, end) in visibleSleeps",
            "AtriaActivityTimelineBuilder.workoutSpans(",
            "for workoutSpan in workoutSpans",
        ]:
            assert_contains(self, activity, needle)

        self.assertGreaterEqual(
            activity.count("AtriaActivitySelectedDaySleeps.overlapping("),
            2,
            "Activity rows and timeline must share one canonical sleep/nap projection",
        )
        assert_not_contains(
            self,
            activity,
            ".filter { source.calendar.isDate($0.day, inSameDayAs: source.selectedDayStart) }",
        )

        activity_root_end = activity.index("/// Detail + editor for a confirmed workout")
        activity_root_source = activity[:activity_root_end]
        assert_not_contains(self, activity_root_source, "@ObservedObject var store: SessionStore")
        assert_not_contains(self, activity_root_source, "store.sleepHistorySnapshot")
        assert_not_contains(self, activity_root_source, "store.confirmedWorkouts")

        for needle in [
            "struct ActivityState: Equatable",
            "final class ActivityStore: ObservableObject",
            "@Published private(set) var state: ActivityState",
            "guard next != state else { return false }",
            "let activityStore: ActivityStore",
            "self.activityStore = ActivityStore(state: Self.makeActivityState(store: store))",
            "AtriaActivityMonitorTab(activityStore: model.activityStore,",
            "model.setActivityProjectionActive(tab == .plan)",
            "self?.requestActivityProjectionRefresh()",
            "guard prefersActivityProjectionUpdates,",
            "!activityProjectionRefreshScheduled else { return }",
            "let pendingSleep = store.pendingSleepReviewNightForUI",
            "let workoutReview = store.latestWorkoutReviewCandidate(",
            "let detections = store.activityDetectionsForUI",
            "activityStore.refresh(Self.makeActivityState(store: store))",
        ]:
            assert_contains(self, home, needle)

        body_start = activity.index("var body: some View")
        day_sections_worker = activity.index("nonisolated private static func makeDaySections(")
        body_source = activity[body_start:day_sections_worker]
        assert_not_contains(self, body_source, "Dictionary(grouping:")
        assert_not_contains(self, body_source, "store.sleepHistorySnapshot.nights.map")
        assert_not_contains(self, body_source, "store.confirmedWorkouts.map")

        timeline_start = activity.index("private var timelineSpans: [TimelineSpan]")
        timeline_end = activity.index("\n\n    private var canGoToNextDay", timeline_start)
        timeline_source = activity[timeline_start:timeline_end]
        assert_not_contains(self, timeline_source, "for night in store.sleepHistorySnapshot.nights")
        assert_not_contains(self, timeline_source, "for workout in store.confirmedWorkouts")

    def test_session_upsert_replaces_with_single_sessions_publish(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private func insertionIndex(in orderedSessions: [SavedSession], for start: Date) -> Int",
            "if orderedSessions[mid].start > start",
            "var next = sessions",
            "let destination = insertionIndex(in: next, for: session.start)",
            "sessions = next",
        ]:
            assert_contains(self, sessions, needle)

        upsert_start = sessions.index("private func upsertSession(_ incomingSession: SavedSession, isLiveCheckpoint: Bool = false) -> String")
        upsert_end = sessions.index("\n    }\n\n    func homeDashboardDiagnostics", upsert_start)
        upsert_source = sessions[upsert_start:upsert_end]
        assert_not_contains(self, upsert_source, "sessions.remove(at:")
        assert_not_contains(self, upsert_source, "sessions.insert(")
        self.assertEqual(upsert_source.count("sessions = next"), 2)

    def test_history_section_cache_includes_confirmed_sleep_revision(self):
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        history = source(ROOT / "Atria" / "Atria" / "AtriaHistorySection.swift")

        for needle in [
            "sleeps: vitals.confirmedSleeps",
            "sleep: vitals.sleepHistorySnapshotRevision",
            "@StateObject private var historyProjectionStore = AtriaVitalsHistoryProjectionStore()",
            "let historyProjection = historyProjectionStore.projection",
            "AtriaHistorySection(model: historyProjection.model,",
        ]:
            assert_contains(self, health, needle)

        for needle in [
            "let model: AtriaHistoryModel",
            "struct AtriaHistoryRevisionKey: Equatable, Hashable, Sendable",
            "let sleep: Int",
            "guard key != requestedKey, key != projection.key else { return false }",
            "private let monthGroups: [MonthGroup]",
            "self.monthGroups = Self.makeMonthGroups(days: model.days)",
            "private static func makeMonthGroups(days: [AtriaHistoryDay]) -> [MonthGroup]",
        ]:
            assert_contains(self, history, needle)
        assert_not_contains(self, history, "@State private var model = AtriaHistoryModel.empty")
        assert_not_contains(self, history, ".onAppear { rebuild() }")
        assert_not_contains(self, history, "private var builtKey")

        full_start = history.index("struct AtriaHistoryFullScreen: View")
        full_body_start = history.index("var body: some View", full_start)
        full_body_end = history.index("private func monthHeader", full_body_start)
        full_body_source = history[full_body_start:full_body_end]
        assert_not_contains(self, full_body_source, "Dictionary(grouping:")
        assert_not_contains(self, full_body_source, "buckets:")

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
            "decisions.append(await makeSleepReviewDecision(store: store))",
            "if includeWorkoutReviewDecisions {",
            "decisions.append(makeWorkoutReviewDecision(store: store, ble: ble))",
            "private static func makeSleepReviewDecision(store: SessionStore) async -> NotificationDecision {",
            "switch store.sleepReviewResolutionForUI(rest: rest,",
            "try? await Task.sleep(for: .milliseconds(20))",
            # 2026-07-12: review flow explicitly consumes the reviewable record.
            "let reviewableSnapshotNight = snapshot.latestReviewable?.confirmed == false ? snapshot.latestReviewable : nil",
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
            "scheduleMorningSummaryIfNeeded(metrics: preparation.metrics, now: preparation.preparedAt)",
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
            'notificationCenter.post(name: Self.didEnqueueNotification, object: url)',
            "static func scheduleFastLaunchMorningSummaryDebugFixtureIfRequested",
            'arguments.contains("--atria-test-morning-summary-notification")',
            'arguments.contains("--atria-test-morning-summary-toggle-off")',
            "private static func scheduleMorningSummaryDebugFixture",
            'ATRIADBG notification_fixture kind=morning_summary status=scheduled_input',
            'ATRIADBG notification_schedule status=skipped_toggle kind=morning_summary',
        ]:
            assert_contains(self, scheduler, needle)

        for needle in [
            "scheduleMorningSummaryIfNeeded(metrics: preparation.metrics, now: preparation.preparedAt)",
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
            "private var overviewTrendPointsRefreshRevision = 0",
            "private(set) var overviewTrendPointsRevision = 0",
            "private var trainingLoadSummaryRevision = 0",
            "private func refreshOverviewTrendPointsCache(",
            "private func refreshTrainingLoadSummaryCache(",
            "deferred: Bool = true,",
            "completion: ((Bool) -> Void)? = nil",
            "DispatchQueue.global(qos: .utility).async",
            "DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self, source, rest, maxHR, revision] in",
            "SessionStore.makeOverviewTrendPoints(sessions: source, rest: rest, maxHR: maxHR)",
            "guard let self, revision == self.overviewTrendPointsRefreshRevision else {",
            "if points != self.overviewTrendPoints {",
            "self.overviewTrendPointsRevision &+= 1",
            "SessionStore.makeTrainingLoadSummary(sessions: source,",
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
            "let projection = projectionStore.state",
            "AtriaTrendChartCard(points: fixturePoints ?? projection.points,",
            "pointsRevision: fixturePoints == nil ? projection.pointsRevision : nil",
            "baselineRestingHR: fixturePoints == nil ? projection.baselineRestingHR : 58",
            "@StateObject private var projectionStore: AtriaTrendChartProjectionStore",
            "final class AtriaTrendChartProjectionStore: ObservableObject",
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
            # 2026-07-07 dedup audit: Latest/Range pills removed from the
            # summary strip (position band owns them).
            "Average \\(summary.averageText)",
            "private struct AtriaTrendPreparedSeries",
            "@State private var prepared = AtriaTrendPreparedSeries.empty",
            "let pointsRevision: Int?",
            "private struct PointsKey: Equatable",
            "let revision: Int?",
            "init(points: [AtriaTrendPoint], revision: Int?)",
            "private var pointsKey: PointsKey",
            "let pointsKey: PointsKey",
            ".onChange(of: pointsKey, initial: true)",
            "let key = PreparedKey(pointsKey: pointsKey, metric: metric, range: range, baselineRestingHR: baselineRestingHR)",
            "@State private var periodReadout = AtriaTrendPeriodReadout.empty",
            "private static func prepareSeries(points: [AtriaTrendPoint]",
            "private static func preparePeriodReadout(points: [AtriaTrendPoint]",
            "let cutoff = range.cutoffDate(now: now)",
            # 2026-07-05: previousCutoff now gates on `range.hasPriorPeriod`
            # (see prepareSeries pin above) instead of unconditionally
            # subtracting `range.days`.
            "range.hasPriorPeriod",
            "previousSeries: previousSamples",
            # 2026-07-07 dedup audit: the dock (a second control bound to
            # the same $range as the segmented picker) is unmounted; its
            # struct remains.
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
            # 2026-07-07 dedup audit: the Recovery/Strain glance lanes were
            # the third rendering of the reserve/load pair — the balance map
            # owns it now; the board keeps its per-metric delta gauges.
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
            # 2026-07-07 dedup audit: the report card's Reserve/Load bars
            # moved to single ownership by the balance map.
            "Balance map. Recovery reserve",
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
            "bandLabel(\"Now\", value: stats.latest)",
            "AtriaTrendSessionDotStrip(series: prepared.series,",
            "private struct AtriaTrendSessionDotStrip: View, Equatable",
            "Array(series.suffix(28))",
            "private static func domain(for samples: [AtriaTrendPoint.Sample]) -> ClosedRange<Double>",
            "let samples = visibleSamples",
            "let domain = Self.domain(for: samples)",
            "Text(\"Day pattern\")",
            "Text(\"\\(samples.count)d\")",
            "let normalized = Self.normalized(sample.value, domain: domain)",
            "Self.opacity(for: normalized)",
            "Self.height(for: normalized)",
            "Day pattern for \\(metric.shortLabel), \\(samples.count) days in view.",
            "private static func normalized(_ value: Double, domain: ClosedRange<Double>) -> Double",
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
            # 2026-07-07 dedup audit: the report card's Res/Load bars were
            # the third rendering of the reserve/load pair in one stack —
            # the balance map is now the single owner.
            "reportTile(strongestSignal)",
            "Trend range report. Best signal",
            "private struct AtriaTrendPeriodBalanceMap: View, Equatable",
            "Label(\"Balance map\", systemImage: \"circle.grid.cross\")",
            "mapCorner(\"Ready\", alignment: .leading)",
            "mapCorner(\"Protect\", alignment: .trailing)",
            # 2026-07-07 dedup audit: the balance map's pill row repeated
            # the pair its 2D dot already encodes; the dot + a11y label are
            # the single owner now.
            "Balance map. Recovery reserve",
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
            "let visibleInterval = range.periodInterval(",
            "let earlierInterval = range.periodInterval(",
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
            "let detailRollups = debugMetricDetailRollups ?? dailyRollupHistory",
            "rollups: detailRollups",
            "rollupsRevision: debugMetricDetailRollups == nil ? dailyRollupHistoryRevision : nil",
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
            "Metrics.dayCalories(cycleSamples.map",
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
        assert_not_contains(self, chart_card_source, ".onChange(of: points,")
        prepared_start = trend_chart.index("private struct PreparedKey: Equatable")
        prepared_end = trend_chart.index("// Real progressive disclosure", prepared_start)
        prepared_source = trend_chart[prepared_start:prepared_end]
        assert_not_contains(self, prepared_source, "let points: [AtriaTrendPoint]")
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
            "private var domain",
            "private func normalized(_ value: Double) -> Double",
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
        assert_contains(self, overview, "AtriaOverviewTrendPresentation.showsContent(")
        assert_contains(self, overview, "cachedPointCount > 0 || debugShowsTrendFixture")
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

    def test_expanded_chart_prepares_domains_overlays_and_brush_stats_once(self):
        expanded = source(ROOT / "Atria" / "Atria" / "AtriaExpandedChart.swift")

        for needle in [
            "private let prepared: AtriaExpandedChartPreparedModel",
            "self.prepared = AtriaExpandedChartPreparedModel(points: points,",
            "RectangleMark(xStart: .value(\"Start\", prepared.dataStart),",
            "ForEach(overlay.points) { point in",
            "y: .value(title, prepared.eventLaneY)",
            ".chartXScale(domain: prepared.xDomain)",
            ".chartYScale(domain: prepared.yDomain)",
            "ForEach(prepared.overlays) { overlay in",
            "return prepared.brushSummary(start: start, end: end, unit: unit)",
            "private struct AtriaExpandedChartPreparedOverlay: Identifiable",
            "private struct AtriaExpandedChartPreparedModel",
            "let xDomain: ClosedRange<Date>",
            "let yDomain: ClosedRange<Double>",
            "let eventLaneY: Double",
            "let overlays: [AtriaExpandedChartPreparedOverlay]",
            "private let brushPoints: [AtriaDetailChartPoint]",
            "brushPoints = points.sorted { $0.day < $1.day }",
            "private static func rescaledOverlayPoints(_ points: [AtriaDetailChartPoint],",
            "func brushSummary(start: Date,",
            "let lower = lowerBound(for: lo)",
            "let upper = upperBound(for: hi)",
            "for point in brushPoints[lower..<upper]",
            "private func lowerBound(for day: Date) -> Int",
            "private func upperBound(for day: Date) -> Int",
        ]:
            assert_contains(self, expanded, needle)

        view_start = expanded.index("struct AtriaExpandedChartView: View")
        view_end = expanded.index("private struct AtriaExpandedChartPreparedOverlay", view_start)
        view_source = expanded[view_start:view_end]
        for forbidden in [
            "private func rescaledOverlayPoints",
            "private var eventLaneY: Double",
            "private var yDomain: ClosedRange<Double>",
            "private var xDomain: ClosedRange<Date>",
        ]:
            assert_not_contains(self, view_source, forbidden)

        brush_start = expanded.index("private var brushSummaryText: String?")
        brush_end = expanded.index("private struct AtriaExpandedChartPreparedOverlay", brush_start)
        brush_source = expanded[brush_start:brush_end]
        for forbidden in [
            "points.filter",
            "inside.map",
            "values.reduce",
        ]:
            assert_not_contains(self, brush_source, forbidden)

    def test_behavior_insights_compute_from_snapshots_off_actor_path(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "let sourceSessions = cachedCanonicalSessions",
            "let journalEntries = cachedBehaviorJournalEntries",
            "private nonisolated static let behaviorCorrelationWindowDays = 90",
            "SessionStore.sortedBehaviorCorrelationSummaries(\n                SessionStore.makeBehaviorCorrelationSummaries(sessions: sourceSessions,",
            "let insights = SessionStore.deriveInsights(from: summaries)",
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
            "DispatchQueue.global(qos: .utility).async { [weak self, sourceSessions, journalEntries, rest, maxHR, metricDays, typedAnswers, generation] in",
            "SessionStore.sortedBehaviorCorrelationSummaries(\n                SessionStore.makeBehaviorCorrelationSummaries(sessions: sourceSessions,",
        ]:
            assert_contains(self, sessions, needle)

        recompute_start = sessions.index("func recomputeBehaviorInsights(")
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
        for needle in [
            "private(set) var behaviorInsightsRevision = 0",
            "self.behaviorInsightsRevision &+= 1",
            "@StateObject private var projectionStore: AtriaOverviewBehaviorJournalProjectionStore",
            "return projectionStore.state.model",
            "final class AtriaOverviewBehaviorJournalProjectionStore: ObservableObject",
            "store.$dashboardRevision.dropFirst()",
            "store.$behaviorCorrelationSummariesCache.dropFirst()",
            "store.$behaviorImpactSummariesCache.dropFirst()",
            "AtriaOverviewBehaviorJournalContent(model: displayModel)",
            ".equatable()",
            "private struct AtriaOverviewBehaviorJournalModel: Equatable",
            "guard next != state else { return false }",
            "summaries: Array(summaries.filter { $0.days > 0 }.prefix(3))",
            "private struct AtriaOverviewBehaviorJournalContent: View, Equatable",
            "AtriaJournalImpactStrip(summaries: model.summaries,",
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
            # 2026-07-08: "Links" (raw correlation count) renamed to plain
            # "Patterns", with "—" instead of "0" in the empty state.
            "glanceChip(title: \"Patterns\"",
            "glanceChip(title: \"Focus\"",
            "Journal impact glance. \\(taggedDays) logged days.",
            "behavior patterns",
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
            # 2026-07-08: the inner 'Impact' header was removed (it duplicated
            # the outer 'Impacts' card header — card-in-card de-dup).
            "GeometryReader { proxy in",
            "let center = width / 2",
            "summary.impactProgress",
            ".atriaInsetCard(tint: .cyan)",
        ]:
            assert_contains(self, sessions + journal_source, needle)
        content_start = journal_source.index("private struct AtriaOverviewBehaviorJournalContent")
        content_end = journal_source.index("private struct AtriaJournalImpactStrip", content_start)
        content_source = journal_source[content_start:content_end]
        assert_not_contains(self, content_source, "store.")
        assert_not_contains(self, content_source, ".filter {")
        assert_not_contains(self, content_source, ".prefix(")
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

    def test_live_heart_rate_zone_indicator_matches_workout_max_hr_bands(self):
        metrics = source(ROOT / "Atria" / "Atria" / "Metrics.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        hero = source(ROOT / "Atria" / "Atria" / "AtriaHeroConnectionSections.swift")

        for needle in [
            "struct HeartRateZone: Equatable, Identifiable",
            "static func heartRateZone(bpm: Int, rest: Int, max: Int) -> HeartRateZone?",
            "let rawReserveFraction = Double(bpm - rest) / Double(max - rest)",
            "let maxFraction = Double(bpm) / Double(max)",
            "case ..<0.50: index = 0",
            "case ..<0.60: index = 1",
            "case ..<0.70: index = 2",
            "case ..<0.80: index = 3",
            "case ..<0.90: index = 4",
            'let names = ["Rest", "Warm-up", "Fat burn", "Aerobic", "Anaerobic", "Max"]',
            "static func heartRateZoneTint(_ index: Int) -> Color",
        ]:
            assert_contains(self, metrics, needle)

        for needle in [
            "rest: initialLiveSessionDerived.rest",
            "maxHR: initialLiveSessionDerived.maxHR",
            "let zoneContext = currentPulseZoneContext()",
            "rest: zoneContext.rest",
            "maxHR: zoneContext.maxHR",
            "AtriaLiveTabAccessoryHost(pulseStore: model.pulseLiveStore,",
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
        live_accessory_router_end = home.index("private struct AtriaLiveWorkoutTabAccessory: View", live_accessory_start)
        live_accessory_router = home[live_accessory_start:live_accessory_router_end]
        assert_not_contains(self, live_accessory_router, "@ObservedObject")
        assert_contains(self, live_accessory_router, "AtriaLiveWorkoutTabAccessory(pulseStore: pulseStore,")
        assert_not_contains(self, live_accessory, "AtriaLiveStatusTabAccessory")

        workout_accessory_start = home.index("private struct AtriaLiveWorkoutTabAccessory: View", live_accessory_start)
        workout_accessory = home[workout_accessory_start:live_accessory_end]
        assert_contains(self, workout_accessory, "@ObservedObject var pulseStore")
        assert_not_contains(self, workout_accessory, "liveStore")
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
        match = re.search(
            r"private func sendCommand\(_ cmd: UInt8,\s*"
            r"_ data: \[UInt8\],\s*"
            r"mode: CommandWriteMode,\s*"
            r"explicitWorkoutHaptic: Bool = false,\s*"
            r"onboardingPairingPreflight: Bool = false\) -> Bool \{"
            r"(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        guard_index = body.find("guard Self.shouldAllowProtectedTransportCommand(")
        first_write_index = body.find("writeValue(")
        self.assertGreaterEqual(guard_index, 0)
        self.assertGreater(first_write_index, guard_index)
        assert_contains(self, body, "standard_hr_only_no_strap_writes")
        assert_contains(self, body, "standard_hr_only_write_blocked")
        assert_contains(self, text, "explicitWorkoutHaptic && command == Cmd.runHapticsPattern")
        assert_contains(self, text, "explicitWorkoutHaptic: true")
        # Direct CoreBluetooth writes are an explicit authority boundary, not a
        # count. A new write in an existing function or a new function must be
        # reviewed by name and must carry the appropriate owner/lease guards.
        declarations = list(re.finditer(
            r"\b(?:private\s+)?func\s+([A-Za-z0-9_]+)\s*\(",
            text,
        ))
        direct_write_authorities = set()
        for write in re.finditer(r"\bwriteValue\s*\(", text):
            prior = [item for item in declarations if item.start() < write.start()]
            self.assertTrue(prior, "every direct BLE write must belong to a named function")
            direct_write_authorities.add(prior[-1].group(1))
        self.assertEqual(
            {
                "sendCommand",
                "sendMotionHandshakeSingleR10ActivationIfReady",
                "sendMotionHandshakeR10IMUSequenceIfReady",
                "sendProtectedR10ResponseEventDataSequenceIfReady",
                "sendProtectedR10ActivationNowIfReady",
                "requestBoundedR10ActivationForSilentStream",
                "retryProtectedR10ShortBurstIfEligible",
                "stopWorkoutRawMotionIfConnected",
                "armWorkoutHistoricalMotionBankIfPossible",
                "scheduleGate4DailyBankRearmAfterHistoryStart",
                "stopWorkoutHistoricalMotionBankIfPossible",
                "scheduleGate4IMUOnlyProbeStop",
                "startGate4HistoricalIMUWindowIfRequested",
                "sendGate4OfficialGen4CompactMotionSequenceIfRequested",
                "sendWorkoutMotionActivationPair",
                "sendProprietaryBatteryRefreshCommand",
            },
            direct_write_authorities,
        )

        def function_block(name):
            blocks = swift_braced_blocks(
                text,
                [rf"\b(?:private\s+)?func\s+{re.escape(name)}\s*\("],
            )
            self.assertEqual(1, len(blocks), f"expected one {name} implementation")
            return blocks[0][1]

        guarded_authorities = {
            "sendMotionHandshakeSingleR10ActivationIfReady": [
                "!readOnlyHistoryCaptureRequested",
                "diagnostic.sendSingleR10Activation",
            ],
            "sendMotionHandshakeR10IMUSequenceIfReady": [
                "!readOnlyHistoryCaptureRequested",
                "diagnostic.sendR10IMUSequence",
            ],
            "sendProtectedR10ResponseEventDataSequenceIfReady": [
                "!readOnlyHistoryCaptureRequested",
                "protectedR10ResponseEventDataProofIsActive",
                "shouldArmHighFrequencyMotion(",
            ],
            "sendProtectedR10ActivationNowIfReady": [
                "!readOnlyHistoryCaptureRequested",
                "standardHROnlyMode",
                "cleanProofActive",
            ],
            "requestBoundedR10ActivationForSilentStream": [
                "!readOnlyHistoryCaptureRequested",
                "if standardHROnlyMode",
                "sendProtectedR10ActivationIfReady()",
            ],
            "retryProtectedR10ShortBurstIfEligible": [
                "!readOnlyHistoryCaptureRequested",
                "shouldRetryProtectedR10ShortBurst(",
            ],
            "armWorkoutHistoricalMotionBankIfPossible": [
                "!historyOnlyProbeMode",
                "!offlineHistoricalSyncInProgress",
                "historicalMotionBankIsArmedForCurrentConnection(",
            ],
            "scheduleGate4DailyBankRearmAfterHistoryStart": [
                "offlineHistoricalSyncGeneration == generation",
                "gate4DailyBankRearmGeneration == generation",
            ],
            "startGate4HistoricalIMUWindowIfRequested": [
                "gate4HistoricalIMUWindowProbeRequested",
                "!gate4HistoricalIMUWindowIssued",
            ],
            "sendGate4OfficialGen4CompactMotionSequenceIfRequested": [
                "gate4PassiveReconnectProbeRequested",
                "gate4RealtimeKeepaliveProbeRequested",
                "gate4OfficialGen4CompactMotionProbeRequested",
            ],
            "sendWorkoutMotionActivationPair": [
                "!readOnlyHistoryCaptureRequested",
                "!historyOnlyProbeMode",
                "!offlineHistoricalSyncInProgress",
                "workoutMotionOwnerStartedAt != nil",
                "shouldArmHighFrequencyMotion(",
            ],
            "sendProprietaryBatteryRefreshCommand": [
                "!readOnlyHistoryCaptureRequested",
                "proprietaryBatteryRefreshPhase == .discoveringResponse",
                "proprietaryBatteryResponseCharacteristic?.isNotifying == true",
            ],
        }
        for authority, required_tokens in guarded_authorities.items():
            authority_body = function_block(authority)
            for required in required_tokens:
                assert_contains(self, authority_body, required)
        assert_contains(self, text, "--atria-confirm-response-event-data-profile")
        assert_contains(self, text, "--atria-confirm-r10-imu-command-sequence")
        assert_contains(self, text, "Cmd.toggleIMUMode, 0x01")
        assert_contains(self, text, "sendProtectedR10ActivationIfReady()")
        assert_contains(self, text, "Cmd.sendR10R11Realtime, 0x01")
        assert_contains(self, text, "if standardHROnlyMode {")
        assert_contains(self, text, "status=repair_scheduled mode=protected")
        assert_contains(self, text, "shouldRetryProtectedR10ShortBurst(")
        assert_contains(self, text, "shortBurstRetryConnectionAt")
        assert_contains(self, text, "one_pair_same_connection_no_cccd_no_reconnect")
        self.assertEqual(body.count("writeValue("), 2)

    def test_realtime_retry_accepts_any_current_link_transport_evidence(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "if realtimeRRStreamIsAlive || rawHRProvesCurrentLink || r10ProvesCurrentLink",
            "reason=transport_alive",
            "reason=no_rr_or_realtime_stream",
            "lastRawHRNotificationAt.map { $0 >= r10EvidenceEpoch }",
            "r10FrameProvesCurrentArm(",
            "standard_hr_frames=%d realtime_frames=%d standard_rr=%d realtime_rr=%d",
            "private var realtimeRRStreamIsAlive: Bool",
            "dbgRealtimeFrames > 0 || decodedStandardRRValues > 0 || decodedRealtimeRRValues > 0",
        ]:
            assert_contains(self, text, needle)
        assert_not_contains(self, text, "realtimeStreamIsAlive")

        match = re.search(r"private var realtimeRRStreamIsAlive: Bool \{(?P<body>.*?)\n    \}", text, re.S)
        self.assertIsNotNone(match)
        body = match.group("body")
        assert_not_contains(self, body, "standardHRFrames")
        assert_not_contains(self, body, "heartRate")

    def test_offline_historical_sync_is_bounded_standard_hr_exception(self):
        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEHistoryTransportPhaseFence.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEHistoricalRecoveryPolicy.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLEEvidence.swift")
        )
        history_pipeline = source(ROOT / "Atria" / "Atria" / "AtriaWhoop4HistoryArchivePipeline.swift")
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
            "func requestOfflineHistoricalSyncIfNeeded(",
            "reason: String,",
            "force: Bool = false,",
            "allowConnectedAutomaticHandoff: Bool = false",
            "private func startOfflineHistoricalSync(reason: String, force: Bool)",
            "historyOnlyProbeEnabled = true",
            "historyTransportPhaseFence.activate(",
            "generation: offlineHistoricalSyncGeneration",
            "historyClockSyncEnabled = true",
            "historyAck skip=archive_persist_failed",
            "historyAck status=queued",
            "historyDurableFlushInFlight",
            "historyDrain.ackCompleted(",
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
            "static func productionHistoricalRecoveryInitCommands() -> [[UInt8]]",
            "historyInitSweepCommands = Self.productionHistoricalRecoveryInitCommands()",
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
            "static let rangeLossBackfillPending",
            "private func markRangeLossBackfillRequired(reason: String)",
            "let alreadyPending = defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)",
            "if !alreadyPending || defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) == nil",
            "already_pending=%d",
            "private func preserveLongWearRangeLossRecovery(reason: String)",
            "let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()",
            "static func shouldRestoreProtectedLongWearRadioInBackground(",
            "activeExplicitWorkout: activeExplicitWorkout",
            "static func isBLEContinuityRelevant(",
            "wait_continuity_owner",
            "let backfillReason = activeExplicitWorkout",
            '? "explicit_workout_range_loss"',
            "? \"strap_low_battery_broadcast_off\"",
            ": \"long_wear_range_loss\"",
            "static func shouldDeferOfflineSyncForExplicitWorkout(",
            'defaults.set("deferred_explicit_workout", forKey: OfflineSyncDefaults.lastStatus)',
            "static func rangeLossBackfillCanClear(newRows: Int) -> Bool",
            "private func scheduleRangeLossBackfillIfNeeded(reason: String)",
            "private func scheduleRangeLossBackfillRetry(reason: String)",
            "private func scheduleStaleArmedRangeLossBackfillReconciliation(reason: String,",
            'let clearableStatuses = ["armed", "archived", "archive_metric_ready", "throttled", "no_rows"]',
            "scheduleStaleArmedRangeLossBackfillReconciliation(reason: \"long_wear_supervisor_tick\",",
            "stale_armed_retained",
            "action=retry_until_new_rows",
            "rangeLossBackfillRetryInterval",
            "rangeLossBackfillReadyForceInterval",
            "private var offlineHistoricalSyncStartRows = 0",
            "offlineHistoricalSyncStartRows = historicalArchiveRows",
            "let newRows = max(0, rows - offlineHistoricalSyncStartRows)",
            "new_rows=%d",
            "private func finalizeOfflineHistoricalSyncAfterLiveRestoration(",
            "terminalAndLiveRestored: Bool",
            "lastAcceptedHRAt.map { $0 >= connectedAt }",
            "awaiting_post_history_live_sample",
            "offline_sync_live_restore_retry_",
            "offline_sync_stale_peripheral",
            "ATRIADBG offline_sync status=pending_range_loss_backfill",
            "ATRIADBG offline_sync status=requesting_range_loss_backfill",
            "stale_force=%d",
            "ready_force=%d",
            "let forceStaleBackfill = (!protectedLiveStream || automaticConnectedHandoff)",
            "&& shouldForceStaleRangeLossBackfill(now: now)",
            "let forceReadyBackfill = (!protectedLiveStream || automaticConnectedHandoff)",
            "&& shouldForceReadyRangeLossBackfill(now: now)",
            "let forceBackfill = automaticConnectedHandoff || forceStaleBackfill || forceReadyBackfill",
            "forceStaleBackfill ? \"force_stale_backfill\"",
            "force_ready_backfill",
            "defer_live_stream",
            "let syncStarted = requestOfflineHistoricalSyncIfNeeded(",
            "allowConnectedAutomaticHandoff: automaticConnectedHandoff",
            "ATRIADBG offline_sync status=range_loss_backfill_request_result",
            "started=%d pending=%d force=%d action=%@",
            "private func rangeLossBackfillRetryDelay(now: Date = Date()) -> TimeInterval",
            "ATRIADBG offline_sync status=retry_scheduled",
            "private func shouldForceReadyRangeLossBackfill(now: Date = Date()) -> Bool",
            "ordinaryInterval: offlineHistoricalSyncMinimumInterval(for: reason),",
            "private func offlineHistoricalSyncMinimumInterval(for reason: String) -> TimeInterval",
            "return rangeLossBackfillRetryInterval",
            "private func shouldForceStaleRangeLossBackfill(now: Date = Date()) -> Bool",
            "protectedLiveStream ? \"defer_live_stream\" : \"sync_when_available\"",
            "static func offlineSyncEvidence() -> String",
            "offline_range_loss_backfill_pending",
            "private func finishOfflineHistoricalSync(",
            "generation: UInt64,",
            "resumePendingSync: Bool = true",
            "generation == offlineHistoricalSyncGeneration",
            "let restoredStandardHROnlyMode = Self.standardHROnlyModeAfterOfflineSync(",
            "applyStandardHROnly(enabled: restoredStandardHROnlyMode,",
            "persist: false,",
            "reason: \"offline_sync_complete_preserve_live_radio\")",
            "action=withhold_completion_and_gap_clear",
            '"publish_after_fresh_hr"',
        ]:
            assert_contains(self, ble, needle)

        # Normalize the production convenience/designated initializer pair so
        # this ordering audit continues to inspect the designated body.
        ble = ble.replace("init(startsBluetooth: Bool) {", "override init() {")

        assert_not_contains(
            self,
            ble,
            "if !historyInitSweepCommands.isEmpty {\n            historySkipDataRangeRequest = true\n        }",
        )

        init_body = re.search(r"override init\(\) \{(?P<body>.*?)\n    \}", ble, re.S)
        self.assertIsNotNone(init_body)
        body = init_body.group("body")
        self.assertIn("guard startsBluetooth else", body)
        early_config = body.find("applyEarlyHistoricalLaunchConfiguration(arguments: arguments)")
        central_create = body.find("central = CBCentralManager")
        self.assertGreaterEqual(early_config, 0)
        self.assertGreater(central_create, early_config)

        for needle in [
            "historicalRecoverySucceeded = await ble",
            ".requestOfflineHistoricalSyncAwaitingCompletion(",
            "admitAutomaticConnectedHandoffIfEligible: true",
            'if reason == "bg_processing"',
            "store.performBackgroundMaintenanceAsynchronously(reason: reason) { succeeded in",
            "case .background:",
            "ble.handleSceneBackgroundTransition(reason: \"scene_background\",",
            "rest: store.baseline.restingInt ?? 60",
            "maxHR: store.profile.maxHR",
            "case .inactive:",
            "ble.flushLifecycleRealtimeState(reason: \"scene_inactive_deferred_checkpoint\")",
            "AtriaSceneResumePolicy.inactiveCheckpointDelay",
            "handleBackgroundTask",
            "performSceneBackgroundMaintenance",
            "historicalSyncSucceeded = await ble",
            "requestOfflineHistoricalSyncAwaitingCompletion(",
            "offline_sync_required=%d",
            "offline_sync_succeeded=%d",
        ]:
            assert_contains(self, app, needle)

        bg_processing = re.search(
            r'if reason == "bg_processing" \{(?P<body>.*?)\n            \}',
            app,
            re.S,
        )
        self.assertIsNotNone(bg_processing)
        bg_processing_body = bg_processing.group("body")
        assert_contains(
            self,
            bg_processing_body,
            "admitAutomaticConnectedHandoffIfEligible: true",
        )

        inactive_case = re.search(
            r"case \.inactive:(?P<body>.*?)case \.active:",
            app,
            re.S,
        )
        self.assertIsNotNone(inactive_case)
        self.assertNotIn("handleUnattendedMode", inactive_case.group("body"))
        self.assertLess(
            inactive_case.group("body").index("Task.sleep"),
            inactive_case.group("body").index("flushLifecycleRealtimeState"),
        )

        scene_background = re.search(
            r"private func performSceneBackgroundMaintenance\(reason: String\) \{(?P<body>.*?)\n    \}",
            app,
            re.S,
        )
        self.assertIsNotNone(scene_background)
        scene_background_body = scene_background.group("body")
        assert_contains(self, scene_background_body, "ble.flushLifecycleRealtimeState(reason: reason)")
        assert_contains(self, scene_background_body, ".requestOfflineHistoricalSyncAwaitingCompletion(")
        assert_contains(self, scene_background_body, "store.awaitRecoveredDataPublication(")
        assert_contains(self, scene_background_body, "historicalSyncFinished = true")
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
            r"func handleSceneBackgroundTransition\((?P<args>.*?)\) \{(?P<body>.*?)\n    \}",
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
            r"func requestOfflineHistoricalSyncIfNeeded\(\s*"
            r"reason: String,\s*"
            r"force: Bool = false,\s*"
            r"allowConnectedAutomaticHandoff: Bool = false,\s*"
            r"freshOwnerCutoverCompleted: Bool = false,\s*"
            r"explicitResearchRequest: Bool = false,\s*"
            r"explicitPostWorkoutBankRequest: Bool = false\s*"
            r"\) -> Bool \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(request_sync)
        request_body = request_sync.group("body")
        live_defer_index = request_body.find("shouldProtectLiveStreamForOfflineSync(now: now)")
        start_index = request_body.find("return startOfflineHistoricalSync(")
        self.assertGreaterEqual(live_defer_index, 0)
        self.assertGreater(start_index, live_defer_index)
        assert_contains(self, request_body, "return false")
        self.assertEqual(
            request_body.count("OfflineSyncDefaults.rangeLossBackfillStartedAt"),
            1,
            "the request gate may read the legacy timestamp for migration but must not write it",
        )
        assert_contains(self, request_body, "backfillStartedAtUnix: defaults.double(")
        self.assertNotIn("defaults.set(false, forKey: OfflineSyncDefaults.rangeLossBackfillPending)", request_body)
        self.assertNotIn("assignIfChanged(\\.rangeLossBackfillPending, false)", request_body)

        finish_sync = re.search(
            r"private func finishOfflineHistoricalSync\(\s*"
            r"reason: String,\s*"
            r"generation: UInt64,\s*"
            r"resumePendingSync: Bool = true\s*"
            r"\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(finish_sync)
        finish_body = finish_sync.group("body")
        assert_contains(self, finish_body, "awaiting_post_history_live_sample")
        assert_contains(self, finish_body, "acceptedAt > restorationRequestedAt")
        assert_contains(self, finish_body, "finalizeOfflineHistoricalSyncAfterLiveRestoration(")
        self.assertNotIn("rangeLossBackfillPending, false", finish_body)
        self.assertNotIn("reconcileRangeLossBackfillPendingWithArchive", finish_body)
        self.assertEqual(
            finish_body.count("cancelPeripheralConnection("),
            1,
            "live restoration may issue only one bounded reconnect repair",
        )
        assert_contains(self, finish_body, "if !reconnectRequested,")
        assert_contains(self, finish_body, "Date().timeIntervalSince(restorationRequestedAt) >= 10")
        assert_contains(self, finish_body, 'reason: "offline_sync_live_restore_rebuild_\\(reason)"')

        finalize_sync = re.search(
            r"private func finalizeOfflineHistoricalSyncAfterLiveRestoration\((?P<args>.*?)\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(finalize_sync)
        finalize_body = finalize_sync.group("body")
        assert_contains(self, finalize_body, "terminalAndLiveRestored")
        assert_contains(self, finalize_body, "&& reconcileRangeLossBackfillPendingWithArchive(")
        assert_contains(self, finalize_body, "scheduleRangeLossBackfillRetry(reason: reason)")

        start_sync = re.search(
            r"private func startOfflineHistoricalSync\(reason: String, force: Bool\) \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(start_sync)
        start_body = start_sync.group("body")
        assert_contains(self, start_body, "_ = startOfflineHistoricalSync(reason: reason,")
        self.assertNotIn("cancelPeripheralConnection", start_body)
        self.assertNotIn("offline_sync_force_while_connecting", ble)
        assert_contains(
            self,
            ble,
            "detail=transaction_boundary_reconnect_in_flight action=no_attempt_no_lease_no_cancel",
        )

        protect_helper = re.search(
            r"private func shouldProtectLiveStreamForOfflineSync\(now: Date = Date\(\)\) -> Bool \{(?P<body>.*?)\n    \}",
            ble,
            re.S,
        )
        self.assertIsNotNone(protect_helper)
        protect_body = protect_helper.group("body")
        for needle in [
            "Self.shouldProtectConnectedLinkForOfflineSync(",
            "connected: peripheral?.state == .connected",
            "connectedAt: connectedAt",
            "hasContact: hasContact",
            "acceptedSampleCount: session.count",
            "lastAcceptedHRAt: lastAcceptedHRAt",
        ]:
            assert_contains(self, protect_body, needle)

        for needle in [
            "Self.shouldDeferAutomaticOfflineSyncForConnectedLink(",
            "explicitUserRequest: explicitHistoricalRequest",
            "deferred_connected_live_link",
            "preserve_realtime_until_natural_disconnect",
        ]:
            assert_contains(self, ble, needle)

        for needle in [
            "AtriaMissedDataBanner(protectsLiveStream: missedDataBackfillIsDeferredForLiveStream)",
            "private var missedDataBackfillIsDeferredForLiveStream: Bool",
            "model.statusStore.state.status == .connected",
            "&& model.coreLiveStore.state.sessionSampleCount > 0",
            "Text(protectsLiveStream ? \"Saved data protected\" : \"Sync ready\")",
            "Live HR stays protected while Atria waits for the best sync moment.",
            "Pull missed strap data when you are ready.",
            "missedDataBannerDismissedUntil = Date().addingTimeInterval(60 * 60)",
            "Button(action: onSync)",
            "Sync missed data now; live heart rate may pause during recovery",
            "Check strap for missed data",
            ".atriaCardAction(prominent: false, tint: .cyan)",
            ".atriaCardAction(prominent: false, tint: .secondary)",
            "Text(protectsLiveStream ? \"Live protected\" : \"Check strap history\")",
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

        for needle in [
            "let currentSessionUsable = (correctedUnix ?? unix) > 0",
            "let metricUsable = HistoricalArchive.metricLayoutValidated(layoutVersion)",
            "currentSessionUsable: currentSessionUsable",
            "metricUsable: metricUsable",
            "metricUsable: false",
            'usabilityReason = "verified_v24_heart_rate"',
            'usabilityReason = "decoded_layout_not_captured_validated"',
            'usabilityReason = "historical_clock_not_verified"',
        ]:
            assert_contains(self, history_pipeline, needle)

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
            "private static let candidateEndians: [Endian] = [.little, .big]",
            "private struct CandidateSummary",
            "return decodeBody(bytes: payload, bodyStart: 1)",
            "private static func decodeBody(bytes: [UInt8], bodyStart: Int) -> DecodeResult?",
            "guard let result = summarizeCandidate(in: bytes,",
            "let samples = samples(in: bytes,",
            "private static func summarizeCandidate(in bytes: [UInt8],",
            "return CandidateSummary(offset: offset,",
        ]:
            assert_contains(self, decoder, needle)
        assert_not_contains(self, decoder, "Array(payload.dropFirst())")
        assert_not_contains(self, decoder, "let samples = samples(in: body")
        assert_not_contains(self, decoder, "let magnitudes = samples.map(\\.magnitudeG)")
        assert_not_contains(self, decoder, "magnitudes.filter")

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
            "AtriaExperimentalSensorCopy.bloodOxygenFootnote(",
            "return \"Not available yet. Atria does not estimate a percentage.\"",
            "value: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable",
            "AtriaExperimentalSensorCopy.skinTemperatureFootnote(",
            "return \"Not available yet. Atria does not show raw sensor data as wrist temperature.\"",
            "@State private var showResearchInfo = false",
            ".accessibilityLabel(\"Experimental sensor info\")",
            "AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,",
            "private struct AtriaResearchSignalInfoSheet: View",
            "Atria does not show an SpO2 percentage until quality checks pass.",
            "never core temperature",
            "Experimental, local, and not medical advice. SpO2 and temperature are not written to HealthKit.",
            "targetMetric: nil",
            "footnote: respiratory.detail",
            "AtriaExperimentalRespiratoryRatePresentation.resolve(",
            "Skin temperature is only a sleep-baseline change.",
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
            "static var validatedSkinTemperatureDecoderAvailable: Bool {",
            "productionSkinTemperatureDecoder != nil",
            "static let productionSkinTemperatureDecoder: SkinTemperatureDecoderIdentity? = nil",
            "struct DecodedSkinTemperatureCelsius: Codable, Equatable, Sendable",
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
            "struct GenerationGate",
            "mutating func acceptsForCandidateCounting(_ summary: Summary) -> Bool",
            "if summary.source == .metadata {",
            "authoritativeGeneration = summary.modelGeneration",
            "guard summary.hasSensorCandidate else { return false }",
        ]:
            assert_contains(self, probe, needle)

        for needle in [
            "case strap4",
            "case .strap4: return \"Strap 4.0\"",
            "case .strap4Class: return \"Strap\"",
            "private var researchProbeGenerationGate = AtriaResearchProbe.GenerationGate()",
            "guard researchProbeGenerationGate.acceptsForCandidateCounting(summary),",
            "supportsGenerationSpecificDecode,",
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
            "var decodedSkinTemperatureCelsius: [AtriaResearchProbe.DecodedSkinTemperatureCelsius]? = nil",
            "let finalizedSleepTemperatureSessions: [SkinTemperatureSession]",
            "finalizedSleepTemperatureSessions = sleepTemperatureSessions.filter { $0.id != activeSessionID }",
            "candidateValues: sleepTemperatureSessions.reduce(0) { $0 + $1.values })",
            "private struct SkinTemperatureSession",
            "private static func sleepTemperatureSessions(from sessions: [SavedSession]) -> [SkinTemperatureSession]",
            "return SkinTemperatureSession(id: session.id,",
            "private static func makeSkinTemperatureDeviationSummary(sleepTemperatureSessions: [SkinTemperatureSession],",
            ".filter { $0.sleepWakeResearchState == \"sleep_research\" }",
            "meanCelsius: samples.reduce(0) { $0 + $1.celsius }",
            "guard baseline.count >= 3 else",
            "latest.meanCelsius - baselineMean",
            "let samples = session.decodedSkinTemperatureCelsius?.filter(\\.isAggregationEligible)",
            "guard AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable else { return nil }",
        ]:
            assert_contains(self, sessions, needle)
        assert_not_contains(self, sessions, "Double(sum) / Double(count) / 100.0")

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
            # 2026-07-08: recompute moved off-main + coalesced (compute-cadence pass);
            # markers still captured from the local cachedResearchManeuverMarkers,
            # local-research-only, built off the sessions snapshot.
            "let markers = cachedResearchManeuverMarkers",
            "ResearchManeuverProbeCorrelationSummary(markers: markers, sessions: sessionsSnapshot)",
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
            "AtriaResearchManeuverMarkerCard(markers: state.markers",
            "correlationSummary: state.correlationSummary",
            "private struct AtriaResearchManeuverMarkerCard: View, Equatable",
            "private static let relativeMarkerFormatter: RelativeDateTimeFormatter",
            "formatter.unitsStyle = .short",
            "AtriaPanelSectionHeader(title: \"Probe markers\", subtitle: \"\")",
            "ForEach(ResearchManeuverMarker.Kind.allCases.filter { $0 != .breathHold })",
            ".atriaCardAction(prominent: false, tint: .teal)",
            "AtriaMetricTile(label: \"Probe match\"",
            "state: markers.isEmpty ? .learning : .research",
            "state: correlationSummary.matchedMarkers > 0 ? .research : .learning",
            "Markers stay on device and help compare probe timing.",
            "Self.relativeMarkerFormatter.localizedString(for: marker.timestamp, relativeTo: Date())",
        ]:
            assert_contains(self, collection, needle)

        assert_not_contains(
            self,
            collection,
            "ForEach(ResearchManeuverMarker.Kind.allCases) { kind in",
        )

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
            "Wrist temperature signal",
            "Relative wrist-skin deviation only; no core temperature or Health export.",
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
        text = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
        )

        for needle in [
            "static let protectedLongWearMigrated",
            "static let strapStepFullProtocolMigrated",
            "static let stableR10TransportMigrated",
            "static let standardHROnlyUserSelected",
            "defaults.set(true, forKey: CaptureDefaults.protectedLongWearMigrated)",
            "defaults.set(true, forKey: CaptureDefaults.strapStepFullProtocolMigrated)",
            "defaults.set(true, forKey: CaptureDefaults.stableR10TransportMigrated)",
            "defaults.set(true, forKey: LongWearDefaults.enabled)",
            "defaults.set(true, forKey: RadioDefaults.standardHROnly)",
            "longWearModeEnabled = true",
            "standardHROnlyMode = true",
            "standardHROnlyEnabled = true",
            "recordRadioMode(\"protected_r10_minimal\", reason: \"stable_hr_r10_default\")",
            "shouldUseStandardHROnlyInProtectedBackground(",
            "return streamSuppressed || persistedStandardHROnly",
            "stable_hr_r10_migration",
            "phone_step_fallback=0",
            "mode=protected_r10_minimal",
            "long_wear_default=1",
            "strap_steps_background=1",
            "offline_sync_default=1",
        ]:
            assert_contains(self, text, needle)

    def test_harness_classifies_untrusted_developer_profile_launch(self):
        text = source(ROOT / "live_device_debug.sh")

        for needle in [
            "launch_output_lines = []",
            "launch_output_lines.append(line)",
            '"because the device was not, or could not be, unlocked" in launch_output',
            "HARNESS_ERROR=device_locked",
            "HARNESS_NEXT_ACTION=unlock_device_leave_on_home_screen_then_retry",
            "\"invalid code signature\" in launch_output",
            "\"profile has not been explicitly trusted\" in launch_output",
            "HARNESS_ERROR=developer_profile_not_trusted",
            "HARNESS_NEXT_ACTION=trust_developer_profile_in_ios_settings_then_retry",
        ]:
            assert_contains(self, text, needle)

    def test_harness_radio_mode_flags_are_mutually_exclusive(self):
        text = source(ROOT / "live_device_debug.sh")

        for option in ["--standard-hr-only)", "--long-wear-mode)"]:
            block = text[text.index(option) : text.index(";;", text.index(option))]
            assert_contains(self, block, "full_protocol_mode=0")

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
        cutover_start = body.index("if self.readOnlyHistoryCaptureRequested")
        normal_restore_start = body.index(
            "self.protectedR10InitialProfilePeripheralID",
            cutover_start,
        )
        normal_restore_body = body[:cutover_start] + body[normal_restore_start:]
        self.assertNotIn(
            "central.cancelPeripheralConnection(restoredPeripheral)",
            normal_restore_body,
        )
        self.assertNotIn("full_protocol_fresh_scan", body)

    def test_long_wear_keepalive_survives_app_switch(self):
        text = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaBLESchema.swift")
        )
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")

        for needle in [
            "enum KeepaliveDefaults",
            "static let armedAt = \"atria.keepalive.armedAt\"",
            "static let tickStartedAt = \"atria.keepalive.tickStartedAt\"",
            "static let lastTickAt = \"atria.keepalive.lastTickAt\"",
            "static let lastPeripheralState = \"atria.keepalive.lastPeripheralState\"",
            "private func ensureForegroundKeepaliveWatchdog(reason: String)",
            "private func runForegroundKeepaliveTick(",
            "private func resetHeartRateNotifyIfNeeded(peripheral: CBPeripheral,",
            "if characteristic.isNotifying {",
            "ATRIADBG ble_notify_reassert status=preserved reason=%@ action=read_or_observe_active",
            "requestHeartRateNotificationEnableIfNeeded(",
            "private func elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: String)",
            "private func restoreProtectedLongWearRadioIfNeeded(reason: String)",
            "sendProtectedR10ActivationIfReady()",
            "preserve_protected_r10_no_full_protocol_escalation",
            "private func rediscoverFullProtocolServicesIfConnected(reason: String)",
            "peripheral.discoverServices(discoveryServicesForCurrentMode)",
            "ATRIADBG radio_mode full_protocol_discovery status=requested",
            "ensureForegroundKeepaliveWatchdog(reason: \"scene_active\")",
            "startLongWearMode(rest: rest, maxHR: maxHR, reason: \"scene_active_foreground\")",
            "keep_supervisor_and_keepalive_armed",
            "elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: \"scene_active_interactive\")",
            "ensureForegroundKeepaliveWatchdog(reason: reason)",
            "restoreProtectedLongWearRadioIfNeeded(reason: reason)",
            "foreground_keepalive armed=1",
            "foreground_keepalive status=silent",
            "guard foregroundKeepaliveTask == nil else {",
            "action=keep_existing_owner",
            "defaults.set(armedAt.timeIntervalSince1970, forKey: KeepaliveDefaults.armedAt)",
            "defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.tickStartedAt)",
            "defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastTickAt)",
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
        notify_reset_start = text.index("private func resetHeartRateNotifyIfNeeded(")
        notify_reset_end = text.index("// MARK: - Duty cycle", notify_reset_start)
        notify_reset_body = text[notify_reset_start:notify_reset_end]
        assert_not_contains(self, notify_reset_body, "setNotifyValue(false")

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
            "ATRIADBG scene_phase phase=%@ reason=%@",
        ]:
            assert_contains(self, app, needle)
        assert_not_contains(self, app, "defaults.synchronize()")

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
            r"func handleSceneBackgroundTransition\((?P<args>.*?)\) \{(?P<body>.*?)\n    \}",
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
        assert_contains(self, keepalive_body, "let governedInterval = checkInterval * effectiveThermalCadenceMultiplier")
        assert_contains(self, keepalive_body, "try? await Task.sleep(for: .seconds(governedInterval))")
        assert_contains(self, keepalive_body, "foregroundKeepaliveLastRawNotifications = sampleDiagnostics.rawNotifications")
        assert_not_contains(self, keepalive_body, "Timer(timeInterval:")
        assert_not_contains(self, keepalive_body, "DispatchSource.makeTimerSource")
        assert_not_contains(self, keepalive_body, "scheduleForegroundKeepaliveProofProbes")
        for needle in [
            "let currentRawNotifications = sampleDiagnostics.rawNotifications",
            "UIApplication.shared.applicationState == .active",
            "foreground_keepalive status=sample_counter_stalled",
            "forceHardReconnectForPacketStall(peripheral: peripheral,",
            "cancelPeripheralConnection(target,",
            "reason: \"\\(scheduledReason)_rebuild\"",
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
            "effectiveBatteryLevel > Self.lowBatteryWarningThreshold",
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
        self.assertNotIn("guard foregroundInteractiveMode, longWearModeEnabled", keepalive_body)

        keepalive_tick = re.search(
            r"private func runForegroundKeepaliveTick\((?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(keepalive_tick)
        keepalive_tick_body = keepalive_tick.group("body")
        assert_contains(self, keepalive_tick_body, "let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()")
        assert_contains(self, keepalive_tick_body, "guard Self.isBLEContinuityRelevant(")
        assert_contains(self, keepalive_tick_body, "longWearEnabled: longWearModeEnabled")
        assert_contains(self, keepalive_tick_body, "activeExplicitWorkout: activeExplicitWorkout")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"disabled\", forKey: KeepaliveDefaults.lastStatus)")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"wait_continuity_owner\", forKey: KeepaliveDefaults.lastAction)")
        assert_contains(self, keepalive_tick_body, "guard peripheral.state == .connected else {")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"peripheral_not_connected\", forKey: KeepaliveDefaults.lastStatus)")
        assert_contains(self, keepalive_tick_body, "defaults.set(\"reconnect_known_strap\", forKey: KeepaliveDefaults.lastAction)")
        assert_contains(self, keepalive_tick_body, "let continuityDisposition = Self.heartRateContinuityRecoveryDisposition(")
        assert_contains(self, keepalive_tick_body, "case .enableHeartRateNotifications:")
        assert_contains(self, keepalive_tick_body, "requestHeartRateNotificationEnableIfNeeded(")
        assert_contains(self, keepalive_tick_body, "let hasSeenPacket = lastRawHRNotificationAt != nil")
        assert_contains(self, keepalive_tick_body, "let effectiveSilenceTimeout = hasSeenPacket ? silenceTimeout : initialSilenceTimeout")
        assert_contains(self, keepalive_tick_body, "let reconnectWindow = hasSeenPacket ? silenceTimeout : initialReconnectWindow")

        long_wear_supervisor = re.search(
            r"private func scheduleLongWearSupervisor\(config: LongWearSupervisorConfig\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(long_wear_supervisor)
        assert_not_contains(self, long_wear_supervisor.group("body"), "runForegroundKeepaliveTick(")

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
            "standardSnapshot && !historyOnlyProbeMode",
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
            "let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()",
            "let shouldPreserveLongWearSession = Self.shouldPreserveSessionOnUnexpectedDisconnect(",
            "activeExplicitWorkout: activeExplicitWorkout",
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
            '"checkpointed_explicit_workout_continuity"',
            '"checkpointed_continuity"',
            "scheduleRangeLossBackfillIfNeeded(reason: \"did_connect\")",
            "scheduleRangeLossBackfillIfNeeded(reason: \"state_restore_connected\")",
            "reason: \"foreground_keepalive_all_gatt_silent_120s\"",
            "preserveLongWearRangeLossRecovery(reason: reason)",
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
        finish_index = body.find("let outcome = await finishSession(")
        reconnect_index = body.find("recordLinkAttempt(reason: \"did_disconnect_reconnect\"")
        self.assertGreaterEqual(preserve_index, 0)
        self.assertGreater(finish_index, preserve_index)
        self.assertGreater(reconnect_index, finish_index)

    def test_long_wear_auto_save_keeps_live_session_open(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        auto_save_start = text.index("private func runLongWearSupervisorAutoSave")
        auto_save_end = text.index("private func scheduleNoDataWatchdogIfNeeded", auto_save_start)
        body = text[auto_save_start:auto_save_end]
        assert_not_contains(self, body, "finishSession(label: label)")
        assert_contains(self, body, "let saved = snapshot")
        assert_contains(self, body, "let persisted = onSessionCheckpoint?(saved) == true")
        assert_contains(self, body, "reason: \"workout_auto_save_supervisor_checkpoint\"")
        assert_contains(self, body, "persistActiveSessionJournalIfNeeded(")
        assert_not_contains(self, body, "persistFinishedSession(")
        assert_contains(self, body, "mode=snapshot_keep_live")
        assert_contains(self, body, "return false")

        diagnostic_start = text.index("private func runLongWearSupervisorDiagnostic")
        diagnostic_end = text.index("private func runLongWearSupervisorAutoSave", diagnostic_start)
        diagnostic_body = text[diagnostic_start:diagnostic_end]
        assert_not_contains(self, diagnostic_body, "persistActiveSessionJournalIfNeeded")

    def test_live_retention_roll_is_not_limited_to_standard_hr_only(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        roll = re.search(
            r"private func rollLongWearLiveSessionIfOversized\(now: Date, reason: String\) -> Bool \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(roll)
        roll_body = roll.group("body")
        assert_contains(self, roll_body, "guard longWearModeEnabled else { return false }")
        assert_not_contains(self, roll_body, "standardHROnlyMode")

        event_checkpoint = re.search(
            r"private func checkpointFromLiveEventIfNeeded\(now: Date\) \{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(event_checkpoint)
        event_body = event_checkpoint.group("body")
        roll_index = event_body.find("rollLongWearLiveSessionIfOversized(now: now, reason: \"ble_event_retention_roll\")")
        snapshot_index = event_body.find("snapshotSession(label: label)")
        self.assertGreaterEqual(roll_index, 0)
        self.assertGreater(snapshot_index, roll_index)
        assert_contains(self, event_body, "lastCanonicalCheckpointAt = now")

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
            r"func flushLifecycleRealtimeState\(reason: String,[^{]+\{(?P<body>.*?)\n    \}",
            text,
            re.S,
        )
        self.assertIsNotNone(lifecycle)
        lifecycle_body = lifecycle.group("body")
        assert_contains(self, lifecycle_body, "flushSampleDiagnostics()")
        assert_contains(self, lifecycle_body, "flushActiveSessionJournal(reason: reason)")
        assert_contains(self, lifecycle_body, "finishWhenActiveJournalFlushSettles(reason: reason,")

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
        assert_contains(self, rr_journal_body, "Self.rrJournalMinimumInterval(")
        assert_contains(self, rr_journal_body, "now.timeIntervalSince(lastActiveJournalSaveAt) < minimumInterval")
        assert_contains(self, rr_journal_body, "persistActiveSessionJournalIfNeeded(reason: reason, force: true)")
        assert_contains(self, text, "min(75, max(30, baseInterval * max(1, cadenceMultiplier)))")

    def test_hrv_refresh_cadence_is_slow_outside_capture(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private nonisolated static let foregroundLiveHRVRefreshMinimumInterval: TimeInterval = 4 * 60 * 60",
            "private nonisolated static let backgroundLiveHRVRefreshMinimumInterval: TimeInterval = 4 * 60 * 60",
            "private nonisolated static let captureHRVRefreshMinimumInterval: TimeInterval = 1.5",
            "nonisolated static func hrvRefreshMinimumInterval(isRecording: Bool,",
            "if isRecording { return captureHRVRefreshMinimumInterval }",
            "nonisolated static func shouldRefreshHRVAnalysis(now: Date,",
            "nonisolated static func shouldAttemptHRVAnalysis(now: Date,",
            "guard cleanWindowSeconds >= 300 else { return false }",
            "normalWearHRVFailedAttemptRetryInterval: TimeInterval = 5 * 60",
            "lastNormalWearHRVAnalysisAttemptAt: Date?",
            "lastAttemptAt: isRecording\n                ? lastHRVAnalysisAttemptAt\n                : lastNormalWearHRVAnalysisAttemptAt",
            "Self.persistNormalWearHRVAnalysisAttemptDate(date)",
            "lastReadyAnalysisAt: lastHRVAnalysisAt",
            "hasReadySnapshot: latestReadyHRVSnapshot?.isReady == true || hrvSnapshot?.isReady == true",
        ]:
            assert_contains(self, text, needle)
        assert_not_contains(self, text, "private let liveHRVRefreshMinimumInterval: TimeInterval = 1.5")

        timer_start = text.find("captureTimer = Timer.scheduledTimer")
        self.assertGreater(timer_start, -1)
        timer_end = text.find("private func seedRecordingFromArchive", timer_start)
        self.assertGreater(timer_end, timer_start)
        timer_body = text[timer_start:timer_end]
        assert_contains(self, timer_body, "self.requestLiveHRVSnapshotRefresh(now: now,")
        assert_not_contains(self, timer_body, "self.refreshHRVSnapshot(now: now, logKind: \"hrv_timer\"")

    def test_long_wear_supervisor_reuses_one_session_analysis_per_tick(self):
        text = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        start = text.index("private func scheduleLongWearSupervisor")
        end = text.index("private func runLongWearSupervisorCheckpoint", start)
        supervisor = text[start:end]
        helpers_start = text.index("private func runLongWearSupervisorDiagnostic", end)
        helpers_end = text.index("private func scheduleNoDataWatchdogIfNeeded", helpers_start)
        helpers = text[helpers_start:helpers_end]

        for needle in [
            "private struct LongWearSessionAnalysis",
            "let diagnosticDue = !deferSessionAnalysis",
            "let autoSaveDue = !deferSessionAnalysis",
            "let sharedAnalysis: LongWearSessionAnalysis",
            "let snapshot = snapshotSession(label: config.label)",
            "readiness: snapshot?.workoutReadiness(rest: config.rest,",
            "analysis: sharedAnalysis",
        ]:
            assert_contains(self, text if needle == "private struct LongWearSessionAnalysis" else supervisor, needle)
        for needle in [
            "guard let saved = analysis.snapshot,",
            "guard let snapshot = analysis.snapshot,",
            "let savedReadiness = readiness",
        ]:
            assert_contains(self, helpers, needle)
        self.assertEqual(supervisor.count("snapshotSession(label:"), 1)
        assert_not_contains(self, helpers, "snapshotSession(label:")

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
            "let isUserAuthored = sleep.source.hasPrefix(\"manual_\") || sleep.source.hasPrefix(\"user_adjusted_\")",
            "guard sleep.source == \"validated_sleep_stages\"",
            "AtriaSleepStageIntegrity.validates(segments, for: sleep)",
            "else { return [] }",
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
            "private struct SavedSessionRespiratoryRateCacheKey: Hashable",
            "private final class SavedSessionRespiratoryRateCache: @unchecked Sendable",
            "private static let respiratoryRateCache = SavedSessionRespiratoryRateCache()",
            "let cacheKey = respiratoryRateCacheKey(rrPoints: rrPoints)",
            "let cached = Self.respiratoryRateCache.lookup(cacheKey)",
            "if cached.hit { return cached.value }",
            "Self.respiratoryRateCache.store(nil, for: cacheKey)",
            "Self.respiratoryRateCache.store(result, for: cacheKey)",
            "private func respiratoryRateCacheKey(rrPoints: [RRPoint]) -> SavedSessionRespiratoryRateCacheKey",
        ]:
            assert_contains(self, text + sessions, needle)
        assert_not_contains(self, text, "let respiratoryRate = session.respiratoryRate")
        assert_not_contains(self, text, "respiratoryRateExported: (session.respiratoryRate ?? 0) > 0")
        assert_not_contains(self, sessions, "let respiratoryRates = recent.compactMap(\\.respiratoryRate)")
        assert_not_contains(self, sessions, "let respiratoryRates = daySessions.compactMap(\\.respiratoryRate)")

    def test_saved_session_local_hrv_uses_cached_summary(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "private struct SavedSessionLocalHRVCacheKey: Hashable",
            "private struct SavedSessionLocalHRVSummary",
            "private final class SavedSessionLocalHRVCache: @unchecked Sendable",
            "private static let localHRVCache = SavedSessionLocalHRVCache()",
            "let summary = localHRVSummary()",
            "guard summary.windowCount >= 3 else { return nil }",
            "return summary.rmssd",
            "localHRVSummary().windowCount",
            "let cacheKey = localHRVCacheKey(rrPoints: rrPoints)",
            "if let cached = Self.localHRVCache.lookup(cacheKey)",
            "Self.localHRVCache.store(summary, for: cacheKey)",
            "private func localHRVCacheKey(rrPoints: [RRPoint]) -> SavedSessionLocalHRVCacheKey",
            "rrCount: rrPoints.count",
            "firstT: first?.t ?? 0",
            "lastT: last?.t ?? 0",
            "while lowerIndex < segment.endIndex",
            "while upperIndex < segment.endIndex",
        ]:
            assert_contains(self, sessions, needle)

        local_rmssd_start = sessions.index("var localRMSSD: Int?")
        local_rmssd_end = sessions.index("var localHRVWindowCount", local_rmssd_start)
        local_rmssd_source = sessions[local_rmssd_start:local_rmssd_end]
        assert_not_contains(self, local_rmssd_source, "segmentedLocalRMSSD()")

        window_count_start = sessions.index("var localHRVWindowCount: Int")
        window_count_end = sessions.index("func localRMSSD(in", window_count_start)
        window_count_source = sessions[window_count_start:window_count_end]
        assert_not_contains(self, window_count_source, "qualifiedLnRMSSDWindows().count")

    def test_trend_summaries_precompute_session_metric_rows(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "struct TrendSessionMetricRow",
            "let localRMSSD: Int?",
            "let referenceValidatedHRV: Int?",
            "let sleepRespiratoryRate: Double?",
            "let acceptedRestingHR: Int?",
            "func baselineLearningEvidence(rest: Int,\n                                  maxHR: Int,\n                                  calendar: Calendar,\n                                  localRMSSD: Int?)",
            "nonisolated static func trendSessionRows(sessions: [SavedSession]",
            "let localRMSSD = session.localRMSSD",
            "localRMSSD: localRMSSD",
            "localRMSSD: localRMSSD)",
            "referenceValidatedHRV: session.referenceValidatedHRV",
            "sleepRespiratoryRate: session.sleepRespiratoryRate(rest: rest,",
            "acceptedRestingHR: evidence.accepted ? evidence.value : nil",
            "let maximumWindowDays = TrendSummary.Window.allCases.map(\\.rawValue).max() ?? 0",
            "let trendSessions = sessions.filter { $0.start >= oldestCutoff }",
            "nonisolated static func dailyMetricTrendSummary(",
            "let byDay = Dictionary(",
            "let recentMetrics = byDay.values.sorted",
            "let hrvs = recentMetrics.compactMap(\\.hrv).filter { $0 > 0 }",
            "let respiratoryRates = recentMetrics.compactMap(\\.respiratoryRate).filter { $0 > 0 }",
            "anomalySource: \"frozen_daily_metrics\"",
            "return Self.dailyMetricTrendSummary(",
        ]:
            assert_contains(self, sessions, needle)

        for forbidden in [
            "fallbackRMSSD: session.localRMSSD",
            "respiratoryRate: session.sleepRespiratoryRate(rest: rest, maxHR: maxHR",
            "let hrvs = recent.compactMap(\\.localRMSSD)",
            "let validatedHRVs = recent.compactMap(\\.referenceValidatedHRV)",
            "let rhrs = recent.compactMap { session -> Int? in",
        ]:
            assert_not_contains(self, sessions, forbidden)

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
            "let activeCalories = activeCaloriesForSnapshot(rest: restingHeartRate,",
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

    def test_faceoff_payload_uses_bounded_recent_metrics(self):
        faceoff = source(ROOT / "Atria" / "Atria" / "AtriaFaceOff.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaFaceOffRHRTests.swift")

        make_start = faceoff.index("    static func makePayload(")
        make_end = faceoff.index("    static func url(for payload:", make_start)
        make_source = faceoff[make_start:make_end]
        for needle in [
            "let recent = recentMetrics(history: history, onOrBefore: today, limit: 7, calendar: calendar)",
            "private static func recentMetrics(history: [SavedDailyMetric],",
            "recent.count < limit",
            "metric.day > oldest.day",
            "insertRecentMetric(metric, into: &recent)",
            "private static func insertRecentMetric",
        ]:
            assert_contains(self, make_source, needle)
        assert_not_contains(self, make_source, ".sorted { $0.day > $1.day }")
        assert_not_contains(self, make_source, ".prefix(7)")

        for needle in [
            "func testMakePayloadUsesNewestSevenOnOrBeforeTodayWithoutSortedInput()",
            "XCTAssertEqual(payload.days.count, 7)",
            "XCTAssertEqual(payload.days.map(\\.o), [0, 1, 2, 3, 4, 5, 6])",
            "Future metrics must not be shared.",
        ]:
            assert_contains(self, tests, needle)

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
            "footnote: vo2MaxEstimate.compactStatusText",
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
        cache_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaBiologicalAgeCacheTests.swift")

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
            "nonisolated static let biologicalAgeCacheSchema = 5",
            "nonisolated static let biologicalAgeCacheTTL: TimeInterval = 7 * 24 * 60 * 60",
            "struct BiologicalAgeCacheSignature: Codable, Equatable",
            "let vo2MaxValueTenth: Int?",
            "let dailyMetricFingerprint: UInt64",
            "let sleepHistoryFingerprint: UInt64",
            "let confirmedSleepFingerprint: UInt64",
            "let canonicalSessionFingerprint: UInt64",
            "let baselineFreshRestingDays: Int",
            "struct BiologicalAgeCacheRecord: Codable, Equatable",
            "struct BiologicalAgeWeeklySummaryRecord: Equatable",
            "let cadenceKey: BiologicalAgeWeeklyCadenceKey?",
            "struct BiologicalAgeWeeklyCadenceKey: Codable, Equatable",
            "let biologicalSex: AthleteProfile.BiologicalSex",
            "struct BiologicalAgeSignatureMemoKey: Equatable",
            "let dailyMetricHistoryRevision: Int",
            "let sleepHistorySnapshotRevision: Int",
            "let confirmedSleepsRevision: Int",
            "let canonicalSessionsRevision: Int",
            "let canonicalSessionCount: Int",
            "let sessionsLoaded: Bool",
            "private var cachedBiologicalAge: BiologicalAgeCacheRecord?",
            "private var cachedBiologicalAgeWeeklySummary: BiologicalAgeWeeklySummaryRecord?",
            "private var cachedBiologicalAgeSignatureMemo: (key: BiologicalAgeSignatureMemoKey, signature: BiologicalAgeCacheSignature)?",
            "private var pendingBiologicalAgeRefreshKey: BiologicalAgeRefreshRequestKey?",
            "private(set) var biologicalAgeSummaryRevision = 0",
            "private var confirmedSleepsRevision = 0",
            "private var canonicalSessionsRevision = 0",
            "private func setCachedCanonicalSessions(",
            "advancesBiologicalAgeSourceGeneration: Bool = true",
            "canonicalSessionsRevision &+= 1",
            "biologicalAgeSourceSessionsRevision &+= 1",
            "private func setCachedConfirmedSleeps(_ sleeps: [UserConfirmedSleep])",
            "confirmedSleepsRevision &+= 1",
            "private let biologicalAgeCacheURL: URL",
            "biological-age-cache.json",
            "private var cachedLatestLocalRMSSD: Int?",
            "private var cachedLatestLocalRMSSDSource: LatestSessionMetricSource?",
            "setLatestLocalRMSSDSource(",
            "Self.latestLocalRMSSDSource(in: cachedCanonicalSessions)",
            "nonisolated static func latestLocalRMSSD(in sessions: [SavedSession]) -> Int?",
            "nonisolated static func latestLocalRMSSDSource(in sessions: [SavedSession]) -> LatestSessionMetricSource?",
            "nonisolated static func latestLocalRMSSDSourceAfterUpsert(",
            "func biologicalAgeSummary(vo2MaxEstimate: VO2MaxEstimateSummary) -> BiologicalAgeSummary",
            "Self.isBiologicalAgeCacheCadenceFresh(cached,",
            "let cadenceKey = Self.biologicalAgeWeeklyCadenceKey(profile: profile,",
            "sessionsLoaded: hasCompletedDeferredSessionLoad,",
            "Self.isBiologicalAgeWeeklyCadenceFresh(weekly, cadenceKey: cadenceKey)",
            "scheduleBiologicalAgeRefresh(vo2MaxEstimate: vo2MaxEstimate,",
            "return BiologicalAgeSummary.refreshing(chronologicalAge: profile.age)",
            "private func scheduleBiologicalAgeRefresh(vo2MaxEstimate: VO2MaxEstimateSummary,",
            "DispatchQueue.global(qos: .utility).async",
            "let output = Self.computeBiologicalAgeOutput(input)",
            "self.cachedBiologicalAgeWeeklySummary = weekly",
            "cadenceKey: cadenceKey",
            "nonisolated static func biologicalAgeWeeklyCadenceKey(profile: AthleteProfile,",
            "let key = Self.biologicalAgeSignatureMemoKey(profile: profile,",
            "self.cachedBiologicalAgeSignatureMemo = (memoKey, output.signature)",
            "nonisolated static func biologicalAgeSignatureMemoKey(profile: AthleteProfile,",
            "canonicalSessionsRevision: canonicalSessionsRevision",
            "canonicalSessionCount: cachedCanonicalSessions.count",
            "sessionsLoaded: hasCompletedDeferredSessionLoad",
            "Same-week live\n        // checkpoints replace points inside an existing canonical session often;",
            "dailyMetricHistory: dailyMetricHistory",
            "sleepHistorySnapshot: sleepHistorySnapshot",
            "confirmedSleeps: cachedConfirmedSleeps",
            "confirmedWorkouts: cachedConfirmedWorkouts",
            "canonicalSessions: cachedCanonicalSessions",
            "trainingLoadSummary: trainingLoadSummarySnapshot",
            "todayHRZoneMinutes: todayHRZoneMinutesSnapshot",
            "nonisolated static func biologicalAgeCacheWeekStart(for date: Date,",
            "nonisolated static func isBiologicalAgeWeeklySummaryFresh(_ record: BiologicalAgeWeeklySummaryRecord,",
            "nonisolated static func isBiologicalAgeWeeklyCadenceFresh(_ record: BiologicalAgeWeeklySummaryRecord,",
            "nonisolated static func isBiologicalAgeCacheCadenceFresh(_ record: BiologicalAgeCacheRecord,",
            "self.persistBiologicalAgeCache(persisted)",
            "nonisolated static func biologicalAgeCacheSignature(profile: AthleteProfile,",
            "dailyMetricFingerprint: biologicalAgeDailyMetricFingerprint(dailyMetricHistory)",
            "sleepHistoryFingerprint: biologicalAgeSleepHistoryFingerprint(sleepHistorySnapshot)",
            "confirmedSleepFingerprint: biologicalAgeConfirmedSleepFingerprint(confirmedSleeps)",
            "canonicalSessionFingerprint: biologicalAgeCanonicalSessionFingerprint(canonicalSessions)",
            "nonisolated static func isBiologicalAgeCacheFresh(_ record: BiologicalAgeCacheRecord,",
            "nonisolated static func readBiologicalAgeCache(from url: URL) -> BiologicalAgeCacheRecord?",
            # Bio age blockers/inputs are computed here from local history, then
            # delegated to AtriaFitnessAge.summary (see fitness_age needles below)
            # rather than the old VO2max/sex/BMI-gated AtriaAnalytics.BiologicalAge path.
            "let restingHR = averageIntSnapshot(recentMetrics.compactMap(\\.restingHR)) ?? input.baseline.restingInt",
            "let hrv = averageIntSnapshot(recentMetrics.compactMap(\\.hrv)) ?? input.baseline.hrvInt",
            "let sleepConsistency = recentMetrics.compactMap(\\.sleepConsistencyPercent).first\n            ?? input.sleepHistorySnapshot.sleepConsistencyPercent",
            "let weeklyZone2PlusMinutes = confirmedWorkoutZone2PlusMinutes(",
            "workouts: input.confirmedWorkouts,",
            "Only a user-confirmed workout with a persisted zone breakdown can earn",
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
        latest_local_match = re.search(r"var latestLocalRMSSD: Int\? \{(?P<body>.*?)\n    \}", sessions, re.S)
        self.assertIsNotNone(latest_local_match)
        assert_contains(self, latest_local_match.group("body"), "cachedLatestLocalRMSSD")
        assert_not_contains(self, latest_local_match.group("body"), "sessions.first")

        bio_age_start = sessions.index("func biologicalAgeSummary(vo2MaxEstimate: VO2MaxEstimateSummary)")
        bio_age_end = sessions.index("var biologicalAgeHealthspanDetailProjection", bio_age_start)
        bio_age_source = sessions[bio_age_start:bio_age_end]
        assert_contains(self, bio_age_source, "scheduleBiologicalAgeRefresh(vo2MaxEstimate: vo2MaxEstimate,")
        assert_contains(self, sessions, "DispatchQueue.global(qos: .utility).async")
        assert_not_contains(self, bio_age_source, "let summary = computeBiologicalAgeSummary")

        for needle in [
            "final class AtriaBiologicalAgeCacheTests: XCTestCase",
            "testBiologicalAgeCacheFreshnessRequiresWeekProfileSignatureAndReadySummary",
            "testBiologicalAgeWeeklySummaryCacheAllowsBuildingOnlyForSameWeekAndSignature",
            "testBiologicalAgeCacheCadenceRejectsWrongSchemaAndProfile",
            "testBiologicalAgeWeeklyCadenceFreshIgnoresSameWeekSignatureChurn",
            "testBiologicalAgeCacheFreshnessTracksSlowMovingInputs",
            "testBiologicalAgeSignatureMemoKeyIsWeeklyAndIgnoresCheckpointChurn",
            "XCTAssertTrue(SessionStore.isBiologicalAgeCacheCadenceFresh(record,",
            "XCTAssertTrue(SessionStore.isBiologicalAgeWeeklyCadenceFresh(",
            "canonicalSessionsRevision: 7",
            "canonicalSessionsRevision: 8",
            "XCTAssertEqual(key, sameWeekCheckpointChurn)",
            "XCTAssertNotEqual(key, newSessionCohort)",
            "XCTAssertNotEqual(key, nextWeek)",
            "XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(staleByAge,",
            "XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(notReady,",
            "XCTAssertTrue(SessionStore.isBiologicalAgeWeeklySummaryFresh(record,",
            "XCTAssertFalse(SessionStore.isBiologicalAgeWeeklySummaryFresh(wrongSchema,",
        ]:
            assert_contains(self, cache_tests, needle)
        for needle in [
            "static let footnoteText = \"Estimate from heart data — not a medical measurement.\"",
            "struct Inputs: Equatable",
            "let chronologicalAge: Int",
            "let biologicalSex: AthleteProfile.BiologicalSex",
            "let vo2Max: Double?",
            "let restingHeartRate: Int?",
            "let hrvRMSSD: Int?",
            "let weeklyZone2PlusMinutes: Double?",
            "let sleepConsistencyPercent: Int?",
            "let historyDays: Int",
            "static func summary(inputs: Inputs) -> BiologicalAgeSummary",
            # 2026-07-17: baseline graduated from a hard 28-day gate to a
            # 14-day early estimate with visible confidence (confident at 28).
            "static let earlyEstimateMinimumDays = 14",
            "static let confidentBaselineDays = 28",
            "if inputs.historyDays < earlyEstimateMinimumDays",
            "blockers.append(\"14 days of heart data\")",
            "earlyEstimateDayCount: earlyDayCount",
            "blockers.append(\"VO2 max estimate\")",
            "if inputs.restingHeartRate == nil",
            "blockers.append(\"resting HR baseline\")",
            "if inputs.hrvRMSSD == nil",
            "blockers.append(\"HRV baseline\")",
            "if inputs.weeklyZone2PlusMinutes == nil",
            "blockers.append(\"weekly zone-2+ minutes\")",
            "if inputs.sleepConsistencyPercent == nil",
            "blockers.append(\"sleep consistency\")",
            # 2026-07-17: copy follows the 14-day early-estimate gate above.
            "agingPaceDetail: \"Needs 14 days before an early fitness-age estimate.\"",
            "label: \"VO2 max\"",
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
        assert_contains(self, home, "let stressMonitorStore: AtriaStressMonitorStore")
        assert_contains(self, home, "stressState: stressMonitorStore.state")
        assert_contains(self, home, "let stress = AtriaStressPresentation.make(state: stressState)")
        assert_not_contains(self, home, "private static func stressState(ble:")
        for needle in [
            r"\(hero.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
            r"\(stats.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)",
            r"\(projectionStore.hrvBaselineSampleCount)/\(PersonalBaseline.trustedMinimumSamples)",
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
            "detail: biologicalAgeSummary.compactStatusText",
            "Calibrating your fitness-age baseline. \\(biologicalAgeSummary.blockerText). \\(biologicalAgeSummary.footnote)",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "let biologicalAgeSummary: BiologicalAgeSummary",
            "AtriaMetricTile(label: \"Body age\"",
            "AtriaMetricTile(label: \"Delta\"",
            "targetMetric: .bioAge",
            "AtriaMetricTile(label: \"Top driver\"",
            "biologicalAgeSummary.agingPaceText",
            "biologicalAgeSummary.agingPaceDetail",
            "state: biologicalAgeSummary.isReady ? .estimate : .learning",
            "AtriaPanelSectionHeader(title: \"Body Age\", subtitle: biologicalAgeSummary.narrative)",
            "ForEach(biologicalAgeSummary.factors)",
            "Text(biologicalAgeSummary.footnote)",
            "let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore",
            "struct AtriaCollectionBiologicalAgeCard: View, Equatable",
            "AtriaCollectionBiologicalAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary,",
            "AtriaPanelSectionHeader(title: \"Body Age\", subtitle: summary.narrative)",
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
            # 2026-07-08: floor raised 6.0 -> 9.0 bpm (0.15 Hz HF-band floor)
            # so HRV LF / Mayer-wave drift can no longer be reported as
            # breathing (device showed a fabricated 6.5-8.2 bpm).
            "for breathsPerMinute in stride(from: 9.0, through: 30.0, by: 0.5)",
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
        assert_contains(self, sessions, "static let maximumResidentNightCount = 84")
        assert_contains(self, sessions, "let clippedNights = Array(sorted.prefix(Self.maximumResidentNightCount))")
        assert_contains(self, sessions, "self.nights = clippedNights")
        assert_contains(self, sessions, "let respiratoryBaselineMean: Double?")
        assert_contains(self, sessions, "let respiratoryBaselineCount: Int")
        assert_contains(self, sessions, "let respiratoryRate = AtriaAnalytics.RespRateRsa.estimate(\n            samples: sorted.map { (t: $0.t, ms: $0.ms) },\n            now: windowEnd\n        )")
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
            "let validatedHRV = store.latestReferenceValidatedRecoveryHRV(on: now)",
            "let fallbackHRV = validatedHRV ?? store.latestLocalRecoveryHRV(on: now)",
            "let latestSleep = store.sleepHistorySnapshot.latestMainSleep",
            "let displayedRecovery = store.recoveryProjection(",
            "initialFallbackHRVSnapshot: ble.recoveryHRVSnapshot",
            "hrvState = widgetRecovery.confidence == .validated ? \"validated\" : \"personal_baseline\"",
        ]:
            assert_contains(self, widget, needle)

        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        assert_contains(self, home, "let recovery = store.recoveryProjectionForPresentation(")
        assert_contains(self, notifications, "let recovery = store.recoveryProjection(")
        for needle in [
            "fallbackRMSSD: fallbackHRV",
            "hrvReferenceValidated: validatedHRV != nil",
            "sleepEfficiency: latestSleep?.sleepEfficiency",
            "sleepDurationHours: latestSleep?.durationHours",
            "nonisolated static let provisionalRecoveryProjectionTTL: TimeInterval = 4 * 60 * 60",
        ]:
            assert_contains(self, sessions, needle)
        # 2026-07-08: de-privatized so the unknown-span honesty rule is testable.
        assert_contains(self, sessions, "nonisolated static func sleepEfficiency(duration: TimeInterval?, span: TimeInterval?) -> Double?")
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
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        assert_contains(self, settings, "Cloud requests are disabled until Atria's reviewed service client is available.")
        assert_contains(self, settings, 'Text("On-device").tag(AtriaAICoachSettings.Mode.local)')
        assert_contains(self, settings, "Coach summaries run on this iPhone.")
        assert_not_contains(self, card, "bring-your-own-key")
        assert_contains(self, settings, ".privacySensitive()")
        assert_not_contains(self, card, "SecureField")
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
        # Documentation citations are allowed; executable Swift still must not
        # contain a network/browser client or URL literal.
        app_text = "\n".join(
            line for line in all_swift_source().splitlines()
            if not line.lstrip().startswith(("//", "/*", "*", "*/"))
        )

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
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        collection = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        content = source(ROOT / "Atria" / "Atria" / "ContentView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "enum AtriaDeveloperMode",
            "defaultsKey = \"atria.developerMode.enabled\"",
            "expiryDefaultsKey = \"atria.developerMode.expiresAt\"",
            "launchArgument = \"--atria-developer-mode\"",
            "static let leaseDuration: TimeInterval = 7 * 24 * 60 * 60",
            "defaults.set(now.addingTimeInterval(leaseDuration), forKey: expiryDefaultsKey)",
            "expiresAt > now",
            "static func disable(defaults: UserDefaults = .standard)",
        ]:
            assert_contains(self, developer_mode, needle)

        for needle in [
            "@State private var developerModeEnabled = AtriaDeveloperMode.isEnabled",
            "developerModeEnabled: developerModeEnabled",
            "AtriaDeveloperMode.disable()",
            "developerModeEnabled = false",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "Button(\"Exit developer mode\", role: .destructive)",
            "onExitDeveloperMode()",
            "navigationPath = NavigationPath()",
        ]:
            assert_contains(self, settings, needle)

        for needle in [
            "let developerModeEnabled: Bool",
            "captureCard\n                        researchSignalsCard\n                        biologicalAgeCard\n                        if developerModeEnabled",
            "captureCard\n                    researchSignalsCard\n                    biologicalAgeCard\n                    if developerModeEnabled",
            "if developerModeEnabled {\n                            rrReferenceCard",
            "if developerModeEnabled {\n                            rrReferenceCard\n                            hrReferenceCard\n                            imuAuditCard",
            "if developerModeEnabled {\n                    AtriaCollectionToggleCard",
            "title: \"Stable sensor mode\"",
            "Recommended minimal connection with heart rate and strap-native motion.",
            "Diagnostic full protocol; richer transport may be less stable.",
            "private var researchSignalsCard: some View",
            "AtriaCollectionResearchSignalsCard(summary: state.summary,",
            "sleepHistory: state.sleepHistory",
            "sleepHistoryRevision: state.sleepHistoryRevision",
            "private struct AtriaCollectionResearchSignalsCard: View, Equatable",
            "let sleepHistoryRevision: Int",
            "&& lhs.sleepHistoryRevision == rhs.sleepHistoryRevision",
            "AtriaPanelSectionHeader(title: \"Experimental sensors\", subtitle: \"\")",
            "Image(systemName: \"info.circle\")",
            "showResearchInfo = true",
            "Experimental sensor info",
            "AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,",
            "AtriaMetricTile(label: \"Blood oxygen\"",
            "AtriaExperimentalSensorCopy.bloodOxygenFootnote(",
            "@AtriaDefault(\"atria.target.bloodOxygen.candidateFrames\") private var bloodOxygenCandidateGoal: Int = 8",
            "lhs.bloodOxygenCandidateGoal == rhs.bloodOxygenCandidateGoal",
            "AtriaMetricTile(label: \"Wrist temp\"",
            "value: AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable",
            "AtriaExperimentalSensorCopy.skinTemperatureFootnote(",
            "AtriaMetricTile(label: \"Resp rate\"",
            "footnote: respiratory.detail",
            "AtriaMetricTile(label: \"Strap steps\"",
            "AtriaExperimentalRespiratoryRatePresentation.resolve(",
            "Rows show evidence counts until checked. Skin temperature is only a sleep-baseline change.",
            "private struct AtriaResearchSignalInfoSheet: View",
            "@Environment(\\.dismiss) private var dismiss",
            "Not available yet. Atria does not show raw sensor data as blood oxygen.",
            "Atria does not show an SpO2 percentage until quality checks pass.",
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
            "AtriaCollectionIMUAuditCard(summary: state.summary)",
        ]:
            assert_contains(self, collection, needle)
        assert_not_contains(self, collection, "title: \"Standard HR radio\"")
        assert_not_contains(self, collection, "Advanced compatibility mode for heart-rate-only collection.")

        for needle in [
            "struct IMUAuditSummary: Equatable",
            "var respiratoryRateText: String",
            "@Published private(set) var imuAuditSummary",
            "private func recomputeCollectionResearchSummaries()",
            # 2026-07-08: research summaries now recompute OFF-main + coalesced
            # (compute-cadence pass) — still built from the real sessions snapshot,
            # nothing fabricated; published back on main. Skin-temp deviation
            # excludes the fresh active journal id so the displayed value is
            # finalized sleep evidence, while candidate counts still include live
            # probe evidence.
            "let activeSessionID = Self.freshActiveSessionIDForResearchSummary()",
            "let imu = IMUAuditSummary(sessions: sessionsSnapshot, activeSessionID: activeSessionID)",
            "private nonisolated static func freshActiveSessionIDForResearchSummary(now: Date = Date()) -> UUID?",
        ]:
            assert_contains(self, sessions, needle)

        recompute_start = sessions.index("private func recomputeCollectionResearchSummaries()")
        recompute_end = sessions.index("private nonisolated static func freshActiveSessionIDForResearchSummary", recompute_start)
        recompute_source = sessions[recompute_start:recompute_end]
        work_start = recompute_source.index("let work = DispatchWorkItem")
        active_lookup = "let activeSessionID = Self.freshActiveSessionIDForResearchSummary()"
        self.assertLess(work_start, recompute_source.index(active_lookup))
        assert_not_contains(self, recompute_source[:work_start], "freshActiveSessionIDForResearchSummary()")

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
        assert_not_contains(self, research_card, "lhs.sleepHistory == rhs.sleepHistory")
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
        assert_contains(self, content, "guard await store.restoreSessionBackup(from: url) else { return false }")
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
            # 2026-07-16: added a "What to track" behavior-selection page between
            # profile and expectations (WHOOP-style journal opt-in).
            "case behaviors",
            "case expectations",
            "Your strap. Your data.",
            "Close WHOOP",
            "Wear it tonight",
            "3–4 nights",
            "ble.startScan(reason: \"onboarding_strap\")",
            "--atria-ui-onboarding-complete-connected-strap",
            "guard historyBootstrap.isCompleteForCurrentStrap, !didComplete else { return }",
            "ATRIADBG onboarding status=debug_complete_connected_strap action=complete",
            "let onRestoreBackup: ((URL) async -> Bool)?",
            ".fileImporter(isPresented: $backupImportPresented",
            "allowedContentTypes: backupArchiveTypes",
            "Restore backup from Files",
            "url.startAccessingSecurityScopedResource()",
        ]:
            assert_contains(self, onboarding, needle)

        assert_not_contains(self, content, "I’ll do this — continue")

    # 2026-07-16: onboarding grew from four to five pages — added a
    # "What to track" journal-behavior selection step before expectations.
    def test_onb1_uses_single_five_page_onboarding_flow(self):
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
            # 2026-07-16: added a "What to track" behavior-selection page between
            # profile and expectations (WHOOP-style journal opt-in).
            "case behaviors",
            "case expectations",
            "Your strap. Your data.",
            "WHOOP insights without the subscription.",
            "Close WHOOP",
            "Wear it tonight",
            "3–4 nights",
            "ble.startScan(reason: \"onboarding_strap\")",
            "--atria-ui-onboarding-complete-connected-strap",
            "guard historyBootstrap.isCompleteForCurrentStrap, !didComplete else { return }",
            "ATRIADBG onboarding status=debug_complete_connected_strap action=complete",
            "Restore backup from Files",
            "handleBackupImport",
        ]:
            assert_contains(self, onboarding, needle)

    def test_pull_to_refresh_connectivity_pill_uses_shared_refresh_path(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        for needle in [
            "refresh: handleConnectivityRefresh,",
            ".refreshable { await refresh() }",
            "private func handleConnectivityRefresh() async",
            "ble.requestStrapStatusRead(reason: \"pull_to_refresh\")",
            "requestOfflineHistoricalSyncIfNeeded(reason: \"pull_to_refresh\", force: true)",
            "showConnectivityPill = true",
            "return \"Refreshing strap…\"",
            "Self.debugLaunchFixtureValue(arguments: arguments) == \"refresh-connectivity-pill\"",
            "await handleConnectivityRefresh()",
        ]:
            assert_contains(self, home, needle)
        refresh_start = home.index("private var connectivityPillText")
        refresh_end = home.index("private func handleConnectivityRefresh", refresh_start)
        refresh_feedback = home[refresh_start:refresh_end]
        assert_not_contains(self, refresh_feedback, "batteryText")
        assert_not_contains(self, refresh_feedback, "connectivityFreshnessText")

    def test_feat4_weekly_report_fixture_opens_sheet(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        debug_logging = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        notifications = source(ROOT / "Atria" / "Atria" / "LocalNotificationScheduler.swift")
        weekly_report = source(ROOT / "Atria" / "Atria" / "AtriaWeeklyReport.swift")
        analytics_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")
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

        init_start = weekly_report.index("    init(rollups: [DailyRollupStoreEntry],")
        init_end = weekly_report.index("    private static func roundedAverage", init_start)
        init_source = weekly_report[init_start:init_end]
        for needle in [
            "let recent = Self.recentRollups(rollups, limit: 14)",
            "private static func recentRollups(_ rollups: [DailyRollupStoreEntry],",
            "recent.count < limit",
            "rollup.day > oldest.day",
            "insertRecentRollup(rollup, into: &recent)",
            "private static func insertRecentRollup",
        ]:
            assert_contains(self, init_source, needle)
        assert_not_contains(self, init_source, "rollups.sorted { $0.day > $1.day }")
        assert_not_contains(self, init_source, "Array(ordered.prefix(7))")
        assert_contains(self, analytics_tests, "Weekly report should not require pre-sorted rollups.")

    def test_north_star_screen_routing_uses_named_rebuild_files(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        strap = source(ROOT / "Atria" / "Atria" / "AtriaStrapScreen.swift")
        highlights = source(ROOT / "Atria" / "Atria" / "AtriaHighlights.swift")
        tri_ring = source(ROOT / "Atria" / "Atria" / "AtriaTriRing.swift")
        analytics_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")

        for needle in [
            "AtriaTodayScreen(liveStore:",
            "AtriaHealthScreen(isActive: selectedTab == .vitals,",
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
            "AtriaTodayShortcutStrip(onStartWorkout: onStartWorkout)",
            "onStartWorkout: onStartWorkout",
            "private struct AtriaTodayShortcutStrip: View, Equatable",
            "Button(action: onStartWorkout)",
            'Text("Start activity")',
            ".frame(maxWidth: .infinity, minHeight: 54)",
        ]:
            assert_contains(self, today, needle)
        assert_contains(self, home, "onOpenJournal: {\n                                 selectedTab = .journal\n                             }")
        assert_contains(self, home, "onOpenShare: {\n                                 showShareSheet = true\n                             }")
        assert_contains(self, home, 'let shouldOpenJournalSheet = arguments.contains("--atria-open-journal")')
        assert_contains(self, home, 'let shouldStartWorkout = arguments.contains("--atria-start-workout")')
        assert_contains(self, home, "showJournalSheet = true")
        assert_contains(self, home, "workoutSession = await makeWorkoutSession()")

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
        # Strap is now the always-interactive leading battery/status pill and
        # remains available in Settings, leaving two compact trailing actions.
        self.assertEqual(top_chrome_body.count(".buttonStyle(AtriaHeaderActionButtonStyle())"), 2)
        assert_contains(self, top_chrome_body, "onTapWhenConnected: onShowStrap")
        assert_not_contains(self, top_chrome_body, "Button(action: onShowStrap)")
        assert_contains(self, top_chrome_body, "Button(action: onShowSettings)")
        self.assertNotIn("private var shouldShowTopChromeHelp: Bool", home)
        assert_contains(self, top_chrome_body, "AtriaToolbarIcon(symbol: \"gearshape\")")
        assert_contains(self, top_chrome_body, ".accessibilityLabel(\"Settings\")")
        assert_contains(self, home, 'Text("Data gap · \\(missedDataDurationText)")')
        assert_contains(self, home, 'Text(protectsLiveStream ? "Live protected" : "Check strap history")')
        assert_contains(self, home, "private var compactState: some View")
        assert_contains(self, home, "if diagnosis.guidanceDomain.offersConnectionGuide {")
        assert_contains(self, home, "Button(action: onHelp) {\n                    Image(systemName: \"questionmark.circle\")")
        assert_contains(self, home, ".buttonStyle(.plain)\n                .foregroundStyle(diagnosis.tint)")
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
            "private final class AtriaHeartRateExplorerPresentationController: ObservableObject",
        ]:
            assert_contains(self, vitals_collection, needle)

        for needle in [
            "struct AtriaHealthScreen: View",
            'static let debugOpenHeartRateTimelineKey = "atria.debug.openHeartRateTimeline"',
            "private var debugShowsHeartRateTimeline: Bool",
            "if debugShowsHeartRateTimeline {\n                AtriaHealthTimelineProofCard(points: chartPoints,",
            ".task(id: isActive && debugShowsHeartRateTimeline) {",
            "guard isActive, debugShowsHeartRateTimeline else { return }",
            "AtriaVitalsArchiveActivityObserver {",
            "debugArchiveRefreshGate.shouldRefreshArchive(isActive: isActive,",
            "AtriaVitalsHeartRateTimeline.mergedHeartRatePoints(live: pulseSparklineStore.state.chartPoints,",
            "guard debugShowsHeartRateTimeline else { return }",
            "let since: Date? = nil",
            "let limit = 6_000",
            "await Task.detached(priority: .utility)",
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
            "override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {",
            "AtriaHeartRateExplorerOrientationPolicy.preferredOrientation",
            "Task { await loadMetricArchiveForDebugProofIfNeeded() }",
        ]:
            assert_contains(self, vitals_collection, needle)

        assert_contains(self, home, 'UserDefaults.standard.set(true, forKey: AtriaHealthScreen.debugOpenHeartRateTimelineKey)')
        assert_contains(self, home, 'let shouldOpenHeartRateTimeline = Self.debugLaunchFixtureValue(arguments: arguments) == "heart-rate-timeline"')
        assert_contains(self, home, 'ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"]')

        for text, needle in [
            (today, "struct AtriaTodayScreen: View"),
            (today, "AtriaHighlights.topTwo(rollups: highlightRollups)"),
            (today, "guard glanceMemo.workoutsRevision != revision || glanceMemo.workoutsWeekStart != weekStart else { return }"),
            (today, "glanceMemo.workoutsWeekStart = weekStart"),
            (today, "let today = Calendar.current.startOfDay(for: Date())"),
            (today, "glanceMemo.strainMedianDay == today"),
            (today, "glanceMemo.strainMedianDay = today"),
            (today, "var strainMedianDay: Date?"),
            (today, "var workoutsWeekStart: Date?"),
            (today, "return sessionProjectionStore.state.dailyRollupHistory"),
            (today, 'arguments[valueIndex] == "north-star-highlights"'),
            (today, "debugHighlightRollups(includeNutrition: Self.debugShowsNutritionRecoveryDetail"),
            # 2026-07-07: strip gained the onOpen route (insight rows are
            # real buttons now, not fake chevrons).
            (today, "AtriaTodayHighlightsStrip(highlights: highlights) { metric in"),
            (today, "private struct AtriaTodayHighlightsStrip: View, Equatable"),
            (today, "AtriaTodayLiveStatusStrip(live: liveStore.state,"),
            (today, "AtriaTodayPlanCard(title: planTitle,"),
            (today, "LazyVGrid(columns: glanceColumns, spacing: AtriaDesignTokens.Spacing.md)"),
            (today, "private var glanceColumns: [GridItem]"),
            (today, "if horizontalSizeClass == .regular"),
            # TODO(unbuilt spec / superseded): "Health" and "Strap" Today glance cards
            # were never implemented as AtriaTodayMetric cases, and docs/23 later
            # explicitly decided against a 4th "Health" tab (graphs live in detail
            # views instead) -- Today's glance grid only renders the metrics in
            # AtriaTodayMetric via the generic AtriaTodayGlanceItem(title: metric.label,
            # pattern pinned below.
            (today, "AtriaTodayGlanceItem(title: metric.label,"),
            # 2026-07-07 UX audit: the Journal info row duplicated the
            # shortcut strip's Journal value on the same screen and was
            # removed; the shortcut strip (pinned below) carries the value.
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
            # 2026-07-07 dedup audit: the Connection row duplicated the
            # state hero's value+detail verbatim and was removed.
            (strap, 'AtriaStrapConnectionHero(statusStore:'),
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
        assert_not_contains(self, today, "@ObservedObject var statusStore")
        assert_not_contains(self, health, "AtriaVitalsTabContent(liveStore:")
        assert_not_contains(self, strap, "AtriaCollectionTabContent(coreLiveStore:")
        assert_contains(self, highlights, "let ordered = rollups.sorted { $0.day > $1.day }")
        assert_contains(self, highlights, "rules.compactMap { $0(ordered) }")
        self.assertEqual(highlights.count("sorted { $0.day > $1.day }"), 1)
        assert_contains(self, analytics_tests, "testHighlightsUseNewestRollupsWhenInputIsUnordered")

    def test_vitals_pulse_timeline_uses_cheap_key_for_card_equality(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        timeline_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaHeartRateTimelineWindowTests.swift")

        for needle in [
            "struct SeriesKey: Equatable",
            "let firstBPM: Int?",
            "init(points: [AtriaHomeModel.HeartRateChartPoint])",
            "private var timelineKey: AtriaHeartRateMergeCache.SeriesKey",
            "AtriaHeartRateMergeCache.SeriesKey(points: chartPoints)",
            "onOpen: openHeartRateExplorer",
            ".onChange(of: timelineKey, initial: true)",
            "timelineKey.count > 0",
            "let startIndex = firstPointIndex(onOrAfter: cutoff, in: points)",
            "let visibleCount = points.count - startIndex",
            "guard visibleCount > displayBudget else { return Array(points[startIndex...]) }",
            "private static func firstPointIndex(onOrAfter date: Date,",
        ]:
            assert_contains(self, vitals, needle)
        windowed_start = vitals.index("static func windowed(_ points:")
        windowed_end = vitals.index("    /// Uniformly thins", windowed_start)
        windowed_source = vitals[windowed_start:windowed_end]
        assert_not_contains(self, windowed_source, "let visible = points.filter { $0.t >= cutoff }")

        pulse_card_start = vitals.index("private struct AtriaPulseCard: View, Equatable")
        pulse_card_end = vitals.index("private struct AtriaHeartRateTimelineCard", pulse_card_start)
        pulse_card_source = vitals[pulse_card_start:pulse_card_end]
        assert_not_contains(self, pulse_card_source, "lhs.chartPoints == rhs.chartPoints")
        assert_not_contains(self, pulse_card_source, ".onChange(of: chartPoints)")
        for needle in [
            "func testWindowedLargeSortedInputMatchesFilterSemantics()",
            "let visible = pts.filter { $0.t >= cutoff }",
            "XCTAssertEqual(exact, visible)",
            "XCTAssertEqual(downsampled.first, visible.first)",
            "XCTAssertEqual(downsampled.last, visible.last)",
        ]:
            assert_contains(self, timeline_tests, needle)

    def test_heart_rate_explorer_uses_cheap_points_key_for_live_updates(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        explorer_start = vitals.index("struct AtriaHeartRateExplorer: View")
        explorer_end = vitals.index("@MainActor", explorer_start)
        explorer_source = vitals[explorer_start:explorer_end]

        for needle in [
            "private var pointsKey: AtriaHeartRateMergeCache.SeriesKey",
            "AtriaHeartRateMergeCache.SeriesKey(points: points)",
            ".onChange(of: pointsKey)",
            "refreshSeries(points)",
            "AtriaVitalsHeartRateTimeline.windowed(source, window: .hour24, displayBudget: 1_200)",
        ]:
            assert_contains(self, explorer_source, needle)

        assert_not_contains(self, explorer_source, ".onChange(of: points)")
        assert_not_contains(self, explorer_source, "_, newValue in")

    def test_health_stress_strip_observes_revision_not_full_history_array(self):
        health = source(ROOT / "Atria" / "Atria" / "AtriaHealthScreen.swift")
        stress = source(ROOT / "Atria" / "Atria" / "AtriaStressMonitor.swift")
        perf_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")

        for needle in [
            "private(set) var history: [StressHistoryPoint] = []",
            "@Published private(set) var historyRevision = 0",
            "historyRevision &+= 1",
            "nonisolated static let unchangedInputEvaluationInterval: TimeInterval = 30",
            "nonisolated static func shouldEvaluateStressInput(force: Bool,",
            "if isNoSignal { return false }",
        ]:
            assert_contains(self, stress, needle)
        assert_not_contains(self, stress, "@Published private(set) var history: [StressHistoryPoint] = []")

        health_start = health.index("struct AtriaHealthScreen: View")
        child_start = health.index("private struct AtriaHealthStressSection: View", health_start)
        parent_source = health[health_start:child_start]
        child_end = health.index("/// One downsampled+segmented session-stress reading", child_start)
        child_source = health[child_start:child_end]

        for needle in [
            "AtriaHealthStressSection(behaviorJournalEntries:",
            "stressMonitorStore: stressMonitorStore",
        ]:
            assert_contains(self, parent_source, needle)

        for needle in [
            "@ObservedObject var stressMonitorStore: AtriaStressMonitorStore",
            "@State private var stressStripReduced: [StressStripPoint] = []",
            "@State private var lastStressEvaluationAt: Date?",
            ".onChange(of: isActive, initial: true)",
            ".onChange(of: stressMonitorStore.state, initial: true)",
            "private func publishStressForBreathwork(now: Date = Date())",
            "lastStressEvaluationAt = now",
            ".onChange(of: stressMonitorStore.historyRevision, initial: true)",
            "stressStripReduced = AtriaHealthScreen.reduceStressStrip(stressMonitorStore.history)",
        ]:
            assert_contains(self, child_source, needle)
        assert_contains(self, perf_tests, "testStressInputEvaluationSkipsUnchangedTicksUntilHistoryCadence")

        for needle in [
            "@StateObject private var stressMonitorStore",
            "@State private var stressStripReduced",
            "@State private var lastStressInputKey",
            "AtriaVitalsStressActivityObserver",
            ".onChange(of: stressMonitorStore.historyRevision",
        ]:
            assert_not_contains(self, parent_source, needle)
        assert_not_contains(self, child_source, "@ObservedObject var pulseStore")
        assert_not_contains(self, child_source, ".onChange(of: stressMonitorStore.history,")

    def test_ble_recent_rr_samples_are_revision_cached_and_tail_windowed(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        for needle in [
            "private struct RecentBreathworkRRSampleCache",
            "private var rrArchiveRevision: UInt64 = 0",
            "private var recentBreathworkRRSampleCache: RecentBreathworkRRSampleCache?",
            "private static let recentBreathworkRRCacheBucketSeconds: TimeInterval = 1",
            "private func noteRRArchiveDidChange()",
            "rrArchiveRevision &+= 1",
            "recentBreathworkRRSampleCache = nil",
        ]:
            assert_contains(self, ble, needle)
        self.assertGreaterEqual(ble.count("noteRRArchiveDidChange()"), 5)

        helper_start = ble.index("func recentBreathworkRRSamples")
        helper_end = ble.index("func startScan", helper_start)
        helper_source = ble[helper_start:helper_end]

        for needle in [
            "cache.archiveRevision == rrArchiveRevision",
            "cache.maxAge == maxAge",
            "cache.nowBucket == nowBucket",
            "for interval in rrArchive.reversed()",
            "guard now.timeIntervalSince(interval.t) <= maxAge else { break }",
            "samples.reserveCapacity(min(rrArchive.count, 900))",
            "if samples.count == 900 { break }",
            "samples.reverse()",
        ]:
            assert_contains(self, helper_source, needle)
        assert_not_contains(self, helper_source, "rrArchive\n            .filter")

    def test_lb1_connection_ui_uses_strap_stream_state(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        strap = source(ROOT / "Atria" / "Atria" / "AtriaStrapScreen.swift")

        for needle in [
            "var strapStreamConnectionLabel: String",
            "case .lowBatteryShutoff:\n                return \"Charge strap\"",
            "case .lowBatteryReducedDetail:\n                return \"Low battery\"",
            "Strap battery too low for live heart rate. Charge to resume.",
            "var strapStreamConnectionSymbol: String",
            "strapStreamConnectionLabel: core.strapStreamConnectionLabel",
            "strapStreamConnectionSymbol: core.strapStreamConnectionSymbol",
            "switch input.strapStreamState",
        ]:
            assert_contains(self, home, needle)

        for needle in [
            "systemImage: connectionSymbol",
            "return coreLiveStore.state.strapStreamConnectionLabel",
            "return coreLiveStore.state.strapStreamConnectionDetail",
            "return coreLiveStore.state.strapStreamConnectionSymbol",
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

    def test_strap_screen_does_not_observe_unused_projection_stores(self):
        strap = source(ROOT / "Atria" / "Atria" / "AtriaStrapScreen.swift")
        declaration = strap[:strap.index("    let store: SessionStore")]

        for unused in [
            "homeStatsStore",
            "snapshotStore",
            "profileStore",
            "profileMetricsStore",
        ]:
            assert_not_contains(self, declaration, unused)
        assert_contains(self, declaration, "let pulseLiveStore: AtriaHomeModel.PulseLiveStore")
        assert_not_contains(self, declaration, "@ObservedObject var pulseLiveStore")
        hero = strap[strap.index("private struct AtriaStrapConnectionHero: View"):]
        assert_contains(self, hero, "@ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore")

    def test_live_workout_isolates_high_frequency_store_observation(self):
        workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        root = workout[workout.index("struct AtriaLiveWorkoutView: View"):
                       workout.index("private struct AtriaLiveWorkoutBackdrop: View")]

        assert_contains(self, root, "let pulseStore: AtriaHomeModel.PulseLiveStore")
        assert_contains(self, root, "let metricStore: AtriaLiveWorkoutMetricStore")
        assert_not_contains(self, root, "@ObservedObject var metricStore")
        assert_not_contains(self, root, "metricStore.state")
        assert_not_contains(self, root, "@ObservedObject var pulseStore")
        assert_not_contains(self, root, "@ObservedObject var liveStore")
        for leaf in [
            "private struct AtriaLiveWorkoutBackdrop: View",
            "private struct AtriaLiveWorkoutHeartBlock: View",
            "private struct AtriaLiveWorkoutRouteMetricsHost: View",
            "private struct AtriaLiveWorkoutStrainGuidanceHost: View",
            "private struct AtriaLiveWorkoutStrainGuidance: View",
            # 2026-07-16: honest motion-status indicator added as its own narrow
            # leaf so a raw strap-motion timestamp update cannot rebuild the
            # workout controls or route map.
            "private struct AtriaLiveWorkoutMotionStatusHost: View",
        ]:
            assert_contains(self, workout, leaf)
        assert_contains(self, workout, "AtriaLiveWorkoutHeartBlock(pulseStore: pulseStore,")
        assert_contains(self, workout, "AtriaLiveWorkoutRouteMetricsHost(metricStore: metricStore,")
        assert_contains(self, workout, "AtriaLiveWorkoutStrainGuidanceHost(metricStore: metricStore,")
        assert_contains(self, workout, "AtriaLiveWorkoutMotionStatusHost(metricStore: metricStore)")
        # 2026-07-16: 2 -> 3 for the added motion-status leaf above; the root
        # view still must not observe metricStore directly (asserted above).
        self.assertEqual(workout.count("@ObservedObject var metricStore: AtriaLiveWorkoutMetricStore"), 3)
        assert_not_contains(self, workout, "private struct AtriaLiveWorkoutZoneCard: View")
        assert_not_contains(self, workout, "private struct AtriaLiveWorkoutStatsRow: View")

    def test_hist1_acceptance_verifier_requires_exact_archive_gap_and_timeline(self):
        verifier = source(ROOT / "tools" / "verify_hist1_acceptance.py")
        runner = source(ROOT / "tools" / "run_hist1_acceptance_after_reconnect.sh")
        marker = source(ROOT / "tools" / "start_hist1_phone_away_gap.sh")

        for needle in [
            "MIN_GAP_SECONDS = 60 * 60",
            "MAX_RECONNECT_TO_PULL_SECONDS = 30 * 60",
            "COVERAGE_BUCKET_SECONDS = 15",
            "MAX_CONTINUITY_GAP_SECONDS = 3.0",
            "MAX_P95_GAP_SECONDS = 1.5",
            "MIN_SAMPLE_DENSITY_HZ = 0.8",
            "MIN_SLEEP_CADENCE_SECONDS = 3 * 60 * 60",
            "MIN_SCREENSHOT_DIMENSION = 500",
            "MIN_SCREENSHOT_BYTES = 10_000",
            "--gap-start",
            "--reconnect",
            "--timeline-screenshot",
            "--pre-pull-summary",
            "--pre-relaunch-pull-summary",
            "--recovery-log",
            "installed_app_provenance_not_verified",
            "compare_analytics",
            "range_loss_backfill_still_pending",
            "archive_metric_not_ready",
            "archive_metric_promotion_blocked",
            "hist1_acceptance_status=",
            "mode=deliberate_gap_exact_archive",
            "timeline_points_derived=",
            "gap_buckets_expected=",
            "gap_buckets_covered=",
            "exact_gap_buckets_missing",
            "historical-archive.identity.jsonl",
            "gap_rows_missing_unique_identity_index_entry",
            "validated_metric_layouts_changed_since_installed_baseline",
            "pre_relaunch_active_journal_not_lossless",
            "resident_overnight_continuity_failed_before_relaunch",
            "historical_recovery_not_continuous_one_hz",
            "tonight_sleep_cadence_window_missing",
            "sleep_projection_not_advanced_for_overnight_window",
        ]:
            assert_contains(self, verifier, needle)
        assert_not_contains(self, verifier, "--timeline-points")
        assert_not_contains(self, verifier, "--allow-current-proof")

        for needle in [
            "--gap-start ISO",
            "--reconnect ISO",
            "pull_atria_state.sh",
            "--runtime-only",
            "--installed-provenance-only",
            'evidence_dir="logs/live-device/$label"',
            'ATRIA_UI_FIXTURE":"heart-rate-timeline"',
            "device capture screenshot",
            "tools/verify_hist1_acceptance.py",
            "--pull-summary \"$evidence_dir/pull-summary.txt\"",
            "--pre-pull-summary \"$pre_pull_summary\"",
            "--pre-relaunch-pull-summary \"$pre_relaunch_dir/pull-summary.txt\"",
            "for checkpoint_attempt in 1 2 3; do",
            "active_journal_final_status",
            "pre_relaunch_ready=1",
            "Refusing to relaunch: no lossless resident checkpoint after 3 attempts.",
            "--recovery-log \"$recovery_log\"",
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
        assert_not_contains(self, runner, "--timeline-points")

        for needle in [
            "--label NAME",
            "--device ID",
            "--bundle-id ID",
            "--preflight-pull",
            "preflight_pull=1",
            "pull_atria_state.sh",
            'evidence_dir="logs/live-device/$label"',
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
            "AtriaTodayLiveStatusHost(liveStore: liveStore,",
            # Perf pass (2026-07-06 docs/26 follow-up): AtriaHighlights.topTwo
            # was hoisted out of the Today body into a
            # dailyRollupHistoryRevision-memoized `highlights` property (it was
            # re-sorting the full history up to 4x per ~700ms live tick). The
            # highlights section still renders in this exact slot, so the
            # ordering marker migrates from the (now-hoisted) topTwo call to the
            # section's guard condition, which occupies the same position.
            "if layoutConfig.showHighlights && !highlights.isEmpty",
            # 2026-07-07: same onOpen-route migration as above.
            "AtriaTodayHighlightsStrip(highlights: highlights) { metric in",
            "AtriaTodayPlanCard(title: planTitle,",
            "LazyVGrid(columns: glanceColumns, spacing: AtriaDesignTokens.Spacing.md)",
            "if layoutConfig.showAICoach && effectiveAICoachSettings.mode != .off",
            # 2026-07-07: Journal info row removed (duplicate of shortcut
            # strip value) — see UX-audit commit.
        ]
        positions = [body.index(token) for token in ordered_tokens]
        self.assertEqual(positions, sorted(positions), "Today stack must match 6.1 order")

        day_rollups_start = today.index("private var dayDescendingRollups")
        day_rollups_end = today.index("private var displayRecovery", day_rollups_start)
        day_rollups_source = today[day_rollups_start:day_rollups_end]
        assert_contains(self, day_rollups_source, "let sorted = highlightRollups")
        assert_not_contains(self, day_rollups_source, "highlightRollups.sorted")

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
            "let resolvedSlots = ringSlots.map {",
            "AtriaTriRing(slots: resolvedSlots,",
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

    def test_today_live_store_observation_is_leaf_scoped(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        parent = today[today.index("struct AtriaTodayScreen: View"):today.index("private struct AtriaTodayHeroShrink")]

        for needle in [
            "let liveStore: AtriaHomeModel.CoreLiveStore",
            "AtriaTodayLiveStatusHost(liveStore: liveStore,",
            "AtriaTodayLiveGlanceTileHost(metric: metric,",
            "private var glanceMetrics: [AtriaTodayMetric]",
            "if glanceMemo.glanceMetricsLayoutConfig == layoutConfig,",
            "static func glanceMetrics(for layoutConfig: AtriaHomeLayoutConfig) -> [AtriaTodayMetric]",
            "var glanceMetricsLayoutConfig: AtriaHomeLayoutConfig?",
            "var glanceMetricsValue: [AtriaTodayMetric]?",
            "if glanceMemo.todaySectionOrderCSV == todaySectionOrderCSV,",
            "static func orderedTodaySections(from csv: String) -> [AtriaTodaySection]",
            "var todaySectionOrderCSV: String?",
            "var todaySectionOrderValue: [AtriaTodaySection]?",
            "ForEach(glanceMetrics) { metric in",
        ]:
            assert_contains(self, parent, needle)

        assert_not_contains(self, parent, "@ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore")
        assert_not_contains(self, parent, "liveStore.state")

        for needle in [
            "private struct AtriaTodayLiveStatusHost: View",
            "AtriaTodayLiveStatusStrip(live: liveStore.state,",
            "private struct AtriaTodayLiveGlanceTileHost: View",
            "let live = liveStore.state",
            "value: steps.valueText",
            "value: live.liveActiveCaloriesText",
        ]:
            assert_contains(self, today, needle)

    def test_today_sleep_need_is_revision_memoized(self):
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")

        for needle in [
            "private var sleepNeedSnapshot: AtriaTodaySleepNeedSnapshot",
            "let key = AtriaTodaySleepNeedKey(sleepRevision: sessionProjectionStore.state.sleepHistorySnapshotRevision,",
            "rollupRevision: sessionProjectionStore.state.dailyRollupHistoryRevision",
            "latestNightID: latest?.id",
            "baseNeedHours: sleepBaseNeedHours",
            "if glanceMemo.sleepNeedKey == key, let cached = glanceMemo.sleepNeedValue",
            "glanceMemo.sleepNeedKey = key",
            "glanceMemo.sleepNeedValue = value",
            "private static func makeSleepNeedSnapshot(sleepHistory: SleepHistorySnapshot,",
            "AtriaSleepBudget.performancePercent(slept: latestSleep.durationHours,",
            "private static func yesterdayStrain(for latestSleep: SleepHistorySnapshot.Night,",
            "var sleepNeedKey: AtriaTodaySleepNeedKey?",
            "var sleepNeedValue: AtriaTodaySleepNeedSnapshot?",
            "private struct AtriaTodaySleepNeedKey: Equatable",
            "let sleepRevision: Int",
            "let rollupRevision: Int",
            "let latestNightID: String?",
            "private struct AtriaTodaySleepNeedSnapshot: Equatable",
        ]:
            assert_contains(self, today, needle)

        sleep_source = today[today.index("private var sleepNeedSnapshot:"):
                             today.index("private var sleepMetric: AtriaTriRingMetric")]
        self.assertEqual(sleep_source.count("sleepHistory.sleepNeedHours(for: latestSleep,"), 1)
        assert_not_contains(self, sleep_source, "store.sleepHistorySnapshot.sleepPerformancePercent")
        assert_not_contains(self, sleep_source, "store.dailyRollupHistory\n            .first")

    def test_ia62_strain_detail_lists_workouts_and_zone_minutes(self):
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")

        for needle in [
            "confirmedWorkouts: projection.confirmedWorkouts",
            "confirmedWorkouts: debugMetricDetailWorkouts ?? confirmedWorkouts",
            "let confirmedWorkouts: [UserConfirmedWorkout]",
            # Strain's compact target rail uses the same period value as its
            # headline (Day = latest, Week/Month = average).
            "AtriaMetricDetailTemplate(heroValue: strainHeroValue,",
            "heroStyle: .strain(score: strainHeroRawValue,",
            "strainWorkoutSection",
            "AtriaMetricContributorRows(rows: strainContributorRows, tint: Metrics.electricStrain)",
            "private var strainActivityContributorRows: [AtriaMetricContributorRow]",
            "@State private var todayWorkoutZoneSummaryMemo = AtriaTodayWorkoutZoneSummaryMemo()",
            "private var todayWorkoutZoneSummary: AtriaTodayWorkoutZoneSummary",
            "let workouts = todayWorkoutZoneSummary.workouts",
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

        assert_contains(self, vitals, "confirmedWorkouts: vitals.confirmedWorkouts")
        assert_contains(self, home, '"recovery-detail", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"')
        for needle in [
            "@State private var metricDetail: AtriaMetricDetailKind?",
            ".sheet(item: $metricDetail)",
            "AtriaMetricDetailSheet(metric: detail,",
            "confirmedWorkouts: debugMetricDetailWorkouts ?? sessionProjectionStore.state.confirmedWorkouts",
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
        plan_tab = source(ROOT / "Atria" / "Atria" / "AtriaPlanTab.swift")
        routine = source(ROOT / "Atria" / "Atria" / "AtriaRoutineCard.swift")
        weekly_plan = source(ROOT / "Atria" / "Atria" / "AtriaWeeklyPlan.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "@State private var showWeeklyReport = false",
            "AtriaTodayWeeklyPlanCard(plan: weeklyPlan)",
            "showWeeklyReport = true",
            ".sheet(isPresented: $showWeeklyReport)",
            "AtriaWeeklyReportSheet(report: weeklyReport)",
            "private var weeklyPlan: WeeklyPlan",
            "weeklyPlan = store.currentWeeklyPlan()",
            "sessionProjectionStore.state.weeklyPlan",
            "publisher(for: .NSCalendarDayChanged)",
            "let weekStart = Self.currentISOWeekStart()",
            "private static func currentISOWeekStart(now: Date = Date()) -> Date",
            "private var weeklyReport: WeeklyReport",
            "glanceMemo.weeklyReportRevision == revision",
            "glanceMemo.weeklyReportWeekStart == weekStart",
            "glanceMemo.weeklyReportRevision = revision",
            "glanceMemo.weeklyReportWeekStart = weekStart",
            "glanceMemo.weeklyReportValue = report",
            "var weeklyReportRevision: Int?",
            "var weeklyReportWeekStart: Date?",
            "var weeklyReportValue: WeeklyReport?",
            "WeeklyReport(rollups: highlightRollups)",
            "private struct AtriaTodayWeeklyPlanCard: View, Equatable",
            "ForEach(Array(plan.targets.prefix(3)))",
            ".gaugeStyle(.accessoryLinearCapacity)",
            "private struct AtriaTodayWeeklyPlanTargetRow: View, Equatable",
            "private static func debugShowsWeeklyReport(arguments: [String]) -> Bool",
            "arguments[valueIndex] == \"weekly-report\"",
        ]:
            assert_contains(self, today, needle)
        assert_not_contains(self, today, "WeeklyPlanStore().currentPlan(rollups: highlightRollups)")

        assert_contains(self, overview, "struct AtriaWeeklyReportSheet: View")
        for needle in [
            "weeklyPlan: store.currentWeeklyPlan()",
        ]:
            assert_contains(self, overview, needle)
        for needle in [
            "@StateObject private var projectionStore: AtriaPlanProjectionStore",
            "AtriaWeeklyPlanCard(plan: projectionStore.weeklyPlan)",
            "final class AtriaPlanProjectionStore: ObservableObject",
            "store.$dailyRollupHistory",
            "NotificationCenter.default.publisher(for: .NSCalendarDayChanged)",
            "self.refresh(store.currentWeeklyPlan())",
        ]:
            assert_contains(self, plan_tab, needle)
        for needle in [
            "@StateObject private var projectionStore: AtriaRoutineProjectionStore",
            "let summary = projectionStore.summary",
            "final class AtriaRoutineProjectionStore: ObservableObject",
            "store.$dailyRollupHistory",
            "store.$dashboardRevision",
            "refreshForJournalRevision(store.behaviorJournalRevision,",
            "NotificationCenter.default.publisher(for: .NSCalendarDayChanged)",
            "AtriaRoutineComputer.summary(rollups: rollups,",
        ]:
            assert_contains(self, routine, needle)
        for needle in [
            "private(set) var behaviorJournalRevision = 0",
            "behaviorJournalRevision &+= 1",
            "private var cachedWeeklyPlanRevision: Int?",
            "private var cachedWeeklyPlanWeekStart: Date?",
            "private var cachedWeeklyPlanValue: WeeklyPlan?",
            "func currentWeeklyPlan(now: Date = Date()) -> WeeklyPlan",
            "weeklyPlanStore.currentPlan(rollups: dailyRollupHistory,",
        ]:
            assert_contains(self, sessions, needle)
        assert_not_contains(self, today, "ForEach(plan.targets)")
        assert_not_contains(self, plan_tab, "private var weeklyPlan: WeeklyPlan")
        assert_not_contains(self, plan_tab, "@ObservedObject var store: SessionStore")
        assert_not_contains(self, plan_tab, "AtriaPlanTabWeeklyPlanMemo")
        assert_not_contains(self, routine, "let summary = AtriaRoutineComputer.summary(rollups: store.dailyRollupHistory,")

        current_plan_start = weekly_plan.index("    func currentPlan(")
        current_plan_end = weekly_plan.index("\n    func plan(", current_plan_start)
        current_plan_source = weekly_plan[current_plan_start:current_plan_end]
        assert_contains(self, current_plan_source, "let freshByKind = Dictionary(uniqueKeysWithValues: WeeklyPlan.generate(from: rollups,")
        self.assertEqual(current_plan_source.count("WeeklyPlan.generate(from: rollups,"), 1)
        assert_not_contains(self, current_plan_source, "recomputed(target, rollups:")
        assert_not_contains(self, weekly_plan, "private func recomputed")

        generate_start = weekly_plan.index("    static func generate(from rollups:")
        generate_end = weekly_plan.index("    private static func bedtimeTarget", generate_start)
        generate_source = weekly_plan[generate_start:generate_end]
        for needle in [
            "let windows = rollupWindows(rollups: rollups, weekStart: weekStart, recentLimit: 28)",
            "private static func rollupWindows(rollups: [DailyRollupStoreEntry],",
            "recent.count < recentLimit",
            "entry.day > oldest.day",
            "insertRecentEntry(entry, into: &recent)",
            "private static func insertRecentEntry",
        ]:
            assert_contains(self, generate_source, needle)
        assert_not_contains(self, generate_source, "let ordered = rollups.sorted")
        assert_not_contains(self, generate_source, "ordered.filter")
        assert_not_contains(self, generate_source, "Array(ordered.prefix(28))")

        recent_entries_start = routine.index("    private static func recentEntries(")
        recent_entries_end = routine.index("    private static func bedtimeTargetMinute", recent_entries_start)
        recent_entries_source = routine[recent_entries_start:recent_entries_end]
        for needle in [
            "guard count > 0 else { return [] }",
            "recent.count < count",
            "entry.day > oldest.day",
            "insertRecentEntry(entry, into: &recent)",
            "private static func insertRecentEntry",
        ]:
            assert_contains(self, recent_entries_source, needle)
        assert_not_contains(self, recent_entries_source, ".sorted { $0.day > $1.day }")
        assert_not_contains(self, recent_entries_source, ".prefix(count)")

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
            "enum AtriaShareComposerLayout",
            "static let storyAspectRatio: CGFloat = 9.0 / 16.0",
            "static func fittedStorySize(in availableSize: CGSize) -> CGSize",
            "private var shareComposer: some View",
            "private var topControls: some View",
            "controlDock",
            "canvasPicker",
            "@State private var controlsRefreshID = UUID()",
            ".id(controlsRefreshID)",
            "GlassEffectContainer(spacing: 12)",
            "AtriaGlassIconButtonStyle(tint: .white, size: 38)",
            "private struct AtriaSystemShareSheet: UIViewControllerRepresentable",
            ".sheet(item: $sharePayload)",
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
            ".padding(.top, format == .story ? 52 : 34)",
            ".padding(.top, format == .story ? 18 : 16)",
            ".padding(.leading, format == .story ? 36 : 34)",
            ".padding(.trailing, format == .story ? 44 : 34)",
            "private var dailyHeroSize: CGFloat",
            "format == .story ? 218 : 220",
            "ring(snapshot.sleep, diameter: format == .story ? 218 : 220",
            "Spacer(minLength: format == .story ? 88 : 48)",
            "GeometryReader { proxy in",
            ".background(Color.black.ignoresSafeArea())",
            "let availableWidth = max(availableSize.width, 1)",
            "let availableHeight = max(availableSize.height, 1)",
            "private func previewSize(for size: CGSize) -> CGSize",
            "AtriaShareComposerLayout.fittedStorySize(in: size)",
            ".frame(height: AtriaShareComposerLayout.styleRailHeight)",
            "let width = min(availableWidth, availableHeight * storyAspectRatio)",
            "return CGSize(width: width, height: width / storyAspectRatio)",
            ".scaleEffect(previewScale(for: proxy.size), anchor: .center)",
            "private func previewScale(for size: CGSize) -> CGFloat",
            "previewSize(for: size).height / AtriaShareFormat.story.renderSize.height",
            "fixed-daily-trio",
            "canvasButtonLabel(title: \"Clear\"",
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
        assert_not_contains(self, share, ".task(id: renderKey)")
        assert_not_contains(self, share, "Task.sleep(for: .milliseconds(120))")
        assert_not_contains(self, share, "@State private var shareURL")
        for needle in [
            "private func prepareShare()",
            "private func prepareShare(_ kind: ExportKind)",
            "private func prepareWeeklyShare()",
            "renderKey == requestedRenderKey",
            "exportTask?.cancel()",
            "ProgressView()",
            "static func dailyCacheKey(snapshot:",
            "static func weeklyCacheKey(snapshot:",
            'return "daily-\\(stableDigest(content))"',
            'return "weekly-\\(stableDigest(content))"',
            "renderedImageURL: imageURL",
            "removeRenderedImageAfterEmbedding: requestedPhotoBackground != nil",
            "cameraPreparationTask?.cancel()",
            "AtriaSharePhotoPreparation.acceptsResult(",
            "completionWithItemsHandler",
            "releaseTemporaryExport(at: payload.url)",
            ".completeFileProtection",
            "FileProtectionType.completeUnlessOpen",
            "private static let cacheCapacity = 24",
            "while cacheRecency.count > cacheCapacity",
            "await removeExportFile(evictedURL)",
            "withTaskCancellationHandler",
            'let routePresence = snapshot.routeFileURL == nil ? "route-absent" : "route-present"',
        ]:
            assert_contains(self, share, needle)
        self.assertEqual(share.count(".sheet(item: $sharePayload)"), 3)
        self.assertEqual(share.count('photoBackground == nil ? "canvas" : UUID().uuidString'), 2)
        daily_sheet = re.search(r"struct AtriaShareSheet: View \{(?P<body>.*?)\nstruct AtriaWorkoutShareSheet", share, re.S)
        self.assertIsNotNone(daily_sheet)
        # 2026-07-13 share-editor requirement: only Cancel at upper-left and
        # Share at upper-right. Saving remains available from the system share
        # sheet instead of duplicating a download action in the header.
        assert_contains(self, daily_sheet.group("body"), 'Button { dismiss() } label:')
        assert_contains(self, daily_sheet.group("body"), 'shareCornerButton(systemImage: "xmark")')
        assert_contains(self, daily_sheet.group("body"), '.accessibilityLabel("Cancel")')
        assert_not_contains(self, daily_sheet.group("body"), 'saveShareCardToPhotos')
        assert_not_contains(self, daily_sheet.group("body"), 'Download image to Photos')
        assert_not_contains(self, daily_sheet.group("body"), 'shareToolbarLabel("Done", systemImage: "checkmark")')
        assert_not_contains(self, daily_sheet.group("body"), "shareToolbarLabel(saveState.label, systemImage: saveState.systemImage)")
        assert_not_contains(self, daily_sheet.group("body"), 'Picker("Format"')
        assert_not_contains(self, daily_sheet.group("body"), "@State private var selectedStatIDs")
        assert_not_contains(self, daily_sheet.group("body"), "statPicker")
        assert_not_contains(self, daily_sheet.group("body"), "toggleStat")
        assert_not_contains(self, daily_sheet.group("body"), "statButtonLabel")
        assert_not_contains(self, daily_sheet.group("body"), "ToolbarItem")
        assert_contains(self, daily_sheet.group("body"), "controlDock\n                .frame(height: AtriaShareComposerLayout.styleRailHeight)")
        workout_sheet = re.search(r"struct AtriaWorkoutShareSheet: View \{(?P<body>.*?)\nprivate struct AtriaShareCameraPicker", share, re.S)
        self.assertIsNotNone(workout_sheet)
        assert_not_contains(self, workout_sheet.group("body"), 'Picker("Format"')
        assert_not_contains(self, workout_sheet.group("body"), "ScrollView(showsIndicators: false)")
        assert_not_contains(self, workout_sheet.group("body"), "ToolbarItem")
        assert_contains(self, workout_sheet.group("body"), "controlDock\n                .frame(height: AtriaShareComposerLayout.styleRailHeight)")
        weekly_sheet = re.search(r"struct AtriaWeeklyShareSheet: View \{(?P<body>.*?)\n@MainActor", share, re.S)
        self.assertIsNotNone(weekly_sheet)
        assert_not_contains(self, weekly_sheet.group("body"), 'Picker("Format"')
        assert_not_contains(self, weekly_sheet.group("body"), "ScrollView(showsIndicators: false)")
        assert_not_contains(self, share, 'Image("AtriaLogo")')
        assert_not_contains(self, share, "private func atriaLogoMark(size: CGFloat) -> some View")
        assert_not_contains(self, share, "private func atriaFallbackGlyph(size: CGFloat) -> some View")
        assert_not_contains(self, share, "private func shareToolbarLabel")
        corner_buttons = re.findall(
            r"private func shareCornerButton\([^)]*\) -> some View \{(?P<body>.*?)\n    \}",
            share,
            re.S,
        )
        self.assertEqual(len(corner_buttons), 3)
        for corner_button in corner_buttons:
            assert_not_contains(self, corner_button, ".glassEffect(")
            assert_contains(self, corner_button, ".frame(width: 18, height: 18)")
            assert_not_contains(self, corner_button, ".contentShape(Circle())")
        self.assertEqual(share.count("AtriaGlassIconButtonStyle(tint: .white, size: 38)"), 6)
        self.assertEqual(share.count("GlassEffectContainer(spacing: 12)"), 3)
        self.assertEqual(share.count(".buttonBorderShape(.circle)"), 0)
        assert_contains(self, plist, "NSCameraUsageDescription")
        assert_contains(self, plist, "NSPhotoLibraryUsageDescription")
        assert_not_contains(self, plist, "NSPhotoLibraryAddUsageDescription")

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

        assert_contains(self, live_workout, 'Label("Broadcast HR", systemImage: "antenna.radiowaves.left.and.right")')
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
            'value: incomplete && !displayHero.strainValue.hasPrefix("≥")',
            '? "≥ \\(displayHero.strainValue)"',
            # 2026-07-28 deterministic-presentation pass: the strain marker is now
            # compact fixed vocabulary ("lower bound") instead of prose describing
            # the plumbing ("Partial · sparse HR"), so the reserved status line
            # cannot wrap and change a card's height. The "≥" lower-bound prefix
            # pinned above is unchanged and still carries the same meaning.
            'incomplete ? "lower bound"',
            # Strain-ring-semantics pass (2026-07-05): the ring fill switched from
            # strain-relative-to-target to absolute strain/21 (WHOOP scale), with the
            # former strain/target math now driving the ring's target marker instead
            # (targetFraction) -- see AtriaTriRing.swift's always-colorful-rings +
            # target-marker work landing alongside this pin update.
            # 2026-07-18: shared truth projection restores the canonical 0-21
            # strain scale; the actual value owns fill while only a real target
            # owns achievement color and the marker.
            "let fill = AtriaRingMetricProjection.strainFill(",
            "targetFraction: incomplete || pending ? nil : AtriaRingMetricProjection.strainTargetFraction(target)",
            "AtriaWorkoutMetricPresentation.cycleStrainIsIncomplete(",
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
            # displayRecovery uses the canonical physiological-cycle hero and
            # keeps the same nap-lift detail inside that single source of truth.
            "value: display.value",
            'let detail = displayHero.recoveryLiftedAfterNap ? "↑ after nap" : displayHero.recoveryDetail',
        ]:
            assert_contains(self, today, needle)

        display_start = today.index("private var displayRecovery")
        display_end = today.index("/// HRV glance carry", display_start)
        display_source = today[display_start:display_end]
        assert_contains(self, display_source, "if let percent = estimate.percent")
        assert_not_contains(self, display_source, "newestStored")
        assert_not_contains(self, display_source, '"yesterday"')

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
            "private struct RRInputKey: Equatable",
            "private var currentRRInputKey: RRInputKey",
            "private struct FinishArtifacts",
            "let currentRRSamples: [RRSample]",
            "@State private var rrSamples: [RRSample] = []",
            'Text("Relax · \\(timeText(remaining))")',
            "Text(\"5.5 breaths/min\")",
            "Picker(\"Duration\", selection: $selectedDuration)",
            "Label(\"Start\", systemImage: \"play.fill\")",
            "Label(currentHeartRate > 0 ? \"\\(currentHeartRate) bpm\" : \"HR learning\"",
            "let onSave: (SavedSession) -> Void",
            "let artifacts = Self.finishArtifacts(samples: samples, rrSamples: rrSamples, start: start, end: end)",
            "private static func finishArtifacts(samples: [HeartSample],",
            "averageHR(sum: startingSum, count: startingCount)",
            "rmssd(inWindow: startingRR, duration: firstWindowEnd.timeIntervalSince(start))",
            "AtriaShortWindowRMSSD.value(",
            "static func savedSession(samples: [HeartSample],",
            "rrPoints: rrPoints.isEmpty ? nil : rrPoints",
            "private static func rmssd(in samples: [RRSample], start: Date, end: Date) -> Double?",
            "* 0.8",
            "label: \"Breathwork\"",
            "kind: \"breathwork\"",
            ".onChange(of: currentRRInputKey) { _, _ in",
            "appendNewRRSamples(currentRRSamples)",
            "for sample in values.reversed()",
            "guard sample.date > newestExisting else { break }",
            "fresh.reverse()",
        ]:
            assert_contains(self, breathwork, needle)
        finish_start = breathwork.index("private func finish()")
        finish_end = breathwork.index("private func timeText", finish_start)
        finish_source = breathwork[finish_start:finish_end]
        assert_not_contains(self, finish_source, "Self.summarize(")
        assert_not_contains(self, finish_source, "Self.savedSession(")
        assert_not_contains(self, breathwork, ".onChange(of: currentRRSamples)")
        append_start = breathwork.index("private func appendNewRRSamples")
        append_end = breathwork.index("private static func rmssd", append_start)
        append_source = breathwork[append_start:append_end]
        assert_not_contains(self, append_source, ".sorted { $0.date < $1.date }")

        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaAnalyticsTests.swift")
        for needle in [
            "var kind: String? = nil",
            "var isBreathwork: Bool",
            'guard !isBreathwork, sleepWakeResearchState != "sleep_research" else { return 0 }',
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
            "Text(summary.compactStatusText)",
            "Text(summary.footnote)",
            '"Fitness age. \\(summary.valueText).',
        ]:
            assert_contains(self, health, needle)

        assert_contains(self, fitness, 'static let footnoteText = "Estimate from heart data — not a medical measurement."')

    def test_live_activity_uses_workout_metrics_and_language(self):
        app_attributes = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityAttributes.swift")
        widget_attributes = source(ROOT / "Atria" / "AtriaWidget" / "AtriaLiveActivityAttributes.swift")
        coordinator = source(ROOT / "Atria" / "Atria" / "AtriaLiveActivityCoordinator.swift")
        widget = source(ROOT / "Atria" / "AtriaWidget" / "AtriaWidget.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        for text in [app_attributes, widget_attributes, coordinator]:
            assert_contains(self, text, "readingCount")
            assert_not_contains(self, text, "sampleCount")

        assert_contains(self, home, "readingCount: model.coreLiveStore.state.sessionSampleCount")
        for needle in ["activityName", "activitySystemImage", "heartRateZoneIndex", "heartRateZoneName", "steps", "workoutStrain"]:
            assert_contains(self, app_attributes, needle)
            assert_contains(self, widget_attributes, needle)
            assert_contains(self, coordinator, needle)
        assert_contains(self, home, "isRecording: session != nil")
        assert_contains(self, widget, "liveActivityZoneLabel(for: context.state,")
        assert_contains(self, widget, "availability: heartAvailability")
        assert_contains(self, widget, "liveActivityStepsPresentation(for: context.state)")
        assert_contains(self, widget, "liveActivityDailyStepGoalPresentation(for: context.state)")
        assert_contains(self, home, 'UserDefaults.standard.integer(forKey: "atria.target.steps.goal")')
        assert_contains(self, widget, "Text(state.timerAnchor ?? startedAt, style: .timer)")
        assert_contains(self, widget, "state.elapsedDuration")
        assert_not_contains(self, widget, "context.state.readingCount")
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
            "if heartRate <= 0 {",
            'reason: "live_signal_cleared"',
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
            "heartRate: liveHeartRate > 0 ? liveHeartRate : nil",
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
            "else if tab == .chat",
            "showAssistant = true",
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
            "case .systemLarge:\n                    systemLargeWidget",
            "private var systemLargeWidget: some View",
            "private var widgetHeader: some View",
            "private func compactMetric(_ title: String,",
            "private func widgetMetricTile(_ title: String,",
            "evidenceNote: String?",
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
            "private let minimumActivityUpdateInterval: TimeInterval = 5",
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
            "let recoveryIsLearning = heroStore.state.recoveryEstimate.percent == nil",
            "recoveryIsLearning: recoveryIsLearning",
        ]:
            assert_contains(self, home, needle)

    def test_home_profile_metrics_are_keyed_before_bio_age_recompute(self):
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        for needle in [
            "dailyMetricHistoryRevision &+= 1",
            "private(set) var dailyMetricHistoryRevision = 0",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "private struct ProfileMetricsKey: Equatable",
            "let profileAge: Int",
            "let dailyMetricRevision: Int",
            "let sleepRevision: Int",
            "let trainingLoad: TrainingLoadSummary",
            "private var profileMetricsKey: ProfileMetricsKey?",
            "let initialProfileMetricsKey = Self.profileMetricsKey(store: store,",
            "self.profileMetricsKey = initialProfileMetricsKey",
            "guard key != profileMetricsKey else { return }",
            "profileMetricsKey = key",
            "private static func profileMetricsKey(store: SessionStore,",
            "profileAge: store.profile.age",
            "dailyMetricRevision: store.dailyMetricHistoryRevision",
            "sleepRevision: store.sleepHistorySnapshotRevision",
            "trainingLoad: store.trainingLoadSummarySnapshot",
        ]:
            assert_contains(self, home, needle)
        profile_key_start = home.index("private struct ProfileMetricsKey: Equatable")
        profile_key_end = home.index("private struct PulseWindowSummary", profile_key_start)
        profile_key_source = home[profile_key_start:profile_key_end]
        assert_not_contains(self, profile_key_source, "dailyRollupRevision")
        assert_not_contains(self, profile_key_source, "latestLocalRMSSD")
        assert_not_contains(self, profile_key_source, "todayHRZoneMinutes")

        key_builder_start = home.index("private static func profileMetricsKey(store: SessionStore,")
        key_builder_end = home.index("\n    }\n\n    private static func makeSavedAggregate", key_builder_start)
        key_builder_source = home[key_builder_start:key_builder_end]
        assert_not_contains(self, key_builder_source, "store.dailyRollupHistoryRevision")
        assert_not_contains(self, key_builder_source, "store.latestLocalRMSSD")
        assert_not_contains(self, key_builder_source, "store.todayHRZoneMinutesSnapshot")

        publish_start = home.index("private func publishProfileMetrics()")
        publish_end = home.index("\n    }\n\n    private func refreshSavedAggregate", publish_start)
        publish_source = home[publish_start:publish_end]
        self.assertLess(publish_source.index("guard key != profileMetricsKey else { return }"),
                        publish_source.index("Self.makeProfileMetricsState(store: store,"))

    def test_skin_temperature_summary_is_cached_by_source_revisions(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        perf_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")

        for needle in [
            "struct SkinTemperatureDeviationSummaryCache: Equatable",
            "private var cachedSkinTemperatureDeviationSummary: SkinTemperatureDeviationSummaryCache?",
            "Self.isSkinTemperatureDeviationSummaryCacheFresh(cached,",
            "dailyMetricRevision: dailyMetricHistoryRevision",
            "dailyRollupRevision: dailyRollupHistoryRevision",
            "cachedSkinTemperatureDeviationSummary = SkinTemperatureDeviationSummaryCache(",
            "nonisolated static func isSkinTemperatureDeviationSummaryCacheFresh(",
            "record.dailyMetricRevision == dailyMetricRevision",
            "&& record.dailyRollupRevision == dailyRollupRevision",
            "&& record.fallback == fallback",
        ]:
            assert_contains(self, sessions, needle)

        summary_start = sessions.index("var skinTemperatureDeviationSummary: IMUAuditSummary.SkinTemperatureDeviationSummary")
        summary_end = sessions.index("\n    }\n    @Published private(set) var researchManeuverProbeCorrelationSummary", summary_start)
        summary_source = sessions[summary_start:summary_end]
        self.assertLess(summary_source.index("Self.isSkinTemperatureDeviationSummaryCacheFresh(cached,"),
                        summary_source.index("latestFinalizedSkinTemperatureDeviationCelsius()"))

        for needle in [
            "func testFinalizedSkinTemperatureDeviationUsesExpandingHistoricalBaseline()",
            "func testSkinTemperatureDeviationSummaryCacheTracksSourceRevisionsAndFallback()",
            "SessionStore.SkinTemperatureDeviationSummaryCache(dailyMetricRevision: 7,",
            "XCTAssertTrue(SessionStore.isSkinTemperatureDeviationSummaryCacheFresh(record,",
            "dailyMetricRevision: 8",
            "dailyRollupRevision: 12",
            "changedFallback",
        ]:
            assert_contains(self, perf_tests, needle)

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
            + list((ROOT / "tools").rglob("*.py"))
            + [
                ROOT / "test_handoff_static_checks.py",
                ROOT / "live_device_debug.sh",
            ]
        )

        for path in paths:
            text = source(path)
            for line_number, line in enumerate(text.splitlines(), start=1):
                if path.suffix == ".swift" and line.lstrip().startswith("//"):
                    continue
                for variant in variants:
                    self.assertIsNone(
                        variant.search(line),
                        f"{path.relative_to(ROOT)}:{line_number} contains placeholder bypass wording",
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

        # 2026-07-12: the pure async-delivery revalidation helper reads this
        # immutable threshold from a nonisolated context.
        assert_contains(self, notifications, "private nonisolated static let actionableBatteryThreshold = 25")
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
        assert_contains(self, notifications, "maxAge: AtriaBLEManager.batteryDisplayFreshnessLimit")
        assert_contains(self, notifications, "AtriaBLEManager.cachedBatteryDrop()")
        assert_contains(self, notifications, "live_2A19_fresh")
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
            "requestOfflineHistoricalSyncAwaitingCompletion(",
            "reason: \"\\(reason)_opportunistic\"",
            "offline_sync_required=%d",
            "offline_sync_succeeded=%d",
            "store.performBackgroundMaintenanceAsynchronously(reason: reason)",
        ]:
            assert_contains(self, app, needle)

        maintenance = re.search(
            r"func performBackgroundMaintenance\(reason: String,\s*"
            r"now: Date,\s*calendar: Calendar,\s*"
            r"backupCompletion: \(@MainActor \(Bool\) -> Void\)\? = nil,\s*"
            r"persistenceAlreadyFlushed: Bool = false\) \{(?P<body>.*?)\n    \}",
            sessions,
            re.S,
        )
        self.assertIsNotNone(maintenance)
        maintenance_body = maintenance.group("body")
        for needle in [
            "flushScheduledPersistence(reason:",
            "autoConfirmSleepOnForegroundIfUseful(",
            "writeAutomaticSessionBackup(reason: reason,",
            "completion: backupCompletion",
            "HealthKitExporter.diagnostics(",
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
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        rollup_store = source(ROOT / "Atria" / "Atria" / "DailyRollupStore.swift")

        for needle in [
            "@Published private(set) var dailyRollupHistory: [DailyRollupStoreEntry] = []",
            "self.dailyRollupHistory = recoveryBlocked ? [] : dailyRollupStore.rollups(last: 400)",
            "dailyRollupHistory = dailyRollupStore.rollups(last: 400)",
        ]:
            assert_contains(self, sessions, needle)
        rollups_body = re.search(r"func rollups\(last count: Int\) -> \[DailyRollupStoreEntry\] \{(?P<body>.*?)\n    \}", rollup_store, re.S)
        self.assertIsNotNone(rollups_body)
        assert_contains(self, rollups_body.group("body"), "Array(cache.prefix(max(0, count)))")
        assert_not_contains(self, rollups_body.group("body"), "cache.sorted")
        for needle in [
            "private var cacheIndexByDay: [Date: Int] = [:]",
            "rebuildCacheIndex()",
            "guard let index = cacheIndexByDay[normalized] else { return nil }",
            "if let index = cacheIndexByDay[normalized.day]",
            "if insertedNewDay {\n            cache.sort { $0.day > $1.day }\n            rebuildCacheIndex()",
            "private func rebuildCacheIndex()",
        ]:
            assert_contains(self, rollup_store, needle)
        upsert_body = re.search(r"func upsertMany\(_ rollups: \[DailyRollupStoreEntry\]\) \{(?P<body>.*?)\n    \}", rollup_store, re.S)
        self.assertIsNotNone(upsert_body)
        assert_not_contains(self, upsert_body.group("body"), "cache.removeAll")

        for needle in [
            "dailyRollupHistory: store.dailyRollupHistory",
            "let dailyRollupHistory: [DailyRollupStoreEntry]",
            "let detailRollups = debugMetricDetailRollups ?? dailyRollupHistory",
            "AtriaMetricDetailSheet(metric: detail,\n                                   rollups: detailRollups,",
            "rollupsRevision: debugMetricDetailRollups == nil ? dailyRollupHistoryRevision : nil,",
            "confirmedWorkoutsRevision: debugMetricDetailWorkouts == nil ? confirmedWorkoutsRevision : nil,",
            "sleepHistoryRevision: sleepHistoryRevision,",
            "private var debugMetricDetailRollups: [DailyRollupStoreEntry]?",
            "init(metric: AtriaMetricDetailKind,\n         rollups: [DailyRollupStoreEntry],",
            "rollupsRevision: Int? = nil,",
            "confirmedWorkoutsRevision: Int? = nil,",
            "sleepHistoryRevision: Int? = nil,",
            "@State private var expandedChartEventsCache = ExpandedChartEventsCache()",
            "private final class ExpandedChartEventsCache",
            "expandedChartEventsCache.value(key: expandedChartEventsKey)",
            "private var expandedChartEventsKey: Int",
            "if let confirmedWorkoutsRevision",
            "if let sleepHistoryRevision",
            "private let preparationBaseInput: AtriaMetricDetailPreparationInput",
            "private var preparationInput: AtriaMetricDetailPreparationInput",
            "@State private var preparation = AtriaStaleWhileRefreshState<",
            "self.preparationBaseInput = AtriaMetricDetailPreparationInput(",
            ".task(id: preparationInput)",
            "private actor AtriaMetricDetailPreparationCache",
            "let prepared = await Task.detached(priority: .userInitiated)",
            "AtriaPreparedMetricHistory(input: input)",
            "guard !Task.isCancelled, preparation.requestedKey == input else { return }",
            "let rollupsRevision: Int?",
            "let rollups: [Rollup]",
            "let referenceDate: Date",
            "item.recovery.map",
            "guard let lnRMSSD = item.lnRMSSD else { return nil }",
            "guard let value = item.restingHeartRate else { return nil }",
            "guard let duration = item.sleepSeconds, duration > 0 else { return nil }",
            "item.respiratoryRate.map",
            "item.strain.map",
        ]:
            assert_contains(self, overview, needle)

        for source_text in [vitals, health, today]:
            assert_contains(self, source_text, "AtriaMetricDetailSheet(metric: detail,")
            assert_contains(self, source_text, "confirmedWorkoutsRevision: ")
        for source_text in [vitals, health]:
            assert_contains(self, source_text, "sleepHistoryRevision: vitals.sleepHistorySnapshotRevision")
        assert_contains(self, today, "sleepHistoryRevision: sessionProjectionStore.state.sleepHistorySnapshotRevision")
        assert_contains(self, vitals, "AtriaMetricDetailSheet(metric: detail,\n                                   rollups: vitals.dailyRollupHistory,\n                                   rollupsRevision: vitals.dailyRollupHistoryRevision,")
        for needle in [
            "@State private var healthMonitorPreparedMemo = AtriaHealthMonitorPreparedMemo()",
            "AtriaHealthMonitorCard(preparedData: healthMonitorPreparedData,",
            "private var healthMonitorPreparedData: AtriaHealthMonitorPreparedData",
            "healthMonitorPreparedMemo.value(rollupsRevision: vitals.dailyRollupHistoryRevision,",
            "sleepHistoryRevision: vitals.sleepHistorySnapshotRevision",
            "AtriaHealthMonitorPreparedData(rollups: Array(vitals.dailyRollupHistory.prefix(28)),",
            "private var healthMonitorRecoveryEstimate: Metrics.RecoveryEstimate",
            # Health Monitor must show the same immutable current-cycle recovery
            # as Home, including confidence/provenance/no-sleep handling. The
            # newest calendar rollup can still be from the prior cycle.
            "heroStore.state.recoveryEstimate",
            # 2026-07-12: Health consumes the canonical frozen hero guidance.
            "heroStore.state.guidance",
            "private final class AtriaHealthMonitorPreparedMemo",
            "private var prepared: AtriaHealthMonitorPreparedData?",
            "let preparedData: AtriaHealthMonitorPreparedData",
            "let rows = rows(prepared: preparedData)",
            "private struct AtriaHealthMonitorPreparedData",
            "init(rollups newestFirstRollups: [DailyRollupStoreEntry], sleepHistory: SleepHistorySnapshot)",
            "sparklineRestingHeartRates = Self.sparkPoints(values: Array(restingHeartRates.prefix(7)))",
            "rangeRespiratoryRates = Self.sparkPoints(values: respiratoryRates)",
        ]:
            assert_contains(self, vitals, needle)
        health_monitor_recovery = re.search(
            r"private var healthMonitorRecoveryEstimate: Metrics\.RecoveryEstimate \{(?P<body>.*?)\n    \}",
            vitals,
            re.S,
        )
        self.assertIsNotNone(health_monitor_recovery)
        recovery_body = health_monitor_recovery.group("body")
        assert_contains(self, recovery_body, "heroStore.state.recoveryEstimate")
        assert_not_contains(self, recovery_body, "dailyRollupHistory")
        assert_not_contains(self, recovery_body, "confidence: .validated")
        for needle in [
            "enum AtriaHealthMetricAuthority",
            "case currentCycle(CurrentCycle)",
            "case datedHistory(DailyRollupStoreEntry)",
            "heroStore.state.recoveryEstimate",
        ]:
            assert_contains(self, health, needle)
        prepared_start = overview.index("private struct AtriaPreparedMetricHistory")
        # 2026-07-07: chart point type became internal so the shared
        # expanded-chart component (AtriaExpandedChart.swift) can consume it.
        prepared_end = overview.index("struct AtriaDetailChartPoint", prepared_start)
        prepared_source = overview[prepared_start:prepared_end]
        input_start = overview.index("private struct AtriaMetricDetailPreparationInput")
        input_end = overview.index("private actor AtriaMetricDetailPreparationCache", input_start)
        input_source = overview[input_start:input_end]
        assert_not_contains(self, overview, "dailyMetricHistory: store.dailyMetricHistory")
        assert_not_contains(self, overview, "let dailyMetricHistory: [SavedDailyMetric]")
        assert_not_contains(self, overview, "debugMetricDetailHistory")
        assert_not_contains(self, overview, "private static func dailyRollupEntries(from history: [SavedDailyMetric])")
        assert_not_contains(self, input_source, "let rollups: [DailyRollupStoreEntry]")
        assert_contains(self, input_source, "struct Rollup: Equatable, Sendable")
        assert_contains(self, input_source, "let rollups: [Rollup]")
        assert_not_contains(self, prepared_source, "history: [SavedDailyMetric]")
        assert_not_contains(self, prepared_source, "item.recoveryPercent")
        assert_not_contains(self, prepared_source, "item.restingHR")
        assert_not_contains(self, prepared_source, "item.sleepDuration")
        prepared_init_start = prepared_source.index("    init(input: AtriaMetricDetailPreparationInput)")
        prepared_init_end = prepared_source.index("    private static func hrvTint", prepared_init_start)
        prepared_init_source = prepared_source[prepared_init_start:prepared_init_end]
        for needle in [
            "let chronologicalRollups = Array(rollups.reversed())",
            "let projection = AtriaMetricPeriodIndexProjection(",
            "days: chronologicalRollups.map(\\.day)",
            "let filtered = projection.currentIndices.map { chronologicalRollups[$0] }",
            "let priorFiltered = projection.priorIndices.map { chronologicalRollups[$0] }",
        ]:
            assert_contains(self, prepared_init_source, needle)
        assert_not_contains(self, prepared_init_source, "rollups.sorted")
        assert_not_contains(self, prepared_init_source, ".filter { $0.day >= cutoff }.sorted")
        assert_not_contains(self, prepared_init_source, ".filter { $0.day >= previousCutoff && $0.day < cutoff }\n                .sorted")
        health_monitor_start = vitals.index("private struct AtriaHealthMonitorCard")
        health_monitor_end = vitals.index("private struct AtriaHealthMonitorRow", health_monitor_start)
        health_monitor_source = vitals[health_monitor_start:health_monitor_end]
        assert_not_contains(self, health_monitor_source, "SavedDailyMetric")
        assert_not_contains(self, health_monitor_source, "dailyMetrics")
        tab_start = vitals.index("struct AtriaVitalsTabContent: View")
        tab_end = vitals.index("enum AtriaVitalsSection", tab_start)
        tab_source = vitals[tab_start:tab_end]
        assert_not_contains(self, tab_source, "DailyRollupStore()")
        assert_not_contains(self, tab_source, ".onAppear(perform: refreshHealthMonitorRollups)")
        assert_not_contains(self, tab_source, "@State private var healthMonitorRollups")
        assert_not_contains(self, health_monitor_source, "private var sortedRollups")
        assert_not_contains(self, health_monitor_source, "let prepared = AtriaHealthMonitorPreparedData")
        assert_not_contains(self, health_monitor_source, ".sorted { $0.day > $1.day }")
        assert_not_contains(self, vitals, "healthMonitorRollups.sorted")
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
            "active_journal_segments_status=partial_copy",
            "active_journal_segment_parse_status=",
            "active_journal_segment_id_status=",
            "active_journal_segment_sequence_status=",
            "active_journal_segment_sample_continuity_status=",
            "active_journal_segment_rr_continuity_status=",
            "active_journal_segment_reconstruction_status=invalid",
            "active_journal_torn_copy_status=detected",
            "active_journal_torn_copy_freshness=",
            "active_journal_reconstructed_from_segments=1",
            "active_journal_final_status=ok",
            "active_journal_final_status={journal_integrity_status}",
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
            "confirmed_workouts_incomplete_coverage_count=",
            "lowest_coverage_workout_percent=",
            "lowest_coverage_workout_observed_s=",
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
            "private func refreshBackupStatusCacheDeferred(reason: String,",
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
        assert_contains(self, deferred_load_preparation.group("body"), "let latestLocalRMSSD: Int?")

        prepare_start = sessions.index("private nonisolated static func prepareDeferredLoad")
        prepare_end = sessions.index("private nonisolated static func shouldRebuildBaselineAfterLoading", prepare_start)
        prepare_source = sessions[prepare_start:prepare_end]
        assert_contains(self, prepare_source, "let latestLocalSource = latestLocalRMSSDSource(in: decoded)")
        assert_contains(self, prepare_source, "latestLocalRMSSDSource: latestLocalSource")
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
            "if metricUsable(object: object)",
            "metricLayoutValidated(layoutVersion)",
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

        refresh_start = sessions.index("func refreshHistoricalArchiveStatus(")
        refresh_end = sessions.index("private func refreshHistoricalTodayHeartRateCache", refresh_start)
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
            "let targetBytes = UInt64(max(4_194_304, min(100_663_296, limit * 1_024)))",
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
            "let samples = loadRecentGravitySamples(start: start, end: end)",
            "private static func loadRecentGravitySamples(start: Date, end: Date) -> [GravitySample]",
            "let estimatedRows = Int((spanSeconds / 2.0).rounded(.up)) + 720",
            "let targetBytes = UInt64(max(2_097_152, min(8_388_608, estimatedRows * 640)))",
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
            "private static let recentGravityCacheLock = NSLock()",
            "private static var recentGravityLoadInFlight = false",
            "if recentGravityLoadInFlight",
            "if Thread.isMainThread",
            "DispatchQueue.global(qos: .utility).async",
            "loadRecentGravitySamplesUncached(targetBytes: targetBytes)",
            'return emptyMotionWindow(status: "learning", reason: "full_archive_requires_background")',
            "static func makeMotionArchiveSnapshot() -> MotionArchiveSnapshot",
            'precondition(!Thread.isMainThread, "Full historical motion decoding must run off the main thread")',
        ]:
            assert_contains(self, archive, needle)

        for needle in [
            "enum HistoricalSleepMotionPolicy",
            "case fullArchive",
            "case boundedRecent",
            "historicalMotionPolicy: HistoricalSleepMotionPolicy = .boundedRecent",
            "HistoricalArchive.boundedMotionWindowDiagnostics(start: start, end: end)",
            "fullArchiveMotionSnapshot = HistoricalArchive.makeMotionArchiveSnapshot()",
            "return fullArchiveMotionSnapshot!.diagnostics(start: start, end: end)",
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

        review_start = sessions.index("nonisolated static func makeSleepReviewNightForCache")
        review_end = sessions.index("nonisolated static func shouldPublishSleepReviewCache", review_start)
        review_source = sessions[review_start:review_end]
        assert_contains(self, review_source, "historicalMotionPolicy: .boundedRecent")
        assert_not_contains(self, review_source, "HistoricalArchive.motionWindowDiagnostics")

        daily_start = sessions.index("func dailyRollups(rest: Int, maxHR: Int")
        daily_end = sessions.index("let aggregateCandidatesByDay", daily_start)
        daily_source = sessions[daily_start:daily_end]
        assert_contains(self, daily_source, "historicalMotionPolicy: .boundedRecent")

    def test_launch_path_archive_rotation_writes_to_segment_after_threshold(self):
        archive = source(ROOT / "Atria" / "Atria" / "HistoricalArchive.swift")
        catalog = source(ROOT / "Atria" / "Atria" / "AtriaHistoricalArchiveCatalog.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        script = source(ROOT / "pull_atria_state.sh")

        for needle in [
            'private static let rotationManifestFilename = "historical-archive.manifest.json"',
            "private static let rotationThresholdBytes = 128 * 1024 * 1024",
            'private static let segmentsDirectoryName = "segments"',
            "private struct RotationManifest: Codable",
            "private static func writableFileURL(now: Date = Date()) throws -> URL",
            "try catalogStoreLocked().writableChunkURL(now: now)",
            "private static func catalogStoreLocked() throws -> AtriaHistoricalArchiveCatalogStore",
            "private static func legacyRotatedSegmentFileURLs() -> [URL]",
            "private static func catalogRawFileURLs() -> [URL]",
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
            "static let productionMaximumActiveBytes: UInt64 = 32 * 1024 * 1024",
            "func writableChunkURL(now: Date) throws -> URL",
            "if crossedDay || actualBytes >= maximumActiveBytes",
            "value.chunks[activeIndex].state = .sealed",
            "let next = makeFreshActiveChunk(now: now)",
            "try persistDurably(value)",
        ]:
            assert_contains(self, catalog, needle)

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
            'printf \'%s_status=partial_copy\\n\'',
            'historical_archive_summary_status={\'partial_copy\' if partial_copy else \'ok\'}',
            'metric_gate = "copy_incomplete"',
            'user_action = "rerun_pull_or_use_bounded_archive_export"',
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
            '"manual_nap", "auto_nap", "nap_candidate", "hr_only_nap", "user_adjusted_nap"',
            '"manual_sleep", "auto_sleep", "auto_confirmed_sleep", "auto_confirmed_sleep_hr_only"',
            '"user_adjusted_sleep"',
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
            "reason: \"hr_continuity_all_gatt_silent_unsavable\"",
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
        motion = source(ROOT / "Atria" / "Atria" / "AtriaMotionActivityContext.swift")
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
            "value: steps.valueText",
            "detail: steps.detailText",
            "AtriaStrapStepLiveStatus.persistedMotionDate()",
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
        assert_contains(self, info, "NSMotionUsageDescription")
        assert_contains(self, motion, "import CoreMotion")
        assert_contains(self, motion, "CMMotionActivityManager")
        assert_contains(self, motion, 'monitorState: "starting"')
        assert_contains(self, home, "@State private var motionActivityMonitor = AtriaMotionActivityMonitor()")
        assert_not_contains(self, home, "@StateObject private var motionActivityMonitor")
        for needle in [
            'static let defaultsKey = "atria.motionContext.diagnostics"',
            "static let minimumUnchangedWriteInterval: TimeInterval = 5 * 60",
            "signature != lastSignature || unchangedIntervalElapsed",
            "func recordStopped(authorization: String, now: Date = Date())",
            "context: .unknown",
            'monitorState: "stopped"',
        ]:
            assert_contains(self, motion, needle)
        assert_contains(self, home, "motionActivityMonitor.recordGateDecision(motionDecision, now: now)")
        for forbidden in ["latitude", "longitude", "coordinate", "route", "accelerometer"]:
            assert_not_contains(self, motion.lower(), f'"{forbidden}')
        for needle in [
            "def emit_motion_context_preferences():",
            'pref(prefs, "motionContext.diagnostics")',
            "motion_context_authorization=",
            "motion_context_latest_kind=",
            "motion_context_latest_confidence=",
            "motion_context_started_age_s=",
            "motion_context_observed_age_s=",
            "motion_context_recorded_gate_decision=",
            "motion_context_effective_gate_decision=",
            "motion_context_effective_gate_reason=no_snapshot",
            'effective_decision = "abstain"',
        ]:
            assert_contains(self, pull, needle)
        assert_not_contains(self, motion, "CMPedometer")
        assert_not_contains(self, motion, "CMMotionManager")
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

    def test_strap_steps_are_live_local_day_not_persisted_only(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        today = source(ROOT / "Atria" / "Atria" / "AtriaTodayScreen.swift")
        perf_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaPerfFixesTests.swift")
        for needle in [
            "@Published private(set) var liveStrapStepResearchCount = 0",
            '@Published private(set) var liveStrapStepResearchState = "research_unvalidated"',
            "static func shouldPublishLiveStrapStepResearch(currentCount: Int,",
            "if force { return true }",
            "return currentCount != publishedCount",
            "private func publishLiveStrapStepResearchIfNeeded(now: Date = Date(),",
            "publishLiveStrapStepResearchIfNeeded(now: now)",
            r"assignIfChanged(\.liveStrapStepResearchCount, strapStepResearchCount)",
            r"assignIfChanged(\.liveStrapStepResearchState, strapStepResearchState)",
            "publishLiveStrapStepResearchIfNeeded(force: true)",
        ]:
            assert_contains(self, ble, needle)
        for obsolete_throttle in [
            "liveStrapStepResearchPublishMinimumInterval",
            "liveStrapStepResearchPublishMinimumDelta",
            "pendingLiveStrapStepResearchPublishTask",
            "scheduleTrailingLiveStrapStepResearchPublish",
        ]:
            assert_not_contains(self, ble, obsolete_throttle)
        assert_not_contains(self, ble, "strapStepResearchState = stepEstimate.state\n        assignIfChanged(\\.liveStrapStepResearchCount, strapStepResearchCount)")

        for needle in [
            "let day: Date",
            "private var cachedTodayTRIMP: (rest: Int, maxHR: Int, day: Date, value: Double)?",
            "now: Date = Date()) -> HomeSavedAggregate",
            "let day = calendar.startOfDay(for: now)",
            "cachedHomeSavedAggregate.day == day",
            "nonisolated static func homeSavedAggregate(from canonicalSessions: [SavedSession],",
            "let dayInterval = DateInterval(start: day, end: dayEnd)",
            "let todaySessions = canonicalSessions.filter { $0.end > day && $0.start < dayEnd }",
            "let savedTodayStrapSteps: Int",
            "let savedActiveSessionStrapSteps: Int",
            "let savedActiveSessionTotalStrapSteps: Int",
            "let activeSessionID: UUID?",
            "$0 + $1.attributedStrapSteps(within: dayInterval)",
            "savedTodayStrapSteps: savedTodayStrapSteps",
            "savedActiveSessionStrapSteps: savedActiveSessionStrapSteps",
            "savedActiveSessionTotalStrapSteps: max(0, savedActiveSessionTotalStrapSteps)",
            "cachedTodayTRIMP.day",
            "cachedTodayTRIMP = (rest: rest, maxHR: max, day: day, value: value)",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "let savedTodayStrapSteps: Int",
            "let savedActiveSessionStrapSteps: Int",
            "var strapStepResearchCount: Int",
            "var strapStepResearchState: String",
            "struct PulseZoneContext: Equatable",
            "static func pulseZoneContext(baselineResting: Int?,",
            "static func resolvedRestingHeartRate(baselineResting: Int?,",
            "if let baselineResting { return baselineResting }",
            "if let liveResting { return liveResting }",
            "return latestSavedResting() ?? 60",
            "private func cachedLatestSavedResting() -> Int?",
            "private var savedRestingFallbackCache: SavedRestingFallbackCache?",
            "let zoneContext = currentPulseZoneContext()",
            "rest: zoneContext.rest",
            "maxHR: zoneContext.maxHR",
            "dailyStepPresentation.valueText",
            "var hasStrapStepResearch: Bool { dailyStepPresentation.count != nil }",
            "ble.$liveStrapStepResearchCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "ble.$liveStrapStepResearchState.removeDuplicates().map { _ in () }.eraseToAnyPublisher()",
            "canonicalStepDays: store.historySnapshot",
            ".verifiedHistoricalStepEvidenceDays",
            "let strapStepsToday = mergedStrapStepResearchCount(",
            "savedActiveSession: savedAggregate.savedActiveSessionStrapSteps",
            "savedActiveSessionTotal: savedAggregate.savedActiveSessionTotalStrapSteps",
            "nonisolated static func mergedStrapStepResearchCount(savedToday: Int,",
            "return saved - savedActive + max(savedActive, max(0, liveActiveSession))",
            "strapStepResearchCount: strapStepsToday",
            "strapStepResearchState: ble.liveStrapStepResearchState",
            "private var liveStepWidgetUpdates: AnyPublisher<Void, Never>",
            "state.strapStepResearchCount",
            "state.strapStepResearchState",
            'scheduleLiveSensorWidgetPatch(reason: "live_steps")',
            "savedTodayStrapSteps: aggregate.savedTodayStrapSteps",
            "savedActiveSessionStrapSteps: aggregate.savedActiveSessionStrapSteps",
            "savedActiveSessionTotalStrapSteps: aggregate.savedActiveSessionTotalStrapSteps",
        ]:
            assert_contains(self, home, needle)
        live_step_widget_start = home.index("private var liveStepWidgetUpdates")
        live_step_widget_end = home.index("private var workoutDetectionUpdates",
                                          live_step_widget_start)
        live_step_widget_source = home[live_step_widget_start:live_step_widget_end]
        assert_not_contains(self, live_step_widget_source, "liveStrapMotionCapturedAt")
        hero_pulse_start = home.index("private func publishHeroPulse()")
        hero_pulse_end = home.index("func setHeartRateBroadcastActive", hero_pulse_start)
        hero_pulse_source = home[hero_pulse_start:hero_pulse_end]
        pulse_live_start = home.index("private func publishPulseLive()")
        pulse_live_end = home.index("private func publishPulseSparkline()", pulse_live_start)
        pulse_live_source = home[pulse_live_start:pulse_live_end]
        assert_not_contains(self, hero_pulse_source, "refreshLiveSessionDerivedIfNeeded()")
        assert_not_contains(self, pulse_live_source, "refreshLiveSessionDerivedIfNeeded()")
        publish_core_start = home.index("private func publishCoreLive()")
        publish_core_end = home.index("private func publishHeroPulse()", publish_core_start)
        publish_core_source = home[publish_core_start:publish_core_end]
        assert_contains(self, publish_core_source, "refreshSavedAggregate()")

        for needle in [
            "private struct AtriaTodayLiveGlanceTileHost: View",
            "@ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore",
            "let live = liveStore.state",
            "value: steps.valueText",
            "detail: legendDetail(steps.detailText,",
            "tint: steps.count == nil ? .secondary",
        ]:
            assert_contains(self, today, needle)

        step_card = today[today.index("case .steps:"):today.index("case .calories:", today.index("case .steps:"))]
        assert_not_contains(self, step_card, "store.imuAuditSummary")
        assert_not_contains(self, step_card, "sensorSummary.strapStepText")
        for needle in [
            "func testLiveStrapStepResearchPublishesEveryChangedPipelineSnapshot()",
            "func testHomeSavedAggregateCacheKeyRollsAtLocalMidnight()",
            "func testPulseZoneContextMatchesRestFallbackOrderWithoutSessionDerivation()",
            "func testReconnectWatchdogsPreferFreshConnectionOverOldPacketTimestamps()",
            "func testResidentMorningSettlementUsesWakeWindowAndThirtyMinuteCadence()",
            "func testFailedConnectRecoveryRetainsSavedStrapAndBackoff()",
            "SessionStore.homeSavedAggregate(from: [yesterdaySession]",
            "AtriaBLEManager.latestLinkActivity([oldPacket, nil, reconnect])",
            "SessionStore.shouldAttemptResidentMorningSettlement(now: at(6, 30),",
            "AtriaBLEManager.failedConnectRecoveryDisposition(isSavedPeripheral: true,",
            "AtriaHomeModel.pulseZoneContext(baselineResting: 55,",
            "XCTAssertEqual(afterMidnight.savedTodayStrapSteps, 0)",
            "XCTAssertFalse(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 12,",
            "XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 4,",
            "XCTAssertTrue(AtriaBLEManager.shouldPublishLiveStrapStepResearch(currentCount: 6,",
            "force: true",
            "func testLiveStepWidgetPublisherIsIndependentFromHeartRateChanges()",
        ]:
            assert_contains(self, perf_tests, needle)
        for needle in [
            "runResidentMorningSettlementIfUseful(now: now)",
            "private var lastResidentMorningSettlementCheckpointAt: Date?",
            "private func runResidentMorningSettlementIfUseful(now: Date)",
            "guard hasCompletedDeferredSessionLoad else { return }",
            "nonisolated static func shouldAttemptResidentMorningSettlement(",
            "now.timeIntervalSince(lastAttemptAt) < minimumInterval",
            "let minutesAfterWakeBoundary = (nowMinute - end + 1_440) % 1_440",
            "autoConfirmSleepOnForegroundIfUseful(reason: \"resident_morning_checkpoint\")",
        ]:
            assert_contains(self, sessions, needle)

        for needle in [
            "nonisolated static func latestLinkActivity(_ candidates: [Date?]) -> Date?",
            "let reference = Self.latestLinkActivity([lastRawHRNotificationAt, connectedAt, armedAt]) ?? armedAt",
            "persistedLastPacketInterval > 0 ? Date(timeIntervalSince1970: persistedLastPacketInterval) : nil,",
            "Self.latestLinkActivity([lastRawHRNotificationAt,\n                                                               lastGattActivityAt,\n                                                               connectedAt])",
            "Self.latestLinkActivity([lastRawHRNotificationAt,\n                                                            lastGattActivityAt,\n                                                            connectedAt])",
            "Self.latestLinkActivity([lastAcceptedHRAt, connectedAt])",
        ]:
            assert_contains(self, ble, needle)
        for needle in [
            "enum FailedConnectRecoveryDisposition: Equatable",
            "nonisolated static func failedConnectRecoveryDisposition(isSavedPeripheral: Bool,",
            "guard target.state != .connecting else {",
            "isSavedPeripheral: savedUUID == peripheral.identifier",
            "case .reconnectKnownAfterBackoff:",
            "self.requestFreshScanReconnect(peripheral: peripheral,",
            "case .waitForExistingConnect:",
            "case .scan:",
        ]:
            assert_contains(self, ble, needle)

        recovery_freeze_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaRecoveryFreezeTests.swift")
        recovery_cadence_tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaRecoveryProjectionCadenceTests.swift")
        for needle in [
            "let recovery = store.recoveryProjectionForPresentation(",
            "initialFallbackHRVSnapshot: ble.recoveryHRVSnapshot",
            "frozenTarget: frozenTarget?.target",
        ]:
            assert_contains(self, home, needle)
        assert_not_contains(self, home, "static func dailyFrozenRecoveryEstimate(")
        for needle in [
            "func recoveryProjection(now: Date = Date(),",
            "DailyRecoveryResolver.summary(rollups: dailyRollupHistory,",
            "provisional: Metrics.recoveryV2(",
        ]:
            assert_contains(self, sessions, needle)
        for needle in [
            "func testFrozenRollupRestoresScoreAndProvenanceAtomically()",
            "let resolved = try XCTUnwrap(rollup.resolvedRecoverySummary())",
            "XCTAssertEqual(estimate.percent, 74)",
        ]:
            assert_contains(self, recovery_freeze_tests, needle)
        assert_contains(self, recovery_cadence_tests, "testUnchangedProjectionHitsFourHourCacheWithoutEvaluatingAutoclosure")

    def test_strap_step_calibration_archive_is_durable_bounded_and_phone_independent(self):
        archive = source(ROOT / "Atria" / "Atria" / "AtriaStrapCalibrationArchive.swift")
        app = source(ROOT / "Atria" / "Atria" / "AtriaApp.swift")
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        reassembler = source(ROOT / "Atria" / "Atria" / "AtriaWhoop4FrameReassembler.swift")
        r10 = source(ROOT / "Atria" / "Atria" / "AtriaR10Motion.swift")
        debug = source(ROOT / "Atria" / "Atria" / "AtriaDebugLogging.swift")
        tests = source(ROOT / "Atria" / "AtriaTests" / "AtriaStrapCalibrationArchiveTests.swift")
        pull = source(ROOT / "pull_atria_state.sh")

        for needle in [
            'static let enableArgument = "--atria-enable-step-calibration"',
            'static let disableArgument = "--atria-disable-step-calibration"',
            'root.appendingPathComponent("atria-step-calibration", isDirectory: true)',
            'maximumArchiveBytes: Int64 = 96 * 1_024 * 1_024',
            'queue = DispatchQueue(label: "com.adidshaft.atria.step-calibration", qos: .utility)',
            'static func canonicalValidatedMotionFrame(from data: Data) -> Data?',
            'payload[0] == 0x2B && payload[1] == 0x0A',
            'let expectedCRC = crc32(payload)',
            '"schema_version,received_at_unix_ms,source,packet_type,record_type,raw_frame_hex\\n"',
            'try currentFileHandle?.synchronize()',
            'now.addingTimeInterval(-retentionInterval)',
            'totalBytes > maximumArchiveBytes',
        ]:
            assert_contains(self, archive, needle)

        for needle in [
            "let receivedAt = Date()",
            "strapStepCalibrationCaptureUntil",
            "receivedAt <= captureUntil",
            "let completeFrames = proprietaryFrameReassembler.feed(data, source: frameSource)",
            "AtriaStrapCalibrationArchive.shared.recordMotionFrame(",
            "AtriaR10MotionDecoder.decode(frame: completeFrame)",
            "r10_stream status=observe_subscribed_stream command=deferred_until_passive_grace",
            "requestBoundedR10ActivationForSilentStream(",
            "protectedR10ActivationLeaseDelay(",
            "receivedAt: receivedAt",
            "transport=existing_protected_r10 mode_change=0 reconnect=0 cccd_changes=0 battery_reads=0 offline_sync=0 commands=0",
        ]:
            assert_contains(self, ble, needle)
        for forbidden in [
            '|| arguments.contains(AtriaStrapCalibrationArchive.enableArgument)',
            'reason: "step_calibration_resume"',
            'rediscoverFullProtocolServicesIfConnected(reason: "step_calibration_arm")',
            'action=temporary_radio_override',
        ]:
            assert_not_contains(self, ble, forbidden)

        for needle in [
            "final class AtriaWhoop4FrameReassembler",
            "buffers: [String: [UInt8]]",
            "guard buffer.count >= totalLength else { break }",
            "guard crc32(payload) == actualCRC else",
            "maximumBufferedBytes",
        ]:
            assert_contains(self, reassembler, needle)
        for needle in [
            "enum AtriaR10MotionDecoder",
            "static let packetType: UInt8 = 0x2B",
            "static let recordType: UInt8 = 0x0A",
            "private static let accelerationOffsets = [85, 285, 485]",
            "private static let gyroscopeOffsets = [688, 888, 1_088]",
            "enum AtriaStrapPedometer",
            "static let peakWindow = 29",
            "static let sensitivityG = 0.06",
            "static let confirmationSteps = 6",
            "final class AtriaR10MotionPipeline",
        ]:
            assert_contains(self, r10, needle)

        self.assertGreaterEqual(app.count("AtriaStrapCalibrationArchive.shared.flush()"), 3)
        self.assertEqual(
            ble.count("arguments.contains(AtriaStrapCalibrationArchive.enableArgument)"),
            0,
            "Calibration enablement must not participate in BLE transport selection",
        )
        assert_not_contains(self, debug, '"--atria-enable-step-calibration"')
        for needle in [
            'copy_from_container "Documents/atria-step-calibration"',
            'step_calibration_archive_summary_status=',
            'step_calibration_archive_row_count=',
            'step_calibration_archive_earliest_received_at_iso_utc=',
            'step_calibration_archive_latest_received_at_iso_utc=',
            'step_calibration_archive_packet_types=',
            'step_calibration_archive_record_types=',
            'step_calibration_capture_status=',
            'step_calibration_capture_armed=',
            'step_calibration_capture_until_unix_s=',
            'step_calibration_capture_until_iso_utc=',
            'step_calibration_capture_remaining_s=',
        ]:
            assert_contains(self, pull, needle)

        for needle in [
            "testCanonicalFrameRequiresMotionOpcodeAndValidCRC",
            "testCalibrationWindowPersistsAcrossLaunchesAndExpires",
            "testArchiveWritesTruePacketTimestampAndRawStrapFrame",
            "testArchiveDropsInvalidAndNonMotionStrapFrames",
        ]:
            assert_contains(self, tests, needle)

        for text in [archive, app, ble]:
            assert_not_contains(self, text, "CoreMotion")
            assert_not_contains(self, text, "CMPedometer")

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
            "targetMetric: .respiratoryRate",
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
            # 2026-07-08: calibration is honest per-metric — baselines (HRV/RHR) pass
            # calibratingTotal:14 + calibratingUnit:"Night" for "Night X of 14"; recovery/
            # sleep keep the default 4/"Day". Accessibility mirrors the visible unit+total.
            "var parts = [calibratingDay.map { \"\\(title) calibrating \\(calibratingUnit.lowercased()) \\(min(max($0, 0), calibratingTotal)) of \\(calibratingTotal)\" } ?? \"\\(title) \\(displayValue)\", detail]",
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
            "hrvBaseline: projection.hrvBaseline",
            "hrvBaselineSamples: projection.hrvBaselineSamples",
            "hrvBaselineTrusted: projection.hrvBaselineTrusted",
            "baselineTarget: projection.baselineTarget",
            "hrvGreenRatio: hrvGreenRatio",
            "hrvYellowRatio: hrvYellowRatio",
            "restingBaseline: projection.restingBaseline",
            "restingBaselineSamples: projection.restingBaselineSamples",
            "restingBaselineTrusted: projection.restingBaselineTrusted",
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
            "zone: qualifiedStrainZone",
            "zone: loadReadinessZone",
            "zone: hrvCalibratingValue != nil ? nil : hrvZone",  # 2026-07-08 partial-data calibration
            "zone: sleepGlanceZone",
            "zone: sleepEfficiencyZone",
            "zone: restingCalibratingValue != nil ? nil : restingHeartRateZone",  # 2026-07-08 partial-data calibration
            "zone: steps.count == nil ? nil : stepsZone",
            "zone: activeCaloriesZone",
            "zone: vo2TrendZone",
            "zone: biologicalAgeZone",
            "zone: respiratoryRateZone",
            "? skinTemperatureDeviationZone",
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
            "return Metrics.sleepDurationZone(latest.durationHours, goalHours: sleepGoalHours)",
            # 2026-07-12: zone color uses the same main night as the metric.
            "Metrics.sleepEfficiencyZone(currentMainSleep?.sleepEfficiency,",
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
            # 2026-07-12: respiratory target zones use main sleep, not naps.
            "Metrics.respiratoryRateZone(currentMainSleep?.respiratoryRate,",
            "baseline: sleepHistory.respiratoryBaselineMean",
            "baselineSamples: sleepHistory.respiratoryBaselineCount",
            "greenDelta: respiratoryGreenDelta",
            "yellowDelta: respiratoryYellowDelta",
            "Metrics.skinTemperatureDeviationZone(skinTemperatureSummary,",
            "greenDelta: skinTemperatureGreenDelta",
            "yellowDelta: skinTemperatureYellowDelta",
        ]:
            assert_contains(self, overview, needle)

        for needle in [
            "recoveryTarget: AtriaMetricTarget.recovery",
            "strainGreenBand: strainGreenBand",
            "strainYellowBand: strainYellowBand",
            "AtriaVitalsPulseCardHost(liveStore: liveStore,",
            "homeStatsStore: homeStatsStore,\n                                 baselineSnapshot: AtriaVitalsPulseBaselineSnapshot(baseline),",
            "private struct AtriaVitalsPulseBaselineSnapshot: Equatable",
            "let restingBaseline: Int?",
            "let restingBaselineSamples: Int",
            "let restingBaselineTrusted: Bool",
            "let baselineTarget: AtriaBaselineTargetSnapshot",
            "init(_ baseline: PersonalBaseline)",
            "let baselineSnapshot: AtriaVitalsPulseBaselineSnapshot",
            "let store: SessionStore",
            "@AtriaDefault(\"atria.target.rhr.greenDelta\") private var restingGreenDelta: Int = 3",
            "@AtriaDefault(\"atria.target.rhr.yellowDelta\") private var restingYellowDelta: Int = 7",
            "restingHeartRate: displayedHomeStats.restingHeartRate",
            "restingBaseline: baselineSnapshot.restingBaseline",
            "restingBaselineSamples: baselineSnapshot.restingBaselineSamples",
            "restingBaselineTrusted: baselineSnapshot.restingBaselineTrusted",
            "baselineTarget: baselineSnapshot.baselineTarget",
            "AtriaVitalsHRVCardHost(liveStore: liveStore,",
            "heroStore: heroStore,\n                               vitalsStore: vitalsStore)",
            "var hrvSDNN: Double?",
            "var hrvPNN50: Double?",
            "var hrvSDNNText: String",
            "var hrvPNN50Text: String",
            "hrvSDNN: ble.hrvSnapshot?.sdnn",
            "hrvPNN50: ble.hrvSnapshot?.pnn50",
            "@AtriaDefault(\"atria.target.hrv.greenRatio\") private var hrvGreenRatio: Double = 0.95",
            "@AtriaDefault(\"atria.target.hrv.yellowRatio\") private var hrvYellowRatio: Double = 0.85",
            "hrvBaseline: baseline.hrvInt",
            "hrvBaselineSamples: baseline.freshHRVSampleCount()",
            "hrvBaselineTrusted: baseline.hasTrustedHRVBaseline()",
            "baselineTarget: AtriaBaselineTargetSnapshot(baseline)",
            "hrvGreenRatio: hrvGreenRatio",
            "hrvYellowRatio: hrvYellowRatio",
            "restingBaseline: baseline.restingInt",
            "restingBaselineSamples: baseline.freshRestingSampleCount()",
            "restingBaselineTrusted: baseline.hasTrustedRestingBaseline()",
            "restingGreenDelta: restingGreenDelta",
            "restingYellowDelta: restingYellowDelta",
            "respiratoryGreenDelta: respiratoryGreenDelta",
            "respiratoryYellowDelta: respiratoryYellowDelta",
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
            "? skinTemperatureDeviationZone",
            "Metrics.restingHeartRateZone(restingHeartRate,",
            "baselineTrusted: restingBaselineTrusted",
            "baselineTarget: baselineTarget",
            "restingTint: restingHeartRateZone?.tint ?? .blue",
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
            # 2026-07-19: zones remain confirmed-main-only even while review evidence is numeric.
            "Metrics.restingHeartRateZone(zonedLatestEvidence?.restingHR,",
            "baselineTrusted: restingBaselineTrusted",
            "baselineTarget: baselineTarget",
            "greenDelta: restingGreenDelta",
            "yellowDelta: restingYellowDelta",
            "Metrics.sleepDurationZone(zonedLatestEvidence?.durationHours, goalHours: sleepGoalHours)",
            "Metrics.sleepEfficiencyZone(zonedLatestEvidence?.sleepEfficiency,",
            "Metrics.hrvZone(zonedLatestEvidence?.hrv,",
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
            "Metrics.respiratoryRateZone(zonedLatestEvidence?.respiratoryRate,",
            "baseline: snapshot.respiratoryBaselineMean",
            "baselineSamples: snapshot.respiratoryBaselineCount",
            "greenDelta: respiratoryGreenDelta",
            "yellowDelta: respiratoryYellowDelta",
            "\\(summary.agreementText) · all saved research sessions",
            "Metrics.skinTemperatureDeviationZone(summary.skinTemperatureDeviation,",
            "greenDelta: skinTemperatureGreenDelta",
            "yellowDelta: skinTemperatureYellowDelta",
        ]:
            assert_contains(self, vitals + home, needle)

        pulse_host_start = vitals.index("private struct AtriaVitalsPulseCardHost: View")
        pulse_host_end = vitals.index("private struct AtriaVitalsPulseBaselineSnapshot", pulse_host_start)
        pulse_host_source = vitals[pulse_host_start:pulse_host_end]
        assert_not_contains(self, pulse_host_source, "@ObservedObject var store: SessionStore")
        assert_not_contains(self, pulse_host_source, "store.baseline")

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
            "General wellness, not medical advice.",
        ]:
            assert_contains(self, settings, needle)
        # Settings density audit: each collapsed target group keeps its reset
        # action in the shared trailing menu rather than adding a full-width
        # row to the expanded controls. Fitness-age still precedes VO2.
        self.assertRegex(
            settings,
            r"resetTitle: \"Reset fitness-age target\"[\s\S]*?onReset: resetFitnessAgeTargets\)[\s\S]*?Stepper\(value: \$vo2GreenDelta",
        )
        targets_start = settings.index("private var targetsSection: some View")
        targets_end = settings.index("@State private var expandedTargetGroups", targets_start)
        targets_source = settings[targets_start:targets_end]
        for old_reset_row in [
            'Label("Reset to recommended"',
            'Label("Reset strain band"',
            'Label("Reset training-load target"',
            'Label("Reset activity targets"',
            'Label("Reset sleep targets"',
            'Label("Reset baseline targets"',
            'Label("Reset signal targets"',
            'Label("Reset fitness-age target"',
            'Label("Reset VO2 trend target"',
        ]:
            assert_not_contains(self, targets_source, old_reset_row)
        self.assertEqual(targets_source.count(".atriaCardAction("), 1)
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
            "expected: 5.94",
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
            "if input.vo2MaxEstimate.value == nil",
            "input.baseline.hasTrustedRestingBaseline(now: input.now)",
            "input.baseline.hasTrustedHRVBaseline(now: input.now)",
            "if sleepNights.count < 3",
            "input.trainingLoadSummary.confidence != \"local\"",
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
        assert_contains(self, sessions, "guard AtriaSleepStageIntegrity.validates(stageSegments, for: sleep) else { return false }")
        assert_contains(self, sessions, "nonAwake <= duration + tolerance")
        assert_contains(self, sessions, "private static func copyConfirmedSleep(_ sleep: UserConfirmedSleep,")
        assert_contains(self, sessions, "UserConfirmedSleep(id: sleep.id,")
        assert_contains(self, sessions, "stageSegments: stageSegments")
        assert_contains(self, sessions, "return Self.copyConfirmedSleep(sleep, stageSegments: migratedStages)")
        assert_contains(self, sessions, "Self.legacyConfirmedSleepStageCompatibility(start: sleep.start,")
        assert_contains(self, sessions, 'source: sleep.source)')
        assert_contains(self, sessions, "private static func legacyConfirmedSleepStageCompatibility")
        assert_contains(self, sessions, "Legacy records")
        assert_contains(self, sessions, "stay stage-unavailable until the HR/motion stager can reconstruct")
        assert_contains(self, sessions, "sleepStageResearchSegments(from:")
        assert_contains(self, sessions, "return []")
        assert_not_contains(self, sessions, "private static func estimatedConfirmedSleepStages")
        assert_not_contains(self, sessions, "(.awake, 0.08), (.light, 0.47)")

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

    def test_live_ui_dotted_defaults_are_equality_gated(self):
        settings = source(ROOT / "Atria" / "Atria" / "AtriaSettingsView.swift")
        research = source(ROOT / "Atria" / "Atria" / "AtriaResearchBundle.swift")
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        assert_contains(self, settings,
                        '@AtriaDefault("atria.faceoff.displayName") private var faceOffDisplayName = ""')
        assert_contains(self, research,
                        "@AtriaDefault(AtriaResearchSharing.optInKey) private var optedIn = false")
        assert_contains(self, vitals,
                        '@AtriaDefault("atria.dutycycle.enabled") private var dutyCycleEnabled = false')
        self.assertNotIn('@AppStorage("atria.faceoff.displayName")', settings)
        self.assertNotIn("@AppStorage(AtriaResearchSharing.optInKey)", research)
        self.assertNotIn('@AppStorage("atria.dutycycle.enabled")', vitals)

    def test_workout_deletion_copy_preserves_recorded_day_strain(self):
        activity = source(ROOT / "Atria" / "Atria" / "AtriaActivityMonitor.swift")

        assert_contains(self, activity,
                        "Removes it from Activity history. Recorded strap data and day strain remain.")
        self.assertNotIn("Removes it from your history and strain", activity)

    def test_battery_decoder_never_turns_malformed_payload_into_zero(self):
        ble = (
            source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
            + source(ROOT / "Atria" / "Atria" / "AtriaStrapPowerPolicy.swift")
        )

        assert_contains(self, ble, "static func parseBatteryLevel(_ data: Data) -> Int?")
        assert_contains(self, ble, "guard data.count == 1, let byte = data.first, byte <= 100 else { return nil }")
        assert_contains(self, ble, "guard let newLevel = Self.parseBatteryLevel(data) else")
        assert_contains(self, ble, "pendingBatteryDropCandidate")
        assert_contains(self, ble, "implausibleBatteryDropRequiredConfirmations = 3")
        assert_contains(self, ble, "implausibleBatteryDropMinimumConfirmationSpan: TimeInterval = 60")
        assert_contains(self, ble, 'requestStrapStatusRead(reason: "long_wear_battery_freshness")')
        self.assertNotIn("let newLevel = Int(data.first ?? 0)", ble)

        pull = source(ROOT / "pull_atria_state.sh")
        assert_contains(self, pull, "raw_fresh = isinstance(level, int) and 11 <= level <= 99 and 0 <= age <= 10 * 60")
        assert_contains(self, pull, "active_notification_lease = (")
        assert_contains(self, pull, '"active_notification_lease" if active_notification_lease else "none"')
        assert_contains(self, pull, "battery_effective_status={'live' if usable else 'pending'}")

    def test_fitness_age_pace_counts_weekly_checks_not_daily_cache_copies(self):
        fitness = source(ROOT / "Atria" / "Atria" / "AtriaFitnessAge.swift")
        overview = source(ROOT / "Atria" / "Atria" / "AtriaOverviewSections.swift")

        assert_contains(self, fitness, "static let paceMinimumEntries = 4")
        assert_contains(self, fitness, "static func weeklyObservations(from deltas: [DailyDelta]")
        assert_contains(self, fitness, "let observations = weeklyObservations(from: deltas, calendar: calendar)")
        assert_contains(self, overview, "of 4 weekly checks saved so far")
        self.assertNotIn("fitnessAgeEntryCount >= 28", overview)

    def test_live_strap_steps_are_scoped_to_today_across_midnight(self):
        ble = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        widget = source(ROOT / "Atria" / "Atria" / "WidgetSnapshot.swift")

        assert_contains(self, ble, "liveStrapStepResearchTodayCount")
        assert_contains(self, ble, "strapStepResearchDayBaseline")
        assert_contains(self, ble, "static func dayScopedStrapStepCount(sessionCount: Int, dayBaseline: Int) -> Int")
        assert_contains(self, home, "liveActiveSession: ble.liveStrapStepResearchCount")
        assert_contains(self, widget, "liveActiveSession: ble.liveStrapStepResearchCount")

    def test_live_workout_consumes_workout_local_metric_projection(self):
        workout = source(ROOT / "Atria" / "Atria" / "AtriaLiveWorkoutView.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")
        root_start = workout.index("struct AtriaLiveWorkoutView: View")
        root_end = workout.index("private struct AtriaLiveWorkoutBackdrop", root_start)
        root = workout[root_start:root_end]

        assert_contains(self, root, "let metricStore: AtriaLiveWorkoutMetricStore")
        assert_not_contains(self, root, "@ObservedObject var metricStore")
        assert_not_contains(self, root, "metricStore.state")
        assert_contains(self, home, "@State private var liveWorkoutMetricStore = AtriaLiveWorkoutMetricStore()")
        assert_not_contains(self, home, "@State private var liveWorkoutMetricProjection")
        assert_contains(self, home, "liveWorkoutMetricStore.publishIfChanged(metricProjection)")
        self.assertNotIn("heroStore.state.strain", root)
        assert_contains(self, workout, "private struct AtriaLiveWorkoutStrainGuidance: View")
        assert_contains(self, workout, "AtriaLiveWorkoutStrainGuidanceHost(metricStore: metricStore")
        assert_contains(self, workout, "AtriaLiveWorkoutStrainGuidance(metricProjection: metricStore.state")
        assert_contains(self, workout, "private var strain: Double { metricProjection.strain }")
        assert_contains(self, home, "makeLiveWorkoutMetricProjection(session: session")
        assert_contains(self, home, "workoutStrain: metricProjection.strain")

    def test_user_adjusted_sleep_uses_fresh_journal_and_repairs_coverage(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        assert_contains(self, sessions, "let sourceSessions = canonicalSessions(includeActiveJournal: true)")
        assert_contains(self, sessions, "candidateCoverage > existingDuration + 1")
        assert_contains(self, sessions, "existingDuration: sleep.duration")
        assert_contains(self, sessions, "candidateCoverage: sensorCovered")

    def test_expanded_heart_rate_is_landscape_and_end_anchored(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        home = source(ROOT / "Atria" / "Atria" / "AtriaHomeView.swift")

        assert_contains(self, vitals, "AtriaHeartRateOrientation.prepareLandscapePresentation()")
        assert_contains(self, vitals, "AtriaHeartRateOrientation.preparePortraitDismissal()")
        assert_contains(self, vitals, "AtriaHeartRateOrientation.restorePortraitAfterDismissal()")
        assert_contains(self, vitals, "AtriaAppDelegate.supportedOrientations = AtriaHeartRateExplorerOrientationPolicy.transitionMask")
        assert_contains(self, vitals, "static let transitionMask: UIInterfaceOrientationMask = .allButUpsideDown")
        assert_contains(self, vitals, "setNeedsUpdateOfSupportedInterfaceOrientations()")
        assert_contains(self, vitals, "scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))")
        assert_contains(self, vitals, "scene.effectiveGeometry.interfaceOrientation == .portrait")
        assert_contains(self, vitals, "AtriaAppDelegate.supportedOrientations = .portrait")
        assert_contains(self, vitals, "domain=%@ code=%@ description=%@ userInfo=%@")
        assert_contains(self, home, "guard !AtriaTransientPresentationState.suppressesStandBy else { return false }")
        assert_contains(self, vitals, "latest.addingTimeInterval(-max(1, visibleDomain))")
        self.assertNotIn("scrollPosition = points.last?.t ?? scrollPosition", vitals)

    def test_expanded_heart_rate_uses_landscape_hosting_controller_not_swiftui_cover(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        presenter_start = vitals.index("private final class AtriaHeartRateExplorerPresentationController: ObservableObject")
        presenter_end = vitals.index("@MainActor\nprivate final class AtriaHeartRateExplorerPresentationModel", presenter_start)
        presenter = vitals[presenter_start:presenter_end]

        for needle in [
            "@StateObject private var heartRateExplorerPresenter = AtriaHeartRateExplorerPresentationController()",
            "onOpen: openHeartRateExplorer",
            "heartRateExplorerPresenter.present(points: points, currentBPM: bpm)",
            "private static func activePresentationSource() -> UIViewController?",
            "scene.windows.first(where: \\.isKeyWindow)?.rootViewController",
            "while let presented = topmost.presentedViewController",
            "schedulePresentationRetry(after: attempt)",
            "Task.sleep(for: .milliseconds(100))",
            "AtriaHeartRateLandscapeHostingController(rootView: root)",
            "hosting.modalPresentationStyle = .fullScreen",
            "presenter.present(hosting, animated: true)",
            "UIHostingController<AtriaHeartRateExplorerPresentationRoot>",
            "override var supportedInterfaceOrientations: UIInterfaceOrientationMask {",
            "AtriaHeartRateExplorerOrientationPolicy.presentedMask",
            "override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {",
            "AtriaHeartRateExplorerOrientationPolicy.preferredOrientation",
            "override var shouldAutorotate: Bool { true }",
            "hosting?.setNeedsUpdateOfSupportedInterfaceOrientations()",
            "AtriaHeartRateOrientation.preparePortraitDismissal()",
            "AtriaHeartRateOrientation.restorePortraitAfterDismissal()",
        ]:
            assert_contains(self, vitals, needle)

        assert_not_contains(self, vitals, ".fullScreenCover(isPresented: $showHeartRateExplorer)")
        assert_not_contains(self, vitals, "AtriaHeartRateExplorerPresenter: UIViewControllerRepresentable")
        assert_not_contains(self, vitals, "AtriaHeartRatePresentationAnchorController")
        assert_not_contains(self, vitals, "showHeartRateExplorer")
        prepare_start = vitals.index("static func prepareLandscapePresentation()")
        prepare_end = vitals.index("static func preparePortraitDismissal()", prepare_start)
        assert_not_contains(self, vitals[prepare_start:prepare_end], "request(.landscape)")
        assert_contains(self, presenter, "private weak var hostingController: AtriaHeartRateLandscapeHostingController?")
        dismiss_start = presenter.index("func dismiss(animated: Bool)")
        dismiss_body = presenter[dismiss_start:]
        self.assertLess(dismiss_body.index("AtriaHeartRateOrientation.preparePortraitDismissal()"),
                        dismiss_body.index("hosting.dismiss(animated: animated)"))
        pulse_host_start = vitals.index("private struct AtriaVitalsPulseCardHost: View")
        pulse_card_start = vitals.index("private struct AtriaPulseCard: View, Equatable", pulse_host_start)
        pulse_host = vitals[pulse_host_start:pulse_card_start]
        pulse_card_end = vitals.index("/// Direct presentation owner", pulse_card_start)
        pulse_card = vitals[pulse_card_start:pulse_card_end]
        assert_contains(self, pulse_host, "@StateObject private var heartRateExplorerPresenter")
        assert_contains(self, pulse_host, ".equatable()\n            .onAppear(perform: openDebugTimelineIfReady)")
        assert_not_contains(self, pulse_card, "@StateObject")
        assert_not_contains(self, pulse_card, "heartRateExplorerPresenter")
        timeline_card_start = vitals.index("private struct AtriaHeartRateTimelineCard: View, Equatable")
        timeline_card_end = vitals.index("struct AtriaHeartRateChartSeries: Equatable", timeline_card_start)
        assert_contains(self, vitals[timeline_card_start:timeline_card_end], ".allowsHitTesting(false)")

    def test_expanded_heart_rate_uses_chart_first_geometry_layout_and_one_glass_close(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")
        layout_start = vitals.index("struct AtriaHeartRateExplorerStageLayout: Equatable")
        explorer_end = vitals.index("struct AtriaHeartRateRangeSummary: Equatable", layout_start)
        explorer = vitals[layout_start:explorer_end]

        for needle in [
            "stageSize = CGSize(width: containerSize.height, height: containerSize.width)",
            "rotationDegrees = 90",
            "isLandscape = size.width > size.height",
            "let controlRailHeight: CGFloat",
            "controlRailHeight = shortEdge < 390 ? 44 : 48",
            "estimatedChartWidth = max(0, size.width - outerPadding * 2)",
            "let stage = AtriaHeartRateExplorerStageLayout(",
            "let layout = AtriaHeartRateExplorerLayout(size: stage.stageSize)",
            "switch stage.mode",
            "case .landscape:",
            "case .portrait:",
            "case .rotatedLandscapeFallback:",
            "landscapeContent(layout: layout)",
            "portraitContent(layout: layout)",
            ".rotationEffect(.degrees(stage.rotationDegrees))",
            "landscapeControlRail\n                .frame(height: layout.controlRailHeight)",
            "heartRateChart\n                .frame(maxWidth: .infinity, maxHeight: .infinity)",
            ".layoutPriority(1)",
            "Button(action: onDismiss)",
            ".glassEffect(.regular.interactive(), in: .circle)",
            ".frame(width: 44, height: 44)",
            ".accessibilityLabel(\"Close heart-rate monitor\")",
        ]:
            assert_contains(self, explorer, needle)

        self.assertEqual(explorer.count("Button(action: onDismiss)"), 1)
        self.assertEqual(explorer.count(".glassEffect(.regular.interactive(), in: .circle)"), 1)
        landscape_start = explorer.index("private func landscapeContent")
        landscape_end = explorer.index("private func portraitContent", landscape_start)
        landscape_source = explorer[landscape_start:landscape_end]
        self.assertLess(landscape_source.index("landscapeControlRail"),
                        landscape_source.index("heartRateChart"))
        assert_not_contains(self, landscape_source, "inspector(")
        assert_not_contains(self, explorer, "inspectorWidth")
        assert_not_contains(self, explorer, "NavigationStack {")
        assert_not_contains(self, explorer, ".toolbar {")
        assert_not_contains(self, explorer, ".atriaCardAction(")
        assert_not_contains(self, explorer, "UIDevice.current.orientation")

    def test_vitals_heart_rate_uses_one_compact_stat_row_and_one_graph(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        assert_contains(self, vitals, "private struct AtriaPulseStatRail: View")
        assert_contains(self, vitals, 'stat("Now", now, tint: .red)')
        assert_contains(self, vitals, 'stat("Average", average, tint: .pink)')
        assert_contains(self, vitals, 'stat("Peak", peak, tint: .red)')
        assert_contains(self, vitals, 'stat("Resting", resting, tint: restingTint)')
        self.assertNotIn("sparklineValues: sparklineValues", vitals)

    def test_short_heart_rate_history_does_not_create_empty_six_hour_viewport(self):
        vitals = source(ROOT / "Atria" / "Atria" / "AtriaVitalsCollectionSections.swift")

        assert_contains(self, vitals, "static func shouldEnableHorizontalScrolling(points:")
        assert_contains(self, vitals, "last.timeIntervalSince(first) > max(1, visibleDomain)")
        assert_contains(self, vitals, "Self.shouldEnableHorizontalScrolling(points: points, visibleDomain: visibleDomain)")

    def test_motion_handshake_harness_is_double_gated_and_transport_isolated(self):
        manager = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        assert_contains(self, manager, 'static let enableArgument = "--atria-motion-handshake-diagnostic"')
        assert_contains(self, manager, 'static let confirmationArgument = "--atria-confirm-isolated-ble-diagnostic"')
        assert_contains(self, manager, 'static let activationConsentArgument = "--atria-confirm-single-r10-command-3f01"')
        assert_contains(self, manager, "arguments.contains(enableArgument)")
        assert_contains(self, manager, "arguments.contains(confirmationArgument)")
        assert_contains(self, manager, "guard motionHandshakeDiagnostic == nil else")
        assert_contains(self, manager, 'event: "proprietary_tx_blocked"')
        assert_contains(self, manager, 'event: "battery_read_blocked"')
        assert_contains(self, manager, 'event: "offline_sync_blocked"')
        assert_contains(self, manager, "restoredPeripheral.discoverServices([Self.UUIDs.strapService])")
        assert_contains(self, manager, "? [Self.UUIDs.strapStream5, Self.UUIDs.strapTX]")
        assert_contains(self, manager, ": [Self.UUIDs.strapStream5]")
        assert_contains(self, manager, "peripheral.discoverServices([Self.UUIDs.heartRateService])")
        assert_contains(self, manager, "diagnostic.sendSingleR10Activation")
        assert_contains(self, manager, "[Packet.command, sequence, Cmd.sendR10R11Realtime, 0x01]")
        assert_contains(self, manager, 'event: "activation_3f01_sent"')

    def test_production_protected_r10_uses_only_physically_proven_minimal_handshake(self):
        manager = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        battery_policy = source(
            ROOT / "Atria" / "Atria" / "AtriaBLEBatteryTransportPolicy.swift"
        )

        assert_contains(self, manager, '"com.adidshaft.atria.ble-central-v6-pure-hr"')
        assert_contains(self, manager, '"com.adidshaft.atria.ble-central-v5"')
        assert_contains(self, manager, "protectedStandardHRServices(")
        assert_contains(self, manager, "var services = [UUIDs.heartRateService, UUIDs.batteryService]")
        assert_contains(self, manager, "case UUIDs.batteryService:")
        assert_contains(self, manager, "return [UUIDs.batteryLevel]")
        assert_contains(self, manager, "protectedStandardHRStrapCharacteristics(")
        assert_contains(self, manager, "guard !streamSuppressed else { return nil }")
        assert_contains(self, manager, "protectedR10ResponseEventDataNotifyOrder + [UUIDs.strapTX]")
        assert_contains(self, manager, "return [UUIDs.strapStream5, UUIDs.strapTX]")
        assert_contains(self, manager, "[Packet.command, sequence, Cmd.sendR10R11Realtime, 0x01]")
        assert_contains(self, manager, 'protected_r10 status=activation_sent cmd=3f data=01 mode=wwr')
        assert_contains(
            self, battery_policy, "explicitReadResearchEnabled: Bool = false"
        )
        self.assertNotIn("explicitReadResearchEnabled: true", battery_policy)
        assert_contains(self, manager, "source=2A19_new_subscription")
        assert_contains(self, manager, "source=2A19_existing_subscription")
        assert_contains(self, manager, "disabled_protected_r10_minimal")
        assert_contains(self, manager, 'action=preserve_2a37_and_passive_stream5_no_reconnect_no_more_commands')
        assert_contains(self, manager, 'static let protectedR10StreamSuppressedKey')
        assert_contains(self, manager, 'protectedR10ActivationLeaseDelay(lastActivationAt:')
        assert_contains(self, manager, "shouldAcceptProtectedProprietaryNotification(")
        assert_contains(self, manager, "shouldObservePassiveR10InProtectedStandardHR(")
        assert_contains(self, manager, "protectedR10StabilityTask")
        assert_contains(self, manager, "stable_window_complete")

    def test_20260718_hr_first_dense_bring_up_is_epoch_bounded_and_convergent(self):
        manager = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")

        # 2026-07-18: the failed gym trace proved connected+s5=0 must escalate,
        # while 2A37 and the connection epoch must exist before motion bring-up.
        for needle in [
            "case missingConnectionEpoch",
            "case awaitHeartRate",
            "case beginBringUp",
            "private func beginConnectionEpoch(peripheral: CBPeripheral",
            "private func beginHRFirstDenseBringUpIfNeeded(peripheral: CBPeripheral",
            "private func beginProtectedR10BringUpForCurrentEpoch(peripheral: CBPeripheral",
            "forKey: WorkoutMotionDefaults.activationConnectionAt",
            "reason: \"state_restore_connected\"",
            "reason: \"did_connect\"",
            "denseStreamFresh: denseStreamFresh",
            "acceptedHeartRateGap: acceptedGap",
            "|| (denseFresh && acceptedGap >= config.hrContinuityTimeout)",
            "status=stale_disconnect_ignored",
            "status=stale_connect_failure_ignored",
            "scheduleWorkoutMotionLeaseEvaluation(reason: \"activation_followup\")",
        ]:
            assert_contains(self, manager, needle)

        coordinator_start = manager.index(
            "private func beginHRFirstDenseBringUpIfNeeded(peripheral: CBPeripheral"
        )
        coordinator_end = manager.index(
            "private let minimumEventDrivenCheckpointInterval",
            coordinator_start,
        )
        coordinator = manager[coordinator_start:coordinator_end]
        self.assertLess(coordinator.index("heartRateCharacteristic?.isNotifying == true"),
                        coordinator.index("discoverServices([Self.UUIDs.strapService])"))
        self.assertNotIn("setNotifyValue(false", coordinator)
        assert_contains(self, manager, "protectedR10ResponseEventDataNotifyOrder")
        assert_contains(self, manager, "Cmd.sendR10R11Realtime, 0x01")
        assert_contains(self, manager, "Cmd.toggleIMUMode, 0x01")

    def test_20260720_read_only_history_capture_is_command_firewalled(self):
        manager = source(ROOT / "Atria" / "Atria" / "AtriaBLEManager.swift")
        policy = source(ROOT / "Atria" / "Atria" / "AtriaBLEReadOnlyHistoryCapture.swift")

        for needle in [
            "static let getDataRange = Command(opcode: 0x22, payload: [0x00])",
            "static let sendHistorical = Command(opcode: 0x16, payload: [0x00])",
            "static let abort = Command(opcode: 0x14, payload: [0x00])",
            "static let exactTrace = [getDataRange, sendHistorical, abort]",
            "static let postRangeResponseSettle: TimeInterval = 2",
            "static let maximumCapturedFrames = 50",
        ]:
            assert_contains(self, policy, needle)

        send_start = manager.index("private func sendCommand(_ cmd: UInt8")
        write_start = manager.index("p.writeValue(frame, for: tx", send_start)
        send_body = manager[send_start:write_start]
        assert_contains(self, send_body, "if readOnlyHistoryCaptureRequested")
        assert_contains(self, send_body, "AtriaBLEReadOnlyHistoryCapturePolicy.allows")
        assert_contains(self, send_body, "reason=outside_exact_allowlist action=no_write")

        capture_start = manager.index("private func startReadOnlyHistoryCaptureIfNeeded")
        capture_end = manager.index("private func startReadOnlyClockProbeIfNeeded", capture_start)
        capture = manager[capture_start:capture_end]
        self.assertLess(capture.index("Cmd.getDataRange"), capture.index("Cmd.sendHistoricalData"))
        self.assertLess(capture.index("postRangeResponseSettle"), capture.index("Cmd.sendHistoricalData"))
        self.assertLess(capture.index("Cmd.sendHistoricalData"), capture.index("Cmd.abortHistoricalTransmits"))
        for forbidden in ["Cmd.getClock", "Cmd.toggleRealtimeHR", "Cmd.enterHighFreqSync",
                          "Cmd.historicalDataResult"]:
            assert_not_contains(self, capture, forbidden)

        handler_start = manager.index("private func handleProprietary(")
        switch_start = manager.index("switch payload.first", handler_start)
        handler_prefix = manager[handler_start:switch_start]
        assert_contains(self, handler_prefix, "handleReadOnlyHistoricalPayload")
        assert_contains(self, manager,
                        "detail=read_only_capture_owns_transport action=no_production_commands")

    def test_20260718_confirmed_sleep_projects_into_durable_daily_history(self):
        sessions = source(ROOT / "Atria" / "Atria" / "Sessions.swift")

        # Confirmed main sleep is the only authoritative overlay for historical
        # sleep/recovery inputs; candidates and naps remain evidence-only.
        projection_start = sessions.index("static func makeSavedDailyMetrics(rollups:")
        projection_end = sessions.index("static func dailyRecoveryInputsChanged(", projection_start)
        projection = sessions[projection_start:projection_end]
        for needle in [
            ".filter { $0.confirmed && !$0.isNapEvidence }",
            "let sleepDuration = night.map(\\.duration)",
            "fallbackRMSSD: hrv",
            "sleepDuration: sleepDuration",
            "sleepStart: night?.start",
            "sleepEnd: night?.end",
        ]:
            assert_contains(self, projection, needle)

        morning_start = sessions.index("static func makeMorningFrozenDailyMetric(for day:")
        morning_end = sessions.index("static func morningMetricDay(for night:", morning_start)
        morning = sessions[morning_start:morning_end]
        assert_contains(self, morning, "confirmedMainSleep != nil || hasAnyConfirmedMainSleep || hour >= 4")
        assert_contains(self, morning, "} else if !hasAnyConfirmedMainSleep {")
        # 2026-07-18 P4: the only exception is an exact, all-2A37 clean-wear
        # input routed through Recovery v2's `.unverified` sleep-missing model.
        assert_contains(self, morning, "reducedConfidenceUnconfirmedRecoveryInput")
        assert_contains(self, morning, "reducedConfidenceInput?.hrv")
        reduced_start = sessions.index("static func reducedConfidenceUnconfirmedRecoveryInput(")
        reduced_end = sessions.index("static func configuredSleepBaseNeedHours(", reduced_start)
        reduced = sessions[reduced_start:reduced_end]
        assert_contains(self, reduced, "contributing.allSatisfy(\\.hasQualifiedRRProvenance)")
        assert_contains(self, sessions, "point.source == .verifiedWhoop4HistoricalV24")
        assert_contains(self, reduced, "metrics.hrvWindowCount >= 3")

        persistence_start = sessions.index("static func makeDailyRollupStoreEntries(metrics:")
        persistence_end = sessions.index("static func makeDailyRespiratoryRatePreparation(", persistence_start)
        persistence = sessions[persistence_start:persistence_end]
        assert_contains(self, persistence, "lnRMSSD: hrvMilliseconds.map(log)")
        assert_contains(self, persistence, "sleepSeconds: metric.sleepDuration")


if __name__ == "__main__":
    unittest.main()
