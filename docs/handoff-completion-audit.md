# Atria Handoff Completion Audit

Date: 2026-06-22

This file tracks the current implementation/evidence state for the autonomous
handoff in `6b30d1b6-5821-4a7a-8682-53703e1663e0.md`. It is intentionally
evidence-first: a task is not marked accepted unless the repo or captured logs
prove it.

## Current Status

Status: **not complete**

Reason: the remaining acceptance proof requires long-running physical-device
validation that is intentionally skipped for now:

- 8-12 hour unattended long-wear run.
- Acceptable iPhone thermal state (`nominal`/`fair`) and "not warm" evidence.
- Broad accessibility/performance proof, including Instruments evidence.
- External-reference validation for the `validated` tier is explicitly skipped
  for this single-strap pass and remains gated/unvalidated by design. Personal
  baseline is the terminal end-user HRV/recovery state for this handoff.

## Handoff 21 Current State (2026-06-28)

Status: **mostly implemented, not final-complete**

`docs/21-codex-customization-and-metrics-handoff.md` is now substantially covered
by local source and physical-device evidence, but it is not marked complete
because historical RR promotion remains intentionally fail-closed without
external/reference validation, and a final measured accessibility/performance pass
has not been captured.

Evidence present:

- Overview glance customization is implemented with persisted order,
  show/hide membership, long-press edit mode, drag/drop reordering, per-card
  remove controls, per-card compact/wide sizing, and a plus-sheet for adding
  hidden widgets back.
- Vitals section ordering is implemented separately from Overview, with coarse
  section-level reordering only.
- Top-left status and top-right actions use uniform header sizing without the
  previous nested pill wrapper. The top status chip derives "Live" from real
  pulse evidence instead of BLE connection alone.
- Contact/status copy no longer tells users to clean the strap while heart rate
  is live. Poor beat-to-beat quality with live HR is surfaced as HRV settling.
- Connection diagnostics cover Bluetooth off, Bluetooth permission, low strap
  battery, range/pending reconnect, fit/no-pulse, stale pairing suspicion, and
  official WHOOP coexistence risk.
- Official WHOOP coexistence is detected when technically available and is
  surfaced as guidance, not silent degradation. Atria cannot kill another iOS app
  from the sandbox; user-facing copy explains the close/uninstall/forget-pairing
  path.
- Range-loss backfill stays local-first and fail-closed for metrics. Current
  pulls show the archive is persisted for continuity repair while HRV, Recovery,
  and Sleep remain gated until historical RR is validated.
- The missed-data banner remains visible while reconnecting/searching and now
  says saved data is protected/backfill is ready instead of implying data loss.
- Sleep history supports confirmed sleep and nap records, auto nap/sleep
  distinction, manual sleep/nap entry, sleep debt/consistency, heat strip,
  stage-building states, and AWAKE/LIGHT/REM/SWS/DEEP labels without fabricating
  unavailable stages.
- Heart-rate timeline includes axes, clipping, tap-to-inspect, full-screen
  explorer, and zoom.
- Biological age is present as an estimate with baseline gating, a younger/older
  delta, factor breakdown, and non-medical labeling.
- Metric target zones are implemented with editable targets from the card and
  Settings, reset-to-recommended actions, and non-medical guidance.
- The handoff-21 static guard suite is green at 84 checks and pins the major
  implementation contracts above.

Most recent physical-device evidence from non-disruptive pulls:

- Atria process running on Aman's iPhone.
- Official WHOOP process/widget not listed.
- Saved sessions present.
- Historical archive present with `historical_archive_rows=46353`,
  `historical_archive_current_session_usable_rows=45414`,
  and `historical_archive_metric_ready=0`.
- Metric promotion blocker remains
  `historical_archive_metric_promotion_blocker=continuity_repair_only`.
- Confirmed sleep records exist: `confirmed_sleep_records=2`, including one nap
  and one overnight record, with zero validated stage records.
- Latest correct-bundle pull (`artifacts/goal-21-state-20260628T133936Z`)
  showed the active journal fresh/active with `active_journal_samples=1308`,
  `active_journal_rr_values=247`, `active_journal_duration_s=1331`, and
  `active_journal_age_s=19`.
- The same pull reported `offline_sync_last_status=deferred_live_link`, pending
  range-loss backfill, `battery_level=58`, `battery_charge_status=notCharging`,
  `battery_is_charging=0`, and no listed official WHOOP process/widget.
- The current RR stream is present but still not locally promotion-ready:
  `active_journal_rr_gate_b_local_ready=0` because the usable RR window is short,
  gappy, and below the corrected-beat threshold.
- Post charge-status UI install pull
  (`artifacts/goal-21-post-charge-ui-20260628T135351Z`) confirmed the updated
  app running with no official WHOOP process/widget, `battery_level=63`,
  `battery_charge_status=charging`, `battery_is_charging=1`, and a fresh active
  journal. This proves the strap charge-state signal is available to the app
  after the copy clarification.

Remaining handoff-21 blockers:

- Historical archive RR layout must be externally/reference validated before
  backfilled history can feed HRV, Recovery, or Sleep metrics.
- Final physical accessibility/performance evidence is still pending: light/dark,
  Reduce Transparency, Increase Contrast, Reduce Motion, and measured scroll
  performance.
- A final requirement-by-requirement audit should be run after those checks before
  calling the goal complete.

2026-06-28 visual/accessibility progress:

- A bounded physical iPhone 15 Pro capture produced
  `docs/evidence/accessibility-performance/summary.draft.json`.
- The draft records passing screenshots for dark mode, light mode, Increase
  Contrast, Reduce Motion, and Reduce Transparency.
- The draft also records a fresh 10s Time Profiler trace at
  `docs/evidence/accessibility-performance/trace-live-20260628T132245Z.trace`.
- Dashboard scroll capture tooling now produced a physical-device smoke trace at
  `docs/evidence/accessibility-performance/dashboard-scroll-20260628T133529Z/dashboard-scroll.trace`
  plus `dashboard-scroll.trace.toc.xml`. CoreDevice screen recording was
  unavailable on this device path, so the capture keeps Instruments trace
  evidence as the durable artifact and treats video as optional.
- This is not final acceptance because `dashboard_scroll_fps` remains `0`; a real
  measured scroll FPS pass is still required before writing final `summary.json`.

## Local Implementation Evidence

### Pillar 1: SwiftUI / Liquid Glass UI

Evidence present:

- Native tab/root and bottom accessory implementation is present in the app
  source.
- Design-token files and renamed content-card surfaces are present.
- External reference import/export cards and the standard-HR radio toggle are
  hidden from the default end-user Data tab behind `AtriaDeveloperMode`.
- Media controls are surfaced in app chrome and Live Activity paths.
- Dead legacy identifiers were not found by local scan for:
  `LegacyContentView`, `DashboardSection`, `AtriaGlassToolbar`,
  `RecoveryRing`, `StrainGauge`.
- Local scan found `ActivityKit` in `AtriaLiveActivityCoordinator.swift`,
  `AtriaLiveActivityAttributes.swift`, and widget code.

Not yet accepted:

- Reduce Transparency / Increase Contrast / Reduce Motion visual checks.
- Light/dark visual pass on physical device.
- 60 fps dashboard scroll proof from Instruments on iPhone 15 Pro.

### Pillar 2: Local Metrics And Native Features

Evidence present:

- Validate-later language and display tiers are present in code/docs.
- HealthKit HRV export uses reference-validated SDNN paths.
- Respiratory rate and resting heart rate export paths are present in
  `HealthKitExporter.swift`.
- Local metrics/features are represented in source: stress, sleep/debt,
  ATL/CTL, VO2 estimate, journal correlations, App Intents, ControlWidget,
  Live Activity, media controls, and phone-side haptics/call awareness.
- `AtriaHapticAlerts.swift` uses `CXCallObserver`.
- `AtriaMediaControls.swift` reads `MPNowPlayingInfoCenter`.
- AI coach code is present and cloud mode is not default-on.
- `AtriaCoachNetworkPolicy` now makes the coach network posture explicit:
  local mode is `.offlineOnly`, cloud mode is `.cloudDisabled`, the local
  disclosure says no data leaves the iPhone, and the static checks forbid
  `URLSession`/request/http usage in `AtriaAICoach.swift`. The stale
  `localModelEnabled` setting was removed so the current UI does not imply a
  downloaded LLM runtime that is not shipped.

Not yet accepted:

- External-reference HRV validation is intentionally skipped for this pass.
  Personal baseline is accepted for end-user display, while the `validated` tier
  and HealthKit HRV writes remain gated.
- End-to-end UI/accessibility proof for all new feature surfaces is not present.
- Optional downloaded local LLM runtime proof is not present; current local
  coach answers are deterministic on-device summaries with explicit offline
  network policy.

### Pillar 3: Background Collection / Battery Safety

Evidence present:

- `PowerThermalGovernor` observes thermal and Low Power Mode state.
- Long-wear supervision is consolidated into a single supervisor path.
- Thermal pressure defers nonessential long-wear analysis and keeps minimal
  persistence.
- Segmented active-journal persistence is implemented in
  `ActiveSessionJournal.swift`.
- Pull-only harness mode can copy sessions and active journal without
  restarting Atria.
- `tools/monitor_long_wear.py` provides a non-invasive monitor with an
  `overnight` preset, explicit acceptance checks, and
  `acceptance_diagnostics` fields that record observed-versus-required values
  for every blocker.
- `test_monitor_long_wear.sh` runs the fast local monitor regression path
  (`py_compile` plus `test_monitor_long_wear.py`).
- `test_handoff_static_checks.sh` locks local source invariants for production
  strap-write blocking, restored-peripheral reuse, validated-only HRV export,
  resting-HR/respiratory-rate HealthKit export, validate-later recovery display,
  native feature seams, monetization seam/no-StoreKit scope, BG task plumbing,
  diagnostic-log gating, production notification identifiers, and iOS 26 UI
  cleanup. It also verifies that every CoreBluetooth `writeValue` call remains
  confined to the guarded `sendCommand` helper, preventing accidental new blind
  strap-write paths.
- `ATRIADBG` HealthKit/export diagnostics route through `AtriaDebugLog`, so
  normal end-user launches do not emit verbose diagnostic rows unless the
  harness/debug flags enable them.
- Production notification identifiers are limited to recovery, strain, and
  battery alerts. The diagnostic delivery probe remains debug-only while still
  being removable during cleanup.
- `tools/audit_handoff_status.py` summarizes local artifacts and long-wear
  monitor summaries into a conservative `complete` / `not_complete` result.
  The top-level audit carries through long-wear `acceptance_diagnostics`, so a
  failed physical summary includes observed-versus-required values without
  manually opening the monitor JSON.
  Use `--skip-external-reference` when external reference validation is
  deliberately deferred for a non-reference readiness audit.
  By default, it discovers
  `docs/evidence/accessibility-performance/summary.json` once a physical
  iPhone 15 Pro accessibility/performance manifest has been recorded. Use
  `--accessibility-performance <summary.json>` only for an alternate evidence
  path.
- `test_audit_handoff_status.sh` verifies that failed or missing physical
  acceptance evidence cannot be reported as complete.
- `test_handoff_local.sh` runs the fast local handoff suite in one command.
- `Info.plist` includes `processing` background mode and permitted BG task
  identifiers.
- 2026-06-22 simulator compile check passed:
  `xcodebuild -project Atria/Atria.xcodeproj -scheme Atria -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/atria-derived-data build`.
- 2026-06-22 end-user readiness smoke on the plugged-in iPhone launched with
  the worn WHOOP strap in standard-HR-only long-wear mode. The smoke log
  captured standard Heart Rate Measurement RR data before relaunching long-wear
  collection: `rr_frames=26`, `rr_values=30`,
  `rr_source_2a37_frames=26`, `standard_2a37_rr_frames=26`,
  `rr_truncated_frames=0`, and `rr_hr_mismatch_values=0`.
- 2026-06-22 non-disruptive physical-iPhone pulls verified that current app
  state can be inspected without relaunching or killing Atria. The pull script
  now copies `Documents/atria-active-session.segments`, reconstructs
  `atria-active-session.json` locally, and reports
  `active_journal_final_status=ok` when segmented reconstruction succeeds.
- The same pulls separated file durability from live-stream continuity:
  `sessions_count=207`, the latest saved session still had `232` HR points and
  `176` RR points, and the best saved RR segment was locally clean
  (`best_saved_rr_segment_gate_b_local_ready=1`), while the live active journal
  was correctly classified as
  `active_journal_continuity_status=stalled`,
  `active_journal_continuity_reason=stale_journal`, and
  `active_journal_interruption_class=live_stream_interrupted_saved_sessions_present`.
- Runtime recovery now clears unsavable stale active-journal tails before they
  can masquerade as current data. No-data, HR-continuity, accepted-HR, and
  disconnect recovery paths call `clearUnsavableActiveJournalIfNeeded` for
  live segments with fewer than two samples, recording
  `cleared_unsavable` / `drop_unsavable_stale_segment` instead of retaining a
  one-sample stale journal.

Recent physical-device smoke evidence already captured:

- `logs/live-device/run-20260622-pull-only-sessions-summary.log`:
  `1173` recent HR samples, `899` RR intervals, zero HR gaps.
- `logs/live-device/run-20260622-pull-only-sessions-summary.log`:
  active journal `83` HR samples, `45` RR intervals, zero gaps.
- `logs/live-device/long-wear-monitor/acceptance-default-check-20260622/summary.json`:
  default acceptance failed for `session_span`, `session_coverage`, and
  `thermal`.

Not yet accepted:

- The required 8-12 hour unattended run has not been completed.
- The current captured thermal state was `serious`, not `nominal`/`fair`.
- Battery drain is only smoke-sampled, not overnight-proven.
- Range-loss/recovery and no-scan-storm proof over an overnight window is not
  present.

## Deferred Acceptance Command

When long runs and physical-device checks are allowed, use:

```sh
ATRIA_DEVICE_ID=<physical-device-id> \
  python3 tools/monitor_long_wear.py \
  --preset overnight \
  --label overnight-$(date -u +%Y%m%dT%H%M%SZ)
```

The run is accepted only if the final monitor summary reports:

```text
acceptance_status=pass
acceptance_blockers=none
```

The handoff audit also verifies that the summary came from the overnight preset
shape: at least 11 planned samples, 10 planned hours, 9 required successful
pulls, 8 hours of persisted-session span, 85% coverage, 30 second maximum
accepted-HR gap, `nominal`/`fair` thermal states only, and at most 35 percentage
points of battery drop. The monitor summary must also include
`monitor_started_at`, `monitor_finished_at`, and an `app_commit` matching the
repository commit being audited. Short custom smokes do not satisfy final
acceptance.

The default overnight preset records:

- 11 pull-only samples.
- 1 hour between samples.
- 10 hour planned duration.
- Minimum 8 hour persisted-session span.
- Minimum 85% persisted-session coverage.
- Maximum accepted-HR gap of 30 seconds.
- Thermal states limited to `nominal`/`fair`.
- Maximum battery drop of 35 percentage points.

## Deferred Accessibility / Performance Evidence

When physical UI checks are allowed, copy
`docs/evidence/accessibility-performance/summary.template.json` to an evidence
folder and fill it only from measured iPhone 15 Pro results. The audit requires:

- Reduce Transparency visual pass.
- Increase Contrast visual pass.
- Reduce Motion visual pass.
- Light mode and dark mode visual pass.
- Dashboard scroll performance of at least 58 fps.
- A recorded Instruments trace path, and the referenced trace artifact must
  exist in the evidence folder.
- Measurement provenance: `measured_at`, `app_commit`, and `app_build`.
  `measured_at` must be an ISO-8601 UTC timestamp ending in `Z`, and
  `app_commit` must match the repository commit being audited.

Then run:

```sh
python3 tools/audit_handoff_status.py --skip-external-reference
```

For a human-readable current-state summary, run:

```sh
python3 tools/audit_handoff_status.py --skip-external-reference --markdown
```

Use `--accessibility-performance <summary.json>` only when checking an
alternate measured evidence file.

To prefill the current commit/build provenance without creating passing
evidence, run:

```sh
python3 tools/prepare_accessibility_performance_evidence.py
```

This writes `docs/evidence/accessibility-performance/summary.draft.json`.
To fill measured values after a real iPhone 15 Pro pass, pass the measured fields
explicitly:

```sh
python3 tools/prepare_accessibility_performance_evidence.py \
  --force \
  --dashboard-scroll-fps 60 \
  --all-accessibility-checks-pass \
  --instruments-trace docs/evidence/accessibility-performance/trace.trace \
  --notes "Measured on iPhone 15 Pro Release build."
```

Only write the final `summary.json` when all fields are genuinely measured:

```sh
python3 tools/prepare_accessibility_performance_evidence.py \
  --final \
  --force \
  --dashboard-scroll-fps 60 \
  --all-accessibility-checks-pass \
  --instruments-trace docs/evidence/accessibility-performance/trace.trace \
  --notes "Measured on iPhone 15 Pro Release build."
```

The `--final` mode refuses to write `summary.json` while any accessibility check
is false, dashboard scroll FPS is below 58, provenance is missing, or the trace
artifact path does not exist.

## Final Summary Rule

Do not claim the handoff is complete until:

- The monitor overnight summary passes.
- Accessibility/performance checks are recorded.
- External-reference-dependent items remain skipped/gated by design; do not
  require them for the single-strap handoff acceptance.
