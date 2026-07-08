# UI/UX + Metric-Consistency Session — 2026-07-08

Full record of the UI/UX and metric-display-consistency work. All commits below are
merged to `main` (PRs #14–17) and installed + launch-verified on the physical device
(iPhone `3803F5B6`, `launch_seen=1`, 0 crashes).

---

## 1. What was done (shipped to `main`)

### PR #14 — `ui-loop-6`: forward-usability + fix loop (12 device-verified fixes)
Merged first (commit `a82498f4`). Preceding autonomous loop; each fix passed the
static-check gate + full unit suite and was launch-verified on device.

| Commit | Fix |
|---|---|
| `e1bf3e1e` | HR timeline loads a full 24h span (was capped ~1.7h); off-main downsample + debounced re-parse |
| `9fd473a4` | Dedicated **morning journal notification** decoupled from the sleep-gated summary |
| `ba2e2c91` | Journal reminder re-engage window 7 → 14 days (survives a lapse) |
| `e5a26068` | **Sleep wake-expansion** — a wake-then-sleep-again grows the confirmed night; extend-only, protects manual edits (two adversarial-review passes) |
| `49167c17` | Workout-detail HR trace cached off the render path |
| `29321e15` | Research summaries computed off-main (hang fix) |
| `c9625e04` | Recovery daily-metric re-mints when the scored night changes instead of going stale |
| `89d12f4e` | Calibration honesty — "Night X of 14" (real threshold) instead of a false "Day 4 of 4" ring |
| `df8e557a` | Real HRV/RHR numbers shown *during* calibration with an honest "night N/14" note |
| `a85f98b5` `d60a8681` | Journal questions: Energy, Focus, Wind-down (feed the correlation engine) |
| `7d34e0f2` | Fitness age computed weekly, not per-refresh (WHOOP-style cadence) |

### PR #15/#16/#17 — `ui-ux-polish`: consistency + empty-state pass

**`e6b14edb` — Empty-state honesty (live grid `AtriaTodayScreen.glanceItem`)**
The calibrating grid mixed honest progress ("HRV 0 of 14 nights") with bare
unit/category labels. Fixed the three bare ones, each verified honest against the real gate:
- **Resting HR** → `"N of 14 nights"` while pending (mirrors the HRV tile:
  `isPendingHeroValue` + `baselineNightsProgress(freshRestingSampleCount())`,
  14-night `PersonalBaseline.trustedMinimumSamples`), then plain `"bpm"`. Also corrected
  a false comment claiming RHR text "is always numeric".
- **Resp rate** → `"After a sleep"` (per-overnight-sleep signal, `Sessions.swift:4552` —
  deliberately **not** a "night N of 14" countdown, which would be false), then `"/min"`.
- **Sleep eff** → `"Needs time in bed"` (efficiency = time asleep / time in bed, needs a
  known in-bed span, `Sessions.swift:4243`), then `"Sleep"`.

**`b5d5aa13` — Recovery consistency (39% vs 67%) + period selector → D/W/M**
- **Root cause of 39-vs-67:** the recovery detail-sheet headline (`recoveryHeroValue`,
  `AtriaOverviewSections.swift:7234`) read the **live** `Metrics.recoveryV2` recompute
  (`recoveryEstimate.percent`) and never indexed the period `range`. It was therefore
  *invariant to the selector* AND drifted from the **frozen** morning value
  (`DailyRollupStoreEntry.recovery`) that the tile, health row and widget read.
- **Fix:** the headline now reads the same frozen daily-rollup series the chart plots
  (`preparedHistory.recoverySummary[range]`): **Day** = that settled day's recovery
  (carried like the tile, so it equals the 67%), **Week/Month** = the window average.
  The hero tint grades that same value.
- **Period selector:** the two live segmented bars now show only **Day / Week / Month**
  (`AtriaTrendRange.primarySegments = [.day,.week,.month]`). Deeper cases
  (`quarter/sixMonths/year/all`) stay in the enum so every per-range data-prep loop and
  the internal `.all` read are untouched. Kept a segmented control (no `Menu`) — a
  readability guard (`test_handoff_static_checks.py:717`) forbids a `Menu` there.
- Added `AtriaTrendRange` unit tests (`primarySegments` == D/W/M; `.all` still in `allCases`).

**`14af0b8e` — Detail headlines track the period too**
The same period-invariance affected every detail headline (all were
`latestMetricText(points.last)` — the same most-recent day for D/W/M). New
`periodHeroText` helper: **Day** = latest (byte-identical to before), **Week/Month** =
the window average from the same `XSummary[range]` the chart's Avg strip uses. Applied to
hrv / rhr / respiratory / sleep / strain / sleepPerformance. Migrated the strain-detail
static pin (`test_handoff_static_checks.py:8943`) with a dated note.

**`b6227e49` — Settle the HRV + RHR overview tiles**
The HRV/RHR tiles showed the **live** hero value (`displayHero.hrvValue` /
`restingHeartRateText`, which can be a BLE read) while their detail sheets read the
frozen rollup — so a tile could disagree with its own detail. New
`displaySettledHRV` / `displaySettledRHR` (mirror `displayRecovery`): read the newest
stored rollup — `Int(exp(lnRMSSD).rounded())` for HRV, `rhr` for RHR (byte-identical to
the detail number) — labeled **"this morning" / "yesterday"** so a carried value is never
read as fresh. Falls back to the live value + "N of 14 nights" only when no rollup carries
a reading. **Strain stays live** (it accumulates through the day); respiratory already
reads the rollup. Adversarially verified (numeric parity, no regressions in
disconnected/calibrating/warm-up, strain untouched).

**`6e3d8ab4` — "Resting trend" card shows the real resting-HR trend**
The default-overview "Resting trend" card rendered `displayHero.loadSignalSummaryText` —
a *training-load* readout (`"ACWR 1.2 balanced, monotony 0.8 varied"`) — under a
resting-HR title. Per user choice, re-wired to `displayRestingTrend`: the **direction of
resting HR** over the last up-to-14 nights (recent-half avg vs earlier-half avg of
`store.restingTrend14`), e.g. `"↓ 2 bpm"` / `"lower over 14 nights"`; lower resting HR is
the better direction. Needs 6 nights (3 vs 3) before a direction is honest, else
`"Learning · N of 6 nights"`. The card is display-only (no detail sheet), so nothing
downstream changed; `loadSignalSummaryText` stays wired to the Load detail + hero snapshot.

---

## 2. Key architecture findings

- **The live overview grid is `AtriaTodayScreen.glanceItem(for:)`** (mounted at
  `AtriaHomeView.swift:2427`), using `AtriaTodayGlanceItem`/`AtriaTodayGlanceTile`. The
  detail sheets (`AtriaMetricDetailSheet`, `AtriaOverviewSections.swift:6668`) are live too
  (confirmed via the `recovery-detail` fixture).

- **The entire legacy `AtriaOverviewSections` glance grid is DEAD CODE.** The chain roots
  at `AtriaOverviewTabContent` (`AtriaOverviewSections.swift:106`), which is **never
  instantiated** (repo-wide grep). Chain: `AtriaOverviewTabContent` →
  `AtriaDisconnectedOverviewHost@293` / `AtriaOverviewLeadingHost@533` →
  `AtriaOverviewReadinessSectionHost@1229` → `AtriaOverviewReadinessSection@1820`
  (`glanceCard@2848`). **Consequence:** the Sleep-eff edit at
  `AtriaOverviewSections.swift:2950` and commit `a5168a46` (Resting-trend "0 of 2 nights"
  at `:3126`) are **harmless no-ops on dead code**. Left in place (removal is large + risky
  with zero user impact) — documented here so nobody re-edits the dead grid.

- **Single settled-source pattern, now consistent across three surfaces.** Today tiles,
  detail sheets, and the Vitals Health Monitor rows all read **settled-first** with the
  **same formulas**: RHR = `Int(rhr)`, HRV = `Int(exp(lnRMSSD).rounded())`; live fallback
  is honestly labeled ("today · estimate" in Vitals; "this morning"/"yesterday" on the
  Today tiles). Vitals (`AtriaHealthScreen`) already did this (2026-07-06 unification); the
  settled-tile fix brought the Today tiles into the same pattern.

---

## 3. Verification

- **Gates on every commit:** `python3 test_handoff_static_checks.py` (pins migrated with
  dated notes where changed) + full unit suite (`AtriaTests`, "TEST SUCCEEDED").
- **Screenshot-verified on sim:** empty-state strings render (Resp rate "After a sleep"
  confirmed); recovery-detail sheet shows the D/W/M-only bar with a consistent headline.
- **Adversarial workflow verification** (design + refute) for the honest calibration
  strings and the settled-tile format parity (GO verdict).
- **Device:** every milestone installed + launch-verified on iPhone `3803F5B6`
  (`launch_seen=1`, 0 crashes). The `↓/↑ N bpm` trend and settled tiles render against real
  rollup data there.

---

## 4. Remaining / follow-ups

**Latent (need data — cannot be built now):**
- **Habit-learning (#7):** the correlation engine (Spearman + threshold-split) exists and
  is tested; it needs *weeks* of journal + recovery data to surface real insights.
- **Deeper perf / hangs (#4):** the main overview's expensive computations
  (`dayDescendingRollups` sort, `strainCompareMedian`) are already memoized behind
  `dailyRollupHistoryRevision`. Finding more needs a real on-device profiling trace, not
  code guessing.

**Deferred / open decisions:**
- **Overview tiles vs detail for a today-in-progress reading:** recovery is fully
  reconciled (its tile is also frozen). HRV/RHR/sleep/strain tiles are now settled too; if
  a future need is a live "today" number on those tiles, it should carry a clear
  "today · estimate" label like the Vitals rows.
- **RHR settled-tile detail** currently shows the freshness label ("this morning"/
  "yesterday") instead of "bpm" — consistent with recovery/HRV. One-line variant available
  to show `"bpm · yesterday"` if the unit should stay visible.
- **Dead legacy overview grid** — could be deleted for code health (large, risky, no user
  impact). Not done.
- Minor: `.sleepHistory` "Routine" and `.insights` "Highlights" are weak subtitles (not
  mismatches). `recovery Scope 2` (hero re-sourcing) remains deferred (latent + blast
  radius).

**Environment note:** the iOS simulator (`51BECE0B`, iPhone 17 Pro, iOS 26) was
chronically unstable this session — it shut down mid-sequence and `clean` operations
re-cloned it and broke the destination. Workaround: `boot` + `bootstatus` first, use plain
(incremental) `test` after a standalone `clean build`, verify compiled literals by grepping
`Atria.app/Atria.debug.dylib` (the thin launcher loads the dylib), and lean on device
installs. The `dashboard-autoscroll` fixture bounces top↔bottom non-deterministically;
~3.3–3.9s after a fresh launch tends to catch the bottom grid.
