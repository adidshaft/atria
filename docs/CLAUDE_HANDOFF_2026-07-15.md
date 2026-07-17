# Atria continuation handoff — 2026-07-15 02:00 IST

This handoff is for **Atria only** in `/Users/amanpandey/projects/atria`.

## Non-negotiable scope and guardrails

- Work only on Atria. Do not reference, modify, submit, notify from, or reuse another application (especially Fizz).
- Use the user's Mac for builds and deployment. Do not create CI/CD workflows.
- Do not access the Passwords app.
- Do not open Brave or Safari. Chrome is allowed if browser work is genuinely required.
- Do not install a new Atria build or terminate the current app before the long-wear monitor finishes; doing so invalidates the in-progress physical evidence.
- Do not invent strap-derived HR, strain, steps, SpO2, skin temperature, or historical metrics when evidence is missing.
- Do not commit or push until final physical verification is complete. When committing, author must be `adidshaft <adidshaft@gmail.com>`.
- Preserve the user's dirty worktree. No destructive Git operations.

## Repository and device state

- Repo: `/Users/amanpandey/projects/atria`
- Branch: `codex/atria-reliability-widget-steps`
- Tracking: `origin/codex/atria-reliability-widget-steps`
- Installed physical-device app source commit: `45ddbc36496baca5e1edc33092b8c3ab8302ce3e`
- Current dirty source is newer and **not installed**.
- Physical CoreDevice ID: `3803F5B6-1666-56D3-A71A-62F131F6CE3B`
- iPhone Mirroring is working. Interact with Atria only and leave unrelated apps untouched.
- Latest direct mirrored state at 01:49 IST: header `69% · 8m ago`, Battery card `69%`, live HR `79 bpm`, zone `Z0`.

## Long-wear capture — keep alive

- Process PID at handoff: `85262`
- launchctl label: `com.adidshaft.atria.longwear.overnight-45ddbc36-full-20260714`
- Run directory: `logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714`
- Planned: 11 hourly pulls over 10 hours; acceptance requires at least 9 successful samples and at least 8 hours of attributed evidence.
- Current: 4/11 successful pulls; every pull returned active/session status `ok`.
- Fourth pull: `20260714T201757Z` (01:47:57 IST).
- Latest active segment: 847 accepted HR, 846 raw HR, 78 bpm latest, 29.8 s maximum accepted gap, battery 69%, thermal nominal.
- Current cumulative attributed durable union: 10,838.03 s, 1,472 samples, 96.3703% coverage.
- Honest retained blocker: a real earlier 360.4469 s gap remains in the union. Do not hide or relabel it.
- Current cumulative battery series: 75, 74, 72, 69.
- A prior `serious` thermal observation remains in the run; later capture is nominal.

Safe status/recompute commands:

```sh
pgrep -alf 'monitor_long_wear.py.*overnight-45ddbc36-full-20260714'
wc -l logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714/samples.jsonl
tail -20 logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714.out
python3 tools/monitor_long_wear.py \
  --repo /Users/amanpandey/projects/atria \
  --recompute-existing-run logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714
jq . logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714/summary.json
```

## Verified current checkpoint

- Latest generic iPhone Release build: `** BUILD SUCCEEDED **`
  - Output: `/tmp/atria-continuation-release/Build/Products/Release-iphoneos/Atria.app`
  - It is unsigned (`CODE_SIGNING_ALLOWED=NO`) and must not be installed yet.
- Full simulator result immediately before the last Live Activity battery-clock patch:
  - 1,318 tests passed, 0 failed, 0 skipped.
  - xcresult: `/tmp/atria-continuation-check/Logs/Test/Test-AtriaTests-2026.07.15_01-49-37-+0530.xcresult`
- After the last patch:
  - `AtriaLiveActivityActionTests`: 35/35 passed.
  - Battery/header suite: 25/25 passed.
  - Sleep/editor/activity/cache/density group: 43/43 passed.
  - Python/static/reliability: 240/240 passed.
  - `git diff --check`: clean.
  - Generic iPhone Release: succeeded.
- The iOS 27 beta simulator logged one clone-launch infrastructure message during the full run, but the authoritative xcresult contains all 1,318 test cases as passed with none skipped.

Re-run the complete suite after any further edits:

```sh
set -o pipefail
xcodebuild test \
  -project Atria/Atria.xcodeproj \
  -scheme AtriaTests \
  -destination 'id=03074F5D-1E2D-4FBF-89E7-94B153C80A33' \
  -derivedDataPath /tmp/atria-continuation-check

python3 -m unittest \
  test_handoff_static_checks \
  test_audit_handoff_status \
  test_monitor_long_wear

git diff --check
```

## Major implemented changes in the dirty tree

- Durable live-workout recovery, checkpointing, foreground/background restoration, and completion-aware flushing.
- Live Activity / Lock Screen metrics: HR, zone, steps, daily goal, workout strain, calories, pause/resume, reconnect state, and compact single-line three-digit HR.
- Independent freshness clocks for HR, motion/steps, workout strain, battery level, and charger state.
  - The final patch added backward-compatible `batteryCapturedAt`, `batteryChargeCapturedAt`, and `batteryAvailability` to both app/widget ActivityKit schemas.
  - Timer, HR, and Lock Screen action updates no longer renew battery evidence.
  - An expired charging event removes the bolt without discarding a still-valid percentage.
- Static widget battery/strain invalidation and fail-closed sensor presentation.
- Battery reliability: sentinel 0/10/100 rejection, coherent percentage/age projection, reconnect baselines, separate charger proof, false-bolt expiry, compact bolt-only charging UI.
- Sleep review/save: one transactional Save path for unchanged candidates, edited candidates, naps, and saved sleeps; persistence is verified before the candidate is dismissed; Activity refreshes immediately.
- Notification deep links wait for cold sleep-review cache resolution rather than opening a black/empty path.
- Physiological wake-to-wake day model, no-sleep fallback, resumed-sleep extension/merge logic, and false-sleep conservatism.
- Activity Center axis/icons, activity-specific symbols, consistent edit/delete/save behavior, and saved sleeps shown before rollups exist.
- Workout route persistence, accurate-location handling, pause segments, GPX, map-first route workouts, and Strava-style post-save sharing.
- Share cards: full 9:16 preview, round close/share controls, picture backgrounds, route context, activity-specific icons; unvalidated estimated zero steps are omitted instead of exported as `~0`.
- Compact native workout setup with activity selection and target lower/upper HR zones.
- HR-zone haptic transitions are wired, but require the physical workout stress run.
- Settings presentation isolated from live Home invalidations; compact destinations and reduced explanatory copy.
- Recovery/Healthspan education reduced from stacked paragraph cards to one summary, compact typical value, actions, and collapsed methodology.
- Onboarding Connect no longer advances while disconnected.
- At-a-glance reorder/reset/save, compact collapsed ring rail, activity chart axis/icons, and reduced visible copy across onboarding, journal, workout, and vitals.
- Biological age remains weekly cached. HRV/recovery projections use bounded revision/time caches rather than recalculating on every view open.

## Metrics that remain deliberately fail-closed

- Exact strap step calibration is **not complete**. The transport/pipeline is substantially more reliable, but final sensitivity must be selected from fresh labeled physical evidence.
- Historical/offline WHOOP transport is reliable as raw storage, but there is no validated HR, RR, or step layout. Keep `validatedMetricLayoutVersions` empty.
- Do not derive historical exact steps from the roughly 1 Hz historical gravity stream.
- SpO2 and skin temperature remain unavailable until decoder layouts and reference comparisons are validated.
- Do not promote preliminary research candidates to user-facing exact metrics.

## Required physical session after the monitor completes

The user plans to provide this at the gym. Use separate named workout sessions where practical and record exact start/end seconds plus manually counted steps:

1. Rest baseline, 3–5 minutes.
2. Slow walk, about 4 minutes, manually counted steps.
3. Normal walk, about 4 minutes, manually counted steps.
4. Brisk walk, 5–10 minutes, manually counted steps.
5. Aerobic run, with natural arm swing and manually counted or independently referenced steps if feasible.
6. Strength workout, including app background/foreground switching.
7. Rest/handling/driving negative controls to measure false positives.

During those sessions verify:

- Step count updates within roughly 2–3 minutes and remains monotonic through reconnects.
- Active workout shows real-time steps, calories, strain, HR, and zone without wrapping three-digit HR.
- Lock Screen/Dynamic Island remains truthful through app switching, pause/resume, reconnect, stale sensor windows, and goal crossing.
- Lower target-zone crossing vibrates once; upper crossing three times; returning from above twice; falling below lower once.
- Outdoor walk/run/cycle shows precise route, preserves pause gaps, saves map/GPX, then presents post-save share.
- Ended workout always appears in Activity and remains editable/deletable/shareable after relaunch.
- Battery percentage, age, low state, and charging bolt remain coherent while the workout runs.

After capture, pull device data without deleting originals, replay each labeled stream plus adjacent rest/handling windows, choose detector parameters against both sensitivity and false-positive safety, then run the complete regression suite.

## Final sequence after physical verification

1. Let the 11-sample monitor finish and recompute its final summary.
2. Analyze pass/fail honestly; preserve any real gaps and thermal evidence.
3. Complete the labeled calibration/stress run and replay data.
4. Apply only evidence-supported step parameters; keep research labels if proof is insufficient.
5. Run full simulator, 240 static checks, `git diff --check`, and signed Release build.
6. Install the signed Release on the physical iPhone.
7. Verify battery, reconnect, workout recovery, Activity save/edit/delete, Live Activity, route, share, journal deep link, sleep save, and app-switch responsiveness through iPhone Mirroring.
8. Only when all required evidence passes: commit all intended Atria changes and push to origin using author `adidshaft <adidshaft@gmail.com>`.

## Current dirty files

Use `git status --short` as authoritative. The dirty set currently spans Atria app/runtime files, mirrored widget ActivityKit schema/rendering, tests, long-wear tooling, and static checks. Do not discard any of it. The most recent files touched are:

- `Atria/Atria/AtriaHomeView.swift`
- `Atria/Atria/AtriaLiveActivityAttributes.swift`
- `Atria/Atria/AtriaLiveActivityCoordinator.swift`
- `Atria/AtriaShared/AtriaLiveWorkoutControlIntent.swift`
- `Atria/AtriaWidget/AtriaLiveActivityAttributes.swift`
- `Atria/AtriaWidget/AtriaWidget.swift`
- `Atria/AtriaTests/AtriaLiveActivityActionTests.swift`
- `Atria/AtriaTests/AtriaLiveTabAccessoryTests.swift`
- `test_handoff_static_checks.py`

The user resumed the goal and explicitly asked that work continue through checkpoints.
It is not complete and should not be marked complete until the long-wear run, physical
calibration/stress run, final signed install, and device verification all pass.

## Addendum — Claude babysit session, 2026-07-15 ~02:55 IST

Verification-only session. No app/widget/test source touched; no build installed; the running app and overnight monitor were never disturbed. The only repo-file change is this addendum. `samples.jsonl`/`summary.json` under the run directory were refreshed twice via the sanctioned `--recompute-existing-run` (monitor-owned derivatives only; pull data untouched).

State at 02:55 IST:

- Monitor PID `85262` alive; 5/11 pulls, all `returncode=0`, active/session `ok`.
- Sample 4 (`20260714T211808Z`, 02:48 IST): thermal nominal, 29.8 s max accepted gap, active duration 10,085.6 s (monotonic; no session restart since sample 2), battery 67.
- After recompute: attributed union coverage 97.27739%, span 14,449.03 s, `attributed_active_ok_samples` 4, battery series 75, 74, 72, 69, 67.
- Next pull ~03:48 IST; final (11th) pull ~08:47 IST, process exits shortly after.

Findings for the final analysis (from reading `tools/monitor_long_wear.py` in the dirty tree):

1. The running monitor process was launched from committed code (`45ddbc36`), which does NOT write `run_attributed_*` fields into samples. The dirty tree's live-path attribution is newer. Therefore new samples lack attribution keys until `--recompute-existing-run` back-fills them. After the process exits, the recompute step is REQUIRED, not optional — the final `summary.json` written by the old process will undercount attributed evidence.
2. The acceptance gate as configured cannot pass regardless of the remaining pulls, because three checks are permanent for this run:
   - `active_gap` and `recent_gap` both evaluate `max_attributed_durable_union_accepted_gap_s` over the whole union; the real 360.4469 s gap (occurred in the 22:47–23:47 IST window, sample-1 pull) cannot heal.
   - `thermal` requires all observed states ⊆ {nominal, fair}; the `serious` observation at sample 0 (22:47 IST, run start) is permanent.
   These are the honest blockers already named in this handoff. Do not relabel them. The checks that CAN still pass: `samples` (≥9), `active_ok_samples` (≥9 attributed; max reachable 10 since sample 0 is `empty`), `session_span` (≥28,800 s), `battery`, `session_coverage`, `attributed_evidence`.
3. Timeline for attribution of the permanent blockers: serious thermal = sample 0 at run start; 360.45 s gap = first hour; everything from sample 2 onward has been clean (≤29.8 s gaps, nominal/fair thermal).

Unchanged remaining sequence: let the run finish → recompute → honest pass/fail analysis (expect `fail` on the three permanent checks; report the clean post-23:47 profile alongside, without hiding the early events) → gym calibration/stress session → replay + evidence-based step parameters → full regression → signed install → physical verification → only then commit/push as `adidshaft <adidshaft@gmail.com>`.

## Addendum 2 — calibration pipeline dry run, 2026-07-15 ~03:10 IST

The step-calibration replay/fit pipeline was verified end-to-end against existing
archives (no device/app/monitor interaction). Full gym-day procedure, verified compile
and invocation commands, the fit tool's exact six-stage manifest contract, and the
honesty ledger are in `docs/GYM_CALIBRATION_RUNBOOK_2026-07-15.md`. Key facts:

- Verified compile: `swiftc -O tools/<tool>.swift Atria/Atria/AtriaR10Motion.swift Atria/Atria/FrameParser.swift -o /tmp/<tool>` (reproduces recorded Jul-12 replay evidence byte-for-byte).
- On-device CSV capture window `atria.strapStepCalibration.captureUntil` was armed until **2026-07-20 03:28:36 IST** as of the Jul-13 pull — verify on a fresh pull before the gym; re-arm needs one `--atria-enable-step-calibration` launch (only after the monitor exits).
- The guided calibration plan + manifest share flow is present in the installed build (committed in `29f74d8f`, ancestor of `45ddbc36`).
- New honest evidence: the Jul-13 rest window `1783938635000…1783939535000` replayed on the fuller 21:12 pull yields 9 raw / ~10 production steps at provisional constants (97.6 % coverage, 0 continuity breaks, correctly `evidence_scoreable=0`), vs 0 steps on the partial 16:14 pull (92.2 %, window ended after that pull was taken). Recorded in the runbook's honesty ledger; gym negative controls adjudicate.
- Pull timing rule derived from the above: take the post-gym pull ≥ ~1 h after the last labeled window ends; strap frames flush late.

## Addendum 3 — read-only audit fixes, 2026-07-15 ~03:22 IST

The monitor was left running and the iPhone app was not touched or reinstalled. Three
source-side contradictions found by parallel review were corrected:

- Workout time-window edits now clear `workoutSteps` and its provenance instead of
  attaching the old absolute window's count to the new interval. Label/type-only edits
  still preserve the count.
- `AtriaPendingWorkoutIntent.save` no longer calls deprecated blocking
  `UserDefaults.synchronize()` on the main actor. Exact byte/decode readback remains the
  immediate success gate, avoiding false save failures and checkpoint UI stalls.
- The dedicated `sleepReviewProjectionQueue` now actually runs sleep review preparation;
  workout review no longer occupies it. This restores the intended cold-launch journal
  notification/save starvation protection.

Focused verification after these edits:

- `AtriaWorkoutSaveDurabilityTests` + `AtriaSleepReviewCacheTests`: succeeded, no failures.
- Python/static/reliability suites: 240/240 passed.
- `git diff --check`: clean.

Calibration preflight also identified an installed-build boundary-alignment hazard: the
manifest aligns inward to complete device seconds. The runbook now requires 2 seconds of
stillness after Start and after the final counted step before Stop, plus >1 second between
stages, so exact counted steps cannot sit in a trimmed edge interval.

The dirty future build now enforces the same protection in code without changing the
manifest schema or weakening archive/fitter gates: walk stages show a 2-second still
countdown before GO; `Steps complete` freezes a persisted finish timestamp; validation
uses that timestamp plus a deterministic 2-second trailing guard; failed frozen windows
remain available until an explicit Retry. Legacy in-progress calibration state still
decodes. Focused calibration/archive tests passed 21/21. The complete serial simulator
suite then passed **1,323/1,323** with 0 failed and 0 skipped; xcresult:
`/tmp/atria-full-after-calibration-guards-serial/Logs/Test/Test-AtriaTests-2026.07.15_03-38-03-+0530.xcresult`.
The 240 Python/static/reliability checks and `git diff --check` also pass.
An unsigned, non-installing generic iPhone Release build from this same source completed
without warnings at
`/tmp/atria-release-after-calibration-guards/Build/Products/Release-iphoneos/Atria.app`
(40 MB; executable SHA-256
`1482eee6d4e1451e7e36eb827cd52cf15d6706c02b1fd6c89e3bfcd103df6195`).

Monitor sample 5 (the sixth pull) arrived at `20260714T221906Z` / 03:49 IST with
`returncode=0`, active/session status `ok`, battery 65%, and thermal/power `fair`.
Its current active journal contained 839 accepted/raw HR samples across 1,989.1 seconds
with a 0.0-second maximum gap. The current active segment duration is lower than sample
4's segment because the prior all-day journal correctly crossed the production 3-hour
rotation cap and was finalized at 10,801.83 seconds; the new journal then began. The
prior segment remains present in the immutable session pull and final recompute correctly
deduplicates/joins both journals. However, a real **957.54519-second sensor gap** exists
between the old segment's last absolute timestamp and the new segment's first timestamp.
A read-only in-memory attribution projection (not a run recompute) gives 18,107.035
seconds of observation at 92.539168% coverage and preserves that gap. This supersedes
the earlier 360.4469-second value as the run maximum while both events remain evidence.
PID 85262 remained alive at 6/11; no mid-run recompute or device interaction occurred.

## Addendum 4 — atomic workout recovery authority, 2026-07-15 ~04:18 IST

The running physical app and overnight monitor were not touched. The future build's
pending-workout recovery record is now an atomic file under Application Support rather
than a main-thread `UserDefaults` checkpoint. A dedicated serial utility queue performs
atomic writes with file protection and exact byte/decode readback before publishing a
lock-protected hot snapshot. Legacy defaults migrate only after the file commit verifies;
corrupt or unwritable authority fails closed.

Start, End, and Lock Screen actions now await their durable transition. Progress snapshots
carry monotonic revisions and enter the persistence queue in invocation order. Terminal
End rebases on the latest canonical open intent so an in-flight Lock Screen pause/resume,
exclusion interval, or step checkpoint cannot be overwritten by stale Home presentation
state; immediate journal/confirmation work consumes that returned canonical terminal
intent. Lock Screen replay releases and stops the ordered command tail after the first
load/write/CAS failure rather than applying later commands out of order. Cold-launch BLE
continuity treats an authority still hydrating (or corrupt) conservatively as potentially
active while all disk I/O remains off the hot path.

New regressions cover cold reload, off-main persistence, legacy migration, corrupt and
unwritable authority, stale clear, delayed older progress, progress/terminal races and
rebasing, canonical terminal consumption, cold-launch BLE policy, and failed ordered
command bursts. Authoritative focused simulator result: **73/73 passed**, 0 failures,
`** TEST EXECUTE SUCCEEDED **`; xcresult:
`/Users/amanpandey/Library/Developer/Xcode/DerivedData/Atria-ctrkttbxjrccqrezhykayorqtnwd/Logs/Test/Test-AtriaTests-2026.07.15_04-16-34-+0530.xcresult`.
The documented Python/static/reliability command independently passes **242/242**, and
`git diff --check` is clean. No build was installed, committed, or pushed.

The complete serial simulator suite was then rerun from the final atomic implementation:
**1,333/1,333 passed**, 0 failures and 0 skips; xcresult:
`/tmp/atria-full-after-atomic-intent/Logs/Test/Test-AtriaTests-2026.07.15_04-18-31-+0530.xcresult`.
A fresh unsigned, non-installing generic iPhone Release build also completed without
warnings at
`/tmp/atria-release-after-atomic-intent/Build/Products/Release-iphoneos/Atria.app`
(40 MB; executable SHA-256
`1118b5f417a93dcc10d2e7a4e32ac16dcbb2071b02d5bb3590bf803aff34d8f9`).

A subsequent guardrail audit found no dirty paths outside the Atria repository scope,
no CI/workflow changes, and no Fizz, Brave, Safari, Passwords-app, or GitHub Actions
references in the implementation diff. `HistoricalArchive.validatedMetricLayoutVersions`
remains exactly the empty set. PID 85262 was still alive with 6/11 immutable pulls at
04:23 IST; the installed app remained untouched.

## Addendum 5 — overnight sample 7, 2026-07-15 04:49 IST

The monitor appended pull index 6 at `20260714T231912Z` / 04:49:12 IST. It is the
seventh of eleven planned pulls and returned code 0 with both active-journal and session
status `ok`. The active All-day wear journal contained 1,509 accepted/raw HR samples over
5,582.7 seconds, latest 76 bpm, battery 62%, nominal power and thermal state, and a
102.6-second maximum accepted/raw gap. The old process's rolling session projection
reported 19,507 samples across seven recent sessions, 95.8% coverage, and the earlier
360.4-second maximum gap; this old schema still does not join the journal-rotation gap.
The already audited 957.54519-second cross-journal sensor gap remains authoritative and
must be preserved by the required post-exit recomputation. PID 85262 remained alive; no
mid-run recompute, app/device interaction, install, commit, or push occurred.

## Addendum 6 — overnight sample 8, 2026-07-15 05:49 IST

The monitor appended pull index 7 at `20260715T001919Z` / 05:49:19 IST. It is the
eighth of eleven planned pulls and returned code 0 with active-journal and session status
`ok`. The active All-day wear journal contained 5,174 accepted/raw HR samples over
9,186.2 seconds, latest 65 bpm, battery 60%, nominal thermal state, and a 102.6-second
maximum accepted/raw gap. The app had raised collection cadence to 1.8x and reported
power mode `warm_battery_drain`; this is retained as evidence rather than relabeled. The
old rolling-session projection reported 21,750 recent samples, 96.3% coverage, and its
legacy 360.4-second maximum gap. The audited 957.54519-second cross-journal gap remains
the authoritative run maximum pending final post-exit recomputation. PID 85262 remained
alive; no mid-run recompute, physical-app interaction, install, commit, or push occurred.

## Addendum 7 — reliability/performance hardening, 2026-07-15 ~06:08 IST

The physical app and monitor remained untouched. Independent read-only audits found and
closed second-order correctness/performance defects before final physical qualification:

- Pending-workout Start/End/Lock Screen authority is atomic and crash durable; foreground
  Start now awaits saved-session hydration before anchoring the merged all-day step
  coordinate. Pause/Resume/End reject stale, delayed, reconnecting, or range-backfill
  step coordinates, and incomplete steps are omitted rather than exported as a total.
- Live workout TRIMP/calories retain an immutable completed prefix across bounded journal
  rolls, pause/resume, and profile changes without double counting or bridging gaps.
- Battery callback errors revoke notification authority and drive a bounded
  disable/enable retry, rediscovery, then reconnect path without erasing packet-fresh
  accepted evidence.
- Unchanged confirmed sleep Save returns the exact canonical record. Sleep-review invalidation
  now follows successfully persisted HR/RR evidence (not checkpoint wall time), while
  retaining five-minute coarsening.
- Static day strain has an independent computation timestamp and physiological-cycle
  expiry; HR/step/battery patches cannot renew it, while active-workout strain keeps its
  strict live freshness gate.
- Backup verify/restore heavy work and canonical projections run on serial utility
  workers. Restore uses revision/CAS remerge, a durable multi-file transaction journal
  with launch recovery/rollback and retained failure markers, bounded streaming gzip
  expansion (64 MiB compressed/256 MiB decoded), strict domain/count validation,
  canonical post-restore backup, and generation-gated status publication.
- Activity route recovery/edit/delete and post-workout route/GPX/share preparation run on
  the route persistence queue. Home receives only immutable bounded artifacts with at
  most 240 preview points; a 20,000-point regression verifies the main actor does not
  traverse the full route.

Focused suites passed throughout (route 40/40 and post-workout 88/88; backup 36/36;
workout/sensor 224/224 then follow-up 208/208; sleep/widget 40/40 with final sleep cache
25/25). The authoritative combined static/reliability command passes **242/242** and
`git diff --check` is clean. The final complete serial suite on iOS 26.5 passes
**1,373/1,373**, 0 failures and 0 skips; xcresult:
`/tmp/atria-full-final-prephysical/Logs/Test/Test-AtriaTests-2026.07.15_06-00-31-+0530.xcresult`.

A fresh unsigned, non-installing generic iPhone Release build completed without warnings
at `/tmp/atria-release-final-prephysical/Build/Products/Release-iphoneos/Atria.app`
(41 MB; executable SHA-256
`3f712e54fafa3aba93e1c66fd80aee6dfd7e947021b8f025826eddbd55264c4f`).
`HistoricalArchive.validatedMetricLayoutVersions` remains exactly empty. No device
interaction, installation, commit, or push occurred.

## Addendum 8 — overnight sample 9, 2026-07-15 06:49 IST

The monitor appended pull index 8 at `20260715T011935Z` / 06:49:35 IST. It is the
ninth of eleven planned pulls and returned code 0 with active-journal and session status
`ok`. The active All-day wear journal had rotated again and contained 2,098 accepted/raw
HR samples over 2,016.8 seconds, latest 66 bpm, battery 59%, nominal thermal state,
cadence 1.8x, power mode `warm_battery_drain`, and a 27.5-second maximum accepted/raw
gap. The old rolling-session projection reported 25,582 recent samples and 96.6%
coverage while retaining its legacy 360.4-second gap. Cross-journal continuity from this
new rotation is intentionally left for the required final recomputation; the known
957.54519-second gap remains authoritative until then. PID 85262 remained alive; no
mid-run recompute, physical-app interaction, install, commit, or push occurred.

## Addendum 9 — settled-source validation, 2026-07-15 ~07:07 IST

Further independent review closed remaining edge cases before physical qualification:

- Restore recovery now runs before persisted baseline/profile/rollup initialization and
  fails closed on a retained marker. All canonical producers and automatic backups are
  fenced across restore; sleeps, metrics, and rollups use current-wins merges; every
  restored domain participates in fingerprints/status; nested values and chronology are
  range validated; resting projections remain off-main; gzip trailing bytes are rejected;
  safety archives/retries are bounded. Real SessionStore reinitialization tests cover
  interrupted recovery and retained-marker boot blocking.
- Compact widget strain surfaces now use the same physiological-cycle/capture gate as
  larger tiles. Terminal workout rebasing invalidates stale completed steps when pause
  metadata changes. Action-time step evidence rejects future samples. Cached battery
  notification state cannot mint authority after an error. Static level and charging
  evidence use independent clocks, and retroactive exclusions overlapping a frozen load
  prefix suppress precise strain/calorie presentation.
- Share exports render only after explicit action. Portable photo recaps reuse the exact
  selected image once; camera preparation is cancellable/generation guarded; share
  completion and cancellation remove protected temporary files; the export cache is
  bounded and deletes evictions; route presence participates in portable cache identity.
  Advanced Target reset menus are accessible sibling controls outside disclosure labels.

The first settled full run exposed two test-contract mismatches (incomplete calories are
now intentionally nil; CoreSimulator does not reliably surface NSFileProtectionKey).
Those assertions were corrected to verify the truthful load gate and explicit production
file-protection contract. The authoritative final serial run on a separate iOS 26.5
simulator passes **1,394/1,394**, 0 failures and 0 skips, without compiler warnings;
xcresult:
`/tmp/atria-full-final-settled/Logs/Test/Test-AtriaTests-2026.07.15_07-05-26-+0530.xcresult`.
The combined Python/static/reliability command passes **242/242**, `git diff --check` is
clean, and validated metric layouts remain empty.

The exact settled production source has a warning-free unsigned, non-installing generic
iPhone Release at
`/tmp/atria-release-final-settled/Build/Products/Release-iphoneos/Atria.app`
(41 MB; executable SHA-256
`236417a0ba651a3ccd103b9e28883a7b0c4228ca434d13d6201ca314a0ca2729`).
The subsequent warning cleanup touched only a test-local `var`→`let`, so this Release
matches the final production source. No physical app interaction, install, commit, or
push occurred.

## Addendum 10 — final restore fencing and overnight sample 10, 2026-07-15 ~07:50 IST

The last independent backup/restore audit closed the remaining durability edges:

- A retained restore marker now prevents construction of the Bluetooth central and the
  normal app root, cancels active workout/BLE/sleep/review/debug work, and blocks every
  canonical writer rather than merely blocking file flushes.
- Live BLE `add`/`checkpoint` producers fail closed while the restore fence is active,
  do not mutate the canonical store, and therefore cannot clear an active journal before
  the session is durable. A runtime regression covers both producer paths.
- Duplicate top-level identities, malformed/duplicate/overlapping nested sleep stages,
  and invalid chronology are rejected before import; profile restore keeps a completed
  current profile but restores the backup profile on a fresh install.
- The local pre-restore rollback archive is never mirrored to iCloud. The successful
  post-restore canonical archive independently preserves the user's iCloud preference,
  so temporary safety copies cannot accumulate remotely.
- Direct Photos writes and the unused Photos add-only permission were removed. Daily,
  workout, and weekly 9:16 composers use only round Cancel/Share controls and the system
  share sheet for user-selected save destinations.

The final focused restore/import/launch/stage suite passes **49/49** with no remaining
P0/P1/P2 audit findings. The compile-only iOS 26.5 simulator build succeeds, the combined
Python/static/reliability command passes **242/242**, and `git diff --check` is clean. The
authoritative complete serial iOS 26.5 run passes **1,409/1,409**, 0 failures and 0 skips,
with no runtime warnings; xcresult:
`/tmp/atria-full-after-restore-hardening-serial/Logs/Test/Test-AtriaTests-2026.07.15_07-51-20-+0530.xcresult`.
An earlier parallel-clone attempt hit CoreSimulator launch noise and was discarded before
this clean serial run.

The same production source also completes a warning-free unsigned generic-iPhone Release
build at
`/tmp/atria-release-after-restore-hardening/Build/Products/Release-iphoneos/Atria.app`
(41 MB; executable SHA-256
`4c11fa839ed1219440287222522914370c7a718c5e4c9e64741dc52e1cc8b2a2`).
`HistoricalArchive.validatedMetricLayoutVersions` remains exactly empty.

The long-wear monitor appended pull index 9 at `20260715T021943Z` / 07:49:43 IST: the
tenth of eleven planned pulls. It returned code 0 with active/session status `ok`. The
active journal contained 3,285 accepted/raw HR samples over 5,626.0 seconds, latest
69 bpm, battery 56%, nominal power/thermal state, and a 27.5-second maximum accepted/raw
gap. The rolling session projection reported 21,186 recent samples and 97.5% coverage,
while honestly retaining the legacy 360.4-second gap. PID 85262 remains alive for its
final scheduled pull; no physical interaction, install, commit, or push occurred.

## Addendum 11 — final lifecycle and SwiftUI hot-path audit, 2026-07-15 ~08:23 IST

The monitor and installed physical app remained untouched while the last code-first
performance/lifecycle audit closed five concrete gaps:

- Vitals and History one-tap sleep confirmation now propagate durable save success.
  A failed/fenced save keeps the candidate visible and shows retry/review guidance;
  failure state clears for a new candidate. History Adjust and Confirm remain separate
  VoiceOver actions rather than being combined into a static card.
- `AtriaTodayScreen` no longer observes live `HeroStore` at its large lazy-container
  root. Six narrow hero-dependent leaves own observation, including the compact ring and
  open metric detail, so 1.5-second strain publishes cannot rebuild every Today section.
- Day-strain incompleteness now has a bounded memo keyed by confirmed-workout revision,
  local civil day, and the low-strain gate. Ring, compact header, accessibility summary,
  and glance consumers no longer rescan the full workout archive in one render.
- The Settings hub owns zero destination-only `AppStorage`/`AtriaDefault` observers.
  Personal owns appearance/Face-Off/Today-layout defaults only when opened; Data owns
  iCloud/nutrition defaults only when opened.
- Rapid profile Stepper/Picker edits are coalesced for 450 ms into one durable store
  update instead of one persistence/cache/backup cycle per tick. The final value flushes
  on Personal navigation, Close, sheet disappearance, and max-HR acceptance; source
  echoes do not write back.

Focused results were 31/31 for sleep lifecycle, 52/52 for Today performance, and 37/37
for Settings. The authoritative complete serial iOS 26.5 suite now passes
**1,414/1,414**, 0 failures and 0 skips, with no runtime warnings; xcresult:
`/tmp/atria-full-post-final-perf/Logs/Test/Test-AtriaTests-2026.07.15_08-20-27-+0530.xcresult`.
The combined Python/static/reliability command passes **242/242**, and `git diff --check`
is clean.

The same exact production source completes a warning-free unsigned generic-iPhone
Release at
`/tmp/atria-release-after-final-perf/Build/Products/Release-iphoneos/Atria.app`
(41 MB; executable SHA-256
`4d3dbfe6e435b3cd4abb8061f1913aca958180237d13b1e971511bcb9f6291e3`).
`HistoricalArchive.validatedMetricLayoutVersions` remains exactly empty. No physical app
interaction, installation, commit, or push occurred.

## Addendum 12 — completed long-wear run and pre-gym capture proof, 2026-07-15 ~08:56 IST

The original overnight invocation completed all eleven planned pulls. Its submitted
launchd job then began a second invocation under the same output label, producing one
extra sample and overwriting `run.json` before detection. A separate stale task heartbeat
was also deleted. The extra pull and source JSONL record were retained as audit evidence
rather than edited away; Addendum 13 records removal of the surviving launchd job and the
one-shot wrapper fix.

`tools/monitor_long_wear.py --recompute-existing-run` now selects one deterministic
zero-based monotonic invocation (complete planned sequence, then longest, then earliest),
writes attribution to a separate `recomputed-samples.jsonl`, and leaves `samples.jsonl`,
`run.json`, and every pull byte-identical. The corrected recompute selected source lines
1–11 / samples 0–10 from `20260714T171718Z` through `20260715T031958Z`, and explicitly
excluded line 12 (`sample=0`, `20260715T032011Z`) as `later_sequence_reset`. The immutable
source JSONL SHA-256 remained
`d530f1772c1b8944627641895ce69e6d0dbc9482aac1e3e0003f32781910fe74`.
New live monitor invocations also fail closed before writing if their labeled output
directory already contains anything, preventing a repeated label from appending to or
overwriting prior evidence in the first place.

The honest result remains **FAIL** only on `active_gap` and `thermal`: 11 samples,
10 attributed-active OK samples, 36,160 seconds observed span, 95.7757% durable-union
coverage, 957.54519-second whole-run durable maximum gap, 14.31037-second latest-hour
maximum gap, thermal states fair/nominal/serious, and strap battery 75%→55% (-20 points).
All other acceptance checks pass. Focused monitor/audit tests pass **64/64**; the
combined monitor/static/handoff command passes **244/244**, and `git diff --check` is
clean.

A subsequent copy-only device pull at `20260715T032518Z` did not launch, terminate, or
reinstall Atria. It confirmed Atria running, no official Whoop process, protected HR+R10
mode qualified, fresh CRC-valid passive R10 motion, and a current calibration archive.
`atria.strapStepCalibration.captureUntil = 1784647457.773982`, so labeled calibration
capture is armed through **2026-07-21 20:54:17 IST**. The installed commit `45ddbc36`
remains in place for the gym calibration; no signed install, commit, or push occurred.

## Addendum 13 — detached monitor one-shot hardening, 2026-07-15 ~09:06 IST

A post-completion process audit found PID 53312 still sleeping under the original monitor
label. `launchctl print` proved this was run 2 of the same submitted job, with inferred
`keepalive`; deleting the separate task heartbeat had not unloaded that launchd job. The
original sample sequence had already completed, so only the accidental monitor process
was terminated and its submitted job removed. The iPhone Atria process and strap stream
were not stopped. Repeated checks now show both the launchd service and matching monitor
process absent. The immutable source remains 12 records with SHA-256
`d530f1772c1b8944627641895ce69e6d0dbc9482aac1e3e0003f32781910fe74`.

Future detached monitors now retain a shell wrapper with an EXIT trap that removes their
one-shot launchd job after the monitor flushes its final summary. Combined with the
non-empty evidence-directory refusal, a completed monitor can neither restart into the
same label nor overwrite/append prior evidence. Monitor tests pass **22/22**, the combined
monitor/static/handoff command remains **244/244**, `py_compile` passes, and
`git diff --check` is clean. A temporary inert submitted launchd job using the exact EXIT
trap pattern also unloaded itself successfully (`oneshot_cleanup=passed`), without
touching Atria or the iPhone.

## Addendum 14 — self-auditing calibration pulls, 2026-07-15 ~09:10 IST

`pull_atria_state.sh` now includes the calibration capture lease in every copy-only pull
summary: status, namespace, armed flag, exact Unix/UTC expiry, and remaining seconds.
The embedded Python compiles, `bash -n` passes, and replaying the summary code against the
08:55 IST preflight pull reports `armed=1`, expiry `2026-07-21T15:24:17.773Z`, with the
expected remaining lease. The combined monitor/static/handoff command remains **244/244**
and `git diff --check` is clean.

## Addendum 15 — exact-winner negative-control replay, 2026-07-15 ~09:18 IST

The fit tool can select any of 1,320 detector tuples, but the prior replay CLI could not
apply an arbitrary winner to the required handling/driving/rest negative windows. Replay
now accepts an all-or-none fitter tuple (`filter`, `peak`, `sensitivity`, `confirmation`,
and `gain`), validates the exact fitter grid and finite 0.75…1.50 gain, and reports the
candidate raw/final count plus walk error or explicit `rest_false_steps/rest_pass`.
Partial, duplicate, unknown, malformed, out-of-grid, non-finite, and incomplete-evidence
candidate runs fail closed; the original positional invocation remains compatible.

The gym runbook now includes the Developer-card launch-argument preflight, exact physical
device/evidence-directory pull command, current capture expiry, and the exact-winner
negative-control replay command. Both Swift tools compile, focused archive/replay tests
pass **12/12**, the expanded monitor/static/handoff/archive command passes **256/256**,
embedded pull Python and shell syntax compile, `validatedMetricLayoutVersions` remains
empty, and `git diff --check` is clean. No production detector default, device app,
install, commit, or push was changed.

## Addendum 16 — completion and scope audit, 2026-07-15 ~09:22 IST

The current tree remains Atria-only: 75 dirty paths after the new pull/replay tooling,
none staged, with no workflow/CI additions, other-project implementation, generated
build/evidence artifact, or validated historical metric layout. Branch and upstream are
still `codex/atria-reliability-widget-steps`, 0 ahead/behind at `45ddbc36`; the eventual
commit must use only `adidshaft <adidshaft@gmail.com>` and no AI co-author trailer.

Completion is still unproven and the goal remains active. Required external evidence is:
the exact six-stage exported manifest, labeled stress/negative windows, a copy-only pull
at least one hour later, a passing strict fit plus zero-step exact-winner negatives, then
the final full regression, signed install, physical Mirroring checklist, commit, and push.
The existing unsigned Release and simulator coverage do not substitute for those gates.

## Addendum 17 — continuation preflight, 2026-07-15 ~09:26 IST

A fresh non-disruptive copy-only pull was written to
`logs/live-device/continuation-preflight-20260715T035617Z`. Durable session,
rollup, historical, active-journal-segment, preference, and step-calibration
artifacts were all present. The step-calibration lease remains armed through
`2026-07-21T15:24:17.773Z`; the copied archive contained 23,605 CRC-valid R10
records through `2026-07-15T03:46:56.258Z`.

The pull also proved that Atria was no longer listed as a running process. Its
active journal was about ten minutes stale and the battery state correctly failed
closed to Pending rather than exposing the stale 54% reading as current. A plain
launch of the already-installed `com.adidshaft.atria` build was attempted without
reinstalling or changing calibration state, but SpringBoard denied it because the
physical iPhone was locked. No device or repository state changed. After the user
unlocks the iPhone, relaunch the installed Atria build and verify fresh strap,
battery, and calibration timestamps before the labeled physical session.

The current simulator source build still launches cleanly with no build/runtime
warnings. XcodeBuildMCP screenshot capture works, but accessibility hierarchy
capture remains unavailable because the configured Xcode-beta lacks
`SimulatorKit.framework`; keep the accessibility/performance gate physical and do
not manufacture a simulator pass.

## Addendum 18 — lossless step accounting rollover, 2026-07-15 ~09:43 IST

A production race independent of detector sensitivity was found and fixed without
changing calibration constants. The serial R10 pipeline can now synchronously drain
already-enqueued frames before `snapshotSession` builds its durable record. Every
snapshot carries a pipeline generation, and delayed callbacks from a closed segment
are rejected before mutating main-actor state. Accounting-only finish, long-gap,
civil-day, and three-hour rolls atomically rebase the raw prefix already handed to
the saved session while preserving detector/gait/device-clock/deduplication
continuity; any frames accepted during the persistence boundary carry into the new
segment instead of being lost or duplicated. Launch/debug resets remain hard resets.

Focused R10/recovery/rollover validation passed **272/272** with zero failures,
skips, or runtime warnings:
`/tmp/atria-rollover-focused/Logs/Test/Test-AtriaTests-2026.07.15_09-39-37-+0530.xcresult`.
The complete current-source simulator suite then passed **1,423/1,423** with zero
failures, skips, or runtime warnings:
`/tmp/atria-full-rollover-prephysical/Logs/Test/Test-AtriaTests-2026.07.15_09-41-30-+0530.xcresult`.
No Swift source is newer than that result. The combined tooling/static suite remains
**256/256**, both Swift calibration tools compile against the new pipeline,
`git diff --check` is clean, and `validatedMetricLayoutVersions` is still empty.
Production step parameters remain the provisional research tuple
`8 / 29 / 0.06 / 6 / 1.11`; physical fitting gates remain outstanding.

## Addendum 19 — missed-sleep boundary, durable R10 boundary, and BLE churn closure, 2026-07-15 ~11:05 IST

A copy-only missed-sleep incident pull at
`logs/live-device/sleep-missed-20260715T043746Z` preserved the exact raw window without
changing the installed app. The 2026-07-15 06:16:03–09:15:56 IST window lasted
2 h 59 m 53 s, contained 7,258 HR and 7,205 RR samples, averaged 64.82 bpm, and had a
27.51-second maximum gap. It missed the prior hard three-hour threshold by seven seconds.
The detector now admits only a bounded review-only morning fallback: closed session,
03:00–08:59 start, end no later than 11:00, 1–60 seconds under three hours, stable low HR,
at least 60% HR/RR coverage, and no gap above 30 seconds. It never changes recovery until
the user saves it, and the prior false-sleep case remains rejected. Focused sleep tests
pass **15/15**:
`/tmp/atria-sleep-boundary-focused/Logs/Test/Test-AtriaTests-2026.07.15_10-14-43-+0530.xcresult`.

The R10/workout persistence boundary now uses a generation-owned FIFO fence. HR/RR are
buffered during persistence, R10 frames cannot cross into the next segment before the
committed generation is installed, journal writes are fenced, and workout intent/route
checkpoints clear only after durable success. Normal release is idempotent; a wrong token
retains the fence, while the explicit generation-scoped fallback prevents a stranded
boundary without falsely reporting success. Focused final R10 validation passes **37/37**
and an independent audit found no loss, duplicate replay, stale-generation release, or
false-success path:
`/tmp/atria-r10-boundary-derived/Logs/Test/Test-AtriaTests-2026.07.15_10-46-31-+0530.xcresult`.

Physical evidence showed healthy standard-HR delivery is naturally sparse (p50 6.04 s,
p90 11.36 s, p95 11.97 s, maximum 13.97 s), so the installed six-second watchdog was
causing real reconnect churn. Source now waits 20–45 seconds (30 seconds by default),
never toggles an already-notifying 2A37 characteristic, coalesces notification enables
through a 30-second lease, and performs a hard rebuild only after both raw HR and every
useful GATT channel have been silent for 120 seconds, with a 120-second cooldown.
Sparse-duty-cycle traffic suppresses rebuilds while retaining bounded battery reads;
low-battery shutdown exits before journal/repair churn. Focused BLE tests pass **176/176**
with an independent clean audit:
`/tmp/atria-watchdog-gate-tests/Logs/Test/Test-AtriaTests-2026.07.15_11-03-31-+0530.xcresult`.

A later copy-only pull at
`logs/live-device/post-watchdog-preinstall-20260715T053651Z` confirmed the old installed
build still running protected HR+R10 with fresh CRC-valid motion, credible 51% battery,
and calibration capture armed through 2026-07-21 20:54:17 IST. It also recorded the old
six-second watchdog firing at a 6.9-second raw-HR gap, which is why no claim is made that
the physical churn is fixed before the eventual post-calibration install. No reinstall,
commit, or push occurred.

## Addendum 20 — conservative activity typing and metric reliability, 2026-07-15 ~11:35 IST

Workout existence remains strap-first: sustained elapsed elevation, a continuous bout,
recent confirmation, contact, accepted-packet quality, and continuity/RR agreement are
required. A single or fragmented HR spike cannot prompt, and streams below 70% accepted
packets fail closed. Denied/unavailable phone context abstains and cannot block a strap
workout. Only fresh, sustained medium/high native Walk, Run, or Cycle context may suggest
a subtype; fresh medium/high Automotive may veto. Strap gait remains research-only
shadow evidence. Dance and Strength remain `Other` until labeled physical captures
establish a confusion matrix instead of guessing from rhythmic wrist motion. The focused
implementation passes **28/28** and the independent broader audit passes **170/170**:
`/tmp/atria-activity-accuracy-derived/Logs/Test/Test-AtriaTests-2026.07.15_11-10-25-+0530.xcresult`
and
`/tmp/atria-activity-detection-audit/Logs/Test/Test-AtriaTests-2026.07.15_11-13-48-+0530.xcresult`.

HRV is now fail-closed across every path. Unvalidated proprietary `0x28` RR is retained
only in explicit research capture and cannot enter live/saved HRV, archives, baselines,
recovery, or export. Live, saved-session, saved-reference, and external-reference RMSSD
preserve rejected-beat ordinals and require at least 70% truly adjacent successive NN
differences. Legacy cached snapshots without adjacency evidence decode but are not ready;
unsafe whole-session SDNN reconstruction is retired. A failed normal-wear attempt may
retry after five minutes only when newer RR exists, while a successful ready value keeps
the four-hour cadence. Focused metric tests pass **425/425** and the independent audit
passes **349/349**:
`/tmp/atria-metric-reliability-derived/Logs/Test/Test-AtriaTests-2026.07.15_11-33-57-+0530.xcresult`
and
`/tmp/atria-metric-reliability-audit/Logs/Test/Test-AtriaTests-2026.07.15_11-33-46-+0530.xcresult`.

SpO2 and wrist-temperature production decoders remain hard-off because no synchronized
reference/layout validation exists. UI continues to withhold numbers, and temperature
copy now says Wrist/relative wrist-skin rather than Body/core temperature. This is an
accuracy result—no fabricated health value was introduced.

## Addendum 21 — independent step holdouts and combined pre-physical checkpoint, 2026-07-15 ~11:43 IST

The production R10-to-step path was audited end-to-end: CRC-valid fixed-layout frames,
FIFO detector, generation-safe session/day reconciliation, and independent home/workout/
widget publication. Capture and fitter tooling retain the exact six-stage contract and
strict device-time coverage gates. Production constants remain unchanged at
`8 / 29 / 0.06 / 6 / 1.11`.

The fitter now supports an optional separate `--holdout-manifest` containing `walk`,
`run`, `rest`, and `negative` windows. Candidate selection and gain freeze before the
holdout is decoded; validation data cannot influence fitting. A valid holdout set requires
at least one counted positive and one zero-step negative, no training overlap, complete
continuous evidence, at most 5% error for every positive, and exactly zero detected steps
for every negative. Legacy CLI behavior remains compatible and prints that no holdout was
provided. Combined calibration-tool tests pass **18/18**, focused Swift calibration tests
pass **13/13**, and both optimized Swift tools compile.

The authoritative complete serial iOS run passes **1,460/1,460**, zero failures/skips,
with no build or runtime warnings:
`/tmp/atria-full-accuracy-final/Logs/Test/Test-AtriaTests-2026.07.15_11-36-26-+0530.xcresult`.
The complete static/reliability/tooling suite passes **262/262**; shell and embedded Python
compile, `git diff --check` is clean, and `HistoricalArchive.validatedMetricLayoutVersions`
remains exactly empty. The exact production source also builds a warning-free, unsigned,
non-installing generic-iPhone Release at
`/tmp/atria-release-accuracy-final/Build/Products/Release-iphoneos/Atria.app` (41 MB),
executable SHA-256
`968614f41f4202d74b6e6afe9b098ac402cc627be02d026403b83c38411d1208`.

The goal remains active. Do not install this source or tune steps before the physical
session. Required evidence is the exact six guided stages plus an independent counted
walk, counted run when practical, and exact labeled windows for strength, stationary
cycle, dance, seated stillness, typing/phone handling, feet-planted wrist motion, and a
passenger/driving control; leave quiet gaps and record timestamps to the second. A
separate outdoor route, HR-zone haptic crossing sequence, app-switch/background workout,
and delayed copy-only pull 1–2 hours later remain mandatory. Only after strict fit,
independent holdout/negative passes, physical Release verification, and the delayed pull
may the final signed build be installed and the tree committed/pushed.

## Addendum 22 — fresh preflight, live continuity benchmark, and research pairing, 2026-07-15 ~12:10 IST

A fresh copy-only pull at
`logs/live-device/prephysical-preflight-20260715T061906Z` found Atria backgrounded with
fresh protected standard HR and CRC-valid R10 motion. Battery was a credible live 49%,
capture remained armed through 2026-07-21 20:54:17 IST, and the calibration archive held
25,299 rows / 98,338,813 bytes. The old installed build still showed its known six-second
watchdog churn; no new source was installed. The new pull preflight measures exact row
bytes, discovers the 96 MiB archive cap and 32 MiB maximum segment from production source,
and uses the peak rolling hour within the newest six hours. Current ingress was
14,580,137 bytes/hour, yielding a conservative 4.603-hour retained window and a safe
pull-within-two-hours action. Missing/corrupt capacity, timestamps, rows, ingress, or
sequence preferences fail closed. The absent sequence key is reported only as default
`not_started`, 0/6; UI visibility remains explicitly unproven.

An exact accepted-HR/RR replay benchmark covered 13 confirmed workouts and seven
confirmed sleep/non-workout windows. The live evaluator's literal five-second evidence
gap fragmented legitimate sparse delivery even though saved workouts use a validated
15-second continuity contract. Replacing only that literal with
`SavedSession.workoutContinuityGapLimit` changed clean workout prompt opportunities from
261 to 317 while adding zero prompts across 91,064 clean sleep-control calls. Every
contact, accepted-share, RR-agreement, current/recent-HR, threshold, and five-second
freshness gate remains unchanged; gaps above 15 seconds still reset the continuous bout.
The change helps vigorous sparse-stream workouts but correctly does not invent the missed
low-HR 33-minute walk: that requires separately validated strap-motion existence evidence,
not a weakened HR threshold.

The raw-motion replay now emits an explicit research-only gait-shadow summary for each
labelled session using overlapping five-second windows at a one-second stride. Those
windows are not independent observations; session-level comparisons can compare
walking/running against dance, strength, cycle, handling, rest, and driving tomorrow.
It always reports the activity decoder unvalidated
and never emits a production label. A separate fail-closed
`tools/pair_sensor_references.py` pairs exported independent SpO2/wrist-temperature
reference rows with clock-qualified raw historical frames while preserving raw layout,
clock delta, and research-only gates. Pairing never validates a decoder or promotes a
metric. Current proprietary realtime `0x28` RR also remains unvalidated: the fresh active
journal contains 1,824 source-free RR values with only 21% three-second coverage and a
247.1-second maximum gap, and no simultaneous source-tagged 2A37/0x28 capture exists.
Future copy-only pulls now preserve `Documents/atria-captures` as well as the active
journal and historical archives so an explicit source-tagged capture cannot be silently
omitted from the Mac evidence bundle. Each capture copy gets a SHA-256 manifest, file
count, and byte count, and the pull refuses a reused nonempty evidence directory so stale
files cannot masquerade as a fresh copy. Sensor-reference pairing now uses one nearest
frame within two seconds, preserves original and clock provenance, exposes archive
ranges/rejections/duplicates/reuse, and rejects malformed evidence.
All metric-layout and proprietary-RR validation sets remain empty.

After the final audit corrections, the complete explicitly non-parallel simulator suite
passes **1,462/1,462**, zero failures/skips, and the authoritative result summary contains
no runtime warnings:
`/tmp/atria-full-accuracy-post-activity-serial/Logs/Test/Test-AtriaTests-2026.07.15_12-26-27-+0530.xcresult`.
The combined static/reliability/calibration/research-tool suite passes **276/276**; both
optimized Swift calibration tools compile, shell/Python syntax checks pass,
`git diff --check` is clean, and production pedometer constants remain unchanged.

## Addendum 23 — immutable long-wear recheck and functional capture-copy proof, 2026-07-15

The completed overnight evidence was rechecked without modifying it. No long-wear
monitor or submitted wrapper remains alive. `samples.jsonl` still contains the 12 raw
records and retains SHA-256
`d530f1772c1b8944627641895ce69e6d0dbc9482aac1e3e0003f32781910fe74`;
the deterministic recompute still attributes the intended 11-record sequence and
excludes only the later zero-index reset. Its honest acceptance result remains `fail`
only for the old installed build's whole-run 957.545-second durable gap and a recorded
serious thermal state. The latest-hour durable gap remains 14.310 seconds, coverage
95.776%, battery 75% to 55%, and all other gates pass. This evidence is not relabelled as
a pass and does not replace the post-calibration physical stress run on the new source.

The copy-only pull's explicit sensor-capture path now has a functional fake-device
regression in addition to static wiring checks. The test exercises a complete pull with
nested `Documents/atria-captures` files, verifies byte-identical copies, independently
recomputes every SHA-256 entry, and checks that manifest path, file count, and total bytes
in `pull-summary.txt` agree with the copied payload. Missing unrelated app files continue
to fail soft within the evidence summary, while a reused nonempty destination fails
before device access. The full step archive/pull test module passes **19/19**, sensor
reference pairing passes **8/8**, and the complete Python/static/tool discovery passes
**359/359**. Shell and Python syntax checks pass and `git diff --check` is clean. No app
launch, install, detector tuning, validation-set promotion, commit, or push occurred.

## Addendum 24 — fail-closed labelled activity batch evaluation, 2026-07-15

`tools/evaluate_activity_detection.py` now turns tomorrow's exact labelled walk, run,
dance, strength, cycle, rest, handling, typing, and driving windows into one deterministic
research report. It invokes the authoritative Swift R10 replay for every window, requires
complete scoreable device-time evidence, rejects malformed/boolean/overlapping windows,
and reports only a sustained `walking_shadow` confusion matrix. A manifest must include
at least one walk/run and one confuser, and every window must span at least 34 seconds so
short controls cannot create artificial true negatives. Exact replay-summary fields,
five-second/one-second-stride semantics, ratios, counts, metric ranges, bounded execution,
and duplicate JSON keys all fail closed. Counted steps remain solely in the separate step
holdout workflow. Even a clean shadow matrix remains explicitly `research_only=1` and
`validation_status=not_validated`, with `activity_decoder_validated=0`, zero production
promotions, and zero production label changes. Locomotion gating and walking-vs-running
subtype accuracy are reported separately.

Real synthetic R10 integration tests prove sustained gait vs stillness, rhythmic dance
and run subtype-confusion reporting, incomplete-frame refusal, strict manifest rejection,
contract mismatch refusal, and replay timeout handling. Production activity logic,
pedometer constants, installed app, validation sets, and physical evidence remain
unchanged. Focused activity-evaluator tests pass **7/7** and the complete
Python/static/tool discovery passes **366/366**; syntax checks and `git diff --check`
are clean.

No retrospective subtype result was manufactured from the prephysical pull. Its one
confirmed overlapping-date Walking workout ran 2026-07-14 14:33:42–15:07:06 UTC, but
the retained CRC-valid R10 archive has no rows in that device-time window; the next raw
receipt block begins around 15:24 UTC. Exact replay therefore reports zero frames and is
unscoreable. Tomorrow's independently labelled physical windows remain the first valid
input to the batch evaluator.

## Addendum 25 — activity and HRV accuracy closure plus physical preflight, 2026-07-15

A fresh non-disruptive pull at
`logs/live-device/accuracy-audit-20260715T073732Z` copied the running installed app
without installing or changing source. Protected standard HR plus CRC-valid R10 motion
was live, the calibration archive remained armed through 2026-07-21 20:54:17 IST, and
the sequence remained unstarted at 0/6. The archive held 25,345 rows / 98,517,535 bytes;
the fail-closed retention forecast remained 4.603 hours with the required pull-within-two-
hours action sufficient. No explicit synchronized SpO2 or wrist-temperature reference
capture existed, so both production decoders correctly remain unavailable.

The completed monitor allowed one relaunch of the same installed commit with only
`--atria-developer-mode`; the capture lease was not re-armed and no build was installed.
iPhone Mirroring then physically proved Settings → Developer → Step calibration visible
at exactly 0/6, showing Stage 1 `Rest before`. `Prepare motion stream`, Start, Restart,
and every calibration action were left untouched. The installed build still contains its
known six-second HR watchdog; the corrected source remains intentionally uninstalled
until physical calibration passes.

Activity prompt semantics were tightened without promoting a gait classifier. Live and
persisted readiness now share destination-sample interval ownership and the same 3-second/
25-bpm microgap reseed rejection. RR presence cannot bridge a hard accepted-HR gap;
disconnected elevated bouts cannot sum into one prompt; sustained and Z3 paths require
one complete continuous qualifying bout; and the current HR must still qualify. A broad
Walk/Run/Cycle suggestion no longer silently persists its first subtype—subtype remains
nil until explicit review selection. Research gait quality rejects non-finite/out-of-range
values and remains shadow-only. Focused activity/review validation passes 25/25.

HRV is now consistent for clean low-rate athletes across live and saved-session paths.
Saved five-minute windows use the decoder-supported 0.5 beat/second minimum instead of a
fixed 240 beats, while still requiring a real five-minute span, 75% retained confidence,
and 70% true adjacent NN differences. Stress and breathwork short-window RMSSD now use
one continuous timestamped segment with range, local-median artifact, confidence, gap,
and adjacency gates; disconnected islands and rejected beats cannot be stitched. The
focused Analytics + Stress suite passes 174/174 with no failures, skips, or runtime
warnings; xcresult:
`/tmp/atria-focused-metric-accuracy/Logs/Test/Test-AtriaTests-2026.07.15_13-05-50-+0530.xcresult`.
The calibration/activity/sensor-reference/archive Python modules pass 40/40 and
`git diff --check` is clean. SpO2, wrist temperature, proprietary realtime RR, and
historical metric layout validation sets remain hard-off/empty.

The independent metric overlap audit then corrected an interval-boundary issue in that
first HRV pass. Because each RR timestamp marks the end of its interval, live coverage
now begins at the measured start of the first standard interval; it never invents time
after the last beat. The same rule lets a genuine 15-minute, 40-bpm saved capture produce
three complete five-minute windows instead of two. Saved RR rejects nonpositive or
greater-than-three-second gaps and all remaining outer readiness guards use the dynamic
0.5 beat/second floor. The audit's final focused run passes 23/23. Legacy persisted RR
still has no per-sample source tag, so files written by the old mixed-fallback build remain
source-ambiguous; no validation gate was weakened to claim otherwise.

Step durability was also hardened without changing the production detector tuple or any
sensitivity threshold. Restore seeding is idempotent, the last CRC-valid R10 device time
is persisted as a serial-number-aware replay watermark, equal/older reconnect frames are
rejected after relaunch or dedupe eviction, and bounded pre-restore races cannot erase
newer live input. Journal step checkpoints remain monotonic and implausible stored totals
fail closed. Detector-applied freshness now advances on every cadence evaluation even
when the count is unchanged, while transport freshness remains separate. The combined
step reliability run passes 242/242, the final R10 rerun passes 40/40, and the restore-race
guard passes its final 1/1 compile/test check. A longer motion-only interval still lacks
an independent lightweight cumulative step ledger; raw archive evidence survives, but
that broader persistence subsystem remains an explicit follow-up rather than a hidden
claim.

After merging all three accuracy passes, the complete explicitly serial simulator suite
passes **1,482/1,482**, zero failures:
`/tmp/atria-full-accuracy-merged/Logs/Test/Test-AtriaTests-2026.07.15_13-27-02-+0530.xcresult`.
The complete Python/static/tool discovery passes **366/366**. Both optimized Swift
calibration tools compile with production decoder dependencies, shell and Python syntax
checks pass, `git diff --check` is clean, and all four SpO2/temperature/proprietary-RR/
historical-layout promotion gates remain exactly hard-off/empty. No build was installed,
no calibration action was started, and no commit or push occurred.

## Addendum 26 — pre-gym Release, independent step ledger, RR provenance, and battery closure, 2026-07-15

The remaining persistence and source-integrity work is now implemented. Strap steps have
an independent atomic Application Support ledger, separate from the HR journal, with
monotonic cross-writer reconciliation, serial-aware R10 watermarking, bounded count/time
coalescing, lifecycle force flush, exact boundary rotation, and fail-closed corrupt or
implausible state. It adds no stationary per-second I/O and does not change the production
detector tuple `8 / 29 / 0.06 / 6 / 1.11`. Standard 2A37 RR samples now carry explicit
per-sample provenance through live buffers, saved sessions, and the active journal. Legacy
or mixed-source RR remains decodable for audit but cannot feed HRV, recovery, stress,
breathwork, respiration, workout RR agreement, or trends. Proprietary realtime RR and
historical metric layouts remain unvalidated and hard-gated.

Before installation, the running phone was copied non-destructively to
`logs/live-device/preinstall-latest-20260715T110727Z`. Calibration was armed through
2026-07-21 20:54:17 IST and remained exactly 0/6. The first installed Release exposed one
real physical failure: HR/R10 could be live while battery remained Pending. The postinstall
evidence showed three distinct reconnect holes. A genuinely new link could inherit a
cached `isNotifying` 2A19 flag without a current CCCD epoch; a confirmed 2A19 link could
remain Pending while 2A37 was briefly silent even though current CRC-valid R10 proved the
strap/link; and cross-process consumers rejected a freshly renewed lease once the original
CCCD callback exceeded one hour. The fix uses the existing bounded CCCD off/on watchdog
for an unconfirmed cached flag, accepts either post-connection HR or CRC-valid R10 solely
as current-link proof, and treats the fresh foreground-renewed lease as corroboration
without falsifying the original battery packet timestamp. It still performs no production
2A19 read and sends no proprietary battery command.

The corrected signed Release was installed from
`/tmp/atria-pre-gym-release/Build/Products/Release-iphoneos/Atria.app`. iPhone Mirroring
showed one consistent 41% value in the top pill and Battery card, with no Pending state;
Settings opened immediately without the reported hang. The copy-only physical proof at
`logs/live-device/postfix-battery-20260715T113130Z` reports `battery_level=41`,
`battery_source=live_2A19`, `battery_usable=1`, `battery_effective_status=live`, a 13.6s
notification lease, live strap stream, fresh active journal, and calibration still exactly
0/6. The 41 MB app is signed as `com.adidshaft.atria` for team `JP4HU7X6G7`; binary
SHA-256 is `583b1c45c710b78323a6617a2360c5f2f2a4fc76d399dd090d5512cc435cd1b0`.

After resetting a disposable iOS 27 simulator whose clone connection UUID failed, the
complete explicitly serial Swift suite passes **1,498/1,498**, zero failures:
`/tmp/atria-battery-epoch-fix/Logs/Test/Test-AtriaTests-2026.07.15_17-07-14-+0530.xcresult`.
The complete Python/static/tool discovery passes **366/366**, the signed Release build
succeeds, codesign verification and `git diff --check` pass, and every sensor-promotion
gate remains hard-off/empty. Remaining work is physical only: the exact guided calibration,
independent positive/zero holdouts, labelled activity windows, outdoor route/pause/resume,
zone haptic order, background workout, delayed archive pull, strict parameter fit, and
final installed verification. No detector tuning, commit, or push has occurred.
