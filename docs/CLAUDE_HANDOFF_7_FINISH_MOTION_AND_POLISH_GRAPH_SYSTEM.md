# Atria — Claude handoff 7: finish protected-v9 motion and make the graph system readable

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `codex/whoop-remaining-product-gaps`  
Exact pushed starting commit: `44c12e0e9c8275affaee10ba2d25f72c578ddc0f` (`Show workout strain in the minimized workout pill`)  
Remote parity at handoff: `HEAD...origin/codex/whoop-remaining-product-gaps = 0 0`  
Clean continuation source: `/private/tmp/atria-combined-successor.T76FQG/source`

## Outcome and hard cutline

This pass has two required deliverables, in this order:

1. **Finish the protected-v9 motion bring-up** by correcting the now-identified discovery-owner priority inversion, add durable exact-stage breadcrumbs, and run one bounded fresh-link physical attempt.
2. **Polish the shared graph system**, led by the sleep-stage chart in the user's screenshot, then apply the same restrained visual grammar to Activity HR/Stress, Vitals traces, Trends, and expanded/inspector graphs.

After those two are green:

3. Verify that an old Activity day reaches a terminal HR state without a tab-toggle kick, and that the current parked history gap does not re-arm past its exact retry budget. Patch only a deterministic failure.
4. If time remains, wire the already-built relative raw skin signal behind its blocker-first authority. Do not let this delay checkpoints 1–3.

Timebox: roughly 4 hours implementation plus 30–45 minutes focused/device verification. This is not a new full-app redesign, BLE archaeology marathon, TestFlight pass, or health-algorithm calibration exercise. At the cutline, ship the proven work and report any exact remaining blocker.

## Worktree safety — mandatory

The user's main checkout at `/Users/amanpandey/projects/atria` is intentionally dirty and old at `293d1a7c988bf99b6093b8529da0cf528d6e4896`. Do not edit, stash, reset, clean, stage, or commit application source there. It contains 14 files of the user's chart work, including Activity, Trend, Expanded Chart, Graph Inspector, HeartRate, HRV, and Overview files.

Continue only in `/private/tmp/atria-combined-successor.T76FQG/source` after proving it is clean and still exactly at `44c12e0e…`, or create a new clean detached worktree from `origin/codex/whoop-remaining-product-gaps`.

Do not blindly apply the dirty main-checkout diff. Much of it is an older partial adoption of `AtriaChartVisualGrammar` that the pushed branch has already superseded. Inspect it only as user intent when useful.

This handoff file is coordination material. Do not include it in an app commit.

## What `44c12e0e` already completed — do not redo

- Launch-time HR-only stage backfills persist and publish in the same process.
- An unchanged `history_sequence_gap` parks after six exact-fingerprint attempts; the gap truth remains visible while automatic radio ownership stops.
- User nap/main classification and `dayPrimaryChoice` survive backfill and relaunch.
- Automatic history drain yields to an in-progress workout motion bring-up.
- The minimized workout pill uses workout strain, not the whole-day hero strain.
- HR-only stages remain explicitly estimated and cannot become motion-validated, Recovery/HRV authority, or HealthKit stage truth.
- Relative skin has a pure blocker-first computation in `AtriaRelativeSkinSignal.swift`; no absolute-temperature decoder exists.
- SpO₂ remains terminally unavailable until there is a simultaneous independent reference corpus. Do not add a fake percentage or generic red/IR formula.
- The correct test scheme is `AtriaTests`, one worker, parallel testing off.

## Fresh installed-device truth from exact `44c12e0e`

I controlled iPhone Mirroring directly in this handoff. Coordinate clicks currently route through `com.apple.ScreenContinuity`; do not claim Mirroring is blocked without trying it. The iPhone is cabled, Atria is running, the strap is connected, and the displayed strap battery was 65% (above the existing 25% high-frequency-motion gate, but no longer “over 70%”). No Passwords, Safari, or Brave was opened.

### Current live/history domains

- Live accepted HR is current and visibly updating.
- The compact banner advanced through `Syncing strap history · … · through 2:08/2:09 AM` at about 4:55 AM IST: roughly 2h46–2h52 of **history-domain** lag while live HR remained current.
- This is not permission to label live HR stale. Keep live capture, history frontier, and motion frontier as separate authorities.

### Sleep/day ownership — physically closed

- Activity current physiological day `WED, AUG 12` shows only the 9h12 main sleep (`6:15 AM–3:27 PM`).
- Previous day `TUE, AUG 11` shows exactly one `Nap · 1:01 AM–3:17 AM · 2h16m · Confirmed`.
- The nap/main move is now physically correct. Do not reopen that transaction unless a new reproducible defect appears.

### Activity historical-HR terminalization probe

- Current-day HR and Stress charts load and show the marker band above the plot.
- On `TUE, AUG 11`, HR remained at `Loading recorded heart rate…` for at least five seconds.
- Switching to Stress loaded normally; switching back to HR then reached the terminal error `Heart-rate history couldn’t be read for this window.`
- This proves a terminal exists, but not that it is autonomously reached. Checkpoint 3 must test this without a tab-toggle. Patch only if the same selected-day request deterministically remains loading past its bounded deadline.

### Trends — honest, keep the data rules

- Resting HR showed three real days.
- HRV showed `0d of data` and `Not enough HRV yet`; no unqualified borrowed point appeared.
- Sparse/gappy trend rules are correct: no line across missing days, no fill without a sufficiently long contiguous run, and linear interpolation does not overshoot observed values.

### Sleep-stage chart — functionally honest, visually poor

User screenshot:

`/var/folders/l9/3shhw7rn0nq9g4f07h5rs50m0000gn/T/codex-clipboard-1be1646b-3abc-4ede-b54f-5686394e79cc.png`

The same 9h12 HR-only estimate currently renders approximately:

```text
Awake 0m
Light 3h00
REM 2h24
SWS --
Deep 3h48
Restorative 6h12 · 67%
```

The provenance is honest (`Estimated stages · HR-only`; motion unavailable; boundaries estimated from HR/breathing), but the chart is a barcode of saturated hairline fragments, with weak lane/time hierarchy and too many competing tiles. This screenshot is visual evidence only—not stage-accuracy or calibration evidence. Do not tune the stage ratios to resemble WHOOP.

## Checkpoint 1 (P0): fix the protected-v9/workout-bank priority inversion

### High-confidence source root candidate

The final physical attempt reached:

```text
bring_up_started = true
responseEventDataConnectionCutoverV9 = true
responseEventDataSequenceSentV9 = false
protocol_imu_frames = 0
```

The pushed source now gives a deterministic explanation in `Atria/Atria/AtriaBLEManager.swift`:

- `shouldUseProtectedV9CharacteristicHandler` is around lines 5101–5113.
- Service discovery computes `workoutBankTransportRequested` around 45237–45249.
- At 45297–45309 the standard-HR + workout-bank branch runs **before** the protected-v9 pending/proving branch at 45310–45330.
- Characteristic discovery recomputes the same bank flag around 45486–45498.
- At 45500–45520, even when `shouldUseProtectedV9CharacteristicHandler(...)` is true, the handler is entered only when `!workoutBankTransportRequested`.
- Therefore an active workout—which is exactly when the motion requalifier is needed—selects the generic/bank characteristic path and suppresses `beginProtectedR10ResponseEventDataProfile`.
- The generic TX path does not start the v9 response/event/data sequence. The physical signature is therefore cutover true, sequence false, zero IMU.

Treat this as a high-confidence root candidate. Prove it with a pure resolver plus a direct callback-route regression before calling it the final root.

### Required ownership precedence

Create one pure, exhaustive discovery-owner resolver. Do not keep parallel nested boolean ladders in service and characteristic callbacks. The precedence must be:

1. Exact active history generation/owner.
2. Explicit diagnostic/probe requested by the user/developer.
3. Exact protected-v9 dense bring-up that is `protectedLaunchPending` or `proving` on the current fresh link.
4. Workout v24 bank transport.
5. Protected standard HR / ordinary standard HR.

When protected-v9 is pending/proving, it temporarily owns the strap-service discovery and response/event/data notification sequence even if a workout-bank request exists. Preserve the workout bank's durable ticket/config; do not clear or fabricate it. After v9 qualifies or explicitly falls back, evaluate/resume the bank owner once under the existing generation fence.

### Required implementation properties

- Use the resolver in **both** service discovery and characteristic discovery.
- Preserve history-owner priority and the explicit diagnostic path byte-for-byte in behavior.
- A v9 owner may send the ordered response/event/data command sequence at most once for one exact connection generation.
- Stale service/characteristic/notify callbacks from an earlier connection cannot advance the current owner.
- Standard 2A37 HR must remain subscribed and accepted during the attempt.
- Do not let the parked sequence gap, automatic drain timer, or workout bank evict the protected-v9 owner before it reaches qualified/fallback terminal state.
- Do not turn protected-v9 into an endless retry loop. One fresh link, one ordered notify pass, one command sequence, one bounded proof.

### Persist exact decline breadcrumbs

Console capture is unreliable across reconnects. Add a bounded, versioned persisted edge receipt (or extend the existing bounded motion-handshake evidence) with monotonically ordered entries for:

```text
service_owner_resolved(owner, connection generation)
strap_characteristics_requested(UUID set)
characteristic_owner_resolved(owner)
protected_profile_begin_accepted OR rejected(reason)
notify_requested(UUID)
notify_confirmed(UUID)
sequence_preflight_blocked(reason)
sequence_started(timestamp)
first_crc_valid_motion_frame(timestamp)
qualified OR fallback(reason)
```

Record no payload bytes and no personal health samples. Include enough exact authority (connection generation, protected owner state, bank-request boolean, peripheral identity hash) to reject a stale edge. Keep the ring bounded; do not write per IMU frame.

### Required tests

- Standard-HR + workout-bank + protected-v9 pending resolves to protected-v9 in both discovery stages.
- Standard-HR + workout-bank without a pending/proving v9 owner resolves to workout bank.
- Exact active history always wins over v9/bank.
- Explicit diagnostic wins over production owners.
- A protected-v9 characteristic callback begins the response/event/data profile even when the bank ticket remains pending.
- Ordered notify confirmations produce exactly one sequence send; duplicate/stale callbacks do not.
- v9 qualified/fallback causes one bank reevaluation and never loses the bank ticket.
- Accepted 2A37 HR continues through the full state-machine test.
- Persisted breadcrumbs name every rejection seam and stay bounded.

### One bounded physical attempt

After focused tests and a signed in-place install of the exact commit:

1. Use Computer Use with iPhone Mirroring (`com.apple.ScreenContinuity`) yourself.
2. Ask the user before starting a workout because that creates a health/activity record.
3. Obtain one genuinely fresh BLE link. Prefer a Faraday pouch or unpowered metal enclosure coordinated with the user. **Never operate a microwave** and do not toggle system Bluetooth without explicit user approval.
4. Keep the app process alive; do not relaunch to fake a fresh callback path.
5. Pass if one current-generation path shows sequence sent, at least one CRC-valid IMU/motion frame, and no live-HR discontinuity/reconnect storm.
6. If it fails, stop after the one attempt and report the exact persisted blocker. Do not start another archaeology loop.

## Checkpoint 2 (P1): graph-system polish, led by the sleep hypnogram

### Product principle

“Cleaner and smoother” means clearer visual hierarchy, stable rendering, anti-aliased lines, and less overdraw. It does **not** mean inventing samples, bridging real gaps, changing stage totals, or smoothing biomarker data.

Use the existing local system:

- `Atria/Atria/AtriaGraphGrammar.swift`
- `AtriaChartVisualGrammar`
- `atriaGraphPlotSurface()`
- `AtriaDesignTokens`

Extend these semantic tokens rather than sprinkling new raw colors, opacities, radii, and line widths through every view. Keep expensive segmentation, downsampling, sorting, and formatting out of SwiftUI `body`. Use pure precomputed value models and stable identities.

### 2A. Replace the barcode sleep-stage presentation

There are currently two diverging hypnogram renderers:

- `Atria/Atria/AtriaSleepHypnogram.swift` (`AtriaSleepHypnogramPresentation` and `AtriaSleepHypnogramCard`; lane rendering around lines 401–435).
- `Atria/Atria/AtriaVitalsCollectionSections.swift` (`AtriaSleepStageHypnogram`, around lines 6676–6760), which drives the user's screenshot.

Converge them on one pure `AtriaSleepStageTimelinePresentation` render model and one shared visual component. Do not maintain two independent drawing grammars.

Required visual direction:

- One conventional stepped timeline, not four/five rows full of isolated pills.
- Four visible semantic levels: Awake, REM, Light, Deep. Fold SWS into Deep for the chart, matching the existing presentation contract; retain raw SWS duration in underlying truth/accessibility where applicable.
- Subtle horizontal lane bands or guide lines, with short y-axis labels and real start/interior/end clock ticks.
- Draw each stage run as a calm rounded horizontal stroke/ribbon with a thin vertical connector at an actual transition.
- Use the existing stage palette but reduce saturation/opacity for the plot; reserve stronger color for selection and compact totals.
- Add a compact `HR-only estimate · Low confidence` badge next to the title. Keep the full honesty caption directly under the plot.
- A scrub/selection shows exact clock range, stage label, and `Estimated` provenance. It must not imply a clinical stage reading.
- Reduce the five competing metric tiles to compact rows/chips. Omit an empty `SWS --` display tile when SWS is folded/unavailable; do not turn `--` into zero.
- Keep one quiet restorative summary; no second loud rainbow block competing with the plot.
- Support light/dark mode, Dynamic Type, Reduce Motion, and VoiceOver.

Required rendering honesty:

- Merge exactly adjacent same-stage spans for drawing; that is lossless.
- Never mutate or persist stage segments for presentation.
- Legend durations/percentages must continue to derive from the original integrity-gated segments, not from a decimated render path.
- If hundreds of sub-pixel transitions cannot be represented at phone width, use a pure, width-aware **display-only** compositor that collapses only sub-pixel runs into the dominant stage for that pixel bucket. Preserve first/last boundaries and all visible long runs. Expose a `Dense estimate`/low-confidence cue rather than pretending the trace became cleaner scientifically.
- Do not apply a time-based “minimum stage duration” to the stored algorithm just to improve appearance.
- Keep `Estimated stages · HR-only` and the motion-unavailable caption inseparable from HR-only bars.

Required pure tests:

- Lossless adjacent-run merge.
- Clipping to the exact sleep window.
- Stable IDs from stage/start/end, not array offsets.
- Pixel-width compositor has a fixed maximum mark count, preserves endpoints/long runs, and never changes raw legend totals.
- Stage order, SWS→Deep display folding, event-time-zone axis labels, and accessibility text remain exact.
- Empty/manual/needs-motion/building states stay terminal and truthful.

### 2B. Activity and Vitals physiological traces

Apply one shared trace style to:

- Activity day HR and Stress (`AtriaActivityMonitor.swift`).
- Vitals live HR/Stress (`AtriaVitalsCollectionSections.swift`, `AtriaStressDetailView.swift`, `AtriaHealthScreen.swift`).
- Sleep overnight HR/Stress where the same projection is used.

Rules:

- Keep genuine data gaps blank by preserving the existing segment IDs and continuity threshold. Never fill or line across a real dropout.
- Use one 1.8–2.0 pt rounded trace, restrained semantic gradient, subtle clipped vertical fill (roughly 0.14–0.18 maximum opacity), and quiet grid/axis labels.
- Preserve observed peaks and selected/source samples. Any screen-width decimation must be bucketed per real segment and keep min, max, first, and last—not a simple average that erases peaks.
- Keep activity markers in the dedicated band above the plot. Never draw marker icons over the physiological line.
- Use one consistent scrub cursor/callout and haptic boundary; do not create a per-chart interaction model.
- Do not animate a long trace from zero. A short opacity reveal is acceptable only when Reduce Motion is off.
- Loading must become data, empty, or named error on a bounded deadline. Do not leave an infinite `ProgressView` after the archive read has terminally failed.

### 2C. Trends, expanded chart, and inspector

Preserve the already-correct data grammar:

- Linear interpolation for daily points; no monotone overshoot.
- A missing day breaks the series.
- Area fill only when the **longest contiguous run** meets the threshold.
- A single point is a compact readout/point, not a fabricated axis or line.
- Prior-period comparison is visually subordinate and cannot change the current-series y-domain unless shown.

Polish only the shared visual language:

- Same plot surface, grid opacity, typography, stroke caps, selection cursor, and callout tokens.
- Consistent chart padding so endpoint labels do not clip.
- Consistent empty/loading/error card height to avoid layout jumps.
- Expanded/inspector views reuse the same prepared series and style; they must not recompute large arrays in `body`.

### 2D. Visual/performance acceptance

Add preview/snapshot fixtures (or deterministic render-host tests already used by this project) for:

- HR-only dense hypnogram from the user's screenshot shape.
- Motion-validated normal hypnogram.
- Activity HR with two real gaps and a peak.
- Stress with a discontinuity.
- One-point, two-point, gappy, and dense Trend series.
- Light and dark mode, at least one accessibility Dynamic Type size, and Reduce Motion.

Performance contracts:

- Prepared marks have stable identity.
- No archive-sized map/filter/sort inside `body` or Canvas draw loops.
- Bound visible mark count to plot width for high-frequency traces and dense estimated stages.
- Only the plot subview observes rapidly changing live data; the surrounding screen should not rebuild on every tick.

Physically inspect all of these with iPhone Mirroring after install:

1. Vitals → Sleep stages.
2. Activity → current day → Heart rate.
3. Activity → current day → Stress.
4. A prior workout detail HR/Stress trace.
5. Vitals → Trends (RHR, Strain, HRV empty state).
6. Expanded chart/inspector scrub.

Capture screenshots. Do not claim visual completion from tests alone.

## Checkpoint 3 (P1): two bounded history acceptance probes

### 3A. Autonomous old-day HR terminalization

Select `TUE, AUG 11` → Heart rate and do not switch tabs. Measure the actual request start and terminal deadline.

Pass if it becomes data, empty, or the existing named archive-read error without an unrelated UI action. If it remains loading past the bounded deadline and a tab toggle wakes it, add a request-generation/finally-state regression and fix that exact lifecycle bug. Do not change the chart or archive truth merely to hide the error.

### 3B. Parked sequence-gap convergence

Read the exact `atria.offlineSync.sequenceGap*.v1` state and current frontier. Pass if one unchanged fingerprint parks at six attempts and no unchanged timer/charge/relaunch edge mints attempt seven. A changed fingerprint or frontier ≥1h newer may mint exactly one fresh attempt. Do not clear the durable gap ledger or call the state fully synced.

## Checkpoint 4 (optional P2): wire the relative raw skin signal, blocker first

Only after checkpoints 1–3 are green.

The pure core already exists:

- `Atria/Atria/AtriaRelativeSkinSignal.swift`
- `Atria/AtriaTests/AtriaRelativeSkinSignalTests.swift`

Raw source rows also exist:

- `HistoricalArchive.SkinTemperatureRawPoint` in `HistoricalArchive.swift`.
- Recovered snapshots carry `skinTemperatureRawPoints`.

Do **not** reuse `attachRecoveredSkinTemperature...` or `recoveredSkinTemperatureProjection...` to publish a relative signal; those pass through the disabled/unvalidated Celsius path.

Build a separate off-main raw-relative projection:

```text
integrity-gated raw points
  + exact same strap/layout/payload/offset authority
  + confirmed main-sleep windows
  -> AtriaRelativeSkinSignal.nightSummary
  -> 7–30 prior qualified-night personal baseline
  -> AtriaRelativeSkinSignal.resolve
```

Fence it by archive source fingerprint and confirmed-sleep revision. While the historical archive/gap is incomplete, publish `.incompleteArchive`, not a number. If eventually available, label it `Relative skin signal · Experimental · uncalibrated`, use raw sensor units/direction only, and never show °C/°F, fever/recovery claims, HealthKit, widget, report, strain, or Recovery integration.

SpO₂ remains `REFERENCE_REQUIRED`; do not touch it in this pass.

## Focused validation

Use the `AtriaTests` scheme, one simulator worker, parallel testing off. Start with changed suites and the closest adjacent contracts:

```text
AtriaBLEBackgroundFastLaneTests
AtriaBLERecoveryCadenceTests
AtriaBLEHistoricalRecoveryPolicyStructureTests
AtriaWhoop4HistoryDrainStateTests
AtriaDailyStepPresentationTests
AtriaSleepStageIntegrityTests
AtriaSleepEstimateReconcileTests
AtriaSleepActivityConsistencyTests
AtriaSwiftUIPerformanceAuditTests
AtriaTrendChartTests                 # or the current exact trend suite name
AtriaActivityTimelineTests           # or the current exact Activity chart suite name
AtriaRelativeSkinSignalTests         # only if checkpoint 4 changes
```

Add direct tests for the new transport resolver and shared stage render model rather than relying only on source-string scans.

Use a guarded temporary symlink to `/Users/amanpandey/projects/atria/evidence` only for tests that require the gitignored evidence corpus. Hash a null-delimited manifest before/after, verify equality, and remove the exact symlink with a trap.

Then run changed-file Swift parse, `git diff --check`, and a signed device build. Do not weaken an authority or data-honesty test to make a screenshot prettier.

## Commit, push, issues, and closure

Use small commits, preferably:

1. `Fix protected-v9 discovery ownership during workouts`
2. `Polish the shared chart and sleep-stage presentation`
3. A separate optional relative-skin wiring commit, only if completed.

Author and committer must be `adidshaft <adidshaft@gmail.com>` with no Claude/Codex/AI trailer. Push only to `origin/codex/whoop-remaining-product-gaps`, clean fast-forward, and report exact hashes/parity. No TestFlight.

Update existing issues with exact evidence:

- `#21`: transport resolver/root cause, persisted breadcrumb, physical IMU result, and current motion/step authority. Keep open unless real CRC-valid IMU frames and advancing verified motion are physically proven.
- `#5`: shared graph-system screenshots and old-day HR terminal result.
- `#25`: sleep-stage visual redesign and estimate provenance; keep the nap/main physical closure recorded.
- `#31`: only if relative skin wiring changes; keep SpO₂ reference-required.
- `#33`: only if the physical attempt changes connection stability evidence.

Close an issue only when its stated physical acceptance is genuinely met.

## Final report format

Return:

- Exact commits and remote parity.
- What changed in transport ownership and why it fixes the observed cutover/sequence stall.
- Exact physical motion result or the single persisted blocker.
- Before/after screenshots for the six graph surfaces.
- Focused test counts and any untouched pre-existing failures.
- Old-day HR autonomous terminal result.
- Parked-gap attempt/fingerprint/frontier result.
- Relative-skin state (`wired`, `incompleteArchive`, or `deferred`) and why.
- Explicit confirmation that live HR truth, health authority, user sleep records, dirty main checkout, and evidence corpus were not weakened or altered.
