# Handoff — Metrics visuals enrichment + feature completion (2026-08-03)

Branch: `claude/atria-background-continuity-88ce90` (worktree
`.claude/worktrees/atria-background-continuity-88ce90`). Codex parity branch:
`codex/atria-reliability-handoff-2026-07-22`.

## 10. Chart honesty review (2026-08-03, device-observed) — READ THIS

Live device review with the user surfaced a cluster of **chart honesty** defects,
all rooted in the same thing: **the install has very little real data (~3 days,
Aug 1–3), and the charts degrade badly with sparse data** — inventing shape,
connecting across gaps, and showing empty/confusing views. Fixes shipped where
noted; the rest is a ranked backlog. These are product-level rules to apply
THROUGHOUT, not one-off patches.

### Findings
1. **Fabricated "prior period" ghost line (FIXED, `d9a942ee`).** The dashed blue
   curve on every metric detail chart was a `.monotone` spline through the prior
   window's sparse points — it swooped to values (≈5) and peaks (≈75) on days
   that had no such reading. "Random, nothing to do with the real figure."
   Removed the per-day ghost curve; kept only the honest FLAT prior-average
   reference line. Current line + area switched `.monotone` → `.linear`.
2. **Lines drawn across day-gaps (FIXED in the combo; APP-WIDE TODO).** A
   `LineMark` over non-consecutive days draws a straight segment across unworn
   days, implying data that never existed. Fixed in `AtriaStrainRecoveryComboChart`
   via a contiguous-run id that breaks the line at gaps. **Every other line chart
   in the app still connects across gaps** — apply the same run-splitting.
3. **Expanded chart shows "nothing there" on sparse data.** `AtriaExpandedChart`
   opens with a brushed selection that lands on days with no points →
   "No data in selection" (`AtriaExpandedChart.swift:604`) over a near-empty
   plot, plus a "fabricated 0…1 axis / 1 of 1 days visible" fallback
   (`:92,:100`). Reads as broken. Needs a sparse-data "building history" state.
4. **Smooth interpolation in general fabricates curvature.** `.monotone`/
   `.catmullRom` invent shape between real points. Honest default is `.linear`
   (straight segments between real readings) everywhere.

### Product decisions (apply throughout — added to memory `atria-product-decisions`)
- **Use native Apple Swift Charts** wherever a chart is needed and native serves
  it better — do NOT hand-roll custom `Path`/`Shape` charts when Swift Charts
  covers it. (The app already standardizes on Swift Charts; keep it that way.)
- **Strain & Recovery combo = two zigzag lines** (strain line + recovery line on
  a dual 0–21 / 0–100% axis), recovery points colored by band — NOT line+dots.
- **Never fabricate shape:** `.linear` only; break every line at day-gaps; no
  per-day prior ghost (flat prior-average reference is the honest comparison).
- **Sparse data degrades honestly:** show a "building history / N days so far"
  state instead of empty plots, fabricated axes, or empty brush selections.
- This is the honesty-first LAW applied to charts: a chart must never draw a
  point, segment, or curve that doesn't correspond to a real reading.

### Ranked backlog (chart honesty)
- **C1 — App-wide gap-breaking:** factor the combo's contiguous-run split into a
  shared helper and apply to every metric detail line (recovery/hrv/rhr/resp/
  sleep/strain) + `AtriaTrendChart` + `AtriaExpandedChart`.
- **C2 — Sparse-data state:** replace empty expanded-chart / "No data in
  selection" / fabricated-0…1-axis with an honest "building history" view; audit
  the default brush so it opens on days that have data.
- **C3 — Interpolation audit:** sweep all `.monotone`/`.catmullRom` chart usages
  → `.linear` (or justify each remaining one).
- **C4 — Combo on the Activity surface** (original G1 part b) + apply the two-
  line treatment consistently.
- **C5 — Re-verify on device** once the install has ≥1–2 weeks of real data, so
  charts are reviewed with realistic density, not a 3-day cold start.

## STATUS — shipped this session (2026-08-03), all on `claude/atria-background-continuity-88ce90`

Device-verified via iPhone Mirroring unless noted:
- ✅ Magnesium opt-in behavior tag (example of the generic engine) + test.
- ✅ Banner honesty: "Catching up history" now reflects real drain progress
  (last-flush recency + lease), Sync gives feedback. Unit-tested.
- ✅ Chart honesty pass: removed the fabricated `.monotone` prior-period ghost
  curve (device-verified gone); `.linear` everywhere (~24 usages / 12 files);
  lines break at day-gaps app-wide; sparse-data "building history" state in the
  expanded chart. No hardcoded/sample data in production (all DEBUG-gated).
- ✅ Strain & Recovery combo (native Swift Charts): two zigzag lines, band-
  colored recovery, gap-broken, **fixed 7-day weekday axis** (render-verified).
  Lives in the Strain + Recovery **details** (NOT Activity).
- ✅ Activity view = intraday + log: **stress monitor + past-24h timeline** on
  top (device-verified, honest "collecting" state when sparse), day activity
  timeline, activities list. Weekly combo removed from Activity.
- ✅ G3 (behaviors strip in Recovery) + G4-style cardio/strength split found
  ALREADY built.
- Docs/memory: interpretation principle (§0.1), chart-honesty (§10), placement
  (§11) — all in memory `atria-product-decisions`.

**Shipped since (2026-08-04 loop, on `codex/atria-reliability-handoff-2026-07-22`):**
- ✅ Steps history chart (P2): 7-day steps bar chart + `AtriaStepsWeekChart`
  extraction with render proof (`080e618c`, `5bfc10a8`).
- ✅ About-sheet mini-trends (P1, `9f5a8ab5` + render-proof commit):
  `AtriaAboutMetricTrend` — same rollup transforms as the detail charts
  (HRV = e^lnRMSSD, sleep hours), nil under 5 readings in the last 30 days,
  linear gap-broken line + per-reading dots on a fixed 30-day frame, axes
  hidden with a real "N nights · lo–hi unit" caption instead. Wired at the
  Health screen + Health Monitor education sheets. Stress/SpO2 never produce
  a trend (no persisted daily history). Snapshot render verified (sheet
  content extracted as `sheetContent` because ImageRenderer can't draw
  NavigationStack — renders the error placeholder if handed the full sheet).

- ✅ Empty HR-timeline fabricated-axis fix (`be780a74`, sim-verified).
- ✅ Stress daily trend (`9c1a02a7`): "Stress by day" card in the stress
  detail — NO new persistence needed; reads the existing
  `AtriaStressDistributionArchive` (per-day band counts, 35-day retention,
  ≥10-sample floor). Stacked share-of-measured-time bars on a fixed 14-day
  frame, blank unmeasured days, building state under 3 measured days, no
  y-axis (bars sum to 1 by construction). Render-proof + gate tests.
- §9.4 audit: G1–G6 all done or covered (§9.7) — G2 deliberately stays the
  paired-bars debt chart, no duplicate line version.

- ✅ Sleep-efficiency per-night trend (P3, `0a23768f`): the detail graduates
  from honest-partial to a LAST 30 NIGHTS `AtriaMiniTrendCard` (shared
  extraction of the About-sheet trend card) fed by confirmed nights'
  `displaySleepEfficiency` (motion-honest; HR-only nights excluded); ≥5-night
  gate, honest-partial copy below it. Stress metric-sheet copy un-staled to
  point at the Stress monitor's new day-by-day trend.
- Skin-temp trend (P3 remainder): DECIDED covered-for-now by the About-sheet
  mini-trend (it charts `skinTemperatureDeviationCelsius` whenever rollups
  carry it); the dedicated detail stays honest-partial until real skin-temp
  values exist on an install to verify against (this install has all-None).

**Not yet done (backlog):** C5 re-verify at ≥1–2wk data density, optional
live-HR line on the Activity stress card, SpO2 (blocked on oximeter data,
§5), same-night Smart-Wake staging (blocked, §3.2). Watch items: Aug-4 sleep
backfill (§12 — still `sleepSeconds: None` at 06:40, drain mid-Aug-3) +
whether the frozen recovery 38 re-scores when the night lands.

## 11. Chart PLACEMENT principle (2026-08-03, user-directed) — right chart, right place

The right chart in the wrong place is still wrong. Match the chart's TIME SCALE
to the surface's purpose:

- **Activity view** = **intraday + log**. Heart/stress monitor, **past-24h**
  graphs (live HR, today's stress timeline), and the list of that day's
  activities (workouts / sleep / naps). NOT weekly/monthly trends. (User: "the
  activity view should only have heart/stress monitor, with graphs from past 24
  hrs and different activities listed.")
- **Strain & Recovery weekly combo** (the 7-day fixed-axis two-line chart) =
  the **Strain and Recovery metric details** (and a candidate for Overview),
  NOT Activity. It is a weekly trend, so it lives where weekly trends live.
- **Metric details** = that metric's history at the selected range + its
  contributors/behaviors.
- **General rule:** today/live/intraday → Activity & the live tiles; daily /
  weekly / monthly trends → metric details & Overview.

**Two fixes applied under this (`this commit`):**
1. The Strain & Recovery combo was REMOVED from the Activity tab (wrong place)
   and stays only in the Strain + Recovery details.
2. The combo now uses a **fixed 7-day x-axis** (seven weekday ticks) instead of
   a sparse 14-day window that rendered as a couple of scattered labels — it
   read as random noise. Data is framed within the week; days without a reading
   simply have no point.

**DONE (P-activity, this session):** the stress monitor + past-24h stress
timeline now sit at the top of the Activity view (`stressMonitorCard` in
`AtriaActivityMonitor.swift`, fed by `AtriaStressMonitorStore`), above the day
activity timeline and the activities list. Honest: observed readings only,
gap-broken, shows the state's "collecting/warming up" copy when sparse.
Follow-up option: add a live-HR number/line to the same card ("heart/stress").

## 12. Overnight inspection 2026-08-04 (~06:00 IST, container pull) — capture was DEAD all night

Ground truth via `devicectl` container pull (Documents + Library/Preferences).
Timestamp note: the `atria.keepalive.*` / `atria.offlineSync.*` defaults store
**Unix-epoch** seconds — decode against 1970, not the Apple 2001 reference
(decoding against 2001 reads as year 2057).

**Timeline (all IST):**
- Aug 3 18:03 — evening live session starts after the day's device review; only
  ~12 samples accepted by 23:35. `atria.hrContinuity.status = stale`,
  `atria.keepalive.stallReconnects = 96` — capture was already mostly dead
  through the evening.
- Aug 3 18:00 — `backgroundLeaseStatus.v1 = orphaned_process_terminated`.
- Aug 4 00:28:12 — app relaunched (background), keepalive armed, new session
  identity created.
- Aug 4 00:29:13 — **last keepalive tick of the night.** The process went
  silent ~60 s after relaunch and never ran again.
- Aug 4 05:58 — this session's install/launch revived capture; the strap
  streamed ~1 Hz immediately (73 samples in ~70 s), so it was worn, charged,
  and in range the whole time.

**Consequences:** no live overnight HR → no Aug-4 sleep/recovery at wake; the
night exists only on strap flash. `automaticFullDrainRecoveryEnabled` is
`true` again, so the catch-up drain should backfill it now that the app runs —
**verify an Aug-4 sleep + rollup appears** (that check doubles as an end-to-end
proof of "the app does the work" backfill).

**Freeze-race answer (06:45, from code):** the premature score is designed to
self-heal. `frozenLimitedFallbackIsAuthoritative` (Sessions.swift ~12795)
holds ONLY while `confirmedNight == nil`; the moment the backfilled night is
confirmed (main-sleep auto-confirm covers this), the merge path mints
`freshMorning` from the real night and replaces the unverified fallback. So
the only dependency is the drained sleep reaching auto-confirm — keep
verifying on device, but no code fix is needed unless the night lands and the
38 persists anyway.

**Backfill watch (06:14):** the catch-up drain IS working — an Aug-4 rollup
appeared ~15 min after revival. BUT recovery scored **38** with
`sleepSeconds: None` and `rhr: 68` (vs the usual 54–58) — i.e. scored from
the post-06:00 awake sliver via the no-sleep fallback BEFORE the night
drained. If `FrozenRecoverySummary` freezes that score for the cycle, it
will NOT correct when the night backfills → **premature scoring races the
drain**. Verify on the next pulls: does recovery re-score once
`sleepSeconds` lands for Aug-4? If not, the freeze rule needs a
"provisional until sleep evidence or cycle end" carve-out.

**RESOLVED (06:41 device screenshot):** the night came back end-to-end. The
catch-up drain recovered 11:33 PM–6:20 AM (6h 46m) from strap flash and it
sits as a "Possible sleep · Confirm to add" review card — not auto-confirmed
because the resting baseline is untrusted (~4 of 14 days), which is the
designed honesty gate, not a bug. The premature rollup-38 never surfaced: the
Overview hero held 63% "prev. sleep" via the physiological-cycle authority.
Remaining user action: tap Confirm; recovery then re-mints from the real
night (§ freeze-race answer above). Still open: the overnight
capture-dead root cause below.

**ROOT CAUSE CONFIRMED for the mid-use kills (06:07 + 06:42 jetsams,
`systemCrashLogs` pull): the 3GB balloon is BACK/STILL ALIVE.** JetsamEvent
06:07:10 = Atria `per-process-limit`, 216,066 pages ≈ **3.45 GB**, state
`active`; 06:42:33 = 3.45 GB, state `active, frontmost` (killed under the
user's fingers — the 06:42 screenshot caught the home screen because of it).
Suspended footprint is a healthy ~236 MB, so the balloon is
foreground-triggered, exactly the `atria-3gb-memory-balloon-real-cause`
signature — **but commit `625d7df9` (window/stream all whole-archive loads) IS
in this build**, so an unidentified lane remains. Scene prefs also revise the
overnight story: the app was FOREGROUNDED 00:28:12→00:29:30 (user opened it
before bed), then never ran — plausibly the same balloon → background memory
limit → jetsam, though no overnight JetsamEvent file survived rotation to
prove it.

**Probe finding #1 (06:5x, decisive negative):** with a stack-capturing probe
INSIDE `AtriaHistoricalAggregateReader.load()`, the resident climb
(128→691MB in ~17s post-launch) produced ZERO load() notes — **the balloon
does NOT flow through the aggregate reader at all**, so the entire Aug-2
unbounded-`load()` theory doesn't cover today's lane. Also: two probe runs
peaked ~460–900MB then SETTLED back to ~130–250MB — the fatal 3.4GB climb is
phase-triggered, not launch-constant; prime suspect is a drain-phase
transition (batch seal → terminal publish / crash-resume materialize, where
the lane breadcrumbs sit waiting). Probe left running on-device
(fsync survives the jetsam) — read `Documents/atria-memprobe.log`'s tail
after the next kill; the last breadcrumb before death names the lane.

**Probe finding #2 (07:0x):** another 3.45GB active+frontmost jetsam at
06:53:40 (pid 2376). Probe showed a smooth climb to ~1.5GB then a LAST LINE
of 767MB 1.2s before death — the terminal ~2.7GB materialized in a burst the
utility-QoS sampler couldn't see (starved by the allocator). Probe v3 now
runs: `.userInitiated` sampler + unconditional 1s heartbeats ("beat" lines —
distinguishes steady-state from starvation), plus lane notes at
`sessions_encode` (measured: 29 sessions → 12.6MB, ~200MB transient — real
but NOT the killer), `recovered_sessions_swap`, and
`recovered_snapshot_begin/end` around
`HistoricalArchive.makeRecoveredDataSnapshot(since: −14d)` — the per-ticket
whole-recovered-decode lane that re-runs after each drained batch and is the
prime steady-climb suspect. Read the log tail after the next kill; the
breadcrumbs now bracket every candidate.

**Soak (08:4x):** no kills since 08:11 (~30 min, though the app suspended
itself cleanly at 08:19 at a healthy 74MB footprint, so most of that window
is weak evidence — the balloon needs foreground+active-drain to trigger; the
footprint probe is armed for the next such window). Recovery fallback has
converged 38→53→56→**63** with RHR 55 (baseline-normal); sleep confirm still
pending. Below-fold audit wrap-up: `AtriaTrendExpandedSheet` has ZERO call
sites (dead code, unpinned, likely superseded by `AtriaExpandedChart`) —
flagged as a spin-off review task rather than deleted unilaterally, per the
pinned-dead-code precedent.

**BALLOON — TRUE SYSTEMIC ROOT CAUSE (09:58 kill, 10:0x analysis).** A new
3.45GB frontmost kill at 09:58 falsified the motion-tick verdict as the FULL
story (its fixes stand but were one layer). The footprint probe's complete
record shows EVERY kill today dies inside `rec_scan_progress` —
`makeRecoveredDataSnapshot`'s scan. Mechanism, now airtight:
1. The drain wrote ~1GB of recovered JSONL today (last scan: 955MB scanned
   at death, hr=638K, grav/motionIDs=658K, **rr=250,000 = pinned at cap**).
2. RR at cap ⇒ `limitations` non-empty ⇒ `recoveredDataCache = nil`
   (deliberate, HistoricalArchive ~3527) ⇒ **every subsequent snapshot is a
   full REBUILD scan, never incremental** — the cache can never form again.
3. Footprint ≈ 3.5× bytes scanned (retained `Record`s carry `rawPayloadHex`
   + `candidateRR` strings ≈ 1-2KB/row; 250K rrRecords alone ≈ 300-500MB;
   plus decoder churn) ⇒ the scan now crosses the limit ⇒ progressively
   worse as the archive grows. Explains why fixes "verified" then failed:
   each reduced other pressure while the archive kept growing.
FIX DESIGN (dedicated session; spun off as a task): (a) move the RR
verification (AtriaRecoveredRRProjection ~171-227, needs rawPayloadHex)
INTO the scan and retain compact verified beats, not whole Records; (b)
count budgets in BYTES; (c) retain the cache PER-CHANNEL so one capped
channel doesn't force whole-archive rebuilds forever. Meanwhile the app
remains usable (kills are on foreground-during-drain; the drain finishes
eventually and scans complete).

**REGRESSION VERDICT FINAL (09:5x): all 6 failures PRE-EXISTING at
session-start `5bfc10a8`** — proven by a baseline worktree run (motion-tick
×2 + widget-battery fail identically there; vitals-education density fails
there; journal density's inputs have empty diffs vs HEAD so it is
deterministically unchanged; the sleep probe is the stray untracked file).
**Session net test impact: +12 fixed (all July-22 baseline failures now
pass), 0 broken.** Baseline worktree `/private/tmp/atria-baseline-5bfc10a8`
can be pruned.

**Full-suite regression run (09:3x): 3354 passed / 6 unique failures** —
and the July-22 baseline's 12 failures (9 record-replays etc.) are GONE.
Triage of the 6: `PhysicalSleepProbeTests` = the stray untracked dev probe
(reads a /tmp dump; pre-existing, not shippable); the two
`AtriaCrossScreenDensityTests` are PRE-EXISTING — their pinned anchor
(`struct AtriaVitalsEducationSheet`) does not exist at HEAD **or** at
session-start 5bfc10a8 (verified by direct source evaluation, no build);
the two `AtriaWhoop4MotionTickDailyStoreTests` + the widget-battery test are
deterministic (fail in isolation), touch none of this session's files, and a
baseline run at 5bfc10a8 is in flight to prove pre-existing vs introduced.

**Organic-use confirmation (09:07 screenshot):** app stable through real
morning use — the sleep candidate grew to 9h 26m (11:33PM–8:59AM) as the
drain caught up, "Sleep ended · processing" settlement is active, hero
honestly holds 63% "prev. sleep", live HR 61bpm, battery 79%, zero kills.
The whole reliability arc (capture revival → backfill → candidate →
settlement) now runs unattended.

**Follow-up closed (09:2x):** the rehydration union-window read
(`metricHeartRatePoints(start:end:maximumPoints:)`) needs NO bounding — it
already does catalog-bounds chunk overlap selection, 64-KiB streaming, one
chunk resident, fail-closed on truncation. It is the pattern
`motionTickWindowRead` should have copied from the start. Soak remains
kill-free.

**VERIFIED (09:1x): the foreground kill is FIXED.** Scene-active
reproduction on the layer-1+2 build: `motion_tick_read` COMPLETES in 12.8s
at 508MB footprint (previously: never reached its end note, killed at 3.45GB
in 45–62s, five consecutive builds). Run peak 1595MB (recovered-snapshot
stack transient — headroom ~1.9GB), settled 124MB, alive past 205s, zero new
kills after 08:52. Remaining follow-ups: keep the memprobe through tonight's
organic overnight cycle, then strip it; the recovered-snapshot ~1.5GB
transient has windowing options in the memory file if it ever creeps; the
rehydration union-window read (1.5M-point ceiling) is the other lane worth
bounding preemptively.

**CONVICTED + FIXED (`7ec72868`, 09:0x): the balloon is the confirmed-workout
step-evidence worker's `motionTickWindowRead`.** Probe caught it naming
itself: `motion_tick_read_begin files=18 bytes=463514851` — 463MB scanned,
every row JSON-parsed, for ONE ~1h walking workout window. Root cause of the
non-pruning: the drain replays OLDEST-FIRST, so chunks sealed today hold
weeks-old rows and the `sealedAt < start` exclusion never fires. Fix layer 1 =
chunk `[firstTimestamp,lastTimestamp]`-vs-window range prune (463MB→172MB
observed); layer 2 = byte-scan timestamp ceiling before JSONSerialization in
the scan closure (out-of-window rows now cost a byte scan, not a Foundation
parse). The recovered-data scan stacking its ~1.5GB on top is what crossed
the limit — with the primary climber gone it should fit. **Verdict pending a
scene-active reproduction**: the post-fix run was a background relaunch
(phone likely locked — `devicectl launch` can't foreground a locked phone),
peaks 343MB, healthy. Next pass: reproduce with the phone unlocked, or
observe the user's next organic foreground. Gate: same 4 pre-existing.

**FOOTPRINT TRAP RESULTS (08:5x) — balloon is reproducible on demand and
nearly cornered.** Foregrounding the app during an active drain kills it in
45–62s, every time (`devicectl launch` suffices — no user interaction). The
footprint probe caught the full curve: ~50MB/s climb to 3374MB footprint
while resident stayed ~500MB. Anatomy: (1) an unbracketed climber runs
297→1740MB in the window between `history_snapshots_end` and
`recovered_snapshot_begin`; (2) the recovered-data scan stacks its ~1.5GB on
top → kill. Dispatch-level notes cleared workout-rehydration / compaction /
step-receipt (flags not set); `fg_step_evidence_scheduled` fires just before
the climb → **lead suspect = the confirmed-workout step-evidence publication
worker (motion-bank decode), the one unbracketed lane in the window.** Next
bisect step: note inside `scheduleConfirmedWorkoutStepEvidencePublication`'s
worker, reproduce (3-min loop), convict, fix. Also note: the workout
rehydration lane's `metricHeartRatePoints(union-window, max 1.5M points)`
is a separate whole-archive-scale read to bound once the primary is fixed.

**STATUS CORRECTION (08:2x): fix #2 did NOT hold either** — another 3.45GB
active+frontmost jetsam at 08:11:45, 63s after the rate-limited build
launched, with zero lane notes during the climb. Conclusion: the
symbolicated gravity stack was the CPU-QUOTA offender (real, and its fixes
stand — history_snapshots now completes in ~0.9-16s instead of looping), but
the FOOTPRINT balloon is a different, still-unnamed lane that resident_size
sampling never saw. Probe upgraded (`b280246d`): samples
`task_vm_info.phys_footprint` (the jetsam-enforced metric) with 1s
heartbeats + dual footprint/resident per line. The next kill's tail will
show the true footprint curve and the nearest breadcrumb. Do NOT re-declare
victory until a multi-hour kill-free soak with the footprint probe.

**BALLOON FIX #2 (`5b1e9e4b`, 08:1x) — fingerprint alone was NOT enough.**
A new 3.45GB jetsam at 07:59:39 (active+frontmost, post-fingerprint-fix
build) with ZERO probe lane notes during the climb. Diagnosis: the drain
WRITES gravity files continuously, so the stat fingerprint invalidates on
every sleep-candidate call while draining — the re-decode loop returned
exactly when the app is busiest (which is also why earlier post-fix runs
"settled": the drain had paused). Fix #2: a cache younger than 45s always
hits (≤45s-stale motion evidence is fine for sleep candidacy). Probe now
also brackets `history_snapshots` — post-fix it completes in 0.86s
(369→424MB) where the old loop ran for minutes. **Verdict deliberately
withheld pending a multi-hour soak** — fix #1 also looked clean for 40
minutes. Watch: any new JetsamEvent + whether `history_snapshots_begin/end`
pairs stay sub-second in the probe log.

**Soak update (08:0x):** latest build (incl. timeline empty-state fix)
installed + relaunched on device; still no kills. Below-fold render audit of
`AtriaHistoryDayDetailSheet` (temp drawHierarchy test per the recipe, deleted
after): populated state CLEAN (value/median/delta rows, physiological delta
colors correct); sparse state had "Building median" printed twice per row —
fixed (`65caaae9`), delta slot now stays empty while the median builds. Note
for future audits: ImageRenderer returns BLACK frames for ScrollView-rooted
views — use the UIHostingController+drawHierarchy recipe. Remaining un-audited
below-fold surfaces: AtriaTrendExpandedSheet.

**Soak update (07:55):** still clean (iOS also pruned the old crash reports —
none remain, none new). Recovery fallback continues to normalize on its own
(38→53→56, RHR 68→57); sleep-confirm tap still pending. Activity
day-timeline empty state made visible (`09a1da71`) — was VoiceOver-only,
read as a broken bare axis to sighted users; sim-verified. Static gate still
at the same 4 pre-existing failures.

**Soak update (07:5x):** ~55 min clean. `activity` launch-arg alias added
(`1ec21012`) — the Activity tab is now in the headless screenshot loop;
sim-verified the Heart & stress card: honest no-signal state, live-HR chip
correctly hidden without fresh contact. iPhone Mirroring access was declined
this session, so the chip WITH live bpm remains user-verifiable on device
(open Activity tab while wearing the strap).

**Soak update (07:4x):** still zero post-fix kills. Recovery fallback
improved on its own 38→53 (RHR 68→58) as morning rest accrued — the
"frozen" fallback legitimately re-mints on input change; sleep still
unconfirmed (user tap pending). Launch-time sessions save identified:
`reason=deferred_load_merge`, correctly gated on a real pending persistence
revision (live HR ticks during load) — NOT skippable; the ~200MB transient
is JSONEncoder's ~20× overhead on a 12.6MB payload, a future
streaming-encoder project, not a bug. Today+Vitals sim regressions clean.

**Soak update (07:33):** ~15 min post-fix — zero new jetsams / CPU fatals
(latest remains 07:17–07:18 pre-fix); app steady at ~164MB backgrounded while
the drain continues. Sim regression pass on HEAD: Vitals clean (axis-honesty
fix intact), Settings reviewed clean. Memory file
`atria-3gb-memory-balloon-real-cause` rewritten with the Aug-4 recurrence +
method lessons (phys_footprint, dSYM symbolication beats breadcrumbs).

**ROOT CAUSE FOUND + FIXED (`0cba1e83`, 07:3x):** symbolicating the
`cpu_resource_fatal` reports against the local dSYM named the lane exactly:
`aggregateSleepCandidates → boundedMotionWindowDiagnostics →
loadRecentGravitySamples → loadRecentGravitySamplesUncached →
bytes(fromHex:)`. The gravity cache's validity check demands corpus coverage
within 120s of the candidate window's end — impossible during drain backfill
(drained gravity always lags now), so EVERY sleep-candidate pass re-decoded
the full 8MiB hex/JSON gravity tail; repeated Foundation churn filled the
memory compressor (footprint 3.45GB while resident read ~440MB — why the
probe's resident_size looked innocent) and burned the CPU quota. Five
jetsams 06:07–07:17, all 3.45GB active/frontmost. FIX: stat-level
source-file fingerprint on the cache — unchanged files ⇒ identical decode ⇒
hit regardless of window end. Post-fix soak: peaks 400–650MB, zero jetsams
across repeated foreground runs. TODO next session: strip the TEMPORARY
AtriaMemprobe instrumentation after a longer soak (a day) confirms; consider
phys_footprint (task_vm_info) for any future memory probe — resident_size
hid this balloon.

**Probe finding #3 (07:1x):** pid 2421 died INSIDE
`makeRecoveredDataSnapshot` (begin note at 1196MB, peak 1801MB, no end note)
— the recovered-data recompute is the kill lane, riding on a ~800MB
launch-time baseline that every run rebuilds (launch also fires an immediate
`sessions.json` save: 12.6MB output, ~200MB encode transient — wasteful,
separate fix). Probe v5 now sub-brackets the snapshot internals
(`rec_scan_begin/progress/done` with per-channel counts vs the
1.5M/250K/750K budget caps, `rec_sort_done`) plus
`canonical_rebuild_begin/end` — the next recompute names the exploding
channel (HR points / RR records / gravity / motion identities) directly.

**In progress:** `AtriaMemprobe` reinstated (fsync'd
`Documents/atria-memprobe.log`, 250ms ≥64MB-delta sampler + lane breadcrumbs
at scene transitions, shadow step, crash-resume materialize ×2, terminal
publish ×2) — TEMPORARY, uncommitted; probe Release build installed ~06:55.
Next: foreground until the balloon fires, pull the log, read the bracketing
breadcrumbs, fix THAT lane, remove the probe.

**Open root-cause question:** why no BLE-event relaunch between 00:29 and
05:58 — strap-side link drop with no reconnect attempt reaching the phone, a
bluetoothd wedge (see `atria-locked-reconnect-fix-proven`), or iOS suspending
the process with no pending connection? The six background-continuity fixes
are in this build, so this is either a new hole or the known
parked-terminal-coverage-authority block (`atria-drain-keeping-hardening-plan`
P0, still open). Evidence copies live in the session scratchpad
(`container-pull/`, `container-pull-lib/`).

## 0. TL;DR — the reframe

The user shared 6 mockup boards (Behavior Impact, Strength Log, Sleep Planner &
Smart Wake, Fuel & Cycle, Healthspan/Body Age, Stress Monitor) and asked to:
(1) fix SpO2 if possible, (2) build Behavior Impact, (3) enrich **all** metrics
with richer visual charts, (4) implement what's "missing" in Strength Log.

**Four parallel codebase surveys established that almost every feature in the
mockups already exists as a full, honest implementation.** So this is NOT a
build-from-scratch effort. The actual work is:

- **A. Enrich existing metrics with charts** where a metric currently shows only
  a number (the real bulk — see §4).
- **B. Wire up the partial pieces** (Smart-Wake decision path; a few honest
  detail cases).
- **C. Two genuinely-blocked items**, honestly: **SpO2** (needs empirical
  oximeter data, §5) and **same-night Smart-Wake staging** (no live sleep
  stages on this transport, §3.2).

## 0.1 Interpretation principle (PRODUCT DECISION — read before implementing)

**The mockups are illustrative of functionality and view, not literal specs.**
Every specific label, behavior, metric, and number in the boards is an *example*
of the shape we want — never a fixed requirement. Build the **generic
capability**; the examples only show how it should look and feel.

Concretely:
- **Behavior Impact is not about Magnesium (or Alcohol, or any named behavior).**
  It is about *whatever the user chooses to track in their journal*. Whatever
  behaviors they log, the impact map, drill-in, recovery deltas, and
  significance gating must surface those — generically. (Magnesium was added as
  one more offered behavior, not because the feature is "about" it. The engine
  is already generic over tags; that genericity is the actual product, not any
  single tag.)
- **The same reading applies to every board:** Strain "contributors" and
  "today's activities", Stress "likely stressors", Fuel "auto-journal tags",
  Sleep "need ledger" line items, Behavior rows — the specific entries shown are
  examples. The feature is the generic engine + view that renders *the user's
  own* data, honestly, whatever it happens to be.
- **Numbers are placeholders.** Percentages, effect sizes, p-values, deltas, and
  counts in the mockups are illustrative. Never hard-code them; never fabricate
  to match them. Real values come from the user's real data, and are honestly
  withheld / marked "learning" when the data isn't there.
- **These are product decisions**, recorded here and in memory
  (`atria-product-decisions`): (1) the mockups define *view + behavior*, not
  content; (2) genericity-over-user-tracked-data is the requirement; (3) honesty
  gating always wins over matching a mockup's filled-in look.

## 1. Transport-honesty correction (important, load-bearing)

An earlier claim in this session — "WHOOP 4 has no live broadcast" — is **only
half true and must not propagate into the spec**:

- **Standard BLE heart rate + RR IS live.** `AtriaBLEManager` subscribes to the
  180D/2A37 Heart Rate Measurement characteristic and treats it as a live stream
  with freshness gates (`currentConnectionHasFreshHeartRate`
  `AtriaBLEManager.swift:836`, `staleHeartRatePacketThreshold: 120s` `:1021`,
  `lastAcceptedHRAt` `:20380`). WHOOP 4 broadcasts standard HR+RR live when worn
  and in broadcast mode.
- **The proprietary channel (strain / steps / motion / sleep) is drained from
  flash, oldest-first, with lag** — that's the part with no live path.
- **There is NO live sleep-stage stream and no forward stage projection.** Sleep
  staging is post-hoc only, from drained data.

Consequence for honesty: a **live Stress gauge is legitimate** (fed by live
2A37, gated to ≤90 s freshness). A **same-night Smart-Wake "lightest 30 min"
is not** (needs live/forecast staging we don't have).

## 2. Honesty ledger (what is real vs blocked)

| Feature | State | Data honesty |
|---|---|---|
| Behavior Impact | ~80% built | REAL (journal + `dailyMetricHistory`); strict gating, no sample-data path even in DEBUG |
| Strength Log | Full | REAL (user-entered) |
| Sleep Planner (need/debt/in-bed-by) | Full | REAL (drained ledger) |
| Smart Wake (lightest-minute) | Partial — `decision()` only called in tests | **BLOCKED**: needs live/forecast sleep staging we don't have; code already refuses to fake the hypnogram |
| Stress Monitor | Full | REAL live 2A37 HR/RR; "Live" honestly gated ≤90 s |
| Fuel (nutrition) | Full | REAL (HealthKit read, opt-in) |
| Cycle | Full | REAL (user-logged), labeled estimate, private store, excluded from research sharing |
| Healthspan/Body Age | Full | REAL, conservatively gated (14/28-day) |
| SpO2 | Capture harness live; not decodable | **BLOCKED**: needs oximeter ground truth across ≥3 nights (§5) |

## 3. Per-feature gap analysis (mockup → reality)

### 3.1 Behavior Impact — HARDEN/EXTEND
Already built: `AtriaBehaviorImpact.swift` (Welch two-sample t, `welchTwoSidedPValue`
`:105`; 90-day window; `minimumLoggedDays=5`, `minimumComparisonDays=5`,
`minimumImpact=3.0`, `maximumPValue=0.10`), `AtriaBehaviorImpactPresentation.swift`
(full screen model, drill-in `detail()` `:363` + `shifts()` `:393` computing
HRV/RHR/deep-sleep deltas logged-vs-quiet), distributions (`Distribution` `:115`),
impact map (`AtriaBehaviorImpactMapCard.swift`), diverging bar chart
(`AtriaBehaviorImpactChart.swift:66`). Wired at `AtriaJournalTab.swift:1277`.
- **The feature is generic over whatever the user tracks** (see §0.1) — this is
  the requirement, and it already holds: any `Tag` the user logs flows through
  `AtriaBehaviorImpact` → map/drill-in/deltas automatically. Work here is about
  the *view* and *offering enough behaviors to track*, not any named behavior.
- **Gaps:** the catalog can keep growing (e.g. Magnesium was added
  2026-08-03 as one more opt-in behavior via a `Tag` case + picker plumbing; the
  same pattern adds any future behavior). Deep-sleep deltas only appear with
  `sleepSource == "validated_sleep_stages"` (frequently absent). Two engines
  share the identical statistic but differ on which rows print (3-pt floor vs
  none) — preserve that. **G3 (§9.4): embed the generic behaviors strip in the
  Recovery detail** so the connection is visible where recovery is read.
- **Verdict:** engine is done and generic; work is view surfacing + catalog
  breadth, not per-behavior features.

### 3.2 Sleep Planner & Smart Wake
Built: `AtriaSleepBudget.swift` (need ledger `:19-39`, decayed 7-night debt
`:51-61`), `AtriaSleepPlanner.swift` (`plan` in-bed-by `:85-98`, learned
efficiency), charts `AtriaSleepPlannerCharts.swift`.
- **Smart Wake gap:** `AtriaWakeAlarmPlanner.decision()` (`AtriaWakeAlarm.swift:64-107`)
  exists but is **called only from tests** (`AtriaAnalyticsTests.swift:2340`);
  production schedules a hard AlarmKit alarm at wake-by only
  (`AtriaSmartWakeView.swift:326-350`). It needs live in-sleep staging that does
  not exist (`AtriaSmartWakeView.swift:5-14` states it verbatim;
  `hasActiveSleepEvidence` hard-coded `false` at `AtriaHomeView.swift:9052,9732`).
- **Verdict:** planner/debt visuals are honest and can be enriched. The
  lightest-minute alarm stays **aspirational until a staging source exists** —
  do NOT wire `decision()` to a fabricated hypnogram.

### 3.3 Stress Monitor — BUILT, chart gap
Built: `AtriaStressMonitor.swift` (0–3 scorer, HR z 0.6 + RMSSD HRV z 0.4 vs
`PersonalBaseline` `:156-244`), gauge/timeline/Live chip
`AtriaStressDetailView.swift`, breathwork `AtriaBreathworkSession.swift`.
Honesty guards strong (no number until 14-day baseline; capped Medium HR-only;
suppressed in workout/sleep/no-contact).
- **Gap:** **no saved daily stress history** → no trend chart. Needs a small
  daily-stress persistence layer before a trend can render (§4 item 3).

### 3.4 Fuel & Cycle — BUILT
Fuel: `HealthKitExporter.swift` nutrition read (`:170-176`, opt-in
`atria.health.readNutrition`), model `AtriaNutritionContext.swift`. Cycle:
`AtriaCycleTracking.swift` (phases, confidence tiers, private `atria-cycle-tracking.json`,
excluded from `AtriaResearchBundle`). Both honest. Minor: could enrich with a
per-phase recovery mini-chart (data present at `AtriaCycleTracking.swift:317-335`).

### 3.5 Healthspan / Body Age — BUILT
`AtriaFitnessAge.swift` (5-factor age, pace-of-aging slope), visuals
`AtriaHealthspanDetailView.swift` (radial dials, pace gauge, trend line `:467`).
Conservatively gated. Minor enrichment only.

### 3.6 Strength Log — BUILT ("what's missing" ≈ polish)
Full: `AtriaStrengthLog.swift` (`LoggedSet`, Epley e1RM `:21-29`, PR detection
`:118-133`, rest timer), catalog `AtriaExerciseCatalog.swift`, progress
`AtriaStrengthProgressView.swift` (e1RM line chart), catalog sparklines
`AtriaStrengthCatalogView.swift:290`. Everything in the mockup exists.
- **Candidate micro-gaps to confirm against the mockup:** per-exercise PR badges
  in the catalog row; "Need 3+" learning state; rest-target "HR back to N bpm"
  line (already honestly gated). Treat as a polish pass, not new feature.

## 4. The real work — chart enrichment backlog (prioritized)

Reusable components (do NOT reinvent): `AtriaPreparedMetricChart`
(`AtriaOverviewSections.swift:10506`), `metricChart(...)` builder (`:10140`),
`AtriaGraphGrammar.swift` (line/bar/area/compare grammar), `AtriaMetricRing`/
`AtriaTriRing`, `ContentView.Sparkline` (`:703`). Data: `AtriaPreparedMetricHistory`
(`AtriaOverviewSections.swift:12721`) + `DailyRollupStoreEntry`
(`DailyRollupStore.swift:541`). Style: `AtriaDesignTokens.swift`,
`AtriaSharedChrome.swift` card modifiers, `Metrics.swift` electric color tokens.

**Metrics currently charted:** Recovery, HRV, RHR, Respiratory, Sleep duration,
Strain, Sleep performance, Fitness age, HR zones.

**Metrics with NO chart (the backlog):**

1. **Steps — highest value.** Detail is `AtriaStrapStepsDetailSheet`
   (`AtriaOverviewSections.swift:6007`): ring + number only, and steps is NOT in
   `AtriaMetricDetailKind` or the rollup pipeline (`DailyRollupStoreEntry` has no
   `steps` field). Source data exists (`AtriaWhoop4MotionTickDailyStore.swift`,
   `AtriaDailyStepPresentation.swift`) but isn't exposed as a chartable
   time-series. **Work:** expose a daily-steps `[day:value]` series → add a
   daily/weekly bar chart to the steps detail. (Two parts: data source + view.)
2. **About-X sheets** (`AtriaAboutMetricSheet.swift:218`) — pure text for every
   metric (hrv, stress, recovery, RHR, respiration, sleep, vo2max, skin temp,
   blood O2). **Cheap, broad "enrich all metrics" win:** drop an inline
   `Sparkline`/compact `AtriaPreparedMetricChart` mini-trend into each, fed from
   existing history, honestly hidden when data is sparse.
3. **Stress trend** — needs daily-stress persistence first, then a trend chart
   (§3.3).
4. **Sleep efficiency** (`:9192`), **Skin temperature** (`:9197`) — data exists
   per-night/reading; wire a trend chart into the honest-partial detail cases.
5. **Blood oxygen** — stays honest-partial until §5 unblocks it.
6. **Home/Today hero tiles** — RHR/HRV/Recovery inline sparklines are partial;
   full chart only appears after tap-through. Optional polish.

## 5. SpO2 — the exact unblock path (cannot be code-only)

Confirmed: `AtriaResearchProbe.validatedSpO2DecoderAvailable = false`
(`AtriaResearchProbe.swift:6`). The capture harness is **already live**:
`historicalFixedOffsetCandidates` (`:264-288`) reads u16LE at offsets 64/66
(oxygen hypotheses) and 68 (validated skin-temp) from historical `0x2f` records
v12/24; accumulated per-offset sum+count through the full persistence stack
(`AtriaBLEManager.swift:29299-29338`, `:1907-1915`). Correlation tooling exists
(`tools/replay_sensor_reference.py`, `pair_sensor_references.py`,
`analyze_sensor_research_probe.py`) and an in-app capture UI exists
(Developer → Research validation → Sensor references,
`AtriaSensorReferenceCapture.swift`). Requirements to flip the flag are in
`docs/14-spo2-skin-temperature-decoder-validation.md:117-148`.

**What a human must do (only they can — SpO2 is sleep-only on WHOOP 4):**
1. Wear WHOOP 4 + a timestamped fingertip pulse oximeter overnight, ≥3 separate
   nights, natural variation only (no breath-holding — doc forbids deliberate
   desaturation `:100-102`).
2. Log oximeter readings via Developer mode "Sensor references" with clock
   markers; export the reference CSV.
3. Run the pairing/replay tools to correlate offset-64 vs offset-66 means against
   ground truth; confirm which byte (if either) is SpO2 and isn't a
   counter/timestamp/motion/contact flag.
4. Thresholds to clear: reference spans ≥4 pts; held-out bias ≤1 pt, MAE ≤2 pts,
   p95 abs err ≤4 pts, correlation ≥0.8; ≥99% CRC-clean frames; ≤2 s alignment;
   zero false promotions in off-wrist negative controls.

**What code does then (and only then):** add `decodeSpO2(...)` (modeled on
`decodeSkinTemperatureCelsius` `AtriaResearchProbe.swift:125-158`), gated on the
proven layout, and flip the flag. Anything earlier fabricates a percentage the
app is architected to refuse. **Status: blocked on data; protocol ready.**

## 6. Implementation plan (phases)

Honesty constraints throughout: never fabricate a value; keep every new chart
"honestly hidden / learning" when data is sparse; do NOT ship blind UI — verify
via iPhone Mirroring (see memory `atria-iphone-mirroring-ui-verification`).

- **P1 — About-sheet mini-trends (broad "enrich all metrics").** Add an inline
  sparkline/mini-trend to `AtriaAboutMetricSheet` per metric, fed from
  `AtriaPreparedMetricHistory`, hidden when <N points. Reuses `Sparkline` +
  existing history. Lowest risk, touches every metric. Unit-testable via the
  presentation model.
- **P2 — Steps history chart.** Expose a daily-steps time-series from
  `AtriaWhoop4MotionTickDailyStore`; add a bar/line trend to
  `AtriaStrapStepsDetailSheet` (and consider adding steps to
  `AtriaMetricDetailKind`). Honestly marks days still draining.
- **P3 — Honest-partial trend cases.** Sleep efficiency + Skin temperature trend
  charts (data exists). Stress trend after adding daily-stress persistence.
- **P4 — Behavior Impact polish** (optional): magnesium tag + opt-in; any visual
  deltas vs the mockup.
- **P5 — Strength Log polish** (optional): reconcile catalog row against mockup.
- **Blocked (documented, not built): SpO2 (§5), same-night Smart-Wake staging
  (§3.2).**

## 7. Verification
- Tests scheme: `AtriaTests` (NOT `Atria` — Atria isn't configured for `test`).
  Sim id `44333107-67D1-4E0C-9107-B8F52D7FDF19` (iPhone 17 Pro, OS 27.0).
- Device build/install: `-scheme Atria -configuration Release -destination
  'platform=iOS,id=3803F5B6-1666-56D3-A71A-62F131F6CE3B' -allowProvisioningUpdates`
  then `devicectl device install/launch`.
- New source files auto-included (project uses `PBXFileSystemSynchronizedRootGroup`).
- Visual verification via iPhone Mirroring + computer-use (memory
  `atria-iphone-mirroring-ui-verification`).

## 8. Open decisions for the user
1. Priority/order of P1–P5 (default: P1 → P2 as the highest-value honest wins).
2. SpO2: does the user have / will they get a fingertip pulse oximeter (~$20)?
   Without it, SpO2 stays honestly blank.
3. Smart-Wake: accept it stays a hard wake-by alarm (honest), or descope the
   "lightest 30 min" copy to match reality?

## 9. Detail-screen design references (2026-08-03 addendum)

The user shared two more mockup batches — full metric-detail "whole scroll"
layouts, chart-interaction sheets, and WHOOP reference screenshots — plus an
explicit ask: **"activity and Strain/Recovery should have a chart view like
this"** (the WHOOP "STRAIN & RECOVERY" dual-axis weekly combo). This section
captures the target patterns and maps each to existing components vs gaps.

### 9.1 The canonical "whole scroll" metric-detail template
Every metric detail should read top-to-bottom as this ordered anatomy (Recovery
and Sleep mockups both follow it):
1. **Hero**: big score/value + tint ring (or duration), timestamp/"updated",
   qualitative word (Good), and a baseline chip ("+4% vs your 30-day baseline").
2. **Range picker**: W / M / 3M / 6M / 1Y / All.
3. **Stat row**: LATEST · Δ PRIOR · AVG · RANGE.
4. **Main chart**: line/area with a baseline RuleMark + scrub. (Exists:
   `AtriaPreparedMetricChart` `AtriaOverviewSections.swift:10506`.)
5. **Contributors** ("WHAT MADE TODAY'S SCORE"): per-input bars with a
   typical/above/lower marker — HRV, Resting HR, Respiratory, Sleep performance.
   (Contributor rows exist in `AtriaOverviewSections`/`AtriaHealthspanDetailView`.)
6. **Secondary mini-trend**: e.g. "HRV · 30 days".
7. **Behaviors that move this metric** (compact impact strip) — see G3.
8. **"What this means today"** narrative card (tinted).
9. **Honesty footnote** ("scored against YOUR baseline, N nights in").

Most of this template already exists in `AtriaMetricDetailSheet`
(`AtriaOverviewSections.swift:8595`) for Recovery/HRV/RHR/Respiratory/Sleep/
Strain/Sleep-performance/Fitness-age. The addendum work is (a) assembling the
FULL scroll for each (contributors + secondary trend + behaviors strip +
narrative in one scroll), and (b) the net-new charts below.

### 9.2 Per-metric detail targets
- **Recovery**: ring + baseline chip + stat row + line + contributors (HRV/RHR/
  Respiratory/Sleep-perf) + "HRV · 30 days" + behaviors strip (G3) + narrative.
- **Sleep**: duration hero + "96% of need · Performance 96%" + Night/W/M/3M/1Y +
  **hypnogram** (`AtriaSleepHypnogram.swift` exists) + stage chips (Deep/REM/
  Light/Awake w/ min + %) + **need ledger** (Baseline + debt + strain − nap =
  total; `AtriaSleepBudget.sleepNeedComponents` exists) + Consistency /
  Disturbances tiles + **sleep-debt trend** (`AtriaSleepDebtChartCard` exists) +
  narrative + Sleep planner / Set haptic alarm buttons.
- **Strain**: value hero + "of 21 · target 12–15" + strain bar w/ Target/Coach-
  limit markers + **HR-zone bars** (G5) + a per-workout HR line ("Morning run ·
  HR avg/max") + **Cardiovascular / Muscular split** (G4) + today's activities
  with per-activity strain contributions + "Room to push" coaching.

### 9.3 Chart-interaction sheets (mostly EXIST — reuse `AtriaGraphGrammar.swift`)
- **Range & interval sheet**: WINDOW (W/M/3M/6M/1Y/All) + BUCKET (Day / Week avg
  / Month avg) + "Show min-max band" toggle → maps to `AtriaGraphBucketInterval`
  (`:212`), `AtriaGraphMinMaxEnvelope` (`:234`). Verify the sheet is presented on
  every metric detail.
- **Edit this chart sheet**: PLOT primary + overlays (HRV, Resting HR) + CHART
  TYPE (Line/Bars/Range) + "Mark journal events" toggle → `AtriaEditChartSheet`
  (`:457`), `AtriaGraphChartType` (`:19`), `AtriaGraphCompareMode` (`:54`).
  Confirm overlay/compare + journal-event marks are wired through.
- **Select · drag a window** (Stress·today: drag → SELECTED 1:10–2:40pm, avg/
  peak/HRV, Log a stressor / Start breathwork): `chartXSelection` scrubbing
  exists (`AtriaGraphInspector.swift`, `AtriaTrendChart`); the **drag-to-
  summarize-a-range** (not just a point) may be partial — verify/extend.

### 9.4 NET-NEW chart gaps (prioritized)
- **G1 — Dual-axis Strain & Recovery weekly combo (EXPLICIT user request).**
  WHOOP "STRAIN & RECOVERY": a weekly chart with **strain as a line on a left
  0–21 axis** and **recovery as colored dots on a right 0–100% axis** (green/
  yellow/red by band), one week of days. NOT present today
  (`AtriaTrendPeriodBalanceMap` `AtriaTrendChart.swift:963` is a different
  balance viz). Needs a dual-`chartYScale` combo. Both series already in
  `DailyRollupStoreEntry` (`recovery`, `strain`). **Also apply to Activity.**
- **G2 — Dual-line Hours vs Need (Sleep).** Two overlaid lines/point-series:
  hours slept vs sleep needed, per day (WHOOP "Hours vs Need"). Not present
  (`grep` for hours-vs-need = 0). Data exists (`AtriaSleepBudget` need +
  `SavedDailyMetric.sleepDuration`).
- **G3 — Embedded "behaviors that move your recovery" strip.** A compact
  diverging strip inside the Recovery detail ("Consistent sleep +9%, Read before
  bed +4%, Alcohol −11% · last 60 days"). The engine exists
  (`AtriaBehaviorImpact`/`AtriaBehaviorImpactDivergingChart`) but is NOT embedded
  in the metric detail. This directly connects the Behavior Impact work (P4) into
  the Recovery detail.
- **G4 — Cardiovascular vs Muscular strain split** + today's activities with
  per-activity strain deltas. Only onboarding/insights refs today; not a strain
  detail card.
- **G5 — HR-zone bars in the Strain detail.** Histogram exists
  (`AtriaOverviewSections.swift:9887` `Chart(histogram){BarMark}`) but is not
  surfaced as the "TIME IN HEART-RATE ZONES" card (22m Z1 … 3m Z5 w/ bpm
  ranges) in the strain scroll. Mostly a surfacing job.
- **G6 — Assemble the Sleep detail** from existing parts (hypnogram + stage
  chips + need ledger + debt trend) into the one scroll of 9.2.

### 9.5 Honesty notes for these charts
- **G1 strain line**: strain is drained/lagged (proprietary channel), so the
  current day marks as "still catching up" until drained — do NOT render a
  live-looking today point. Recovery dots colored strictly by band; missing days
  are gaps, never zero.
- **G2**: "need" is an estimate (label it); nights without a recovery/sleep read
  don't plot.
- **G3**: reuse the exact Welch-gated stats — never show an impact row that fails
  the ≥5/≥5 · p<0.10 gate; below gate = "learning".
- **G5 zones**: only from real per-workout HR; no zone bar without HR coverage.

### 9.7 §9.4 status audit (2026-08-04 loop) — ALL of G1–G6 done or covered
- **G1** ✅ combo built + placed (details, not Activity).
- **G2** ✅ COVERED BY DESIGN, not built literally: `sleepDebtTrendCard`
  (AtriaOverviewSections ~9740) is already a 7-night need-vs-slept paired-bars
  chart headlined by the same `sleepBudgetDebtHours` the ledger uses. A second
  dual-line chart of the same two series would duplicate a card in the same
  scroll — per §0.1 the mockup shows the relationship, not a required chart
  type. Decision: keep the bars; do NOT add a redundant line version.
- **G3** ✅ `behaviorsMoveYouCard` is wired in the Recovery detail (:8968) —
  Welch-gated rows + "association, not proof of cause" caption.
- **G4** ✅ `strainActivityMixCard`, **G5** ✅ `strainZoneHistogramCard` — both
  already in the strain detail template (:9133-9135).
- **G6** ✅ sleep detail assembles hypnogram + plan + need ledger + debt trend.
- True remaining chart backlog = §6 P3 (stress persistence → trend;
  sleep-efficiency + skin-temp trend cases) + C5 re-verify at density.

### 9.6 Backlog + phase updates (supersedes §4/§6 ordering)
Add to the charting backlog, and re-order phases to honor the user's explicit
"Strain/Recovery + Activity combo" priority AFTER the chosen Behavior-Impact
start:
- **P4 (in progress, user-selected): Behavior Impact polish** — the goal is the
  GENERIC engine + view working for *any* tracked behavior (§0.1), not a named
  one. Done: catalog breadth (magnesium added as one example). Remaining:
  reconcile diverging-bar/distribution visuals to the mockup shape; **G3** (embed
  the generic behaviors strip in the Recovery detail).
- **P-combo (next, user-requested): G1 dual-axis Strain & Recovery weekly combo**
  for the Strain/Recovery detail AND the Activity view.
- **P-sleep: G6 + G2** — assemble the full Sleep detail scroll + Hours-vs-Need.
- **P-strain: G4 + G5** — cardio/muscular split + HR-zone bars in Strain.
- Then P1 (About-sheet trends), P2 (Steps chart), P3 (Stress/partial trends) from
  §6.
- **Blocked, documented: SpO2 (§5), same-night Smart-Wake staging (§3.2).**
