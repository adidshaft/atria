# Codex handoff — correct the NEW-3 commit that swept in user WIP

**Branch:** `codex/whoop-remaining-product-gaps`
**Author/committer for every commit:** `adidshaft <adidshaft@gmail.com>` — **no** `Co-Authored-By` / Claude / Codex trailer.
**Do NOT** run TestFlight, forced rebuilds, process kills, or Bluetooth mode changes.

---

## TL;DR

I (Claude) implemented **NEW-3** (smooth brief telemetry hiccups in the live HR + Stress traces) and, in the commit step, used `git commit --only <paths>` — which commits the **working-tree** content of the named paths, not the staged index. For `AtriaVitalsCollectionSections.swift` the working tree held **my 2 hunks PLUS the user's uncommitted WIP**, so the user's WIP was swept into the commit and pushed. The other 13 dirty files were untouched.

- **Remote HEAD (BAD, pushed):** `8ad9993903a3445538c6a56fb17adc0712dbecca`
  Contains my correct NEW-3 change **and** the user's 2 Vitals WIP hunks (should not be there).
- **Local HEAD (FIXED, NOT pushed):** `18181f46786dbd64b7461cf342c0e30b2dc39bca`
  Contains **only** the NEW-3 change; the user's Vitals WIP is back as an **uncommitted** working-tree change.
- **Base (pre-NEW-3 tip):** `cf06696cfa01781e1a309e157bf124137e362a3d`

The user asked that **you (Codex) handle the git correction** rather than have me force-push. Two clean recipes below. Recipe A (rewrite + force-push) is recommended and produces identical history to what should have happened.

> ⚠️ The local checkout is currently at `18181f46` (the fixed commit) with the user's Vitals WIP uncommitted on top. Local and remote have **diverged by 1 commit each**. **Do not `git pull`/merge** — it would knit the bad and good commits together. Pick a recipe below.

---

## What NEW-3 is (the change that SHOULD land)

**Goal (user request):** graphs for stress/HR should read smoothly across *brief* signal hiccups; only *genuine, long* dropouts should break the line and stay blank. Two failure modes the user named: (1) long signal drops → stay blank (already handled), (2) short drops → previously broke the line, "that kind of break is bad looking" → now smoothed.

**Design:** a display-only continuity window, distinct from the strict data/coverage thresholds.

- New constant `AtriaChartVisualGrammar.traceDisplayContinuityGap = 5 * 60` (`AtriaGraphGrammar.swift`), with a docstring explaining it smooths ≤5-min hiccups while a >5-min dropout still breaks into a new Charts `series` and stays blank. The strict `heartRateGapThreshold` (2 min) and `maximumFactContinuityGap` (90 s) used for **telemetry integrity + coverage accounting are untouched**.
- **Scope = ambient / all-day live traces only** (what the user screenshotted). **Workout traces stay strict** (a short hole in a focused session is meaningful), so `AtriaStressTimelinePoint.segment`'s **default is left at `maximumFactContinuityGap`** and the ambient sites opt in explicitly:
  - `AtriaHeartRateChartSeries.smoothedBuckets` + the raw `segmentedPoints` in `AtriaVitalsCollectionSections.swift` → use `traceDisplayContinuityGap` (Vitals HR chart).
  - `AtriaStressTimelineEvidenceProjection.make(...)` in `AtriaStressDetailView.swift` → passes `traceDisplayContinuityGap` (feeds the Vitals "Live Stress" card + expanded stress detail).
  - The HR-under-stress raw trace in `AtriaStressDetailView.swift` → `traceDisplayContinuityGap`.
  - `AtriaHealthScreen.swift` caller (ambient stress `points`) → passes `traceDisplayContinuityGap`; the overnight HR trace's hardcoded `5 * 60` was DRY'd to the constant.
  - `AtriaWorkoutStressTraceSummary` (workout) and `reduceStressStrip` (legacy, unrendered, test-pinned) intentionally **keep the strict gap**.
- Regression test added: `AtriaStressDetailViewTests.testAmbientStressTraceConnectsAShortHiccupButBreaksARealDropout` — 3-min gap connects under the display gap, >5-min breaks, and the strict default still breaks the 3-min gap (guards workouts).

**Files in the correct commit (`18181f46`) — 5 files, +83/−14:**
```
Atria/Atria/AtriaGraphGrammar.swift
Atria/Atria/AtriaHealthScreen.swift
Atria/Atria/AtriaStressDetailView.swift
Atria/Atria/AtriaVitalsCollectionSections.swift        (ONLY 2 hunks: smoothedBuckets @4491, segmentedPoints @5431)
Atria/AtriaTests/AtriaStressDetailViewTests.swift
```

**Validation:** focused suites pass on the iOS-27 sim (`AtriaStressDetailViewTests`, `AtriaHeartRateTimelineWindowTests`, `AtriaVitalsProjectionStoreTests`, `AtriaActivitySectionsCacheTests`) — `** TEST SUCCEEDED **`. Not yet built/installed on device (the user took the phone to the gym).

---

## The defect in the pushed commit `8ad99939`

`AtriaVitalsCollectionSections.swift` in `8ad99939` has **four** hunks. Two are mine (correct), two are the user's WIP (must be uncommitted):

| Hunk | Owner | Content |
|------|-------|---------|
| `@@ -1157` (`AtriaHealthMonitorSparkline`) | **USER WIP — remove from commit** | `.interpolationMethod(.linear)` → `.monotone` + `.lineStyle(AtriaChartVisualGrammar.trendLine)` |
| `@@ -4491/4493` (`AtriaHeartRateChartSeries`) | mine — keep | `heartRateGapThreshold` → `traceDisplayContinuityGap` (smoothedBuckets) |
| `@@ -5428/5433` (`AtriaHeartRateAxisChart`) | mine — keep | `heartRateGapThreshold` → `traceDisplayContinuityGap` (raw segmentedPoints) |
| `@@ -5564/5571` (`AtriaHeartRateAxisChart`) | **USER WIP — remove from commit** | `.atriaGraphPlotSurface()` + `.background(Color.primary.opacity(0.035))` |

The user's two hunks must end up as **uncommitted working-tree changes** (joining the other 13 dirty chart files), never in tracked history.

---

## Desired end state

1. Branch tip = a commit identical to `18181f46`: the 5 NEW-3 files, Vitals containing **only** the two `traceDisplayContinuityGap` hunks.
2. Working tree = that tip **plus** the user's uncommitted WIP: the 2 Vitals hunks above **and** the 13 other untouched dirty chart files.
3. Author + committer `adidshaft <adidshaft@gmail.com>`, no trailer.
4. Issue #33 stays open. No TestFlight.

---

## Recipe A — rewrite + force-push (recommended, cleanest)

If you are operating on **this** working copy, the local `18181f46` is already the corrected commit with WIP restored — just publish it:

```bash
git rev-parse HEAD          # expect 18181f46...
git show HEAD --stat        # expect the 5 NEW-3 files only
git diff HEAD -- Atria/Atria/AtriaVitalsCollectionSections.swift   # expect ONLY the 2 user hunks
git status --porcelain | grep -c '^ M'                              # expect 14 dirty files
git push --force-with-lease=codex/whoop-remaining-product-gaps:8ad9993903a3445538c6a56fb17adc0712dbecca origin codex/whoop-remaining-product-gaps
```

The `--force-with-lease` pins the expected remote tip (`8ad99939`) so the push is refused if anything else moved it.

If you are on a **fresh clone** (only `8ad99939` present), apply the shipped patch instead:

```bash
git reset --hard cf06696cfa01781e1a309e157bf124137e362a3d
git am docs/handoff/new3-correct-commit.patch      # recreates 18181f46 content, author preserved
git apply docs/handoff/user-vitals-wip.patch       # restores the user's 2 Vitals hunks (uncommitted)
git push --force-with-lease origin codex/whoop-remaining-product-gaps
```

## Recipe B — forward revert (no history rewrite, no force-push)

Keeps `8ad99939` in history and lands a follow-up commit that removes just the user's two hunks and returns them to the working tree:

```bash
git checkout codex/whoop-remaining-product-gaps      # at 8ad99939
git apply -R docs/handoff/user-vitals-wip.patch      # remove the 2 user hunks from the working tree
git add Atria/Atria/AtriaVitalsCollectionSections.swift
git commit -m "Un-commit Vitals chart WIP that landed by mistake"   # author adidshaft, no trailer
git apply docs/handoff/user-vitals-wip.patch         # put the 2 hunks back, now uncommitted
git push origin codex/whoop-remaining-product-gaps   # normal fast-forward
```

Downside: two commits in history reference the WIP (added then removed). Recipe A is cleaner.

---

## Shipped patch files (in `docs/handoff/`)

- `new3-correct-commit.patch` — the full correct NEW-3 commit (`git am`-able, author `adidshaft`).
- `user-vitals-wip.patch` — the user's 2 Vitals WIP hunks (`git apply`-able), so they stay uncommitted.

## Guardrails
- Never commit any of the 14 dirty chart files or the `docs/handoff/*` / handoff docs.
- Prefer the index-only staging technique (`git apply --cached` a per-file patch) over `git commit --only` for files that also carry the user's WIP — `--only` commits working-tree content and re-introduces this bug.
- Keep issue #33 open; do not upload TestFlight.
