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

## 12.0 DEFECT (user-caught, 2026-08-04 evening): sleep candidate swallows a
known wake window — duration == span

The "Possible sleep 11:33 PM–8:59 AM · 9h 26m" review card counts the FULL
span as slept (11:33PM→8:59AM is exactly 9h26m — zero wake deducted), yet
the user was demonstrably awake ~05:45–06:15 (messaging, phone unlocked,
builds installing; even the earlier 6h46m candidate ending 6:20 covered
it). I (Claude) quoted the card approvingly twice without noticing —
logged here as a review-vigilance failure too.

Facts: the card renders `night.durationHours`; for this candidate duration
equals span ⇒ the aggregate candidate merged across the wake with no
exclusion. UX OBSERVATION (post-rollover screenshot — CORRECTED for the
below-the-fold trap): after the cycle rollover, the Sleep TILE dropped from
"9h 26m · Review sleep" to "--" and the settlement banner reset to
waiting — the review state no longer feeds the Overview tiles. Whether the
review CARD itself is gone, below the fold, or was user-dismissed is NOT
verifiable from a single non-scrolling screenshot (the earlier claim that
it "left the Overview" was over-concluded). What stands: the tile/banner
no longer surface the unconfirmed night, which is still the
`atria-nap-surfacing-gap` class question for MAIN sleep — WHOOP keeps its
pending-sleep prompt sticky until resolved. Product decision remains open:
should an unresolved previous-night candidate keep a visible Overview
surface (tile and/or card) until resolved? Verify card presence via
iPhone Mirroring or user report before building anything.

FIXED (`b95f8817`, evening): `AtriaRecoveredMotionAnalytics
.sustainedAwakeSeconds` (validated non-low-motion epoch blocks ≥10min;
rollovers never deducted; unvalidated never trusted) deducted from candidate
duration at construction — span intact, downstream gates fail-closed. 5 new
tests incl. an end-to-end regression replaying this night's shape; sleep
net (replays + review + detection accuracy) zero failures; gate at baseline.
Build installed + launched — the pending review card regenerates with net
duration on the next candidate recompute. Follow-up candidate (not built):
SPLITTING a candidate at a long wake block into two sleeps; deduction-only
was chosen for v1 (honest + minimal blast radius).

GROUND TRUTH EXTRACTED (evening pass, chunk
raw-20260804-731d9a45…jsonl, 3,872 rows @1Hz across 05:30–06:30 IST):
movement (mean abs gravity-component delta) in the wake window runs
110–596 mg vs a ≤6 mg sleep-still baseline — 05:40–06:05 sustained
31–584 mg with HR 66–86 (peak 05:45: 419 mg @ HR 85.6), another 596 mg
burst 06:25–06:30; only 06:10–06:20 reads still. The drained archive
therefore CONTAINS unmistakable, gravity-validated wake evidence for the
exact window the candidate counted as sleep ⇒ hypothesis (1) is confirmed
at the data level: the candidate builder never consulted recovered motion
for wake exclusion. Remaining work is the FIX: make the aggregate/recovered
candidate path segment or deduct against recovered-motion stillness (and
never render duration == span across detectable wake), plus a regression
test replaying this night. Original hypotheses kept for the fix session: (1) the wake window's
evidence is HR-only in the candidate (quiet typing ≈ resting HR) and
motion-validated segmentation didn't run against the DRAINED motion for
that window (recovered-motion epochs attach later / HR-only candidates show
no hypnogram by design — but duration must still exclude detected wake);
(2) gap-bridging tolerance merged main sleep + morning re-sleep across a
too-long ambiguous stretch; (3) span-vs-duration conflation in the
aggregate-candidate builder for recovered (vs live) evidence. Ground truth
available: the drained archive holds per-second HR AND wrist motion for
05:40–06:20 — typing should show clear gravity movement.

USER GUIDANCE meanwhile: do NOT confirm as-is — open the card and EDIT the
times (the review sheet supports it): real night ≈ 11:33PM–05:40AM; if you
re-slept ~06:20–08:59, log it separately (nap/second sleep) so the ledger
stays honest.

## 12.1 WHOOP-reference copy check (2026-08-04 loop, per the user's
"when confused, check WHOOP" rule)

Verified against WHOOP's official/support behavior: with sleep
pending/undetected, WHOOP shows Recovery as "--%" and produces NO recovery
at all until sleep exists (users must manually add missed sleeps; Health
Monitor sits on "Pending"). Comparison verdict for Atria's equivalents —
all VALIDATED, no changes needed:
- Atria's ring "--" + "Save sleep to score" matches WHOOP's "--%" pattern
  and is MORE actionable (names the unblocking step).
- Atria's hero holding the previous cycle's score labeled "prev. sleep" is
  richer than WHOOP's blank while staying honest (provenance labeled).
- Atria's auto-detect → review card ("Possible sleep · Confirm") is the
  affordance-rich version of WHOOP's manual-add fallback.
- The internal no-sleep fallback score stays rollup-only ("unverified") and
  never fronts the hero — stricter than WHOOP requires, consistent with the
  honesty-first law.

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
**Multi-hour soak bar MET (~16:00): ~5h kill-free** since the pool fix,
spanning multiple foreground windows, the full-archive scan, backfill
digestion, and one survived CPU-quota diagnostic. Remaining before "fixed"
enters the record: one user-organic session + tonight's overnight. Then the
cleanup pass (strip AtriaMemprobe + notes + bisect lever + relief/recycle
counters; final full suite).

**Late CPU diagnostic triaged (14:2x):** an `Atria.cpu_resource_fatal`
stamped 12:13 (written hours late) is the current-cycle STEP-RECEIPT lane
(`prepareCurrentCycleStrapStepReceipt → motionTickDayEvidenceRead → JSONL
scan`, with `compactArchive` also in-stack) grinding through the day's ~1GB
backfill — CPU-hungry but memory-flat under the pooled scanner, and the
process demonstrably survived it (pid 4362 alive past 12:33). Expected
digestion cost; compaction in the same stack is what shrinks the archive
and retires this cost. No action. Separately: app currently not running
and foreground launch fails → phone locked (benign; BLE relaunch owns
background capture); relaunch when unlocked.

**Kernel-side confirmation (13:5x):** a late-written JetsamEvent (11:57:48,
killed process = an unrelated idle system daemon) doubles as an independent
snapshot of Atria DURING the pool-fix scan: `active, frontmost, 20,041
pages ≈ 320MB, reason None` — kernel-attested flat footprint in the exact
window that previously recorded 3.45GB kills. Atria soak record remains
unblemished.

**Soak + suite update (13:1x):** ~2h kill-free since 11:48; app alive
through pid cycles (benign lifecycle exits, zero JetsamEvents). Suite
health: the two stale CrossScreenDensity failures are resolved
(`f51b041d` — journal pin migrated to heat-strip-era copy; vitals-education
pin retired with a tripwire assert, successor contracts in
AtriaAboutMetricSheetTests) → pre-existing failures now 4 (motion-tick
pair + widget-battery, all pre-dating this session, plus the stray
untracked dev probe file). User awake; sleep Confirm still pending
(fallback recovery 63, RHR 55).

**FINAL CONVICTION (15:1x): JSONDecoder retains live memory per decode —
confirmed clean-room.** decode-only under live-stats (decode+discard, no
append, no verify): live 635→3006MB across the scan with net blocks nearly
flat; count-only on the same build stays at 411MB peak. So plain
`JSONDecoder().decode(Record.self, from: line)` × ~3.6M lines retains ~GBs,
SURVIVING instance recycling ⇒ shared swift-foundation infrastructure —
note the device runs iOS 27.0 BETA (24A5380h); plausibly a beta Foundation
regression. FIX (specified, not yet built): remove JSONDecoder from the
scan hot path — parse scan lines via JSONSerialization + a manual
`Record(jsonObject:)` mapping (the motionTickWindowRead lane already parses
this way and stays memory-flat under the pools); keep Codable everywhere
else; add a GOLDEN PARITY test (JSONDecoder vs jsonObject mapping must
produce identical Records over representative real lines, incl. iso8601
capturedAt and every optional). Also file the beta-Foundation suspicion for
re-test on iOS 27 GA before considering the workaround permanent.

**FIX BUILT (16:0x, this commit) — status: IN VERIFICATION, no verdict
yet.** `HistoricalArchive.Record` gained two failable initializers at the
bottom of HistoricalArchive.swift: `init?(scanLine: Data)`
(JSONSerialization) and `init?(scanObject: [String: Any])` (manual
field-by-field mapping). Semantics deliberately mirror JSONDecoder:
CFBoolean-gated numeric bridging (a JSON `true` can't pass as an Int and
`1` can't pass as a Bool), `Int/UInt32/UInt16(exactly:)` conversions, a
tri-state `scanOptional` so an ABSENT/null optional reads nil but a
PRESENT-but-wrong-type key rejects the whole record (decodeIfPresent +
typeMismatch parity), and `ISO8601DateFormatter` `.withInternetDateTime`
for `capturedAt` (exactly what `.iso8601` uses). The scan closure in
`makeRecoveredDataSnapshot` now calls `Record(scanLine:)`; the JSONDecoder
instance, its recycle counter, and the recycle block are GONE from the hot
path (recycling was proven useless anyway). The bisect lever stays for
verification — `decode-only` now exercises the NEW parser. Codable remains
the parser everywhere else (bounded lanes, diagnostics, replay).
GOLDEN PARITY: `AtriaTests/AtriaRecordScanParserParityTests.swift` — both
parsers must agree on accept/reject AND accepted records must re-encode to
byte-identical canonical JSON (sortedKeys, iso8601) across: fully-populated
row, all-optionals-absent row, hand-written line with explicit nulls +
unknown future key, missing required key, truncated/empty line,
present-optional-with-wrong-type, and a 4-way realistic variation matrix.
Verification protocol before ANY "fixed" claim (per the thrice-learned
rule): parity+wake tests green → static gate at baseline → device install
→ foreground-during-drain reproduction → `rec_scan_done` + full recompute
completion with flat live-stats/vmtags → multi-hour + overnight soak.

**16:1x FALSIFIED ON DEVICE — the JSONSerialization swap did NOT fix it.**
Installed the swap build, launched foreground during drain: pid 5710
ballooned 656→3107MB in 46s and was jetsammed (the "alive at 300s" process
was the background RELAUNCH, pid 5719, which never fronts a scan — process
liveness is NOT a verdict channel; only the probe log is). Then the
decisive bisect: decode-only (parse+discard) with the NEW JSONSerialization
parser leaked identically — live 523→3189MB, blocks near-flat
(589k→593k through a 1.5GB climb), killed ~140s. So the retention was
never JSONDecoder-specific: **on iOS 27.0 beta, BOTH JSONDecoder and
JSONSerialization leak live memory per parse** (they share
swift-foundation's JSON engine there), and the parse temporaries survive
the scanner's per-line AND per-chunk autoreleasepools. Re-reading the
saga: the pre-prefilter motionTickWindowRead balloon (463MB/18 files,
JSONSerialization per row) fits the same law — its "fix" worked by
parsing ~1000× fewer lines, not because that API was safe. Corollary: the
count-only lane is genuinely clean, so Swift-NATIVE allocations drain
fine; only Foundation JSON parses retain.

**16:2x THE REAL FIX (built): zero-Foundation-JSON hand parser.**
`Record(scanLine:)` is now backed by `AtriaScanRecordParser` (private,
HistoricalArchive.swift tail): a byte-level JSON parser specialized to
Record lines — known key→type dispatch, generic skip for unknown keys,
full string-escape handling (\uXXXX + surrogate pairs), exact-integer +
correctly-rounded-double numbers (Int64/Double(String)), hand ISO8601
(civil-days algorithm, Z and ±HH[:]MM offsets, fractional rejected — the
.iso8601 contract), strict accept/reject mirroring JSONDecoder. The
JSONSerialization intermediary (init?(scanObject:)) is deleted. The
golden parity suite now guards the hand parser directly and gained: -0.0
full-parity (the byte parser preserves the sign JSONSerialization lost),
escaped strings incl. an explicit 😀 surrogate-pair line, and a
+05:30 offset date. Same verification protocol owed; no verdict until the
probe shows rec_scan_done with flat live-stats.

**16:3x BYTE PARSER ALSO FALSIFIED in full mode — the parser was NEVER
the retainer.** Installed `5cb41b42` (zero Foundation JSON), launched
foreground: pid 6050 climbed 655→3079MB and died with the IDENTICAL
signature. The breadcrumb trail (read in full this time, not filtered to
rec_scan) shows the climb ONSET is positional: the scan runs FLAT at
~230-300MB through the first ~99.7MB of bytes, then jumps 297→540MB in
200ms at byte ~100MB and climbs ~100:1 vs bytes read while progress
continues normally (~500MB/s vs ~5MB/s read) — i.e., the leak ignites
when the scan reaches a specific REGION/FILE of the archive, on every
build, in every parser. rr-append also stalls at 42594 right at onset
(unexplained — possibly coincident). Evidence matrix now: count-only
clean end-to-end (411MB peak) on all builds; JSONDecoder full + decode
leak; JSONSerialization decode-only leaks; byte-parser FULL leaks;
byte-parser decode-only = NOT YET RUN (the one cell that splits
parse-vs-append). Two-leak hypotheses stay open until that cell fills.
ARMED: the device app is currently running with
`--atria-debug-recovered-scan-mode decode-only` on the byte-parser
build, but the phone LOCKED before it could front (no scene_active — the
foreground-gated recompute never fired; process liveness lied again
earlier, only the probe log is a verdict channel). One unlock+open runs
the discriminant; user pinged by push. If decode-only completes clean it
in-memory-caches empty channels — relaunch the app normally afterwards
to restore real data. NOTE the probe build tag still reads
compact-rr-v1 on FOUR different binaries — distinguish runs by launch
epoch only; bump the tag on the next instrumented build.

**16:4x THE THEORY THAT SURVIVED + STATE AT PHONE-DETACH (evening).**
User unlocked; decode-only on the byte-parser build ran to completion:
climb to ~2.1GB plateau, `rec_scan_done` at 43s, then FULL RELEASE back
to 68-84MB. So nothing is retained — the balloon is TRANSIENT PER-LINE
GARBAGE outrunning page reclaim during the scan, and full mode dies by
stacking append-path garbage on the same plateau. count-only = the
411MB bar (no per-line allocation). Two fix rounds landed on that
theory, each real but so far insufficient on device:
`f7e735cb` in-place parser (no line copy/key/number Strings, span
ISO8601, probe tag → inplace-parser-v1) and `2fe14d72` allocation-
frugal append (byte-wise hex encode/decode fast paths in
bytes(fromHex:)/RR decodeHex/identity payload; sha256+normalizedHex
without String(format:); ONE payload decode per record shared by
gravity+skin) — parity/RR/scanner suites 30/30, all output-identical.
Full mode still died (~500MB/s climb), BUT the flat prefix moved
100MB→512MB of bytes read: ignition tracks REACHING CANDIDATE-DENSE
(post-cutoff) rows, not a file position — the closure only runs on
candidates, so the garbage is per-CANDIDATE (~40KB/row unexplained by
audited allocations; canonical decoder audited lean — provenance rawHex
is computed-only). `AtriaWhoop4HistoricalRecordDecoder.decode` still
runs ×2 per candidate (gravitySample + RR verify) — sharing one decode
is the next planned reduction, but blind fixes are paused pending the
lane verdict. LEVER BUILT (last commit): 3-way append bisect
`append-sans-motion|-rr|-skin` (full append minus exactly one
subsystem). ALL THREE RAN on-device (launch epochs 1785843178 /
1785844232 / 1785844507, then normal relaunch 1785844784) but the
devicectl file service wedged (~20min) before the probe log could be
pulled — VERDICT IS ON THE PHONE, unread. NEXT SESSION FIRST MOVE: plug
phone in, pull Documents/atria-memprobe.log, read the three bisect
windows by epoch; the run whose climb is missing/flattest names the
lane. Also available in the log: the earlier in-place decode-only run
(epoch 1785841510, scene never fronted → rerun if empty) and the
unread sans-motion window. If the file service still wedges, verdict
fallback = systemCrashLogs jetsam timestamps vs the three windows.

**LIVE-RETENTION CONFIRMED + SCANNER EXONERATED (15:0x):** zone stats show
size_in_use tracking footprint 1:1 through the burst (live=3074MB at
3104MB) — the MALLOC_SMALL mass is GENUINELY RETAINED, not freed-dirty
churn. And count-only under the same probe now runs CLEAN end-to-end (full
archive in 17s, peak 411MB, rec_scan_done reached) — the per-chunk pool
fully fixed the scanner layer, and the progress/lease machinery (identical
in count-only) is exonerated. The retainer therefore lives in the per-line
DECODE or APPEND path exclusively; tracked containers audit to only ~80MB,
so ~2.4GB is held by something outside the channel arrays. decode-only
under live-stats is in flight to split decoder vs append. Identity payload
construction audited clean (fresh exact-capacity copy, no slice sharing).

**TAG ATTRIBUTION (14:4x): the balloon is a MALLOC_SMALL burst.** VM-region
user_tag milestones during a reproduction: m_small 552→2904MB in <4s
(~600MB/s) ~20s into the scan (m_large flat at ~145MB — the pooled chunks
are innocent). MALLOC_SMALL = 1-15KB blocks — consistent with the per-line
Data slices (~1-2KB JSONL rows) and decoder temporaries. Next discriminant
in flight: malloc_zone_statistics size_in_use at each milestone — LIVE
growth ⇒ a real retainer to hunt; flat-live ⇒ freed-but-dirty churn ⇒ fix
is allocation-avoidance in the scanner's line path (slice views instead of
per-line Data copies) or scan throttling. Verdict owed next read.

**RE-OPENED (14:1x): kill #9 at 13:55:41 — the pool fix reduced but did
NOT close the balloon.** pid 5158 (wake-fix build, all prior fixes present):
pre-scan phases clean (motion-tick read 46s @≤502MB), then the recovered
scan climbed to 3375MB by 237MB scanned (~155s) → per-process-limit kill,
frontmost. CORRECTIONS to the record: (a) the earlier "reproduction passed"
never observed `rec_scan_done` for pid 4362 — process liveness was NOT
proof the scan completed; (b) decode-only bisect predates the pool fix, so
its decoder-attribution is confounded. RATE RE-ANALYSIS across all runs
fits TIME-based accumulation ~18-50MB/s during scan-era activity better
than per-byte (this run 3GB/166s; count-only +1GB/33s; decode-only
2.8GB/57s; the "flat" observation covered only the first ~13s). Hypothesis
now: a CONCURRENT allocator active while the archive queue is busy (live
drain pipeline? diagnostics accumulators?) — NOT (only) the scan's own
per-line work. Decoder statics ruled out (grep clean). NEXT (decisive, not
another breadcrumb): reproduce under `xctrace record --template
Allocations --attach` (worked at 11:10; export needs the schema-table
form, e.g. --xpath into data/table[@schema] rather than tracks/detail) and
read the allocation call trees. Probe + levers stay armed.

**REPRODUCTION PASSED (12:3x): pid 4362 (pool-fix build, full mode) alive
45+ minutes** — vs 45-124s deaths for every pre-fix run — with ZERO
JetsamEvents in the window (probe file-service flaky, but the crash-log
channel and process liveness agree). Soak clock officially running from
11:48. Threshold for "fixed": multi-hour + one organic foreground session +
tonight's overnight. Cleanup after that: strip AtriaMemprobe + the
--atria-debug-recovered-scan-mode bisect lever + probe notes (list in the
memory file), then re-run the full suite.

**ROOT FOUND (11:2x-11:3x): AUTORELEASED CHUNKS — per-chunk pool fix is
holding.** Decoder-recycle failed identically → re-analysis showed the climb
is ~1:1 with BYTES READ in count-only (978MB read → +1GB) with a ~4x decode
multiplier — pointing at the scanner's read loop: FileHandle.read returns
AUTORELEASED NSData chunks and the loop's thread pool never drains until the
scan ends (the per-LINE pool inside process() cannot release objects
autoreleased outside it); the decoder's bridged temporaries ride the same
pool. Fix: autoreleasepool per 64KB chunk in BOTH read paths
(`pending-hash`). On-device full-mode repro: footprint FLAT ~150MB through
the scan where every prior run was 500+MB and climbing (kills at 3.37GB).
This also explains every failed counter (recycle/pressure-relief can't touch
autoreleased-alive objects). Scan completion + multi-hour soak still owed.

**BISECT COMPLETE (11:2x): the mid-scan climber is JSONDecoder ITSELF.**
decode-only (decode per line, retain nothing) died at 3.37GB after 594MB —
vs count-only surviving all 978MB at 1.5GB. A reused JSONDecoder hoards
~300B/decode across ~9M lines. Counter in test: recycle the decoder every
8192 lines (`pending`); if insufficient, next lever = byte-scan field
extraction replacing full-Record decode. (The diagnostics burst below was
ALSO real — both fixes needed.)

**BISECT VERDICT (11:1x): the killer burst is DIAGNOSTICS LOGGING.**
count-only mode completed the FULL 978MB scan in 33s at 1512MB peak — then
died 5s later in a 1512→3359MB burst with zero notes: the post-recompute
`logSleepValidation`/`aggregateSleepDiagnostics` pass calls
aggregateSleepCandidates(historicalMotionPolicy: **.fullArchive**) whose
loadGravitySamples() built an in-memory [String] of EVERY raw file
simultaneously (~1GB archive → 2-3GB in seconds) — to decorate ATRIADBG log
lines. Also proven by the same run: pressure-relief didn't matter, the scan
itself reaches ~1.5GB for 978MB (survivable), and full-mode deaths mid-scan
were this burst racing the slower decode on other threads. FIXED
(`pending-commit-hash`): diagnostics use .boundedRecent; loadGravitySamples
streams one file per autoreleasepool. Full-mode reproduction in flight —
verdict owed. Bisect lever + probe stay until a clean multi-hour soak.

**TAGGED REPRODUCTION (10:5x): retention fixed, churn remains.** The
build-tagged compact-RR run died identically (3374MB at 101s) but with
arrays PROVABLY tiny (rr=52K accepted ≈8MB) and the pre-scan phase peaking
at just 540MB (motion-tick layers verified). The residual balloon is
~1.4KB/line of freed-but-dirty malloc pages during the scan's per-line
decode churn — pages never returned to the OS. Countermeasure landed
(`malloc_zone_pressure_relief` every ~1MB of input, in the scan's progress
hook): verdict OWED from the next probe read. If relief doesn't hold the
footprint, next lever = replace the per-line full-Record JSONDecoder decode
with targeted byte-scan field extraction (timestamp(in:)-style) so
non-contributing lines never allocate.

**REFACTOR LANDED (`c6df5735`, 10:4x)** per the map below: compact
Accumulator (12/12 projection tests unchanged), snapshot carries verified
beats, cache survives capped channels via truncatedChannels, rebuild
stale-limitations quirk fixed, RR budget 250K→1M accepted (compact).
29/29 RR+scanner tests, replay+archive-warm net clean, gate at baseline.
The compact-RR build is INSTALLED on device (launched ~10:40) but the
device file service dropped before the reproduction probe could be read —
**on-device verdict OWED: pull Documents/atria-memprobe.log, check the
rec_scan runs' footprint peak (expect far below 3.4GB) and NO new
JetsamEvents, then a multi-hour soak before any verdict.**

IMPLEMENTATION MAP (10:2x pass — everything read, refactor NOT landed to
avoid another under-tested loop-pass fix):
- `AtriaRecoveredRRProjection.project(records:)` (~94-148) = per-record
  `verify()` (~170-234, needs rawPayloadHex for payload re-decode +
  cross-checks) + cross-record dedup via `acceptedByRecordID[stableRecordID]`
  with clock-provenance preference (~106-125). Extract this loop into a
  streaming `Accumulator` (compact per-record storage: recordID String once,
  clockRank, correctedUnix/subsec11/counter, intervals [Int]; materialize
  `Beat`s only in `finish()` — beats' id strings are the fat part).
  `project(records:)` becomes ingest-loop + finish → tests untouched.
- `HistoricalArchive.appendRecoveredRecord` (~3563): RR branch (~3624)
  currently appends the WHOLE Record (rawPayloadHex + candidateRR + 3 int
  arrays ≈ 0.8-1.2KB each; 250K ≈ 300MB). Replace `rrRecords: inout [Record]`
  with the accumulator; budget counts accepted records
  (`RecoveredProjectionBudget.maximumRRRecords` 250K can then rise ~4× at
  equal bytes).
- Cache: `RecoveredDataCache` (~4900) + `prunedRecoveredCache` (~3677, prune
  accumulator by correctedUnix ≥ cutoff) + reuse limitations (~3446) +
  retention decisions (~3525-3533). ADD `truncatedChannels: Set<Channel>` so
  a capped channel keeps reporting budgetExceeded after prune instead of the
  cache being discarded (the current `recoveredDataCache = nil` on
  limitations is the rebuild-forever amplifier). NOTE: cache is a process-
  lifetime STATIC — retention alone cannot stop first-scan-after-launch
  kills; the compact accumulation is what shrinks the scan itself.
- Also compact: `AtriaRecoveredMotionReplayIdentity.payload = .bytes(Data)`
  (full raw payload per identity; 658K ≈ 130MB) — a SHA-256 digest preserves
  identity semantics at 32B.
- Pre-existing quirk found while mapping (fix or document): on plan=.rebuild
  (~3480-3486) the arrays are cleared but `limitations` (~3465) was seeded
  from the PRE-clear reused counts — a full cache forced into rebuild starts
  with stale budgetExceeded flags that block appends.
- Consumer swap: Sessions ~9301 `AtriaRecoveredRRProjection.project(records:
  snapshot.rrRecords)` → snapshot carries the projection/accumulator.
- Sizing at last kill: rr 250K Records ≈300MB + motion IDs ≈130MB + hr/grav
  ≈45MB retained; remainder of the 3.3GB ≈ malloc-dirty churn from full-
  Record JSONDecoder decodes over 955MB of lines (per-line autoreleasepool
  exists; native-heap dirty pages still accumulate in footprint).

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

## 12.2 WHOOP-alignment slate (2026-08-04 evening, 8-agent review → 8 shipped)

An 8-agent per-screen review of fresh `north-star-highlights` fixture
screenshots (7 reviewers + adversarial synthesis; ~711k tokens) produced a
ranked slate; all 8 items + 2 inline finds shipped, sim-verified
before/after, static gate back at its 4-failure baseline (one pin
migrated), affected suites 20/20:

1. Plan pill honesty: `planTargetText` guarded — "Target 10.2 · strain
   pending" while the strain hero is pending (was "10.2 to go" asserting a
   measured 0.0 beside a "--" chip).
2. Day-timeline axis truth: both `AxisValueLabel(centered: true)` →
   uncentered (labels sat ~3.5h right of their gridlines; "Now" clipped).
3. "READINESS" kicker → "RECOVERY" (AtriaHealthScreen:1054) — WHOOP's own
   pillar name over exactly WHOOP's recovery cluster.
4. "Heart & stress" card → "Stress Monitor" — visible title now matches
   its own a11y label and WHOOP's feature name.
5. "Learning · N of 14 days" → "Resting HR learning · …" (Insights:280) —
   the only subject-less rotating notice; test pins migrated.
6. `.noContact` badge tint `.red` → `.secondary` app-wide (routine absence
   is not an alarm; colour-is-earned).
7. Activity fully-empty day: bare-axis strip gated out — one consolidated
   empty card instead of three stacked negatives; strip still shows while
   loading or with any data.
8. Sleep banner "Still waiting for enough strap data" → "Last night · not
   enough strap data yet" (Subject · state pattern; pin migrated).
Inline finds: unzoned Resting tint `.blue`→`.secondary` (fixture's
"Resting 119" rendered as a live-blue verdict; gate pin migrated) and
unzoned Sleep-RHR tile `.red`→`.secondary`.

Deferred next-slate headliner (synthesis): Journal Yes/No answer
neutrality; then RHR-acronym row copy, "104% of need", Health Monitor
single-carrier status, strap/settings deep-detail passes. The synthesis
also flagged the '119' PROVENANCE question (presentation RHR falls back
to a saved-wear session's restingStable with no source label) as a
derivation-adjacent item needing a product decision — not shipped.

Balloon status unchanged this pass: 3-way append bisect results remain
UNREAD on the phone (locked, file-service error 4016); read
Documents/atria-memprobe.log on next unlock (§16:4x).

## 12.3 Balloon endgame status (2026-08-04 late evening)

**THE SCAN IS FIXED — architecturally.** Thread-per-pass budgeted scanning
(`4c14af2b`, 32MB/pass, fresh dying Thread per pass, adaptive unwind wait):
full production scan of the 1.007GB archive completes in ~15s across 30
passes with footprint ≤850MB (previously dead by the halfway mark on every
build). Root law, twice-proven: on this iOS 27.0 beta the allocator
returns a worker's transient garbage only at THREAD TEARDOWN — not at
autoreleasepool drains, not via malloc_zone_pressure_relief, not on naps.
Per-pass thread death is the reclaim lever.

**Stage-by-stage exoneration** (probe brackets, three naming runs): scan →
snapshot build → proj_hr → proj_sessions → proj_motion → fields → skin →
sessions_swap → canonical → motion-provenance → stage-backfill → HRV
requalify → baseline: ALL clean, whole recompute ≤1.2GB. sleep_candidates
and deferred_details also bracketed and exonerated.

**REMAINING KILLER (one lane left): the post-publish DERIVED fan-out.**
The climb (859→3143MB at ~450MB/s, same garbage signature) starts 0.4-11s
after post_swap_done, carries no notes, and dies in ~6s. Effects
dispatcher: projectionCompleted → .startDerived →
runRecoveredArchiveStatusStep → chain of ~8 derived consumers — which
includes the Aug-2 memory's KNOWN remaining unbounded whole-archive sites
(readVerifiedConsumerSources → 2 whole loads per source, reader.readSource,
shadow step). Instrumented `recompute_stage phase=/component=` note in
armRecoveredDataRecomputeTimeout (fires per derived component) — the
naming run is INSTALLED and has run on-device, but the file service
wedged before the log could be pulled. NEXT: pull
Documents/atria-memprobe.log (launch epoch 1785855194), read which
component note precedes the climb, then apply the same medicine to that
consumer (windowed load or thread-per-slice). Note the probe log is
~30MB+ now — consider trimming after pull.

## 12.4 Balloon: state at session end (2026-08-04 night)

Installed build (`HEAD`): thread-per-pass scan (32MB budget) + fresh dying
thread per recompute + 30s-throttled probe beats. VERIFIED on device: the
scan completes (~15s, ≤850MB), a full single recompute cycle completes
(scan → projection → swap → post-swap, peak ~1.2-2GB), per-cycle reclaim
works (footprint dips to ~880MB after a cycle ends), and data COMMITS
(post_swap_done reached repeatedly) — the app is functionally recovering
data now even when a later kill occurs.

REMAINING (two named, mechanical items):
1. **Recompute storm**: drain chunk-writes re-trigger projection tickets
   back-to-back (7 in 60s observed). Cycles pace ~20s each; consecutive
   cycles creep the baseline (1254 → 2062MB across two cycles). Needs a
   TRIGGER-side coalesce (min-interval debounce while drain is active) in
   the recompute coordinator — design carefully against its timeout
   machinery; do NOT delay inside .startProjection (eats the projection
   timeout).
2. **Derived-phase garbage**: after post_swap_done the derived chain runs
   (components now named in probe: archiveStatusAndCycleHeartRate →
   confirmedWorkouts → …; shadow step = Task.detached on the LONG-LIVED
   cooperative pool — same thread-teardown law violation). Give the heavy
   derived bodies (refreshHistoricalArchiveStatus, shadow step's
   readVerifiedConsumerSources, confirmedWorkouts step-evidence) the same
   fresh-dying-thread treatment. Death tonight = storm creep (2062MB
   baseline) + derived garbage (~1GB) crossing 3.4GB.

Verification protocol unchanged: after both fixes, require repeated
foreground cycles with peak <1.5GB + an organic overnight, THEN strip all
TEMPORARY instrumentation (AtriaMemprobe + note sites + bisect levers +
recompute_stage note + append-skip levers) and run the full suite.

## 13. Accuracy-first completion sweep (2026-08-04 late night, user directive)

User directive: close background tasks, complete everything open, and make
"every single metric as accurate and reliable as possible, shown as soon
as it can be shown." Executed:

**Reliability (the Recovery-persistence fix):** inter-cycle recompute REST
(12s, coordinator state machine + scheduleTrailingStart effect, clock-
injected, 13/13 suite) so drain-triggered cycles never run back-to-back;
`AtriaTransientWorkThread` (dying-thread lifetime boundary) applied to the
shadow-step sweep + archive-status walk. Installed with the whole sweep
for the overnight soak. Process stable across checks post-install. NOTE:
the probe log now exceeds the ~40MB devicectl transfer cap — the soak
verdict needs the log ROTATED at next instrumented build (or read crash
logs instead); pulls truncate at exactly 40,000,000 bytes.

**Decisions implemented:** RHR = sleep-cycle authorities only (the '119'
class of unlabeled daytime estimates cannot render); sticky unresolved
sleep/nap prompt through rollover (48h cap, superseded by newer confirmed
evidence); Smart-Wake copy descoped to the hard-alarm reality; naps
audited — confirmed naps ALREADY flow into Activity sections and newer
nap candidates ALREADY win the review slot (Aug-1 memory partially
stale); the surviving gap was the rollover age-cap, now fixed by the
sticky prompt.

**P3 complete:** sleep-efficiency 30-day mini-trend (confirmed nights,
≥5 qualified, HR-only nights fail closed); skin-temp About-trend verified
already live; stress daily trend shipped earlier today.
**P4/P5 audited complete:** magnesium tag present + tested; strength-log
learning states, need-more countdown, PR badges all exist.
**UI backlog batch:** journal Yes/No answer-neutrality, "% of need",
"Resting HR" spelled out, Health Monitor single-carrier status, "Strap
control · Only Atria connects". Pins migrated (Ownership, notice titles,
RHR chain test); gate at 4-failure baseline; vitals+journal
screenshot-verified ("Resting --" honest, equal-weight buttons).

**Still open after this sweep (honest tail):** SpO2 (hardware validation
— user's oximeter call), steps drain-latency policy (P0 decouple raw
drain remains the big engineering item), settings profile-header polish
(needs visual sign-off), instrumentation strip + full suite AFTER a clean
overnight, C5 chart re-verify at real data density, iOS 27 GA re-test.

## 13.1 Balloon frontier log (2026-08-04 night, loop pass)

Fix chain verified on-device this pass (each layer HOLDS):
- 12→20s inter-cycle rest works (observed exact-gap trailing starts).
- Fresh-thread-per-recompute + PER-STAGE dying threads inside the
  recompute (snapshot / HR projection / sessions+motion+skin): both
  cycles of a drain-triggered pair now complete at ~1.1GB peak
  (previously: cycle 2 died at 3.3GB in the serial materialization).
- history_snapshots full rebuild staged per-substage: passes at ~1GB.
- Probe log rotation at 8MB (40MB devicectl truncation trap solved);
  hero_snapshot + dash_diag bracketed and exonerated.
DEATH FRONTIER now at +180s: after archiveStatusAndCycleHeartRate and
confirmedWorkouts complete (~1GB), an unnamed lane between +132s and
+180s climbs to 3.3GB. Remaining derived components not yet reached in
notes: sleepSettlement, historySleepAndDailyRollups' TAIL consumers,
overviewTrends, trainingLoad, todayHeartRateZones, behaviorInsights —
next pass brackets each derived component's runner (the recompute_stage
note only marks the timeout arm, not stage completion) and applies the
dying-thread stage pattern to whichever names itself. Settings + plan
surfaces audited clean this pass (Developer row properly gated).

## 13.2 Loop pass (late night): tail-derived serialization shipped, awaiting organic verdict

The +132→+180s killer was structural: the four tail derived refreshes
(overviewTrends / trainingLoad / todayHeartRateZones / behaviorInsights)
launched IN PARALLEL after history snapshots — four stacked transient
bursts. They now run as a completion chain with per-step probe notes
(`derived_step <name>` … `derived_steps_done`); coordinator semantics
per component unchanged. Shipped to device with the stress-card
unblock-condition line (existing model copy). Phone locked before a
foreground cycle could run — the serialized chain verdict arrives at the
next unlock's cycle; meanwhile 5+ min of locked-background operation
showed zero deaths at ≤311MB. Note for readers: pulls now read the
ROTATED current log — the previous generation is atria-memprobe.1.log.
Read protocol next session: pull log, find newest `rec_scan_begin`,
follow through derived_step notes; if `derived_steps_done` appears with
peak <1.5GB, the balloon is DEAD and the instrumentation strip + full
suite is unlocked.

## 13.3 Live-defect pass (2026-08-05 early AM, user: "some things are showing up really off")

Live device screenshot analysis (devicectl capture screenshot works —
new verification channel; Mirroring stays denied). Found + shipped:
gated Today-deck drag behind edit mode (stuck floating tile preview over
the deck was the "off" floater; drag pins migrated ×2), RHR empty-state
copy "after tonight's sleep", workouts glance zero-strain suppression +
week-scope honesty, detections closure type annotation. ALSO seen live
and GOOD: "Capturing live" banner with strap connected at 48%, honest
"Strap steps · Partial archive · 15% covered · 357", VO2max "Improving ·
day 11 of 14" — the honest-display machinery is working with real data.
Balloon frontier: cycle 1 fully clean (post_swap 1339MB); remaining
collision = full history rebuild starting while the trailing recompute
runs (+55.6s death) — per-session replay dying-thread wraps shipped in
this build may tame the rebuild half; if the next unlock's log still
shows a death there, add the heavy-pipeline mutual-exclusion gate
(shared semaphore around makeRecoveredDataSnapshot and full
makeHistorySnapshots — they never nest). A post-relaunch full rebuild
DID complete bounded (detections 100s at ≤400MB) proving the wraps work
in isolation.

## 13.4 Loop pass (2026-08-05 ~00:30): steady-state health observed

Balloon: the healthiest window of the saga — ONE pid across 12+ min
including a foreground launch, peak 358MB, cache reuse doing its job
(history rebuild incremental in 0.2s). Not yet the stress verdict (needs
a drain-heavy rebuild + trailing recompute under the new per-session
wraps) — organic soak continues.

Live-verified on device (real data): recovery 53-54% Fair with new
"-27% vs yesterday" context; sleep SAVED (5h24m of 10h need, honest
red); strain accruing live (2.3→4.4) with plan pill arithmetic exact
(13.7−4.4 → "9.4 to go"); "Capturing live" with strap at 47%; no stuck
drag floater after the edit-mode gate. Shipped this pass: bottom
contentMargins(72) on the dashboard scroll — the tabViewBottomAccessory
(Live pill) height is not added to the scroll safe area on this beta, so
the last card was permanently clipped behind bottom chrome.

Watch item (not acted on): strain climbed 2.1 in ~10 quiet minutes at
83-87bpm — plausible TRIMP at elevated-resting HR, but worth a sanity
pass against the zone floor if the user reports inflated daily strain.

## 13.5 Loop pass: strain watch-item AUDITED CLOSED; soak still perfect

Soak since the margin build: ONE pid across 35+ min, peak 333MB,
incremental history stages instant. Zero deaths since the per-session
replay wraps + serialized tail landed (three consecutive healthy
windows now).

Strain climb (2.3→4.4 in ~10 quiet min) audited: every strain lane —
saved, saved-active, AND the hero's live component
(liveSessionDailyLoadTRIMP) — routes through dailyLoadTRIMP's
50%-of-max floor (95bpm at maxHR 190), so sub-floor wear cannot accrue.
The observed climb is legitimate: drain catch-up retro-computing the
day's recovered TRIMP (honest backfill) and/or real above-floor moments
between captures. WATCH ITEM CLOSED, no code change.

Remaining campaign checklist (unchanged): clean drain-heavy stress
cycle in the soak log → strip ALL temp instrumentation (AtriaMemprobe +
note sites + bisect/append levers + recompute_stage note) → full suite
→ then the deferred product tail (steps drain P0, SpO2 hardware,
settings profile polish, C5 density re-verify, iOS 27 GA re-test).

## 14. WHOOP-parity push (2026-08-05 user directive + research)

**Shipped this pass:**
1. **In-activity Heart rate / Stress picker** (user screenshot parity):
   the workout detail sheet's trace card gained a segmented picker; Stress
   mode renders `AtriaWorkoutStressTraceChart` — 0–3 axis, low/high
   annotations, height-mapped blue→green→amber line, gap-split segments,
   honest empty state when the bounded stress history no longer covers the
   window. Wired from the Activity tab with a window-sliced
   `stressMonitorStore.history`.
2. **Activity catalog 29 → 77 types** (add-only; raw values persisted):
   the meaningful breadth of WHOOP's 115-activity list incl. sports,
   water/winter, combat, recovery (Sauna, Ice bath, Massage, Meditation,
   Breathwork) and daily-life types; icons per case; `Category` axis
   (9 groups); the add-workout revealed catalog now renders sectioned by
   category (search stays flat); resolver keywords extended (~30 new).

**Research inventory distilled → prioritized parity backlog** (full agent
report in session log; feature-by-feature vs Atria):
- ALREADY AT PARITY: physiological sleep-to-sleep cycles (WHOOP Cycles),
  optimal-strain-style target from recovery, sleep need/debt dynamics,
  auto sleep/nap detection + manual add, behavior journal with impact
  correlation, steps with honest latency, VO2 estimating window.
- QUICK WINS (next passes): strain BAND NAMES on the hero/detail (WHOOP:
  Light 0–9 · Moderate 10–13 · High 14–17 · All Out 18–21); "Restorative
  sleep (REM+Deep)" rollup metric on sleep detail; sleep-metric threshold
  copy alignment (performance ≥85 optimal / 70–85 sufficient / <70 poor,
  efficiency ≥90 optimal); recovery band thresholds cross-check
  (WHOOP green ≥67 / yellow 34–66 / red ≤33 vs Atria's current bands).
- MEDIUM: stress week-trend breakout (Total Day / Sleep / Non-Activity);
  Health-Monitor deviation colors (green/orange/red vs rolling baseline —
  Atria zones partially do this); step goals in the plan.
- PRODUCT DECISIONS: guided breathwork sessions (stress monitor
  companion); exportable 30/180-day health REPORT (Atria has raw export
  only); WHOOP-Age-style long-horizon score (needs months of data).

## 14.1 Balloon endgame status (2026-08-05 ~02:00)

CLOSED this pass: all three rehydration raw-scan entries (trailing ×2,
foreground replay) + the projection-first stand-down rule — verified: no
rehydration_raw note in the final cycle. WHOOP-parity features shipped
(picker chart, 77-type catalog, band names, Restorative sleep row).

REMAINING (one precise signature): cold launch → first recompute
completes and COMMITS (post_swap ~+46s, ~1.3GB) → un-noted ~2GB burst in
the next ~9s → one jetsam → relaunch → indefinitely stable (~300MB,
verified across 3 consecutive builds; 7+ clean minutes each). User
impact: a single silent restart shortly after a cold open; no data loss
(the swap commits first). NEXT BRACKET TARGET: the post-publish window's
un-instrumented consumers — prime suspect the widget-projection/publish
encode (WidgetSnapshot walks the recovered channels and carries NO probe
notes); second suspect the startDerived dispatch path before its first
component note. One note-instrumented cycle names it; then the same
dying-thread/stage medicine closes the campaign, followed by the
instrumentation strip + full suite.

## 14.2 User-feedback pass (2026-08-05 ~02:30)

Shipped: review-prompt context line ("Since ≈6:12 PM · 23 min elevated ·
looks like walking" — approximate start derived from the contiguous
elevated count, honestly marked "≈") and a calmer prompt trigger (READY
bar 90s@+25 → 5min@+30bpm; detection/candidates untouched — only the
interruptive prompt). Naming cycle: widget publishes measured INSTANT in
the healthy process (suspect weakened); the cold-launch death window's
first-process tail still needs a read on the next pass.

**STEPS COVERAGE — the user's "why the hell" (P0 escalation).** The 18%
is honest arithmetic: strap flash replays oldest-first at ~1× realtime
with no seek (proven dead on WHOOP4), and background catch-up was
additionally blocked by the parked terminal coverage authority + weeks
of foreground jetsams killing every drain. The balloon work removes the
biggest blocker (drains now survive); coverage should trend up
organically starting tonight. THE REMAINING ENGINEERING (next session's
P0, from the drain-keeping plan): decouple the RAW drain from the
parked coverage authority so background catch-up runs without waiting
for foreground; then chain+slice (P1) and charge-resume. Target the
user set: ≥95% coverage tracking near-real-time during normal wear.
WHOOP's own benchmark: step data refreshes ~every 10 minutes.

## 14.3 P0 drain decoupling SHIPPED (2026-08-05 ~03:00, user directive)

`strapBacklogPendingForCatchUp()` (range-loss flag OR fresh flush debt >
caught-up floor) now drives: the connected catch-up gate, the background
flush window, the HR-independent re-arm ticker (also armed on every
fresh 0x22 debt observation), the charge-resume edge, and the
parked-terminal-authority raw pass-through. All downstream guards
unchanged. Every prior pass of this machinery was proven under the
range-loss ticket; this broadens only the trigger. VERIFY over the next
day: steps card coverage % should climb toward ≥95% and stay
near-real-time during normal wear; watch flush-debt level transitions
in defaults (flushDebtLevel) and offline_sync status lines. User was
told foregrounding the app accelerates catch-up NOW (true: foreground
unparks materialization + drains survive foreground post-balloon).
Review-prompt UX + calmer trigger also live on device.

## 14.4 P0 first verification (2026-08-05 ~02:10, state pull)

STRAP SIDE: healthy and nearly caught up — flushDebtPendingRecords=161
(~3 min of data, level=low, fresh observation), handshake
full_drain_write_confirmed, lastDrainAttemptYieldedRows=true, durable
flush boundary confirmed seconds before the pull. The drain machinery is
actively landing rows.

PHONE SIDE: the coverage % lag is NOT strap lag — the authority sits at
gapResolvedConsumersPending with materializing=1 (consumer
materialization in flight; this chain only started SURVIVING today).
The scary-looking terminalConsumerDependencyMismatch/terminal archive
failure keys in the pull are STALE v1-era values (code moved to .v2,
which is clear) — do not chase them. Expectation: coverage % climbs as
the surviving recompute+derived chain commits consumer receipts;
verify at next foreground with the steps card. User's phone is
backgrounded overnight = exactly the P2 flush window P0 now unlocks —
the overnight log is the real P0 verdict.

## 14.5 Sync-nudge + cluster fix shipped (2026-08-05 ~02:45)

User directive implemented: sync-nudge local notifications (pure
decision, 6/6 tests — foreground-helps / strap-away / Low Power
variants; silent when progressing, active, night, shallow, or
stale-but-connected; 6h cooldown; wired from the flush-debt observer +
maintenance ticker). ALSO shipped: per-cluster dying threads in
aggregateWorkoutCandidates — the definitively-named cold-launch burst
(all-day recovered clusters copying+sorting a day of points ×3 replay
modes, ~14 clusters summed on one thread inside hist_stage=detections).
Cold-launch verdict for the cluster fix: NEXT cold launch (this build's
launch included it — read start-pid count across the +60s cliff, both
log generations). If clean → the balloon campaign closes → strip ALL
instrumentation → full suite.

## 14.6 Ops changes + frontier (2026-08-05 ~03:20)

USER DIRECTIVES APPLIED: loop cadence 5min→2min (session cron);
parallel-work pattern adopted — subagents run audits/research while
device builds and soaks run in background. Nudge retuned per user
decision: NO time-of-day gate + threshold = 30 minutes of missed
records (was level=high + 9-21h window); tests updated 6/6.

FRONTIER: the 6h aggregation bound shipped but the trailing cycle's
detections stage STILL bursts (1156→3122MB at +55-59s, death +61).
So the burst survives: per-session readiness wraps, aggregate-pass
wraps, per-cluster wraps, AND the all-day exclusion. Remaining
suspects inside the detections tree: windowedWorkoutCandidates
(per-window point copies?), stitchedObservedWorkoutPoints, or a
whole-points copy in the summaries path. A parallel audit agent is
mapping every O(points) allocation site in the tree; its ranked list
names the next surgical fix. Cold-launch UX impact unchanged: one
silent restart ~60s after cold open, data intact, then stable.

## 15. Allocation batch shipped + UI campaign round 1 (2026-08-05)

ALLOCATION AUDIT FIXES COMMITTED (e665dcfd): #1 workoutReadiness
copy-elimination (bpms materialized+sorted ONCE per call; percentiles
take presorted); #2 windowedWorkoutCandidates 6h cluster-span ceiling
(chained clusters produced up to 3168 window copies); #3 per-candidate
dying thread around workoutReviewCandidate(fromQualifiedWindow:)
(whole-corpus rescan garbage reclaimed at teardown). Test migrations
for the raised prompt bars: rest+35 rename, stays-quiet rest+27 pin
(the user's too-eager complaint, now a permanent test), RR gap-bridge
test rebuilt — continuous and sustained floors are EQUAL now (5min),
so the old premise (bout clears continuous but not sustained) is
impossible; new form uses sub-bar 200s bouts whose in-window SUM
clears the floor, third bout ending AT now (maximumSampleAge=5s trap:
a tail bout ending 40s ago returns emptyResult). 210/210 green.
Static pin migrated: feat5 fixture names. VERDICT PENDING: cold launch
on device — if the +60s restart is gone, the balloon campaign closes.

UI ROUND 1 COMMITTED (9b3f3618) from three subagent audits:
- WIDTH (audit ranked 17 live sites): Health Trends double-box deleted;
  8-site metric-detail chart full-bleed + trailing axis + no rotated
  unit label (~72%→~84% plot width); sheet gutters 18→12; breakouts on
  week-recovery, combo, steps-week, stress timeline/by-day, about-sheet
  sparkline, Vitals HR timeline, workout traces, hypnogram lanes.
  NOT DONE: Sessions.swift historySection (:34921) padding 18→14 and
  the :34759 sheet gutter — do with next Sessions.swift touch.
- MANUAL-SLEEP HONESTY: Night.isManualEntry; .manualEstimate folded
  into the HR-only motion gate; backfill skips manual_* (stages were
  stripped at next migration anyway — appear-then-vanish fixed); all
  six surfaces now say "manual entry — no stages" instead of promising
  "building/calibrating". Pins migrated (sheet copy + building summary
  ternary→headline/detail). Deliberately REJECTED: duration-derived
  stage templates (= estimatedConfirmedSleepStages, guarded against).
- STRESS TRANSPARENCY (live user report mid-loop): calibrating detail
  now carries the real progress "Baseline n of 14 rest days"; narrative
  says live HR streams NOW and scoring activates at 14 qualified rest
  days (~2 weeks). Card was showing detail without the label's (n/14).
  AtriaStressMonitorTests migrated (13-of-14 fixture), 18/18.

WHOOP DESIGN SPEC (subagent, saved refs in scratchpad/whoop/): dark
near-black blue bg, 2 elevations, semantic-only accents (recovery
green/yellow/red, strain #0093E7, sleep slate #7BA1BB), two-font rule
(prose + DIN-like numerals), ALL-CAPS letterspaced micro-labels,
3-dial home, day-scoped ‹TODAY› capsule stepper, metric detail =
full-page push (hero ring → notched stat card → coach block), stat-row
grammar with ▲▼ vs prior 30 days. Adoption pass = task #3.

PARALLEL SESSION: user is running a second UI-only session on the SAME
branch/worktree (codex/atria-reliability-handoff-2026-07-22 at
/Users/amanpandey/projects/atria). Commit early, pull before editing,
expect concurrent commits.

## 15.1 COLD-LAUNCH VERDICT: CLEAN (2026-08-05 ~04:05)

Build 9b3f3618 (allocation audit #1/#2/#3 aboard), cold launch pid=11178
epoch 1785882829: at +161s exactly ONE start marker (no restart) and
peak footprint 293MB at +77s — vs the pre-fix 1156→3122MB burst and
death at +61s. The detections-stage burst is gone; readiness
copy-elimination + 6h windowed span ceiling + per-candidate dying
thread were the missing pieces. REMAINING before closing the campaign:
overnight soak on this build (trailing cycles keep running), then strip
ALL instrumentation (AtriaMemprobe + note sites + bisect levers) and
run the full suite.

## 15.2 WHOOP adoption pass 1 begun + soak healthy (2026-08-05 ~04:15)

Soak at +267s: still ONE start marker, footprint settled to 82MB from
the 293MB startup peak — the allocation fixes hold. build-device/
DerivedData gitignored so the parallel UI session can't stage it.

Stat-row grammar shipped (8a6e8d6f) on the metric-detail contributor
rows: CAPS letterspaced micro-labels, louder numerals, ▲▼ triangles,
flat divider rows (chip-boxes removed), recessed legend naming the
HONEST semantics (band judgments, not vs-prior-30d — direction is
band-based at every call site; a WHOOP-style "vs prior 30 days" legend
would have been a lie). VISUAL SIGN-OFF PENDING: render via the sim
fixture loop (or Mirroring) BEFORE installing this change to the phone
— rows live behind metric detail → Show details, unreachable by
devicectl screenshots. Next slices queued: hero unit at ~40% size,
day-scoped ‹TODAY› capsule on day-scoped screens, caps micro-labels on
remaining metric-name sites, half-width monitor tiles.

PARALLEL SESSION note: no second-session commits observed yet; my next
edits stay in AtriaOverviewSections/AtriaHomeView/AtriaSharedChrome.

## 15.3 Stat-row grammar RENDER-VERIFIED (2026-08-05 ~04:20)

Temp-XCTest render (recipe: protocols memory) of the new contributor
rows PASSED visual sign-off — CAPS letterspaced labels, bold aligned
numerals, ▲/▼ triangles, flat divider rows, recessed honest legend.
One fix came out of the render: reserved 14pt qualifier column so
neutral rows share the value right-edge. Structs de-privatized (dated
comments) for render-testability; gate pins at :493/:510 migrated;
temp test DELETED after use. Safe to include in the next device
install. Next: hero unit scaling, ‹TODAY› capsule, caps micro-labels
on remaining metric-name sites.

## 15.4 Hero two-scale numerals shipped (2026-08-05 ~04:30)

Soak at +17min: one start, peak 340MB (recompute cycle), idle 99MB.
2eb1367e: AtriaMetricHeroValueText — 56pt numeral + 22pt baseline-
aligned unit at reduced emphasis, CONSERVATIVE split (unit = digit-free
trailing token or glued %, prefix must bear a digit; '6h 24m'/'Live
read'/'Learning'/'--' stay unsplit). Render-verified via temp XCTest
(deleted); PERMANENT AtriaMetricHeroValueTextTests pins the no-split
honesty cases. Gate baseline 4. Applies to every .standard hero
(HRV/RHR/respiratory/sleep hours/performance/efficiency); ring heroes
(recovery/strain) untouched. Next: ‹TODAY› capsule stepper styling,
remaining caps micro-label sites, then a device install bundling the
render-verified UI batch.

## 15.5 Day capsule + full UI batch INSTALLED on phone (2026-08-05 ~04:30)

01e33ad3: WHOOP day-capsule stepper on the Activity toolbar (caps
letterspaced TODAY in a quiet capsule, chevrons outside, forward
chevron dimmed at today, past-day capsule taps back to today) —
sim-screenshot verified via --atria-ui-screen activity (WORKS as a
fixture screen, alias added Aug 4). The same frame reconfirmed the
resting-HR pill copy "Resting HR learning · 0 of 14 days" and honest
sim stress state.

DEVICE INSTALL: full render-verified UI batch (width sweep, honesty
slice, stress transparency, stat rows, hero units, day capsule) built
Release + installed + launched on Aman's iPhone. Screen was OFF at
capture (04:30, black frame — the documented nighttime trap), so live
visual check = user's eyes in the morning + next-cycle probe pull for
the new build's cold-launch health. The overnight soak now runs on
THIS build (same allocation fixes aboard).

## 15.6 CORRECTION: §15.1 verdict was WRONG — burst survives (2026-08-05 ~04:35)

The "+161s clean" read was a measurement artifact: devicectl log copies
LAG live content by ~60-90s, and the log ROTATED at 8MB right at the
verdict window. Full-log truth: pid 11178 (allocation build, 04:00
cold launch) DIED at +67s in the classic burst — 896MB at +61s →
3363MB at +67s (~500MB/s), m_small live 2717MB / 4.4M blocks. BLE
restore relaunched it (11231) which ran 26min at ≤362MB. Pattern
unchanged: first cold launch dies once, relaunch is stable.

NEW EVIDENCE that re-aims the hunt: the burst window contains ONLY
sleep_candidates_end → widget_publish(dashboard_revision) ×2 +
hero_snapshot ×3 (all cheap, on-main) — NO hist_stage or derived_step
note fired. The balloon thread is UN-INSTRUMENTED: it starts after
sleep settlement and before/without the history pass's first substage
note. Suspects: confirmedWorkouts component entry (rehydration input
materialization before its first note), coordinator startDerived
dispatch copies, or an input snapshot (canonicalSessions copy) taken
before the first phase note.

COUNTER-DATA: pid 11324 (04:30 cold launch of the UI-batch build)
SURVIVED +195s with no restart — cold launches do not burst when the
prior process already committed the recompute (11231 ran 26min).
The burst needs a PENDING cold-launch recompute backlog.

MEASUREMENT RULES learned: (1) never trust a devicectl log copy's
recency — compare the copy's LAST timestamp against wall clock before
reading a verdict; (2) always pull BOTH atria-memprobe.log and .1.log
around a rotation; (3) a per-pid window analysis (awk on [start_a,
start_b)) is the only honest per-launch peak.

NEXT: controlled repro — cold relaunch now (fresh backlog from 11324's
run is small, may not burst); if no burst, the morning's first user
cold-open is the decisive sample. Memory file corrected.

## 15.7 BURST ROOT CAUSE FOUND: two heavy passes CONCURRENT (2026-08-05 ~04:50)

Instrumented build reproduced the death (pid 11371, +61s) with CURRENT
logs (2s lag). The complete story:

- +41s: recovered_snapshot_begin → rec_scan_begin plan=rebuild
  sources=98 bisect=full (the projection's full 1GB+ archive scan).
- Passes 1-29 PLATEAU at ~780-830MB — per-pass dying threads WORK; the
  scan alone is healthy even in sustained operation.
- +41.8s: a THIRD hist_entry reuse=0 fires (non-coordinator caller;
  comp_begin notes: ZERO — the coordinator's derived chain never
  started). That refresh NEVER reaches history_snapshots_begin.
- Pass 30→31 (~+57-59s): footprint 949→2287MB DURING the scan's 2s
  unwind sleep — allocated by that concurrent, note-less thread: the
  canonical-history ENTRY materialization (reuse=0 = fresh canonical
  load) inside refreshHistorySnapshotCache, past my hist_entry note.
- Pass 31 (+0.4GB) → 3261MB → jetsam. Relaunch (11434) stable.

CONCLUSION: the +60s cold-launch death is the SUPERPOSITION of the
recovered archive scan (~830MB plateau) and a REDUNDANT concurrent
full history refresh (~1.3GB entry load under the reclaim law) — one
completed at +6s, another started at +41.8s anyway. Neither alone
kills; together they cross 3.4GB in the dense region.

FIX DIRECTION (next cycle): the entry guard
historySnapshotProjectionShouldDefer ALREADY defers history passes
during exact-recovery priority — extend the same defer to "recovered
projection scan active" so external refreshes wait; the coordinator's
own history step (which runs AFTER projection completes) provides the
refresh anyway. Also worth killing the redundancy itself: 3× reuse=0
full refreshes within 42s of cold launch (triggers TBD). Deadlock-
free because the defer path returns early (completion-based); no
blocking waits.

Measurement note: comp_begin instrumentation worked — zero fires
proved the coordinator chain was NOT the burst context this time.

## 15.8 Single-heavy-lane fix SHIPPED (2026-08-05 ~05:00)

60d5ab60: historySnapshotProjectionShouldDefer gains
projectionScanActive (defaulted; old 2-arg callers/tests unaffected).
External history refreshes now defer while the coordinator is
.projecting — same defer external consumers already accept under
exact-recovery priority. Recovered publications pass. Lifecycle:
pendingHistoryRefreshDeferredByProjectionScan set on defer +
hist_deferred_scan_active probe note; cleared on .publish (pipeline's
own history component refreshed); re-run on .failed (no stale-strand).
Lane cases pinned in AtriaHistoricalFullDrainCoverageAuthorityTests
(42/42). Gate baseline 4. Installed + cold-launched for verification;
decisive sample = the next BACKLOGGED cold open (morning). Watch for:
one start marker, peak well under 3GB, hist_deferred_scan_active
firing during rec_scan passes.

Redundancy backlog (not yet done): 3× reuse=0 refreshes in 42s of
cold launch — coalescing would cut launch CPU/alloc further; triggers
still unidentified (sleep-candidate settles + scene activation?).

## 15.9 Burst-hunt round 3: guards verified, lane widened (2026-08-05 ~05:20)

Verified on-device, three consecutive instrumented cold launches:
- Round 1 (single-lane fix 60d5ab60): scan COMPLETED (20s, plateau
  892MB, hist_deferred_scan_active fired) — death MOVED to +80s inside
  shadow parity (955→3202MB; readVerifiedConsumerSources decodes at
  whole-archive scale even with maximumSourceCount:1).
- Round 2 (shadow cold-launch skip c63e7397): shadow_step_skipped
  fired; death MOVED to +151s — an EXTERNAL reuse=0 history refresh
  during the DERIVING phase, stacking its ~1.3GB entry load on the
  ~1.3GB retained recovered working set (recovered_snapshot_end shows
  hrPoints=726K rrBeats=474K resident ≈1.23GB — RETAINED, not garbage).
- Round 3 (lane widened to .deriving, this commit): installed +
  cold-launched ~05:20; verdict next cycle.

Pattern: each fix moves the death later and the guards demonstrably
engage. Remaining structural issues once round 3 verifies: (a) WHO
fires the repeated external reuse=0 refreshes (3-4 per cold launch —
coalescing backlog); (b) the 1.3GB retained recovered working set is
itself half the ceiling — bounding/staging it is the durable fix;
(c) bounded reads for readVerifiedConsumerSources (task #10 list).

## 15.10 Round-3: widened-lane cold launch CLEAN (2026-08-05 ~05:25)

BOOKKEEPING CORRECTION to §15.9: 11637 ("death at +151s") was
terminated by the round-3 INSTALL at +152s while at 3373MB — 4MB under
the ceiling, mid-climb, so the deriving-phase superposition diagnosis
stands, but no jetsam actually fired.

ROUND-3 RESULT: pid 11676 (widened-lane build, cold launch 05:17) ran
402s with peak 352MB and ended IDLE at 95MB — fully clean. It was then
recycled by ordinary iOS background policy (no climb, no jetsam
signature) and BLE restore brought up 11706, which is NOW running the
full rebuild gauntlet: 32 scan passes done, plateau ~904MB,
rec_scan_done hr=726K. The derived phase — where 11637 climbed — is
executing; next cycle's pull is the decisive full-gauntlet verdict.

Note: 11676 fired no lane guards (0), consistent with its cycle not
overlapping any external refresh — the clean run is necessary but not
sufficient; 11706's gauntlet is the real test.

## 15.11 Round-4: gauntlet still dies at +65s — new note-less climber (2026-08-05 ~05:30)

pid 11706 (BLE relaunch that ran the FULL rebuild): scan ✓ (904MB,
+49s), sort ✓, snapshot ✓ (1240MB), proj stages ✓ (1392MB, +52s),
post_swap ✓ (footprint DROPPED to ~911MB at +53s — reclaim worked).
THEN a note-less climber: 835MB@+57s → 1153@+60s → 1731@+61s →
2184@+62s → jetsam 3303MB@+65s (~350MB/s). The coordinator's derived
chain NEVER started (zero comp_begin fires) — this climber is NOT the
recompute pipeline. Lane guard deflected 3 external history refreshes
(hist_deferred_scan_active ×3) — those are handled. Interleaved notes
during the climb: dashboard_revision widget publishes + live_bpm
(strap streaming). Successors 11732 (356MB peak, recycled idle) and
11771 (308MB, healthy) confirm: only the full-gauntlet process dies.

SUSPECTS for the post-swap note-less climber (next instrumentation
targets): (a) refreshHistoricalArchiveStatus via NON-coordinator
callers (the comp_begin note only covers the coordinator's entry);
(b) the P0 connected catch-up drain / terminal materialization lanes
kicking in on the live strap link right after the swap; (c) widget/
dashboard revision fan-out materializing consumer projections. Add
entry notes to all three, reproduce once, read the last note.

User-visible state UNCHANGED all along: one silent restart on
backlogged launches, relaunch stable, data intact (post_swap commits
before the death every time).

## 15.12 USER DIRECTIVES + round-4b armed (2026-08-05 ~05:50)

DIRECTIVE (mid-loop): this session = ENGINE ONLY — UI belongs to the
parallel session (WHOOP-adoption queue in §15.2-15.5 + the design spec
is theirs to consume). No overnight soaks: force same-day verification.

Round-4 verdict: 11799 ran clean (311MB/205s) but likely incremental —
no gauntlet. Round-4b build adds the LAST un-noted heavy lanes:
arch_status_entry (all callers), terminal_publish_entry/exit,
verified_read_source/exit, daily_metrics_build. Installed ~05:47.
FORCED REPRO ARMED: 10min backlog accumulation → terminate+relaunch →
+180s pull → last-note-before-death analysis (background task, result
next cycle). If the climber shows, its note names it; if the launch is
clean N times under forced backlog, the +65s death is closed by the
lane+skip fixes and the remaining kill needs the LONG backlog only a
real overnight gap produces (then: reproduce by seeding a synthetic
gap, still today).

## 15.13 KEY FACT: the dying cycle was SUPERSEDED (2026-08-05 ~06:10)

In 11706's death window, `recompute_stage phase=derived` NEVER fired:
post_swap_done (+53s) was followed by the coordinator taking the
SUPERSEDE path (a trailing archive revision queued by the streaming
strap during the 25s scan) — effects [.superseded,
.scheduleTrailingStart(20s)], so the derived chain (comp_begin) never
ran and the death at +65s belongs to a FLUSH-TRIGGERED lane outside
the recompute pipeline (or the supersede/rollback path itself).

Two-front hunt running NOW:
1. Flush-synchronized forced repro (device): poll for a fresh durable
   flush marker, terminate+relaunch within seconds of it so the launch
   sees an unprocessed revision → rebuild-scale recompute + flush lanes
   under round-4b's complete note net.
2. climber-hunt workflow (wf_3021d643): 5 parallel mappers (BLE flush
   lanes / archive append / rollback+supersede / dashboard observers /
   steps-today) → adversarial verification against the observed note
   pattern → ranked verdict + one discriminating note.

Also learned: cold relaunches with a committed archive run NO scan at
all (no pending revision → no recompute) — forced repro must be
flush-synchronized to exercise the gauntlet.

## 15.14 CLIMBER NAMED AND FIXED (2026-08-05 ~06:45)

18-agent adversarial workflow (wf_3021d643, 2M tokens) + the supersede
discovery converged on the climber: **motionTickDayEvidenceRead** (the
strap-step-receipt daily scan, HistoricalArchive.swift ~2629) — ONE
continuous budget-less scan of the backlogged ~1GB archive on the
long-lived projection queue. Fully observed causal chain: superseded
recovery cycle releases archive priority (+53s) →
resumeDeferredForegroundArchiveWork re-arms the DEFERRED receipt work
→ climb onset +57s at ~350MB/s (reclaim law: one stretch accumulates
all parse garbage) → jetsam +65s. Note-less because the lane had no
probe note. Runner-up (documented, unfixed): the session-boundary
derived trio (overview trends / training load / HR zones,
Sessions.swift 8957/8983/9013) — known-jetsammer per in-repo comment
at 10804; fix pattern identical if it ever shows.

FIX SHIPPED 969debbf: budgeted 32MB dying-thread passes (rec_scan
driver pattern) + step_receipt_day_scan/_done notes + heavy-lane defer
guard on refreshCurrentCycleStrapStepReceipt (was missing; prepare
had it). 79/79 step/motion/authority tests; gate baseline 4.
DEFERRED: fingerprint-latch improvement (exclude live active segment
from the attempt signature) — needs its own receipt-correctness pass.

VERIFICATION RUNNING: corrected mid-scan kill loop (prior loop had a
grep -c shell bug and never armed) — kills the app mid-scan so the
revision stays unpublished, relaunches into the true gauntlet on the
FIXED build. Expect: step_receipt_day_scan notes bracketing budgeted
passes, peak well under 3GB, ONE start marker.
