# Atria — Claude handoff 10: publish current sleep from durable live evidence, make Today date-honest, and finish the sparse charts

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `codex/whoop-remaining-product-gaps`  
Exact pushed starting commit: `f72ad32bde957a405388a48c0e87a10a4e157722` (`Match the HR probe to the production navigation's priority`)  
Remote parity verified at handoff: `HEAD...origin/codex/whoop-remaining-product-gaps = 0 0`  
Clean release worktree: `/private/tmp/atria-notifications-integration.wyA4H7/source`  
Dirty user checkout that must not be touched: `/Users/amanpandey/projects/atria` at `293d1a7c988bf99b6093b8529da0cf528d6e4896`  
Primary issues: [#25](https://github.com/adidshaft/atria/issues/25), [#21](https://github.com/adidshaft/atria/issues/21), [#2](https://github.com/adidshaft/atria/issues/2), [#5](https://github.com/adidshaft/atria/issues/5)

## Mission and hard cutline

This pass has exactly three deliverables, in this order:

1. **P0 — current sleep must not wait for the slower strap-history frontier when Atria already has a durable, sufficiently complete live HR/RR journal.** Use the canonical union with explicit provenance and gap rules; surface an HR-only review candidate when motion is absent. Never auto-confirm a 17-hour claim or invent stage certainty.
2. **P0 — Today must stop silently rendering the prior physiological cycle as if it belongs to the current date.** Aug 13 and Aug 12 must not show the same 92% / 9 h 12 m / ~3.3 rings when Aug 13 already has a distinct partial metric row (54% / no sleep / ~1.0 strain).
3. **P1 — repair the exact sparse Recovery/Strain/Sleep chart presentation shown in the attached screenshots.** Fix clipped axes, ambiguous weekday initials, and the giant empty one-observation panel while preserving truthful gaps and exact samples.

Timebox: **3–4 hours total**, including focused tests and one physical acceptance run. Maximum three focused commits. If a P0 cannot pass, stop with a concrete blocker and evidence. Do not expand into motion/R10, notifications, skin/SpO2, general redesign, or a full-suite marathon.

## Explicitly out of scope

- No R10/IMU service discovery, radio writes, qualification experiments, motion-bank work, or step-formula changes.
- No changes to validated ACK ordering, durable-prefix retirement, raw/accepted HR authority, sequence-gap truth, or the `persistedDrainResumeAllowed` production fence.
- No absolute skin temperature, SpO2 formula, medical claim, WHOOP API, HealthKit, widget redesign, notification redesign, TestFlight, Safari, Brave, or Passwords.
- Do not smooth charts with a curve that overshoots real samples. Missing days remain missing.
- Do not auto-confirm the user's stated `Aug 12 21:00 → Aug 13 14:00` interval simply because the user described it as sleep. Derive evidence first and keep HR-only/motion-missing output review-only.

## Worktree safety — mandatory

The main checkout contains the user's uncommitted chart work and handoff documents. Never edit, stash, reset, clean, stage, switch, merge, rebase, or commit application source there.

Continue only in `/private/tmp/atria-notifications-integration.wyA4H7/source` after proving:

```text
HEAD = f72ad32bde957a405388a48c0e87a10a4e157722
git status --short = empty
git rev-list --left-right --count HEAD...origin/codex/whoop-remaining-product-gaps = 0 0
```

If that worktree is unavailable or dirty, create a fresh isolated worktree from the exact remote tip. This handoff document is coordination material and must not enter the app commit.

Use author and committer `adidshaft <adidshaft@gmail.com>`, no AI/co-author trailer. Push only a clean fast-forward to `origin/codex/whoop-remaining-product-gaps` after every gate passes.

## Verified Handoff-9 state — do not redo it

The release tip already includes and physically passed:

- `ddd97c44` — 4 MiB sealed history chunks and fast Activity HR reads.
- `bcca337b` — 60-second retry only after an exact durable productive-slice receipt.
- `5a247276`, `cef6d842` — blocker-first relative-skin row on the real Vitals surface.
- `6d71eb6d`, `f72ad32b` — read-only acceptance probes matched to production priority.
- `44f44cff` — sidecar scheduling at the durable flush boundary.
- The integrated 17-category notification catalog and hardening at `61fec3b1` / `0bc84fdd`.

Verified physical results:

```text
Activity Aug-11 HR cold: 633 / 601 / 613 ms
raw scanned: 1 file, 2,199,602 bytes
returned points: 90,018
history catch-up settled slope: 2.18x
focused Handoff-9 matrix: 745/745
installed build: signed Release f72ad32b chain
```

Do not reopen those designs unless this pass's exact evidence proves a regression.

## Fresh Aug-13 incident evidence — authoritative starting point

I used iPhone Mirroring first, then read-only `devicectl` pulls after Mirroring disconnected because the user started using the phone. No install, terminate, launch, settings change, or data mutation was performed.

Physical device:

```text
device: Aman's iPhone / iPhone 15 Pro
CoreDevice ID: 3803F5B6-1666-56D3-A71A-62F131F6CE3B
bundle: com.adidshaft.atria
main PID at pull: 37183
widget PID at pull: 37182
data container: C410A583-8373-4073-8830-DA7144AC2BC3
app group: E1D7DD82-6B8B-4212-A2BB-0F1CDDAE95E0
```

Read-only incident bundle:

```text
/private/tmp/atria-aug13-rings-incident.LvaHvX
```

Key hashes:

```text
initial app prefs: 3c42022b3606d6b71fbbba5329fdf7bdae21aae59404c4a492906a719006b3c6
later app prefs:   4ec925db4b3e0b17817585a6a9dbba096422bfb07a3277bd9ca27f7853458104
sessions.json:     b890207274f545debf78faf629ff3665a4033972af5b274064433dee6a965ec3
daily-metrics:     a135a7e908f436951fcfc3328c85d9afc6f5d55acac1a97827f3e6d354b9f508
confirmed sleeps:  5a3c926992226d56e5182e65ea9b53791a28c0af9819f8fb094d79ba2ecb903f
widget snapshot:   8a3bfd0966d39daabdff1988fbca2da40ddc4d7ca62ac0e06e252251b993dbf3
```

User report:

```text
claimed sleep: roughly Aug 12 21:00 → Aug 13 14:00 IST
strap worn continuously, connected, charged
Today and Yesterday rings appear identical
history banner about two hours behind
```

### The ring contradiction is real

`daily-metrics.json` has two distinct civil-day rows:

| Civil day | Recovery | Sleep | Strain | Detail |
| --- | ---: | ---: | ---: | --- |
| 2026-08-12 | 92% | 9 h 12 m | 3.296 | sleep-led, HRV unavailable |
| 2026-08-13 | 54% | none | 1.026 | RHR-only, sleep + HRV unavailable |

Aug 13's 54 is explicitly unverified and says:

```text
Limited confidence · sleep and HRV unavailable · from resting HR only — confirm a sleep to add HRV
```

But `widget-snapshot.json`, created at 14:43 IST on Aug 13, still publishes:

```text
recovery = 92%
sleep = 9.198 h / Confirmed sleep
strain = 3.3199
cycleStart = Aug 12 15:27 IST
cycleExpiresAt = Aug 13 15:27 IST
```

The sparse chart screenshot independently shows the newer Thursday recovery near 54% and strain near 1.0 while Home's Today rings show the prior 92 / 9 h 12 / ~3.3 values. This is a same-build authority disagreement, not missing data in every store.

The code already has `HeroSnapshot.recoveryIsFromPreviousSleep`, but a tiny `Previous sleep` marker is insufficient: the primary ring value and fill still look exactly like yesterday, sleep and strain are also carried, and the surrounding surface is labelled Today/Aug 13.

### Live data already spans the claimed sleep

The persisted canonical sessions contain, inside Aug 12 21:00 → Aug 13 14:00 IST:

```text
HR points: 57,409
RR intervals: 36,996
first HR: 21:00:02
last HR: 13:59:59
coverage using a conservative 5-second cap: 89.36%
gaps >30 s: 11
gaps >120 s: 5
largest gap: 1,938 s
median HR: 75 bpm
p10 / p90: 61 / 90 bpm
motion: unavailable or diagnostic-observe-only; never validated
```

This does **not** prove seventeen hours of sleep. It does prove Atria already has enough durable live HR/RR evidence to run a gap-aware detector and produce either a review candidate or a named evidence blocker without waiting for the strap-history frontier.

### The history drain is productive, not stalled

Two read-only preference pulls:

```text
14:44:09 pull: drainedThrough = 12:18:50 IST
14:49:19 pull: drainedThrough = 12:29:28 IST
wall interval: 310 s
frontier advance: 638 s
slope: 2.06x
later lag: 8,391 s (2 h 19 m 51 s)
flush debt: 1,030 records / low
last status: armed
last reason: connected_raw_catch_up_accepted_hr_batch
last durable flush: OK
rangeLossBackfillPending: true
```

At 2.06x, net convergence is only about 1.06 seconds per wall second. A 2 h 20 m lag still needs roughly 2 h 12 m of uninterrupted catch-up. From the 14:49 sample, the frontier would not pass 14:15 until about 15:40. Waiting until clock time 14:15 was therefore not the relevant gate.

The product defect is not “the drain currently does nothing.” It is:

1. Current-day sleep/rings are unnecessarily hostage to a slower redundant archive frontier even though durable live evidence is already present.
2. Any process interruption can still orphan an in-flight `gap_retained_transaction_unverified` episode until foreground activity re-arms it, so the user repeatedly returns to a large backlog.
3. Foreground/open-app policy intentionally favors live HR; a user should not have to reason about keeping the app foregrounded versus backgrounded to get a current sleep result.

## Checkpoint 1 (P0): current-day authority and ring identity

### Source anchors

- `Atria/Atria/AtriaHomeView.swift`
  - `HeroSnapshot` around line 9309.
  - `makeHeroSnapshot` around line 11890.
  - `recoveryIsFromPreviousSleep` around line 11940.
- `Atria/Atria/WidgetSnapshot.swift`
  - `publish(store:ble:reason:now:)` around line 1200.
  - Recovery/sleep/strain selection and schema-4 snapshot around lines 1230–1475.
- `Atria/Atria/Sessions.swift`
  - `currentPhysiologicalMainSleep` around line 23434.
  - `recoveryProjection` / `recoveryProjectionForPresentation` around 23505–23680.
- `Atria/Atria/AtriaHealthScreen.swift` and `AtriaOverviewSections.swift`
  - current-cycle versus historical detail projection.

### Required design

Introduce one explicit presentation identity, not another heuristic boolean:

```text
display civil day
physiological-cycle start/end
source sleep ID (if any)
source civil day
value state: current / currentPartial / priorCycleDisclosure / awaitingCurrentSleep
calculatedAt + evidence frontier
```

Apply it consistently to Home/Today hero rings, Vitals current metric projection, widget snapshot, share snapshot, and day-detail selection.

Rules:

1. A surface labelled `Today` or `Aug 13` may not silently use an Aug-12 source as its primary ring value/fill.
2. If Aug 13 has an actual current-day partial metric row, use it only with its real confidence and blockers. For this fixture that means either:
   - show `54% · Limited · RHR only; sleep and HRV unavailable`, or
   - withhold the number under an existing stricter product rule and show `Awaiting current sleep`.
   Never show 92 as today's recovery.
3. Today's sleep ring must be `-- / Awaiting current sleep` until current evidence exists. The prior `9 h 12 m` may appear only in a clearly dated `Last confirmed cycle · Aug 12` disclosure.
4. Today's strain must use the current cumulative lower bound (~1.0 here), with its partial/coverage label. Do not reuse yesterday's ~3.3.
5. Yesterday remains exactly 92 / 9 h 12 / ~3.3.
6. When a new Aug-13 sleep is reviewed/confirmed, publish a single atomic current-day replacement. Do not mutate Aug 12 and do not momentarily flash the prior cycle.
7. Physiological calculations may remain wake-to-wake. This checkpoint changes presentation identity and cross-surface selection, not the underlying day model.
8. Widget/App Intent/share payloads must carry enough identity to reject stale cross-day reuse after relaunch.

### Required tests

- Exact fixture: Aug-12 frozen `92 / 9h12 / 3.3`; Aug-13 partial `54 / nil sleep / 1.0`.
- Today selection never returns Aug-12 values; Yesterday remains unchanged.
- Prior-cycle disclosure includes its date and never supplies a primary fill.
- Current partial recovery preserves `unverified`, `usesHRV=false`, and the real RHR-only detail.
- No current-day metric: all three rings are terminal `awaiting`/partial states, not borrowed values.
- New review candidate updates Sleep only as review; no canonical Recovery remint.
- Confirmed new sleep atomically updates Today + widget once; stale callbacks cannot restore Aug 12.
- Day navigation Aug 12 → Aug 13 → Aug 12 uses distinct value/source identities and cache keys.
- Cross-surface parity test for Home, Vitals, widget, share, and Recovery detail.

## Checkpoint 2 (P0): detect from the durable live journal and self-heal catch-up

### Part A — canonical live/history union for the current sleep

Do not make the current sleep wait for `drainedThroughUnix` when the exact interval is already covered by durable accepted live sessions.

Build one bounded, provenance-preserving current-window input:

```text
accepted durable live HR/RR
union with recovered historical HR/RR
dedupe by timestamp + channel + source authority
history replaces only byte-identical/stronger provenance, never blindly
retain exact gap intervals
retain motion unavailable/validated state
```

Admission requirements:

- Durable live journal/session checkpoint covers the candidate through wake plus the existing post-wake tail.
- No unresolved persistence transaction for the exact live interval.
- Required HR coverage and max-gap policy are applied to each candidate segment, not to the entire claimed 17-hour span as one blob.
- RR provenance remains standard 2A37 / existing verified sources only.
- Motion absent means review-only and HR-estimated stages only; never auto-confirm and never claim motion-derived boundaries.
- If evidence is insufficient, emit a named blocker with the exact missing interval. Do not leave `Loading` and do not wait silently for an unrelated global frontier.

The detector should find evidence-shaped segments. It must not force the user's entire 21:00–14:00 description into one sleep record. If it finds one or more plausible episodes, surface them for review with coverage/gap/provenance. If none qualifies, report why.

Publication requirements:

- Current review appears without foreground-only intervention.
- Review survives relaunch and remains non-authoritative until confirmed.
- Confirmation/edit/nap reclassification follows existing ownership rules and invalidates/rebuilds the exact daily metric once.
- Current sleep, recovery, RHR/HRV/respiration, relative-skin blocker, ring, graph, Activity marker, and widget all use the same committed publication fence.
- No old generation can publish after a newer sleep edit or confirmation.

### Part B — process-interruption self-heal

Preserve the Handoff-9 productive cadence. Add only the missing process-lifecycle receipt:

```text
slice generation
gap fingerprint
captured start frontier
process epoch / owner identity
startedAt
terminal outcome if written
```

On launch, reconnect, or accepted live HR:

1. If a prior process epoch started a slice but wrote no terminal receipt, treat only its process-local owner as stale.
2. Re-evaluate the durable gap/debt/frontier normally.
3. Re-enter the existing connected-raw catch-up lane after the normal brake.
4. Never infer ACK, durable persistence, prefix retirement, or success from the missing terminal receipt.
5. Never enable `persistedDrainResumeAllowed`, resurrect retired full-flash replay, or bypass transaction/gap truth.
6. No foreground launch should be required. Foreground may accelerate UI publication but cannot be the only re-arm event.
7. Failure/no-progress remains on the 300-second brake; exact durable productive progress keeps the 60-second cadence.

Source anchors in `AtriaBLEManager.swift`:

- constants around 2082–2115;
- launch ticker around 5590–5640;
- `persistedDrainResumeAllowed` around 8990;
- durable productive receipt around 14590–14770;
- `gap_retained_transaction_unverified` around 16275–16345;
- maintenance ticker around 16445–16660.

### Required tests

- Live journal fully covers wake + tail while archive frontier is behind → current sleep detector runs and produces review/blocker without waiting.
- Mixed live/history overlap dedupes exactly; no duplicate HR/RR or time inflation.
- Gap crossing threshold splits/rejects the affected segment and names it.
- No motion → review-only; protected/validated motion keeps its existing stronger behavior.
- Process epoch G1 starts and dies before terminal receipt; G2 launch re-arms exactly once after the brake.
- G1 had a successful durable terminal receipt → G2 may use the productive 60-second cadence.
- G1 failure/no progress → G2 keeps 300 seconds.
- Missing terminal receipt never advances frontier/ACK/prefix authority.
- Foreground/background transitions cannot orphan or duplicate G2.
- Existing live HR acceptance and durable journal counts are byte/row unchanged.

### Physical acceptance

First take a fresh read-only pull and calculate:

```text
frontier slope
net lag
live accepted timestamp
durable live-session end
current sleep candidate/blocker
process/slice generation
```

Then, after tests/build and only after preserving the pre-state:

- One signed in-place install; migration audit must retain sessions, sleeps, daily metrics, prefs, and journal authority.
- One normal no-argument launch.
- Atria must surface a current Aug-13 review or a precise evidence blocker using the already persisted live journal before the archive frontier catches up.
- Controlled process-restart proof is allowed once: terminate only Atria after recording the active slice receipt, relaunch normally, and prove autonomous re-arm without data loss, duplicate publication, or foreground-only rescue.
- Live raw/accepted/durable HR gaps remain <30 seconds; no disconnect/CCCD/watchdog/jetsam/crash.
- Catch-up remains productive; do not require a higher slope than Handoff-9 if the sleep UI is no longer hostage to it.

## Checkpoint 3 (P1): sparse chart polish without changing truth

Attached screenshots:

```text
/var/folders/l9/3shhw7rn0nq9g4f07h5rs50m0000gn/T/codex-clipboard-36152681-54ab-4402-8d16-4a973b878bc1.png
/var/folders/l9/3shhw7rn0nq9g4f07h5rs50m0000gn/T/codex-clipboard-6f2fad30-6d68-4353-bbd0-840d479e72fd.png
/var/folders/l9/3shhw7rn0nq9g4f07h5rs50m0000gn/T/codex-clipboard-fe5a9de8-12ed-485a-b135-d803b8b642dd.png
```

Concrete defects:

- `21` and `100%` top-axis labels are visibly clipped.
- Seven `.weekday(.narrow)` labels produce repeated, ambiguous `S / S / T / T` initials.
- The negative full-bleed padding plus whole-chart `.clipped()` in `AtriaStrainRecoveryComboChart.swift` is the immediate clipping source.
- A single Recovery observation renders a huge empty chart panel with explanatory text in the middle.
- Sparse points look accidental rather than intentionally absent, even though the gap-breaking logic is correct.

Required bounded design:

1. Preserve `.linear` interpolation and `contiguousDayRuns()`. Never connect across missing days and never use overshooting splines.
2. Give the plot explicit top/left/right insets so `21`, `100%`, edge points, and date labels are fully visible. Do not solve it by hiding axis labels.
3. Replace narrow weekday-only ticks with compact weekday + day-of-month labels, e.g. `M 10`, `T 11`, so repeated initials are distinguishable.
4. Reduce grid contrast and keep both series visually clear: strain blue, recovery point colored by band, recovery line consistent and legible.
5. One observation must render a compact terminal summary (`Aug 12 · 92%`) with source/confidence, not a mostly empty faux-chart. Two or more observations may chart.
6. Apply the same axis/padding/one-point grammar to Recovery, Strain, and Sleep trend/detail graphs shown in these surfaces. Do not redesign the stage hypnogram in this pass.
7. Dynamic Type, VoiceOver, dark mode, 320-point width, and screenshot crop must remain readable.

Source anchors:

- `Atria/Atria/AtriaStrainRecoveryComboChart.swift` around lines 40–190.
- `Atria/Atria/AtriaOverviewSections.swift` one-observation view around line 11556.
- Existing shared `AtriaDetailChartPoint.contiguousDayRuns()` extension.

Required tests:

- Top/edge labels are not clipped at 320- and 390-point widths.
- Tick formatter distinguishes all seven dates even when weekday initials repeat.
- Missing day splits the line; no area or line crosses it.
- One observation uses compact terminal layout; zero observations uses named no-data state.
- Two adjacent samples draw one linear segment with exact endpoints and no overshoot.
- Recovery right-axis mapping still equals 0/33/67/100 and strain left axis 0/7/14/21.
- Snapshot/source contract covers Recovery, Strain, and Sleep variants.

## Focused validation only

Run the exact affected suites plus their existing authority neighbors, serially, one worker:

```text
AtriaCurrentCycle / physiological-cycle tests
AtriaRecoveryProjection and DailyMetric/Rollup tests
AtriaSleepAuditRegression / SleepImmediateProjection / SleepReview tests
AtriaRecoveredData publication/coordinator tests
AtriaBLE live-continuity + durable productive-slice tests
AtriaWidgetSnapshot / Home / Today presentation tests
AtriaSwiftUIPerformanceAuditTests
Atria trend/detail/chart presentation tests
```

Do not weaken or delete a test. If a source-scan assertion is stale because formatting changed, replace it with a behavioral/pure contract test; do not merely update a magic substring.

Gate:

- all selected tests pass;
- simulator app build succeeds with zero new warnings;
- `git diff --check` clean;
- changed Swift files parse;
- no app/evidence-corpus mutation from tests;
- signed Release build succeeds before physical install.

## iPhone Mirroring / physical navigation

Use Computer Use with iPhone Mirroring (`com.apple.ScreenContinuity`) first. In the initial read-only check it worked until the user began operating the phone, at which point Mirroring correctly showed `iPhone in Use`. Lock the phone/reconnect when the user is finished; do not fight simultaneous ownership.

Known navigation facts:

- Synthetic taps have previously landed about 123 px above the target, and the bottom tab bar can be unreachable.
- Prefer deep links through `devicectl device process launch --payload-url` for `atria://overview`, `atria://vitals`, `atria://sleep-review`, `atria://strap`, and supported routes.
- The phone currently runs Release. Reinstall Debug only for DEBUG fixture/probe arguments; return to signed Release for final acceptance.

Capture at minimum:

1. Aug-13 Today rings with source-state copy.
2. Aug-12 Yesterday rings proving distinct values.
3. Current Sleep review/blocker.
4. Recovery day detail one-observation state.
5. Strain & recovery seven-day graph with unclipped axes/date ticks.
6. Sleep trend/detail graph using the same grammar.
7. History banner showing live HR current separately from historical frontier.

## Issue hygiene and completion

- Update #25 with the Aug-13 live-journal candidate/publication evidence. Close only if the current sleep surfaces/reviews correctly on device and survives relaunch.
- Update #21 with the measured 2.06x incident slope, the process-epoch self-heal proof, and explicit separation of live HR from historical frontier. Keep open for whole-day step accuracy unless that separate scope is already closed.
- Update #2 with the Today versus prior-cycle recovery authority fix. Close only if its broader morning/HRV acceptance is also satisfied; otherwise leave open with the exact remaining blocker.
- Update #5 with the unclipped sparse-chart screenshots. Close only if all its existing trend/history criteria are actually satisfied.
- Do not touch #31/#34/#36 in this pass unless a regression is directly caused by these changes.

Final handback must include:

```text
starting and ending commits
per-commit subjects
focused test counts + xcresult paths
simulator and signed Release build results
physical migration and process health
before/after frontier slope and lag
current-sleep candidate/blocker provenance
Aug-12 vs Aug-13 ring values/source identities
seven required screenshots
issue links/status
remote parity 0 0
explicit untouched list
```

## Definition of done

This handoff is complete only when:

- Aug 13 no longer silently displays Aug 12's 92 / 9 h 12 / ~3.3 as its primary rings.
- Yesterday still displays the correct Aug-12 values.
- The current sleep detector consumes the durable live journal and surfaces a review or exact blocker without waiting for the global history frontier.
- Motion-missing sleep remains review-only and stage estimates remain labelled HR-only.
- A process interruption cannot strand catch-up until a foreground launch.
- Live HR remains current and the durable journal/ACK/gap contracts are unchanged.
- Recovery/Strain/Sleep charts have unclipped axes, unambiguous date ticks, truthful gaps, and a compact one-observation state.
- Tests/build/install/physical checks pass, commits are pushed cleanly, and issues are updated.

