#!/usr/bin/env bash
set -euo pipefail

device_id=${ATRIA_DEVICE_ID:-${WHOOP_DEVICE_ID:-}}
xcode_device_id=${ATRIA_XCODE_DEVICE_ID:-${WHOOP_XCODE_DEVICE_ID:-$device_id}}
bundle_id=${ATRIA_BUNDLE_ID:-${WHOOP_BUNDLE_ID:-com.adidshaft.atria}}
seconds=${ATRIA_LIVE_DEBUG_SECONDS:-${WHOOP_LIVE_DEBUG_SECONDS:-120}}
log_path=${ATRIA_LIVE_DEBUG_LOG:-${WHOOP_LIVE_DEBUG_LOG:-}}
build_configuration=${ATRIA_BUILD_CONFIGURATION:-Debug}
build=1
pull_only=0
seconds_explicit=0
until_realtime=0
until_ready=0
complete_onboarding=0
log_baseline=0
log_gate_status=0
log_gate_readiness=0
log_gate_status_deep=0
log_gate_status_after=""
log_collection_health=0
log_collection_health_after=""
log_activity_detections=0
log_daily_rollups=0
log_trends=0
log_widget_snapshot=0
log_workout_preflight=0
log_strain_validation=0
log_hr_consistency=0
log_hr_artifact_policy=0

if [[ -z "$device_id" ]]; then
  printf 'Set ATRIA_DEVICE_ID to your physical iPhone CoreDevice identifier.\n' >&2
  exit 64
fi
log_hr_continuity_watchdog_state=0
quiet_ble_logs=0
full_protocol_mode=0
standard_hr_only=0
long_wear_mode=0
reset_capture_defaults=0
reset_link_diagnostics=0
reset_sample_diagnostics=0
reset_protocol_diagnostics=0
active_motion_imu_check=0
flush_active_journal_after=""
manual_checkpoint_after=""
force_no_data_watchdog_after=""
force_hr_continuity_watchdog_after=""
force_rr_presence_watchdog_after=""
force_missing_2a37_after=""
force_accepted_hr_watchdog_after=""
backup_sessions=0
verify_backup=0
restore_backup=0
healthkit_export=0
healthkit_reference_audit=0
healthkit_reset_rebuild=0
confirm_best_workout_candidate=0
confirm_best_sleep_candidate=0
export_rr_reference_package=0
export_hr_reference_package=0
validate_rr_reference=0
validate_hr_reference=0
morning_hrv_check=0
morning_hrv_force=0
auto_save_session_after=""
auto_save_session_every=""
checkpoint_session_every=""
log_live_workout_every=""
auto_save_workout_when_ready=""
verify_workout_label=""
verify_workout_after=""
gate_e_workout_capture=0
gate_e_hr_only_workout_capture=0
gate_d_hr_comparison_capture=0
verify_sleep=0
verify_sleep_label=""
verify_sleep_after=""
schedule_notifications=0
test_notification=0
notification_delay=""
auto_capture=0
stop_when_ready=0
capture_label="gate-b-auto"
capture_label_explicit=0
auto_capture_delay=""
auto_capture_when_rr=""
auto_capture_rr_window=""
auto_capture_rr_timeout=""
auto_capture_rr_min_frames=""
auto_capture_max_rr_gap=""
auto_capture_max_attempts=""
realtime_start_retries=""
realtime_restart_zero_rr_seconds=""
realtime_reassert_zero_rr_seconds=""
disable_history_ack=0
history_ack_mode=""
history_recent_sweep=0
history_recent_offsets=""
history_selector_sweep=0
history_selector_mode=""
history_selector_range_index=""
history_range_sweep=0
history_range_payloads=""
history_init_sweep=""
history_skip_range=0
history_only_probe=0
history_noop_backfill=0
history_clock_handshake=0
probe_command=""
probe_command_delay=""
probe_command_mode=""
probe_sweep=""
probe_sweep_interval=""
pull_capture_dir=""
pull_backups_dir=""
pull_sessions_dir=""
pull_historical_dir=""
pull_reference_package_dir=""
push_backup_path=""
push_rr_reference_path=""
push_hr_reference_path=""
push_rr_reference_name="rr-reference.csv"
push_hr_reference_name="hr-reference.csv"
clear_reference_inputs=0
auto_stop_after=""
strict_live_rr_capture=0
replay_log=""
leave_running=0
gate_e_contract=0

usage() {
  cat <<'EOF'
Usage:
  ./live_device_debug.sh [--device DEVICE_ID] [--xcode-device XCODE_DEVICE_ID] [--configuration Debug|Release] [--release] [--seconds N] [--log PATH] [--no-build] [--pull-only] [--until-realtime] [--until-ready] [--complete-onboarding] [--log-baseline] [--log-collection-health] [--log-collection-health-after N] [--log-gate-status] [--log-gate-readiness] [--log-gate-status-after N] [--log-gate-status-deep] [--log-activity-detections] [--log-daily-rollups] [--log-trends] [--log-widget-snapshot] [--log-workout-preflight] [--log-strain-validation] [--log-hr-consistency] [--log-hr-artifact-policy] [--log-hr-continuity-watchdog-state] [--quiet-ble-logs] [--full-protocol-mode] [--standard-hr-only] [--long-wear-mode] [--leave-running] [--reset-link-diagnostics] [--reset-sample-diagnostics] [--reset-protocol-diagnostics] [--active-motion-imu-check] [--flush-active-journal-after N] [--manual-checkpoint-after N] [--force-no-data-watchdog-after N] [--force-hr-continuity-watchdog-after N] [--force-rr-presence-watchdog-after N] [--force-missing-2a37-after N] [--force-accepted-hr-watchdog-after N] [--backup-sessions] [--verify-backup] [--restore-backup] [--push-backup PATH] [--push-rr-reference PATH] [--push-rr-reference-as NAME.csv] [--push-hr-reference PATH] [--push-hr-reference-as NAME.csv] [--clear-reference-inputs] [--healthkit-export] [--confirm-best-workout-candidate] [--confirm-best-sleep-candidate] [--export-rr-reference-package] [--validate-rr-reference] [--pull-reference-package DIR] [--morning-hrv-check] [--morning-hrv-force] [--gate-d-hr-comparison-capture] [--gate-e-workout-capture] [--gate-e-hr-only-workout-capture] [--auto-save-session-after N] [--auto-save-session-every N] [--checkpoint-session-every N] [--log-live-workout-every N] [--auto-save-workout-when-ready N] [--verify-workout-label LABEL] [--verify-workout-after N] [--verify-sleep] [--verify-sleep-label LABEL] [--verify-sleep-after N] [--schedule-notifications] [--test-notification] [--notification-delay N] [--auto-capture] [--strict-live-rr-capture] [--auto-capture-delay N] [--auto-capture-when-rr FRACTION] [--auto-capture-rr-window N] [--auto-capture-rr-min-frames N] [--auto-capture-max-rr-gap N] [--auto-capture-rr-timeout N] [--stop-when-ready] [--auto-stop-after N] [--label LABEL] [--realtime-start-retries N] [--realtime-restart-zero-rr-seconds N] [--realtime-reassert-zero-rr-seconds N] [--disable-history-ack] [--history-ack-mode trim|enddata|index|unix|zero|none] [--history-recent-sweep] [--history-recent-offsets N[,N...]] [--history-clock-handshake] [--history-noop-backfill] [--probe-command HEX] [--probe-command-delay N] [--probe-sweep HEX[,HEX...]] [--probe-sweep-interval N] [--probe-command-mode wwr|wr] [--pull-capture DIR] [--pull-backups DIR] [--pull-sessions DIR] [--pull-historical DIR] [--replay-log PATH]

Builds, installs, and launches the Atria app on a physical iPhone with
devicectl --console so ATRIADBG lines stream in real time. Defaults to adidshaft's
paired iPhone. Set ATRIA_DEVICE_ID, legacy WHOOP_DEVICE_ID, or pass --device to override.

Options:
  --device DEVICE_ID   CoreDevice/devicectl physical iPhone identifier.
  --xcode-device ID    Xcode destination id for the same physical iPhone.
  --configuration NAME Xcode build configuration. Allowed: Debug or Release.
                       Default: ATRIA_BUILD_CONFIGURATION or Debug.
  --release            Shorthand for --configuration Release. Use this for
                       UX/performance evidence; Debug is diagnostic only.
  --seconds N          Console capture duration before stopping. Default: 120.
  --log PATH           Also write the console transcript to PATH.
                       Use --log auto for logs/live-device/<timestamp>.log.
  --no-build           Reuse the existing <configuration>-iphoneos app bundle.
  --pull-only          Do not build, install, launch, terminate, or relaunch.
                       Only copy requested app-container artifacts. Use with
                       --pull-sessions, --pull-backups, or other pull flags
                       during unattended long-wear runs.
  --until-realtime     Stop once a 61080005 realtime frame is observed.
  --until-ready        Stop once ATRIADBG reports a validation-ready HRV window
                       or a ready capture_summary.
  --complete-onboarding
                       Debug launch arg: complete local profile onboarding.
  --log-baseline      Debug launch arg: log baseline maturity and validated-HRV
                       readiness for Recovery v2.
  --log-collection-health
                       Debug launch arg: log one compact current-collection
                       health row from the active journal, BLE link, sample-gap,
                       and watchdog diagnostics. This is fail-closed and never
                       promotes HRV or workout metrics.
  --log-collection-health-after N
                       Delay the collection-health row by N seconds after launch
                       so BLE has time to create a real active journal.
  --log-gate-status   Debug launch arg: log one cross-gate honesty summary
                       from current local evidence.
  --log-gate-readiness
                       Debug launch arg: log the in-app Gate readiness rows
                       once on launch, without waiting for the diagnostics UI.
  --log-gate-status-after N
                       Delay the Gate Status row by N seconds after launch.
                       Useful when protocol counters must accumulate before
                       the on-device honesty summary is emitted.
  --log-gate-status-deep
                       Debug launch arg: run replay-heavy RR/workout forensics
                       after the fast gate-status rows.
  --log-activity-detections
                       Debug launch arg: log local activity detection summary.
  --log-daily-rollups
                       Debug launch arg: log daily rollups and workout
                       readiness diagnostics from saved sessions.
  --log-trends         Debug launch arg: log local trend windows.
  --log-widget-snapshot
                       Debug launch arg: publish and log app-local widget
                       snapshot payload.
  --log-workout-preflight
                       Debug launch arg: log the personalized Gate E workout
                       threshold and minimum duration/elevated-bout criteria.
  --log-strain-validation
                       Debug launch arg: log Gate D rest-to-max strain-zone
                       readiness and exact blockers from saved local sessions.
  --log-hr-consistency
                       Debug launch arg: compare standard BLE 2A37 HR against
                       proprietary 0x28 realtime HR when samples are close.
  --log-hr-artifact-policy
                       Debug launch arg: log the HR artifact jump policy
                       self-test without saving a session.
  --quiet-ble-logs     Do not request verbose per-packet ATRIADBG logs. Default
                       debug captures keep packet logs enabled for evidence.
  --full-protocol-mode Disable persisted Long wear / Low radio HR and reconnect
                       through the full WHOOP custom protocol for Gate B/H.
  --standard-hr-only   Subscribe only to standard BLE HR (2A37) and battery for
                       workout capture. Skips WHOOP custom notify streams,
                       realtime START, and history ACKs; HRV remains learning.
  --long-wear-mode     Persist and arm the in-app long-wear profile: low-radio
                       HR, 60s checkpoints, 15s live workout diagnostics, and
                       strict workout auto-save only after the detector is ready.
  --leave-running      After the console evidence window and pulls finish,
                       relaunch Atria without --console in safe low-radio
                       long-wear mode so unattended local capture continues.
                       One-shot debug operations are not repeated.
  --reset-capture-defaults
                       Debug launch arg: clear only persisted radio/Long Wear
                       defaults before launch so first-normal-launch bootstrap
                       can be verified without deleting sessions.
  --reset-link-diagnostics
                       Debug launch arg: clear persisted BLE link counters
                       before this run.
  --reset-sample-diagnostics
                       Debug launch arg: clear persisted HR sample-gap counters
                       before this run.
  --reset-protocol-diagnostics
                       Debug launch arg: clear persisted protocol packet
                       counters, including diagnostic and IMU candidate frames.
  --active-motion-imu-check
                       Preset for the active Gate E/H live-motion proof:
                       full protocol, reset protocol counters, log Gate Status,
                       and emit an on-device motion-script row. During the
                       window, alternate 30s still, 30s wrist rotations/taps,
                       30s still, 30s walking arm swing, then check for
                       protocol_imu_frames, sleep_motion_hint_count, or
                       imu_candidate. No metric is promoted from this test.
  --flush-active-journal-after N
                       Debug launch arg: force-save the active session journal
                       after N seconds.
  --manual-checkpoint-after N
                       Debug launch arg: save a non-destructive manual session
                       checkpoint after N seconds.
  --force-no-data-watchdog-after N
                       Debug launch arg: force the no-data watchdog recovery
                       path after N seconds, proving checkpoint + fresh-scan
                       reconnect without waiting for a natural BLE stall.
  --force-accepted-hr-watchdog-after N
                       Debug launch arg: force the accepted-HR watchdog recovery
                       path after N seconds, proving checkpoint + fresh-scan
                       reconnect without waiting for a natural BLE stall.
  --force-rr-presence-watchdog-after N
                       Debug launch arg: force the RR-presence watchdog recovery
                       path after N seconds, proving checkpoint plus 2A37
                       read/re-notify without interrupting a healthy HR stream.
  --force-missing-2a37-after N
                       Debug launch arg: clear the cached standard HR
                       characteristic after N seconds, proving rediscovery on
                       the physical iPhone without waiting for a discovery stall.
  --backup-sessions    Debug launch arg: write local sessions backup.
  --verify-backup      Debug launch arg: decode and validate latest local
                       sessions backup.
  --restore-backup     Debug launch arg: restore latest local sessions backup
                       after writing a pre-restore safety backup.
  --push-backup PATH    Copy a Mac-side backup JSON into the app container's
                       Documents/atria-backups directory before launch. Use with
                       --restore-backup and --verify-backup for recovery smoke.
  --push-rr-reference PATH
                       Copy a Mac-side independent RR/IBI CSV into
                       Documents/atria-reference/rr-reference.csv before launch.
                       Pair with --validate-rr-reference; copied Atria exports
                       are still rejected by the app.
  --push-rr-reference-as NAME.csv
                       Use NAME.csv under Documents/atria-reference instead of
                       rr-reference.csv. This is for verifying the app's
                       single-candidate auto-selection; pass a basename only.
  --push-hr-reference PATH
                       Copy a Mac-side independent HR CSV into
                       Documents/atria-reference/hr-reference.csv before launch.
                       Pair with --validate-hr-reference; copied Atria exports
                       are still rejected by the app.
  --push-hr-reference-as NAME.csv
                       Use NAME.csv under Documents/atria-reference instead of
                       hr-reference.csv. This is for verifying the app's
                       single-candidate auto-selection; pass a basename only.
  --clear-reference-inputs
                       Ask the app to delete Documents/atria-reference
                       rr-reference.csv and hr-reference.csv on launch before
                       any reference export or validation runs.
  --pull-backups DIR    Copy the backup JSON logged by --backup-sessions from
                       the app container to DIR on this Mac.
  --pull-sessions DIR   Copy the app's current Documents/sessions.json from
                       the app container to DIR on this Mac. Also pulls the
                       active-session journal and segmented active journal when present.
  --pull-historical DIR
                       Copy the app's historical JSONL archive from
                       Documents/atria-historical into DIR on this Mac.
  --healthkit-export   Debug launch arg: request HealthKit authorization and
                       write real saved HR/workout samples.
  --confirm-best-sleep-candidate
                       Debug launch arg: store the best saved local sleep
                       candidate as user-confirmed sleep evidence without
                       promoting automatic Gate E sleep.
  --healthkit-reference-audit
                       Debug launch arg: read Apple Health HR samples over the
                       saved-session window and compare non-Atria sources to
                       Atria HR. Atria's own HealthKit exports are rejected as
                       self-reference and never unlock Gate D.
  --healthkit-reset-rebuild-atria-hr
                       Debug launch arg: delete Atria-authored Apple Health HR
                       samples in the saved-session window, then rebuild only
                       Atria HR rows from local sessions. Independent Health
                       samples are excluded from deletion.
  --export-rr-reference-package
                       Debug launch arg: export the best saved strict 5-min
                       RR window as a validator-ready CSV and JSON manifest.
  --export-hr-reference-package
                       Debug launch arg: export the best saved HR segment as a
                       Gate D validator-ready CSV and JSON manifest. This never
                       marks Gate D passed without an external HR reference.
  --validate-rr-reference
                       Debug launch arg: compare the best saved WHOOP RR window
                       against Documents/atria-reference/rr-reference.csv on
                       device. Missing/invalid reference keeps Gate B closed.
  --validate-hr-reference
                       Debug launch arg: compare the best saved WHOOP HR window
                       against Documents/atria-reference/hr-reference.csv on
                       device. Missing/invalid reference keeps Gate D closed.
  --pull-reference-package DIR
                       Copy RR/HR reference CSV/manifest files logged by
                       --export-*-reference-package into DIR on this Mac.
  --morning-hrv-check  Debug launch arg: evaluate the morning-HRV auto-capture
                       gate and schedule a strict RR capture when eligible.
  --morning-hrv-force  With --morning-hrv-check, bypass the local 04:00-11:59
                       window for device smoke testing. HRV still stays
                       learning unless the real RR window passes.
  --gate-e-workout-capture
                       Preset for one designed Gate E workout attempt. Sets
                       label=gate-e-hrr50-workout, seconds=1200 unless
                       overridden, quiet BLE logs, reset link/sample diagnostics,
                       checkpoint every 60s, live workout logs every 15s,
                       auto-save when strict workout readiness passes every 15s,
                       delayed workout verification at 900s, daily rollups,
                       Gate status, backup write, and backup verify.
  --gate-e-hr-only-workout-capture
                       Same Gate E preset, plus --standard-hr-only. Use this
                       to isolate workout HR coverage from custom WHOOP traffic.
  --gate-d-hr-comparison-capture
                       Preset for the next HR reference comparison attempt.
                       Uses standard HR only, label=gate-d-hr-comparison,
                       seconds=1200 unless overridden, quiet BLE logs, reset
                       link/sample diagnostics, checkpoints, live workout
                       diagnostics, strict workout auto-save, delayed workout
                       verification, HR reference package export, backup write,
                       and backup verify. Run --log-gate-status afterward for
                       cross-gate truth. Pair with
                       --pull-reference-package DIR to copy the Atria HR CSV.
  --auto-save-session-after N
                       Debug launch arg: finish and save the live HR session
                       after N seconds without waiting for disconnect.
  --auto-save-session-every N
                       Debug launch arg: periodically finish and save live HR
                       chunks every N seconds for unattended durability.
  --checkpoint-session-every N
                       Debug launch arg: periodically upsert the current live
                       HR session without resetting it.
  --log-live-workout-every N
                       Debug launch arg: log live workout-readiness evidence
                       every N seconds without changing detector thresholds.
  --auto-save-workout-when-ready N
                       Debug launch arg: check the live session every N seconds
                       and save it only after strict workout readiness passes.
  --verify-workout-label LABEL
                       Debug launch arg: after launch, verify whether a saved
                       session matching LABEL passes workout detection.
  --verify-workout-after N
                       Seconds after launch before --verify-workout-label runs.
                       Use with checkpoints to validate the current live run.
  --verify-sleep      Debug launch arg: verify the longest/latest saved session
                       against the local sleep-candidate detector.
  --verify-sleep-label LABEL
                       Restrict --verify-sleep to saved sessions whose label
                       matches or starts with LABEL.
  --verify-sleep-after N
                       Seconds after launch before --verify-sleep runs.
  --schedule-notifications
                       Debug launch arg: provisionally authorize and schedule
                       eligible local recovery/strain/battery notifications.
  --test-notification  Debug launch arg: schedule a diagnostic local
                       notification and log foreground delivery.
  --notification-delay N
                       Seconds after launch before notification decisions.
                       Default: 8.
  --auto-capture       Pass launch args that start Capture automatically.
  --strict-live-rr-capture
                       Disable pre-capture RR archive seeding and judge timeout
                       from the latest clean RR window after any quality reset.
  --auto-capture-delay N
                       Delay auto-capture start by N seconds after app launch.
                       Useful for excluding protocol warm-up from HRV windows.
  --auto-capture-when-rr FRACTION
                       Start Capture only after recent realtime frames have at
                       least this RR-bearing fraction, e.g. 0.90.
  --auto-capture-rr-window N
                       Seconds of recent realtime frames used by
                       --auto-capture-when-rr. Default: 30.
  --auto-capture-rr-min-frames N
                       Minimum recent realtime frames before adaptive capture
                       can start. Default: 10.
  --auto-capture-max-rr-gap N
                       Require the recent RR-bearing frame gap to be no more
                       than N seconds before adaptive capture can start.
                       Default: off.
  --auto-capture-rr-timeout N
                       Start Capture after N seconds even if RR fraction never
                       reaches threshold, preserving learning evidence.
  --stop-when-ready    With --auto-capture, stop Capture at the first ready HRV
                       window so ATRIADBG emits a capture_summary.
  --auto-stop-after N  With --auto-capture, stop Capture after N seconds even if
                       HRV is still learning. Useful for preserving timeout CSVs.
  --label LABEL        Capture label used by --auto-capture. Default: gate-b-auto.
  --realtime-start-retries N
                       Protocol experiment: retry START this many times after
                       the initial START, stopping once standard HR, standard
                       RR, realtime frames, or realtime RR appear. App default: 0.
  --realtime-restart-zero-rr-seconds N
                       Debug launch arg: after RR has appeared, send STOP then
                       START when realtime frames carry rrnum=0 for N seconds.
                       Default: off.
  --realtime-reassert-zero-rr-seconds N
                       Debug launch arg: after RR has appeared, send START only
                       when realtime frames carry rrnum=0 for N seconds.
                       Default: off.
  --disable-history-ack
                       Debug launch arg: log historical metadata but do not send
                       0x17 continuation ACKs. Use to isolate live RR continuity
                       from stored-session transfer traffic.
  --history-ack-mode trim|enddata|index|unix|zero|none
                       Debug launch arg: choose the u32 cursor sent in 0x17
                       continuation ACK payloads, or enddata to echo the 8
                       HISTORY_END bytes with a confirmed write. Default: trim.
  --history-recent-sweep
                       Debug launch arg: after the first live realtime timestamp,
                       send recent-time 0x16 historical-start variants.
  --history-recent-offsets N[,N...]
                       Seconds before the first live realtime timestamp to use
                       in --history-recent-sweep. Default app offsets: 0,300,3600.
  --history-selector-sweep
                       Debug launch arg: after a 0x22 data-range response,
                       derive a constrained 0x21 read-pointer selector from
                       the live-ish Unix field, then request 0x16 history.
  --history-selector-mode MODE
                       Selector shape: current-unix-bare, current-unix-prefix0,
                       current-unix-prefix1, current-unix-all,
                       current-record8, known-block-record8, range-window24,
                       or record-shape-all.
  --history-selector-range-index N
                       With --history-selector-sweep, only allow the Nth
                       0x22 data-range response to trigger 0x21 + 0x16.
  --history-range-sweep
                       Debug launch arg: in history-only mode, send multiple
                       0x22 data-range payloads without realtime START.
  --history-range-payloads HEX[,HEX...]
                       Payloads for --history-range-sweep. Default app payload
                       is 00. Example: 00,01,02,03.
  --history-init-sweep HEX[,HEX...]
                       In history-only mode, send command+payload hex commands
                       before any 0x22 range request. Example: 1400,6000,1600.
  --history-skip-range
                       In history-only mode, do not send the default 0x22 range
                       request after --history-init-sweep.
  --history-noop-backfill
                       Preset for NOOP-style stored-session probing:
                       history-only, confirmed writes, init sweep 1400,6000,
                       start historical 1600, skip 0x22 range, ACK enddata.
  --history-only-probe
                       Debug launch arg: skip realtime START and send a
                       read-only 0x22 [00] data-range request after 61080005
                       notify is active. Use with --history-selector-sweep to
                       test stored-session fallback without live-HRV contention.
  --probe-command HEX  Debug launch arg: send one extra command after the
                       validated START. HEX is unframed command+data, e.g. 0301.
  --probe-command-delay N
                       Seconds after validated START before --probe-command.
                       Default: 0.
  --probe-sweep HEX[,HEX...]
                       Debug launch arg: send each unframed command+data after
                       the validated START, separated by --probe-sweep-interval.
  --probe-sweep-interval N
                       Seconds between --probe-sweep commands. Default: 30.
  --probe-command-mode wwr|wr
                       Write mode for --probe-command. Default: wwr.
  --pull-capture DIR   After the app logs ATRIADBG capture_file, copy that CSV
                       from the app data container into DIR.
  --replay-log PATH    Parse an existing ATRIADBG console log and print the same
                       summary without building, installing, or launching.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      device_id=${2:?--device requires a value}
      shift 2
      ;;
    --xcode-device)
      xcode_device_id=${2:?--xcode-device requires a value}
      shift 2
      ;;
    --configuration)
      build_configuration=${2:?--configuration requires a value}
      shift 2
      ;;
    --release)
      build_configuration=Release
      shift
      ;;
    --seconds)
      seconds=${2:?--seconds requires a value}
      seconds_explicit=1
      shift 2
      ;;
    --log)
      log_path=${2:?--log requires a value}
      shift 2
      ;;
    --no-build)
      build=0
      shift
      ;;
    --pull-only)
      pull_only=1
      build=0
      shift
      ;;
    --until-realtime)
      until_realtime=1
      shift
      ;;
    --until-ready)
      until_ready=1
      shift
      ;;
    --complete-onboarding)
      complete_onboarding=1
      shift
      ;;
    --log-baseline)
      log_baseline=1
      shift
      ;;
    --log-collection-health)
      log_collection_health=1
      shift
      ;;
    --log-collection-health-after)
      log_collection_health=1
      log_collection_health_after=${2:?--log-collection-health-after requires a value}
      shift 2
      ;;
    --log-gate-status)
      log_gate_status=1
      shift
      ;;
    --log-gate-readiness)
      log_gate_readiness=1
      shift
      ;;
    --log-gate-status-after)
      log_gate_status=1
      log_gate_status_after=${2:?--log-gate-status-after requires a value}
      shift 2
      ;;
    --log-gate-status-deep)
      log_gate_status=1
      log_gate_status_deep=1
      shift
      ;;
    --log-activity-detections)
      log_activity_detections=1
      shift
      ;;
    --log-daily-rollups)
      log_daily_rollups=1
      shift
      ;;
    --log-trends)
      log_trends=1
      shift
      ;;
    --log-widget-snapshot)
      log_widget_snapshot=1
      shift
      ;;
    --log-workout-preflight)
      log_workout_preflight=1
      shift
      ;;
    --log-strain-validation)
      log_strain_validation=1
      shift
      ;;
    --log-hr-consistency)
      log_hr_consistency=1
      shift
      ;;
    --log-hr-artifact-policy)
      log_hr_artifact_policy=1
      shift
      ;;
    --log-hr-continuity-watchdog-state)
      log_hr_continuity_watchdog_state=1
      shift
      ;;
    --quiet-ble-logs)
      quiet_ble_logs=1
      shift
      ;;
    --full-protocol-mode)
      full_protocol_mode=1
      standard_hr_only=0
      long_wear_mode=0
      shift
      ;;
    --standard-hr-only)
      standard_hr_only=1
      shift
      ;;
    --long-wear-mode)
      long_wear_mode=1
      standard_hr_only=1
      shift
      ;;
    --leave-running)
      leave_running=1
      shift
      ;;
    --reset-capture-defaults)
      reset_capture_defaults=1
      shift
      ;;
    --reset-link-diagnostics)
      reset_link_diagnostics=1
      shift
      ;;
    --reset-sample-diagnostics)
      reset_sample_diagnostics=1
      shift
      ;;
    --reset-protocol-diagnostics)
      reset_protocol_diagnostics=1
      shift
      ;;
    --active-motion-imu-check)
      active_motion_imu_check=1
      full_protocol_mode=1
      standard_hr_only=0
      long_wear_mode=0
      reset_protocol_diagnostics=1
      log_gate_status=1
      shift
      ;;
    --flush-active-journal-after)
      flush_active_journal_after=${2:?--flush-active-journal-after requires a value}
      shift 2
      ;;
    --manual-checkpoint-after)
      manual_checkpoint_after=${2:?--manual-checkpoint-after requires a value}
      shift 2
      ;;
    --force-no-data-watchdog-after)
      force_no_data_watchdog_after=${2:?--force-no-data-watchdog-after requires a value}
      shift 2
      ;;
    --force-accepted-hr-watchdog-after)
      force_accepted_hr_watchdog_after=${2:?--force-accepted-hr-watchdog-after requires a value}
      shift 2
      ;;
    --force-hr-continuity-watchdog-after)
      force_hr_continuity_watchdog_after=${2:?--force-hr-continuity-watchdog-after requires a value}
      shift 2
      ;;
    --force-rr-presence-watchdog-after)
      force_rr_presence_watchdog_after=${2:?--force-rr-presence-watchdog-after requires a value}
      shift 2
      ;;
    --force-missing-2a37-after)
      force_missing_2a37_after=${2:?--force-missing-2a37-after requires a value}
      shift 2
      ;;
    --backup-sessions)
      backup_sessions=1
      shift
      ;;
    --verify-backup)
      verify_backup=1
      shift
      ;;
    --restore-backup)
      restore_backup=1
      shift
      ;;
    --push-backup)
      push_backup_path=${2:?--push-backup requires a value}
      shift 2
      ;;
    --push-rr-reference)
      push_rr_reference_path=${2:?--push-rr-reference requires a value}
      shift 2
      ;;
    --push-rr-reference-as)
      push_rr_reference_name=${2:?--push-rr-reference-as requires a value}
      shift 2
      ;;
    --push-hr-reference)
      push_hr_reference_path=${2:?--push-hr-reference requires a value}
      shift 2
      ;;
    --push-hr-reference-as)
      push_hr_reference_name=${2:?--push-hr-reference-as requires a value}
      shift 2
      ;;
    --clear-reference-inputs)
      clear_reference_inputs=1
      shift
      ;;
    --healthkit-export)
      healthkit_export=1
      shift
      ;;
    --healthkit-reference-audit)
      healthkit_reference_audit=1
      shift
      ;;
    --healthkit-reset-rebuild-atria-hr)
      healthkit_reset_rebuild=1
      shift
      ;;
    --confirm-best-workout-candidate)
      confirm_best_workout_candidate=1
      shift
      ;;
    --confirm-best-sleep-candidate)
      confirm_best_sleep_candidate=1
      shift
      ;;
    --export-rr-reference-package)
      export_rr_reference_package=1
      shift
      ;;
    --export-hr-reference-package)
      export_hr_reference_package=1
      shift
      ;;
    --validate-rr-reference)
      validate_rr_reference=1
      shift
      ;;
    --validate-hr-reference)
      validate_hr_reference=1
      shift
      ;;
    --pull-reference-package)
      pull_reference_package_dir=${2:?--pull-reference-package requires a value}
      shift 2
      ;;
    --morning-hrv-check)
      morning_hrv_check=1
      shift
      ;;
    --morning-hrv-force)
      morning_hrv_force=1
      shift
      ;;
    --gate-e-workout-capture)
      gate_e_workout_capture=1
      shift
      ;;
    --gate-e-hr-only-workout-capture)
      gate_e_workout_capture=1
      gate_e_hr_only_workout_capture=1
      standard_hr_only=1
      shift
      ;;
    --gate-d-hr-comparison-capture)
      gate_d_hr_comparison_capture=1
      standard_hr_only=1
      shift
      ;;
    --auto-save-session-after)
      auto_save_session_after=${2:?--auto-save-session-after requires a value}
      shift 2
      ;;
    --auto-save-session-every)
      auto_save_session_every=${2:?--auto-save-session-every requires a value}
      shift 2
      ;;
    --checkpoint-session-every)
      checkpoint_session_every=${2:?--checkpoint-session-every requires a value}
      shift 2
      ;;
    --log-live-workout-every)
      log_live_workout_every=${2:?--log-live-workout-every requires a value}
      shift 2
      ;;
    --auto-save-workout-when-ready)
      auto_save_workout_when_ready=${2:?--auto-save-workout-when-ready requires a value}
      shift 2
      ;;
    --verify-workout-label)
      verify_workout_label=${2:?--verify-workout-label requires a value}
      shift 2
      ;;
    --verify-workout-after)
      verify_workout_after=${2:?--verify-workout-after requires a value}
      shift 2
      ;;
    --verify-sleep)
      verify_sleep=1
      shift
      ;;
    --verify-sleep-label)
      verify_sleep_label=${2:?--verify-sleep-label requires a value}
      shift 2
      ;;
    --verify-sleep-after)
      verify_sleep_after=${2:?--verify-sleep-after requires a value}
      shift 2
      ;;
    --schedule-notifications)
      schedule_notifications=1
      shift
      ;;
    --test-notification)
      test_notification=1
      shift
      ;;
    --notification-delay)
      notification_delay=${2:?--notification-delay requires a value}
      shift 2
      ;;
    --auto-capture)
      auto_capture=1
      shift
      ;;
    --strict-live-rr-capture)
      strict_live_rr_capture=1
      shift
      ;;
    --auto-capture-delay)
      auto_capture_delay=${2:?--auto-capture-delay requires a value}
      shift 2
      ;;
    --auto-capture-when-rr)
      auto_capture_when_rr=${2:?--auto-capture-when-rr requires a value}
      shift 2
      ;;
    --auto-capture-rr-window)
      auto_capture_rr_window=${2:?--auto-capture-rr-window requires a value}
      shift 2
      ;;
    --auto-capture-rr-min-frames)
      auto_capture_rr_min_frames=${2:?--auto-capture-rr-min-frames requires a value}
      shift 2
      ;;
    --auto-capture-max-rr-gap)
      auto_capture_max_rr_gap=${2:?--auto-capture-max-rr-gap requires a value}
      shift 2
      ;;
    --auto-capture-rr-timeout)
      auto_capture_rr_timeout=${2:?--auto-capture-rr-timeout requires a value}
      shift 2
      ;;
    --auto-capture-max-attempts)
      auto_capture_max_attempts=${2:?--auto-capture-max-attempts requires a value}
      shift 2
      ;;
    --stop-when-ready)
      stop_when_ready=1
      shift
      ;;
    --auto-stop-after)
      auto_stop_after=${2:?--auto-stop-after requires a value}
      shift 2
      ;;
    --label)
      capture_label=${2:?--label requires a value}
      capture_label_explicit=1
      shift 2
      ;;
    --realtime-start-retries)
      realtime_start_retries=${2:?--realtime-start-retries requires a value}
      shift 2
      ;;
    --realtime-restart-zero-rr-seconds)
      realtime_restart_zero_rr_seconds=${2:?--realtime-restart-zero-rr-seconds requires a value}
      shift 2
      ;;
    --realtime-reassert-zero-rr-seconds)
      realtime_reassert_zero_rr_seconds=${2:?--realtime-reassert-zero-rr-seconds requires a value}
      shift 2
      ;;
    --disable-history-ack)
      disable_history_ack=1
      shift
      ;;
    --history-ack-mode)
      history_ack_mode=${2:?--history-ack-mode requires a value}
      shift 2
      ;;
    --history-recent-sweep)
      history_recent_sweep=1
      shift
      ;;
    --history-recent-offsets)
      history_recent_offsets=${2:?--history-recent-offsets requires a value}
      shift 2
      ;;
    --history-selector-sweep)
      history_selector_sweep=1
      shift
      ;;
    --history-selector-mode)
      history_selector_mode=${2:?--history-selector-mode requires a value}
      shift 2
      ;;
    --history-selector-range-index)
      history_selector_range_index=${2:?--history-selector-range-index requires a value}
      shift 2
      ;;
    --history-range-sweep)
      history_range_sweep=1
      shift
      ;;
    --history-range-payloads)
      history_range_payloads=${2:?--history-range-payloads requires a value}
      shift 2
      ;;
    --history-init-sweep)
      history_init_sweep=${2:?--history-init-sweep requires a value}
      shift 2
      ;;
    --history-skip-range)
      history_skip_range=1
      shift
      ;;
    --history-only-probe)
      history_only_probe=1
      shift
      ;;
    --history-noop-backfill)
      history_noop_backfill=1
      shift
      ;;
    --history-clock-handshake)
      history_clock_handshake=1
      shift
      ;;
    --probe-command)
      probe_command=${2:?--probe-command requires a value}
      shift 2
      ;;
    --probe-command-delay)
      probe_command_delay=${2:?--probe-command-delay requires a value}
      shift 2
      ;;
    --probe-sweep)
      probe_sweep=${2:?--probe-sweep requires a value}
      shift 2
      ;;
    --probe-sweep-interval)
      probe_sweep_interval=${2:?--probe-sweep-interval requires a value}
      shift 2
      ;;
    --probe-command-mode)
      probe_command_mode=${2:?--probe-command-mode requires a value}
      shift 2
      ;;
    --pull-capture)
      pull_capture_dir=${2:?--pull-capture requires a value}
      shift 2
      ;;
    --pull-backups)
      pull_backups_dir=${2:?--pull-backups requires a value}
      shift 2
      ;;
    --pull-sessions)
      pull_sessions_dir=${2:?--pull-sessions requires a value}
      shift 2
      ;;
    --pull-historical)
      pull_historical_dir=${2:?--pull-historical requires a value}
      shift 2
      ;;
    --replay-log)
      replay_log=${2:?--replay-log requires a value}
      build=0
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$gate_e_workout_capture" -eq 1 ]]; then
  if [[ "$seconds_explicit" -eq 0 ]]; then
    seconds=1200
  fi
  if [[ "$capture_label_explicit" -eq 0 ]]; then
    capture_label="gate-e-hrr50-workout"
  fi
  quiet_ble_logs=1
  if [[ "$gate_e_hr_only_workout_capture" -eq 1 ]]; then
    standard_hr_only=1
  fi
  reset_link_diagnostics=1
  reset_sample_diagnostics=1
  log_workout_preflight=1
  log_daily_rollups=1
  log_gate_status=1
  backup_sessions=1
  verify_backup=1
  gate_e_contract=1
  if [[ -z "$checkpoint_session_every" ]]; then
    checkpoint_session_every=60
  fi
  if [[ -z "$log_live_workout_every" ]]; then
    log_live_workout_every=15
  fi
  if [[ -z "$auto_save_workout_when_ready" ]]; then
    auto_save_workout_when_ready=15
  fi
  if [[ -z "$verify_workout_label" ]]; then
    verify_workout_label="$capture_label"
  fi
  if [[ -z "$verify_workout_after" ]]; then
    verify_workout_after=900
  fi
  if [[ -z "$log_path" ]]; then
    log_path=auto
  fi
fi

if [[ "$gate_d_hr_comparison_capture" -eq 1 ]]; then
  if [[ "$seconds_explicit" -eq 0 ]]; then
    seconds=1200
  fi
  if [[ "$capture_label_explicit" -eq 0 ]]; then
    capture_label="gate-d-hr-comparison"
  fi
  standard_hr_only=1
  quiet_ble_logs=1
  reset_link_diagnostics=1
  reset_sample_diagnostics=1
  log_workout_preflight=1
  log_daily_rollups=1
  export_hr_reference_package=1
  backup_sessions=1
  verify_backup=1
  if [[ -z "$checkpoint_session_every" ]]; then
    checkpoint_session_every=60
  fi
  if [[ -z "$log_live_workout_every" ]]; then
    log_live_workout_every=15
  fi
  if [[ -z "$auto_save_workout_when_ready" ]]; then
    auto_save_workout_when_ready=15
  fi
  if [[ -z "$verify_workout_label" ]]; then
    verify_workout_label="$capture_label"
  fi
  if [[ -z "$verify_workout_after" ]]; then
    verify_workout_after=900
  fi
  if [[ -z "$log_path" ]]; then
    log_path=auto
  fi
fi

if [[ "$gate_e_contract" -eq 1 ]]; then
  cat <<EOF
HARNESS_GATE_E_WORKOUT_CONTRACT_START
mode=$([[ "$gate_e_hr_only_workout_capture" -eq 1 ]] && printf 'standard_hr_only' || printf 'full_protocol')
label=$capture_label
seconds=$seconds
expected_target_hr_min_bpm=121
authoritative_threshold_field=ATRIADBG_workout_preflight_or_live_workout_threshold_hr
target_continuous_bout_min_s=480
target_total_duration_min_s=600
target_stream_coverage_min_percent=75
success_fields=workout_saved_ready,workout_days,live_workout_ready,workout_best_stream_coverage_percent,workout_best_elevated_s,workout_best_longest_bout_s,workout_best_required_bout_s,workout_best_threshold_gap_bpm
fail_closed_rules=no_hr_estimation,no_workout_from_borderline_only,no_healthkit_workout_until_detector_ready,no_external_hr_reference_from_atria_healthkit
post_run_analysis=tools/analyze_gate_e_workout_log.py LOG && tools/analyze_workout_store.py --active-journal PULLED_ACTIVE_JOURNAL
HARNESS_GATE_E_WORKOUT_CONTRACT_END
EOF
fi

if [[ "$active_motion_imu_check" -eq 1 ]]; then
  full_protocol_mode=1
  standard_hr_only=0
  long_wear_mode=0
  reset_protocol_diagnostics=1
  log_gate_status=1
  if [[ "$seconds_explicit" -eq 0 ]]; then
    seconds=180
  fi
  if [[ -z "$log_path" ]]; then
    log_path=auto
  fi
fi

if [[ "$history_noop_backfill" -eq 1 ]]; then
  history_only_probe=1
  history_skip_range=1
  history_clock_handshake=1
  if [[ -z "$history_init_sweep" ]]; then
    history_init_sweep="1400,6000,1600"
  fi
  if [[ -z "$history_ack_mode" ]]; then
    history_ack_mode="enddata"
  fi
  if [[ -z "$probe_command_mode" ]]; then
    probe_command_mode="wr"
  fi
  if [[ "$seconds_explicit" -eq 0 ]]; then
    seconds=180
  fi
  if [[ -z "$log_path" ]]; then
    log_path=auto
  fi
fi

protocol_experiment=0
if [[ "$full_protocol_mode" -eq 1 || "$active_motion_imu_check" -eq 1 || "$until_realtime" -eq 1 || "$until_ready" -eq 1 || "$auto_capture" -eq 1 ]]; then
  protocol_experiment=1
fi
if [[ "$history_recent_sweep" -eq 1 || "$history_selector_sweep" -eq 1 || "$history_range_sweep" -eq 1 || "$history_only_probe" -eq 1 || "$history_noop_backfill" -eq 1 || "$history_clock_handshake" -eq 1 ]]; then
  protocol_experiment=1
fi
if [[ -n "$probe_command" || -n "$probe_sweep" || -n "$history_init_sweep" || -n "$history_recent_offsets" || -n "$history_range_payloads" || -n "$history_selector_mode" ]]; then
  protocol_experiment=1
fi

status_or_export_audit=0
if [[ "$log_gate_status" -eq 1 || "$log_gate_status_deep" -eq 1 || "$log_activity_detections" -eq 1 || "$log_daily_rollups" -eq 1 || "$log_trends" -eq 1 || "$log_widget_snapshot" -eq 1 || "$log_workout_preflight" -eq 1 || "$log_strain_validation" -eq 1 || "$backup_sessions" -eq 1 || "$verify_backup" -eq 1 || "$healthkit_export" -eq 1 || "$healthkit_reference_audit" -eq 1 || "$healthkit_reset_rebuild" -eq 1 || -n "$pull_sessions_dir" || -n "$pull_backups_dir" ]]; then
  status_or_export_audit=1
fi

if [[ "$protocol_experiment" -eq 0 && "$status_or_export_audit" -eq 1 ]]; then
  standard_hr_only=1
  long_wear_mode=1
fi

case "$seconds" in
  ''|*[!0-9]*)
    printf 'Invalid --seconds value: %s\n' "$seconds" >&2
    exit 64
    ;;
esac

case "$realtime_start_retries" in
  ''|*[!0-9]*)
    if [[ -n "$realtime_start_retries" ]]; then
      printf 'Invalid --realtime-start-retries value: %s\n' "$realtime_start_retries" >&2
      exit 64
    fi
    ;;
esac

if [[ -n "$realtime_restart_zero_rr_seconds" && ! "$realtime_restart_zero_rr_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --realtime-restart-zero-rr-seconds value: %s\n' "$realtime_restart_zero_rr_seconds" >&2
  exit 64
fi
if [[ -n "$realtime_reassert_zero_rr_seconds" && ! "$realtime_reassert_zero_rr_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --realtime-reassert-zero-rr-seconds value: %s\n' "$realtime_reassert_zero_rr_seconds" >&2
  exit 64
fi
if [[ -n "$auto_stop_after" && ! "$auto_stop_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-stop-after value: %s\n' "$auto_stop_after" >&2
  exit 64
fi
if [[ -n "$auto_capture_delay" && ! "$auto_capture_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-capture-delay value: %s\n' "$auto_capture_delay" >&2
  exit 64
fi
if [[ -n "$auto_capture_when_rr" && ! "$auto_capture_when_rr" =~ ^([01]([.][0-9]+)?|[.][0-9]+)$ ]]; then
  printf 'Invalid --auto-capture-when-rr value: %s\n' "$auto_capture_when_rr" >&2
  exit 64
fi
if [[ -n "$auto_capture_rr_window" && ! "$auto_capture_rr_window" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-capture-rr-window value: %s\n' "$auto_capture_rr_window" >&2
  exit 64
fi
if [[ -n "$auto_capture_max_rr_gap" && ! "$auto_capture_max_rr_gap" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-capture-max-rr-gap value: %s\n' "$auto_capture_max_rr_gap" >&2
  exit 64
fi
case "$auto_capture_rr_min_frames" in
  ''|*[!0-9]*)
    if [[ -n "$auto_capture_rr_min_frames" ]]; then
      printf 'Invalid --auto-capture-rr-min-frames value: %s\n' "$auto_capture_rr_min_frames" >&2
      exit 64
    fi
    ;;
esac
if [[ -n "$auto_capture_rr_timeout" && ! "$auto_capture_rr_timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-capture-rr-timeout value: %s\n' "$auto_capture_rr_timeout" >&2
  exit 64
fi
case "$auto_capture_max_attempts" in
  ''|*[!0-9]*)
    if [[ -n "$auto_capture_max_attempts" ]]; then
      printf 'Invalid --auto-capture-max-attempts value: %s\n' "$auto_capture_max_attempts" >&2
      exit 64
    fi
    ;;
esac
if [[ -n "$notification_delay" && ! "$notification_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --notification-delay value: %s\n' "$notification_delay" >&2
  exit 64
fi
if [[ -n "$log_gate_status_after" && ! "$log_gate_status_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --log-gate-status-after value: %s\n' "$log_gate_status_after" >&2
  exit 64
fi
if [[ -n "$auto_save_session_after" && ! "$auto_save_session_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-save-session-after value: %s\n' "$auto_save_session_after" >&2
  exit 64
fi
if [[ -n "$auto_save_session_every" && ! "$auto_save_session_every" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-save-session-every value: %s\n' "$auto_save_session_every" >&2
  exit 64
fi
if [[ -n "$checkpoint_session_every" && ! "$checkpoint_session_every" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --checkpoint-session-every value: %s\n' "$checkpoint_session_every" >&2
  exit 64
fi
if [[ -n "$flush_active_journal_after" && ! "$flush_active_journal_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --flush-active-journal-after value: %s\n' "$flush_active_journal_after" >&2
  exit 64
fi
if [[ -n "$manual_checkpoint_after" && ! "$manual_checkpoint_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --manual-checkpoint-after value: %s\n' "$manual_checkpoint_after" >&2
  exit 64
fi
if [[ -n "$force_hr_continuity_watchdog_after" && ! "$force_hr_continuity_watchdog_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --force-hr-continuity-watchdog-after value: %s\n' "$force_hr_continuity_watchdog_after" >&2
  exit 64
fi
if [[ -n "$force_rr_presence_watchdog_after" && ! "$force_rr_presence_watchdog_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --force-rr-presence-watchdog-after value: %s\n' "$force_rr_presence_watchdog_after" >&2
  exit 64
fi
if [[ -n "$force_missing_2a37_after" && ! "$force_missing_2a37_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --force-missing-2a37-after value: %s\n' "$force_missing_2a37_after" >&2
  exit 64
fi
if [[ -n "$force_accepted_hr_watchdog_after" && ! "$force_accepted_hr_watchdog_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --force-accepted-hr-watchdog-after value: %s\n' "$force_accepted_hr_watchdog_after" >&2
  exit 64
fi
if [[ -n "$log_live_workout_every" && ! "$log_live_workout_every" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --log-live-workout-every value: %s\n' "$log_live_workout_every" >&2
  exit 64
fi
if [[ -n "$auto_save_workout_when_ready" && ! "$auto_save_workout_when_ready" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --auto-save-workout-when-ready value: %s\n' "$auto_save_workout_when_ready" >&2
  exit 64
fi
if [[ -n "$verify_workout_after" && ! "$verify_workout_after" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --verify-workout-after value: %s\n' "$verify_workout_after" >&2
  exit 64
fi
if [[ -n "$probe_command" && ! "$probe_command" =~ ^(0x)?[0-9a-fA-F][0-9a-fA-F]([:_-]?[0-9a-fA-F][0-9a-fA-F])*$ ]]; then
  printf 'Invalid --probe-command hex value: %s\n' "$probe_command" >&2
  exit 64
fi
if [[ -n "$probe_sweep" && ! "$probe_sweep" =~ ^(0x)?[0-9a-fA-F][0-9a-fA-F]([:_-]?[0-9a-fA-F][0-9a-fA-F])*(,(0x)?[0-9a-fA-F][0-9a-fA-F]([:_-]?[0-9a-fA-F][0-9a-fA-F])*)*$ ]]; then
  printf 'Invalid --probe-sweep hex list: %s\n' "$probe_sweep" >&2
  exit 64
fi
if [[ -n "$probe_command_delay" && ! "$probe_command_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --probe-command-delay value: %s\n' "$probe_command_delay" >&2
  exit 64
fi
if [[ -n "$probe_sweep_interval" && ! "$probe_sweep_interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Invalid --probe-sweep-interval value: %s\n' "$probe_sweep_interval" >&2
  exit 64
fi
if [[ -n "$history_recent_offsets" && ! "$history_recent_offsets" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
  printf 'Invalid --history-recent-offsets value: %s\n' "$history_recent_offsets" >&2
  exit 64
fi
if [[ -n "$history_range_payloads" && ! "$history_range_payloads" =~ ^([0-9a-fA-F][0-9a-fA-F])+(,([0-9a-fA-F][0-9a-fA-F])+)*$ ]]; then
  printf 'Invalid --history-range-payloads value: %s\n' "$history_range_payloads" >&2
  exit 64
fi
if [[ -n "$history_init_sweep" && ! "$history_init_sweep" =~ ^(0x)?[0-9a-fA-F][0-9a-fA-F]([:_-]?[0-9a-fA-F][0-9a-fA-F])*(,(0x)?[0-9a-fA-F][0-9a-fA-F]([:_-]?[0-9a-fA-F][0-9a-fA-F])*)*$ ]]; then
  printf 'Invalid --history-init-sweep value: %s\n' "$history_init_sweep" >&2
  exit 64
fi
if [[ -n "$history_selector_range_index" && ! "$history_selector_range_index" =~ ^[0-9]+$ ]]; then
  printf 'Invalid --history-selector-range-index value: %s\n' "$history_selector_range_index" >&2
  exit 64
fi
if [[ -n "$push_backup_path" ]]; then
  if [[ ! -f "$push_backup_path" ]]; then
    printf 'Missing --push-backup file: %s\n' "$push_backup_path" >&2
    exit 66
  fi
  if [[ "$push_backup_path" != *.json ]]; then
    printf 'Invalid --push-backup file extension, expected .json: %s\n' "$push_backup_path" >&2
    exit 64
  fi
  python3 -m json.tool "$push_backup_path" >/dev/null
fi
if [[ -n "$push_rr_reference_path" ]]; then
  if [[ ! -f "$push_rr_reference_path" ]]; then
    printf 'Missing --push-rr-reference file: %s\n' "$push_rr_reference_path" >&2
    exit 66
  fi
  if [[ "$push_rr_reference_path" != *.csv ]]; then
    printf 'Invalid --push-rr-reference file extension, expected .csv: %s\n' "$push_rr_reference_path" >&2
    exit 64
  fi
  if [[ ! "$push_rr_reference_name" =~ ^[A-Za-z0-9._-]+[.]csv$ ]]; then
    printf 'Invalid --push-rr-reference-as value, expected safe basename ending .csv: %s\n' "$push_rr_reference_name" >&2
    exit 64
  fi
fi
if [[ -n "$push_hr_reference_path" ]]; then
  if [[ ! -f "$push_hr_reference_path" ]]; then
    printf 'Missing --push-hr-reference file: %s\n' "$push_hr_reference_path" >&2
    exit 66
  fi
  if [[ "$push_hr_reference_path" != *.csv ]]; then
    printf 'Invalid --push-hr-reference file extension, expected .csv: %s\n' "$push_hr_reference_path" >&2
    exit 64
  fi
  if [[ ! "$push_hr_reference_name" =~ ^[A-Za-z0-9._-]+[.]csv$ ]]; then
    printf 'Invalid --push-hr-reference-as value, expected safe basename ending .csv: %s\n' "$push_hr_reference_name" >&2
    exit 64
  fi
fi
if [[ "$active_motion_imu_check" -eq 1 && -z "$log_gate_status_after" ]]; then
  if (( seconds > 150 )); then
    log_gate_status_after=150
  elif (( seconds > 45 )); then
    log_gate_status_after=$((seconds - 15))
  else
    log_gate_status_after=15
  fi
fi
case "$history_selector_mode" in
  ""|"current-unix-bare"|"current-unix-prefix0"|"current-unix-prefix1"|"current-unix-all"|"current-record8"|"known-block-record8"|"range-window24"|"record-shape-all") ;;
  *)
    printf 'Invalid --history-selector-mode value: %s\n' "$history_selector_mode" >&2
    exit 64
    ;;
esac
case "$history_ack_mode" in
  ""|"trim"|"enddata"|"index"|"unix"|"zero"|"none") ;;
  *)
    printf 'Invalid --history-ack-mode value: %s\n' "$history_ack_mode" >&2
    exit 64
    ;;
esac
case "$probe_command_mode" in
  ""|"wwr"|"wr") ;;
  *)
    printf 'Invalid --probe-command-mode value: %s\n' "$probe_command_mode" >&2
    exit 64
    ;;
esac
case "$build_configuration" in
  Debug|Release) ;;
  *)
    printf 'Invalid --configuration value: %s (expected Debug or Release)\n' "$build_configuration" >&2
    exit 64
    ;;
esac

project="Atria/Atria.xcodeproj"
scheme="Atria"
derived_data="build/DerivedData"
app_path="${derived_data}/Build/Products/${build_configuration}-iphoneos/Atria.app"
xcode_build_destination="id=${xcode_device_id}"
devicectl_destination_state="unchecked"

log_devicectl_destination_state() {
  local device_details device_status devicectl_state
  local devicectl_paired devicectl_wired devicectl_booted devicectl_developer_mode
  set +e
  device_details=$(xcrun devicectl device info details --device "$device_id" 2>&1)
  device_status=$?
  set -e
  if [[ "$device_status" -eq 0 ]]; then
    devicectl_state="unknown"
    devicectl_paired=0
    devicectl_wired=0
    devicectl_booted=0
    devicectl_developer_mode=0
    grep -Fq "Pairing State: paired" <<<"$device_details" && devicectl_paired=1
    grep -Fq "Transport Type: wired" <<<"$device_details" && devicectl_wired=1
    grep -Fq "Boot State: booted" <<<"$device_details" && devicectl_booted=1
    grep -Fq "Developer Mode Status: Enabled" <<<"$device_details" && devicectl_developer_mode=1
    if [[ "$devicectl_paired" -eq 1 \
      && "$devicectl_wired" -eq 1 \
      && "$devicectl_booted" -eq 1 \
      && "$devicectl_developer_mode" -eq 1 ]]; then
      devicectl_state="ready"
    fi
    devicectl_destination_state="$devicectl_state"
    printf 'HARNESS_DEVICE_PREFLIGHT_DEVICE status=%s tool=devicectl_details paired=%d wired=%d booted=%d developer_mode_enabled=%d install_device=%s\n' \
      "$devicectl_state" \
      "$devicectl_paired" \
      "$devicectl_wired" \
      "$devicectl_booted" \
      "$devicectl_developer_mode" \
      "$device_id"
  else
    devicectl_destination_state="failed"
    printf 'HARNESS_DEVICE_PREFLIGHT_DEVICE status=failed tool=devicectl_details code=%d install_device=%s\n' "$device_status" "$device_id"
  fi
}

xcode_destination_preflight() {
  local output status reason
  set +e
  output=$(xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration "$build_configuration" \
    -destination "id=${xcode_device_id}" \
    -destination-timeout 10 \
    -showdestinations 2>&1)
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    reason="xcodebuild_showdestinations_failed"
    if grep -Fq "observing system notifications failed" <<<"$output"; then
      reason="unlock_or_development_services_required"
      log_devicectl_destination_state
      if [[ "$devicectl_destination_state" == "ready" ]]; then
        reason="xcode_notification_observe_false_negative"
      fi
    fi
    if [[ "$reason" == "xcode_notification_observe_false_negative" ]]; then
      xcode_build_destination="generic/platform=iOS"
      printf 'HARNESS_XCODE_DESTINATION_WARNING suppressed=1 raw_reason=observing_system_notifications_failed devicectl_state=%s showdestinations_status=%d action=generic_ios_build_then_devicectl_install\n' "$devicectl_destination_state" "$status"
      printf 'HARNESS_DEVICE_PREFLIGHT status=fallback reason=%s tool=xcodebuild_showdestinations code=%d xcode_destination=%s install_device=%s action=generic_ios_build_then_devicectl_install\n' "$reason" "$status" "$xcode_build_destination" "$device_id"
      return 0
    fi
    printf '%s\n' "$output" >&2
    printf 'HARNESS_DEVICE_PREFLIGHT status=failed tool=xcodebuild_showdestinations code=%d\n' "$status" >&2
    printf 'HARNESS_ERROR=device_destination_preflight_failed\n' >&2
    exit 69
  fi
  if grep -Fq "not available because" <<<"$output"; then
    reason="device_unavailable"
    if grep -Fq "observing system notifications failed" <<<"$output"; then
      reason="unlock_or_development_services_required"
    fi
    log_devicectl_destination_state
    if [[ "$reason" == "unlock_or_development_services_required" && "$devicectl_destination_state" == "ready" ]]; then
      reason="xcode_notification_observe_false_negative"
    fi
    if [[ "$reason" == "xcode_notification_observe_false_negative" ]]; then
      printf 'HARNESS_XCODE_DESTINATION_WARNING suppressed=1 raw_reason=observing_system_notifications_failed devicectl_state=%s action=ignore_xcode_observer_and_use_devicectl\n' "$devicectl_destination_state"
    else
      printf '%s\n' "$output" >&2
    fi
    xcode_build_destination="generic/platform=iOS"
    printf 'HARNESS_DEVICE_PREFLIGHT status=fallback reason=%s tool=xcodebuild_showdestinations xcode_destination=%s install_device=%s action=generic_ios_build_then_devicectl_install\n' "$reason" "$xcode_build_destination" "$device_id"
    return 0
  fi
  xcode_build_destination="id=${xcode_device_id}"
  printf 'HARNESS_DEVICE_PREFLIGHT status=ok tool=xcodebuild_showdestinations xcode_destination=%s install_device=%s\n' "$xcode_build_destination" "$device_id"
}

if [[ "$log_path" == "auto" ]]; then
  log_path="logs/live-device/$(date -u +"%Y%m%dT%H%M%SZ").log"
fi
if [[ -n "$log_path" ]]; then
  mkdir -p "$(dirname "$log_path")"
fi

if [[ -z "$replay_log" ]]; then
  if ! xcrun devicectl list devices | grep -F "$device_id" | grep -Fq "physical"; then
    printf 'Physical iPhone not available to devicectl: %s\n' "$device_id" >&2
    printf 'Check cable, trust prompt, and Developer Mode, then retry.\n' >&2
    exit 69
  fi
fi

if [[ -z "$replay_log" && "$pull_only" -eq 0 ]]; then
  if [[ "$build" -eq 1 ]]; then
    xcode_destination_preflight
    build_output=$(mktemp -t atria-xcodebuild.XXXXXX.log)
    set +e
    xcodebuild \
      -project "$project" \
      -scheme "$scheme" \
      -configuration "$build_configuration" \
      -destination "$xcode_build_destination" \
      -destination-timeout 10 \
      -derivedDataPath "$derived_data" \
      build >"$build_output" 2>&1
    build_status=$?
    set -e
    if [[ "$build_status" -ne 0 ]]; then
      if grep -Fq "not available because" "$build_output"; then
        build_fallback_reason="xcode_destination_unavailable"
        if grep -Fq "observing system notifications failed" "$build_output"; then
          build_fallback_reason="unlock_or_development_services_required"
          log_devicectl_destination_state
          if [[ "$devicectl_destination_state" == "ready" ]]; then
            build_fallback_reason="xcode_notification_observe_false_negative"
          fi
        fi
        if [[ "$build_fallback_reason" == "xcode_notification_observe_false_negative" ]]; then
          printf 'HARNESS_XCODE_BUILD_WARNING suppressed=1 raw_reason=observing_system_notifications_failed devicectl_state=%s action=generic_ios_build_then_devicectl_install\n' "$devicectl_destination_state"
        else
          cat "$build_output" >&2
        fi
        printf 'HARNESS_BUILD_FALLBACK status=retry reason=%s from_destination=%s to_destination=generic/platform=iOS action=generic_ios_build_then_devicectl_install\n' "$build_fallback_reason" "$xcode_build_destination"
        xcode_build_destination="generic/platform=iOS"
        set +e
        xcodebuild \
          -project "$project" \
          -scheme "$scheme" \
          -configuration "$build_configuration" \
          -destination "$xcode_build_destination" \
          -destination-timeout 10 \
          -derivedDataPath "$derived_data" \
          build 2>&1 | tee -a "$build_output"
        build_status=${PIPESTATUS[0]}
        set -e
        if [[ "$build_status" -ne 0 ]]; then
          printf 'HARNESS_ERROR=xcodebuild_generic_fallback_failed code=%d\n' "$build_status" >&2
          rm -f "$build_output"
          exit "$build_status"
        fi
      else
        cat "$build_output" >&2
        printf 'HARNESS_ERROR=xcodebuild_failed code=%d\n' "$build_status" >&2
        rm -f "$build_output"
        exit "$build_status"
      fi
    else
      cat "$build_output"
    fi
    rm -f "$build_output"
  else
    if [[ ! -d "$app_path" ]]; then
      printf 'No built app at %s; rerun without --no-build.\n' "$app_path" >&2
      exit 66
    fi
    newest_source=$(find Atria/Atria -name '*.swift' -type f -newer "$app_path" -print -quit)
    if [[ -n "$newest_source" ]]; then
      printf 'Refusing stale --no-build: %s is newer than %s. Rerun without --no-build.\n' "$newest_source" "$app_path" >&2
      exit 66
    fi
  fi

  xcrun devicectl device install app --device "$device_id" "$app_path"

  if [[ -n "$push_backup_path" ]]; then
    pushed_backup_name="atria-sessions-$(date -u +"%Y%m%dT%H%M%SZ")-pushed.json"
    xcrun devicectl device copy to \
      --device "$device_id" \
      --domain-type appDataContainer \
      --domain-identifier "$bundle_id" \
      --source "$push_backup_path" \
      --destination "Documents/atria-backups/$pushed_backup_name"
    printf 'ATRIADBG_BACKUP_PUSH_FILE=Documents/atria-backups/%s\n' "$pushed_backup_name"
  fi
  if [[ -n "$push_rr_reference_path" ]]; then
    xcrun devicectl device copy to \
      --device "$device_id" \
      --domain-type appDataContainer \
      --domain-identifier "$bundle_id" \
      --source "$push_rr_reference_path" \
      --destination "Documents/atria-reference/$push_rr_reference_name"
    printf 'ATRIADBG_RR_REFERENCE_PUSH_FILE=Documents/atria-reference/%s\n' "$push_rr_reference_name"
  fi
  if [[ -n "$push_hr_reference_path" ]]; then
    xcrun devicectl device copy to \
      --device "$device_id" \
      --domain-type appDataContainer \
      --domain-identifier "$bundle_id" \
      --source "$push_hr_reference_path" \
      --destination "Documents/atria-reference/$push_hr_reference_name"
    printf 'ATRIADBG_HR_REFERENCE_PUSH_FILE=Documents/atria-reference/%s\n' "$push_hr_reference_name"
  fi
fi

python3 - "$device_id" "$bundle_id" "$seconds" "$until_realtime" "$until_ready" "$log_path" "$auto_capture" "$stop_when_ready" "$capture_label" "$auto_capture_delay" "$auto_capture_when_rr" "$auto_capture_rr_window" "$auto_capture_rr_min_frames" "$auto_capture_max_rr_gap" "$auto_capture_rr_timeout" "$auto_capture_max_attempts" "$strict_live_rr_capture" "$realtime_start_retries" "$realtime_restart_zero_rr_seconds" "$realtime_reassert_zero_rr_seconds" "$disable_history_ack" "$history_ack_mode" "$history_recent_sweep" "$history_recent_offsets" "$history_selector_sweep" "$history_selector_mode" "$history_selector_range_index" "$history_range_sweep" "$history_range_payloads" "$history_init_sweep" "$history_skip_range" "$history_clock_handshake" "$history_only_probe" "$probe_command" "$probe_command_delay" "$probe_command_mode" "$pull_capture_dir" "$pull_backups_dir" "$pull_sessions_dir" "$pull_historical_dir" "$export_rr_reference_package" "$export_hr_reference_package" "$validate_rr_reference" "$validate_hr_reference" "$clear_reference_inputs" "$pull_reference_package_dir" "$auto_stop_after" "$replay_log" "$probe_sweep" "$probe_sweep_interval" "$complete_onboarding" "$log_baseline" "$log_collection_health" "$log_collection_health_after" "$log_gate_status" "$log_gate_readiness" "$log_gate_status_after" "$log_gate_status_deep" "$log_activity_detections" "$log_daily_rollups" "$log_trends" "$log_widget_snapshot" "$log_workout_preflight" "$log_strain_validation" "$log_hr_consistency" "$log_hr_artifact_policy" "$log_hr_continuity_watchdog_state" "$quiet_ble_logs" "$full_protocol_mode" "$standard_hr_only" "$long_wear_mode" "$reset_capture_defaults" "$reset_link_diagnostics" "$reset_sample_diagnostics" "$reset_protocol_diagnostics" "$active_motion_imu_check" "$flush_active_journal_after" "$manual_checkpoint_after" "$force_no_data_watchdog_after" "$force_hr_continuity_watchdog_after" "$force_rr_presence_watchdog_after" "$force_missing_2a37_after" "$force_accepted_hr_watchdog_after" "$backup_sessions" "$verify_backup" "$restore_backup" "$healthkit_export" "$healthkit_reference_audit" "$healthkit_reset_rebuild" "$confirm_best_workout_candidate" "$confirm_best_sleep_candidate" "$morning_hrv_check" "$morning_hrv_force" "$auto_save_session_after" "$auto_save_session_every" "$checkpoint_session_every" "$log_live_workout_every" "$auto_save_workout_when_ready" "$verify_workout_label" "$verify_workout_after" "$verify_sleep" "$verify_sleep_label" "$verify_sleep_after" "$schedule_notifications" "$test_notification" "$notification_delay" "$leave_running" "$pull_only" <<'PY'
import subprocess
import sys
import time
import signal
import select
import shlex
import os
import json
import hashlib
from collections import Counter
from datetime import datetime
from pathlib import Path

device_id, bundle_id, seconds_raw, until_realtime_raw, until_ready_raw, log_path, auto_capture_raw, stop_when_ready_raw, capture_label, auto_capture_delay, auto_capture_when_rr, auto_capture_rr_window, auto_capture_rr_min_frames, auto_capture_max_rr_gap, auto_capture_rr_timeout, auto_capture_max_attempts, strict_live_rr_capture_raw, realtime_start_retries, realtime_restart_zero_rr_seconds, realtime_reassert_zero_rr_seconds, disable_history_ack_raw, history_ack_mode, history_recent_sweep_raw, history_recent_offsets, history_selector_sweep_raw, history_selector_mode, history_selector_range_index, history_range_sweep_raw, history_range_payloads, history_init_sweep, history_skip_range_raw, history_clock_handshake_raw, history_only_probe_raw, probe_command, probe_command_delay, probe_command_mode, pull_capture_dir, pull_backups_dir, pull_sessions_dir, pull_historical_dir, export_rr_reference_package_raw, export_hr_reference_package_raw, validate_rr_reference_raw, validate_hr_reference_raw, clear_reference_inputs_raw, pull_reference_package_dir, auto_stop_after, replay_log, probe_sweep, probe_sweep_interval, complete_onboarding_raw, log_baseline_raw, log_collection_health_raw, log_collection_health_after, log_gate_status_raw, log_gate_readiness_raw, log_gate_status_after, log_gate_status_deep_raw, log_activity_detections_raw, log_daily_rollups_raw, log_trends_raw, log_widget_snapshot_raw, log_workout_preflight_raw, log_strain_validation_raw, log_hr_consistency_raw, log_hr_artifact_policy_raw, log_hr_continuity_watchdog_state_raw, quiet_ble_logs_raw, full_protocol_mode_raw, standard_hr_only_raw, long_wear_mode_raw, reset_capture_defaults_raw, reset_link_diagnostics_raw, reset_sample_diagnostics_raw, reset_protocol_diagnostics_raw, active_motion_imu_check_raw, flush_active_journal_after, manual_checkpoint_after, force_no_data_watchdog_after, force_hr_continuity_watchdog_after, force_rr_presence_watchdog_after, force_missing_2a37_after, force_accepted_hr_watchdog_after, backup_sessions_raw, verify_backup_raw, restore_backup_raw, healthkit_export_raw, healthkit_reference_audit_raw, healthkit_reset_rebuild_raw, confirm_best_workout_candidate_raw, confirm_best_sleep_candidate_raw, morning_hrv_check_raw, morning_hrv_force_raw, auto_save_session_after, auto_save_session_every, checkpoint_session_every, log_live_workout_every, auto_save_workout_when_ready, verify_workout_label, verify_workout_after, verify_sleep_raw, verify_sleep_label, verify_sleep_after, schedule_notifications_raw, test_notification_raw, notification_delay, leave_running_raw, pull_only_raw = sys.argv[1:109]
seconds = int(seconds_raw)
until_realtime = until_realtime_raw == "1"
until_ready = until_ready_raw == "1"
auto_capture = auto_capture_raw == "1"
stop_when_ready = stop_when_ready_raw == "1"
strict_live_rr_capture = strict_live_rr_capture_raw == "1"
disable_history_ack = disable_history_ack_raw == "1"
history_recent_sweep = history_recent_sweep_raw == "1"
history_selector_sweep = history_selector_sweep_raw == "1"
history_range_sweep = history_range_sweep_raw == "1"
history_skip_range = history_skip_range_raw == "1"
history_clock_handshake = history_clock_handshake_raw == "1"
history_only_probe = history_only_probe_raw == "1"
export_rr_reference_package = export_rr_reference_package_raw == "1"
export_hr_reference_package = export_hr_reference_package_raw == "1"
validate_rr_reference = validate_rr_reference_raw == "1"
validate_hr_reference = validate_hr_reference_raw == "1"
clear_reference_inputs = clear_reference_inputs_raw == "1"
complete_onboarding = complete_onboarding_raw == "1"
log_baseline = log_baseline_raw == "1"
log_collection_health = log_collection_health_raw == "1"
log_gate_status = log_gate_status_raw == "1"
log_gate_readiness = log_gate_readiness_raw == "1"
log_gate_status_deep = log_gate_status_deep_raw == "1"
log_activity_detections = log_activity_detections_raw == "1"
log_daily_rollups = log_daily_rollups_raw == "1"
log_trends = log_trends_raw == "1"
log_widget_snapshot = log_widget_snapshot_raw == "1"
log_workout_preflight = log_workout_preflight_raw == "1"
log_strain_validation = log_strain_validation_raw == "1"
log_hr_consistency = log_hr_consistency_raw == "1"
log_hr_artifact_policy = log_hr_artifact_policy_raw == "1"
log_hr_continuity_watchdog_state = log_hr_continuity_watchdog_state_raw == "1"
quiet_ble_logs = quiet_ble_logs_raw == "1"
full_protocol_mode = full_protocol_mode_raw == "1"
standard_hr_only = standard_hr_only_raw == "1"
long_wear_mode = long_wear_mode_raw == "1"
reset_capture_defaults = reset_capture_defaults_raw == "1"
reset_link_diagnostics = reset_link_diagnostics_raw == "1"
reset_sample_diagnostics = reset_sample_diagnostics_raw == "1"
reset_protocol_diagnostics = reset_protocol_diagnostics_raw == "1"
active_motion_imu_check = active_motion_imu_check_raw == "1"
backup_sessions = backup_sessions_raw == "1"
verify_backup = verify_backup_raw == "1"
restore_backup = restore_backup_raw == "1"
healthkit_export = healthkit_export_raw == "1"
healthkit_reference_audit = healthkit_reference_audit_raw == "1"
healthkit_reset_rebuild = healthkit_reset_rebuild_raw == "1"
confirm_best_workout_candidate = confirm_best_workout_candidate_raw == "1"
confirm_best_sleep_candidate = confirm_best_sleep_candidate_raw == "1"
export_rr_reference_package = export_rr_reference_package_raw == "1"
verify_sleep = verify_sleep_raw == "1"
morning_hrv_check = morning_hrv_check_raw == "1"
morning_hrv_force = morning_hrv_force_raw == "1"
schedule_notifications = schedule_notifications_raw == "1"
test_notification = test_notification_raw == "1"
leave_running = leave_running_raw == "1"
pull_only = pull_only_raw == "1"
history_probe_requested = (
    history_recent_sweep
    or bool(history_recent_offsets)
    or history_selector_sweep
    or history_range_sweep
    or bool(history_range_payloads)
    or bool(history_init_sweep)
    or history_clock_handshake
    or history_only_probe
    or bool(probe_command)
    or bool(probe_sweep)
)
post_gate_side_effects = (
    backup_sessions
    or verify_backup
    or restore_backup
    or healthkit_export
    or healthkit_reference_audit
    or export_rr_reference_package
    or export_hr_reference_package
    or validate_rr_reference
    or validate_hr_reference
    or clear_reference_inputs
    or schedule_notifications
    or test_notification
    or log_trends
    or log_gate_readiness
    or log_strain_validation
    or log_widget_snapshot
    or bool(verify_workout_label)
    or verify_sleep
    or bool(pull_backups_dir)
    or bool(pull_reference_package_dir)
    or bool(pull_sessions_dir)
    or bool(pull_capture_dir)
    or bool(pull_historical_dir)
    or history_probe_requested
    or (standard_hr_only and log_gate_status)
)
log_file = None
if log_path:
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    log_file = open(log_path, "w", encoding="utf-8")


def emit(line: str = "") -> None:
    print(line, flush=True)
    if log_file is not None:
        log_file.write(line + "\n")
        log_file.flush()


def tokens_after(prefix: str, line: str) -> dict[str, str]:
    if prefix not in line:
        return {}
    tail = line.split(prefix, 1)[1].strip()
    parsed = {}
    for part in tail.split():
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        parsed[key] = value
    return parsed


def parse_log_timestamp(line: str) -> datetime | None:
    if len(line) < 23:
        return None
    try:
        return datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        return None


def elapsed_seconds(start: datetime | None, end: datetime | None) -> str:
    if start is None or end is None:
        return ""
    return f"{(end - start).total_seconds():.1f}"

def summarize_active_journal_segments(directory: Path) -> None:
    segments = []
    for path in sorted(directory.glob("segment-*.json")):
        try:
            with path.open(encoding="utf-8") as handle:
                segment = json.load(handle)
                segment["_file"] = path.name
                segments.append(segment)
        except (OSError, json.JSONDecodeError) as error:
            emit(f"ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY status=decode_error file={path.name} error={str(error)!r}")
            return
    if not segments:
        emit("ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY status=empty segments=0")
        return
    samples = []
    rr_samples = []
    starts = []
    updates = []
    for segment in segments:
        samples.extend(segment.get("samples", []))
        rr_samples.extend(segment.get("rrSamples", []))
        if isinstance(segment.get("startedAt"), (int, float)):
            starts.append(segment["startedAt"])
        if isinstance(segment.get("updatedAt"), (int, float)):
            updates.append(segment["updatedAt"])
    latest = segments[-1]
    duration = (max(updates) - min(starts)) if starts and updates else 0
    latest_bpm = samples[-1].get("bpm", "none") if samples else "none"
    emit("ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY "
         f"status=ok segments={len(segments)} duration_s={duration:.1f} "
         f"delta_samples={len(samples)} delta_rr={len(rr_samples)} "
         f"accepted_hr={latest.get('acceptedHRSamples', 0)} raw_hr={latest.get('rawHRNotifications', 0)} "
         f"raw_gaps={latest.get('rawHRGaps', 0)} accepted_gaps={latest.get('acceptedHRGaps', 0)} "
         f"max_raw_gap_s={float(latest.get('maxRawHRGap', 0) or 0):.1f} "
         f"max_accepted_gap_s={float(latest.get('maxAcceptedHRGap', 0) or 0):.1f} "
         f"battery={latest.get('batteryLevel', 'missing')} thermal={latest.get('thermalState', 'missing')} "
         f"low_power={int(bool(latest.get('lowPowerMode', False)))} "
         f"power_mode={latest.get('powerMode', 'missing')} "
         f"cadence_multiplier={float(latest.get('cadenceMultiplier', 0) or 0):.1f} "
         f"latest_bpm={latest_bpm} latest_file={latest.get('_file', 'unknown')} "
         f"label={str(latest.get('label', '')).replace(' ', '_')}")


def summarize_sessions_file(path: Path) -> None:
    try:
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        emit(f"ATRIADBG_SESSIONS_SUMMARY status=decode_error error={str(error)!r}")
        return
    if isinstance(payload, list):
        sessions = [item for item in payload if isinstance(item, dict)]
    elif isinstance(payload, dict):
        sessions = [item for item in payload.get("sessions", []) if isinstance(item, dict)]
    else:
        sessions = []
    if not sessions:
        emit("ATRIADBG_SESSIONS_SUMMARY status=empty sessions=0")
        return

    def number(value, default=0.0):
        return value if isinstance(value, (int, float)) else default

    def duration(session: dict) -> float:
        start = number(session.get("start"))
        end = number(session.get("end"))
        if end > start:
            return end - start
        points = session.get("points", [])
        if isinstance(points, list) and points:
            return max(number(point.get("t")) for point in points if isinstance(point, dict))
        return 0.0

    def rr_count(session: dict) -> int:
        rr = session.get("rrPoints")
        return len(rr) if isinstance(rr, list) else 0

    ordered = sorted(sessions, key=lambda session: number(session.get("end")), reverse=True)
    latest = ordered[0]
    latest_end = number(latest.get("end"))
    recent_window_s = 12 * 60 * 60
    recent = [
        session for session in sessions
        if latest_end <= 0 or number(session.get("end")) >= latest_end - recent_window_s
    ]
    recent_starts = [number(session.get("start")) for session in recent if number(session.get("start")) > 0]
    recent_ends = [number(session.get("end")) for session in recent if number(session.get("end")) > 0]
    recent_span = (max(recent_ends) - min(recent_starts)) if recent_starts and recent_ends else 0.0
    recent_duration = sum(duration(session) for session in recent)
    recent_samples = sum(len(session.get("points", [])) for session in recent if isinstance(session.get("points"), list))
    recent_rr = sum(rr_count(session) for session in recent)
    recent_raw_gaps = sum(int(number(session.get("hrRawGaps"), 0)) for session in recent)
    recent_accepted_gaps = sum(int(number(session.get("hrAcceptedGaps"), 0)) for session in recent)
    max_raw_gap = max((number(session.get("hrMaxRawGap")) for session in recent), default=0.0)
    max_accepted_gap = max((number(session.get("hrMaxAcceptedGap")) for session in recent), default=0.0)
    recent_coverage = (recent_duration / recent_span * 100) if recent_span > 0 else 0.0
    latest_samples = len(latest.get("points", [])) if isinstance(latest.get("points"), list) else 0
    latest_rr = rr_count(latest)
    latest_bpm = "none"
    latest_points = latest.get("points", [])
    if isinstance(latest_points, list) and latest_points:
        last_point = latest_points[-1]
        if isinstance(last_point, dict):
            latest_bpm = last_point.get("bpm", "none")
    emit("ATRIADBG_SESSIONS_SUMMARY "
         f"status=ok sessions={len(sessions)} recent_sessions={len(recent)} recent_window_s={recent_window_s} "
         f"recent_span_s={recent_span:.1f} recent_duration_s={recent_duration:.1f} recent_coverage_percent={recent_coverage:.1f} "
         f"recent_samples={recent_samples} recent_rr={recent_rr} "
         f"recent_raw_gaps={recent_raw_gaps} recent_accepted_gaps={recent_accepted_gaps} "
         f"recent_max_raw_gap_s={max_raw_gap:.1f} recent_max_accepted_gap_s={max_accepted_gap:.1f} "
         f"latest_duration_s={duration(latest):.1f} latest_samples={latest_samples} latest_rr={latest_rr} "
         f"latest_bpm={latest_bpm} latest_label={str(latest.get('label', '')).replace(' ', '_')}")


def frame_payload_from_frame_hex(line: str) -> tuple[str, bytes, bool] | None:
    tokens = tokens_after("ATRIADBG frame", line)
    channel = tokens.get("ch", "")
    raw_hex = tokens.get("hex")
    if raw_hex is None:
        return None
    try:
        frame = bytes.fromhex(raw_hex)
    except ValueError:
        return None
    if not frame:
        return None
    if frame[0] != 0xAA:
        return channel, frame, False
    if len(frame) < 8:
        return None
    length = frame[1] | (frame[2] << 8)
    payload_end = min(length, len(frame))
    payload = frame[4:payload_end]
    return channel, payload, length > len(frame) - 4


def realtime_payload_from_frame_hex(line: str) -> tuple[bytes, bool] | None:
    parsed = frame_payload_from_frame_hex(line)
    if parsed is None:
        return None
    _channel, payload, logged_hex_truncated = parsed
    if len(payload) < 10 or payload[0] != 0x28:
        return None
    return payload, logged_hex_truncated


startup_deadline = time.time() + max(seconds, 60)
deadline = startup_deadline
launch_seen = False
lines: list[str] = []
rr_summary = {
    "rr_frames": 0,
    "rr_values": 0,
    "rr_truncated_frames": 0,
    "rr_hr_mismatch_values": 0,
    "rr_source_2a37_frames": 0,
    "rr_source_2a37_values": 0,
    "rr_source_0x28_frames": 0,
    "rr_source_0x28_values": 0,
    "rr_source_0x28_used_frames": 0,
    "rr_source_0x28_used_values": 0,
    "standard_2a37_frames": 0,
    "standard_2a37_rr_frames": 0,
    "standard_2a37_rr_values": 0,
    "last_standard_2a37_payload": "",
    "last_standard_2a37_hr": "",
    "last_standard_2a37_rrnum": "",
    "last_standard_2a37_rr_ms": "",
    "last_rr_quality_source": "",
    "realtime_frames": 0,
    "realtime_rr_frames": 0,
    "realtime_rr_zero_frames": 0,
    "realtime_malformed_frames": 0,
    "realtime_truncated_rr_frames": 0,
    "realtime_restarts": 0,
    "realtime_reasserts": 0,
    "auto_capture_starts": 0,
    "auto_capture_stops": 0,
    "capture_aborts": 0,
    "capture_quality_resets": 0,
    "auto_capture_exhausted": 0,
    "last_realtime_hr": "",
    "last_realtime_rrnum": "",
    "last_realtime_rr_bytes": "",
    "last_realtime_payload_tail": "",
    "realtime_rr_fraction": "",
    "realtime_rr_percent": "",
    "realtime_zero_rr_tail_nonzero_frames": 0,
    "realtime_zero_rr_tail_valid_candidate_frames": 0,
    "last_rr_values": "",
    "last_rr_implied_bpm": "",
    "hrv_max_rr_gap_s": "0.0",
    "last_hrv_max_rr_gap_s": "",
    "first_realtime_elapsed_s": "",
    "first_rr_elapsed_s": "",
    "rr_start_delay_s": "",
    "last_rr_elapsed_s": "",
    "max_rr_log_gap_s": "",
        "cmd_response_count": 0,
        "cmd_response_last_seq": "",
        "cmd_response_last_cmd": "",
        "cmd_response_last_status": "",
        "cmd_response_statuses": "",
        "frame_61080003_count": 0,
        "frame_61080004_count": 0,
        "frame_61080005_count": 0,
        "frame_61080007_count": 0,
        "frame_61080004_types": "",
        "frame_61080005_types": "",
        "frame_61080007_types": "",
        "metadata_0x31_frames": 0,
        "metadata_0x31_lengths": "",
        "metadata_0x31_body_hashes": "",
        "historical_2f_frames": 0,
        "historical_data_rows": 0,
        "historical_archive_rows": 0,
        "historical_archive_metric_usable": "",
        "historical_archive_current_usable": "",
        "historical_2f_candidate_rr_values": 0,
        "historical_2f_first_prefix": "",
        "historical_2f_last_prefix": "",
        "sensor_research_probe_rows": 0,
        "sensor_research_probe_spo2_candidate_frames": "",
        "sensor_research_probe_skin_temp_candidate_frames": "",
        "sensor_research_probe_last_model_generation": "",
        "sensor_research_probe_last_model_evidence": "",
        "model_gate_rows": 0,
        "model_gate_assume_4_class_rows": 0,
        "model_gate_metadata_explicit_rows": 0,
        "model_gate_last_status": "",
        "model_gate_last_model": "",
        "model_gate_last_reason": "",
        "model_gate_last_evidence": "",
        "sleep_motion_hint_count": 0,
        "sleep_motion_hint_kinds": "",
    }
timestamps = {
    "first_whoopdbg": None,
    "first_realtime": None,
    "first_rr": None,
    "last_rr": None,
}
max_rr_log_gap_s = 0.0
flags = {
    "notify_61080005": False,
    "realtime_start": False,
    "cmd_response": False,
    "frame_61080005": False,
    "hrv_ready": False,
    "capture_summary_ready": False,
    "auto_capture_start": False,
    "auto_capture_stop": False,
    "gate_status_start": False,
    "gate_status_complete": False,
    "gate_readiness_complete": False,
    "gate_status_deep_complete": False,
    "healthkit_reference_audit_complete": False,
    "healthkit_export_complete": False,
    "healthkit_export_verify_complete": False,
    "healthkit_export_authorization_pending_complete": False,
    "healthkit_sleep_export_verify_complete": False,
    "healthkit_sleep_export_deferred_complete": False,
    "healthkit_reset_rebuild_complete": False,
    "workout_confirm_complete": False,
    "sleep_confirm_complete": False,
    "post_healthkit_gate_status_complete": False,
    "collection_health_complete": False,
    "rr_reference_package_complete": False,
    "hr_reference_package_complete": False,
    "rr_reference_validation_complete": False,
    "hr_reference_validation_complete": False,
    "reference_inputs_clear_complete": False,
    "workout_validation_complete": False,
    "sleep_validation_complete": False,
    "backup_complete": False,
    "backup_verify_complete": False,
    "notification_schedule_complete": False,
    "notification_delivery_complete": False,
    "radio_low_traffic_complete": False,
    "trend_summary_complete": False,
    "trend_windows_complete": False,
    "strain_validation_complete": False,
    "widget_snapshot_complete": False,
}
capture_file_path = ""
backup_file_path = ""
backup_verified_path = ""
rr_reference_csv_path = ""
rr_reference_manifest_path = ""
hr_reference_csv_path = ""
hr_reference_manifest_path = ""
cmd_response_statuses: list[str] = []
frame_type_counts = {
    "61080004": Counter(),
    "61080005": Counter(),
    "61080007": Counter(),
}
metadata_0x31_lengths: Counter = Counter()
metadata_0x31_body_hashes: Counter = Counter()
sleep_motion_hint_kinds: Counter = Counter()
trend_windows_seen: set[str] = set()
segments: list[dict[str, object]] = []
current_segment: dict[str, object] | None = None


def requested_post_gate_work_complete() -> bool:
    if healthkit_export and not flags["healthkit_export_complete"]:
        return False
    if healthkit_export and not flags["healthkit_export_verify_complete"]:
        if not flags["healthkit_export_authorization_pending_complete"]:
            return False
    if healthkit_export and confirm_best_sleep_candidate and not flags["healthkit_sleep_export_verify_complete"]:
        if not flags["healthkit_sleep_export_deferred_complete"] and not flags["healthkit_export_authorization_pending_complete"]:
            return False
    if healthkit_reset_rebuild and not flags["healthkit_reset_rebuild_complete"]:
        return False
    if healthkit_reset_rebuild and not flags["healthkit_export_verify_complete"]:
        return False
    if healthkit_reference_audit and not flags["healthkit_reference_audit_complete"]:
        return False
    if confirm_best_workout_candidate and not flags["workout_confirm_complete"]:
        return False
    if confirm_best_sleep_candidate and not flags["sleep_confirm_complete"]:
        return False
    if log_gate_status and (healthkit_export or healthkit_reference_audit or healthkit_reset_rebuild) and not flags["post_healthkit_gate_status_complete"]:
        return False
    if export_rr_reference_package and not flags["rr_reference_package_complete"]:
        return False
    if export_hr_reference_package and not flags["hr_reference_package_complete"]:
        return False
    if validate_rr_reference and not flags["rr_reference_validation_complete"]:
        return False
    if validate_hr_reference and not flags["hr_reference_validation_complete"]:
        return False
    if clear_reference_inputs and not flags["reference_inputs_clear_complete"]:
        return False
    if log_collection_health and not flags["collection_health_complete"]:
        return False
    if log_gate_readiness and not flags["gate_readiness_complete"]:
        return False
    if verify_workout_label and not flags["workout_validation_complete"]:
        return False
    if verify_sleep and not flags["sleep_validation_complete"]:
        return False
    if backup_sessions and not flags["backup_complete"]:
        return False
    if verify_backup and not flags["backup_verify_complete"]:
        return False
    if schedule_notifications and not flags["notification_schedule_complete"]:
        return False
    if test_notification and not flags["notification_schedule_complete"]:
        return False
    if test_notification and not flags["notification_delivery_complete"]:
        return False
    if log_trends and not flags["trend_summary_complete"]:
        return False
    if log_trends and not flags["trend_windows_complete"]:
        return False
    if log_strain_validation and not flags["strain_validation_complete"]:
        return False
    if log_widget_snapshot and not flags["widget_snapshot_complete"]:
        return False
    if pull_capture_dir and not capture_file_path:
        return False
    if standard_hr_only and log_gate_status and not flags["radio_low_traffic_complete"]:
        return False
    if (
        history_probe_requested
        and int(rr_summary["historical_2f_frames"]) <= 0
        and int(rr_summary["historical_data_rows"]) <= 0
        and int(rr_summary["historical_archive_rows"]) <= 0
    ):
        return False
    return True


def start_segment(label: str, raw: str, timestamp: datetime | None) -> None:
    global current_segment
    current_segment = {
        "label": label,
        "raw": raw,
        "start": timestamp,
        "frames": 0,
        "rr_frames": 0,
        "zero_frames": 0,
        "rr_values": 0,
        "cmd_status": "",
        "frame_61080003_count": 0,
        "frame_61080004_count": 0,
        "frame_61080005_count": 0,
        "frame_61080007_count": 0,
        "frame_61080004_types": Counter(),
        "frame_61080005_types": Counter(),
        "frame_61080007_types": Counter(),
        "historical_2f_frames": 0,
        "historical_data_rows": 0,
        "historical_archive_rows": 0,
        "historical_2f_candidate_rr_values": 0,
        "historical_2f_first_prefix": "",
        "historical_2f_last_prefix": "",
        "sleep_motion_hint_count": 0,
        "sleep_motion_hint_kinds": Counter(),
    }
    segments.append(current_segment)


def ingest_segment_realtime(rrnum: int) -> None:
    if current_segment is None:
        return
    current_segment["frames"] = int(current_segment["frames"]) + 1
    if rrnum == 0:
        current_segment["zero_frames"] = int(current_segment["zero_frames"]) + 1
    else:
        current_segment["rr_frames"] = int(current_segment["rr_frames"]) + 1
        current_segment["rr_values"] = int(current_segment["rr_values"]) + rrnum


def ingest_frame_catalog(line: str) -> None:
    parsed = frame_payload_from_frame_hex(line)
    if parsed is None:
        return
    channel, payload, _logged_hex_truncated = parsed
    if not channel.startswith("6108000"):
        return
    channel_short = channel[:8]
    key = f"frame_{channel_short}_count"
    if key in rr_summary:
        rr_summary[key] += 1
    if current_segment is not None and key in current_segment:
        current_segment[key] = int(current_segment[key]) + 1
    if channel_short in frame_type_counts and payload:
        payload_type = f"0x{payload[0]:02x}"
        frame_type_counts[channel_short][payload_type] += 1
        if channel_short == "61080005" and payload_type == "0x31":
            metadata_0x31_lengths[str(len(payload))] += 1
            metadata_0x31_body_hashes[hashlib.sha256(payload).hexdigest()[:16]] += 1
        segment_counter = (
            current_segment.get(f"frame_{channel_short}_types")
            if current_segment is not None
            else None
        )
        if isinstance(segment_counter, Counter):
            segment_counter[payload_type] += 1
    # Historical data is a packet type, not an event-channel guarantee. whoof's
    # protocol notes place 0x2f on 61080005 (data), so count it on any WHOOP
    # packetized characteristic we catalog.
    if payload and payload[0] == 0x2F:
        candidates = historical_rr_candidate_count(payload)
        rr_summary["historical_2f_frames"] += 1
        rr_summary["historical_2f_candidate_rr_values"] += candidates
        prefix = payload[:24].hex()
        if not rr_summary["historical_2f_first_prefix"]:
            rr_summary["historical_2f_first_prefix"] = prefix
        rr_summary["historical_2f_last_prefix"] = prefix
        if current_segment is not None:
            current_segment["historical_2f_frames"] = int(current_segment["historical_2f_frames"]) + 1
            current_segment["historical_2f_candidate_rr_values"] = (
                int(current_segment["historical_2f_candidate_rr_values"]) + candidates
            )
            if not current_segment["historical_2f_first_prefix"]:
                current_segment["historical_2f_first_prefix"] = prefix
            current_segment["historical_2f_last_prefix"] = prefix


def format_counter(counter: Counter) -> str:
    return ",".join(f"{name}:{count}" for name, count in sorted(counter.items()))


def historical_rr_candidate_count(payload: bytes) -> int:
    return sum(
        1
        for index in range(1, len(payload) - 1, 2)
        if 300 <= (payload[index] | (payload[index + 1] << 8)) <= 2000
    )


def parse_cmd_response(line: str) -> None:
    tokens = tokens_after("ATRIADBG cmdResp", line)
    payload_hex = tokens.get("payload", "")
    try:
        payload = bytes.fromhex(payload_hex)
    except ValueError:
        return
    if len(payload) < 3 or payload[0] != 0x24:
        return
    seq = payload[1]
    command = payload[2]
    status = payload[3:].hex() or "-"
    rr_summary["cmd_response_count"] += 1
    rr_summary["cmd_response_last_seq"] = str(seq)
    rr_summary["cmd_response_last_cmd"] = f"0x{command:02x}"
    rr_summary["cmd_response_last_status"] = status
    cmd_response_statuses.append(f"seq={seq}:cmd=0x{command:02x}:status={status}")
    rr_summary["cmd_response_statuses"] = ";".join(cmd_response_statuses[-12:])
    if current_segment is not None:
        current_segment["cmd_status"] = f"seq={seq}:cmd=0x{command:02x}:status={status}"


def ingest_sleep_motion_hint(line: str) -> None:
    tokens = tokens_after("ATRIADBG sleep_motion_hint", line)
    kind = tokens.get("kind", "unknown") or "unknown"
    rr_summary["sleep_motion_hint_count"] += 1
    sleep_motion_hint_kinds[kind] += 1
    rr_summary["sleep_motion_hint_kinds"] = format_counter(sleep_motion_hint_kinds)
    if current_segment is not None:
        current_segment["sleep_motion_hint_count"] = int(current_segment["sleep_motion_hint_count"]) + 1
        segment_kinds = current_segment.get("sleep_motion_hint_kinds")
        if isinstance(segment_kinds, Counter):
            segment_kinds[kind] += 1


def ingest_historical_data_row(line: str) -> None:
    tokens = tokens_after("ATRIADBG historicalData", line)
    rr_summary["historical_data_rows"] += 1
    payload_hex = tokens.get("payload", "")
    if payload_hex and not rr_summary["historical_2f_first_prefix"]:
        rr_summary["historical_2f_first_prefix"] = payload_hex[:48]
    if payload_hex:
        rr_summary["historical_2f_last_prefix"] = payload_hex[:48]
    try:
        rr_count = int(tokens.get("strap4_v24_rrnum18", "0"))
    except ValueError:
        rr_count = 0
    rr_summary["historical_2f_candidate_rr_values"] += rr_count
    if current_segment is not None:
        current_segment["historical_data_rows"] = int(current_segment["historical_data_rows"]) + 1
        current_segment["historical_2f_candidate_rr_values"] = (
            int(current_segment["historical_2f_candidate_rr_values"]) + rr_count
        )
        if payload_hex and not current_segment["historical_2f_first_prefix"]:
            current_segment["historical_2f_first_prefix"] = payload_hex[:48]
        if payload_hex:
            current_segment["historical_2f_last_prefix"] = payload_hex[:48]


def ingest_historical_archive_row(line: str) -> None:
    tokens = tokens_after("ATRIADBG historicalArchive", line)
    try:
        rows = int(tokens.get("rows", "0"))
    except ValueError:
        rows = 0
    rr_summary["historical_archive_rows"] = max(int(rr_summary["historical_archive_rows"]), rows)
    rr_summary["historical_archive_metric_usable"] = tokens.get(
        "metric_usable",
        rr_summary["historical_archive_metric_usable"],
    )
    rr_summary["historical_archive_current_usable"] = tokens.get(
        "current_session_usable",
        rr_summary["historical_archive_current_usable"],
    )
    if current_segment is not None:
        current_segment["historical_archive_rows"] = max(
            int(current_segment["historical_archive_rows"]),
            rows,
        )


def ingest_whoopdbg(line: str) -> None:
    global max_rr_log_gap_s, capture_file_path, backup_file_path, backup_verified_path
    global rr_reference_csv_path, rr_reference_manifest_path, hr_reference_csv_path, hr_reference_manifest_path
    lines.append(line)
    timestamp = parse_log_timestamp(line)
    if timestamp is not None and timestamps["first_whoopdbg"] is None:
        timestamps["first_whoopdbg"] = timestamp
    if "notifyState ch=61080005" in line and "notifying=1" in line:
        flags["notify_61080005"] = True
    if "ATRIADBG gate_status_start" in line:
        flags["gate_status_start"] = True
    if "ATRIADBG execution_priority" in line:
        flags["gate_status_complete"] = True
    if "ATRIADBG gate_readiness_ui source=launch_arg" in line:
        flags["gate_readiness_complete"] = True
    if "ATRIADBG gate_status_deep" in line:
        flags["gate_status_deep_complete"] = True
    if "ATRIADBG healthkit_reference_audit status=" in line:
        flags["healthkit_reference_audit_complete"] = True
    if "ATRIADBG healthkit_export status=" in line:
        flags["healthkit_export_complete"] = True
    if "ATRIADBG healthkit_export_verify status=" in line:
        flags["healthkit_export_verify_complete"] = True
    if "ATRIADBG healthkit_export status=authorization_pending" in line:
        flags["healthkit_export_authorization_pending_complete"] = True
    if "ATRIADBG healthkit_sleep_export_verify status=" in line:
        flags["healthkit_sleep_export_verify_complete"] = True
    if "ATRIADBG healthkit_sleep_export status=authorization_required" in line:
        flags["healthkit_sleep_export_deferred_complete"] = True
    if "ATRIADBG healthkit_sleep_export status=permission_required" in line:
        flags["healthkit_sleep_export_deferred_complete"] = True
    if "ATRIADBG healthkit_reset_rebuild status=complete" in line:
        flags["healthkit_reset_rebuild_complete"] = True
    if "ATRIADBG workout_confirm status=" in line:
        flags["workout_confirm_complete"] = True
    if "ATRIADBG sleep_confirm status=" in line:
        flags["sleep_confirm_complete"] = True
    if "ATRIADBG launch_exports_post_healthkit_gate_status status=completed" in line:
        flags["post_healthkit_gate_status_complete"] = True
    if (
        "ATRIADBG rr_reference_validation status=" in line
        and " status=started " not in line
    ):
        flags["rr_reference_validation_complete"] = True
    if (
        "ATRIADBG hr_reference_validation status=" in line
        and " status=started " not in line
    ):
        flags["hr_reference_validation_complete"] = True
    if "ATRIADBG reference_inputs_clear status=" in line:
        flags["reference_inputs_clear_complete"] = True
    if "ATRIADBG collection_health " in line:
        flags["collection_health_complete"] = True
    if "ATRIADBG workout_validation status=" in line:
        flags["workout_validation_complete"] = True
    if "ATRIADBG sleep_validation status=" in line:
        flags["sleep_validation_complete"] = True
    if "ATRIADBG session_backup " in line:
        flags["backup_complete"] = True
    if "ATRIADBG session_backup_verify " in line:
        flags["backup_verify_complete"] = True
    if "ATRIADBG notification_schedule status=" in line:
        flags["notification_schedule_complete"] = True
    if "ATRIADBG notification_delivered kind=diagnostic" in line:
        flags["notification_delivery_complete"] = True
    if "ATRIADBG trend_summary " in line:
        flags["trend_summary_complete"] = True
    if "ATRIADBG trend_window " in line:
        tokens = tokens_after("ATRIADBG trend_window", line)
        days = tokens.get("days", "")
        if days:
            trend_windows_seen.add(days)
        if {"7", "30", "90"}.issubset(trend_windows_seen):
            flags["trend_windows_complete"] = True
    if "ATRIADBG strain_validation " in line:
        flags["strain_validation_complete"] = True
    if "ATRIADBG widget_snapshot status=" in line:
        flags["widget_snapshot_complete"] = True
    if "ATRIADBG gate_status gate=" in line and "radio_standard_hr_only=1" in line:
        radio_fields = tokens_after("evidence=", line.replace(";", " "))
        skipped = int(radio_fields.get("_radio_custom_notify_skipped", radio_fields.get("radio_custom_notify_skipped", "0")) or "0")
        tx_skipped = int(radio_fields.get("_radio_tx_skipped", radio_fields.get("radio_tx_skipped", "0")) or "0")
        realtime_skipped = int(radio_fields.get("_radio_realtime_start_skipped", radio_fields.get("radio_realtime_start_skipped", "0")) or "0")
        enabled = int(radio_fields.get("_radio_custom_notify_enabled", radio_fields.get("radio_custom_notify_enabled", "0")) or "0")
        if (skipped > 0 or tx_skipped > 0 or realtime_skipped > 0) and enabled == 0:
            flags["radio_low_traffic_complete"] = True
    if "ATRIADBG radio_low_traffic status=ready" in line and "mode=standard_hr_only" in line:
        flags["radio_low_traffic_complete"] = True
    if "ATRIADBG model_gate " in line:
        tokens = tokens_after("ATRIADBG model_gate", line)
        status = tokens.get("status", "")
        rr_summary["model_gate_rows"] += 1
        rr_summary["model_gate_last_status"] = status
        rr_summary["model_gate_last_model"] = tokens.get("model", "")
        rr_summary["model_gate_last_reason"] = tokens.get("reason", "")
        rr_summary["model_gate_last_evidence"] = tokens.get("evidence", "")
        if status == "assume_4_class":
            rr_summary["model_gate_assume_4_class_rows"] += 1
        if status == "metadata_explicit":
            rr_summary["model_gate_metadata_explicit_rows"] += 1
    if "ATRIADBG sensor_research_probe " in line:
        tokens = tokens_after("ATRIADBG sensor_research_probe", line)
        rr_summary["sensor_research_probe_rows"] += 1
        rr_summary["sensor_research_probe_spo2_candidate_frames"] = tokens.get("spo2_candidate_frames", "")
        rr_summary["sensor_research_probe_skin_temp_candidate_frames"] = tokens.get("skin_temp_candidate_frames", "")
        rr_summary["sensor_research_probe_last_model_generation"] = tokens.get("model_generation", "")
        rr_summary["sensor_research_probe_last_model_evidence"] = tokens.get("model_evidence", "")
    if "ATRIADBG send mode=" in line and "cmd=03" in line:
        flags["realtime_start"] = True
    if "ATRIADBG send mode=" in line and current_segment is None:
        tokens = tokens_after("ATRIADBG send", line)
        cmd = tokens.get("cmd", "")
        frame = tokens.get("frame", "")
        start_segment("initial", cmd, timestamp)
        current_segment["frame"] = frame
    if "ATRIADBG probeSweep send" in line:
        tokens = tokens_after("ATRIADBG probeSweep send", line)
        index = tokens.get("index", str(len(segments)))
        raw = tokens.get("raw", "")
        start_segment(f"sweep_{index}", raw, timestamp)
    if "ATRIADBG probeCommand send" in line:
        tokens = tokens_after("ATRIADBG probeCommand send", line)
        cmd = tokens.get("cmd", "")
        data = tokens.get("data", "")
        start_segment("probe", f"{cmd}{data}", timestamp)
    if "ATRIADBG cmdResp" in line:
        flags["cmd_response"] = True
        parse_cmd_response(line)
    if "ATRIADBG sleep_motion_hint" in line:
        ingest_sleep_motion_hint(line)
    if "ATRIADBG historicalData" in line:
        ingest_historical_data_row(line)
    if "ATRIADBG historicalArchive" in line:
        ingest_historical_archive_row(line)
    if "ATRIADBG standardHR" in line:
        tokens = tokens_after("ATRIADBG standardHR", line)
        rr_summary["standard_2a37_frames"] += 1
        rr_summary["last_standard_2a37_payload"] = tokens.get("payload", "")
        rr_summary["last_standard_2a37_hr"] = tokens.get("hr", "")
        rr_summary["last_standard_2a37_rrnum"] = tokens.get("rrnum", "")
        rr_summary["last_standard_2a37_rr_ms"] = tokens.get("rr_ms", "")
        try:
            rrnum = int(tokens.get("rrnum", "0"))
        except ValueError:
            rrnum = 0
        if rrnum > 0:
            rr_summary["standard_2a37_rr_frames"] += 1
            rr_summary["standard_2a37_rr_values"] += rrnum
    if "ATRIADBG frame ch=6108000" in line:
        ingest_frame_catalog(line)
    if "ATRIADBG realtimeRestart" in line:
        rr_summary["realtime_restarts"] += 1
    if "ATRIADBG realtimeReassert" in line:
        rr_summary["realtime_reasserts"] += 1
    if "ATRIADBG frame ch=61080005" in line:
        flags["frame_61080005"] = True
        if timestamp is not None and timestamps["first_realtime"] is None:
            timestamps["first_realtime"] = timestamp
        parsed_realtime = realtime_payload_from_frame_hex(line)
        if parsed_realtime is None:
            rr_summary["realtime_malformed_frames"] += 1
        else:
            payload, _logged_hex_truncated = parsed_realtime
            rr_summary["realtime_frames"] += 1
            hr = payload[8]
            rrnum = payload[9]
            rr_summary["last_realtime_hr"] = str(hr)
            rr_summary["last_realtime_rrnum"] = str(rrnum)
            ingest_segment_realtime(rrnum)
            expected_rr_bytes = rrnum * 2
            available_rr_bytes = max(0, len(payload) - 10)
            rr_bytes = payload[10:10 + expected_rr_bytes]
            payload_tail = payload[10 + expected_rr_bytes:]
            rr_summary["last_realtime_rr_bytes"] = rr_bytes.hex()
            rr_summary["last_realtime_payload_tail"] = payload_tail.hex()
            if rrnum == 0:
                rr_summary["realtime_rr_zero_frames"] += 1
                if any(byte != 0 for byte in rr_bytes):
                    rr_summary["realtime_zero_rr_tail_nonzero_frames"] += 1
                valid_tail_candidates = [
                    rr_bytes[index] | (rr_bytes[index + 1] << 8)
                    for index in range(0, len(rr_bytes) - 1, 2)
                    if 300 <= (rr_bytes[index] | (rr_bytes[index + 1] << 8)) <= 2000
                ]
                if valid_tail_candidates:
                    rr_summary["realtime_zero_rr_tail_valid_candidate_frames"] += 1
            else:
                rr_summary["realtime_rr_frames"] += 1
                if available_rr_bytes < expected_rr_bytes:
                    rr_summary["realtime_truncated_rr_frames"] += 1
    if "ATRIADBG hrv" in line:
        tokens = tokens_after("ATRIADBG hrv", line)
        gap = tokens.get("max_rr_gap_s")
        if gap is not None:
            rr_summary["last_hrv_max_rr_gap_s"] = gap
            try:
                current = float(rr_summary["hrv_max_rr_gap_s"])
                rr_summary["hrv_max_rr_gap_s"] = f"{max(current, float(gap)):.1f}"
            except ValueError:
                pass
        if "ready=1" in line:
            flags["hrv_ready"] = True
    if "ATRIADBG rr_quality" in line:
        tokens = tokens_after("ATRIADBG rr_quality", line)
        rr_summary["last_rr_quality_source"] = tokens.get("source", "")
    if "capture_summary" in line and "ready=1" in line:
        flags["capture_summary_ready"] = True
    if "ATRIADBG autoCapture start" in line:
        flags["auto_capture_start"] = True
        rr_summary["auto_capture_starts"] += 1
    if "ATRIADBG autoCapture stop" in line:
        flags["auto_capture_stop"] = True
        rr_summary["auto_capture_stops"] += 1
    if "ATRIADBG capture_abort" in line:
        rr_summary["capture_aborts"] += 1
    if "ATRIADBG capture_quality_reset" in line:
        rr_summary["capture_quality_resets"] += 1
    if "ATRIADBG autoCapture exhausted" in line:
        rr_summary["auto_capture_exhausted"] += 1
    if "ATRIADBG capture_file" in line:
        tokens = tokens_after("ATRIADBG capture_file", line)
        capture_file_path = tokens.get("path", "") or capture_file_path
    if "ATRIADBG rr_reference_package" in line:
        tokens = tokens_after("ATRIADBG rr_reference_package", line)
        rr_reference_csv_path = tokens.get("csv", "") or rr_reference_csv_path
        rr_reference_manifest_path = tokens.get("manifest", "") or rr_reference_manifest_path
        flags["rr_reference_package_complete"] = bool(rr_reference_csv_path and rr_reference_manifest_path)
    if "ATRIADBG hr_reference_package" in line:
        tokens = tokens_after("ATRIADBG hr_reference_package", line)
        hr_reference_csv_path = tokens.get("csv", "") or hr_reference_csv_path
        hr_reference_manifest_path = tokens.get("manifest", "") or hr_reference_manifest_path
        flags["hr_reference_package_complete"] = bool(hr_reference_csv_path and hr_reference_manifest_path)
    if "ATRIADBG session_backup " in line:
        tokens = tokens_after("ATRIADBG session_backup", line)
        backup_file_path = tokens.get("path", "") or backup_file_path
    if "ATRIADBG session_backup_verify " in line:
        tokens = tokens_after("ATRIADBG session_backup_verify", line)
        backup_verified_path = tokens.get("path", "") or backup_verified_path
    if "ATRIADBG rr " in line:
        tokens = tokens_after("ATRIADBG rr", line)
        source = tokens.get("source", "")
        if timestamp is not None:
            if timestamps["first_rr"] is None:
                timestamps["first_rr"] = timestamp
            if timestamps["last_rr"] is not None:
                max_rr_log_gap_s = max(
                    max_rr_log_gap_s,
                    (timestamp - timestamps["last_rr"]).total_seconds(),
                )
                rr_summary["max_rr_log_gap_s"] = f"{max_rr_log_gap_s:.1f}"
            timestamps["last_rr"] = timestamp
        rr_summary["rr_frames"] += 1
        decoded_values = 0
        try:
            decoded_values = int(tokens.get("decoded", "0"))
            rr_summary["rr_values"] += decoded_values
        except ValueError:
            pass
        if source == "0x2A37":
            rr_summary["rr_source_2a37_frames"] += 1
            rr_summary["rr_source_2a37_values"] += decoded_values
        elif source == "0x28":
            rr_summary["rr_source_0x28_frames"] += 1
            rr_summary["rr_source_0x28_values"] += decoded_values
            if tokens.get("used", "1") == "1":
                rr_summary["rr_source_0x28_used_frames"] += 1
                rr_summary["rr_source_0x28_used_values"] += decoded_values
        try:
            rr_summary["rr_hr_mismatch_values"] += int(tokens.get("hr_mismatch", "0"))
        except ValueError:
            pass
        if tokens.get("truncated") == "1":
            rr_summary["rr_truncated_frames"] += 1
        rr_summary["last_rr_values"] = tokens.get("values", "")
        rr_summary["last_rr_implied_bpm"] = tokens.get("implied_bpm", "")
    baseline = timestamps["first_whoopdbg"]
    rr_summary["first_realtime_elapsed_s"] = elapsed_seconds(baseline, timestamps["first_realtime"])
    rr_summary["first_rr_elapsed_s"] = elapsed_seconds(baseline, timestamps["first_rr"])
    rr_summary["rr_start_delay_s"] = elapsed_seconds(timestamps["first_realtime"], timestamps["first_rr"])
    rr_summary["last_rr_elapsed_s"] = elapsed_seconds(baseline, timestamps["last_rr"])

if pull_only:
    emit("HARNESS_PULL_ONLY status=enabled action=skip_build_install_launch")
elif replay_log:
    skipping_existing_summary = False
    with open(replay_log, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip()
            if line == "ATRIADBG_SUMMARY_START":
                skipping_existing_summary = True
                continue
            if skipping_existing_summary:
                if line == "ATRIADBG_SUMMARY_END":
                    skipping_existing_summary = False
                continue
            emit(line)
            if "ATRIADBG" in line:
                ingest_whoopdbg(line)
else:
    devicectl_log_path = f"{log_path}.devicectl.log" if log_path else ""
    cmd = [
        "xcrun", "devicectl",
    ]
    if devicectl_log_path:
        cmd.extend(["--log-output", devicectl_log_path])
    cmd.extend([
        "device", "process", "launch",
        "--device", device_id,
        "--terminate-existing",
        "--console",
        bundle_id,
    ])
    if auto_capture:
        cmd.extend(["--atria-auto-capture", "--atria-capture-label", capture_label])
    elif morning_hrv_check or auto_save_session_after or auto_save_session_every or checkpoint_session_every or log_live_workout_every or auto_save_workout_when_ready or verify_workout_label:
        cmd.extend(["--atria-capture-label", capture_label])
    if auto_capture or morning_hrv_check:
        if auto_capture_delay:
            cmd.extend(["--atria-auto-capture-delay", auto_capture_delay])
        if auto_capture_when_rr:
            cmd.extend(["--atria-auto-capture-when-rr", auto_capture_when_rr])
        if auto_capture_rr_window:
            cmd.extend(["--atria-auto-capture-rr-window", auto_capture_rr_window])
        if auto_capture_rr_min_frames:
            cmd.extend(["--atria-auto-capture-rr-min-frames", auto_capture_rr_min_frames])
        if auto_capture_max_rr_gap:
            cmd.extend(["--atria-auto-capture-max-rr-gap", auto_capture_max_rr_gap])
        if auto_capture_rr_timeout:
            cmd.extend(["--atria-auto-capture-rr-timeout", auto_capture_rr_timeout])
        if auto_capture_max_attempts:
            cmd.extend(["--atria-auto-capture-max-attempts", auto_capture_max_attempts])
        if stop_when_ready:
            cmd.append("--atria-stop-when-ready")
        if auto_stop_after:
            cmd.extend(["--atria-auto-stop-after", auto_stop_after])
        if strict_live_rr_capture:
            cmd.append("--atria-strict-live-rr-capture")
    if complete_onboarding:
        cmd.append("--atria-complete-onboarding")
    if log_baseline:
        cmd.append("--atria-log-baseline")
    if log_collection_health:
        cmd.append("--atria-log-collection-health")
        if log_collection_health_after:
            cmd.extend(["--atria-log-collection-health-after", log_collection_health_after])
    if log_gate_status:
        cmd.append("--atria-log-gate-status")
        if log_gate_status_after:
            cmd.extend(["--atria-log-gate-status-after", log_gate_status_after])
    if log_gate_readiness:
        cmd.append("--atria-log-gate-readiness")
    if log_gate_status_deep:
        cmd.append("--atria-log-gate-status-deep")
    if log_activity_detections:
        cmd.append("--atria-log-activity-detections")
    if log_daily_rollups:
        cmd.append("--atria-log-daily-rollups")
    if log_trends:
        cmd.append("--atria-log-trends")
    if log_widget_snapshot:
        cmd.append("--atria-log-widget-snapshot")
    if log_workout_preflight:
        cmd.append("--atria-log-workout-preflight")
    if log_strain_validation:
        cmd.append("--atria-log-strain-validation")
    if log_hr_consistency:
        cmd.append("--atria-log-hr-consistency")
    if log_hr_artifact_policy:
        cmd.append("--atria-log-hr-artifact-policy")
    if log_hr_continuity_watchdog_state:
        cmd.append("--atria-log-hr-continuity-watchdog-state")
    if not quiet_ble_logs:
        cmd.append("--atria-log-ble-frames")
    if full_protocol_mode:
        cmd.append("--atria-full-protocol-mode")
    if standard_hr_only:
        cmd.append("--atria-standard-hr-only")
    if long_wear_mode:
        cmd.append("--atria-long-wear-mode")
    if reset_capture_defaults:
        cmd.append("--atria-reset-capture-defaults")
    if reset_link_diagnostics:
        cmd.append("--atria-reset-link-diagnostics")
    if reset_sample_diagnostics:
        cmd.append("--atria-reset-sample-diagnostics")
    if reset_protocol_diagnostics:
        cmd.append("--atria-reset-protocol-diagnostics")
    if active_motion_imu_check:
        cmd.append("--atria-active-motion-imu-check")
    if flush_active_journal_after:
        cmd.extend(["--atria-flush-active-journal-after", flush_active_journal_after])
    if manual_checkpoint_after:
        cmd.extend(["--atria-manual-checkpoint-after", manual_checkpoint_after])
    if force_no_data_watchdog_after:
        cmd.extend(["--atria-force-no-data-watchdog-after", force_no_data_watchdog_after])
    if force_hr_continuity_watchdog_after:
        cmd.extend(["--atria-force-hr-continuity-watchdog-after", force_hr_continuity_watchdog_after])
    if force_rr_presence_watchdog_after:
        cmd.extend(["--atria-force-rr-presence-watchdog-after", force_rr_presence_watchdog_after])
    if force_missing_2a37_after:
        cmd.extend(["--atria-force-missing-2a37-after", force_missing_2a37_after])
    if force_accepted_hr_watchdog_after:
        cmd.extend(["--atria-force-accepted-hr-watchdog-after", force_accepted_hr_watchdog_after])
    if backup_sessions:
        cmd.append("--atria-backup-sessions")
    if verify_backup:
        cmd.append("--atria-verify-backup")
    if restore_backup:
        cmd.append("--atria-restore-backup")
    if healthkit_export:
        cmd.append("--atria-healthkit-export")
    if healthkit_reference_audit:
        cmd.append("--atria-healthkit-reference-audit")
    if healthkit_reset_rebuild:
        cmd.append("--atria-healthkit-reset-rebuild-atria-hr")
    if confirm_best_workout_candidate:
        cmd.append("--atria-confirm-best-workout-candidate")
    if confirm_best_sleep_candidate:
        cmd.append("--atria-confirm-best-sleep-candidate")
    if export_rr_reference_package:
        cmd.append("--atria-export-rr-reference-package")
    if export_hr_reference_package:
        cmd.append("--atria-export-hr-reference-package")
    if validate_rr_reference:
        cmd.append("--atria-validate-rr-reference")
    if validate_hr_reference:
        cmd.append("--atria-validate-hr-reference")
    if clear_reference_inputs:
        cmd.append("--atria-clear-reference-inputs")
    if morning_hrv_check:
        cmd.append("--atria-morning-hrv-check")
    if morning_hrv_force:
        cmd.append("--atria-morning-hrv-force")
    if auto_save_session_after:
        cmd.extend(["--atria-auto-save-session-after", auto_save_session_after])
    if auto_save_session_every:
        cmd.extend(["--atria-auto-save-session-every", auto_save_session_every])
    if checkpoint_session_every:
        cmd.extend(["--atria-checkpoint-session-every", checkpoint_session_every])
    if log_live_workout_every:
        cmd.extend(["--atria-log-live-workout-every", log_live_workout_every])
    if auto_save_workout_when_ready:
        cmd.extend(["--atria-auto-save-workout-when-ready", auto_save_workout_when_ready])
    if verify_workout_label:
        cmd.extend(["--atria-verify-workout-label", verify_workout_label])
        if verify_workout_after:
            cmd.extend(["--atria-verify-workout-after", verify_workout_after])
    if verify_sleep:
        cmd.append("--atria-verify-sleep")
        if verify_sleep_label:
            cmd.extend(["--atria-verify-sleep-label", verify_sleep_label])
        if verify_sleep_after:
            cmd.extend(["--atria-verify-sleep-after", verify_sleep_after])
    if schedule_notifications:
        cmd.append("--atria-schedule-notifications")
    if test_notification:
        cmd.append("--atria-test-notification")
    if schedule_notifications or test_notification:
        if notification_delay:
            cmd.extend(["--atria-notification-delay", notification_delay])
    if realtime_start_retries:
        cmd.extend(["--atria-realtime-start-retries", realtime_start_retries])
    if realtime_restart_zero_rr_seconds:
        cmd.extend(["--atria-realtime-restart-zero-rr-seconds", realtime_restart_zero_rr_seconds])
    if realtime_reassert_zero_rr_seconds:
        cmd.extend(["--atria-realtime-reassert-zero-rr-seconds", realtime_reassert_zero_rr_seconds])
    if disable_history_ack:
        cmd.append("--atria-disable-history-ack")
    if history_ack_mode:
        cmd.extend(["--atria-history-ack-mode", history_ack_mode])
    if history_recent_sweep:
        cmd.append("--atria-history-recent-sweep")
        if history_recent_offsets:
            cmd.extend(["--atria-history-recent-offsets", history_recent_offsets])
    if history_selector_sweep:
        cmd.append("--atria-history-selector-sweep")
    if history_selector_mode:
        cmd.extend(["--atria-history-selector-mode", history_selector_mode])
    if history_selector_range_index:
        cmd.extend(["--atria-history-selector-range-index", history_selector_range_index])
    if history_range_sweep:
        cmd.append("--atria-history-range-sweep")
        if history_range_payloads:
            cmd.extend(["--atria-history-range-payloads", history_range_payloads])
    if history_init_sweep:
        cmd.extend(["--atria-history-init-sweep", history_init_sweep])
    if history_skip_range:
        cmd.append("--atria-history-skip-range")
    if history_clock_handshake:
        cmd.append("--atria-history-clock-handshake")
    if history_only_probe:
        cmd.append("--atria-history-only-probe")
    if probe_command:
        cmd.extend(["--atria-probe-command", probe_command])
        if probe_command_delay:
            cmd.extend(["--atria-probe-command-delay", probe_command_delay])
    if probe_command_mode:
        cmd.extend(["--atria-probe-command-mode", probe_command_mode])
    if probe_sweep:
        cmd.extend(["--atria-probe-sweep", probe_sweep])
        if probe_sweep_interval:
            cmd.extend(["--atria-probe-sweep-interval", probe_sweep_interval])
    emit("HARNESS_LAUNCH_ARGS=" + " ".join(shlex.quote(part) for part in cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    stopped_for_deadline = False
    app_exit_code = None
    launch_output_lines = []
    try:
        while time.time() < deadline:
            line = ""
            if proc.stdout:
                readable, _, _ = select.select([proc.stdout], [], [], 0.2)
                if readable:
                    line = proc.stdout.readline()
            if line:
                line = line.rstrip()
                launch_output_lines.append(line)
                emit(line)
                if not launch_seen and "Launched application with" in line:
                    launch_seen = True
                    deadline_seconds = seconds
                    if log_gate_status or log_gate_status_deep:
                        deadline_seconds = max(deadline_seconds, 180)
                    deadline = time.time() + deadline_seconds
                if "ATRIADBG" in line:
                    if "ATRIADBG gate_status_start" in line and (log_gate_status or log_gate_status_deep):
                        gate_deadline_seconds = 240 if log_gate_status_deep else 120
                        deadline = max(deadline, time.time() + gate_deadline_seconds)
                        emit(f"HARNESS_GATE_STATUS_DEADLINE_RESET seconds={gate_deadline_seconds}")
                    ingest_whoopdbg(line)
                    if "ATRIADBG frame ch=61080005" in line and until_realtime:
                        break
                    if flags["hrv_ready"] or flags["capture_summary_ready"]:
                        if until_ready:
                            break
                    if log_gate_readiness and not (log_gate_status or log_gate_status_deep) and flags["gate_readiness_complete"]:
                        break
                    if log_gate_status_deep and flags["gate_status_deep_complete"] and not post_gate_side_effects:
                        break
                    if log_gate_status and not log_gate_status_deep and flags["gate_status_complete"] and not post_gate_side_effects:
                        break
                    if log_gate_status_deep and flags["gate_status_deep_complete"] and post_gate_side_effects and requested_post_gate_work_complete():
                        break
                    if log_gate_status and not log_gate_status_deep and flags["gate_status_complete"] and post_gate_side_effects and requested_post_gate_work_complete():
                        break
                    if log_trends and requested_post_gate_work_complete():
                        break
                    if log_strain_validation and requested_post_gate_work_complete():
                        break
                    if log_widget_snapshot and requested_post_gate_work_complete():
                        break
                    if (verify_workout_label or verify_sleep) and requested_post_gate_work_complete():
                        break
                    if post_gate_side_effects and not (log_gate_status or log_gate_status_deep) and requested_post_gate_work_complete():
                        break
            elif proc.poll() is not None:
                app_exit_code = proc.returncode
                break
            else:
                time.sleep(0.1)
        else:
            stopped_for_deadline = True
    finally:
        if stopped_for_deadline and proc.poll() is None:
            emit(f"HARNESS_CAPTURE_TIMEOUT seconds={seconds} launch_seen={int(launch_seen)} action=stop_devicectl_console")
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGINT)
            except ProcessLookupError:
                pass
        try:
            rest = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            rest = proc.communicate()[0]

    if rest:
        for line in rest.splitlines():
            launch_output_lines.append(line)
            emit(line)
            if "ATRIADBG" in line:
                ingest_whoopdbg(line)
    if app_exit_code is None and proc.returncode is not None and not stopped_for_deadline:
        app_exit_code = proc.returncode
    if app_exit_code is not None:
        emit(f"HARNESS_APP_EXIT code={app_exit_code} before_deadline={int(not stopped_for_deadline)}")
    if devicectl_log_path and os.path.exists(devicectl_log_path):
        with open(devicectl_log_path, encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                line = raw.rstrip()
                if "ATRIADBG" not in line:
                    continue
                emit(line)
                ingest_whoopdbg(line)

emit("ATRIADBG_SUMMARY_START")
if rr_summary["realtime_frames"]:
    fraction = rr_summary["realtime_rr_frames"] / rr_summary["realtime_frames"]
    rr_summary["realtime_rr_fraction"] = f"{fraction:.3f}"
    rr_summary["realtime_rr_percent"] = f"{fraction * 100:.1f}"
rr_summary["frame_61080004_types"] = format_counter(frame_type_counts["61080004"])
rr_summary["frame_61080005_types"] = format_counter(frame_type_counts["61080005"])
rr_summary["frame_61080007_types"] = format_counter(frame_type_counts["61080007"])
rr_summary["metadata_0x31_frames"] = frame_type_counts["61080005"].get("0x31", 0)
rr_summary["metadata_0x31_lengths"] = format_counter(metadata_0x31_lengths)
rr_summary["metadata_0x31_body_hashes"] = format_counter(metadata_0x31_body_hashes)
for name, value in flags.items():
    emit(f"{name}={str(value)}")
for name, value in rr_summary.items():
    emit(f"{name}={value}")
for index, segment in enumerate(segments):
    frames = int(segment["frames"])
    rr_frames = int(segment["rr_frames"])
    fraction = (rr_frames / frames) if frames else 0.0
    emit(f"segment_{index}_label={segment['label']}")
    emit(f"segment_{index}_raw={segment['raw']}")
    emit(f"segment_{index}_frames={frames}")
    emit(f"segment_{index}_rr_frames={rr_frames}")
    emit(f"segment_{index}_zero_frames={segment['zero_frames']}")
    emit(f"segment_{index}_rr_values={segment['rr_values']}")
    emit(f"segment_{index}_rr_fraction={fraction:.3f}")
    emit(f"segment_{index}_rr_percent={fraction * 100:.1f}")
    emit(f"segment_{index}_cmd_status={segment['cmd_status']}")
    emit(f"segment_{index}_frame_61080003_count={segment['frame_61080003_count']}")
    emit(f"segment_{index}_frame_61080004_count={segment['frame_61080004_count']}")
    emit(f"segment_{index}_frame_61080005_count={segment['frame_61080005_count']}")
    emit(f"segment_{index}_frame_61080007_count={segment['frame_61080007_count']}")
    emit(f"segment_{index}_frame_61080004_types={format_counter(segment['frame_61080004_types'])}")
    emit(f"segment_{index}_frame_61080005_types={format_counter(segment['frame_61080005_types'])}")
    emit(f"segment_{index}_frame_61080007_types={format_counter(segment['frame_61080007_types'])}")
    emit(f"segment_{index}_historical_2f_frames={segment['historical_2f_frames']}")
    emit(f"segment_{index}_historical_data_rows={segment['historical_data_rows']}")
    emit(f"segment_{index}_historical_archive_rows={segment['historical_archive_rows']}")
    emit(f"segment_{index}_historical_2f_candidate_rr_values={segment['historical_2f_candidate_rr_values']}")
    emit(f"segment_{index}_historical_2f_first_prefix={segment['historical_2f_first_prefix']}")
    emit(f"segment_{index}_historical_2f_last_prefix={segment['historical_2f_last_prefix']}")
    emit(f"segment_{index}_sleep_motion_hint_count={segment['sleep_motion_hint_count']}")
    emit(f"segment_{index}_sleep_motion_hint_kinds={format_counter(segment['sleep_motion_hint_kinds'])}")
emit(f"ATRIADBG_LINES={len(lines)}")
if log_path:
    emit(f"ATRIADBG_LOG={log_path}")
if capture_file_path:
    emit(f"ATRIADBG_CAPTURE_FILE={capture_file_path}")
if backup_file_path:
    emit(f"ATRIADBG_BACKUP_FILE={backup_file_path}")
elif backup_verified_path:
    emit(f"ATRIADBG_BACKUP_FILE={backup_verified_path}")
if rr_reference_csv_path:
    emit(f"ATRIADBG_RR_REFERENCE_CSV_FILE={rr_reference_csv_path}")
if rr_reference_manifest_path:
    emit(f"ATRIADBG_RR_REFERENCE_MANIFEST_FILE={rr_reference_manifest_path}")
if hr_reference_csv_path:
    emit(f"ATRIADBG_HR_REFERENCE_CSV_FILE={hr_reference_csv_path}")
if hr_reference_manifest_path:
    emit(f"ATRIADBG_HR_REFERENCE_MANIFEST_FILE={hr_reference_manifest_path}")
emit("ATRIADBG_SUMMARY_END")

if not replay_log and not pull_only:
    if not launch_seen:
        launch_output = "\n".join(launch_output_lines)
        if (
            "invalid code signature" in launch_output
            or "profile has not been explicitly trusted" in launch_output
            or "BSErrorCodeDescription = RequestDenied" in launch_output
        ):
            emit("HARNESS_ERROR=developer_profile_not_trusted")
            emit("HARNESS_NEXT_ACTION=trust_developer_profile_in_ios_settings_then_retry")
            sys.exit(2)
        emit("HARNESS_ERROR=app_launch_not_confirmed")
        sys.exit(2)
    if not lines:
        emit("HARNESS_ERROR=no_whoopdbg_lines_after_launch")
        sys.exit(3)

if not replay_log and pull_capture_dir and capture_file_path:
    destination = Path(pull_capture_dir)
    destination.mkdir(parents=True, exist_ok=True)
    destination_file = destination / Path(capture_file_path).name
    copy_cmd = [
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", device_id,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundle_id,
        "--source", capture_file_path,
        "--destination", str(destination_file),
    ]
    result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for line in result.stdout.splitlines():
        emit(line)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    emit(f"ATRIADBG_CAPTURE_PULL_FILE={destination_file}")

if not replay_log and pull_backups_dir:
    backup_source_path = backup_file_path or backup_verified_path
    if not backup_source_path:
        emit("ATRIADBG_BACKUP_PULL_SKIPPED=missing_session_backup_path")
    else:
        destination = Path(pull_backups_dir)
        destination.mkdir(parents=True, exist_ok=True)
        destination_file = destination / Path(backup_source_path).name
        copy_cmd = [
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", device_id,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundle_id,
            "--source", backup_source_path,
            "--destination", str(destination_file),
        ]
        result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in result.stdout.splitlines():
            emit(line)
        if result.returncode != 0:
            raise SystemExit(result.returncode)
        emit(f"ATRIADBG_BACKUP_PULL_FILE={destination_file}")

if not replay_log and pull_sessions_dir:
    destination = Path(pull_sessions_dir)
    destination.mkdir(parents=True, exist_ok=True)
    destination_file = destination / "sessions.json"
    copy_cmd = [
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", device_id,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundle_id,
        "--source", "Documents/sessions.json",
        "--destination", str(destination_file),
    ]
    result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for line in result.stdout.splitlines():
        emit(line)
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    emit(f"ATRIADBG_SESSIONS_PULL_FILE={destination_file}")
    summarize_sessions_file(destination_file)
    active_destination_file = destination / "atria-active-session.json"
    last_active_result = None
    for source_path in [
        "Documents/atria-active-session.json",
        "Documents/whoop-active-session.json",
    ]:
        copy_cmd = [
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", device_id,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundle_id,
            "--source", source_path,
            "--destination", str(active_destination_file),
        ]
        result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        last_active_result = result
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                emit(line)
            emit(f"ATRIADBG_ACTIVE_JOURNAL_PULL_FILE={active_destination_file}")
            emit(f"ATRIADBG_ACTIVE_JOURNAL_PULL_SOURCE={source_path}")
            break
    else:
        if last_active_result is not None:
            for line in last_active_result.stdout.splitlines():
                emit(line)
        emit("ATRIADBG_ACTIVE_JOURNAL_PULL_STATUS=missing")
    active_segments_destination = destination / "atria-active-session.segments"
    copy_cmd = [
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", device_id,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundle_id,
        "--source", "Documents/atria-active-session.segments",
        "--destination", str(active_segments_destination),
    ]
    result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            emit(line)
        emit(f"ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_PULL_FILE={active_segments_destination}")
        summarize_active_journal_segments(active_segments_destination)
    else:
        emit("ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_PULL_STATUS=missing")
    gate_status_destination_file = destination / "atria-gate-status.txt"
    copy_cmd = [
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", device_id,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundle_id,
        "--source", "Documents/atria-gate-status.txt",
        "--destination", str(gate_status_destination_file),
    ]
    result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            emit(line)
        emit(f"ATRIADBG_GATE_STATUS_PULL_FILE={gate_status_destination_file}")
    else:
        emit("ATRIADBG_GATE_STATUS_PULL_STATUS=missing")

if not replay_log and pull_historical_dir:
    destination = Path(pull_historical_dir)
    destination.mkdir(parents=True, exist_ok=True)
    destination_file = destination / "historical-archive.jsonl"
    last_result = None
    for source_path in [
        "Documents/atria-historical/historical-archive.jsonl",
        "Documents/whoop-historical/historical-archive.jsonl",
    ]:
        copy_cmd = [
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", device_id,
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundle_id,
            "--source", source_path,
            "--destination", str(destination_file),
        ]
        result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        last_result = result
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                emit(line)
            emit(f"ATRIADBG_HISTORICAL_PULL_FILE={destination_file}")
            emit(f"ATRIADBG_HISTORICAL_PULL_SOURCE={source_path}")
            break
    else:
        if last_result is not None:
            for line in last_result.stdout.splitlines():
                emit(line)
            raise SystemExit(last_result.returncode)

if not replay_log and pull_reference_package_dir:
    sources = [path for path in [
        rr_reference_csv_path,
        rr_reference_manifest_path,
        hr_reference_csv_path,
        hr_reference_manifest_path,
    ] if path]
    if not sources:
        emit("ATRIADBG_REFERENCE_PULL_SKIPPED=missing_reference_package_path")
    else:
        destination = Path(pull_reference_package_dir)
        destination.mkdir(parents=True, exist_ok=True)
        for source_path in sources:
            destination_file = destination / Path(source_path).name
            copy_cmd = [
                "xcrun", "devicectl", "device", "copy", "from",
                "--device", device_id,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundle_id,
                "--source", source_path,
                "--destination", str(destination_file),
            ]
            result = subprocess.run(copy_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            for line in result.stdout.splitlines():
                emit(line)
            if result.returncode != 0:
                raise SystemExit(result.returncode)
            name = Path(source_path).name
            prefix = "ATRIADBG_HR_REFERENCE_PULL_FILE" if "hr-reference" in name else "ATRIADBG_RR_REFERENCE_PULL_FILE"
            emit(f"{prefix}={destination_file}")

if not replay_log and leave_running and not pull_only:
    keepalive_cmd = [
        "xcrun", "devicectl", "device", "process", "launch",
        "--device", device_id,
        "--terminate-existing",
        bundle_id,
    ]
    emit("HARNESS_LEAVE_RUNNING_ARGS=" + " ".join(shlex.quote(part) for part in keepalive_cmd))
    result = subprocess.run(
        keepalive_cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    for line in result.stdout.splitlines():
        emit(line)
    if result.returncode != 0:
        emit(f"HARNESS_ERROR=leave_running_launch_failed code={result.returncode}")
        raise SystemExit(result.returncode)
    emit("HARNESS_LEAVE_RUNNING status=launched mode=normal_end_user")

if pull_only:
    sys.exit(0)
if until_realtime and not flags["frame_61080005"]:
    raise SystemExit(2)
if until_ready and not (flags["hrv_ready"] or flags["capture_summary_ready"]):
    raise SystemExit(2)
if log_gate_status_deep and not flags["gate_status_deep_complete"]:
    emit("HARNESS_ERROR=gate_status_deep_incomplete")
    raise SystemExit(2)
if log_gate_status and not flags["gate_status_complete"]:
    emit("HARNESS_ERROR=gate_status_incomplete")
    raise SystemExit(2)
if log_gate_readiness and not flags["gate_readiness_complete"]:
    emit("HARNESS_ERROR=gate_readiness_incomplete")
    raise SystemExit(2)
if healthkit_reference_audit and not flags["healthkit_reference_audit_complete"]:
    emit("HARNESS_ERROR=healthkit_reference_audit_incomplete")
    raise SystemExit(2)
if healthkit_export and not flags["healthkit_export_verify_complete"]:
    if not flags["healthkit_export_authorization_pending_complete"]:
        emit("HARNESS_ERROR=healthkit_export_verify_incomplete")
        raise SystemExit(2)
if healthkit_export and confirm_best_sleep_candidate and not flags["healthkit_sleep_export_verify_complete"]:
    if not flags["healthkit_sleep_export_deferred_complete"] and not flags["healthkit_export_authorization_pending_complete"]:
        emit("HARNESS_ERROR=healthkit_sleep_export_verify_incomplete")
        raise SystemExit(2)
if healthkit_reset_rebuild and not flags["healthkit_reset_rebuild_complete"]:
    emit("HARNESS_ERROR=healthkit_reset_rebuild_incomplete")
    raise SystemExit(2)
if healthkit_reset_rebuild and not flags["healthkit_export_verify_complete"]:
    emit("HARNESS_ERROR=healthkit_reset_rebuild_verify_incomplete")
    raise SystemExit(2)
if confirm_best_workout_candidate and not flags["workout_confirm_complete"]:
    emit("HARNESS_ERROR=workout_confirm_incomplete")
    raise SystemExit(2)
if confirm_best_sleep_candidate and not flags["sleep_confirm_complete"]:
    emit("HARNESS_ERROR=sleep_confirm_incomplete")
    raise SystemExit(2)
if log_trends and not flags["trend_summary_complete"]:
    emit("HARNESS_ERROR=trend_summary_incomplete")
    raise SystemExit(2)
if log_trends and not flags["trend_windows_complete"]:
    seen = ",".join(sorted(trend_windows_seen)) or "none"
    emit(f"HARNESS_ERROR=trend_windows_incomplete seen={seen}")
    raise SystemExit(2)
if log_strain_validation and not flags["strain_validation_complete"]:
    emit("HARNESS_ERROR=strain_validation_incomplete")
    raise SystemExit(2)
if log_widget_snapshot and not flags["widget_snapshot_complete"]:
    emit("HARNESS_ERROR=widget_snapshot_incomplete")
    raise SystemExit(2)
if verify_workout_label and not flags["workout_validation_complete"]:
    emit("HARNESS_ERROR=workout_validation_incomplete")
    raise SystemExit(2)
if verify_sleep and not flags["sleep_validation_complete"]:
    emit("HARNESS_ERROR=sleep_validation_incomplete")
    raise SystemExit(2)
if log_gate_status and (healthkit_export or healthkit_reference_audit or healthkit_reset_rebuild) and not flags["post_healthkit_gate_status_complete"]:
    emit("HARNESS_ERROR=post_healthkit_gate_status_incomplete")
    raise SystemExit(2)
if log_file is not None:
    log_file.close()
PY
