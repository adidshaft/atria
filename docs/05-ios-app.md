# iOS App

SwiftUI + CoreBluetooth app at `Atria/`. Shows live heart rate, battery,
manufacturer, and a raw log of proprietary frames.

## Requirements

- **Xcode** 26.5 or 27 (project format opens in both).
- A **real iPhone** — the Simulator has no Bluetooth radio.
- Run on a device whose iOS matches the Xcode you build with (this project is
  deployed with Xcode 27 to an iOS 27 device).

## Build & run

1. Open `Atria/Atria.xcodeproj`.
2. Target → Signing & Capabilities → select your **Team** (free Apple ID works).
   Change the bundle id if `com.adidshaft.atria` is taken.
3. Select your iPhone, **Run**. Approve the Bluetooth prompt; trust the developer
   cert under Settings → General → VPN & Device Management if needed.
4. Wear the strap to wake the sensors.

## Architecture

| File | Role |
|---|---|
| `AtriaApp.swift` | App entry; owns the `AtriaBLEManager` as a `@StateObject`. |
| `AtriaBLEManager.swift` | `CBCentralManager`/`CBPeripheralDelegate`. Finds the strap, subscribes to HR/battery/proprietary streams, auto-reconnects. `@MainActor ObservableObject` publishing state to the UI. |
| `HeartRate.swift` | `HRSample` model, 5-zone model (`HRZone`), Swift Charts line chart, and the zone bar. |
| `FrameParser.swift` | Decodes the `aa+len+payload+checksum` frames. |
| `ContentView.swift` | UI: pulsing BPM + sparkline, battery/maker tiles, capture controls, frame log. |

## Capture & export

A **Capture** card records every frame + HR sample to CSV while you do a labeled
activity, then exports via the iOS share sheet (AirDrop to Mac, etc.):

1. Type a **label** (e.g. `still`, `walking`, `deep breath`) — stored per row so
   we can correlate bytes with what you were doing.
2. **Record** → rows accumulate; **Stop** → an **Export** button appears.
3. Share the CSV off the phone for offline analysis.

Export filenames include timestamp, sanitized label, and final readiness state:
`whoop-capture-YYYYMMDD-HHMMSS-<label>-ready.csv` or `...-learning.csv`.

CSV columns: `elapsed_ms, kind, source, opcode, len, label, value`.
`kind` can be `capture_meta`, `frame`, `hr`, `hr_artifact`, `rr`, `hrv`, or
`capture_summary`. Each fresh capture starts with a provenance metadata row
(`started_at_utc`, app bundle, iOS version, phone model, strap display name, and
label) followed by the strict schema/correction contract row. RR rows are raw
decoded realtime intervals in milliseconds, including values the analyzer later
rejects; HRV rows are periodic analyzer snapshots.
This is how we'll build a labeled dataset to decode proprietary opcodes and run
the Gate B reference comparison. While recording, the Capture card shows
corrected RR kept/raw, confidence, and 5-minute window readiness.

When Capture stops, the app also writes the same CSV under
`Documents/atria-captures/` and logs `ATRIADBG capture_file path=...`. This lets
`live_device_debug.sh --pull-capture DIR` copy unattended auto-captures from the
cabled iPhone's app data container for Gate B reference validation.
For saved-session replay, debug launches can pass
`--atria-export-rr-reference-package` or use
`live_device_debug.sh --export-rr-reference-package --pull-reference-package DIR`.
The app selects the best saved strict 5-minute RR window, writes a
validator-ready CSV plus JSON manifest under
`Documents/atria-rr-reference-packages/`, and logs
`ATRIADBG rr_reference_package ... external_reference_required=1
reference_validated=0`. Schema 2 manifests also include the exact
`Documents/atria-reference/rr-reference.csv` validation path, accepted RR/time
column aliases, the 300-second window requirement, `300-2000 ms` and
`|delta RR| <= 20%` artifact policy, `>=240` corrected beats, `>=75%`
confidence, no `>3s` RR gap, and the `+/-5 ms` RMSSD tolerance. This export
never turns saved RR into validated HRV by itself; it exists so the same raw RR
window can be compared against an independent external RR/IBI reference.
The validator rejects Atria-vs-Atria copied exports with
`reason=same_content_not_external_reference`, where the output still reports
`external_reference=0` and `gate_b_pass=0`. The Mac reducer now also parses
`ATRIADBG rr_reference_package` and `ATRIADBG rr_reference_validation` rows
directly, including focused logs that do not emit a full Gate Status table.
`live_device_debug.sh` exits as soon as requested reference package/validation
side effects complete, instead of waiting for unrelated long-wear timers.
To run the same check entirely on the cabled iPhone, copy an independent CSV
into the app container with
`live_device_debug.sh --push-rr-reference /path/to/rr.csv --validate-rr-reference`.
The harness writes it to `Documents/atria-reference/rr-reference.csv` before
launch. Atria still rejects copied Atria exports and still keeps Gate B closed
unless the pushed file satisfies the 300-second, no-`>3s`-gap, `>=240` corrected
beats, `>=75%` kept, and `+/-5 ms` RMSSD contract.
Use `live_device_debug.sh --clear-reference-inputs` to remove both on-device
reference CSV inputs before launch when a parser-smoke or stale reference file
should not affect the next audit.
Debug launches can also pass `--atria-auto-stop-after N` with
`--atria-auto-capture`; the app will stop and save the capture after N seconds
even if HRV is still `learning`, preserving timeout runs as explicit
`...-learning.csv` evidence instead of losing the CSV when the console session
ends. `live_device_debug.sh --auto-capture-delay N` forwards
`--atria-auto-capture-delay N`, which schedules Capture after protocol warm-up so
Gate B can measure only the candidate steady-state RR window. For continuity
experiments, `--auto-capture-when-rr FRACTION` forwards
`--atria-auto-capture-when-rr FRACTION`; the app then waits until recent realtime
frames meet the requested RR-bearing fraction before starting Capture. Pair it
with `--auto-capture-rr-window N`, `--auto-capture-rr-min-frames N`, and
`--auto-capture-rr-timeout N` so a failed adaptive gate still produces explicit
`learning` evidence.
`--strict-live-rr-capture` forwards `--atria-strict-live-rr-capture`, which
disables pre-capture archive seeding and measures timeout from the latest clean
RR window after any quality reset. RR rows are still real intervals only; the app
now reconstructs `2A37`/`0x28` beat timestamps from the RR intervals before using
gap checks, so BLE notification batching is not mistaken for a beat gap. The
same beat-timeline logic is used by the pre-capture auto gate; logs include both
`max_rr_gap_s` and `frame_max_rr_gap_s` plus `beat_timeline=1` when the decision
used reconstructed beats.

## Morning HRV auto-capture

Debug launches can pass `--atria-morning-hrv-check` or use
`live_device_debug.sh --morning-hrv-check`. The app evaluates a local morning
window (04:00-11:59), configures strict RR-continuity capture, and logs:
`ATRIADBG morning_hrv_check ... still_source=rr_continuity motion_source=unavailable`.
The current stillness precondition is intentionally labeled as RR-continuity
only because IMU/motion is not decoded yet. If RR continuity does not satisfy
the 5-minute HRV gate, the capture file is saved as `...-learning.csv` and no
HRV-backed recovery is promoted. `--morning-hrv-force` exists only for physical
device smoke tests outside the morning clock window; it does not bypass any HRV
readiness, confidence, or artifact rule.

## Trends dashboard

The dashboard and History screen render 7/30/90-day trend windows for Recovery,
HRV, RHR, and Strain from saved local sessions. Recovery and HRV charts stay in
`learning` when no reference-validated HRV exists; they do not plot zeroes or
fallback values. RHR uses accepted baseline-learning evidence, Strain uses saved
HR-reserve TRIMP, and each window carries sparse-history confidence plus anomaly
flags. Debug launches can pass `--atria-log-trends`; the chart surface also logs
`ATRIADBG trend_chart_ui ...` on appear so physical-device runs prove the chart
inputs and confidence gates. Gate-status runs also emit explicit Gate F blockers
(`trend_blockers=...`) so sparse history, missing reference-validated HRV, and
missing Recovery/HRV trend points are separated instead of collapsed into a
generic `learning` state.
Trend logs now include the exact coverage needed for high confidence using the
same 70% rule as the UI: 5/7 days, 21/30 days, and 63/90 days. Physical iPhone
evidence in `docs/evidence/gate-f/20260615T-trend-required-coverage-device-verify/`
logged those required-day counts and kept Gate F in `learning` with
`trend_blockers=coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
The device harness now treats `--log-trends` as a real completion target: a run
must see `trend_summary` plus all three `trend_window` rows for 7/30/90 days, or
it fails with `HARNESS_ERROR=trend_summary_incomplete` or
`HARNESS_ERROR=trend_windows_incomplete`. Targeted trend-only logs are also
reduced into a Gate F row by `tools/analyze_gate_status.py`, so Gate F can be
checked without requiring a heavyweight all-gates audit.
Trend anomaly flags are now computed from daily rollups rather than raw saved
session fragments. This keeps reconnect chunks and short journal segments from
acting like independent 7/30/90-day observations. Physical iPhone evidence in
`docs/evidence/gate-f/20260615T-daily-rollup-anomaly-source-device-verify-3/`
logged all trend windows with `anomaly_source=daily_rollups` and
`anomaly_days=3`; the companion Gate Status run in
`docs/evidence/gate-f/20260615T-daily-rollup-anomaly-source-gate-status-device-verify/`
logged `trend90_anomaly_source=daily_rollups`, `trend90_anomaly_days=3`, and
kept Gate F `partial` because coverage and HRV/Recovery reference requirements
are still missing.

## Daily rollups and local activity

History now includes a Daily rollups section so the app is useful even when a
formal workout is not accurate enough to count. Rollups separate
`activityCandidates` from strict `workouts`: strength-like or near-threshold
saved HR evidence can appear as a local low-confidence activity, while Apple
Health workout export and Gate E still require the sustained HRR50 workout
detector to be ready. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-activity-rollups-device-verify/` logged
`daily_rollup day=2026-06-14 ... activity_candidates=1 workouts=0
sleep_candidates=1 ... workout_gate_strict=1` and kept the gym signal labeled
`strength_diagnostic_only=1` instead of promoting it to a workout.

## Measured HRV display while reference-pending

When Atria has a clean local RR package but no independent RR/IBI reference
comparison, the Today HRV tile now shows the measured local RMSSD value with an
explicit `not ref checked` detail instead of hiding the number behind
`pending`. This is display-only: Recovery, validated HRV baseline learning,
Gate B, and HealthKit HRV export remain gated until the external `+/-5 ms`
RMSSD reference check passes.

Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-measured-hrv-reference-pending-device-verify-unlocked/`
verified the behavior on the cabled iPhone after an earlier lock-screen launch
denial. The run logged `ATRIADBG hrv_display
state=measured_reference_pending main_rmssd=33 ... rr_package_ready=1
rr_package_raw=368 rr_package_kept=361 rr_package_conf=98
rr_package_gap_s=1.8 rr_package_rmssd=32.7
reason=external_rr_reference_required metric_promotions=0 surface=today`, then
Gate Status kept `gate=B status=reference_pending` with
`external_rr_reference_required=1` and `reference_validated=0`. The same run
showed the strap reconnect path was healthy (`ble_scan status=matched
name=ADIDSHAFT'S WHO rssi=-53`, followed by `ble_link status=connected`), so the
UI treats reconnecting as a transport state while saved clean RR remains visible.

## Local session backup

Debug launches can pass `--atria-backup-sessions` or use
`live_device_debug.sh --backup-sessions`. The app writes a local JSON envelope to
`Documents/atria-backups/` containing schema version, creation time, saved
sessions, learned baseline, and athlete profile. It logs
`ATRIADBG session_backup path=Documents/atria-backups/... sessions=N
rr_samples=N motion_short_samples=N bytes=N`.
This is local-only; no WHOOP cloud/account or remote service is involved.
Use `--atria-verify-backup` or `live_device_debug.sh --verify-backup` to decode
the latest backup on-device and compare schema/session counts against the
current store. Verification logs `ATRIADBG session_backup_verify status=ok`,
including RR, motion-hint, and observe-only `motion_short` totals, or an explicit
error/mismatch. Legacy `Documents/whoop-backups/` files remain readable for
restore/verify, but new backups are Atria-named.
Use `--atria-restore-backup` or `live_device_debug.sh --restore-backup` to run a
guarded restore of the latest backup. The app writes a `pre-restore` safety
backup first, restores sessions, baseline, and athlete profile into their normal
local stores, then logs `ATRIADBG session_backup_restore status=ok` or an
explicit error.

## Physical-device harness availability

Before building, `live_device_debug.sh` now runs an Xcode destination preflight
with `xcodebuild -showdestinations` and a bounded destination timeout. If the
cabled iPhone is connected to CoreDevice but unavailable to Xcode's physical
destination service, the harness keeps the two device-id namespaces separate:
`--xcode-device`/`ATRIA_XCODE_DEVICE_ID` is used only for Xcode destination
selection, while `--device`/`ATRIA_DEVICE_ID` is used for `devicectl` install,
launch, copy, and log capture.

If the Xcode physical-destination build fails with the transient development
services error, the harness logs `HARNESS_BUILD_FALLBACK status=retry` and
retries a signed `generic/platform=iOS` build before continuing to install and
launch on the real iPhone with `devicectl`. Physical-device evidence in
`docs/evidence/gate-g/20260615T-xcode-build-fallback-device-verify/` hit that
fallback, reached `** BUILD SUCCEEDED **`, installed `Atria.app`, emitted
ATRIADBG Gate Status on the cabled iPhone, and left Atria running in
standard-HR-only long-wear mode. A ready phone can still log
`HARNESS_DEVICE_PREFLIGHT status=ok`; that row means the destination was listed,
not that the later build step cannot fall back.

When `xcodebuild -showdestinations` reports the same "observing system
notifications failed / Development services need to be enabled" line but
`devicectl` simultaneously reports the phone as paired, wired, booted, and
Developer Mode enabled, the harness treats it as an Xcode observer false
positive. It suppresses the raw scary destination/build row, logs
`HARNESS_XCODE_DESTINATION_WARNING suppressed=1` or
`HARNESS_XCODE_BUILD_WARNING suppressed=1`, builds for `generic/platform=iOS`,
then installs and launches on the physical iPhone with `devicectl`.

If `xcodebuild -showdestinations` or the physical-destination build reports the
known `observing system notifications failed` text but
`devicectl device info details` still shows the phone paired, wired, booted, and
Developer Mode enabled, the harness logs
`HARNESS_DEVICE_PREFLIGHT_DEVICE status=ready` and classifies the event as
`xcode_notification_observe_false_negative`. That is a tooling-layer fallback,
not proof that the user failed to unlock or enable Developer Mode.

## HealthKit export

Debug launches can pass `--atria-healthkit-export` or use
`live_device_debug.sh --healthkit-export`. The exporter is intentionally narrow:
it writes real saved heart-rate samples, writes Apple Health workouts only when
the same HRR50 Gate E workout detector is ready for that session, and writes HRV
samples only when a saved session has `hrvReferenceValidated=true`. Otherwise
workouts and HRV remain absent/learning rather than promoted from ordinary
sessions, unreferenced RR, or threshold-near-miss evidence.
Each export also runs a non-prompting `healthkit_reference_audit`: it checks
whether heart-rate read access is already available, then counts independent
non-Atria HR samples in the saved-session time span. Atria samples are excluded
by bundle ID and `atria_session_id` metadata, so Apple Health never becomes a
fake external reference for the data Atria just wrote.
After a successful export, Atria also runs `healthkit_export_verify`, a
readback query over the saved-session span. Reconciliation is scoped to
`atria_session_id` values that match the local saved sessions, while the broad
Atria-looking count is logged separately. This proves Atria-authored HR rows are
visible through HealthKit without treating them as an independent reference:
`readback_covers_delta=1` means the newly saved delta appears, and
`expected_total_reconciled=1` means the session-attributed Atria total matches
the local writable-HR plan exactly.

## Long-wear RR recovery

Long-wear standard-HR mode treats BLE `2A37` as the primary HR/R-R source. If a
new active segment keeps receiving fresh HR samples but no real R-R intervals,
Atria records `rr_presence_watchdog status=segment_hr_only` after 12 seconds of
fresh segment HR with zero segment RR and first reasserts the `2A37` notify/read
path. If the same segment remains HR-only, it escalates to a fresh
scan-and-connect after saving the active journal. This is a recovery and
evidence path only: HRV remains `learning` until real R-R intervals return, and
Atria never estimates HRV from HR-only frames.

The exporter checks the embedded provisioning profile before calling HealthKit.
Without the entitlement it logs:
`ATRIADBG healthkit_export status=missing_entitlement ...`.
A 2026-06-14 physical-iPhone signing recheck in
`docs/evidence/gate-g/20260614T044257Z-healthkit-entitled-build-recheck/`
passed the existing `WhoopApp.entitlements` file through
`CODE_SIGN_ENTITLEMENTS=Atria/Atria.entitlements`; Xcode still rejected
the automatic `iOS Team Provisioning Profile: *` because it lacks the HealthKit
capability and `com.apple.developer.healthkit` entitlement. The default project
therefore remains unwired so BLE/device builds stay green until the Apple
developer profile is updated.
A second recheck on 2026-06-14 in
`docs/evidence/gate-g/20260614T-healthkit-profile-blocker-recheck/` produced
the same provisioning errors, then restored the default project configuration
and confirmed a physical-iPhone green build.
A third 2026-06-14 recheck in
`docs/evidence/gate-g/20260614T-gate-g-entitlements-device-verify/` tried the
HealthKit + app-group entitlement set needed for the app/widget pair. Xcode
again rejected the automatic wildcard profile: HealthKit is not in the profile,
and app-group entitlement insertion was refused for both app and widget. The
default target remains unwired so physical BLE builds stay green, while
`WhoopApp.entitlements` / `AtriaWidget.entitlements` document the exact
capabilities needed once an explicit App ID/profile is available.
Atria now uses explicit Apple App IDs and manual development profiles:
`com.adidshaft.atria` for the app and `com.adidshaft.atria.widget` for the
widget. The app profile includes HealthKit, so the 2026-06-14 cabled iPhone run
in `docs/evidence/gate-g/20260614T-gate-g-atria-healthkit-export-device-verify/`
installed `Atria.app`, requested HealthKit authorization, and after the user
granted write permission logged:
`ATRIADBG healthkit_export status=saved sessions=84 hr_samples=40672 workouts=84 hrv_samples=0`.
Those pre-gating runs proved authorization and sample writing, but they also
exposed that every saved session was being exported as an `HKWorkout`.
Zero-duration HR samples at exact session end are skipped instead of creating
invalid HealthKit samples. HRV samples remain absent because Gate B reference
validation is still missing.
After Health write permission was granted again on 2026-06-14, the cabled
iPhone run in
`docs/evidence/gate-g/20260614T111819Z-healthkit-write-permission-saved-retry/`
rebuilt, installed, launched, and logged
`ATRIADBG healthkit_export status=saved sessions=86 hr_samples=40906 workouts=86 hrv_samples=0`.
This confirmed the current Atria profile can write to Apple Health. The exporter
was then tightened so only detector-ready workouts produce `HKWorkout` samples.
The 2026-06-14 cabled iPhone run in
`docs/evidence/gate-g/20260614T114411Z-healthkit-workout-gated-export-device-verify/`
rebuilt, installed, launched, used the granted Health write permission, and
logged `ATRIADBG healthkit_export status=saved sessions=87 hr_samples=41609 workouts=0 hrv_samples=0`.
The matching gate summary reported `healthkit_workouts=0` because Gate E has
`workout_saved_ready=0`; this is the correct fail-closed behavior. The zero HRV
export remains intentional until Gate B has external RR/IBI RMSSD reference
validation.
After Health write permission was granted on the current cabled phone, the
bounded export verification in
`docs/evidence/gate-g/20260614T124249Z-bounded-rr-export-healthkit-device-verify/`
rebuilt, installed, launched `Atria.app`, and logged
`ATRIADBG healthkit_export status=saved sessions=96 hr_samples=42198 workouts=0 hrv_samples=0`.
The same run proved launch exports now defer off first appearance and complete:
`launch_exports status=completed`, an HR reference package was pulled with
`11236` real `2A37` samples, and an RR reference package was pulled from a real
5-minute window (`raw=368 kept=361 conf=98 max_rr_gap_s=1.8 rmssd=32.7`).
The same-file validator smokes passed only as parser checks with
`external_reference=0`, so Gate B and Gate D remain reference-pending.
The current-store handoff in
`docs/evidence/reference-handoff/20260615T-current-reference-handoff-device-verify/`
is the freshest reference package set: RR
`atria-rr-reference-20260614T224410Z-gate-b-300s-live-rr.csv`
(`raw=368`, `kept=361`, `conf=98`, `rmssd=32.7`) and HR
`atria-hr-reference-20260614T224410Z-gate-e-overnight-checkpoint-run.csv`
(`11236` samples, `100%` coverage). Both manifests explicitly say
`readyForExternalReference=true` and `referenceValidated=false`; use
`./reference_validate.sh <label> --rr <independent-rr.csv> --hr <independent-hr.csv>`
to push independent reference files back to the iPhone and run the on-device
validators.
A follow-up Gate D physical-device audit in
`docs/evidence/gate-d/20260614T125246Z-healthkit-reference-audit-device-verify/`
rebuilt, installed, launched, and verified the new reference check. HealthKit
write still succeeded (`status=saved sessions=99 hr_samples=42503 workouts=0
hrv_samples=0`), and the audit logged
`healthkit_reference_audit status=read_permission_required request_status=should_request external_reference_ready=0`.
This gives Gate D a local Apple Health reference path, but it remains partial
until heart-rate read permission and independent non-Atria HR samples exist.
After the user granted Apple Health write permission again, the 2026-06-14
cabled re-run in
`docs/evidence/gate-g/20260614T125607Z-healthkit-write-permission-rerun/`
confirmed the distinction: Atria saved HealthKit data
(`healthkit_export status=saved sessions=100 hr_samples=42541 workouts=0 hrv_samples=0`)
and pulled the HR reference package, but the audit still reported
`healthkit_reference_audit status=read_permission_required request_status=should_request external_reference_ready=0`.
Write access is therefore verified; Apple Health cannot yet be used as an
independent HR reference until heart-rate read access is granted and
non-Atria HR samples are available.
The exporter now requests heart-rate read access in the same HealthKit
authorization flow as the write export and runs the independent-reference audit
after authorization returns. Physical-device evidence in
`docs/evidence/gate-d/20260614T125832Z-healthkit-read-request-device-verify/`
installed the patched build and logged
`healthkit_export status=authorization_requested sessions=101 hr_samples=42681 workouts=0 hrv_samples=0 read_hr=1`.
The run was terminated before HealthKit returned an authorization callback, so
no reference query was counted in that capture. This verifies the app now asks
for the missing permission; Gate D still waits for the on-device Health read
grant and independent non-Atria HR samples.
The follow-up cabled run in
`docs/evidence/gate-d/20260614T130159Z-healthkit-auth-watchdog-device-verify/`
verified the completed read/write path. Atria requested HealthKit with
`read_hr=1`, saved `42646` HR samples, then queried Apple Health and logged
`healthkit_reference_audit status=ok total_hr_samples=375677 atria_hr_samples=375677 independent_hr_samples=0 independent_sources=none external_reference_ready=0`.
Heart-rate read access is therefore available; Apple Health still cannot serve
as Gate D reference because the matching window contains no independent
non-Atria HR samples.
Atria persists the latest HealthKit reference-audit result and threads it into
Gate D diagnostics. Physical-device evidence in
`docs/evidence/gate-d/20260614T130658Z-healthkit-reference-state-gate-status-device-verify/`
first updated the audit (`total_hr_samples=418323`,
`atria_hr_samples=418323`, `independent_hr_samples=0`), then relaunched with
`--log-gate-status`. The Gate D row now reports
`primary_blocker=independent_non_atria_hr_reference_missing`,
`healthkit_reference_status=ok`, and
`healthkit_external_reference_ready=0`, and the readiness strip shows
`D=partial[independent_hr_reference_missing]`.
Repeated pre-ledger exports polluted Apple Health with duplicate Atria-owned HR
samples (`healthkit_reference_audit total_hr_samples=461000`,
`atria_hr_samples=461000`). A broad metadata delete was tested on the physical
iPhone but did not finish within the debug harness window, so the app now uses a
local HealthKit export ledger instead of trying to clean the whole legacy store
on every launch. If the persisted reference audit proves Apple Health already
contains at least the current planned Atria HR sample count, the exporter seeds
the ledger, logs `healthkit_export status=skipped_existing_atria_samples ...
ledger_seeded=1 idempotent=1`, and only allows incremental exports from then on.
Physical-device evidence in
`docs/evidence/gate-g/20260614T132128Z-healthkit-ledger-seed-device-verify/`
verified the seed path with `sessions=106`, `hr_samples=43229`, and
`atria_hr_samples=461000`. A second cabled iPhone run in
`docs/evidence/gate-g/20260614T132229Z-healthkit-ledger-incremental-device-verify/`
verified cached authorization plus the ledger guard:
`healthkit_export status=authorization_cached ... hr_samples=1`, followed by
`healthkit_export status=up_to_date ... ledger_entries=105 idempotent=1`.
This prevents further duplicate floods. It does not erase the already-written
legacy duplicates from Apple Health; those remain excluded from Gate D reference
validation because their source is Atria.
The follow-up ledger planner now uses the same writable-point filter as the
HealthKit writer: positive BPM only, and a sample window that still intersects
the saved session end. This avoids reporting a delta for terminal or zero-width
points that HealthKit correctly skips. Physical-device evidence in
`docs/evidence/gate-g/20260614T132920Z-healthkit-ledger-writable-count-device-verify/`
matched the planned and saved delta exactly:
`healthkit_export status=authorization_cached ... hr_samples=44`, then
`healthkit_export status=saved ... hr_samples=44 ... incremental=1`.
After Health write permission was granted again on 2026-06-14, the cabled
iPhone run in
`docs/evidence/gate-c/20260614T134906Z-strict-recovery-learning-healthkit-device-verify/`
reverified the current incremental writer with cached authorization:
`healthkit_export status=authorization_cached ... hr_samples=267`, followed by
`healthkit_export status=saved ... hr_samples=267 workouts=0 hrv_samples=0
ledger_entries=114 idempotent=1 incremental=1`. The same run read Apple Health
for reference auditing and found only Atria-origin HR rows
(`independent_hr_samples=0`), so HealthKit write is working while Gate D
external-reference validation remains incomplete.
After the current Apple Health write permission change, a fresh cabled iPhone
run in
`docs/evidence/gate-g/20260614T141325Z-healthkit-write-permission-current-device-verify/`
rebuilt, installed, launched, and confirmed the same writer on live state:
`healthkit_export status=authorization_cached ... hr_samples=564`, followed by
`healthkit_export status=saved ... hr_samples=564 workouts=0 hrv_samples=0
ledger_entries=115 idempotent=1 incremental=1`. The read-side audit remained
honest (`independent_hr_samples=0`), so HealthKit write is verified while Gate D
still needs an external non-Atria HR source.
The latest cabled-device check in
`docs/evidence/gate-d/20260614T151015Z-healthkit-independent-reference-current-device-verify/`
reconfirmed that distinction after current Health permissions: HealthKit saved a
fresh Atria delta (`hr_samples=321`) and readback returned
`readback_covers_delta=1`, `data_appears=1`, but the reference audit still
reported `independent_hr_samples=0` and `external_reference_ready=0`. Gate G is
ready; Gate D remains partial until Apple Health contains HR from a non-Atria
source or another external HR CSV is validated.
A 2026-06-14 physical-device recheck in
`docs/evidence/gate-g/20260614T-atria-app-group-profile-recheck/` temporarily
wired the correct app-group entitlement into both the app and widget. Xcode
rejected the build with exit 65: both explicit Atria profiles have
`app_groups=[]` and do not support `group.com.adidshaft.atria`. The entitlements
were restored to the buildable fail-closed state, then Atria rebuilt, installed,
and launched on the cabled iPhone with `widget_app_group=0`,
`widget_target=1`, `complication_target=1`, and
`action=enable_shared_app_group`.
A bounded automatic-signing attempt in
`docs/evidence/gate-g/20260614T-app-group-xcode-managed-profile-attempt/`
temporarily added the App Group entitlement and used
`-allowProvisioningUpdates`, but Xcode has no local developer account configured
and fell back to a wildcard profile that lacks HealthKit, App Groups, and
`group.com.adidshaft.atria`. The app was restored to manual signing and
physically relaunched; widget shared storage remains blocked by profile/portal
state, not app code.
The portal/profile blocker was then repaired through Apple Developer in Chrome:
both Atria identifiers were assigned `group.com.adidshaft.atria`, the invalidated
profiles were regenerated, downloaded to
`~/Documents/keys/atria-profiles`, and installed into Xcode's
profile cache. `docs/evidence/gate-g/20260614T113817Z-atria-app-group-ready-status-device-verify/`
rebuilt, installed, and launched on the physical iPhone with the real App Group
entitlements. Runtime logs now show `gate_status gate=G status=ready`,
`widget_storage=app_group_userdefaults`, `widget_app_group=1`,
`complication_target=1`, `app_group_widget=shared_ready`, and
`widget_readiness status=ready`.

## Local notifications

Debug launches can pass `--atria-schedule-notifications` or use
`live_device_debug.sh --schedule-notifications`. The scheduler requests
provisional local-notification authorization, waits briefly for live BLE state,
then schedules only eligible notifications:

- recovery ready only when Recovery confidence is `high`
- strain target only when day Strain has actually reached the current
  high-confidence Recovery target
- battery only when the strap battery is known and at or below 20%

Every decision logs through `ATRIADBG`: `notification_auth`,
`notification_scheduled`, `notification_skip`, and final
`notification_schedule status=scheduled count=N`. Skipped notifications remain
skipped; the app does not invent a target hit, battery level, or HRV-backed
recovery.
Battery notification decisions use the latest live standard Battery Level
(`2A19`) read when available, or a fresh persisted `2A19` cache when launch
status runs before the strap has returned battery again. Gate Status includes
`battery_level`, `battery_source`, `battery_age_s`, and `battery_usable`, and
scheduler logs include `notification_battery_decision ... source=... usable=...`.
Stale or missing battery evidence stays `learning`; Atria does not schedule a
battery warning from an unknown level.
For delivery verification, pass `--atria-test-notification` or
`live_device_debug.sh --test-notification`. This schedules a clearly labeled
`Atria diagnostic` notification and logs foreground delivery as
`ATRIADBG notification_delivered kind=diagnostic`; it is not used as a recovery,
strain, or battery signal. Use it by itself when testing delivery; combine it
with `--schedule-notifications` only when intentionally testing the metric
notification decisions too.
The user-facing low-battery title is `Strap battery low`, keeping the app
identity as Atria while still describing the wearable as a strap.
Physical-device evidence in
`docs/evidence/gate-g/20260614T140323Z-atria-notification-naming-device-verify/`
verified `notification_scheduled ... title=Atria diagnostic` and
`notification_delivered kind=diagnostic ... foreground=1`.
Physical iPhone evidence in
`docs/evidence/gate-g/20260615T-battery-evidence-notification-device-verify/`
proved a live strap battery read (`battery level=49 source=2A19 ... persisted=1`)
and a battery scheduler decision using `source=live_2A19`. The follow-up run in
`docs/evidence/gate-g/20260615T-battery-evidence-gate-status-cached-device-verify/`
proved the cached launch path: Gate Status reported `battery_level=49`,
`battery_source=live_2A19`, `battery_age_s=41`, and `battery_usable=1`, then the
notification decision refreshed from live `2A19` and skipped low-battery
delivery with `battery_49_not_low_source_live_2A19`.

## Widget/complication snapshot

Debug launches can pass `--atria-log-widget-snapshot` or use
`live_device_debug.sh --log-widget-snapshot`. The app publishes a compact local
JSON snapshot for future widget/complication surfaces with recovery, recovery
confidence, strain, RHR, HRV state, and HRmax. It logs
`ATRIADBG widget_snapshot status=ok ... hrv=learning|reference_pending|validated ... app_group=0|1`.
The readiness fields are runtime checks: the app scans its installed
`PlugIns/*.appex` bundle extension points for WidgetKit/Watch targets and checks
the embedded provisioning profile for app-group capability strings before
logging `widget_target`, `complication_target`, and `app_group`.

The launcher treats this as a strict completion target:
`live_device_debug.sh --log-widget-snapshot` now waits for the actual
`ATRIADBG widget_snapshot status=...` row and fails with
`HARNESS_ERROR=widget_snapshot_incomplete` if it never appears.

The project now includes a signed `AtriaWidget` WidgetKit extension target. The
main app verifies it at runtime by scanning `PlugIns/*.appex`, so
`widget_target=1` means a real embedded `com.apple.widgetkit-extension` is
present in the installed app bundle. The same extension supports WidgetKit
accessory families for Lock Screen / accessory complication surfaces; the app
counts `complication_target=1` only when the installed extension declares that
accessory-family support.
The widget code now reads the same snapshot from
`group.com.adidshaft.atria` when that app group is actually provisioned, and the
app reloads WidgetKit timelines after publishing to shared storage. Physical
iPhone evidence in
`docs/evidence/gate-g/20260614T-gate-g-atria-healthkit-export-device-verify/`
verified the fail-closed state on the explicit Atria profiles:
`widget_snapshot status=ok`, `widget_target=1`, `complication_target=1`, but
`storage=app_local_userdefaults app_group=0` and `action=enable_shared_app_group`.
The current strict verifier evidence in
`docs/evidence/gate-g/20260615T-widget-harness-completion-device-verify/`
built, installed, and launched Atria on the physical iPhone, logged
`widget_snapshot_complete=True`, and captured
`storage=app_group_userdefaults`, `app_group=1`, `widget_target=1`, and
`complication_target=1`. The fallback reducer reports Gate G as
`metric_gated`, not complete, because HRV and workout exports still wait on the
upstream reference/workout gates.

## Strain validation diagnostic

Debug launches can pass `--atria-log-strain-validation` or use
`live_device_debug.sh --log-strain-validation`. The app groups saved local HR
sessions by day and logs `ATRIADBG strain_validation` with personalized
HR-reserve zone seconds, stream coverage, TRIMP, Strain, and exact fail-closed
Gate D blockers. It never estimates effort from HR-only gaps or relaxes the
external HR reference requirement.
The launcher treats this as a strict completion target: `--log-strain-validation`
must observe `ATRIADBG strain_validation` or it fails with
`HARNESS_ERROR=strain_validation_incomplete`. `tools/analyze_gate_status.py`
also reduces strain-only logs into a focused Gate D row for the current
rest-to-max blockers.
The dashboard also shows the same readiness contract in a Strain validation
card and logs `ATRIADBG strain_validation_ui`, so rest-to-max blockers can be
checked directly on the cabled iPhone without opening a separate evidence
script. The card is display-only: it surfaces the existing fail-closed
criteria and does not make Gate D pass without the external HR reference.
`tools/validate_hr_reference.py` compares WHOOP capture HR against an external
HR CSV for the final `+/-2 bpm` check. Same-file comparisons are rejected by
default with `reason=same_file_not_external_reference`; `--allow-self-compare`
is parser-smoke only and still reports `external_reference=0` and
`gate_d_pass=0`.
For current-device evidence, pass `--atria-export-hr-reference-package` or run
`live_device_debug.sh --export-hr-reference-package --pull-reference-package DIR`.
The app exports the best saved real `2A37` HR segment as CSV plus a manifest
with sample count, coverage, average/peak/resting HR, and
`external_reference_required=1`. The package is ready for comparison, but it
does not pass Gate D until `tools/validate_hr_reference.py` compares it against
an independent HR reference within the `+/-2 bpm` contract.
Debug launches can also pass `--atria-validate-hr-reference` or use
`live_device_debug.sh --validate-hr-reference`. The on-device validator reads
`Documents/atria-reference/hr-reference.csv`, rejects same-content copies of
Atria's own export, pairs WHOOP samples to the nearest external sample within
5 seconds, and requires at least 30 paired samples over 60 seconds with mean and
max absolute delta within `2 bpm`. Missing or invalid reference data logs
`gate_d_pass=0` and `reference_validated=0`; `external_reference` is `0` when
the file is absent or self-content, and `1` when a distinct but failing file was
actually parsed. No Strain or workout gate is promoted from Atria-only HR data.
Use `live_device_debug.sh --push-hr-reference /path/to/hr.csv
--validate-hr-reference` to copy an independent chest-strap or non-Atria HR CSV
to the expected on-device path before validation. Pushing a CSV only changes the
input file; it does not mark Gate D passed unless the validator logs
`gate_d_pass=1 external_reference=1 reference_validated=1`.
`tools/analyze_gate_status.py` reduces focused `hr_reference_package` and
`hr_reference_validation` logs into a Gate D row. When the WHOOP-side package is
ready but the external CSV is missing or too small, the reducer now reports the
specific reference blocker instead of the generic rest-to-max blocker.
The launcher also treats HR/RR reference validation as complete only after a
terminal validator row, not the initial `status=started` row.
`--clear-reference-inputs` deletes the HR and RR reference input files before
validation, so missing-reference audits can be restored without uninstalling
the app or deleting saved sessions.
Apple Health can be one local source of that independent HR reference only when
the `healthkit_reference_audit` row reports `external_reference_ready=1` and
the counted samples are from non-Atria sources. If the row reports
`read_permission_required`, no HealthKit HR reference has been read.

## Key implementation notes

- **Project format:** hand-authored `project.pbxproj` (objectVersion 77) using a
  **file-system-synchronized root group** — any `.swift` added to `Atria/` is
  picked up automatically, no pbxproj edits needed.
- **Bluetooth permission:** declared via the build setting
  `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription` (no manual Info.plist).
- **Finding the strap for realtime/HRV:** Gate A uses a fresh
  `scanForPeripherals` → `connect` path only. `retrieveConnectedPeripherals` is
  deliberately not used for realtime diagnosis because it can attach to a
  system-shared/stale link where the strap ACKs the command but keeps
  command-driven channels silent. If the app cannot find the strap, free it so it
  advertises, then relaunch the app.
- **Scan by service, not UUID:** iOS peripheral UUIDs are per-device, so we scan
  for the WHOOP service + Heart Rate service rather than a hardcoded id.
- **Heart rate/RR parsing:** standard `0x2A37` — flags byte, uint8/uint16 BPM,
  optional Energy Expended, then R-R intervals in 1/1024 seconds. These R-R
  intervals are the primary live HRV source; proprietary `0x28` RR remains
  supplemental diagnostics when present.
- **Command channel + HRV:** after `61080005` notification is confirmed, the app
  waits 3 seconds, then writes `TOGGLE_REALTIME_HR`
  (`encodeFrame([0x23, seq, 0x03, 0x01])`) to `CMD_TO_STRAP` (`61080002`) using
  write-without-response for the current Gate A attempt. The diagnostic overlay
  shows command count, write mode/result, proprietary frame count, realtime frame
  count, and packet signatures; `ATRIADBG` os_log includes command frames and
  command responses. The default path sends this START once. Additional START
  retries are disabled unless the physical-device launcher supplies
  `--atria-realtime-start-retries N`; retry experiments stop as soon as standard
  `2A37` HR/RR or proprietary realtime frames prove the stream is alive. This
  keeps HRV anchored to real RR intervals while avoiding unnecessary command
  chatter during long captures.
- **Debug-only protocol probes:** `live_device_debug.sh --probe-command HEX`
  passes an extra unframed command+data payload to the app after the validated
  START, for example `0301`. The app still frames the command with the current
  sequence byte and logs `ATRIADBG probeCommand` plus the normal `send` line.
  This is for physical-iPhone protocol evidence only; it does not change HRV
  readiness or artifact gates.
- **Historical archive:** historical `0x2f` frames are persisted locally as JSONL
  in `Documents/whoop-historical/historical-archive.jsonl`. Each row stores a
  schema, layout version, raw payload, NOOP-compatible WHOOP 4 historical
  version, provisional HR/RR fields, decoded gravity, clock-correction fields,
  and fail-closed `metricUsable=false` / `currentSessionUsable=false` flags. The app
  logs `ATRIADBG historicalArchive`; if a write fails, future continuation ACKs
  are skipped with `historyAck skip=archive_persist_failed` so the transfer is
  not advanced past unpersisted data. `live_device_debug.sh --pull-historical DIR`
  copies the archive from the physical iPhone for evidence. Gate-status logging
  also reads the on-device archive and reports local parse health, row counts,
  byte count, raw-payload rows, usable-row counts, layout versions, raw/corrected
  Unix ranges, and physically plausible gravity rows. The Gate H row now
  distinguishes protocol expansion from metric use:
  `status=ready`, `historical_download_validated=1`, and
  `gate_h_protocol_exit_ready=1` mean the local archive exists, parses, contains
  raw `0x2f` payload rows, and has zero undecodable rows. It still reports
  `historical_rr_metric_ready=0`, `historical_metric_fail_closed=1`,
  `historical_archive_metric_usable=0`, and
  `historical_archive_current_usable=0` until current-session alignment and
  external validation exist. `tools/analyze_historical_archive.py --sessions-json
  PATH` compares the pulled archive directly with the pulled on-device
  `sessions.json`; this is the preferred current-overlap check when quiet device
  runs do not print every `0x2f` frame in the console log.
  `tools/analyze_historical_archive.py ARCHIVE --usability PATH` combines the
  pulled archive with `tools/analyze_historical_usability.py` output and keeps
  printing `ready=0` for metric usability while protocol exit is separately
  ready.
- **NOOP historical gravity/clock cross-check:** NOOP's WHOOP 4 historical v24
  layout maps raw historical payload offsets to real Unix, HR, RR, and gravity;
  v25 maps Unix plus an i16 gravity vector. The app and
  `tools/analyze_historical_archive.py` now decode those gravity layouts and
  count rows whose gravity magnitude is physically plausible. Stale strap-clock
  correction follows NOOP's fail-closed policy: apply a snapped 5-minute offset
  only when a `GET_CLOCK` reference shows gross drift, and keep corrected rows
  diagnostic-only until current-session overlap and external validation are
  proven. For sleep validation, historical gravity more than 24 hours away from
  the sleep window is labeled `historical_archive_stale` and maps to
  `sleep_motion_unvalidated_historical_stale`, so old stored history can never
  upgrade a current sleep candidate.
- **History-only override:** explicit historical probes now override persisted
  standard-HR-only mode for the custom WHOOP service only. Physical iPhone
  evidence in
  `docs/evidence/gate-h/20260614T032719Z-clock-policy-noop-backfill-override-device-verify/`
  confirmed `61080003/04/05/07` subscriptions, `SET_CLOCK`/`GET_CLOCK`
  correlation (`drift_s=6`), `0x16 [00]` ACK, and `50` codec-clean `0x2f`
  frames pulled into the archive. The analyzer still reports
  `gate_h_current_session_metric_ready=0` and `ready=0` because the selected
  stored range is old March 29, 2026 data with no overlap.
- **Background logging:** `UIBackgroundModes: bluetooth-central` keeps HR notifications
  flowing while backgrounded. The key lives in a partial `Info.plist` at the project
  root (`INFOPLIST_FILE = Info.plist`) which Xcode **merges** with the generated
  keys — kept *outside* the synchronized source folder to avoid a duplicate
  Info.plist build error. (`INFOPLIST_KEY_UIBackgroundModes` is not a supported
  generated-plist setting, hence the file.)
- **Background restoration/checkpoints:** the BLE central uses a CoreBluetooth
  restoration identifier and live `2A37` HR events trigger periodic session
  checkpoint upserts. This is the workout/overnight durability path when iOS
  keeps BLE notifications flowing but ordinary timers may be delayed.
- **Auto-save:** on disconnect, a session with ≥10 samples is finished and handed to
  `SessionStore` via the manager's `onSessionEnd` callback (wired in the app entry).
- **Delayed debug save:** `live_device_debug.sh --auto-save-session-after N`
  forwards `--atria-auto-save-session-after N`, finishing and saving the live HR
  session after N seconds without waiting for a disconnect. This is useful for
  cabled overnight evidence runs where the console launcher would otherwise
  terminate the app before a session is persisted.
- **Periodic debug save:** `live_device_debug.sh --auto-save-session-every N`
  forwards `--atria-auto-save-session-every N`, finishing and saving repeated
  live HR chunks with `mode=periodic`. This is a durability fallback for long
  cabled runs that may lose the CoreDevice console connection; short chunks do
  not satisfy the 3-hour sleep-candidate detector by themselves.
- **Periodic debug checkpoint:** `live_device_debug.sh --checkpoint-session-every N`
  forwards `--atria-checkpoint-session-every N`, upserting the same live HR
  session with `mode=upsert` without resetting it. This is the preferred
  unattended overnight path because the saved record can keep growing toward the
  3-hour HR-only sleep-candidate threshold even if the Mac console later drops.
- **Daily rollup diagnostics:** `live_device_debug.sh --log-daily-rollups`
  forwards `--atria-log-daily-rollups`, logging one `ATRIADBG daily_rollup`
  row per saved day plus `workout_readiness` rows for recent sessions. Workout
  readiness and `live_workout` diagnostics report duration, observed stream
  duration, dropped gap seconds, max sample gap, gap count, avg/peak HR over
  resting baseline, elevated-zone seconds, the HR-reserve workout threshold
  (`threshold_method=hrr50` in preflight), and `threshold_gap_bpm` (how far peak
  HR is below the threshold) before auto-detect can call a real workout. HR
  sample gaps over `5s` are missing data and do not count toward sustained
  elevated bouts.
- **Gate E workout replay:** `--log-gate-status` is now the fast current-store
  blocker table: it emits `ATRIADBG gate_status_summary` and all gate rows
  before any replay-heavy analysis, so short cabled-device status launches do
  not get killed before reporting. The normal Gate E row now runs the bounded
  saved-workout replay directly and includes the best saved attempt's source,
  chunk count, near-miss reason, stream coverage, dropped-gap seconds,
  elevated seconds, sustained bout length, threshold gap, and fail-closed
  historical repair fields. Deep workout/RR forensic replay is opt-in via the
  app launch argument `--atria-log-gate-status-deep`, which leaves the initial
  rows fast, skips slow RR-ledger replay, then logs `gate_status gate=E.deep`,
  `ATRIADBG workout_replay_summary`, threshold sensitivity, and historical gap
  repair. It replays saved sessions and same-day aggregate saved-session chunks
  through the same sustained-workout detector.
- **Low-radio status/export audits:** `live_device_debug.sh` automatically adds
  `--atria-standard-hr-only --atria-long-wear-mode` for status, rollup, widget,
  backup, HealthKit, and store-pull audits unless the command is an explicit
  realtime/probe/history experiment or passes `--full-protocol-mode`. This keeps
  routine current-store evidence on the standard `2A37` + battery channel and
  reserves custom WHOOP traffic for Gate B/H protocol work. The app also
  fresh-scans on standard-HR-only launches and disables restored custom
  notifications, preventing an old full-protocol CoreBluetooth restoration from
  leaking `61080003/04/05/07` traffic into long-wear runs.
  Replay, aggregate workout, and per-session readiness logs include saved HR quality counters
  (`hr_raw_2a37`, accepted samples, zero/contact samples, artifact holds/drops,
  raw/accepted gaps, and max raw/accepted gap seconds) so a failed unattended
  workout can be attributed to low captured HR, sparse delivery, or filtering.
  They also include `threshold_gap_bpm`, so below-threshold failures carry the
  exact bpm shortfall instead of just a boolean blocker.
  Gate status, workout validation, and `tools/analyze_workout_store.py` also
  expose a diagnostic-only `near_miss` flag when enough sparse data exists to
  inspect an activity-like block and the peak HR is close to the HRR50 threshold.
  A near miss never increments workout days or writes workouts; it only explains
  why a likely activity signal stayed below confidence.
  Focused `--verify-sleep` / `--verify-workout-label` launches are now strict
  harness completion targets too: the launcher waits for
  `ATRIADBG sleep_validation` and/or `ATRIADBG workout_validation`, fails with
  `HARNESS_ERROR=sleep_validation_incomplete` or
  `HARNESS_ERROR=workout_validation_incomplete` when missing, and
  `tools/analyze_gate_status.py` synthesizes a focused Gate E row from those
  logs without requiring a full Gate Status replay.
- **Gate readiness UI:** the Local Status card includes a compact A-H readiness
  strip backed by the same local diagnostics as `ATRIADBG gate_status`. It logs
  `ATRIADBG gate_readiness_ui gates=8 ready=N evidence=...` on the physical
  device so the in-app blocker state can be verified without reading every
  detailed gate row. This is a decision surface only: it never promotes HRV,
  workout, HealthKit, widget, or historical metrics past their confidence gates.
  `--log-activity-detections` also emits low-confidence `Activity candidate`
  rows for near-miss saved sessions or aggregates. This is the strength-training
  and gappy-link fallback: workout-like local evidence becomes visible without
  counting the day as a workout, writing HealthKit workouts, or passing Gate E.
  Gate-status logging also emits diagnostic-only
  `ATRIADBG workout_threshold_sensitivity` rows for HRR35/40/45/50. These rows
  rerun the saved-session replay at lower thresholds to identify calibration or
  optical-underread suspicion, but the actual detector remains HRR50 and the
  rows carry `diagnostic_only=1 detector_threshold_hrr50_unchanged=1`.
  Saved replay, threshold-sensitivity rows, Gate E status, Local Status, and
  the store/log analyzers also expose `borderline_*` fields for samples within
  `5 bpm` below the selected threshold. Borderline seconds use the same `5s`
  sample-gap reset as the real detector and are always labeled diagnostic-only;
  they can explain a threshold-edge suspicion but cannot increment workout days
  or pass Gate E.
  The in-app Local Status panel and `ATRIADBG local_status` now surface the best
  saved workout attempt, including source/chunk count, near-miss reason,
  primary blocker, stream coverage, observed seconds, HR threshold gap, elevated
  seconds, bout length, max gap seconds, gap count, an explicit capture
  diagnosis/action, and the diagnostic-only borderline seconds. This keeps a
  returned-from-workout device pull actionable even when the live console missed
  the relevant period. Heavy saved replay, trend preview, and strain-validation
  dashboard diagnostics defer briefly after launch so CoreBluetooth fresh scan,
  notify subscription, and realtime START are not starved by large local stores.
  The same local status now includes fail-closed `historical_gap_repair_*`
  fields. The app compares the saved workout attempt's start/end against the
  on-device historical archive range and reports overlap, separation, current
  usable rows, and metric usability. Historical rows never fill workout gaps or
  pass Gate E unless they overlap the workout window and are explicitly marked
  metric-usable; otherwise the fields remain `diagnostic_only=1` and
  `metric_usable=0`.
  Aggregate workout chunks are grouped only across gaps of `30m` or less;
  sample gaps over `5s` remain missing data and reset elevated-HR bouts.
  `tools/analyze_workout_store.py` mirrors the same HRR50 threshold and accepts
  both raw app-container `sessions.json` files and backup envelopes with ISO
  timestamps.
- **Current-store pull:** `live_device_debug.sh --pull-sessions DIR` copies the
  app's current `Documents/sessions.json` from the physical iPhone app data
  container after the run and also tries to pull the active Long Wear journal as
  `atria-active-session.json` (`whoop-active-session.json` remains a legacy
  fallback). Pair the pulled files with `tools/analyze_workout_store.py
  --active-journal ...` when adidshaft returns from a long wear/workout so the
  saved local history and still-running segment are audited directly instead of
  inferred from console logs.
- **HealthKit export/readback:** after Apple Health write permission is granted,
  `live_device_debug.sh --healthkit-export --log-gate-status` writes only
  confidence-eligible local metrics and then reads Apple Health back. Physical
  iPhone evidence in
  `docs/evidence/gate-g/20260615T-healthkit-permission-live-export-device-verify/`
  saved a fresh incremental HR delta (`hr_samples=63`, `idempotent=1`,
  `incremental=1`) and verified `readback_covers_delta=1` /
  `data_appears=1`. Atria-authored HealthKit HR is diagnostic readback only:
  `healthkit_reference_audit ... independent_hr_samples=0` means those rows are
  not accepted as the external HR reference for Gate D. HRV and workout writes
  remain metric-gated until Gate B/E pass.
  The 2026-06-15 physical iPhone proof in
  `docs/evidence/gate-g/20260614T233211Z-healthkit-post-permission-device-verify/`
  logged cached Health authorization, `healthkit_export status=saved ...
  hr_samples=39 workouts=0 hrv_samples=0`, and
  `healthkit_export_verify status=ok ... readback_covers_delta=1 ...
  data_appears=1`; HealthKit still had `independent_hr_samples=0`, so Gate D
  remains externally unvalidated and Gate G remains `metric_gated`.
  When a launch includes both `--healthkit-export` and `--log-gate-status`,
  Atria now emits a second Gate Status block after the async HealthKit
  save/readback path has time to persist its result. The cabled-iPhone verifier
  in
  `docs/evidence/gate-g/20260614T233522Z-post-healthkit-gate-status-device-verify-2/`
  logged `launch_exports_post_healthkit_gate_status status=completed` and a
  post-readback Gate G row with `healthkit_readback_status=ok` and
  `metric_blockers=healthkit_hrv_reference_pending+healthkit_workout_learning`.
- **Gate E workout log analyzer:** `tools/analyze_gate_e_workout_log.py LOG
  --label LABEL` reduces a ATRIADBG transcript to explicit readiness, blocker,
  HRR50 preflight, validation, historical gap repair, backup, and
  missing-evidence fields. It does not change detector thresholds; it just
  prevents ambiguous "big log, unclear decision" evidence.
- **Windowed workout replay:** saved workout replay now scans realistic
  10-90 minute workout windows inside long saved sessions and saved-session
  aggregates before choosing the best Gate E candidate. The production detector
  is unchanged: HRR50, real HR samples only, stream coverage, elevated seconds,
  continuous bout, and confidence gates still decide readiness. The offline
  `tools/analyze_workout_store.py` audit now mirrors the app's
  `stitched_observed_chunks` candidate, which compresses missing inter-session
  time while inserting 16-second reset gaps. This keeps pulled-store audits
  aligned with the on-device Gate E row: the current best stitched span has
  `stream_coverage_percent=85`, but only `elevated_s=3` and
  `longest_bout_s=3`, so it remains a diagnostic strength candidate rather than
  a counted workout. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T234100Z-stitched-workout-audit-alignment-device-verify/`
  built, launched, pulled `sessions.json`, and saved a corrected
  `workout-store-analysis.txt` with `best_source=stitched_observed_chunks` for
  the HRR50 sensitivity row.
  and continuous-bout gates still decide readiness. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-windowed-workout-replay-device-verify-3/`
  verified `source=windowed_workout` rows on device and kept the current gym
  data fail-closed: `window_ready=0`, `aggregate_window_ready=0`,
  `peak=120`, `threshold=121`, `elevated_s=0`, and
  `primary_blocker=stream_gaps_and_hr_below_threshold`.
- **Stitched observed workout replay:** multi-session workout replay now also
  evaluates `stitched_observed_chunks`, which removes unobserved between-chunk
  wall-clock time from coverage math while inserting reset gaps so sustained-HR
  bouts are still broken honestly. Candidate ranking now prefers the strongest
  intensity evidence with better stream coverage before longer raw span, and
  diagnostic text only blames stream gaps when coverage or the primary blocker
  actually says stream. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T150654Z-stitched-observed-workout-ranked-device-verify/`
  verified `best_source=stitched_observed_chunks`,
  `stream_coverage_percent=85`, `primary_blocker=insufficient_elevated_time`,
  `elevated_s=3`, and `required_elevated_s=1200`. Gate E stayed partial with
  `workout_days=0`; this is an honest diagnosis improvement, not a workout pass.
- **Live workout capture diagnosis:** every `live_workout` and
  `workout_auto_save` decision row now carries `capture_diagnosis`,
  `capture_action`, and the saved/session HR sample counters (`hr_raw_2a37`,
  `hr_accepted`, `hr_zero`, artifact holds/drops, gap counts, max gap seconds,
  and last sample status/reason). This is diagnostic-only and does not loosen
  Gate E. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-live-workout-capture-diagnosis-device-verify-2/`
  verified the fields on the cabled iPhone in low-radio Long Wear:
  `live_ticks=6`, `capture_diagnosis=stream_gaps`,
  `capture_action=keep_learning_reconnect_or_keep_phone_near`,
  `stream_coverage_percent=70`, `max_gap_s=134.3`, `hr_raw_2a37=1090`,
  `hr_accepted=1090`, `hr_zero=0`, `hr_artifact_held=0`,
  `hr_artifact_dropped=0`, and `peak_hr=87` against `threshold_hr=122`.
  The same run confirmed real standard `2A37` RR was flowing
  (`standard_2a37_rr_values=116`) while the active session remained
  fail-closed.
- **One-command Gate E workout audit:** `gate_e_workout_audit.sh` wraps the
  workout capture/pull/analyze flow for post-workout returns. It builds,
  installs, launches through `live_device_debug.sh`, defaults to low-radio
  standard `2A37` HR, pulls current `Documents/sessions.json`, pulls
  `Documents/atria-active-session.json` with a legacy
  `Documents/whoop-active-session.json` fallback, pulls the verified backup, runs
  `tools/analyze_gate_e_workout_log.py`, runs `tools/analyze_workout_store.py`,
  and writes `summary.txt`. The active journal is analyzed as a separate
  `active_journal` candidate and is not merged into aggregate chunks, preventing
  overlap/double-count inflation while still exposing the currently running Long
  Wear segment. By default it analyzes all labels so a persisted Long wear
  session does not hide live evidence under the `Long wear` label. Physical
  iPhone evidence:
  `docs/evidence/gate-e/20260614T-gate-e-workout-audit-wrapper-device-verify/`.
  The smoke produced `missing=none`, `backup_verified=1`, pulled the current
  store, and correctly stayed `gate_e_workout_ready=0` with
  `primary_blocker=stream_gaps_and_hr_below_threshold`.
  Follow-up physical iPhone evidence:
  `docs/evidence/gate-e/20260614T-active-journal-audit-wrapper-device-verify/`
  verified active-journal pull with `active_journal_pull_status=ok` and
  `active_journal=1`. The active candidate was visible but still failed closed:
  `active_journal_ready=0`, `duration_s=1676`, `observed_s=950`,
  `dropped_gap_s=726`, `stream_coverage_percent=57`, `peak=120`,
  `threshold=121`, and `elevated_s=0`.
- **Workout capture-integrity labels:** live workout diagnostics, saved replay,
  aggregate candidates, delayed workout validation, and `local_status` include
  `primary_blocker`/`stream_coverage_percent` so a failed workout is attributed
  to clean short duration, stream gaps, HR below threshold, or a combination
  without relaxing the detector.
- **Strength-candidate diagnostics:** saved workout replay and
  `tools/analyze_workout_store.py` also emit `strength_candidate`,
  `strength_candidate_reason`, `strength_diagnostic_only=1`, and `next_action`.
  This is observe-only. It can label fragmented, strength-training-like HR
  evidence in `local_status`, Gate E status, aggregate workout logs, and
  workout validation, but it never increments workout days, writes HealthKit
  workouts, or passes Gate E unless the existing sustained HRR50 detector passes.
  Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-strength-candidate-diagnostic-device-verify/`
  logged `workout_strength_candidate=1`, `saved_workout_capture_action=
  observe_strength_signal_without_counting`, and
  `next_action=fix_stream_continuity_before_counting` for the current gym data.
- **Dual-blocker next action:** workout diagnostics now return
  `fix_stream_continuity_and_validate_intensity` when a candidate has both
  stream gaps and HR below the personalized HRR threshold. This keeps the same
  fail-closed detector, but stops a stream-continuity label from hiding the
  separate HR-reference/profile blocker. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T142048Z-workout-dual-blocker-action-device-verify/`
  logged several aggregate/windowed candidates with
  `primary_blocker=stream_gaps_and_hr_below_threshold` and
  `next_action=fix_stream_continuity_and_validate_intensity`; Gate E stayed
  partial because the selected best saved aggregate still had
  `workout_best_blocker=stream_gaps`, `workout_days=0`, and no sustained HRR
  bout.
- **Interrupted sleep fallback:** broken-sleep aggregation keeps the strict
  3-hour low-HR total as the primary rule, but now also accepts a labeled
  low-confidence fallback for interrupted nights: at least 2.5 hours of
  low-HR evidence across a 3-hour overnight span, with cluster gaps no larger
  than 2 hours. High-HR/wake chunks remain excluded, motion remains
  unvalidated, and HRV/Recovery stay gated. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T133632Z-fragmented-sleep-fallback-device-verify/`
  logged `broken_sleep_candidate day=2026-06-14 sessions=2 duration_s=10545
  span_s=13706 max_gap_s=3161 avg_hr=60 peak_hr=102 confidence=low` with
  reason `HR-only interrupted overnight low-HR aggregate`, and the daily rollup
  moved to `sleep_candidates=1` for both 2026-06-13 and 2026-06-14. Gate E is
  still partial because `workout_days=0` and motion is not validated.
- **Aggregate sleep validation:** `--verify-sleep` now validates the newest
  aggregate sleep candidate when no specific label is supplied, so interrupted
  nights are not hidden behind the longest single saved session. Physical
  iPhone evidence in
  `docs/evidence/gate-e/20260614T134015Z-aggregate-sleep-validation-device-verify/`
  logged `sleep_validation status=ready reason=aggregate_overnight_low_hr_window
  matched_label=aggregate_sleep_2_chunks source=aggregate_sleep duration_s=10545
  span_s=13706 max_gap_s=3161 samples=6249 confidence=low`.
- **Sleep fallback diagnostics:** Gate Status and `--verify-sleep` now report
  HR-only interrupted-sleep fallback evidence explicitly as diagnostic-only
  fields: `sleep_fallback_available`, `sleep_fallback_source`,
  `sleep_fallback_duration_s`, `sleep_fallback_span_s`,
  `sleep_fallback_chunks`, and `sleep_fallback_diagnostic_only`. This preserves
  the overnight estimate for review while keeping `sleep_ready=0` until current
  motion/IMU or overlapping validated historical gravity exists. Physical
  iPhone evidence in
  `docs/evidence/gate-e/20260615T-sleep-fallback-diagnostics-device-verify/`
  logged `sleep_fallback_available=1`,
  `sleep_fallback_source=hr_only_fragmented_sleep`,
  `sleep_fallback_duration_s=10545`, `sleep_fallback_chunks=2`, and
  `sleep_validation status=learning reason=sleep_motion_unvalidated_historical_stale`.
- **One-command Gate E workout attempt:** `live_device_debug.sh
  --gate-e-workout-capture` expands to the canonical HRR50 workout attempt:
  label `gate-e-hrr50-workout`, `1200s` console capture unless overridden,
  quiet BLE logs, reset link/sample diagnostics, workout preflight, 60-second
  checkpoints, 15-second live-workout diagnostics, 15-second auto-save checks,
  delayed workout validation at `900s`, daily rollups, Gate status, backup
  write, and backup verify. This is the next real-workout path; the detector
  still requires sustained elevated HR and stays `learning` on short/rest runs.
- **Gate E HR-only workout attempt:** `live_device_debug.sh
  --gate-e-hr-only-workout-capture` runs the same workout preset but passes
  `--atria-standard-hr-only` to the app. In that mode the app subscribes to
  standard `2A37` HR/RR and battery, skips WHOOP custom notify streams,
  skips realtime START, disables history ACKs, and budgets `standardHR` payload
  logs to the first five frames plus one per minute with
  `suppressed_since_last=N` unless verbose packet logging is explicitly enabled.
  This is a labeled isolation path for workout capture coverage and possible
  Bluetooth-audio coexistence; HRV remains `learning` unless the normal Gate B
  reference contract is satisfied.
- **Gate E workout contract banner:** the Gate E workout presets now print a
  `HARNESS_GATE_E_WORKOUT_CONTRACT` block before launch. It records the intended
  radio mode, label, capture duration, current expected target HR floor
  (`121 bpm` for the present profile, with the app's `workout_preflight` /
  `live_workout threshold_hr` remaining authoritative), required continuous
  elevated bout (`480s`), total target workout duration (`600s`), minimum stream
  coverage (`75%`), success fields, and fail-closed rules. This makes a real
  workout attempt auditable from the harness log without weakening the detector:
  no HR-only interpolation, no borderline-only workout pass, and no HealthKit
  workout write until the sustained-workout gate is ready.
- **Default production capture:** a normal app launch now bootstraps Long Wear
  + standard `2A37` HR-only radio on first normal launch. It arms 60-second
  checkpoints, 15-second live-workout diagnostics, 15-second strict workout
  auto-save checks, and stale-stream watchdogs without needing a debug preset.
  `--atria-full-protocol-mode` remains the explicit Gate B/H override, and user
  toggles mark capture defaults as configured. `live_device_debug.sh
  --reset-capture-defaults` clears only radio/Long Wear defaults for verification
  without deleting sessions. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-default-long-wear-bootstrap-device-verify/`
  logged `capture_defaults status=enabled`, `radio_mode=standard_hr_only`,
  `long_wear_mode enabled=1`, `checkpoint_source=long_wear`, `notifyState
  ch=2A37`, and no custom realtime stream. This is capture hardening, not a
  Gate E pass.
- **Long-gap chunk rollover:** Long Wear treats a standard `2A37` sample gap of
  `>=30s` as a local segment boundary. The app saves the pre-gap active
  session, clears the active journal, and starts the next received HR sample in
  a clean live segment. Gaps remain missing data in saved history; they are not
  filled or estimated. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-long-gap-rollover-device-verify/` verified
  the original `>=120s` policy with
  `active_session_rollover status=saved ... gap_s=120.7`; later Gate E evidence
  tightened the boundary to `>=30s` so relaunch/debug gaps cannot poison the
  next live workout window. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-gate-e-30s-gap-rollover-device-verify/`
  showed `active_session_rollover ... gap_s=60.8 threshold_s=30.0`, followed by
  fresh live diagnostics at `stream_coverage_percent=100`, `dropped_gap_s=0`,
  and `hr_raw_gaps=0`. Gaps remain fail-closed missing data, not backfill. Gate
  E remains partial because the earlier gym aggregate is still a
  low-confidence HR-only near miss.
  Stale journals are also closed during Long Wear restore once their age exceeds
  the same `30s` boundary, so gate-status diagnostics no longer report an old
  active segment before the first fresh HR notification arrives.
- **Low-radio app mode:** the Local Status card includes a `Low radio HR`
  toggle. It persists `whoop.radio.standardHROnly`, reconnects on changes, and
  applies before characteristic discovery on the next launch/connection. Runtime
  logs include `ATRIADBG radio_mode ...` and `local_status radio_mode=...`.
  Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T000449Z-low-radio-init-device-verify/`
  verified `radio_mode=standard_hr_only`, `standard_2a37_frames=41`,
  `standard_2a37_rr_values=42`, and no custom WHOOP notify frames. Use this for
  long sleep/workout HR collection; use full protocol mode for Gate B/Gate H
  protocol probes.
- **Long-wear app mode:** the Local Status card also includes a `Long wear`
  toggle, and `live_device_debug.sh --long-wear-mode` passes
  `--atria-long-wear-mode` on launch. This persists
  `whoop.longWear.enabled`, forces low-radio standard HR/RR, schedules
  60-second local checkpoints, schedules 15-second live workout diagnostics,
  and arms strict workout auto-save only after the existing sustained-workout
  gate is ready. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T001408Z-long-wear-mode-device-verify/`
  verified `long_wear_mode enabled=1`, `checkpoint_interval_s=60`,
  `live_workout_interval_s=15`, `workout_autosave_interval_s=15`,
  `standard_2a37_frames=80`, `standard_2a37_rr_values=69`, and
  `frame_61080005_count=0`. The first checkpoint saved `samples=62`,
  `rr_samples=54`, `hr_accepted=62`, and no HR gaps over 59 seconds. This is the
  preferred unattended wear/workout mode, but it does not loosen Gate E: stored
  workout replay still stays `learning` when stream coverage or sustained
  elevated HR is insufficient. The HR-continuity watchdog is deliberately less
  aggressive than the RR-quality contract: Long Wear reasserts `2A37` notify
  only after about `12s` of missing raw HR, while the no-data watchdog still
  performs fresh-scan reconnect after a longer stall. This avoids repeated BLE
  notify churn during normal short standard-HR delivery gaps.
  elevated HR is insufficient.
- **Full protocol reset:** `live_device_debug.sh --full-protocol-mode` passes
  `--atria-full-protocol-mode` before CoreBluetooth setup. The app clears the
  persisted Long wear and Low radio HR defaults, cancels Long wear timers, and
  discards CoreBluetooth-restored peripherals so the next attach is a fresh scan
  in full-protocol mode. Gate B/H runs cannot accidentally inherit
  `standard_hr_only` or a stale restored connection from an unattended
  collection session. The expected device evidence is `ATRIADBG
  full_protocol_mode ...`,
  `ATRIADBG long_wear_mode enabled=0 ...`, and `ATRIADBG radio_mode
  mode=full_protocol ...`; if state restoration occurs, expect
  `ATRIADBG ble_restore status=discarded reason=full_protocol_fresh_scan ...`.
  Physical iPhone evidence in
  `docs/evidence/gate-b/20260614T075916Z-full-protocol-reset-device-verify.md`
  verified the full path: restored peripheral discarded, fresh scan connected,
  `61080005` notifications enabled, START sent, CMD_RESP received, and one
  `0x28` realtime frame observed. The frame had `rrnum=0`, so this restores the
  execution channel but does not pass Gate B.
- **Reconnect watchdog:** same-peripheral reconnect attempts now have a
  20-second watchdog. If CoreBluetooth remains in `connecting`, the app logs a
  link failure, cancels the stale connection, clears the stale peripheral, and
  starts the same fresh scan-and-connect path used for normal strap discovery.
  Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-reconnect-watchdog-device-verify/`
  verified the patched app built, installed, launched, restored the strap as
  connected, and kept Long wear streaming with `standard_2a37_frames=66`,
  `standard_2a37_rr_values=67`, live `stream_coverage_percent=100`, and no HR
  gaps. The watchdog did not naturally fire in that short run because restore
  succeeded; it is armed for the next real out-of-range workout attempt.
  Long Wear now also uses fresh scan-and-connect after any real disconnect
  instead of reconnecting the same `CBPeripheral`, keeping the post-gym
  out-of-range path aligned with the strap connection contract. Physical iPhone
  evidence in
  `docs/evidence/gate-e/20260614T-long-wear-fresh-disconnect-policy-device-verify/`
  verified `disconnect_reconnect_policy=fresh_scan`; a follow-up stream run
  restored CoreBluetooth and logged `standard_2a37_frames=90`,
  `standard_2a37_rr_values=81`, with custom WHOOP streams still off.
- **No-data watchdog:** Long wear also watches for connected-but-silent
  standard HR streams. By default it checks every 15 seconds and treats
  30 seconds without a `2A37` notification as stale. On stale data, it
  checkpoints the real samples already collected and forces fresh scan/reconnect.
  Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-no-data-watchdog-device-verify/` verified the
  watchdog schedule plus non-disruptive collection:
  `standard_2a37_frames=72`, `standard_2a37_rr_values=69`,
  `frame_61080005_count=0`, live `stream_coverage_percent=100`, and no HR gaps.
  The watchdog did not fire because the short run stayed healthy.
- **Active session journal:** Long wear persists accepted standard `2A37` HR
  samples into `Documents/atria-active-session.json` every small batch and before
  checkpoint/diagnostic decisions, then restores the same live session on app
  relaunch or CoreBluetooth restoration. The legacy
  `Documents/whoop-active-session.json` path is still readable for old evidence.
  `local_status` and Gate E status include
  `active_journal_present`, `active_journal_samples`, `active_journal_age_s`, and
  `active_journal_duration_s`. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-active-session-journal-device-verify/` verified
  a two-launch flow: phase 1 saved `samples=42 duration_s=40`; phase 2 restored
  `samples=70 duration_s=74 age_s=5` and immediately reported
  `live_workout_samples=70` instead of restarting from zero. The same runs stayed
  in low-radio mode (`frame_61080005_count=0`) and kept Gate E partial because no
  sustained elevated-HR workout had validated.
  Physical iPhone evidence in
  `docs/evidence/gate-e/20260615T-active-journal-pull-flushed-device-verify/`
  verified the current pull path: the harness built and launched Atria, forced an
  active journal flush (`active_session_journal status=saved ... samples=22
  rr_values=23`), pulled `ATRIADBG_ACTIVE_JOURNAL_PULL_FILE=.../atria-active-session.json`
  from `Documents/atria-active-session.json`, and `tools/analyze_workout_store.py`
  reported `active_journal=1`. The same evidence kept Gate E partial; this is
  current-evidence extraction, not a workout detector pass.
- **Active journal RR persistence:** Long wear now persists real standard
  `2A37` RR values in the active journal as well as HR samples, restores them
  into `rrArchive`, and surfaces `active_journal_rr_values` in `local_status` and
  Gate status. Physical iPhone evidence in
  `docs/evidence/gate-b/20260614T-active-journal-rr-persistence-device-verify/`
  verified phase 1 saved after real RR arrived
  (`active_session_journal status=saved ... rr_values=2`) and phase 2 restored
  RR on relaunch (`active_session_journal status=restored ... rr_values=11`),
  then continued to `rr_values=22` from `2A37`. The run stayed low-radio
  (`frame_61080005_count=0`). This fixes an app-side RR continuity loss path; it
  does not pass clinical Gate B because external RR/IBI reference validation is
  still missing.
- **Active journal RR continuity diagnostics:** `local_status` and the Gate E
  log analyzer now report `active_journal_rr_max_gap_s`,
  `active_journal_rr_gap_over_3s`, `active_journal_rr_gap_over_5s`, and
  `active_journal_rr_coverage_3s_percent` from real persisted `2A37` RR
  arrivals. These fields are diagnostic only: RR is never used to fabricate HR
  samples or pass workout/HRV gates. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-active-journal-rr-continuity-device-verify/`
  verified the current Long wear journal with `active_journal_rr_values=1554`,
  `active_journal_rr_max_gap_s=124.6`,
  `active_journal_rr_gap_over_3s=85`,
  `active_journal_rr_gap_over_5s=73`, and
  `active_journal_rr_coverage_3s_percent=53`. This rules out RR-backed local
  repair for the current workout attempt; the saved aggregate remains blocked by
  `stream_gaps_and_hr_below_threshold`.
- **Active journal lifecycle flush:** the app force-saves the active Long wear
  journal when the scene goes inactive/background, when the process terminates,
  and through the debug hook `--atria-flush-active-journal-after N` exposed by
  `live_device_debug.sh --flush-active-journal-after N`. Physical iPhone evidence
  in
  `docs/evidence/gate-e/20260614T-active-journal-lifecycle-flush-device-verify/`
  verified the same save path with `active_session_journal status=saved
  reason=debug_timer samples=693 duration_s=743`, then normal batch persistence
  continued to `samples=710 duration_s=759`. The run stayed in low-radio mode
  (`frame_61080005_count=0`) with `standard_2a37_rr_values=25`; Gate E remained
  partial because saved workout replay still reported
  `stream_gaps_and_hr_below_threshold`.
- **Durable session-store upsert:** final session saves now report whether the
  `sessions.json` write succeeded, and same-ID final saves replace existing
  checkpoint rows instead of inserting duplicates. The active Long wear journal
  is cleared only after a confirmed durable save; on failure the journal is
  retained and logged. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-session-store-durable-upsert-device-verify/`
  verified `session_store_save status=ok op=add mode=replace ... samples=986
  duration_s=1042`, followed by `active_session_journal status=cleared
  reason=session_auto_save`, then fresh journal persistence at `samples=25
  duration_s=23`. The run had no store-failure or retained-journal rows.
- **Replay de-dupe:** workout replay, aggregate workout/sleep candidates, daily
  rollups, and today strain now canonicalize saved sessions by ID in memory,
  preferring the longest/newest row, so existing duplicate checkpoint/final rows
  do not double-count. Raw local history is left intact for backups/audit.
  Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-replay-dedupe-device-verify/` logged
  `workout_replay_summary raw_sessions=69 canonical_sessions=68`, while Gate E
  stayed `partial` with `workout_saved_ready=0` and
  `stream_gaps_and_hr_below_threshold`.
- **BLE link diagnostics:** the app persists BLE link attempts, disconnects,
  successes, failures, last status/reason/error, and the disconnect auto-save
  result. `ATRIADBG local_status` and `gate_status gate=E` include these as
  `ble_link_*` fields so workout failures can distinguish CoreBluetooth link
  churn from sample-level HR coverage gaps. `live_device_debug.sh
  --reset-link-diagnostics` forwards `--atria-reset-link-diagnostics` to clear
  counters before a physical-device run. If `didFailToConnect` fires, the app
  falls back to a fresh scan instead of staying on a stale peripheral.
- **HR sample-gap diagnostics:** the app persists raw `2A37` notification count,
  accepted HR sample count, zero-contact samples, artifact holds/drops, raw
  notification gaps, accepted-sample gaps, and max raw/accepted gap seconds.
  `local_status` and Gate E status include these as `hr_*` fields. `live_device_debug.sh
  --reset-sample-diagnostics` forwards `--atria-reset-sample-diagnostics` for a
  clean physical-device run. A raw gap means iOS did not deliver a standard HR
  notification within the HR/workout continuity limit; an accepted gap means the
  app did not add an HR sample within that limit. That HR/workout limit is `15s`
  because standard BLE Heart Rate (`2A37`) can arrive in short bursts even while
  connected. RR/HRV still uses the stricter Gate B rule (`no >3s RR gap`) and is
  not relaxed by this. Saved sessions and automatic backups also carry the
  per-session HR quality fields, and backup verification logs compare
  backup/current HR totals so unattended captures remain auditable after
  relaunch. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-gate-e-hr-workout-gap-tolerance-device-verify/`
  verified the split: live workout coverage stayed at `100%` with no HR gaps,
  while RR quality remained `poor_contact`/`learning`.
- **HR-continuity watchdog:** Long wear now has a pre-gap `2A37` watchdog in
  addition to the accepted-HR reconnect watchdog. When standard HR notifications
  are stale for `3.5s` while connected in standard-HR-only mode, the app
  reasserts notification on the cached Heart Rate Measurement characteristic
  and reads it if the characteristic supports read. The action is logged as
  `ATRIADBG hr_continuity_watchdog ... action=<reassert_notify|read_reassert_notify>`
  and persisted so detached physical-device launches can be verified later with
  `--atria-log-hr-continuity-watchdog-state`. The launcher exposes this through
  `live_device_debug.sh --force-hr-continuity-watchdog-after N` and
  `--log-hr-continuity-watchdog-state`. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T043504Z-hr-continuity-watchdog-detached-device-verify/`
  verified a forced detached action: `status=forced`, `action=reassert_notify`,
  `notifying=1`, with the analyzer reporting `hr_continuity_watchdog_actions=1`.
  This is capture hardening; it does not lower the workout detector or synthesize
  missing HR.
- **Accepted-HR watchdog:** Long wear now has a second stale-stream watchdog
  in addition to the no-data watchdog. If accepted HR samples stop for 12s while
  the app remains connected, the app checkpoints the current real samples,
  force-flushes the active journal, and reconnects through the fresh-scan path.
  The reconnect request also arms a delayed fallback scan, so if iOS does not
  deliver the disconnect callback promptly the app still clears the stale
  peripheral and starts a new scan instead of waiting silently. Fresh scans log
  `ATRIADBG ble_scan status=started|matched|retry` with the reason and retry
  count, making scan stalls auditable in cabled runs.
  If raw `2A37` packets are still arriving but the last sample status/reason is
  zero contact, the watchdog logs `stale_contact` and waits instead of
  reconnecting for a fit/contact problem. Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T-accepted-hr-watchdog-device-verify/` verified
  `accepted_hr_watchdog schedule timeout_s=12.0 interval_s=15.0` and
  `long_wear_mode ... accepted_hr_timeout_s=12 ... disconnect_reconnect_policy=fresh_scan`.
  A forced physical-device verifier is available through
  `live_device_debug.sh --force-accepted-hr-watchdog-after N`, forwarding
  `--atria-force-accepted-hr-watchdog-after N`. Evidence in
  `docs/evidence/gate-e/20260614T-accepted-hr-watchdog-forced-device-verify-2/`
  verified the recovery outcome with post-action diagnostics:
  `checkpoint_last_status=saved_accepted_hr_watchdog`,
  `checkpoint_last_samples=2589`, `checkpoint_last_duration_s=3030`,
  `ble_link_disconnects=1`, `ble_link_successes=2`, and
  `ble_link_last_autosave=saved`. The direct forced watchdog log line was not
  captured because the console stream ended before the delayed timer fired, so
  this evidence is outcome verification rather than a direct-line capture.
  This hardens the next workout capture; it does not retroactively pass the
  existing gym aggregate, which remains blocked by
  `stream_gaps_and_hr_below_threshold`.
- **Low-radio fresh-scan verification:** Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T121628Z-low-radio-reconnect-fallback-device-verify/`
  built, installed, and launched the app in standard-HR-only Long Wear mode with
  reset link/sample diagnostics. The app logged `ble_scan status=started`,
  `ble_scan status=matched`, `ble_link status=connected`, and `notifyState
  ch=2A37 notifying=1`, then saved a checkpoint with `samples=125`,
  `duration_s=120`, `hr_raw_2a37=125`, `hr_accepted=125`, `hr_raw_gaps=0`,
  and `hr_accepted_gaps=0`. Live workout diagnostics reached
  `stream_coverage_percent=100` over `141s` with `147` accepted HR samples.
  Custom protocol remained off (`notify_61080005=False`,
  `realtime_start=False`, `frame_61080005_count=0`). This fixes the current
  low-radio capture path for future workouts; Gate E remains partial because
  this verification was a below-threshold rest window and the previous gym
  aggregate remains fail-closed.
- **Forced reconnect recovery verification:** Physical iPhone evidence in
  `docs/evidence/gate-e/20260614T122128Z-forced-low-radio-reconnect-fallback-device-verify/`
  forced the accepted-HR watchdog after `25s`. The app checkpointed real data,
  logged `accepted_hr_watchdog status=forced ... action=fresh_scan_reconnect`,
  received `did_disconnect`, saved the segment, started a fresh scan, matched
  the strap, reconnected (`attempts=2`, `successes=2`, `disconnects=1`), and
  resubscribed to `2A37`. Post-reconnect live diagnostics reported
  `stream_coverage_percent=100`, `samples=45`, `duration_s=41`,
  `dropped_gap_s=0`, `hr_raw_gaps=0`, and `hr_accepted_gaps=0`. Custom protocol
  remained off (`notify_61080005=False`, `realtime_start=False`,
  `frame_61080005_count=0`). This verifies reconnect survival for unattended
  low-radio collection, not workout completion.
- **Quiet long-wear logging:** raw BLE packet `NSLog` rows (`standardHR
  payload`, `realtimeFrame`, raw `frame ch=...`, unknown packet hex, and raw RR
  packet dumps) are opt-in via `--atria-log-ble-frames`. `live_device_debug.sh`
  requests verbose packet logs by default so forensic captures still work; pass
  `--quiet-ble-logs` for low-noise long wear where higher-level rows such as
  `live_workout`, `session_checkpoint`, battery, gate status, HRV summaries,
  and validated sleep-motion hints are enough. In standard-HR-only mode,
  `standardHR payload` logs are now budgeted even without `--quiet-ble-logs`,
  and dashboard `strain_explain`/`local_status` logs are time-gated so large
  saved stores do not flood the foreground capture path.
- **HR artifact policy diagnostics:** `live_device_debug.sh
  --log-hr-artifact-policy` forwards `--atria-log-hr-artifact-policy`, logging
  `ATRIADBG hr_artifact_policy` cases for isolated jumps, confirmed jumps, and
  stale-median-after-gap acceptance. Runtime `ATRIADBG hr_artifact` rows use the
  same policy: isolated `>50 bpm` jumps are held/dropped, repeated aligned jumps
  are accepted, and post-gap jumps are accepted so real workout rises are not
  discarded because of an old resting median.

## Verified working

- Live **84 BPM** with sparkline, **43%** battery, **WHOOP Inc.**, "Connected" —
  on device, 2026-06-11.
- Gate A realtime unlock verified on adidshaft's physical iPhone, 2026-06-12:
  `61080005` notify confirmed, write-without-response sent
  `aa0800a82300030199bce9cf`, `61080003` returned command response
  `24c6030002000000`, and sustained `0x28` realtime frames arrived on
  `61080005`.
- Gate B HRV pipeline smoke-verified on adidshaft's physical iPhone, 2026-06-12:
  realtime RR fed the clinical analyzer, which logged `raw=45 kept=45 conf=100
  window=34 ready=0 rmssd=26.9 sdnn=34.8 pnn50=4.5 lnrmssd=3.29`. `ready=0` is
  expected before the 5-minute window is complete.
- Gate B `2A37` RR path verified on adidshaft's physical iPhone, 2026-06-13:
  `standardHR payload=10435f03 hr=67 rrnum=1 rr_ms=843`, with a pulled
  `2A37`-primary ready capture (`raw=345 kept=315 conf=91 window=300
  max_rr_gap_s=2.8`). Clinical Gate B remains reference-pending until an
  external RR/IBI recorder agrees within +/-5 ms RMSSD.
- Gate B saved RR-ledger replay verified on adidshaft's physical iPhone, 2026-06-13:
  `rr_ledger_summary ... best_ready=1 ... raw=347 kept=317 conf=91
  max_rr_gap_s=2.8 reference_validated=0`, while
  `gate_status gate=B status=reference_pending` kept the external-reference
  requirement explicit. The live minute in that smoke had no fresh RR, so no
  live HRV number was promoted.
- Gate B saved RR reference-package export verified on adidshaft's physical iPhone,
  2026-06-14: `rr_reference_package status=ok` exported and pulled a
  validator-ready CSV/manifest from the app container. The selected real RR
  window was `raw=347 kept=317 conf=91 max_rr_gap_s=2.8 interpolated=0
  rmssd=50.2`. The CSV self-parse smoke passed only as a parser check;
  `gate_status gate=B status=reference_pending` remains correct until an
  external RR/IBI reference agrees within +/-5 ms RMSSD.
- Gate B/G launch export hardening verified on adidshaft's physical iPhone,
  2026-06-14: launch-driven HealthKit, HR-reference, and RR-reference exports
  are deferred and explicitly logged. The bounded RR exporter avoided the
  previous launch-time kill and pulled a ready real-RR package
  (`raw=368 kept=361 conf=98 max_rr_gap_s=1.8 rmssd=32.7`) while HealthKit saved
  `42198` real HR samples and no gated-out workouts/HRV.
- Gate B RR reference reducer + early-exit verification on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-rr-reference-early-exit-device-verify/`.
  The run built cleanly, installed/launched Atria, exported and pulled a
  WHOOP-side RR package (`raw=368`, `kept=361`, `conf=98`,
  `max_rr_gap_s=1.8`, `rmssd=32.7`), then ran on-device validation against the
  current `Documents/atria-reference/rr-reference.csv`. Validation correctly
  failed with `reason=reference_window`: the reference file had only `5` raw
  samples and was not a valid 300-second independent RR/IBI recording
  (`gate_b_pass=0`, `reference_validated=0`). The harness reported
  `rr_reference_package_complete=True` and `rr_reference_validation_complete=True`
  and exited without `HARNESS_CAPTURE_TIMEOUT`. Gate B remains
  `reference_pending`.
- Gate B reference validator honesty guard verified on adidshaft's physical iPhone,
  2026-06-14:
  `docs/evidence/gate-b/20260614T-reference-validator-honesty-guard-device-verify/`.
  The app built, installed, launched, exported a ready saved RR package, and the
  updated validator rejected default same-file comparison as
  `same_file_not_external_reference` with `gate_b_pass=0`; explicit
  `--allow-self-compare` returned `parser_smoke_pass` while still reporting
  `external_reference=0`.
- Gate B strict-live beat-gap verification on adidshaft's physical iPhone,
  2026-06-14:
  `docs/evidence/gate-b/20260614T143646Z-strict-live-rr-beat-gap-device-verify/`.
  The app built, installed, launched, wrote HealthKit HR with cached permission
  (`hr_samples=355 workouts=0 hrv_samples=0`), and started strict live capture
  after a clean short `2A37` RR gate (`fraction=1.000`, `max_rr_gap_s=1.1`).
  The full run did not pass Gate B: `standard_2a37_frames=440`,
  `standard_2a37_rr_frames=259`, `standard_2a37_rr_values=342`,
  `capture_quality_resets=5`, `max_rr_log_gap_s=33.1`, and final `2A37`
  payload was HR-only (`rrnum=0`). HRV correctly stayed `learning`.
- Gate B beat-timeline auto-gate verification on adidshaft's physical iPhone,
  2026-06-14:
  `docs/evidence/gate-b/20260614T151533Z-beat-timeline-rr-gate-device-verify/`.
  The app built, installed, launched, and received real `2A37` RR
  (`standard_2a37_frames=394`, `standard_2a37_rr_frames=159`,
  `standard_2a37_rr_values=217`), but the auto-capture gate did not start
  because the reconstructed RR beat timeline still exceeded the strict 3-second
  max-gap contract (`auto_capture_start=False`, `capture_summary_ready=False`,
  `max_rr_log_gap_s=60.4`). This rules out BLE notification batching as the sole
  explanation for that run; HRV correctly stayed `learning`.
- Fresh all-gates audit on adidshaft's physical iPhone, 2026-06-14:
  `docs/evidence/gate-status/20260614T152558Z-fresh-all-gates-post-beat-timeline-audit/`.
  The app built, installed, launched, exported HealthKit HR, verified backup,
  logged widget readiness, trends, daily rollups, and deep gate status, then
  pulled sessions/backups. Current readiness is `gate_readiness_ui gates=8
  ready=2`: Gate G is `ready` and Gate H is `ready`; Gates B/C/D/E/F remain
  honestly gated by external RR/HR reference, HRV baseline, workout evidence,
  and trend coverage. HealthKit readback covered the fresh delta
  (`hr_samples=432`, `data_appears=1`), widget/app group/complication
  diagnostics were ready, and backup verification reported `digest_match=1`.
- Gate B on-device RR reference validator verified on adidshaft's physical
  iPhone, 2026-06-14:
  `docs/evidence/gate-b/20260614T153533Z-on-device-rr-reference-validator-final/`.
  `--atria-validate-rr-reference` exports the best saved WHOOP RR package and
  compares it to `Documents/atria-reference/rr-reference.csv` when present,
  using the same 300-second, no-`>3s`-gap, `>=240` corrected beats,
  `>=75%` kept, and `+/-5 ms` RMSSD rules as the Mac validator. It also rejects
  same-content copies of Atria's own export. The device run exported a ready
  WHOOP package (`raw=368`, `kept=361`, `conf=98`, `max_rr_gap_s=1.8`,
  `rmssd=32.7`) and correctly stayed reference-pending because the independent
  file was missing (`gate_b_pass=0`, `external_reference=0`).
- Gate D on-device HR reference validator verified on adidshaft's physical
  iPhone, 2026-06-14:
  `docs/evidence/gate-d/20260614T154423Z-on-device-hr-reference-validator-final/`.
  `--atria-validate-hr-reference` exports the best saved real `2A37` HR segment
  and compares it to `Documents/atria-reference/hr-reference.csv` when present,
  using the same `+/-2 bpm` contract as the Mac validator. It rejects
  same-content copies of Atria's own export. The device run exported a WHOOP HR
  package (`samples=11236`, `duration_s=10801`, `coverage_percent=100`,
  `avg_hr=58.1`, `peak_hr=85`, `resting_hr=47`) and correctly kept Gate D
  partial because the independent file was missing (`gate_d_pass=0`,
  `external_reference=0`).
- Gate D strain verifier completion verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-d/20260615T-strain-harness-completion-device-verify/`.
  `live_device_debug.sh --log-strain-validation` now waits for the
  `ATRIADBG strain_validation` row and reports
  `strain_validation_complete=True`. The verified run built cleanly,
  installed/launched Atria, and reduced the current store into a focused Gate D
  row. Gate D remained `partial` with
  `stream_coverage_below_75_percent+missing_high_zone_exposure+max_hrr_below_85_percent+external_hr_reference_missing`;
  the best day had `stream_coverage_percent=39`, `high_z3_z4_s=0`,
  `max_hrr_percent=51`, and `external_hr_reference_validated=0`.
- Gate D HR reference reducer and terminal-validation harness verified on
  adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/gate-d/20260615T-hr-reference-reducer-device-verify/`.
  The run built cleanly, installed/launched Atria, connected to
  `ADIDSHAFT'S WHO`, exported a ready WHOOP-side HR package
  (`samples=11236`, `duration_s=10801`, `coverage_percent=100`,
  `avg_hr=58.1`, `peak_hr=85`, `resting_hr=47`), and then failed closed against
  the current external CSV with `reason=insufficient_pairs`
  (`reference_samples=5`, `pairs=10`, `mean_delta_bpm=5.10`,
  `max_delta_bpm=6.00`, `within_tolerance_percent=0`,
  `gate_d_pass=0`). The reducer reports Gate D as `partial` with blocker
  `insufficient_pairs`; the next proof is a real independent HR reference CSV
  with enough paired samples inside the `+/-2 bpm` contract.
- Reference CSV push smoke verified on adidshaft's physical iPhone,
  2026-06-14:
  `docs/evidence/gate-reference/20260614T155030Z-reference-push-smoke/`.
  The launcher copied Mac-side smoke CSVs into
  `Documents/atria-reference/rr-reference.csv` and
  `Documents/atria-reference/hr-reference.csv`, then Atria consumed both files
  on-device. The tiny fixtures intentionally failed closed:
  `rr_reference_validation status=fail reason=reference_window gate_b_pass=0
  external_reference=1` and
  `hr_reference_validation status=fail reason=insufficient_pairs gate_d_pass=0
  external_reference=1`. Real reference CSVs overwrite these smoke files.
- Reference input cleanup verified on adidshaft's physical iPhone, 2026-06-14:
  `docs/evidence/gate-reference/20260614T155714Z-reference-clear-device-verify/`.
  `--atria-clear-reference-inputs` removed both prior smoke files
  (`reference_inputs_clear status=ok removed=2 missing=0 failed=0`) before the
  validators ran. HR and RR validation then returned to missing-reference
  status with `gate_d_pass=0`, `gate_b_pass=0`, and `external_reference=0`.
- HealthKit export harness guard verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-g/20260615T-healthkit-permission-current-verify/`. The
  first permission recheck exposed that the device harness could stop after
  `healthkit_export status=saved` before the asynchronous
  `healthkit_export_verify` readback line arrived. The harness now treats
  `--healthkit-export` as incomplete until `ATRIADBG healthkit_export_verify`
  is logged, so future Gate G runs cannot mistake a save callback for Apple
  Health readback evidence. The post-patch physical-device rerun then stayed
  alive through `healthkit_export_verify status=ok reason=up_to_date
  readback_covers_delta=1 data_appears=1`.
- Active motion IMU preset verified on adidshaft's physical iPhone,
  2026-06-15:
  `live_device_debug.sh --active-motion-imu-check` now forces full-protocol
  mode, resets protocol counters, logs the expected active wrist-motion script,
  and can delay Gate Status via `--log-gate-status-after N` so the status row
  reflects the protocol window. The immediate smoke in
  `docs/evidence/gate-h/20260615T-active-motion-imu-preset-device-verify/`
  exposed early status ordering (`protocol_packets=0`). The delayed rerun in
  `docs/evidence/gate-h/20260615T-active-motion-imu-delayed-status-device-verify/`
  built, installed, launched, pulled sessions, and logged a complete post-window
  status with live RR/custom traffic (`realtime_rr_fraction=0.956`,
  `protocol_packets=2`, `protocol_event_frames=1`) but no current motion source
  (`protocol_imu_frames=0`, `protocol_diagnostic_frames=0`,
  `sleep_motion_hint_count=0`). The app keeps motion-derived sleep/workout
  evidence in **learning** until a deliberate active-motion script produces
  nonzero live IMU/current-motion evidence or an external official-app/sniffer
  trace reveals the missing trigger.
- Active motion result row verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-h/20260615T-active-motion-result-row-device-verify/`.
  `--atria-active-motion-imu-check` now schedules a delayed
  `ATRIADBG active_motion_imu_check` result row, configurable with
  `--atria-active-motion-result-after N`. The verified run installed and
  launched Atria on the cabled iPhone, connected to the strap, enabled the full
  custom notify set, sent START, and produced
  `status=no_strap_motion_signal` with `protocol_packets=3`,
  `protocol_imu_frames=0`, `protocol_diagnostic_frames=0`,
  `sleep_motion_hint_count=0`, `phone_motion_over_still_threshold=0`, and
  `metric_promotions=0`. No sleep/workout metric was promoted; the row is a
  faster fail-closed decision point for the single-device motion path.
- Capture summaries keep RMSSD, SDNN, pNN50, lnRMSSD, and respiratory rate as
  **learning** until the same 5-minute validation gate is ready.
- Current RR continuity priority verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-rr-continuity-local-priority-device-verify/`.
  `ActiveSessionJournal` now exposes typed RR continuity diagnostics instead of
  requiring Gate Status to parse its own evidence string. The verified run
  restored a fresh active journal with real `2A37` RR
  (`active_journal_rr_values=12`) but a collapsed current stream
  (`active_journal_rr_max_gap_s=31.0`,
  `active_journal_rr_coverage_3s_percent=1`). Gate Status therefore logged
  `execution_priority next_gate=B
  next_action=restore_current_rr_continuity_before_external_reference
  next_local_gate=B
  next_local_action=restore_current_rr_continuity_no_gap_over_3s`. The saved
  clean RR candidate remains visible as a personal-baseline/unverified HRV
  value when the local data-sufficiency gates pass; only the `validated` badge,
  clinical Gate B pass, and HealthKit HRV export wait for an external RR/IBI
  reference.
- HR-continuity reconnect escalation: when standard `2A37` notifications remain
  stale for a second watchdog window, Atria now flushes the active journal and
  fresh scan-connects from the HR-continuity watchdog instead of waiting for the
  later no-data/accepted-HR watchdogs. Reconnect requests log before
  CoreBluetooth cancellation, immediately start a fresh scan, and keep a
  1-second fallback scan if iOS does not deliver a timely disconnect callback.
  This targets the current observed 31-91 second RR gaps without estimating RR
  from HR-only frames.
- RR-presence reconnect escalation: if the current segment already has real RR
  and later standard `2A37` frames continue as HR-only (`rrnum=0`) past the RR
  presence timeout, Atria now fresh scan-connects immediately. Segments with no
  RR yet still get one gentler notify/read reassert first.
- RR-startup recovery cadence: when a fresh long-wear segment has enough valid
  `2A37` HR to prove the stream is alive but still has zero RR, Atria first
  reasserts/reads `2A37` instead of reconnecting immediately. It escalates to a
  fresh scan only after the stream stays stale or the same RR-presence failure
  repeats. The 2026-06-15 cabled iPhone run in
  `docs/evidence/gate-b/20260615T-current-rr-gap-sentinel-device-verify/`
  verified `hr_continuity_watchdog status=stale ... action=reassert_notify`
  before later reconnect escalation. HRV remains **learning** throughout;
  HR-only frames are never converted into RR.
- Large-store Gate Status fast path verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-bounded-large-store-status-direct-install-verify/`.
  The previous current-state audit reached `gate_status_start` on the 273
  session store and then iOS killed Atria with signal 9 before
  `execution_priority`. Fast Gate Status now detects a large store and emits a
  bounded fail-closed status instead of replaying the expensive RR/workout,
  HealthKit, historical, sleep, and trend diagnostics inline. The physical
  iPhone run installed the signed Atria build, launched it, verified the latest
  backup with `digest_match=1`, logged
  `gate_status_progress stage=bounded_fast_large_store`, all gate rows, and
  `execution_priority`, then the harness completed with
  `gate_status_complete=True`, `backup_verify_complete=True`, and
  `radio_low_traffic_complete=True`. The bounded row is intentionally not a
  metric pass: skipped diagnostics are labeled as skipped, Gate B remains
  `reference_pending`, Gate D remains external-reference blocked, and Gate G/H
  targeted diagnostics must be run separately when needed.
- Bounded Gate Status analyzer alignment verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-status/20260615T-bounded-analyzer-clarity-device-verify/`.
  `tools/analyze_gate_status.py` now treats `skipped_bounded_audit` as a
  deliberate bounded-mode result instead of ordinary missing data. For bounded
  fast rows it reports Gate E as
  `sleep_replay_skipped_bounded_audit,workout_replay_skipped_bounded_audit`,
  Gate F as `trend_replay_skipped_bounded_audit`, Gate G as requiring dedicated
  HealthKit readback diagnostics, and Gate H as
  `historical_archive_skipped_bounded_audit`. A no-build physical iPhone launch
  confirmed the same bounded ATRIADBG rows, backup digest match, and low-radio
  readiness, and the analyzer output points to targeted follow-up diagnostics
  rather than claiming a pass or a generic capture failure.
- Targeted Gate E/F diagnostics verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-targeted-ef-diagnostics-device-verify/`.
  The targeted no-build launch ran daily rollups, sleep validation, workout
  preflight, trends, backup verify, and low-radio BLE on the real phone. Gate E
  remains fail-closed with useful reasons: sleep has two HR-only candidates but
  stays `learning` because current motion/IMU is not validated and the
  historical gravity window is stale; the best saved workout aggregate is a
  diagnostic strength candidate only (`stream_coverage=85%`, peak `122 bpm`,
  threshold `121 bpm`) but has only `3s` elevated time versus `1200s` required
  and a longest bout of `3s` versus `480s` required. Gate F remains learning:
  coverage is `3/5` days for 7-day partial, `3/21` for 30-day, and `3/63` for
  90-day, with HRV/recovery points still gated by external RR reference.
- Focused Gate E validation reducer verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-focused-validation-reducer-device-verify/`.
  The run built cleanly, installed/launched Atria, and completed both strict
  focused verdicts (`sleep_validation_complete=True`,
  `workout_validation_complete=True`). The reducer synthesized Gate E as
  `partial` with the concrete blockers
  `sleep_motion_unvalidated_historical_stale` and
  `near_miss:stream_gaps:stream_coverage_low+elevated_seconds_below_required+continuous_bout_below_required`.
  Current sleep has an HR-only fragmented fallback (`10545s`, `2` chunks) but
  stale/unvalidated motion, and the best workout aggregate has peak `122` vs
  threshold `121` but only `3s` elevated and `37%` stream coverage. No workout,
  sleep, or HealthKit metric was promoted.
- Gate F trend harness completion verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-f/20260615T-trend-harness-completion-device-verify/`.
  `live_device_debug.sh --log-trends` now waits for `trend_summary` and all
  `7/30/90` trend windows before succeeding, then reports
  `trend_summary_complete=True` and `trend_windows_complete=True`. The verified
  run built cleanly, installed/launched Atria, connected BLE in standard-HR-only
  long-wear mode, and logged the current local trend truth: `sessions=282`,
  7-day `coverage_days=3/5` (`confidence=partial`), 30-day `3/21`
  (`learning`), 90-day `3/63` (`learning`), `hrv_state=reference_pending`,
  `anomaly_flags=none`, and blockers
  `coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
  This is verifier hardening, not a Gate F pass.
- Dedicated Gate G platform readback verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-g/20260615T-dedicated-platform-readback-device-verify/`.
  Atria wrote `716` incremental HR samples to HealthKit and read them back with
  `healthkit_export_verify status=ok`, `readback_covers_delta=1`,
  `expected_total_reconciled=1`, and `data_appears=1`. HealthKit reference
  audit remained fail-closed because all `48879` HR samples in the comparison
  window were Atria-authored and no independent source was present. Widget
  storage is ready (`app_group=1`, `widget_target=1`,
  `complication_target=1`), backup digest matched, and notification scheduling
  was authorized but scheduled zero production notifications because recovery
  is learning, strain depends on recovery confidence, and battery is not low.
  The app was later killed with signal 9 after the requested diagnostics had
  completed; Gate G is therefore platform/readback verified but still
  metric-gated by HRV reference and workout learning.
- Dedicated Gate G widget snapshot verifier completed on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-g/20260615T-widget-harness-completion-device-verify/`.
  The harness now fails closed unless `ATRIADBG widget_snapshot` appears. The
  verified run logged `widget_snapshot_complete=True` with shared app-group
  storage and signed widget/complication targets ready; the reducer synthesized
  Gate G as `metric_gated` with
  `healthkit_hrv_reference_pending+healthkit_workout_learning`.
- History-only probe isolation, 2026-06-15:
  `docs/evidence/gate-h/20260615T-single-device-noop-backfill-current-recheck/`.
  A NOOP-style `1400,6000,1600` recheck on the real iPhone pulled the persisted
  local archive (`728` codec-clean rows) but did not receive new live `0x2f`
  frames. The evidence showed Atria's long-wear HR/RR watchdogs forcing fresh
  reconnects during the explicit history-only init sequence, so history-only
  probe mode now suppresses no-data, HR-continuity, RR-presence, and accepted-HR
  reconnect actions. This keeps future protocol probes attached long enough to
  judge the strap response while preserving the normal long-wear recovery policy
  outside explicit probe mode. The stale archive remains diagnostic-only and
  cannot unblock HRV, sleep, or workout metrics without current overlap.
  Post-fix device evidence in
  `docs/evidence/gate-h/20260615T-history-probe-watchdog-suppressed-device-verify/`
  confirms the fix: the same command sequence produced live `0x2f` rows and a
  pulled `50`-row archive while the watchdogs logged
  `action=suppressed_history_only_probe` instead of reconnecting. The corrected
  historical range is still March 29, 2026, so Gate H stays protocol-ready but
  metric-fail-closed.
- First-screen usability and stable HR-first BLE policy verified on
  adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-stable-hr-first-device-verify/`.
  The dashboard now puts a cheap `Today` card directly under connection status:
  live HR, local strain, recovery/HRV confidence, saved session count, and local
  logging state. Heavy sleep/workout/trend/gate replay stays behind the warmed
  diagnostics section, so launch no longer blocks on full local-status
  reduction. The verified build installed and launched Atria, emitted
  `ATRIADBG today_usability`, connected to `ADIDSHAFT'S WHO`, subscribed to
  `2A37`, and received real standard HR/RR payloads such as
  `payload=104b0703 hr=75 rrnum=1 rr_ms=757`. To reduce Bluetooth churn during
  normal long-wear use, the RR-presence watchdog no longer tears down a healthy
  HR connection just because RR is missing; it now logs
  `action=hold_hr_connection_reassert_2a37` and keeps HRV in `learning` unless
  real RR continuity is present. This is a usability/reliability improvement,
  not a Gate B pass.
- Gate H history-probe harness/reducer hardening verified on adidshaft's
  physical iPhone, 2026-06-15:
  `docs/evidence/gate-h/20260615T-history-probe-early-exit-fix-device-verify/`.
  The launcher now treats explicit historical/probe requests as pending
  post-gate work and will not declare the run complete from a pulled archive
  alone; history probes must observe live `0x2f` frames or reach the capture
  timeout. The focused device run built cleanly, launched Atria with
  `--atria-history-only-probe`, skipped realtime START, sent `0x22`, received a
  `cmdResp`/`data_range_response`, and stayed attached until
  `HARNESS_CAPTURE_TIMEOUT seconds=45`. During that probe, no-data,
  HR-continuity, accepted-HR, and RR-presence watchdogs logged
  `action=suppressed_history_only_probe` rather than reconnecting, preserving
  the protocol window. It did not receive `historical_2f_frames` in this
  minimal probe, so no Gate H metric moved. The broader `1400,6000,1600`
  history-init sweep in the same evidence folder was killed by iOS before any
  `ATRIADBG` line and is explicitly not counted. The reducer now also fails
  closed for bare historical-archive analyzer output: a stale local archive is
  reported as Gate H `partial` until stored-transfer and codec evidence are
  present.
- App-side Gate H honesty verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-h/20260615T-app-gate-h-honesty-device-verify/`. Atria
  now applies the same fail-closed rule in its dashboard/gate-status path: a
  stale local historical archive is not enough to show Gate H as ready. The
  cabled iPhone run built cleanly, launched Atria, completed fast gate-status
  logging, and emitted `ATRIADBG gate_status gate=H status=partial` with
  `historical_archive=skipped_bounded_audit` and
  `historical_metric_fail_closed=1`. The execution-priority row also kept Gate
  H in `local_blocked` rather than `ready`. This removes the previous mismatch
  where the app UI could show `H=ready[metric_fail_closed]` while the stricter
  reducer reported `partial`.
- Quiet historical proof and current-selector recheck, 2026-06-15:
  `docs/evidence/gate-h/20260615T-noop-backfill-current-selector-recheck-device-verify/`.
  A targeted NOOP/WHoof-style history-only run built, installed, and launched
  on the cabled iPhone, performed `SET_CLOCK`/`GET_CLOCK` with `drift_s=1`,
  sent `0x14 [00]`, `0x60 [00]`, and `0x16 [00]`, and received
  `cmd_response_last_cmd=0x16` with status `06020b0000`. The quiet console
  did not print raw `ATRIADBG frame` rows, but the app emitted `50`
  `ATRIADBG historicalData` rows and persisted a `100`-row archive. The
  launcher and `tools/analyze_historical_usability.py` now count app-level
  `historicalData` payloads as historical transfer evidence, so quiet runs no
  longer summarize real downloads as zero frames. The pulled archive is
  codec-clean and has physically plausible NOOP gravity
  (`noop_historical_gravity_validated_rows=100/100`), but the corrected range is
  still `2026-03-29T23:17:19Z` to `2026-03-29T23:18:07Z`. Therefore Gate H
  protocol evidence is real, while `historical_archive_current_usable=0` and
  `historical_archive_metric_usable=0` remain binding. These rows must not feed
  HRV, recovery, sleep, workout, trends, or HealthKit metrics. A follow-up
  physical-device build/install/launch in
  `docs/evidence/gate-h/20260615T-quiet-history-row-count-device-verify/`
  verified the harness on the cabled iPhone but hit a BLE timeout before the
  `0x16` response/history rows; it is recorded as a timeout and was not retried.
- Actionable local priority verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-actionable-local-priority-device-verify/`.
  Fast gate status now keeps external blockers and local diagnostics separate.
  When B/C/D are blocked by missing external RR/HR references, Atria no longer
  reports `next_local_gate=none`; it emits a concrete local path. The verified
  cabled-iPhone run logged `execution_priority next_gate=B` with
  `external_blocked=B:external_rr_reference,C:validated_hrv_baseline_0_of_7,D:external_hr_reference`,
  then `next_local_gate=H`,
  `next_local_action=run_targeted_historical_diagnostics_then_healthkit_readback_if_needed`,
  plus `secondary_local_gate=G` for dedicated HealthKit readback. Metrics remain
  gated; this only makes the app's next-step diagnostics truthful and
  actionable.
- Usable local priority routing verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-usable-local-priority-routing-device-verify/`.
  After stale historical selector evidence, Atria no longer sends bounded fast
  audits back into blind Gate H retries. The cabled iPhone run built, installed,
  launched, connected to `ADIDSHAFT'S WHO`, and logged
  `execution_priority next_gate=B next_action=restore_current_rr_continuity_before_external_reference`
  because the active journal had current HR samples but no RR values. It then
  set `secondary_local_gate=G` with
  `secondary_local_action=run_healthkit_readback_after_rr_presence`, kept
  `H:historical_metrics_fail_closed` in `diagnostic_only`, and preserved
  `skip=no_start_retry_no_blind_history_selector_no_fake_metrics`. The bounded
  Gate H row now says
  `action=skip_blind_history_selector_until_new_evidence`. This is routing and
  usability evidence only; all reference-gated metrics remain learning/partial.
- Gate H protocol-status split verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-h/20260615T-gate-h-protocol-status-device-verify/`.
  The proof run aligned the dashboard readiness row with Gate Status:
  `gate_readiness_ui ... H=ready[protocol_ready_metrics_fail_closed_current_usable_0_metric_usable_0]`
  and `gate_status gate=H status=ready`. The cached local historical archive
  is codec-clean for protocol purposes (`historical_download_validated=1`,
  `gate_h_protocol_exit_ready=1`, `historical_archive_rows=100`,
  `historical_archive_raw_payload_rows=100`,
  `historical_archive_undecodable_rows=0`,
  `historical_archive_gravity_validated_rows=100/100`), while metric use remains
  barred (`historical_rr_metric_ready=0`, `historical_metric_fail_closed=1`,
  `historical_archive_metric_usable=0`,
  `historical_archive_current_usable=0`). This is a Gate H protocol-exit
  status fix only; HRV, sleep, workout, and HealthKit metrics stay gated by
  their own evidence contracts.
- Atria product-name/device-process cleanup verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-atria-product-name-device-verify/`.
  The build now produces `Atria.app` with executable `Atria`, the device install
  reported `installationURL=.../Atria.app/`, and the console log prefix was
  `Atria[...]`. A stale legacy `Whoop.app/Whoop` process and old widget
  extension were still alive after install; they were terminated, leaving only
  `/Atria.app/Atria`. The non-disruptive pull now reports
  `process_status=running` and `process_name_status=atria`, so future physical
  device evidence does not falsely report the app as missing.
- Current-store Gate E decision, 2026-06-15:
  `docs/evidence/gate-e/20260615T160055Z-current-store-workout-decision/`.
  The pulled store has `400` sessions, but the workout analyzer found
  `ready=0`, `aggregate_ready=0`, `window_ready=0`, and
  `aggregate_window_ready=0`. The best HRR50 candidate reached peak `122` vs
  threshold `121`, but only `3s` above threshold and a `3s` longest bout versus
  the required `1200s` elevated and `480s` bout. Sensitivity checks at HRR35,
  HRR40, and HRR45 also produced `ready_candidates=0`. This rules out a clean
  detector pass from the current store and keeps the strength signal
  diagnostic-only rather than loosening thresholds to fake Gate E.
- Fast workout Today-card evidence verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-fast-workout-today-card-device-verify/`.
  The first screen now uses a bounded saved-workout reducer over recent local
  sessions, so it can surface post-gym evidence without running the full
  replay-heavy Gate E reducer at launch. The verified run built cleanly,
  installed and launched Atria on the cabled iPhone, reconnected to
  `ADIDSHAFT'S WHO`, and logged `ATRIADBG today_usability` with
  `workout_value=strength`, `workout_strength_candidate=1`,
  `workout_near_miss=1`, `workout_peak_hr=120`,
  `workout_threshold_hr=121`, `workout_stream_coverage_percent=87`, and
  `workout_duration_s=3030`. Atria still did not count this as a validated
  workout because the evidence was `stream_gaps_and_hr_below_threshold`; the UI
  now says the strength-like signal was saved and remains fail-closed until HR
  intensity/continuity evidence is stronger.
- Today battery and RR package surface verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-today-battery-rr-package-device-verify/`.
  The first screen now shows strap battery, a strict saved-RR package state, and
  baseline maturity beside the existing live HR/strain/workout cards. The RR
  package uses the same saved-window reducer as the Gate B export path, not an
  HR-derived estimate. Physical-device proof logged `rr_package_ready=1`,
  `rr_package_samples=24469`, `rr_package_raw=368`,
  `rr_package_kept=361`, `rr_package_conf=98`,
  `rr_package_gap_s=1.8`, and `rr_package_rmssd=32.7`; this is labeled as
  reference-ready only because `reference_validated=0`. A 60s follow-up launch
  waited for live BLE battery and logged `battery level=40 source=2A19` plus
  `today_usability_update reason=battery battery_level=40`. Gate readiness
  stayed fail-closed (`B=reference_pending`, `C=learning`, `E=partial`,
  `G=metric_gated`, `H=partial`), so this improves usability without promoting
  any gated metric.
- Usable Gate G local platform loop verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-g/20260615T-usable-healthkit-backup-reference-nobuild-device-verify/`.
  Xcode's full physical build/install attempt was blocked by iPhone development
  services requiring an unlock, so this proof is explicitly a `--no-build`
  launch of the already installed current Atria bundle, followed by a separate
  green generic iOS build. The device run wrote and verified a backup
  (`sessions=301`, `rr_samples=24573`, `digest_match=1`), pulled a JSON-valid
  backup file, exported `665` incremental Atria HR samples to HealthKit, and
  read the store back with `readback_atria_hr_samples=50260`,
  `expected_total_atria_hr_samples=50260`, `readback_covers_delta=1`,
  `expected_total_reconciled=1`, and `data_appears=1`. The HealthKit reference
  audit correctly remained fail-closed (`independent_hr_samples=0`,
  `external_reference_ready=0`), so Atria-authored HealthKit data is only
  readback evidence, not an external HR reference. The same launch connected to
  `ADIDSHAFT'S WHO`, received standard `2A37` RR, and completed the
  low-traffic radio path; Gate G remains metric-gated by missing validated HRV
  and workout exports.
- Today platform row verified on adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-usable-platform-today-card-device-verify/`.
  The first screen now shows Backup, Health, and Reference status beside the
  existing HR/strain/RR/workout tiles. Backup is backed by a store-level
  digest/status check, Health is explicitly Atria HR readback, and Reference
  remains missing until independent HR/HRV evidence is imported. The build was
  green; xcodebuild's physical-destination preflight reported an unlock/
  development-services warning, but direct `devicectl` installed the app and the
  harness launched it on the cabled iPhone. The device log verified
  `backup_current=1`, `backup_sessions=301`, `backup_rr_samples=24573`,
  `health_readback=ok`, `health_data_appears=1`,
  `health_atria_hr_samples=50260`, `health_expected_hr_samples=50260`,
  `reference_ready=0`, and
  `reference_reason=independent_reference_missing`; the run also reconnected to
  `ADIDSHAFT'S WHO` and completed low-traffic radio mode. No metric gate was
  promoted.
- Today sleep candidate verified on adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-today-sleep-candidate-device-verify/`.
  The first screen now shows Sleep beside Workout/Log using the existing
  fail-closed `SleepEvidenceStatus` reducer. HR-only overnight evidence is shown
  as a candidate, not a validated sleep metric, until motion evidence is
  validated. The device run built green, installed, launched on the cabled
  iPhone, reconnected to `ADIDSHAFT'S WHO`, and logged
  `sleep_value=candidate`, `sleep_ready=0`, `sleep_state=low_confidence`,
  `sleep_blocker=sleep_motion_unvalidated_historical_stale`,
  `sleep_candidates=2`, `sleep_fallback=1`,
  `sleep_fallback_source=hr_only_fragmented_sleep`,
  `sleep_fallback_duration_s=10545`, `sleep_fallback_span_s=13706`, and
  `sleep_motion_validated=0`. Gate E remains learning; this only makes the
  overnight evidence visible and honest.
- Today settled-state diagnostics verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-today-connection-settled-device-verify/`.
  The Today card now logs an update when BLE connects or when live HR first
  arrives, and has a waiting-state diagnostic if the strap stays disconnected
  after launch. The verified run built green, installed, launched, connected to
  `ADIDSHAFT'S WHO`, received real `2A37` RR, and logged
  `today_usability_update reason=connected connected=1` followed by
  `today_usability_update reason=live_hr connected=1 hr=67`. The settled row
  replaced the initial pre-connect action with the useful fail-closed action:
  `Strength signal saved; Atria will not count it as workout until HR evidence
  is stronger.` Gate B stayed `reference_pending`, Gate E stayed `learning`,
  and Gate G stayed `metric_gated`.
- Daily evidence card verified on adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-daily-evidence-card-device-verify-4/`.
  The first screen now shows a compact `Detected locally` card with today's
  saved minutes, local activity/sleep candidates, and saved RR count. It uses a
  bounded recent-session reducer on launch and treats the existing saved
  strength/near-miss signal as an activity candidate, not a counted workout.
  The device run built green, installed, launched, reconnected to
  `ADIDSHAFT'S WHO`, received standard `2A37` RR, and logged
  `daily_evidence_ui ... sessions_today=142 saved_minutes=58 rr_saved=1877
  activity_candidates=1 workout_signal=1
  workout_diagnosis=fragmented_stream_and_below_threshold diagnostic_only=1`.
  Gate B remained `reference_pending`, Gate E remained `learning`, and Gate G
  remained `metric_gated`.
- Collection reliability card verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-collection-reliability-card-device-verify/`.
  The first screen now shows long-wear/checkpoint protection, active-journal
  freshness, RR presence, and watchdog recovery state without replaying the
  full store. The physical run built green, installed, launched, connected to
  `ADIDSHAFT'S WHO`, received real standard `2A37` RR, and logged
  `collection_reliability_ui ... long_wear=1 checkpoint_armed=1 ... fail_closed=1`.
  A follow-up refresh run restored a fresh journal and logged
  `journal_present=1 journal_fresh=1 journal_rr_values=2
  journal_rr_coverage_3s_percent=100 rr_present=1`, then later exposed the
  live RR-presence watchdog as `rr_presence_status=hr_only` while keeping HRV
  fail-closed. This improves unattended collection visibility only; no metric
  gate was promoted.
- Bounded Gate G cached-platform status verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-g/20260615T-bounded-gate-g-cached-platform-device-verify/`.
  The fast large-store Gate Status path now reuses cached HealthKit readback,
  widget/app-group, and backup evidence instead of reporting
  `healthkit_status_skipped_bounded_audit`. The verified run built green,
  installed, launched on the cabled iPhone, wrote and verified a current backup
  (`sessions=308`, `digest_match=1`), exported and read back Atria HR in
  HealthKit with `expected_total_reconciled=1` and `data_appears=1`, logged
  `widget_readiness status=ready`, delivered the diagnostic notification, and
  kept low-radio `standard_hr_only` ready. Gate G now reports
  `platform_ready=1` and `status=metric_gated` with blockers limited to
  `healthkit_hrv_reference_pending+healthkit_workout_learning`; the execution
  router logs `local_blocked=none`, so future work should move to metric
  validation instead of replaying platform plumbing. No HRV, workout, or
  HealthKit metric was promoted.
- User-confirmed workout export verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-user-confirmed-workout-healthkit-device-verify/`.
  Atria now lets the user confirm the strongest saved local activity candidate
  with the `Confirm Activity` UI or the debug
  `--atria-confirm-best-workout-candidate` launch path. The confirmed item is
  stored separately from strict auto-detected workouts, exported to HealthKit
  with `atria_workout_source=user_confirmed`, and remains labeled
  `auto_gate_e_unchanged=1` so Gate E is not falsely advanced. The focused
  device run confirmed one long-wear/strength-like candidate
  (`duration_s=47889`, `observed_s=17744`, `samples=19085`, `peak_hr=122`,
  `confidence=user_confirmed_near_miss`) and HealthKit saved/read back
  `workouts=1` plus `hr_samples=70` with `expected_total_reconciled=1`. The
  follow-up status run showed Gate G `platform_ready=1` with
  `healthkit_workouts=1`; the remaining Gate G metric blocker is HRV reference
  validation. Gate E still remains `learning` until sustained automatic workout
  detection passes without user confirmation.
- User-confirmed sleep candidate verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-user-confirmed-sleep-device-verify/`.
  Atria now lets the user confirm the strongest saved local sleep candidate
  with `Confirm Sleep` or the debug `--atria-confirm-best-sleep-candidate`
  launch path. The confirmed item is stored as `UserConfirmedSleep` and remains
  local-only with `metric_promotions=0`, `auto_gate_e_unchanged=1`, and
  `healthkit_source=none`. The verified run built green, installed, launched
  on the cabled iPhone, and confirmed an HR-only interrupted overnight aggregate
  (`start=2026-06-14T01:00:21Z`, `end=2026-06-14T04:48:46Z`,
  `duration_s=10545`, `span_s=13706`, `sessions=2`, `samples=6249`,
  `avg_hr=60`, `peak_hr=102`, `confidence=user_confirmed_hr_only`). A follow-up
  launch logged `daily_evidence_ui ... confirmed_sleeps=1
  sleep_motion_validated=0` and `sleep_confirm status=already_confirmed`.
  Automatic Gate E sleep remains learning/partial until validated motion
  evidence is available; this phase only makes the single-device overnight
  evidence usable and durable.
- User-confirmed sleep HealthKit export prepared but permission-gated on
  adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/gate-g/20260615T-user-confirmed-sleep-healthkit-device-verify/`.
  Atria now builds HealthKit Sleep Analysis samples from `UserConfirmedSleep`
  with `atria_sleep_source=user_confirmed`, `auto_gate_e_unchanged=1`, and
  `metric_promotions=0`; Gate G evidence also reports `healthkit_sleeps=1`.
  The cabled device run built green, installed, launched, and confirmed the
  existing sleep item, but iOS held the new Health permission at
  `healthkit_export status=authorization_pending ... sleeps=1 read_sleep=1`.
  No sleep sample was written or read back, and the harness correctly failed
  with `healthkit_export_verify_complete=False` and
  `healthkit_sleep_export_verify_complete=False`. This is not a Gate G pass;
  the next run must grant Apple Health Sleep Analysis access on the iPhone and
  rerun the same harness command.
- HealthKit partial export fallback verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-g/20260615T-healthkit-partial-sleep-defer-device-verify/`.
  Atria no longer lets a pending Sleep Analysis permission block already
  authorized HealthKit HR export. The cabled device run built green, installed,
  launched, confirmed the local sleep item, logged
  `healthkit_sleep_export status=permission_required ... authorization=not_determined`,
  then exported the authorized HR delta with `sleeps=0`. Apple Health readback
  verified `expected_delta_hr_samples=157`,
  `expected_total_reconciled=1`, and `data_appears=1`; the harness summary
  reported `healthkit_export_verify_complete=True` and
  `healthkit_sleep_export_deferred_complete=True`. No sleep sample was written
  or promoted, and Gate G remained `metric_gated` by
  `healthkit_hrv_reference_pending`.
- Recovery guidance explainability verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-c/20260615T-recovery-guidance-explainability-device-verify/`.
  The daily guidance card now consumes the full Recovery estimate instead of a
  nullable percent, so it displays and logs the exact reason guidance is
  learning when Recovery is not high-confidence. The cabled device run built
  green, installed, launched, and logged
  `guidance_decision recovery=learning recovery_confidence=learning
  target=learning state=learning reason=recovery_learning_not_high
  recovery_detail=learning__need_validated_HRV`. The same run kept Gate C
  `learning` with `validated_hrv_baseline=0/7`, and the delayed in-app gate row
  now matches Gate Status for Gate G:
  `G=metric_gated[platform_ready_metric_blockers:healthkit_hrv_reference_pending]`.
  This is an explainability/usability fix only; no HRV, Recovery, or automatic
  workout metric was promoted.
- HRmax calibration hint verified on adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/gate-d/20260615T-hrmax-calibration-hint-device-verify/`.
  The Profile card now surfaces the highest real HR Atria has observed from
  saved and live samples, and only offers a user-confirmed `Use peak` raise when
  observed HR exceeds the current measured HRmax. It never lowers HRmax from a
  submax session and never changes the profile automatically. The cabled device
  run built green, installed, launched, and logged
  `hrmax_calibration_ui ... observed_peak=122 saved_peak=122 live_peak=82
  measured_max_hr=190 active_max_hr=189 source=ageEstimate can_raise_measured=0
  suggestion=keep_profile_no_auto_lower auto_change=0
  user_confirmation_required=1`. Gate D stayed `partial`; strain validation
  still requires stream coverage, high-zone exposure, and an external HR
  reference before the rest-to-max accuracy exit can pass.
- Strict sleep candidate split verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-strict-daily-rollup-sleep-candidates-device-verify/`.
  Daily rollups and Local Status now separate validated sleep days from
  low-confidence HR-only sleep candidates. The cabled device run built green,
  installed, launched, and logged `daily_rollup_summary ... sleep_ready_days=0
  sleep_candidate_days=2 workout_days=0`; the two overnight candidates remained
  `sleep_ready=0` with `sleep_gate_strict=1`. The Today card showed
  `sleep_value=candidate`, `sleep_ready=0`,
  `sleep_blocker=sleep_motion_unvalidated_historical_stale`, and Gate E stayed
  `learning`. This makes the app more usable without promoting weak sleep
  evidence into completed sleep metrics.
- Confirmed workout rollup split verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-confirmed-workout-rollup-device-verify/`.
  Daily rollups and Local Status now separate strict automatic workout days
  from manually confirmed workout evidence. The cabled device run built green,
  installed, launched, and logged `daily_rollup_summary ... workout_days=0
  confirmed_workout_days=1 confirmed_workouts=1`; the June 14 row kept
  `workouts=0 confirmed_workouts=1 workout_gate_strict=1`. Gate E stayed
  `learning`, and the Today card still reported the saved activity as
  strength/near-miss evidence rather than an automatic workout. The same pull
  saw `broken_sleep_summary candidates=2`, so the reported short nap did not
  produce a new sleep candidate under the current strict duration/overnight
  detector.
- Rest/nap candidate diagnostics verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-rest-nap-candidate-device-verify/`.
  Atria now classifies short low-HR saved sessions as `Rest candidate` evidence
  instead of silently dropping them from local history. Rest candidates are
  labeled `rest_diagnostic_only=1`, do not count as sleep, do not feed
  HRV/Recovery, and do not promote Gate E. The cabled device run built green,
  installed, launched, and logged `daily_rollup_summary ...
  rest_candidate_days=1 rest_candidates=1 ... sleep_ready_days=0
  sleep_candidate_days=2`; the detected rest candidate was on June 14. The
  same run's Today evidence showed `rest_candidates=0`, so adidshaft's reported
  short nap did not produce a saved current-day low-HR rest chunk under the
  current detector.
- Confirmed sleep HealthKit permission recheck verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-g/20260615T-healthkit-sleep-permission-retry-device-verify/`.
  After the user reported granting Apple Health write access, the cabled device
  run built green, launched Atria, confirmed the existing local sleep item, and
  retried the HealthKit export path. Sleep Analysis is still permission-gated on
  this device:
  `healthkit_sleep_export status=permission_required sleeps=1
  authorization=not_determined`, so no sleep sample was written or read back.
  The partial exporter still saved and reconciled the authorized HR delta
  (`hr_samples=489`, `expected_total_reconciled=1`, `data_appears=1`), and the
  harness reported `healthkit_sleep_export_deferred_complete=True`. Gate G
  remains `metric_gated`; this is a permission checkpoint, not a sleep export
  pass.
- HealthKit Sleep Analysis authorization request verified on adidshaft's
  physical iPhone, 2026-06-15:
  `docs/evidence/gate-g/20260615T-healthkit-sleep-auth-request-devicectl-nobuild/`.
  The exporter now treats Sleep Analysis `not_determined` as an authorization
  request path instead of silently dropping the confirmed sleep sample from the
  writable plan. The cabled iPhone run installed and launched Atria through
  `devicectl` after Xcode's destination service rejected the CoreDevice id
  namespace, then logged `healthkit_sleep_export status=authorization_required
  sleeps=1 authorization=not_determined action=request_health_sleep_analysis`
  followed by `healthkit_export status=authorization_requested ... sleeps=1`
  and the watchdog row `healthkit_export status=authorization_pending ...
  action=approve_health_permissions_on_device`. The harness records
  `healthkit_export_authorization_pending_complete=True` and leaves the app
  running in low-radio long-wear mode. This proves the app now asks iOS for
  Sleep Analysis; no sleep sample was written/read back in this checkpoint
  because the permission prompt was still pending. Gate G remains
  `metric_gated`, not passed.
- Manual checkpoint and Today-card stability verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-manual-checkpoint-device-verify/`.
  Atria now has a non-destructive `Save checkpoint` action beside
  `Finish & save session`, plus a debug launch trigger
  `--atria-manual-checkpoint-after N`. The first verification launch exposed a
  SwiftUI/iOS 27 stack-guard crash while building the large Today card; the
  crash report is preserved in the evidence folder. The card was then hardened
  by rendering metrics from data-driven rows, rebuilt, reinstalled, and
  relaunched successfully. The cabled device logged
  `manual_checkpoint status=saved samples=11 duration_s=10 ... reset_live_session=0`,
  `session_store_save status=ok op=checkpoint`, and
  `session_backup_auto status=ok reason=session-checkpoint`; the live journal
  stayed fresh after the checkpoint. This makes short rest/nap/workout slices
  easier to preserve without ending long-wear collection.
- Manual checkpoint harness wiring verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-manual-checkpoint-harness-device-verify/`.
  `live_device_debug.sh --manual-checkpoint-after N` now forwards the app's
  debug trigger through the standard cabled-device harness. Two physical-iPhone
  runs built green, installed, launched, and logged `HARNESS_LAUNCH_ARGS ...
  --atria-manual-checkpoint-after 15` / `45`, followed by
  `manual_checkpoint schedule delay_s=... source=launch_arg`. The delayed run
  also showed the honest failure mode when the strap did not reconnect inside
  the evidence window: `connected=0`, repeated fresh BLE scans, and
  `checkpoint_last_status=skipped_manual_insufficient_samples`; no empty
  checkpoint or promoted metric was created.
- Post-harness long-wear relaunch verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-leave-running-after-harness/`.
  After the checkpoint harness stopped its console session, Atria was relaunched
  in standard-HR-only long-wear mode with `--leave-running`. The evidence run
  matched the strap, connected, parsed real standard `2A37` R-R intervals
  (`standardHR ... rrnum=2`, `rr_quality source=2a37 fraction=1.000`), and
  saved the active journal (`samples=20 rr_values=24 duration_s=18`) before the
  harness relaunched Atria headless with 60-second checkpoints and 15-minute
  autosaves. Workout stayed `learning` because HR was below the configured
  workout band; this is a continuity proof, not a metric promotion.
- Gate B 5-minute capture harness guard verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-standard-2a37-5min-capture-after-reconnect/`.
  `--pull-capture DIR` now waits for a real `ATRIADBG capture_file` path before
  the harness treats post-run work as complete. Before the guard, the harness
  interrupted Atria immediately after launch. After the guard, the same
  420-second physical-device run stayed alive, connected to the strap, and
  honestly failed closed: `standard_2a37_frames=5`,
  `standard_2a37_rr_frames=0`, `auto_capture_start=True`,
  `capture_summary_ready=False`, and no capture CSV was copied because no RR
  window existed. Atria saved the HR-only chunk and left HRV/Recovery in
  learning/reference-pending.
- Missing standard-HR characteristic recovery verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-missing-2a37-recovery-device-verify/`.
  When Atria is connected but its cached `2A37` characteristic is missing, the
  HR/RR watchdog now actively rediscovers the Heart Rate service instead of
  passively waiting. If the characteristic remains missing after the watchdog
  timeout and the raw HR gap is stale, Atria checkpoints the active journal and
  escalates to a fresh scan. The cabled-device proof used
  `--force-missing-2a37-after 18` to clear the cached characteristic only after
  real `2A37` discovery, then logged `missing_2a37_debug status=forced
  had_characteristic=1`, `hr_continuity_watchdog ...
  action=rediscover_2a37_service`, and a follow-up `notifyState ch=2A37
  notifying=1`. That verification run carried HR-only `2A37` payloads
  (`rrnum=0`), so HRV/Recovery correctly stayed in learning and Gate B did not
  advance.
- Activity diagnostic cap and delayed gate-status wait verified on adidshaft's
  physical iPhone, 2026-06-15:
  `docs/evidence/gate-status/20260615T-activity-diagnostics-cap-device-verify/`.
  `--atria-log-activity-detections` now emits only the top 12 ranked detections
  and includes kind totals plus `emitted`/`suppressed` counts in
  `ATRIADBG activity_detect_summary`. The activity-only cabled-device run logged
  `detections=60 emitted=12 suppressed=48 workouts=0 activity_candidates=58
  sleep_candidates=1 rest_candidates=1`, connected to `ADIDSHAFT'S WHO`, and
  relaunched Atria in long-wear mode. `live_device_debug.sh` also no longer
  treats post-gate side effects as completion while a delayed Gate Status row is
  still requested; a focused gate-status run reached `gate_status_complete`.
  Combined activity+daily+trend+gate audits are still too heavy for the current
  large local store and should be split into focused launches. This is tooling
  reliability only; it does not promote any metric gate.
- RR-presence refresh verified on adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-rr-presence-refresh-device-verify/`. Xcode's
  direct physical destination again reported `observing system notifications
  failed`, and the harness correctly fell back to a generic signed iOS build
  with `devicectl` install/launch. After reconnect, real standard `2A37` RR
  arrived and the app refreshed stale RR-presence evidence:
  `rr_presence_status=rr_present`, `rr_presence_action=observe_real_rr_0x2A37`,
  `rr_presence_rr_values=19`, and `rr_presence_age_s=0.5`. Gate Status also
  saw the fresh active journal (`active_journal_rr_values=17`,
  `active_journal_rr_coverage_3s_percent=100`) while keeping Gate B
  `reference_pending` because the independent RR/IBI reference is still
  missing. The harness relaunched Atria in standard-HR-only long-wear mode with
  `--leave-running`.
- RR-presence fresh reconnect policy verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-b/20260615T-rr-presence-fresh-reconnect-device-verify/`
  and
  `docs/evidence/gate-b/20260615T-rr-presence-forced-reconnect-device-verify/`,
  with a follow-up clamp check in
  `docs/evidence/gate-b/20260615T-rr-presence-clamped-gap-device-verify/`.
  The RR-presence watchdog now reaches its fresh-scan branch for
  `segment_hr_only`, RR-present-to-HR-only, or repeated RR-presence stalls
  instead of always falling back to notify/read reassert. The harness has
  `--force-rr-presence-watchdog-after N` for focused physical-device proof of
  this branch. The fresh reconnect run restored real standard `2A37` RR and
  Gate Status logged `active_journal_rr_values=25`,
  `active_journal_rr_coverage_3s_percent=100`, while Gate B remained
  `reference_pending`. After an interrupted forced proof, Atria was relaunched
  cleanly in standard-HR-only long-wear mode and the process list confirmed it
  was running. The clamp check rebuilt and relaunched on the same iPhone,
  logged `rr_presence_accepted_gap_s=0.0`, restored real `2A37` RR, and left
  Atria running.
- Current-segment RR honesty verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-current-segment-rr-honesty-device-verify/`.
  The Collection card/log now treats only the active journal's current RR as
  `rr_present`; old RR-presence ledger values surface as `saved_rr_only` until
  new current-segment RR arrives. The physical run built, installed, launched,
  and logged both `rr_present=0 rr_presence_status=saved_rr_only` after a
  rollover and `rr_present=0 rr_presence_status=segment_hr_only` once the new
  active segment had accepted HR but no RR. The same run kept
  `rr_package_ready=1`, so saved RR remains usable while HRV stays honest.
- Execution-router upstream blocker fix verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-execution-router-snapshot-immediate-device-verify/`
  and
  `docs/evidence/gate-status/20260615T-execution-router-harness-pull-device-verify/`.
  Gate Status now writes `Documents/atria-gate-status.txt` as a durable local
  snapshot, and `--pull-sessions` pulls it as `atria-gate-status.txt`. This
  keeps device verification available even when `devicectl --console` attaches
  poorly. The physical snapshot shows Gate G remains `metric_gated` with
  `platform_ready=1` and only `healthkit_hrv_reference_pending`, while
  `execution_priority` correctly moves the next local task to Gate E targeted
  sleep/workout diagnostics instead of rerunning already-proven HealthKit
  readback plumbing. The follow-up harness run verified the automatic
  `ATRIADBG_GATE_STATUS_PULL_FILE` path and left Atria running.
- Short rest/nap review verified on adidshaft's physical iPhone, 2026-06-15:
  `docs/evidence/gate-e/20260615T-short-rest-review-device-verify/`. Atria now
  lets quiet HR-only chunks as short as two minutes surface as `Rest candidate`
  review rows when average, p95, and peak HR all stay below the workout band.
  This fixes the single-device usability gap where a small nap/checkpoint was
  saved but invisible because the old detector had a hard 10-minute minimum.
  Workout and sleep gates are unchanged: short rest rows remain
  `rest_diagnostic_only=1`, never count as sleep, never write HealthKit sleep,
  and never satisfy the sustained-HR workout detector. Physical-device evidence
  logged `activity_detect_summary ... rest_candidates=45 workouts=0
  sleep_candidates=1` and a focused daily-rollup launch logged
  `day=2026-06-15 ... rest_candidates=1 ... workout_gate_strict=1
  sleep_gate_strict=1 rest_diagnostic_only=1`.
- Today-card rest summary consistency verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-today-rest-summary-device-verify/`.
  The daily rollup already found today's short rest candidate, but the Today
  card sampled only the newest 40 recent sessions and could miss older same-day
  quiet chunks. The card now evaluates all same-day sessions plus a capped
  recent-history window, so the main UI and rollup agree without changing Gate
  E rules. Physical-device evidence logged `daily_evidence_ui ...
  rest_candidates=2 ... top_kind=Rest candidate ... top_reason=Quiet HR-only
  rest/nap review; below workout band; not counted as sleep or workout ...
  rest_diagnostic_only=1`. Sleep/workout/HRV remained gated.
- Gate E bounded status now surfaces usable user-confirmed evidence separately
  from automatic detection. On large stores, fast Gate Status may skip expensive
  sleep/workout replay; it now logs `gate=E status=user_confirmed` only when
  both a user-confirmed sleep and user-confirmed workout exist, with
  `auto_gate_e_ready=0` and `auto_detection_required=1`. This makes the app
  useful for local review/HealthKit export without pretending Gate E's automatic
  sleep/workout exit has passed. Physical-device evidence:
  `docs/evidence/gate-e/20260615T-user-confirmed-gate-e-status-device-verify/`.
- Confirmed-vs-auto Gate E training diagnostics verified on adidshaft's
  physical iPhone, 2026-06-15:
  `docs/evidence/gate-e/20260615T-confirmed-vs-auto-training-device-verify/`.
  Gate Status now persists `ATRIADBG_gate_e_training` rows for the latest
  user-confirmed workout and sleep, so the app can learn from confirmed local
  examples without promoting them into automatic detections. The confirmed
  workout overlaps real saved data but still fails the automatic workout
  contract (`auto_ready=0`, `primary_blocker=stream_gaps`,
  `coverage_percent=38`, `peak_hr=122`, `p95_hr=90`, `threshold_hr=121`,
  `elevated_s=3`, `required_elevated_s=1200`, `longest_bout_s=3`,
  `required_bout_s=480`). The confirmed sleep overlaps the best aggregate
  sleep candidate but still fails automatic sleep confidence because the
  evidence is HR-only, interrupted, below the strict 3-hour low-HR total, and
  motion is not decoded/validated. Gate E remains `user_confirmed` for local
  usefulness and `auto_detection_required=1` for the real gate exit.
- Today-card Gate E training proof verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-today-training-card-device-verify/`. Atria
  now reuses one shared `GateETrainingSummary` for Gate Status and the Today UI,
  rendering confirmed sleep/workout examples as training evidence instead of
  hiding them behind a generic learning state. The on-device log emitted
  `ATRIADBG today_gate_e_training confirmed_workout=1 workout_auto_ready=0
  workout_blocker=stream_gaps workout_stream_coverage_percent=38
  workout_elevated_s=3 workout_required_elevated_s=1200 confirmed_sleep=1
  sleep_auto_ready=0 sleep_motion_validated=0 auto_detection_required=1`. This
  is a usability/explainability checkpoint only; automatic Gate E still requires
  validated motion-backed sleep or the accepted fallback plus sustained workout
  evidence. Follow-up routing now moves the local action to
  `validate_motion_or_sustained_workout_from_training_blockers` so the execution
  loop does not keep re-running the completed training-surface work. Physical
  iPhone evidence in
  `docs/evidence/gate-e/20260615T-training-router-device-verify/` logged
  `gate=E status=user_confirmed ... action=validate_motion_or_sustained_workout_from_training_blockers`
  and `execution_priority ... next_local_action=validate_motion_or_sustained_workout_from_training_blockers`.
- Gate E training-proof routing now converts the confirmed sleep/workout
  blockers into exact proof labels instead of a broad next action. The shared
  `GateETrainingSummary` reports `sleep_proof`, `workout_proof`, and
  `next_proof`, so the Today card, Gate Status, and `ATRIADBG_gate_e_training`
  agree on the next physical evidence needed. For the current confirmed
  examples, physical iPhone evidence in
  `docs/evidence/gate-e/20260615T-training-proof-labels-device-verify/` logged
  `gate=E status=user_confirmed ... auto_gate_e_ready=0`, `sleep_proof=
  decode_wrist_motion_or_label_hr_only_sleep_fallback`, `workout_proof=
  capture_clean_sustained_hrr50_with_stream_coverage`, and
  `next_local_action=sleep:decode_wrist_motion_or_label_hr_only_sleep_fallback+workout:capture_clean_sustained_hrr50_with_stream_coverage`.
  This is still fail-closed: no sleep/workout auto-detection is promoted until
  those proof labels become `none` under real saved data.
- HR-only sleep fallback proof verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-hr-only-sleep-fallback-proof-device-verify/`.
  Atria now resolves the sleep side of the Gate E training proof only when the
  latest user-confirmed sleep substantially overlaps an HR-only overnight
  candidate that satisfies the broken-sleep duration/span fallback contract.
  Workout proof status was then tightened on the same physical iPhone in
  `docs/evidence/gate-e/20260615T-workout-proof-status-device-verify/`. Gate
  Status, the `ATRIADBG_gate_e_training` rows, and the Today card now report
  `workout_proof_status` plus the exact missing stream coverage, elevated
  seconds, bout seconds, and `workout_ready_if` contract. The verified current
  workout example still fails closed with
  `workout_proof_status=needs_stream_coverage_75p_missing_37p`,
  `workout_missing_elevated_s=1197`, `workout_missing_bout_s=477`, and
  `workout_ready_if=coverage>=75+observed>=600+elevated>=1200+bout>=480+hr>=121`.
  This does not promote workout auto-detection; it makes the remaining local
  proof actionable instead of generic.
  The fallback is explicitly labeled, not promoted to validated motion sleep:
  device logs show `sleep_blocker=hr_only_fallback_labeled`,
  `sleep_proof=none`, `sleep_fallback_accepted=1`,
  `sleep_fallback_policy=hr_only_sleep_fallback_labeled_confirmed_overlap`,
  and `auto_gate_e_ready=0`. The next local action is now narrowed to
  `workout:capture_clean_sustained_hrr50_with_stream_coverage`; Gate E still
  has not passed automatic detection.
- Gate B current-RR routing honesty verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-b/20260615T-recent-rr-routing-device-verify-2/`. Atria
  now closes one-sample stale active journals after long gaps, emits recent RR
  duration/coverage diagnostics, and requires real recent elapsed duration
  before treating current RR as locally clean. The cabled iPhone run logged a
  genuine short clean window (`active_journal_recent_rr_duration_s=12`,
  `active_journal_recent_rr_coverage_3s_percent=100`) and then correctly
  degraded after 26-27 s `2A37` delivery gaps. Gate Status stayed fail-closed:
  `active_journal_rr_coverage_3s_percent=17`,
  `active_journal_max_rr_gap_s=27.1`,
  `active_journal_recent_rr_duration_s=0`,
  `active_journal_recent_rr_clean=0`, and
  `local_blocked=B:current_rr_continuity_gap_27s_coverage_17p`. This prevents
  buffered reconnect bursts from being mistaken for continuous HRV evidence;
  Gate B remains `reference_pending`.
- Gate B staged BLE recovery verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-b/20260615T-staged-ble-recovery-device-verify/`. Long
  wear now uses a staged recovery policy instead of the previous fast reconnect
  cadence: no-data timeout `75s`, HR-continuity timeout `22.5s` with
  `read_or_reassert_notify`, accepted-HR timeout `45s`, and
  `disconnect_reconnect_policy=staged_read_reassert_then_fresh_scan`. The
  physical run verified that BLE disconnect count stayed flat while a current
  15.6s notification gap recovered without a fresh-scan reconnect; a later
  29.4-32.2s notification gap still failed the long live Gate B window, so the
  app kept HRV in `learning`. A focused Gate Status run then saw a fresh clean
  short RR segment (`active_journal_rr_coverage_3s_percent=100`,
  `active_journal_max_rr_gap_s=2.7`, `active_journal_recent_rr_clean=1`) and
  correctly routed `local_blocked=none` with
  `next_local_gate=E`. This removes an app-caused reconnect churn path; Gate B
  remains `reference_pending` until the full 5-minute/reference contract passes.
- Gate E workout proof coach verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-workout-proof-coach-device-verify/`. Atria
  now shows the remaining confirmed-workout proof as a compact checklist in the
  Today card and logs the same source-of-truth fields in `today_gate_e_training`,
  `ATRIADBG_gate_e_training`, and `gate_status gate=E`. The final device run
  logged `workout_progress=coverage_38_of_75+observed_18109_of_600+
  elevated_3_of_1200+bout_3_of_480+peak_122_of_121`,
  `workout_next_step=keep_phone_near_strap_until_coverage_75p`, and
  `workout_ready_if=coverage>=75+observed>=600+elevated>=1200+bout>=480+hr>=121`.
  Workout readiness now explicitly requires stream coverage `>=75%`, matching
  the Gate E proof contract. The checkpoint stayed honest:
  `auto_gate_e_ready=0`, `workout_blocker=stream_gaps`, and live workout status
  remained `learning`; Gate E is still not auto-detected.
- Gate B current RR gap sentinel verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-b/20260615T-current-rr-gap-sentinel-device-verify/`.
  The phone was visible to both CoreDevice and Xcode tooling despite the known
  Xcode notification-observer warning. Atria built, installed, and launched on
  the physical iPhone, logged `hr_continuity_watchdog schedule timeout_s=6.0
  interval_s=3.0`, and verified the first stale standard-HR recovery as
  `action=reassert_notify`. When no new `2A37` HR arrived, the same run
  escalated to `fresh_scan_reconnect`, preserving a bounded recovery path
  without immediate startup churn. This did not pass Gate B:
  `standard_2a37_rr_values=0`, `active_journal_rr_values=0`, and Gate Status
  remained `reference_pending`.
- Atria collection-health verifier verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-collection-health-device-verify/`.
  The cabled phone was wired, paired, booted, and Developer Mode enabled by
  `devicectl`, while Xcode's notification observer still produced the known
  `observing_system_notifications_failed` warning. The harness now treats that
  as `xcode_notification_observe_false_negative` when CoreDevice says the
  device is ready, builds with `generic/platform=iOS`, installs with
  `devicectl`, and launches anyway. Atria logged the new
  `ATRIADBG collection_health` row with `metric_promotions=0`; this run was
  correctly `status=learning blocker=active_journal_missing`, so no HRV,
  workout, or HealthKit metric was promoted from stale/missing active state.
  Atria was relaunched detached afterward and confirmed running as
  `/Atria.app/Atria`.
- Atria active-journal first-sample persistence verified on adidshaft's
  physical iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-active-journal-first-sample-device-verify/`.
  Long-wear mode now writes `atria-active-session.json` immediately after the
  first real accepted `2A37` HR sample instead of waiting for the fifth batched
  sample or a later checkpoint. The device run logged
  `active_session_journal status=saved reason=first_accepted_hr samples=1
  rr_values=0`, then the delayed verifier logged
  `collection_health phase=delayed status=ready blocker=none
  active_journal_samples=10`. The pulled journal was fresh with `14` real HR
  samples and `0` RR values, so Atria can now prove live local collection
  quickly while still keeping HRV/Gate B in learning when RR is absent.
- Atria live-settled Gate Status verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-live-settled-gate-status-device-verify/`.
  When Gate Status is launched in standard-HR/long-wear mode without an
  explicit delay, Atria now schedules an 18s settle window before logging and
  persisting status rows. The physical run logged
  `gate_status schedule delay_s=18.0 reason=live_collection_settle`, then
  completed Gate Status with `active_journal_present=1`,
  `active_journal_fresh=1`, `active_journal_samples=1`, and
  `active_journal_rr_values=0` in Gate B. The post-run pull showed a fresh
  active journal with `6` real HR samples and `0` RR values. This prevents
  stale launch snapshots from reporting `active_journal_missing` while
  preserving the correct HRV learning/reference-pending state.
- Atria current-collection saved-tail status verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/app-usability/20260615T-current-collection-saved-tail-device-verify-2/`.
  The cabled iPhone was wired, paired, booted, and Developer Mode enabled;
  the known Xcode notification observer warning was again suppressed as
  `xcode_notification_observe_false_negative` because `devicectl` reported the
  phone ready. Atria now treats a recent saved session tail as current
  collection evidence for the long-wear checkpoint window, without promoting
  any health metric. The proof run first logged
  `collection_ready=1 collection_source=saved_session_tail
  collection_age_s=275 collection_metric_promotions=0`, then after reconnect
  and first real `2A37` HR sample switched to
  `collection_ready=1 collection_source=active_journal collection_samples=1
  collection_rr_values=0`. Gate Status persisted
  `current_collection_ready=1`, `current_collection_source=active_journal`,
  and `current_collection_metric_promotions=0`. Gate B stayed
  `reference_pending` (`standard_2a37_rr_values=0`,
  `active_journal_rr_values=0`), Gate E stayed user-confirmed but
  auto-detection-pending, and Gate G stayed metric-gated only by HRV reference.
- Gate B non-disruptive RR segment auditor verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-nondisruptive-rr-segment-auditor-device-verify/`.
  `pull_atria_state.sh` now audits RR quality from the currently pulled
  active journal, the latest saved session tail, the best whole saved RR
  session, and the best contiguous saved RR segment without reinstalling,
  launching, or terminating Atria. The final physical pull left Atria running
  and found a clean saved RR segment from `gate-b-2a37-reset-keep-recording`:
  `raw_beats=372`, `duration_s=309.0`, `corrected_beats=337`,
  `kept_percent=91`, `max_gap_s=2.8`, and
  `best_saved_rr_segment_gate_b_local_ready=1`. The best whole saved session
  still failed because it had a `3028.5s` gap, and the latest live tail was
  HR-only, so the auditor reports the exact blocker instead of promoting a
  metric. Gate B remains `reference_pending` until an independent RR/IBI CSV
  validates RMSSD within the ±5 ms contract.
- Gate B bounded Gate Status RR replay verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-bounded-rr-replay-gate-status-device-verify/`.
  The fast bounded large-store Gate Status path now runs the exhaustive
  RR-only 300s window replay while still skipping expensive workout/deep
  replays. The device run logged `bounded_rr_replay_done mode=fast ready=1
  label=gate-b-300s-live-rr raw=368 kept=361 conf=98 max_gap_s=1.8
  reason=ready`, then Gate B persisted `saved_rr_ready=1`,
  `saved_rr_best_rmssd=32.7`, and `rr_replay=computed_exhaustive_rr_only`.
  Gate B still stayed `reference_pending` with
  `external_rr_reference_required=1` and `reference_validated=0`; this is a
  status accuracy fix, not a clinical HRV pass. Atria was relaunched detached
  in standard-HR long-wear mode after verification.
- Gate B Today/HRV reference-pending display verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-b/20260615T-today-hrv-display-reference-pending-device-verify/`.
  The Today HRV tile and HRV card now treat a clean saved RR package as
  `reference_pending` instead of generic `learning`, while still withholding
  HRV/Recovery promotion until an independent RR reference validates RMSSD.
  The real-device log includes
  `ATRIADBG hrv_display state=reference_pending ... rr_package_ready=1
  rr_package_raw=368 rr_package_kept=361 rr_package_conf=98
  rr_package_gap_s=1.8 rr_package_rmssd=32.7
  reason=external_rr_reference_required surface=today`. Gate B stayed
  `reference_pending` with `external_rr_reference_required=1` and
  `reference_validated=0`, so this is an honesty/usability checkpoint rather
  than a clinical Gate B pass.
- Gate F bounded local trend status verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-f/20260615T-bounded-local-trends-device-verify/`.
  The fast large-store Gate Status path now computes a bounded local trend
  summary instead of hiding trends behind `trend_replay=skipped_bounded_audit`.
  The physical run logged `ATRIADBG trend_fast_local windows=3
  local_windows=3 rhr_points=3 strain_points=3 recovery_points=0
  hrv_points=0 trend90_confidence=learning trend90_coverage_days=3
  trend90_required_coverage_days=63 trend90_coverage_percent=3
  hrv_reference_gated=1 status=partial`, then persisted Gate F as `partial`
  with `trend_replay=fast_local_summary`, `local_non_hrv_trends_ready=1`,
  `trend90_rhr_points=1`, and `trend90_strain_points=1`. Gate F is still not
  ready: blockers remain
  `coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
- Gate E workout proof intensity routing verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-e/20260615T-workout-proof-intensity-routing-final-device-verify/`.
  The confirmed-workout proof coach now distinguishes "coverage only" from
  "coverage plus received-HR intensity missing" when the captured workout has
  enough observed time but almost no sustained HRR50. The final device run
  logged `workout_blocker=stream_gaps+intensity_unvalidated`,
  `workout_proof=capture_clean_hrr50_or_validate_received_hr`,
  `workout_proof_status=needs_stream_coverage_75p_missing_37p+needs_sustained_hrr50_1197s`,
  and `workout_next_step=keep_phone_near_strap_and_validate_received_hr_intensity`
  in both `today_gate_e_training` and `gate_status gate=E`. Gate E stayed
  `user_confirmed` with `auto_gate_e_ready=0` and `auto_detection_required=1`;
  the workout detector thresholds were not loosened.
- Atria Today next-action alignment verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/app-usability/20260615T-today-next-action-gate-e-alignment-device-verify/`.
  The Today card now uses the same Gate E training-proof source of truth for
  its action row, so the first screen no longer says only to reconnect/keep
  phone nearby when the confirmed workout also needs received-HR intensity
  validation. The device run logged `today_usability ... next_action=Keep
  phone near strap and validate received HR intensity before counting workouts.`
  on first render, plus the same text in the connected and live-HR update rows.
  Gate Status still stayed honest with `auto_gate_e_ready=0`,
  `auto_detection_required=1`, and
  `workout_proof=capture_clean_hrr50_or_validate_received_hr`.
- Harness nonzero Xcode observer fallback verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-status/20260615T-harness-nonzero-xcode-observer-fallback-device-verify/`.
  `live_device_debug.sh` now suppresses the
  `observing system notifications failed` / "Development services" false
  negative even when `xcodebuild -showdestinations` exits nonzero, but only
  after `devicectl device info details` proves the phone is paired, wired,
  booted, and Developer Mode enabled. A shimmed preflight reproduced the
  nonzero observer failure (`showdestinations_status=70`), the harness fell
  back to `generic/platform=iOS`, then built, installed, launched, logged Gate
  Status, pulled sessions, and relaunched Atria detached in long-wear mode on
  the physical iPhone. This is an execution reliability fix; no metric gate was
  promoted.
- Execution priority saved-RR routing verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-status/20260615T-execution-priority-saved-rr-ready-routing-device-verify/`.
  When Gate B has a clean saved RR package, transient active-journal RR gaps no
  longer become the top local blocker. The physical run intentionally showed
  both truths: Gate B logged `saved_rr_ready=1`,
  `saved_rr_best_raw=368`, `saved_rr_best_kept=361`,
  `saved_rr_best_conf=98`, `saved_rr_best_gap_s=1.8`, and
  `saved_rr_best_rmssd=32.7`, while the active journal still exposed
  `active_journal_max_rr_gap_s=55.5` and
  `active_journal_rr_coverage_3s_percent=15`. The router now logs
  `next_action=provide_external_rr_reference_for_ready_rr_window`,
  `next_local_gate=E`, `next_local_action=workout:capture_clean_hrr50_or_validate_received_hr`,
  and `local_blocked=none`. Gate B remains `reference_pending`; this only
  prevents local execution from looping on live RR continuity after saved RR is
  already ready.
- Gate E workout intensity proof detail verified on adidshaft's physical
  iPhone, 2026-06-15:
  `docs/evidence/gate-e/20260615T-workout-intensity-proof-detail-device-verify/`.
  Atria now logs and displays the specific intensity proof behind a confirmed
  workout miss instead of collapsing it into a generic stream issue. The device
  run logged
  `workout_intensity_proof=received_hr_p95_90_below_threshold_121_by_31bpm`,
  `workout_p95_hr=90`, `workout_p95_gap_bpm=31`, and
  `workout_peak_gap_bpm=0` in `today_gate_e_training`, Gate Status, and
  `gate_e_training`. Gate E stayed honest with `auto_gate_e_ready=0` and
  `auto_detection_required=1`; this explains the blocker but does not loosen
  workout thresholds or promote the gate.
- Gate E workout profile proof verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-workout-profile-proof-device-verify/`.
  Atria now logs and displays why lowering the HRmax/profile cannot honestly
  solve the confirmed gym miss. The device run logged
  `workout_profile_proof=profile_fix_would_require_maxhr_128_current_189_lower_by_61bpm`,
  with `workout_p95_hr=90`, `workout_p99_hr=105`,
  `workout_profile_max_hr=189`, and
  `workout_required_profile_max_hr_for_p95_hrr50=128`. Gate E remained
  `user_confirmed` with `auto_gate_e_ready=0` and
  `auto_detection_required=1`; the app now rules out dishonest profile
  manipulation and keeps the next action on real sustained HR, HR reference, or
  validated motion/protocol evidence.
- Gate E readiness UI state verified on adidshaft's physical iPhone,
  2026-06-15:
  `docs/evidence/gate-e/20260615T-gate-e-user-confirmed-readiness-ui-device-verify-3/`.
  The in-app Gate readiness rows now use the same `GateETrainingSummary` as
  Gate Status and the Today training proof, so confirmed sleep+workout evidence
  appears as `user_confirmed` rather than generic `partial`. The device run
  built green, installed, launched, logged real `2A37` RR, pulled sessions, and
  left Atria running in standard-HR-only long-wear mode. Gate Status confirmed
  `gate=E status=user_confirmed`, `confirmed_workouts=1`,
  `confirmed_sleeps=1`, `auto_gate_e_ready=0`,
  `auto_detection_required=1`, and
  `workout_intensity_proof=received_hr_p95_90_below_threshold_121_by_31bpm`.
  This is a usability/readiness-label fix only; Gate E is still not passed
  until automatic sleep/workout evidence satisfies the strict contract.
