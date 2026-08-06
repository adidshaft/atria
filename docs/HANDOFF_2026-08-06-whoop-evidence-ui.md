# Handoff — WHOOP-informed product completion (2026-08-06)

## Branch and scope

- **Working branch:** `codex/whoop-remaining-product-gaps`
- **Required integration target:** `codex/atria-reliability-handoff-2026-07-22`
- **Do not merge to `main`.**
- Source backlog: `docs/WHOOP_REMAINING_PRODUCT_GAPS.md` (currently an
  untracked, user-owned planning document; do not stage or replace it unless
  the owner explicitly asks).

This pass prioritized two product rules:

1. A chart must reveal a real decision from qualified evidence, not create a
   decorative or more certain-looking interpretation.
2. A user-facing score or label must reconcile to frozen inputs and must not
   rewrite history when defaults, profile values, or data quality change.

## Completed implementation checkpoints

The work below is committed on the working branch. The parenthetical commit is
the final checkpoint for that section; the log contains the smaller preceding
commits where a section was developed incrementally.

### P0 / P1 product correctness and UI

- **Frozen adaptive Sleep Need** — nightly need is frozen with the physiological
  cycle; old nights without trustworthy evidence stay missing rather than being
  recalculated. (`b3d16c45`, `d2e57cc3`)
- **Canonical Sleep Consistency** — schedule, score, contributors, trend and
  chart now share one evidence-qualified calculation rather than competing
  interpretations. (`1ec113a0`, `c175731f`)
- **HRR-based activity zones** — live targets, haptic transitions and completed
  activity zone distribution use frozen HRR BPM boundaries. (`b1d19432`,
  `c175731f`)
- **Recovery is morning-frozen** — naps feed a subsequent Sleep Need only and
  no longer inflate an already-issued Recovery. (`d2e57cc3`)
- **Truthful sleep presentation** — `Sleep stress` is now `Overnight HR load`;
  the card supports a Heart Rate / HR Load switch, preserves data gaps and
  shows an explicit unavailable state when archived evidence is absent.
  (`95fdef84`, `ffb0f659`, `c01d42b3`)
- **Sleep-stage honesty** — a saved sleep window with insufficient qualified
  motion/archived signal no longer pretends that stages are still processing;
  duration and available vitals remain visible while the hypnogram is
  explicitly unavailable. (`f7c9bbc1`, `a93b7ed7`)
- **Strength workflow** — persisted ordered supersets, transition/rest context
  and deterministic logged muscular-input receipts are present. The receipt is
  not yet fused into cardiovascular Strain. (`f50e3f7c`, `8cdc00e4`)
- **Recovery detail** — frozen, versioned contributor/input receipts support a
  transparent daily recovery explanation and prevent a later baseline change
  from rewriting the explanation. (`11627b4c`, `4d3974c4`, `9fe09400`)
- **Journal** — duplicate/repetitive surfaces were reduced; journal context is
  separated from recovery inputs and consented research data. (`3ecd5cbb`,
  `b577a752`)
- **Space and copy pass** — removed redundant outer shells from Live Monitor,
  Sleep detail and Morning Check-in. Live Monitor now has a distinct
  disconnected/baseline-building state instead of repeating “stress” at every
  hierarchy level. (`bf26d134`, `29456ab3`)

### Research and validation guardrails

- **External-label corpus gates** — schemas and validators now distinguish
  research/reference labels from Atria-derived output and enforce the correct
  signals, outcomes, provenance, and held-out participants. (`65fa04ef`,
  `e81d17ed`, `7fe6c267`)
- **Held-out evaluators** — offline evaluators exist for overnight HR load,
  activity classification, sleep stages, Recovery calibration and candidate
  temperature/SpO2 decoders. They report metrics only; none may promote a
  production model automatically. (`81a6e334`, `505d59eb`, `029210c5`,
  `59cd519a`)
- **Versioned export receipts** — research export is schema v6, containing
  frozen Recovery and muscular-input evidence while explicitly marking the
  latter as unfused. (`bb35c644`)

## Device verification completed

Use **iPhone Mirroring** for future visual checks; install/launch directly to
the attached device before reviewing. The latest device pass confirmed:

- App launches successfully after the v6 export work; no observed crash loop.
- Overview remains usable with incomplete strap history and labels the state as
  `Strap data gap — history incomplete`.
- The saved sleep state says `Sleep window saved`, not language implying that
  sleep-stage analysis is pending or complete.
- Sleep detail correctly shows unavailable sufficiency/efficiency/stages and
  overnight HR load when that specific saved window lacks archival evidence.
- Live Monitor’s stress baseline-build state uses a 0–3 scale and Heart Rate
  still exposes a clear timeline and Now/Average/Peak/Resting summary.
- The Recovery bottom sheet expands to the full detent without being obscured
  by bottom navigation.
- The removal of the giant outer containers in Live Monitor, Sleep detail and
  Morning Check-in is visually confirmed.

### Important interpretation for the currently attached device

An approximately eight-hour saved sleep window is **not** a completed stage
analysis. On this device, it was saved without usable archived HR/motion
coverage, so the correct display is duration plus an unavailable-evidence
state—not a hypnogram. This is not treated as a permanently stalled analysis.

Likewise, a partial strap-day with zero recovered steps must display `--`, not
`0` or `3% at 0`; `AtriaDailyStepPresentation` has that fail-closed rule.
Re-check this against a fresh install if the device shows a contradictory value.

## Required verification command sequence

Build and install from the current checkout (do not use a stale app bundle):

```sh
xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/atria-device build
xcrun devicectl device install app --device 00008130-000C74820130001C \
  /tmp/atria-device/Build/Products/Debug-iphoneos/Atria.app
xcrun devicectl device process launch --device 00008130-000C74820130001C \
  com.adidshaft.atria
```

Then inspect via iPhone Mirroring with the `computer-use` skill. Fetch a fresh
screenshot/state after every tap; the accessibility tree is sparse, so use
coordinate interactions only against the just-captured frame.

Do not accept research-sharing consent or upload/share health data during a
visual verification pass.

## Remaining work, in recommended order

### Must remain blocked pending external, consented reference evidence

These are deliberately **not** production features yet:

1. **GAP-10: validated overnight physiological-load/stress model.** Existing
   HR-load is a useful descriptive trace, but cannot be called a validated
   stress score or enter composite Sleep Score without reference outcomes.
2. **GAP-06: composite Sleep Score.** Do not produce one until all components,
   including GAP-10 overnight physiology, are independently qualified and the
   score is reproducible from frozen inputs.
3. **GAP-09: fuse muscular and cardiovascular Strain.** Logged muscular input
   is available, but the saturating fusion rule needs outcome-labelled
   calibration so it does not double-count cardiovascular work.
4. **GAP-11: automatic activity type classifier.** Requires participant-split,
   user-confirmed activity labels plus cadence/orientation/gyro/HR evidence.
5. **GAP-12: sleep-stage model validation.** Requires PSG or another defensible
   reference, split by participant. Never expose stages as EEG-measured.
6. **GAP-13: Recovery calibration.** Requires held-out fatigue, standardized
   performance, next-day HRV or RHR outcomes. Existing score stays versioned
   and transparent, not “validated.”
7. **GAP-14: temperature and SpO2 decoder validation.** Requires independent
   reference-device pairing, unit/range/placement/dropout analysis and
   repeated participants before any production reading.

The tools/docs are ready for these programs:

- `tools/validate_research_corpus.py`
- `tools/evaluate_overnight_load_model.py`
- `tools/evaluate_activity_classifier.py`
- `tools/evaluate_recovery_model.py`
- `tools/evaluate_sensor_decoder.py`
- `docs/research-validation-corpus.md`
- `docs/export-schema.md`

Baseline validation command:

```sh
python3 -m unittest \
  tools/test_validate_research_corpus.py \
  tools/test_evaluate_activity_classifier.py \
  tools/test_evaluate_overnight_load_model.py \
  tools/test_evaluate_sensor_decoder.py \
  tools/test_evaluate_recovery_model.py
```

The last run completed **37 tests, all passing**.

### Product/UI review still worth doing with more real history

- Re-check every trend after at least 1–2 weeks of qualified wear. Sparse
  history must show a useful building state, never fabricated interpolation,
  axes, or lines crossing data gaps.
- Review the Sleep consistency/history surface on-device. Keep the canonical
  schedule view only if it exposes actual bed/wake timing and a clear decision;
  remove any remaining opaque bar-strip rendition rather than restyling it.
- Exercise all strength superset flows on a device: create, reorder, ungroup,
  pause/resume and save. Check that logged muscular input is labelled as logged
  input—not total Strain.
- Recheck all unavailable states with deliberately partial/no wear: sleep
  detail, overnight HR load, steps, stress, Recovery contributors and activity
  zones. `--` is preferable to a numerical-looking placeholder.
- Continue the copy audit. Do not repeat “stress” in title, selector, subtitle,
  empty state and footnote when one precise explanation will do.

## Guardrails for the next implementer

- Work on a branch off `codex/atria-reliability-handoff-2026-07-22`; never use
  `main` as the source or integration target.
- Preserve frozen historical receipts. Fixes create new model versions or new
  cycles; they do not silently recompute history from today’s profile/baseline.
- Do not add unknown data as a neutral default, create synthetic chart points,
  or bridge a wearable gap with a line.
- Do not promote a research evaluator to production based only on passing unit
  tests. Unit tests validate the gate/tool, not the model.
- Do not stage `Atria/build-sim/` or the user-owned
  `docs/WHOOP_REMAINING_PRODUCT_GAPS.md` unless explicitly asked.

## Current checkpoint

`bb35c644 Export frozen muscular research receipts` is the last implementation
commit before this handoff. The handoff commit that follows records this paused
state; no merge has been made to `main`.

## Field diagnosis 2026-08-06 23:15 IST — five user-reported symptoms, one wedge

Read-only forensics (device plist pulled 23:14; no code changed). User
reports: (1) steps "3% of today verified · no usable step count yet";
(2) Stress "Waiting for a fresh strap signal"; (3) Live strain chart
"No saved observations"; (4) Vitals history heart/strain missing +
"not connected to Bluetooth"; (5) workout started 21:35 but review
window begins ~19:06-19:30.

### Root finding: offlineSync transport wedged mid-handshake since 09:26:58

- `atria.offlineSync.handshakeStatus.v1 = history_first_frame_received`
  with `handshakeAt = 09:26:58` — a history handshake opened at 09:26:58
  and NEVER completed or reset.
- `lastDurableFlushBoundaryOKAt = 09:33:47` — the durable flush boundary
  has been FROZEN for ~14 h. flushDebt stuck at "low 132" observed
  09:26:55 (the debt monitor stalled with it).
- Meanwhile LIVE capture ran all day: `sample.lastRawNotificationAt =
  22:53:02`, 779,791 accepted samples, session checkpoints saving
  (`saved_accepted_hr_watchdog`), duty-cycle armed 14.3 h today. HR was
  CAPTURED but nothing after 09:33 was durably flushed/verified.

Downstream, this one wedge produces all five symptoms:
1. STEPS 3%: offload verification rides the same transport —
   `pendingOffloads` ballooned to 244 tickets (was 6-16 yesterday);
   windows close but never verify → coverage collapapsed to 3%.
2. STRESS: intraday stress needs fresh flushed/verified signal; the
   stores starved after 09:33. (Also the link is down right now.)
3. LIVE STRAIN "No saved observations": no durably saved rows since
   09:33 → today's chart genuinely has nothing saved to draw.
4. VITALS history missing + "not connected": same starvation for the
   history surfaces, and the "not connected" chip is TRUE — the link
   is currently down (`keepalive missing_peripheral` since ~22:54,
   `strapStream.state unknown / notifying=false`; a bluetooth.off
   actionable diagnosis fired 19:16; stallReconnects now 101).
   Strap battery 29% at 22:35 — declining, charge it tonight.
5. WORKOUT WINDOW: `workoutMotion.boundaryStartedAt = 19:06:26`,
   status released 19:15:48, backfillReason r10_range_unrecovered for
   ~19:39-19:43 — the detection boundary anchored at the 19:06-19:16
   link-flap era. With no durable rows since 09:33, cluster anchors
   degrade; the 21:35 workout inherited the 19:06 boundary. (Chain is
   evidence-consistent; exact review-window math needs code
   confirmation next session.)

### Timing/causality note (honest accounting)

09:26-09:33 is exactly the morning ship flurry on the OTHER branch
(codex/atria-reliability-handoff-2026-07-22): eda13ba0/31225021
installs (~09:25/~09:33) and d8c0f441 (~09:15) which set
`automaticFullDrainRecoveryEnabled = false`. Leading hypothesis: an
install kill interrupted the 09:26:58 history handshake, AND the
disabled automatic drain lane removed the path that historically
RESET half-open handshake state on its next arming — so nothing ever
clears it. The deadlock the flag-disable fixed was real (authority is
now `resolved` — yesterday's publication landed); the missing piece is
a handshake reset that does not depend on drain arming.

### Recommended fixes (next implementer — none applied)

1. HANDSHAKE WATCHDOG: half-open history handshake
   (`history_first_frame_received` and friends) older than N minutes
   with no subsequent frames → reset the offlineSync transport state
   machine (same self-heal family as the §15.50 poweredOff-wedge
   design in HANDOFF_2026-08-03). This is the structural fix.
2. IMMEDIATE USER REMEDIATION (no code): relaunch the app (clears
   process handshake state — proven on the CB wedge) and charge the
   strap (29%). Expect boundary to advance and the 244 tickets to
   start verifying within minutes of a healthy link.
3. Re-examine d8c0f441's side effects: enumerate every reset path
   that only ran on automatic drain arming; move those resets to
   connection-epoch boundaries instead.
4. After recovery, re-run the coverage SLA measurement (§15.76 in
   HANDOFF_2026-08-03) on a clean day — today is invalid for it.

## CORRECTION + fix spec (23:45 IST, post-relaunch verification)

The relaunch test DISPROVED the "wedged handshake" framing above:
link restored, HR flowing (raw notifications 23:36), battery reading
live — but boundary/handshake/debt timestamps unchanged. Deep read
of the writer settles it:

`lastDurableFlushBoundaryOKAt` is written ONLY in the historical
drain's durable-flush success path (AtriaBLEManager ~30653, guarded
by offlineHistoricalSyncInProgress + drain generation). The boundary
is not wedged — THE DRAIN LANE IS OFF. d8c0f441 (2026-08-06 ~09:15,
automaticFullDrainRecoveryEnabled=false) was TOO BROAD: besides the
doomed July gap-replay it also disabled the routine CONNECTED-SLICE
drain (armed from the history first-frame handler, ~29852
armConnectedHistoricalSliceIfNeeded) — which is the archive's
primary ingestion path for CURRENT data. The 09:26:58 handshake is
simply the LAST drain's footprint before the lane went dark.

Consequences (matches all five symptoms): live capture + session
checkpoints healthy all day (sleep/workout sessions intact), but the
HISTORICAL ARCHIVE ingested nothing after 09:33 → archive-backed
surfaces starve: strain "No saved observations", Vitals history,
stress stores, steps verification (flushDebt 132 frozen; offload
tickets 245 and climbing).

### Fix (IMMEDIATE, one line — recommend first thing next session)

Revert the flag: AtriaHistoricalFullDrainCoverageCoordinator.swift:8
`automaticFullDrainRecoveryEnabled = true` (+ un-migrate the test pin
in AtriaHistoricalFullDrainCoverageAuthorityTests ~1194). This
restores yesterday's behavior: archive ingestion works; the cost is
the known transport-occupancy problem (44-73%, §15.76 in
HANDOFF_2026-08-03), which was the ORIGINAL target. Data flowing
beats coverage optimization.

### Fix (STRUCTURAL, the real one)

Split the single flag into two:
- `automaticGapRecoveryEnabled = false` — gates ONLY gap-ledger
  window recovery arming (the July windows the 309-day analysis
  proved unreachable). Stays off until a proven seek exists.
- `connectedSliceDrainEnabled = true` — the routine
  connected-chunked-backfill slice lane (current-data ingestion).
  Always on; bound its continuous transport occupancy (e.g. slice
  N minutes, yield M minutes when flushDebt is low) to solve the
  §15.76 occupancy problem WITHOUT starving the archive.
Trace both consumers of productionHistoricalFullDrainGapRecoveryEnabled
(AtriaBLEManager 8666/8794/8821 + the slice-arm path at ~29852) and
route each to the correct new flag. Verify afterwards: boundary
advances within minutes of a connected link; the 245 tickets begin
verifying; steps % climbs; strain/stress/history surfaces repopulate.
Then re-run the §15.76 occupancy measurement with the bounded slice.

### Verification protocol for the fix session

1. Ship revert (or split) → within 5 min of connected link expect:
   handshakeStatus advances past history_first_frame_received,
   lastDurableFlushBoundaryOKAt goes current, flushDebt re-observes.
2. Watch pendingOffloads fall from 245.
3. Confirm on-screen: strain chart gains today's observations;
   stress leaves "waiting"; Vitals history returns.
4. Workout-window symptom (5) re-check AFTER a day of healthy
   archive — the 19:06 anchor may self-correct once rows exist.
