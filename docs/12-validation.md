# Validation Harness

Gate B exits only after a real 5-minute iPhone RR capture agrees with a reference
recording across the clinical HRV metric set: **RMSSD ≤5 ms**, **SDNN ≤5 ms**,
**pNN50 ≤5 percentage points**, and **lnRMSSD ≤0.2**. The app now exports raw RR
rows while recording, and `validate_hrv.py` replays those rows with the same
correction rules used by the app.

## Capture protocol

1. Wear the WHOOP strap and the reference sensor at the same time.
2. Force-quit the iOS app, then relaunch so it uses the fresh scan-and-connect
   path.
3. Wait until the HRV card shows realtime RR activity.
4. Start Capture with a label such as `gate-b-reference`.
5. Stay still until the Capture card shows **5-min HRV window ready**.
6. Stop Capture only after the card is ready; the stopped Capture card should
   show **Validation-ready**.
7. Export the WHOOP CSV; usable Gate B captures should share as
   `whoop-capture-YYYYMMDD-HHMMSS-<label>-ready.csv`.
8. Export the matching reference RR/IBI CSV segment from the reference device.
   Its timestamps must describe the same final validation window as the WHOOP
   export; trim or elapsed-reset the reference export if the reference recording
   started earlier.

If the reference export is not already in `elapsed_ms,rr_ms` form, normalize it
before running the Gate B wrapper:

```bash
./prepare_reference_rr.py reference-export.csv reference-rr.csv --window-s 300 --window-end-s <reference-window-end-seconds>
./gate_b_reference.sh docs/evidence/gate-b/<run-label>/whoop-capture-...csv reference-rr.csv <run-label>
```

`prepare_reference_rr.py` accepts common RR/IBI column names such as `rr_ms`,
`RR Interval [ms]`, `R-R Interval [ms]`, `ibi_ms`, and `IBI [ms]`. It accepts
timestamp columns such as `elapsed_ms`, `time_s`, `seconds`, `timestamp`, and
`time`; when no timestamp column exists, it derives elapsed time from cumulative
RR. The output is always validator-ready `elapsed_ms,rr_ms`, reset to start at
0 unless `--keep-source-time` is passed. The utility refuses malformed RR values
and non-increasing timestamps instead of guessing.

For cabled real-time debugging, use:

```bash
./live_device_debug.sh --seconds 720 --until-ready --auto-capture --stop-when-ready --label gate-b-reference --log auto --pull-capture docs/evidence/gate-b/<run-label>
```

For the current fastest external-reference handoff, use:

```bash
./reference_handoff.sh <run-label>
```

This builds, installs, and launches Atria on the physical iPhone through
`live_device_debug.sh`, exports the best saved WHOOP RR package and HR package,
runs the HealthKit independent-HR audit, logs fast gate status, pulls
`sessions.json`, and writes a compact summary under
`docs/evidence/reference-handoff/<run-label>/`. The package is still not a Gate
B or Gate D pass by itself: the RR CSV must be compared with an external
RR/IBI file within the `<=5 ms` RMSSD tolerance, and the HR CSV must be compared
with an independent HR reference before HRV, Recovery, Strain, workouts, or
HealthKit HRV/workout exports can be marked validated.
The summary includes machine-readable fields such as
`ATRIA_HANDOFF_RR_READY_FOR_EXTERNAL_REFERENCE`,
`ATRIA_HANDOFF_RR_GATE_B_PASSED`,
`ATRIA_HANDOFF_HR_READY_FOR_EXTERNAL_REFERENCE`, and
`ATRIA_HANDOFF_HR_GATE_D_PASSED`; the ready-for-reference fields may be `1`
while the gate-pass fields remain `0` until independent files validate.
The wrapper waits 240 seconds by default so post-launch side effects and pulls
finish cleanly; set `ATRIA_REFERENCE_HANDOFF_SECONDS=75` (or legacy
`REFERENCE_HANDOFF_SECONDS=75`) only for smoke-verifying the wrapper itself.

After an independent reference export is available, push and validate it on the
physical iPhone with:

```bash
./reference_validate.sh <run-label> --rr external-rr.csv --hr external-hr.csv
```

`--rr` copies the independent RR/IBI CSV to
`Documents/atria-reference/rr-reference.csv`; `--hr` copies the independent HR
CSV to `Documents/atria-reference/hr-reference.csv`. The app then runs the same
on-device validators used by the dashboard imports, logs fast gate status, and
pulls `sessions.json` into `docs/evidence/reference-validate/<run-label>/`.
Run without `--rr` or `--hr` to smoke-test the fail-closed path; it should log
missing-reference validation rows and must not mark Gate B or Gate D passed. Use
`--clear` only when intentionally deleting staged reference inputs from the app
container before validation.
Every run appends parsed result fields to `reference-validate-summary.txt`,
including `ATRIA_REFERENCE_RR_STATUS`, `ATRIA_REFERENCE_RR_GATE_B_PASS`,
`ATRIA_REFERENCE_HR_STATUS`, and `ATRIA_REFERENCE_HR_GATE_D_PASS`. For the final
clinical gate check, add `--require-rr-pass` and/or `--require-hr-pass`; those
options make the wrapper exit nonzero unless the matching on-device pass bit is
`1`.

Physical iPhone verification:
`docs/evidence/reference-validate/20260615-reference-validate-result-bits-device-verify/`
shows the fail-closed path with no staged independent references:
`rr_reference_validation status=missing ... gate_b_pass=0`,
`hr_reference_validation status=missing ... gate_d_pass=0`,
`ATRIA_REFERENCE_RR_GATE_B_PASS=0`, `ATRIA_REFERENCE_HR_GATE_D_PASS=0`, a valid
pulled `sessions.json`, and `HARNESS_CAPTURE_TIMEOUT ... action=stop_devicectl_console`.
This verifies command completion and parsed fields without claiming Gate B or
Gate D.

Gate E status must remain equally fail-closed. `gate_status gate=E` is only
allowed to report `ready` when both sleep evidence is ready/validated and a
sustained workout is ready. HR-only sleep candidates stay `sleep_ready=0` with
`sleep_blocker=sleep_low_confidence`; strength candidates stay diagnostic-only
until the sustained HR/workout contract passes. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-gate-e-sleep-confidence-alignment-device-verify/`
verified `gate_status gate=E status=partial` with `sleep_ready=0`,
`sleep_blocker=sleep_low_confidence`, and `execution_priority ...
real_world_needed=E:validated_sleep_confidence,E:real_sustained_workout,...`.
The sleep verifier follows the same rule: `sleep_validation` may identify an
overnight low-HR aggregate, but it must remain `status=learning` with
`reason=sleep_low_confidence_motion_unvalidated` until low-motion evidence is
validated. This prevents HR-only sleep from satisfying Gate E.

Harness note: when a physical-device run combines `--log-gate-status` with
post-run pulls such as `--pull-sessions`, the launcher should detach after the
requested in-app ATRIADBG evidence is complete, then copy artifacts. For a sleep
verification checkpoint, the required stop evidence is both `execution_priority`
and `sleep_validation status=...`; the subsequent `ATRIADBG_SESSIONS_PULL_FILE`
proves the app container pull still happened after console detachment.

Deep Gate Status on a large saved-session store must be bounded rather than
allowed to kill the app before evidence is emitted. The harness resets its
deadline when `ATRIADBG gate_status_start` appears, and the app labels bounded
deep replay as `workout_replay_scope=bounded_large_store` plus
`gate_status_deep_detail status=skipped ... diagnostic_only=1` for the
expensive detail dump. This is an evidence-path optimization only: the gate rows
must still show the same blockers and must not mark workout, sleep, HRV, or
HealthKit-derived metrics ready from a bounded diagnostic. Physical iPhone
evidence in
`docs/evidence/gate-status/20260615T-deep-status-bounded-deadline-device-verify/`
shows `BUILD SUCCEEDED`, `HARNESS_GATE_STATUS_DEADLINE_RESET seconds=240`,
`gate_status_complete=True`, `gate_status_deep_complete=True`, a pulled
`sessions.json`, and `execution_priority ... next_local_gate=none` with Gates
B/D/E still honestly blocked by external references or real-world evidence.

For Gate G notification delivery checks, use `--test-notification` with
`--notification-delay 0` and keep the app foregrounded. The harness must log
`notification_schedule status=scheduled`, `notification_delivered kind=diagnostic`,
`notification_schedule_complete=True`, and
`notification_delivery_complete=True` before it detaches. Production recovery,
strain, and battery notifications stay confidence-gated and must not be used as
metric readiness evidence.

For the current known-good WHOOP-side Gate B reference capture, prefer the
wrapper:

```bash
./gate_b_whoop_capture.sh <run-label>
```

It runs the physical-iPhone recipe that has already produced a ready 5-minute
window: single validated realtime START (`--realtime-start-retries 0`), followed
by debug probe command `0301` after 8 seconds, with auto-capture stopped at the
first ready HRV window. It writes the live device transcript, pulled WHOOP CSV,
and `WHOOP_CAPTURE_MANIFEST.txt` under `docs/evidence/gate-b/<run-label>/`.
That bundle is still only the WHOOP side; add the matched external RR/IBI export
and run `gate_b_reference.sh` before calling Gate B complete.

The helper builds, installs, and launches the app on adidshaft's physical iPhone with
`devicectl --console`, then streams `ATRIADBG` while the capture is performed on
device. `--auto-capture` passes a debug launch argument that starts Capture
without tapping the UI; `--stop-when-ready` stops that capture at the first
ready HRV window so the transcript includes `ATRIADBG capture_summary ready=1`.
`--auto-stop-after N` stops and saves the capture after N seconds even if HRV is
still learning, so timeout runs preserve a CSV and `capture_summary ready=0`
instead of only a live transcript.
Operator-facing launchers prefer `ATRIA_DEVICE_ID`, `ATRIA_LIVE_DEBUG_SECONDS`,
`ATRIA_LIVE_DEBUG_LOG`, `ATRIA_REFERENCE_HANDOFF_SECONDS`, and
`ATRIA_REFERENCE_VALIDATE_SECONDS`; legacy `WHOOP_*` variables still work for
old scripts and evidence replay.
RR export timestamps are reconstructed from the realtime frame's decoded RR
payload so multi-RR frames do not produce duplicate `elapsed_ms` rows. If iOS
delivery jitter or frame ordering still collapses two exported RR rows onto the
same millisecond, the app bumps only the exported RR timestamp by 1 ms; RR
values and clinical readiness math are not changed.
Normal user launches still require manual Capture control. `--log auto` saves
the transcript under `logs/live-device/` for later Gate B triage. That directory
is git-ignored runtime output; preserve a specific transcript by copying it into
`docs/evidence/gate-b/` when it belongs with a reference capture. `--until-ready`
exits successfully only after `ATRIADBG hrv ... ready=1` or
`ATRIADBG capture_summary ready=1`, which is the on-device proof that the
5-minute window became validation-ready. For a short smoke check, use
`./live_device_debug.sh --until-realtime --seconds 45 --log auto`; that exits
after the first `61080005` realtime frame and prints a summary of the notify,
command-response, and realtime-frame flags.
When `--pull-capture DIR` is present and the app logs `ATRIADBG capture_file`,
the helper copies the saved WHOOP CSV from the app data container into `DIR`.
Use that pulled CSV as the WHOOP input to `gate_b_reference.sh`.

For command-policy comparisons, pass `--realtime-start-retries N`. The app
default is `6`, matching the retry behavior used while diagnosing delayed RR
startup. `--realtime-start-retries 0` sends only the initial validated START
after `61080005` notify/settle, then observes the stream without additional
START writes.
For a follow-up zero-RR continuity experiment, pass
`--realtime-restart-zero-rr-seconds N`. The app leaves this off by default; when
enabled, it waits until at least one RR-bearing realtime frame has arrived, then
sends STOP followed by START if subsequent realtime frames carry `rrnum=0` for
`N` seconds. Treat this as a command-policy diagnostic until a physical iPhone
comparison proves it improves clean 5-minute RR continuity.
For a less disruptive command-policy comparison, pass
`--realtime-reassert-zero-rr-seconds N`. This waits until at least one
RR-bearing realtime frame has arrived, then sends START only if subsequent
realtime frames carry `rrnum=0` for `N` seconds. Treat it as diagnostic evidence;
it must not be enabled by default unless physical-iPhone evidence proves it
improves clean 5-minute RR continuity.

When realtime frames contain RR intervals, the app logs compact decode lines:

```text
ATRIADBG rr hr=<bpm> rrnum=<declared> decoded=<count> total_decoded=<session_count> truncated=<0|1> hr_mismatch=<count> implied_bpm=<bpm,...> values=<rr_ms,...>
```

Use these lines with `ATRIADBG hrv ... reason=confidence` to decide whether a
failed readiness run was caused by sparse/truncated realtime payloads or by
artifact rejection of decoded RR values. The helper summary repeats this as
`rr_frames`, `rr_values`, `rr_truncated_frames`, `rr_hr_mismatch_values`,
`last_rr_values`, and `last_rr_implied_bpm`. It also decodes each logged
`61080005` frame's realtime payload and reports `realtime_frames`,
`realtime_rr_frames`, `realtime_rr_zero_frames`, `realtime_malformed_frames`,
`realtime_truncated_rr_frames`, `last_realtime_hr`, and `last_realtime_rrnum`.
Use those counters to distinguish a BLE/frame dropout from a connected realtime
stream whose payloads carry `rrnum=0`. The helper also reports
`first_realtime_elapsed_s`, `first_rr_elapsed_s`, `rr_start_delay_s`,
`last_rr_elapsed_s`, and `max_rr_log_gap_s` so unattended runs can separate
delayed RR startup from long RR-bearing-frame dropouts. `hr_mismatch` is
diagnostic only:
it counts decoded RR intervals whose implied BPM differs from the frame HR by
more than 30 bpm, so obvious payload artifacts can be inspected without changing
the clinical correction contract. The helper also summarizes HRV-window sparsity
as `hrv_max_rr_gap_s` (largest observed rolling-window RR gap during the run)
and `last_hrv_max_rr_gap_s` (the final HRV snapshot's gap).

If the physical iPhone keeps timing out with steady realtime frames and long RR
gaps, force-quit the iOS app and run the Mac probe:

```bash
./force_quit_ios_app.sh
.venv/bin/python probe.py --start-only-seconds 180
```

The probe's `WHOOP_PROBE_SUMMARY` reports `realtime_frames`, `rr_frames`,
`rr_zero_frames`, `rr_values`, first/last RR timing, and `max_rr_log_gap_s` so
alternate command tests can be compared against the same continuity evidence.
If the probe fails with CoreBluetooth `CBErrorDomain Code=14` / "Peer removed
pairing information", treat the Mac path as blocked by stale macOS pairing state
and keep the cabled iPhone evidence authoritative until that pairing state is
repaired.

The cabled iPhone helper also preserves command-response status details in
`ATRIADBG_SUMMARY`: `cmd_response_count`, `cmd_response_last_seq`,
`cmd_response_last_cmd`, `cmd_response_last_status`, and
`cmd_response_statuses`. Use those fields when comparing START, STOP, reassert,
probe-command, and sniffer-derived command experiments. Existing logs can be
re-summarized without touching the phone:

```bash
./live_device_debug.sh --replay-log logs/live-device/<run>.log --no-build
```

For Gate B continuity experiments, the primary decision variable is the fraction
of `61080005` realtime frames whose decoded `rrnum >= 1`. EXP-1
(`docs/evidence/gate-b/20260612T-exp1-full-realtime-payload-60s/README.md`)
verified that the previous `ATRIADBG frame` line was truncated, but the decoder
was not hiding RR intervals: zero-RR frames carried only zero RR slots plus a
fixed trailer, with `0` valid 300-2000 ms tail candidates. The 60-second still
run measured `realtime_rr_fraction=0.361`, below the `>=0.900` Gate-B-ready bar.
EXP-2 is iPhone-only realtime-parameter sweep, not START retry or STOP/START
policy: send `0302`, `0303`, `030101`, and bare `03` one at a time, 30 seconds
apart, then compare per-segment `segment_N_rr_fraction` and command responses.
Success means the RR-frame fraction jumps near sustained 1/s over a 60-second
still window.

EXP-3 is iPhone-only opcode discovery. Send raw one-byte opcodes `06`, `07`,
`08`, `09`, `0a`, `10`, and `11` as `--probe-sweep` entries after the validated
START. The app frames each as `[0x23, seq, OP]`. Catalog the `61080003`
command response for each segment plus any new `61080004`/`61080005` traffic
using `segment_N_frame_61080004_count`, `segment_N_frame_61080005_count`,
`segment_N_frame_61080004_types`, and `segment_N_frame_61080005_types`.
The physical-iPhone run in
`docs/evidence/gate-b/20260612T-exp3-opcode-discovery/README.md` found no
new `61080004`/`61080005` payload family and no continuity win: overall
`realtime_rr_fraction=0.190`, best segment `11` at `36.4%`, and
`max_rr_log_gap_s=68.3`.
EXP-4 historical-download probing on iPhone must treat `0x2f` frames on
`61080004` as the success signal and must not decode stored RR unless such
frames are actually present. The physical-iPhone run in
`docs/evidence/gate-b/20260612T-exp4-historical-06-sweep/README.md` tested
`06`, `0600`, `0601`, `060100`, `06000000`, and `06010000`; `0600` and `0601`
ACKed with long `0x06` responses, but `historical_2f_frames=0`, so no stored RR
window was available.

EXP-4b extended the cabled-iPhone `0x06` selector sweep to `0600` through
`0607` in
`docs/evidence/gate-b/20260612T-exp4b-historical-06-param-sweep/README.md`.
It still found no historical download payloads (`historical_2f_frames=0`), but
it found a strong live-continuity signal: `0605` produced a 30-second segment at
`100.0%` RR-bearing realtime frames, `0606` produced `96.8%`, and `0607`
produced `92.4%`. The whole sweep is not Gate-B-ready because the initial sparse
period left `max_rr_log_gap_s=99.0`, so HRV correctly remained `learning`. The
next iPhone-only Gate B experiment should validate one selected `0x06` selector,
starting with `0605`, over a clean 300-second still window before sniffer
escalation.

The isolated `0605` validation in
`docs/evidence/gate-b/20260612T-gate-b-0605-clean-300s/README.md` did not
reproduce the EXP-4b continuity win over a full capture. It ACKed, produced some
RR, then fell into long zero-RR stretches: `segment_1_rr_fraction=0.298`,
`realtime_rr_fraction=0.293`, `max_rr_log_gap_s=73.0`, and
`capture_summary ready=0 ... reason=gap`. The saved capture remained
`learning`, as required. Do not treat isolated `0605` as a Gate B fix. Next
iPhone-only options are isolated `0606`/`0607` validation or a
sequence-preservation test that sends the `0600` through `0605` warm-up before
starting the 300-second measurement window.

The isolated `0606` validation in
`docs/evidence/gate-b/20260612T-gate-b-0606-clean-300s/README.md` also failed
the clean-window bar. It improved the probe-segment RR fraction to `52.7%`, but
still logged `max_rr_log_gap_s=87.5` and saved
`capture_summary ready=0 ... reason=gap`. This makes the ordered selector
sequence the stronger next iPhone-only hypothesis: reproduce the `0600` through
`0605` warm-up from EXP-4b, then start measuring only after the high-continuity
state appears.

The isolated `0607` validation in
`docs/evidence/gate-b/20260612T-gate-b-0607-clean-300s/README.md` also failed
the clean-window bar. It produced `segment_1_rr_fraction=0.584`
(`58.4%`) and `max_rr_log_gap_s=51.0`; the timeout capture saved
`capture_summary ready=0 ... rmssd=learning`. This closes the isolated
`0605`/`0606`/`0607` branch. The remaining iPhone-only continuity hypothesis is
stateful ordering: run the `0600` through `0605` selector warm-up and start the
300-second measurement only after the candidate high-continuity state appears.

The delayed-capture ordered `0600` through `0605` validation in
`docs/evidence/gate-b/20260612T-gate-b-ordered-0600-0605-delayed-300s/README.md`
also failed the clean-window bar. Capture started after the full warm-up, then
timed out with `capture_summary ready=0 ... raw=94 kept=84 conf=89 window=300
max_rr_gap_s=132.6 reason=gap rmssd=learning`. Segment evidence matters:
`0600` was `100.0%`, `0601` was `83.9%`, `0602` fell to `41.9%`, `0603` was
`0.0%`, `0604` was `16.1%`, and the final `0605` state was only `24.1%`.
There were still no historical `0x2f` frames. The ordered full sequence is not a
fix; if staying on iPhone before sniffer escalation, test only the early selector
state (`0600` alone, or `0600,0601`) with delayed capture.

If the cabled iPhone path keeps showing steady realtime frames with long
`rrnum=0` stretches after EXP-2 through EXP-4, Gate B requires protocol evidence
before new metric work. Do not loosen the 3-second RR-gap gate, the 75%
confidence gate, or the artifact rules to make a timeout look like HRV.

As of `docs/evidence/gate-b/20260612T1600Z-protocol-decision-sniffer-or-repaired-mac.md`,
single START, STOP→START zero-RR restarts, and START-only zero-RR reasserts have
all been rejected as sufficient Gate B continuity fixes on the physical iPhone.
Current steering keeps Gate B work on the cabled iPhone channel and explicitly
does not repair the Mac probe. After EXP-4b and the failed isolated
`0605`/`0606`/`0607` validations plus the failed ordered `0600`-through-`0605`
delayed capture, the immediate next step is no longer broad START-policy
iteration or full-sequence probing. The only remaining low-cost iPhone lead is
the early-selector state (`0600`, maybe `0600,0601`); otherwise Gate B needs
sniffer evidence. Until continuity is proven, HRV-dependent product surfaces
must remain `learning` or explicitly fallback-labeled.

For CSV sniffer exports that include timestamp, direction, characteristic/UUID,
and byte-payload columns, summarize the trace before comparing protocol paths:

```bash
./summarize_sniffer_trace.py official-whoop-trace.csv \
  --output docs/evidence/gate-b/<run-label>/sniffer-summary.md
```

The summarizer decodes WHOOP command writes, command responses, realtime frames,
zero-RR realtime frames, and RR-bearing realtime frames using `whoop_codec.py`.
It is protocol evidence only; Gate B still requires a physical-iPhone clean
5-minute RR window and external RR/IBI reference validation.

Current physical-device evidence:

- `docs/evidence/gate-b/20260612T140338Z-probe-command-ready-window.md`
  records the first validation-ready 5-minute iPhone HRV window. The app sent
  START, sent debug probe command `0x03 0x01` after 8 seconds, and logged
  `capture_summary ready=1 elapsed=315 raw=320 kept=294 conf=92 window=300
  max_rr_gap_s=2.1 rmssd=44.2`. This proves the on-device HRV readiness path
  can complete, but it is not the Gate B exit until matched against an external
  RR/IBI reference.
- `docs/evidence/gate-b/20260612T141523Z-auto-capture-file-pull.md` records a
  physical-iPhone ready auto-capture that wrote a CSV under
  `Documents/whoop-captures/` and verified the saved CSV can be pulled from the
  app data container with `devicectl`. This makes the WHOOP side of the matched
  reference capture reproducible, but it is not the Gate B exit without the
  external RR/IBI reference.
- `docs/evidence/gate-b/20260612T1443Z-auto-stop-timeout-csv.md` records a
  physical-iPhone debug auto-capture with `--auto-stop-after 45`. The app stopped
  and saved a `...-learning.csv` even though no clean RR window was present, and
  the helper pulled that CSV from the app data container. This verifies timeout
  evidence preservation, not Gate B HRV accuracy.
- `docs/evidence/gate-b/20260612T1459Z-full-wrapper-autostop-timeout.md`
  records a full physical-iPhone Gate B wrapper attempt with `--auto-stop-after
  715`. The app decoded `384` RR values across `311` RR-bearing realtime frames
  and pulled a 2249-row `...-learning.csv`, but the capture ended with
  `ready=0 reason=window max_rr_gap_s=99.0` and the validator rejected duplicate
  RR timestamps. This is not a Gate B exit.
- `docs/evidence/gate-b/20260612T1506Z-monotonic-rr-export-smoke.md` records the
  physical-iPhone smoke after the RR export timestamp fix. The app decoded
  multi-RR realtime frames, pulled a 304-row `...-learning.csv`, and the
  validator advanced past timestamp ordering to the expected short-run failures:
  `WHOOP coverage 41s < 300s` and `WHOOP corrected beats 51 < 240`. A direct
  scan found `rr_rows=54 min_delta_ms=115 nonmonotonic_examples=[]`. This fixes
  the export blocker but is not a Gate B exit.
- `docs/evidence/gate-b/20260612T1523Z-post-export-full-wrapper-timeout.md`
  records a full physical-iPhone Gate B wrapper attempt after the monotonic RR
  export fix. The pulled CSV had `rr_rows=370 min_delta_ms=1
  nonmonotonic_examples=[]`, but the run ended with `ready=0 reason=window
  max_rr_gap_s=57.0`; the validator failed on `WHOOP max RR gap 57.0s > 3.0s`
  and `WHOOP corrected beats 163 < 240`. This confirms the remaining blocker is
  realtime RR continuity, not CSV export ordering.
- `docs/evidence/gate-b/20260612T1538Z-zero-rr-restart-45-timeout.md` records a
  full physical-iPhone command-policy comparison with
  `--realtime-restart-zero-rr-seconds 45`. The app fired `7` STOP-then-START
  restarts after post-RR zero-RR stretches and received command responses, but
  decoded only `277` RR values while `523 / 744` realtime frames still carried
  `rrnum=0`. The final validator window regressed to `kept=9`, `conf=11%`, and
  `max_rr_gap_s=66.1`, so the 45-second restart policy is rejected as a Gate B
  continuity improvement. This is not a Gate B exit.
- `docs/evidence/gate-b/20260612T1554Z-start-reassert-zero-rr-45-timeout.md`
  records the corresponding START-only reassert comparison with
  `--realtime-reassert-zero-rr-seconds 45`. The app fired `6` START-only
  reasserts after post-RR zero-RR stretches and received command responses, but
  decoded only `290` RR values while `516 / 744` realtime frames still carried
  `rrnum=0`. The final validator window reached `conf=78%` but still failed
  with `max_rr_gap_s=113.4` and only `87` corrected beats, so START-only
  reasserts are also rejected as a Gate B continuity fix. This is not a Gate B
  exit.
- `docs/evidence/gate-b/20260612T1556Z-mac-probe-pairing-still-blocked-after-reassert.md`
  records a fresh Mac probe recheck after force-quitting the iOS app. The app was
  already not running, but `probe.py --start-only-seconds 180` still failed
  before subscription with CoreBluetooth `CBErrorDomain Code=14` / "Peer removed
  pairing information" and zero frames. Mac opcode experiments remain blocked
  until macOS BLE pairing state is repaired.
- `docs/evidence/gate-b/20260612T1600Z-protocol-decision-sniffer-or-repaired-mac.md`
  records the current Gate B protocol decision. The app can decode RR bursts and
  export honest `learning` evidence, but the WHOOP-side stream is not
  reproducibly continuous enough for clinical 5-minute HRV. Gate B should now
  progress through repaired Mac opcode probing or a BLE sniffer trace of the
  official app's continuous-RR request path; do not loosen validation thresholds
  or show numeric HRV from failed captures.
- `docs/evidence/gate-b/20260612T105336Z-until-ready-timeout.md` records an
  until-ready attempt on adidshaft's iPhone where realtime stayed connected and the
  HRV window reached 300 seconds, but confidence fell to 64-68%. The app
  correctly kept RMSSD, SDNN, pNN50, lnRMSSD, and respiratory rate as
  `learning`; this is not a Gate B exit.
- `docs/evidence/gate-b/20260612T111503Z-until-ready-rr-summary.md` records a
  follow-up until-ready attempt on adidshaft's iPhone where realtime produced `238`
  decoded RR values across `222` RR-bearing frames with no truncation. The app
  reached a 300-second window but stayed `learning` with `reason=beats` because
  only `89` corrected beats were available; this is not a Gate B exit.
- `docs/evidence/gate-b/20260612T114856Z-auto-capture-timeout.md` records the
  first unattended auto-capture until-ready attempt on adidshaft's iPhone. Auto-capture
  started, realtime stayed connected, and the app decoded `204` RR values, but
  RR-bearing payloads began about 241 seconds after launch; the final HRV
  snapshot therefore had only a 149-second window and correctly stayed
  `learning` with `reason=window`. This is not a Gate B exit, and the unattended
  reference run should allow at least 720 seconds.
- `docs/evidence/gate-b/20260612T115809Z-720s-auto-capture-timeout.md` records a
  720-second unattended auto-capture attempt on adidshaft's iPhone. Auto-capture,
  realtime START, command response, `61080005` frames, and RR decoding all worked,
  but the run still timed out without a ready HRV row. The app decoded `473` RR
  values and observed a worst rolling-window RR gap of `100.0` seconds; the best
  cited full-window snapshot kept only `181` beats, so the app correctly stayed
  `learning` with `reason=beats`. This is not a Gate B exit.
- `docs/evidence/gate-b/20260612T121602Z-gap-gate-smoke.md` records the physical
  iPhone smoke for the stricter on-device gap gate. The app built, installed, and
  launched on the phone, decoded `68` RR values, observed a `53.8` second
  RR-bearing-log gap, and kept all clinical metrics `learning`. This is not a
  Gate B exit because it was a short smoke rather than a 300-second validation
  window with reference comparison.
- `docs/evidence/gate-b/20260612T122202Z-gap-gated-until-ready-timeout.md`
  records a 720-second until-ready attempt on adidshaft's iPhone with the stricter
  gap gate installed. The app decoded `212` RR values, reached full 300-second
  HRV windows, and observed raw RR gaps up to `151.0` seconds while realtime
  frames continued. The app correctly logged `ready=0 reason=gap` and kept all
  clinical metrics `learning`. This is not a Gate B exit.
- `docs/evidence/gate-b/20260612T1237Z-mac-probe-pairing-blocked.md` records a
  Mac-side continuity probe attempt that found the target strap but failed before
  subscription with CoreBluetooth `CBErrorDomain Code=14` / "Peer removed pairing
  information". This blocks Mac opcode experiments until macOS BLE pairing state
  is repaired; it is not a Gate B exit.
- `docs/evidence/gate-b/20260612T1350Z-mac-probe-pairing-still-blocked.md`
  records a repeated Mac-side probe after the iPhone restart experiments. The
  probe again failed before subscription with CoreBluetooth `CBErrorDomain
  Code=14` / "Peer removed pairing information" and emitted a structured
  `WHOOP_PROBE_SUMMARY` with zero frames. Mac opcode experiments remain blocked
  until macOS BLE pairing state is repaired or a sniffer trace is collected.
- `docs/evidence/gate-b/20260612T1400Z-force-quit-helper-mac-probe-blocked.md`
  records physical iPhone verification of `force_quit_ios_app.sh`: the helper
  found and terminated the running app by PID, then confirmed it was not running.
  A clean-prep Mac probe still failed with CoreBluetooth `CBErrorDomain Code=14`
  and zero frames, so macOS BLE pairing state remains the blocker.
- `docs/evidence/gate-b/20260612T124229Z-rrnum0-until-ready-timeout.md` records a
  720-second until-ready attempt on adidshaft's iPhone with realtime payload counters
  enabled. The app received `744` realtime `61080005` frames and decoded `144`
  RR values from `119` RR-bearing frames, but `625` realtime frames carried
  `rrnum=0` and raw RR gaps reached `246.2` seconds. The app correctly kept all
  clinical metrics `learning`; this is not a Gate B exit.
- `docs/evidence/gate-b/20260612T130203Z-single-start-240s.md` records a
  240-second physical iPhone command-policy comparison using
  `--realtime-start-retries 0`. The app logged `start_retries=0`, sent the
  initial START once, received command response and realtime frames, and decoded
  `63` RR values from `50` RR-bearing frames while `194 / 244` realtime frames
  carried `rrnum=0`. This is not a Gate B exit, but it verifies the single-START
  diagnostic path and justifies a full 720-second single-START comparison.
- `docs/evidence/gate-b/20260612T130844Z-single-start-until-ready-timeout.md`
  records that full 720-second single-START comparison on adidshaft's iPhone. The app
  logged `start_retries=0`, decoded `345` RR values from `264` RR-bearing
  realtime frames, and improved RR density versus the retrying baseline, but
  `479 / 743` realtime frames still carried `rrnum=0` and raw RR gaps reached
  `189.4` seconds. The app correctly kept all clinical metrics `learning`; this
  is not a Gate B exit.
- `docs/evidence/gate-b/20260612T132956Z-zero-rr-restart-360s.md` records a
  360-second physical iPhone diagnostic with `--realtime-start-retries 0` and
  `--realtime-restart-zero-rr-seconds 20`. The app logged
  `restart_zero_rr_s=20.0`, fired `10` STOP-then-START restarts after post-RR
  zero-RR stretches, and received command responses, but decoded only `63` RR
  values while `317 / 365` realtime frames still carried `rrnum=0`. The app
  correctly kept all clinical metrics `learning`; this is not a Gate B exit.
- `docs/evidence/gate-b/20260612T133819Z-zero-rr-restart-60s-timeout.md`
  records the full 720-second physical iPhone comparison with
  `--realtime-restart-zero-rr-seconds 60`. The restart policy fired `2` times
  and slightly improved RR density versus single START (`361` decoded RR values
  from `304` RR-bearing frames), but `439 / 743` realtime frames still carried
  `rrnum=0`, raw RR gaps reached `68.3` seconds, and the run timed out without a
  ready HRV row. The app correctly kept all clinical metrics `learning`; this
  is not a Gate B exit.

The WHOOP CSV contains:

```text
elapsed_ms,kind,source,opcode,len,label,value
```

Rows with `kind=rr` are raw decoded realtime RR intervals in milliseconds,
including values that the analyzer later rejects. Each fresh capture starts with
a `kind=capture_meta` provenance row containing `started_at_utc`, app bundle,
iOS version, phone model, strap display name, and label. It is followed by a
second `kind=capture_meta` row containing
`schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw`,
which identifies the exact drop/outlier/interpolation correction and confidence
contract. The schema/correction row must remain the final metadata row so stale
or mismatched exports fail validation. Rows with `kind=hrv` are analyzer
snapshots for audit/debugging. While recording, the app writes every HRV
snapshot to CSV with a `reason` token (`window`, `gap`, `beats`, `confidence`,
or `ready`), but clinical metric fields remain `learning` until `ready=1`; the
first ready snapshot is the first point where RMSSD, SDNN, pNN50, lnRMSSD, and
respiratory rate can appear numerically. A full five-minute window with
`reason=confidence` means the app had enough elapsed time but rejected too many
RR intervals to meet the 75% confidence gate. The validator records the set of
seen readiness reasons in its JSON report and rejects malformed values; new app
exports must use only `window`, `gap`, `beats`, `confidence`, or `ready`.
Each HRV snapshot also records `max_rr_gap_s`, the largest timestamp gap between
decoded RR samples in the current rolling window. The on-device readiness gate
requires `max_rr_gap_s <= 3.0`, matching the offline validator's final-window gap
threshold, and the ready app HRV row plus stopped capture summary must
replay-match `max_rr_gap_s` within 1 second.
That preserves the exact ready-state RMSSD that was shown on-device. The final
`kind=capture_summary` row records whether the stopped capture was
validation-ready and repeats the final raw/kept/confidence counts, final
readiness reason, largest RR gap, the two artifact-rejection counters, and
interpolation count.
When `ready=0`, the summary
records RMSSD, SDNN, pNN50, lnRMSSD, and respiratory rate as `learning` instead
of exporting derived numbers from an insufficient or aborted window. A `ready=1`
summary carries replay-checkable numeric HRV metrics; respiratory rate may still
remain `learning` if the RSA estimator cannot identify a trustworthy peak.
Reference-mode validation requires both the ready `kind=hrv` snapshot and the
stopped `capture_summary` to include `resp`, either numeric or `learning`, so the
RSA gate is explicit in the evidence. Numeric respiratory rates must be inside
the app estimator's inclusive 6-30 breaths/minute search band; otherwise the
capture is rejected instead of reporting an impossible RSA value.
Malformed respiratory tokens such as `resp=fast` are rejected as missing
respiratory status; the only non-numeric value allowed in evidence is
`resp=learning`. The stopped summary must also match the ready HRV row's
respiratory status. If both rows are numeric, their respiratory rates must agree
within 0.05 breaths/minute.
Fresh schema-2 exports use `lnrmssd` for lnRMSSD. The validator still accepts
legacy `ln` rows from earlier local captures, but new evidence should use the
explicit `lnrmssd` key. When a legacy `ln` row is parsed, the JSON report also
includes a normalized `lnrmssd` field so clinical audit paths stay stable.

WHOOP `kind=rr` rows must have parseable numeric `elapsed_ms` and `value`
fields. The validator fails malformed RR rows instead of dropping them, because
silently removing beats would inflate confidence and distort the final RMSSD
comparison.

Rejected RR intervals stay in the raw `kind=rr` stream and are excluded by the
correction pass. Interior rejected gaps with accepted RR intervals on both sides
are linearly interpolated for metric continuity; interpolation does not increase
the kept count or confidence. In the app tachogram, accepted and interpolated
samples draw the line while rejected artifacts appear as orange points for
on-device review.

During recording, the Capture card shows recording elapsed time, corrected RR
kept/raw, rejection counts, interpolation count, confidence, HRV window length,
and a compact readiness checklist for contact, window duration, largest RR gap,
corrected beats, confidence, artifacts, interpolation, and final ready/learning
state. Do not use the export as Gate B evidence until the **HRV** window reaches
300 seconds, the card says the 5-minute window is ready, and the stopped summary says
**Validation-ready**.
The offline validator also rejects final-window RR streams with any raw
timestamp gap over 3 seconds, because a silent packet/reference dropout can make
confidence look cleaner than the physiology actually was.

Starting Capture resets the app's RR analyzer, so the on-screen HRV readiness and
the exported `kind=rr` rows are the same self-contained validation window.
The app also requires at least 10 seconds of stable skin contact before it starts
feeding RR intervals into HRV or exporting validation `kind=rr` rows. The first
post-stability beat opens a fresh clean window and writes
`hrv_quality=clean_rr_window_started`; subsequent RR rows are the same beats used
by the app analyzer. Contact loss resets the HRV window and writes an
`hrv_quality` row to the capture CSV.
The offline validator requires this clean-window marker for schema-2 captures;
exports without it, or with the marker timestamped after the first RR row, are
stale and must be recaptured with the current iOS app.
The marker's `elapsed_ms` must be parseable and finite.

## Replay

WHOOP-only replay:

```bash
./validate_hrv.py path/to/whoop-capture.csv
```

Learning-token smoke test:

```bash
./test_validate_hrv_learning.sh
```

This synthetic test proves that `ready=0` exports with `learning` clinical metric
fields can still replay RR rows in WHOOP-only mode, but cannot satisfy reference
mode or the Gate B accuracy exit. It also proves a `ready=1` HRV capture can pass
reference mode while respiratory rate remains `learning`, because respiratory
rate has its own RSA confidence gate.

Gate B wrapper smoke test:

```bash
./test_gate_b_reference_wrapper.sh
```

This synthetic test runs the evidence wrapper against a validation-ready
5-minute fixture, then verifies the retained `validator.log`, manifest summary
fields, terminal summary, JSON report, and checksum list. It removes its
synthetic evidence directory when it exits, so committed evidence remains limited
to real device/reference attempts.

WHOOP vs reference:

```bash
./validate_hrv.py path/to/whoop-capture.csv --reference path/to/reference-rr.csv
```

Gate B evidence report:

```bash
./gate_b_reference.sh path/to/whoop-capture.csv path/to/reference-rr.csv 20260612-h10
```

The wrapper copies both source CSVs into `docs/evidence/gate-b/<run-label>/`,
runs `validate_hrv.py` against those copies, writes the JSON artifact to
`docs/evidence/gate-b/<run-label>/report.json`, and preserves the validator
terminal transcript as `validator.log`. Use a label that identifies the reference
device/session, such as `20260612-h10`. The wrapper refuses to overwrite a
non-empty evidence directory; choose a new label for each attempt. It also writes
`MANIFEST.txt` with the UTC timestamp, run label, git commit, validator command,
validator file hash, validator exit code, stable `validator_exit_reason`, host
details, source paths, final WHOOP `capture_meta` / `capture_summary` values,
and the reference RR/time column interpretation. It repeats the parsed WHOOP capture
context (`started_at_utc`, app bundle, iOS version, phone model, strap display
name, label), the enforced capture contract, the JSON report status, and, when
present, the failure reason. It also repeats the validation thresholds used for
the run: RMSSD tolerance, app replay tolerance, minimum duration, minimum
corrected beats, minimum confidence, maximum RR gap, maximum final-window
alignment delta, and the reference tolerances for SDNN, pNN50, and lnRMSSD.
For failed runs, structured JSON failure lists such as readiness failures and
alignment failures are mirrored into `report_failures` and
`report_alignment_failures`.
When the JSON report includes a reference
comparison, the manifest also repeats the WHOOP/reference RMSSD values,
WHOOP/reference confidence percentages, total raw counts/durations, raw and
corrected final-window durations, the clean-RR marker value/timestamp/order
check, stopped-summary elapsed/window/max-gap check, `delta_rmssd_ms`,
`delta_sdnn_ms`, `delta_pnn50_pct`, `delta_lnrmssd`, app/summary replay
max-gap deltas, and per-metric tolerance booleans so the pass-critical Gate B
values are visible without opening JSON. The wrapper also prints a concise
terminal summary with status, failure reason, RMSSD delta, non-RMSSD clinical
deltas, app/summary replay gap deltas, confidence, respiratory status,
reference import provenance, total durations, window durations, gap checks,
clean-RR marker timing, stopped-summary timing, alignment deltas, and artifact paths. It then hashes the retained CSVs, report,
validator log, and manifest in
`SHA256SUMS`. Failed validation attempts still keep their manifest and checksums
so the evidence trail is auditable instead of disappearing at the first failing
gate.

Reference CSVs can use one of these RR column names: `rr_ms`, `rr`, `ibi`,
`ibi_ms`, or `interval_ms`. Optional time columns: `elapsed_ms`, `time_s`,
`seconds`, or `t`. When a time column is present, RR timestamps must be
strictly increasing; duplicate or out-of-order samples invalidate the capture
because interpolation and final-window trimming depend on sample order. Reference
files without a time column are treated as sequential RR intervals and get a
cumulative timeline from the intervals themselves. Reference RR and timestamp
values must be parseable finite numbers; malformed, `NaN`, or infinite values
fail validation instead of being ignored. Reference files missing an RR/IBI
column also fail validation with a JSON report and manifest instead of aborting
the evidence wrapper. The JSON report records
`reference_metadata` with the selected RR column, selected time column,
`timeline_source` (`timestamp_column` or `derived_from_rr`), and interpreted time
unit so imports from different reference devices remain auditable. The wrapper
mirrors `reference_timeline_source` into `MANIFEST.txt`.

Before comparing against the reference, the validator trims both recordings to
the final validation window, which defaults to 300 seconds. Longer recordings are
allowed, but only the trailing 5-minute window is used for correction, app
snapshot replay, stopped-summary checks, and WHOOP-vs-reference HRV metric
deltas. The JSON report keeps total-capture duration separately for audit and
records raw/corrected final-window start and end times so failed reference
comparisons can be inspected for window alignment. Passing reference reports
also include `window_alignment`, which repeats the WHOOP/reference final-window
start/end seconds and their absolute deltas. Reference mode fails when either
delta exceeds the alignment threshold, which defaults to 3 seconds, because a
time-offset reference segment can make unrelated physiology look accurate.

The validator also checks any exported ready `kind=hrv` snapshot against the
replayed final-window `kind=rr` rows for RMSSD, SDNN, pNN50, and lnRMSSD. A
mismatch means the app and offline replay are not computing the same metrics from
the same capture, so the file cannot be used for the clinical accuracy gate. Any
ready app snapshot must also carry replay-matching raw RR count, kept RR count,
confidence, HRV window duration, largest RR gap, rejection counters for
out-of-range and delta-over-20-percent RR artifacts, plus the interpolation
count. Reference mode also requires a final `kind=capture_summary` row with
`ready=1` and replay-matching raw/kept/confidence/window, largest RR gap,
rejection, and interpolation counters. The summary must include `elapsed`, and
elapsed recording time must be at least as long as both the validation threshold
and the reported HRV window.
Missing, implausibly short, or unready summary rows mean the iOS capture was not
stopped as validation-ready.

Readiness uses final-window coverage, not the first-to-last timestamp span inside
the retained samples. RR packets arrive at discrete beat times, so a true
300-second capture can have a final sample span of 299.x seconds depending on
where the last beat lands. The app and validator both require 300 seconds of
continuous capture coverage while computing metrics only from samples in the
final 300-second window.

## Rules

- Keep RR intervals from **300–2000 ms**.
- Drop beats where `abs(RRn - RRn-1) / RRn-1 > 20%`.
- Linearly interpolate interior rejected gaps for HRV metrics while keeping
  confidence equal to accepted RR intervals divided by raw RR intervals.
- Require a `capture_meta` row with
  `schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw`;
  older or mismatched exports are stale and must be recaptured.
- Require an `hrv_quality` row whose value is `clean_rr_window_started` before
  trusting exported RR rows as the same clean window analyzed on device; the
  marker's `elapsed_ms` must be at or before the first exported RR row.
- Use the final 300-second validation window for WHOOP and reference metrics.
- Require strictly increasing WHOOP and reference RR timestamps before trimming
  the final window.
- Fail malformed or non-finite WHOOP/reference RR rows instead of silently
  dropping samples.
- Require 300 seconds of continuous final-window coverage.
- Require at least 240 corrected beats and at least 75% RR confidence for both
  WHOOP and reference windows.
- Require no raw RR timestamp gap over 3 seconds in either final window.
- Require WHOOP and reference final-window start/end timestamps to align within
  3 seconds by default.
- Require the app-side HRV window to start after stable skin contact; contact
  loss during capture means the HRV window restarts and the capture remains
  learning until it earns a fresh 5-minute window.
- Require the app's exported ready RMSSD/SDNN/pNN50/lnRMSSD to match offline
  replay within 0.6 tolerance before trusting a reference comparison.
- Require the app's exported ready raw/kept/confidence/window/max-gap fields to
  match offline replay before trusting a reference comparison.
- Require the ready app HRV snapshot and stopped summary to carry respiratory
  status as `resp=<number>` or `resp=learning`.
- Require numeric `resp` values to be within the inclusive 6-30 breaths/minute
  RSA search band.
- Reject malformed `resp` values; only numeric values or `resp=learning` are
  valid Gate B evidence.
- Require the stopped `capture_summary` respiratory status to match the ready
  HRV row, with numeric rates agreeing within 0.05 breaths/minute.
  Numeric summary drift above that threshold fails even when both rows are in
  the valid 6-30 breaths/minute range.
- Require the stopped iOS capture summary to be `ready=1`, with
  raw/kept/confidence/window, rejection counters, interpolation count, and HRV
  metrics agreeing with final-window replay, plus elapsed time at least as long
  as the validation window. The test suite covers both missing `elapsed` and
  too-short `elapsed` as hard failures.
- Require the stopped summary row to occur at or after the ready HRV row in the
  exported timeline, proving the summary is not stale relative to the metrics.
- Require the stopped summary row to occur at or after the final WHOOP RR row,
  proving no later RR samples were exported after the terminal summary.
- Require the stopped summary row to occur at or after the final HRV analyzer
  row, proving no later analyzer state was exported after the terminal summary.
- Report WHOOP-vs-reference deltas for RMSSD, SDNN, pNN50, and lnRMSSD in the
  JSON artifact for clinical review.
- Pass the accuracy gate only when WHOOP RMSSD differs from reference RMSSD by
  **≤5 ms**, SDNN differs by **≤5 ms**, pNN50 differs by **≤5 percentage
  points**, and lnRMSSD differs by **≤0.2**.

When `--report` is supplied, the validator writes a JSON artifact with the input
paths, thresholds, WHOOP/reference metrics, app-vs-replay metric deltas,
WHOOP-vs-reference metric deltas, rejection counts, interpolation counts, and
final pass/fail status. The report keeps all parsed `capture_meta` rows in
`capture_metadata_rows`, splits the provenance row into `capture_context`, and
splits the enforced schema/correction row into `capture_contract`. Reference
reports also include
`rmssd_within_tolerance`, an explicit boolean for the Gate B RMSSD threshold.
They also include `reference_metric_tolerances` and
`reference_metric_within_tolerance` for RMSSD, SDNN, pNN50, and lnRMSSD.
Each capture block includes `window_start_s`,
`window_end_s`, `corrected_start_s`, and `corrected_end_s` for final-window
diagnostics. Reference reports include `window_alignment` with final-window
start/end deltas, and the wrapper repeats raw/corrected final-window durations
plus total raw counts/durations, max raw RR gaps, `clean_rr_marker_value`,
`clean_rr_marker_elapsed_s`, `clean_rr_marker_before_first_rr`,
`capture_summary_elapsed_s`, `capture_summary_window_s`,
`capture_summary_max_rr_gap_s`, `capture_summary_elapsed_ok`,
`app_replay_*_delta`, `app_replay_max_rr_gap_delta_s`,
`capture_summary_*_delta`, `capture_summary_max_rr_gap_delta_s`,
`window_start_delta_s`, `window_end_delta_s`, and
`threshold_max_window_alignment_s`, `threshold_min_resp_bpm`,
`threshold_max_resp_bpm`, and `threshold_max_resp_match_delta_bpm` in
`MANIFEST.txt`. It also repeats
`app_ready_resp_status`, `capture_summary_resp_status`, `app_ready_resp_bpm`,
`capture_summary_resp_bpm`, `resp_status_match`, `resp_bpm_delta`,
`app_ready_snapshot_row_elapsed_s`, `capture_summary_row_elapsed_s`, and
`capture_summary_after_ready_snapshot`. It also records
`whoop_last_rr_row_elapsed_s`, `capture_summary_after_last_rr`,
`whoop_last_hrv_row_elapsed_s`, and `capture_summary_after_last_hrv`.
Reference imports also include
`reference_metadata` with the chosen CSV columns, timeline source, and time-unit
interpretation.
Rejection counts are split into
`rejected_out_of_range` for RR outside 300-2000 ms and
`rejected_delta_over_20_percent` for ectopic/motion jumps. The wrapper keeps
that report beside copied `whoop-capture.csv`, `reference-rr.csv`, and
`SHA256SUMS` files as Gate B evidence.
