# Consolidated status — dev

> **Superseded for current Git/install work (Aug 10):** the authoritative
> branch tip is now `f68c14c9352e40972d38f420279144cba761b467`, pushed with
> upstream parity `0 0`. Use
> [`CLAUDE_F68C14C_PHYSICAL_HANDOFF.md`](./CLAUDE_F68C14C_PHYSICAL_HANDOFF.md)
> for the exact remaining physical checklist. The historical branch-tip and
> required-Git-action sections below are retained only as an audit trail.

Merges Codex's Final-Acceptance-Checklist report (landed `4c1e3887`) with this
Claude session's additions (sleep ring, strain finding, graph smoothing) and the
current git state. Author/committer on every commit: `adidshaft <adidshaft@gmail.com>`,
no trailer. Issue #33 open. No TestFlight.

## Branch history (linear, newest last)
```
422add5c  BLE/MainActor defaults deadlock + crash-consistent restore-slot   (ESSENTIALS handoff CP1/CP2)
4c1e3887  Graph-truth & sparse-series UI corrections                        (FINAL checklist CP1–5, 8, 9)  ← Codex report
cf06696c  Sleep ring from measured hours + NEW-3 short-gap monotone         (this session)
8ad99939  NEW-3 refinement — BAD: swept user Vitals WIP into the commit     ← REMOTE TIP (needs fix)
18181f46  NEW-3 refinement — FIXED: my files only, user WIP uncommitted     ← LOCAL TIP
```
Remote = `8ad99939`, Local = `18181f46`, diverged 1/1 (the two NEW-3 siblings). `4c1e3887` and `cf06696c` are both pushed ancestors. **Codex's "parity 0 0 at 4c1e3887" is stale — the branch advanced +2.**

---

## Part 1 — Final Acceptance Checklist (landed `4c1e3887`) — accepted, carried forward

| CP | Result |
|----|--------|
| 1 Live HR gap truth | ✅ HR segments at the shared 2-min threshold, Charts `series` keyed per run → multi-hour holes stay blank; lone runs get PointMarks; trailing bpm axis un-clipped |
| 2 Stress bands | ✅ `AtriaStressContextInterval` coalesces asleep/activity minutes into one band per run (both charts); ±30 s barcode gone; never bridges a gap |
| 3 Sleep distribution | ✅ Unavailable card compacted; no-fabrication motion/integrity gate locked with regressions |
| 4 Saved/overnight HR | ✅ `AtriaExactWindowHeartRate` unions canonical + archive + observed HR; `.loading` state; refreshes on history revision |
| 5 Sparse Trends | ✅ `AtriaTrendSparseGrammar` — every observed/lone-day point visible; area only at 5+ points meeting coverage; card shrinks when sparse |
| 8 Validation | ✅ 267 focused tests, 0 failures; parse clean; `git diff --check` clean; app target builds |
| 9 Commit/push/issue | ✅ committed, pushed, #33 updated, 14 user diffs preserved |

## Part 2 — CP6 / CP7 — UPDATED (device-proven this session, supersedes Codex's report)

Codex's report listed CP6 as NOT EXERCISED and CP7 as pending a strap mode change. After your on-device authorization ("Can you try these now?…"), both were run and **passed** on the installed build (engine = `422add5c`, unchanged by the UI passes):

- **CP6 drain-on-glance — ✅ PASS.** Foreground → `workout_motion_bank_offload frontier_ticket_created` → `receipt_refresh_complete reason=compact_generation_durable`; receipt strictly strengthened (window 808035902 motionTicks 976→1058, capturedThrough advanced), strongest durable intact, 0 regressions. (First attempt power-pressure-parked; retried at higher battery.)
- **CP7 central-rebuild — ✅ PASS, and it does NOT need a strap mode change.** `--atria-force-hr-continuity-watchdog-after 120` + backgrounding the app fires the in-process `rebuildCentralForWedgedSessionOnce`: exactly one `post_connect_repair=action_central_rebuild`, same PID survived (no 0x8BADF00D — deadlock fix held), restore slot flipped `…v8-pure-hr`→`…recovery-b-v1` after retirement (crash-consistency fix), old session reaped, no CCCD 0x002b disable, accepted HR resumed >60 s. (Corrects Codex's "needs long-wear/full-protocol mode" — backgrounding is the trigger.)

## Part 3 — This session's product work (NEW-1/2/3)

- **NEW-1 Sleep ring — ✅ done + device-verified** (`cf06696c`). The Today tri-ring drew Sleep as the generic dotted "awaiting-data" track whenever `fill==nil`; need-based `sleepPerformancePercent` was nil. Fix: fall back to slept-hours / `sleepGoalHours` proportional fill + Sleep tint (closure marker still gated on real need — no fabrication). Confirmed filled green (8 h 7 m) on the mirror.
- **NEW-2 Strain "0.2" — ✅ investigated, NO change (legitimate).** `AtriaStrainLoadModel` uses a 30 % HRR floor (~96–99 bpm at rest 60 / max ~187); ~90 bpm ≈ 24 % HRR → contributes ~0. Test-pinned + literature-cited; not a regression from the personalized-strain commit `1c2cc966`. Making it WHOOP-like (accrue from any elevation) is validation-gated product tuning that breaks pinned tests — **your call**, not done unilaterally.
- **NEW-3 Two-tier gap smoothing — ✅ code done + sim-tested; ⚪ device-verify pending (phone at gym).** `cf06696c` switched compact HR + Stress traces `.linear`→`.monotone`; the on-device zoom still showed short breaks, so `18181f46` adds `AtriaChartVisualGrammar.traceDisplayContinuityGap = 5 min` (display-only), scoped to **ambient/all-day** traces (Vitals HR, Live Stress, Health-screen stress/HR). **Workout traces stay strict** (a short hole mid-workout is meaningful). Strict `heartRateGapThreshold`/`maximumFactContinuityGap` (coverage/telemetry) untouched. 4 focused suites green + new regression test.

## Part 4 — Git action required (Codex)

The remote tip `8ad99939` wrongly bundled the user's Vitals WIP (my `git commit --only` committed working-tree content). Corrected locally to `18181f46`. See `docs/handoff/CODEX_NEW3_GIT_HANDOFF.md` + patches (`new3-correct-commit.patch`, `user-vitals-wip.patch`). Recommended fix (Recipe A, on this working copy):
```
git push --force-with-lease=dev:8ad99939 origin dev
```
Do NOT `git pull` (local/remote diverged by design). All 14 user dirty chart files remain uncommitted/preserved.

## Part 5 — Still gated on your explicit go-ahead
- **NEW-3 device visual verification** — build + install + mirror-confirm the smoothed traces (~6 min, needs the phone).
- **Strain WHOOP-like re-tuning (NEW-2)** — validation-gated; breaks pinned tests; product decision.
- **TestFlight** — not uploaded.
- (CP7's *long-wear/full-protocol* forensic is no longer required — backgrounding proved the rebuild — but if you still want that specific mode-change run, it needs the strap mode change you'd previously declined.)
