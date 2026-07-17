# Gym calibration & stress-run runbook — prepared 2026-07-15 ~03:10 IST

Everything below was verified end-to-end on 2026-07-15 against existing archived data,
without touching the device, the running app, or the overnight monitor. The gym session
runs on the **installed build (commit `45ddbc36`)** — do not reinstall first; the signed
install comes after calibration per the handoff sequence.

## 0. Preconditions (must all be true before leaving)

1. The 11-sample overnight monitor has exited and its final summary was recomputed:
   `python3 tools/monitor_long_wear.py --repo /Users/amanpandey/projects/atria --recompute-existing-run logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714`
   (recompute is REQUIRED — the running process is old code that does not write
   `run_attributed_*` fields; see handoff addendum.)
2. CSV capture window is armed. The copy-only 2026-07-15 08:55 pull recorded
   `atria.strapStepCalibration.captureUntil = 1784647457.773982` →
   **expires 2026-07-21 20:54:17 IST**. Semantics (committed
   `AtriaStrapCalibrationArchive.swift`):
   the window persists across normal launches; `--atria-enable-step-calibration` re-arms
   now+7d; `--atria-disable-step-calibration` clears it. If a fresh pull shows it expired,
   relaunch the app once with the enable argument (allowed only after the monitor exits).
3. Verify **Settings → Developer → Step calibration** is visible before leaving. The
   research card is launch-argument-only and does not appear after an ordinary launch.
   If it is absent, after the monitor has completed, relaunch the installed build once:

   ```sh
   xcrun devicectl device process launch \
     --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
     --terminate-existing \
     com.adidshaft.atria \
     --atria-developer-mode
   ```

   If and only if the capture lease is also expired, append
   `--atria-enable-step-calibration` to that same launch. Do not relaunch merely to re-arm
   a lease that is still current.
   Before collecting anything, verify the calibration card says **0/6**. If it does not,
   use **Restart sequence** first; never mix retained stages from an earlier attempt with
   the new gym session.
4. Strap and phone charged; strap worn snug on the wrist (not carried). **Remove the
   strap charger/battery pack before every calibration, holdout, and negative-control
   window.** The earlier charger-on walk is not qualification evidence.
5. Keep Atria foregrounded and the phone near the strap for all six guided stages,
   including both rests. Ordinary workout sessions do not replace the guided sequence or
   its exported manifest.

## 1. Six-stage guided calibration (the fit tool's exact contract)

`tools/fit_step_calibration.swift` hard-fails unless the manifest is EXACTLY:

| # | Label       | Kind | Expected steps | Constraint |
|---|-------------|------|----------------|------------|
| 1 | Rest before | rest | 0              | ≥ 65 s, genuinely still |
| 2 | Slow 100    | walk | 100            | count exactly 100 steps |
| 3 | Normal 100  | walk | 100            | count exactly 100 steps |
| 4 | Brisk 100   | walk | 100            | count exactly 100 steps |
| 5 | Normal 200  | walk | 200            | count exactly 200 steps |
| 6 | Rest after  | rest | 0              | ≥ 65 s, genuinely still |

Windows must be chronological and non-overlapping. Use the in-app guided calibration flow
(`AtriaStepCalibrationPlan`, present in the installed build): it records each stage's
start/end and, when all six stages are complete, exports
`atria-step-calibration-<sessionStartedMS>.json` via the share sheet — **share/AirDrop the
manifest to the Mac before leaving the gym.** Count steps out loud or with a hand clicker;
count every footfall as one step, not one two-foot stride. If the count is lost or an
already-saved stage is fumbled, use **Restart sequence** and repeat the entire six-stage
sequence; the installed build cannot replace one successfully saved stage. Never alter
the manifest's expected count to match a guess.

Per-window evidence gate (fit tool refuses to score otherwise): coverage ≥ 95 %, zero
device-second continuity breaks, zero uncovered boundary time. Keep the phone near the
strap and the app foregrounded throughout all six stages to minimise dropped frames.

**Required boundary buffer for the currently installed build:** each exported manifest
window is aligned inward to the first and last complete strap device seconds. Immediately
after tapping Start, remain motionless for at least **2 seconds** before beginning the
count. After the final counted step, remain motionless for at least **2 seconds** before
tapping Stop. Leave more than 1 second between stages. Without these buffers, a step at
either wall-clock edge can be trimmed while the aligned manifest still appears complete.
Never compensate by changing the expected count or guessing a missing step. Run both
rests for at least **65 wall-clock seconds**, not exactly 60: the installed app can accept
a 60-second tap window whose inward-aligned manifest is only 59 seconds, which the fitter
then rejects.

### Preserve capture after stage 6

Saving the sixth stage calls `finishStepCalibrationCapture()` and removes the raw-motion
capture lease. Therefore **do not begin the stress stages immediately after sharing the
manifest**. Perform this exact sequence first:

1. Share/AirDrop the completed JSON to the Mac and verify that the file arrived.
2. In the calibration card, tap **Restart sequence**. This clears the in-app plan, not
   the already-shared Mac copy or retained raw CSV files.
3. Tap **Prepare motion stream** and wait for fresh motion/ready state.
4. Leave the newly reset Rest-before stage unstarted. Raw archival is now re-armed for
   the holdout, stress, and negative-control windows below.

If the card is not fresh/ready, do not collect a timed window. Re-arm or repair first;
the normal live step display alone does not prove that raw archival is active.

## 2. Holdout, negative controls, and stress stages

The fitter learns its gain from the same four guided walks that it scores. A printed fitter
pass is therefore not sufficient by itself. After re-arming capture as described above,
collect at least one **independent charger-free holdout walk** that is not part of the
six-stage manifest: preferably a longer normal or brisk walk, manually counted from the
first through final footfall. The selected candidate must later replay within 5% on this
holdout.

Use separate named workout sessions where practical. Maintain an external timing note for
every holdout, stress, and negative-control window with second-level timestamps and the
independent count, for example:

```text
Holdout normal — 437 steps — 07:21:14 to 07:25:02 IST — charger removed
Seated upper-body — 0 steps — 07:41:10 to 07:44:10 IST — feet planted
```

Saved workout start/end times do not preserve a manual count or isolate motion from
warm-up/equipment transitions, so they cannot substitute for this note. Record
motion-only boundaries to the second and do not combine different activities inside one
scored window.

Required sessions (handoff §“Required physical session”):

1. Independent normal or brisk holdout walk, manually counted; 5–10 minutes if practical.
2. Slow jog/aerobic run with natural arm swing, manually counted or independently
   referenced when practical.
3. Strength workout including app background/foreground switching.
4. Stationary cycling with a clean, externally timed zero-step interval.
5. A separate 5–10 minute dance session with an exact label and timestamps. Do not call
   this a zero-step control: dance may contain real footfalls. Count them if practical;
   otherwise use the window only for activity-type confusion analysis and false walking
   classification, not step-error acceptance.
6. Clean zero-step controls, each with its own exact start/end and `expected_steps=0`:
   seated still wear; phone-only handling while the strap wrist remains still;
   typing; feet-planted upper-body/strap-motion work; stationary cycling; and a
   passenger/driving interval. Never operate the phone while driving. A mixed strength
   workout is not a zero-step reference unless every real footfall is independently
   accounted for.
7. One separate **outdoor** walk/run/cycle for route qualification. Treadmill and
   stationary-bike sessions cannot prove location, pause gaps, map persistence, or GPX
   sharing.

During these, verify the handoff's live checklist: step latency/monotonicity through
reconnects, live workout metrics (steps/calories/strain/HR/zone, no 3-digit HR wrap),
Lock Screen/Dynamic Island truthfulness through pause/resume/app-switch/goal crossing,
HR-zone haptics (lower-cross ×1, upper ×3, return-from-above ×2, fall-below-lower ×1),
route/GPX/pause-gap on outdoor movement, post-save share, Activity persistence after
relaunch, battery/bolt coherence throughout.

Do not leave haptic coverage to chance. Before one short workout, choose reachable lower
and upper targets around the expected exercise HR, then deliberately cross in this order:
below → in range (**1 pulse**), in range → above (**3**), above → in range (**2**), and
in range → below (**1**). Record whether each strap pattern occurred. For the outdoor
route session, grant precise location, deliberately pause and resume once, end/save it,
then verify the map, preserved pause gap, GPX export, post-save share, and persistence
after relaunch.

## 3. Post-session pull (at home, not at the gym)

**Lesson from 2026-07-13:** the 16:14 IST audit pull had only 92.2 % coverage of a rest
window ending 16:15:35 IST; the 21:12 IST pull of the same window had 97.6 % — strap
frames flush late. **Pull at least ~1 h after the final window ends**, never delete
on-device originals. Run the pull about 1–2 hours after the final scored window: not
immediately, but also not many hours or days later.

The script requires a device identifier and a unique output directory. From the repository
root, run:

```sh
pull_label="gym-calibration-$(date -u +%Y%m%dT%H%M%SZ)"
pull_dir="logs/live-device/${pull_label}"
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  ./pull_atria_state.sh --evidence-dir "$pull_dir"
```

The copied calibration archive is then at `$pull_dir/atria-step-calibration`. Keep the
app-exported manifest separately; neither the pull nor later replay deletes device data.
Never reuse an existing pull directory, and verify
`step_calibration_archive_status=ok` in `$pull_dir/pull-summary.txt`.

At the 2026-07-15 preflight, the bounded calibration archive was already about 98.3 MB
(97.7%) against its 96 MiB cap. The pull now calculates a fail-closed retention forecast
from exact CSV row bytes and the peak rolling hour in the latest six hours. That preflight
measured 14,580,137 bytes/hour and a conservative 4.603-hour retained window after
reserving one full 32 MiB segment, so the required pull within two hours was `sufficient`.
Read `step_calibration_archive_retention_forecast_status` and
`step_calibration_archive_retention_action` on the real gym pull. If evidence is unknown,
insufficient, or shorter than two hours, follow the printed immediate-pull action; never
assume the old forecast still applies. New frames evict the oldest files, so pull promptly
after the required settling hour and preserve that copy.

## 4. Replay & fit (verified working 2026-07-15)

Compile (verified: reproduces recorded evidence byte-for-byte; omitting FrameParser.swift
fails on crc8/crc32):

```sh
swiftc -O tools/replay_step_calibration.swift Atria/Atria/AtriaR10Motion.swift Atria/Atria/FrameParser.swift -o /tmp/replay_step_calibration
swiftc -O tools/fit_step_calibration.swift    Atria/Atria/AtriaR10Motion.swift Atria/Atria/FrameParser.swift -o /tmp/fit_step_calibration
```

Replay any labeled window (epoch **milliseconds**, end exclusive; frames are selected by
strap device time, which is unix-epoch-seconds ×1000):

```sh
/tmp/replay_step_calibration <pull>/atria-step-calibration <start-ms> <end-ms> [expected-steps]
```

After the fitter prints its selected candidate, replay that exact winner against every
extra rest/handling/driving negative-control window (not only the six fit windows):

```sh
/tmp/replay_step_calibration <pull>/atria-step-calibration <start-ms> <end-ms> 0 \
  --candidate-filter <selected-filter> \
  --candidate-peak <selected-peak> \
  --candidate-sensitivity <selected-sensitivity> \
  --candidate-confirmation <selected-confirmation> \
  --candidate-gain <selected-gain>
```

Candidate mode requires the complete five-value tuple, rejects values outside the
fitter's search grid/gain bounds, and exits nonzero for incomplete motion evidence. A
negative-control window passes only when it reports
`candidate_expected_steps=0 scoreable=1 rest_false_steps=0 rest_pass=1`.

Replay the independent counted holdout with the same complete five-value candidate tuple
and its real expected count. It passes only when `evidence_scoreable=1` and the absolute
`error_pct` is at most 5%. A strength, cycle, or driving interval containing uncounted real
footfalls is diagnostic only and cannot be used as zero-step acceptance evidence.

Fit against the app-exported manifest (fails closed on incomplete evidence; passes only
when rest false steps = 0, mean walk error ≤ 3 %, max walk error ≤ 5 % across a
1,320-candidate sweep):

```sh
/tmp/fit_step_calibration <pull>/atria-step-calibration <manifest.json>
```

The fitter also accepts a separate holdout manifest without changing the six-stage app
contract or allowing validation data to influence fitting:

```json
{
  "windows": [
    {"label":"Holdout normal","kind":"walk","start_ms":0,"end_ms":0,"expected_steps":437},
    {"label":"Typing","kind":"negative","start_ms":0,"end_ms":0,"expected_steps":0}
  ]
}
```

Replace the zero timestamps with the exact end-exclusive strap-device epoch milliseconds.
Kinds are `walk`, `run`, `rest`, or `negative`. The holdout file must contain at least one
counted walk/run and at least one zero-step rest/negative, use unique non-overlapping
windows, and must not overlap any training window. Run:

```sh
/tmp/fit_step_calibration <pull>/atria-step-calibration <manifest.json> \
  --holdout-manifest <holdout.json>
```

The candidate and gain are frozen before the holdout file is decoded. Every positive
holdout must be within 5%, every negative must report exactly zero steps, and incomplete,
discontinuous, missing, overlapping, positive-only, or negative-only validation exits
nonzero. Legacy fitting without the flag remains supported and explicitly prints
`holdout_validation=not_provided`.

Reject the selected candidate if any externally timed zero-step control reports a false
step or if any independent counted holdout exceeds 5%, even when the six-window fitter
itself prints `pass=1`. Do not apply parameters until the fitter, the separate holdout
gate, and all scoreable zero-step controls pass.

Coverage audit without running the detector: `tools/summarize_step_archive_coverage.py`.
A schema-validated manifest example lives in the session scratchpad
(`manifest-example.json`) for reference; the real one must come from the app.

Every replay now also prints a research-only `gait_shadow_*` summary. Assessments use
overlapping five-second windows at a one-second stride, so their count is not a count of
independent samples. The output includes accepted ratio, longest accepted stride run, and
accepted-window median cadence/periodicity/consistency/gyroscope agreement. It always
prints `activity_decoder_validated=0 production_label=none`. Compare whole labelled
sessions—not individual overlapping windows—across walk, run, dance, strength, cycle,
handling, and driving to build a session-level confusion matrix. Do not turn the shadow
summary into a visible activity label until held-out positive and negative sessions
support it.

Batch the exact labelled activity windows into a separate research manifest after the
session. This manifest does not replace the six-stage calibration or holdout manifests:

```json
{
  "version": 1,
  "windows": [
    {"label":"Brisk walk","activity":"walk","start_ms":0,"end_ms":0},
    {"label":"Dance","activity":"dance","start_ms":0,"end_ms":0},
    {"label":"Feet-planted strength","activity":"strength","start_ms":0,"end_ms":0}
  ]
}
```

Supported labels are `walk`, `run`, `dance`, `strength`, `cycle`, `rest`, `handling`,
`typing`, and `driving`. Every window must be at least 34 seconds so even a confuser has
enough time to trigger the five-second/one-second-stride gait gate. Replace every zero
timestamp with the exact chronological, non-overlapping end-exclusive strap-device epoch
milliseconds. Counted steps belong only in the separate calibration/holdout manifest;
this activity manifest deliberately has no step field. Then run:

```sh
python3 tools/evaluate_activity_detection.py \
  <pull>/atria-step-calibration <activity-manifest.json> \
  --replay-binary /tmp/replay_step_calibration \
  --output <new-activity-evaluation.json>
```

The evaluator requires a walk/run and at least one confuser, refuses incomplete replay
evidence, and reports sustained `walking_shadow` confusion across every labelled class.
Even a clean report remains `research_only=1` and `validation_status=not_validated`, with
`activity_decoder_validated=0`, `production_promotions=0`, and no production label
change. It reports locomotion existence separately from subtype accuracy: a running
window may support locomotion yet is still counted as a wrong walking subtype if the only
shadow is `walking_shadow`. Dance may contain real steps, but a walking shadow during a
dance-labelled window still counts as subtype confusion; it is not a zero-step assertion.

## 5. Independent SpO2 and wrist-temperature reference pairing

SpO2 and wrist-temperature decoders remain unavailable until synchronized independent
references validate a versioned raw layout. If independent instruments are available,
capture several stable levels/sites in Atria's local Sensor References card and export its
CSV. Pair the export with the copied historical archive without promoting any metric:

```sh
python3 tools/pair_sensor_references.py <atria-sensor-reference.csv> \
  <pull>/historical-archive-segments \
  --output-dir <new-empty-output-directory> \
  --window-seconds 2
```

The tool selects only the nearest clock-qualified raw frame within the documented
two-second limit, reports candidate counts and reused assignments, accepts only strict
integer/boolean clock provenance, and reports archive ranges, duplicates, and rejection
counts. It requires the CSV's `local_only=1`,
`research_only=1`, `decoder_validated=0`, and `metric_promotions=0` gates, and writes a
deterministic JSONL evidence bundle plus summary. Its output remains `not_validated` even
when frames pair successfully. Production enablement requires multiple levels and users,
a frozen versioned decoder, held-out comparison with independent instruments, and a
separate accuracy review. Never populate `validatedMetricLayoutVersions` from pairing
alone.

## 6. Honesty ledger (do not lose these)

- Current provisional detector constants (research-only, never promoted): filter=8,
  peak=29, sensitivity=0.06 g, confirmation=6, referenceGain=1.11.
- Jul-13 rest window `1783938635000…1783939535000` on the fuller 21:12 pull counts
  **9 raw / ~10 production steps** at provisional constants (vs 0 on the partial 16:14
  pull that was missing the tail). Both results stand as recorded; fresh gym negative
  controls adjudicate.
- Replay marks a window scoreable only at 100 % expected frames + zero continuity breaks;
  fit requires ≥ 95 % per window. Neither may be relaxed to make data fit.
- `validatedMetricLayoutVersions` stays empty regardless of calibration outcome; no
  historical exact steps from the ~1 Hz gravity stream; SpO2/skin-temp stay unavailable.

## 7. After calibration passes (unchanged handoff sequence)

Apply only evidence-supported parameters → full simulator suite + the current complete
static/tooling suite +
`git diff --check` → signed Release build → install → physical verification via mirroring
→ only then commit/push as `adidshaft <adidshaft@gmail.com>`.
