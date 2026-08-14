# Atria — Claude handoff 8: make historical HR fast, prove backlog convergence, and wire relative skin honestly

Date: 2026-08-13 (Asia/Kolkata)  
Release branch: `codex/whoop-remaining-product-gaps`  
Exact pushed starting commit: `5befd2066a3ebfe2a3e87b02be46dbddb33b7f1d` (`Route the existing sleep-scope fixture's root tab`)  
Remote parity at handoff: `HEAD...origin/codex/whoop-remaining-product-gaps = 0 0`  
Clean continuation source: `/private/tmp/atria-combined-successor.T76FQG/source`  
Primary tracking issues: [#35](https://github.com/adidshaft/atria/issues/35), [#21](https://github.com/adidshaft/atria/issues/21), [#31](https://github.com/adidshaft/atria/issues/31)

## Hard cutline

This is a short product-completion pass. Do these in order:

1. **P0 — make a completed Activity day's exact HR lookup terminal within a few seconds**, not ~42 seconds.
2. **P0 — prove the live history drain is actually converging faster than new data arrives.** Patch only if the measured frontier slope cannot catch up.
3. **P1 — wire the existing relative raw skin signal incrementally and blocker-first.** Shipping a typed blocker/baseline-progress state is a valid result; publishing an unqualified number is not.
4. Run focused tests, one signed in-place install, and physical acceptance through iPhone Mirroring. Commit/push/update issues.

Timebox: about 3 hours implementation plus 30–45 minutes device acceptance. Stop at the cutline. Do not start another dense-IMU archaeology pass, broad graph redesign, SpO₂ formula experiment, SWS-HRV feature, full-suite marathon, or TestFlight release.

## Worktree safety — mandatory

The user's main checkout `/Users/amanpandey/projects/atria` is intentionally dirty and old at `293d1a7c988bf99b6093b8529da0cf528d6e4896`. Do not edit, stash, reset, clean, stage, or commit application source there. It contains the user's chart work plus prior handoff documents.

Continue only in `/private/tmp/atria-combined-successor.T76FQG/source` after proving it is clean and exactly at `5befd206…`, or create a new clean worktree from `origin/codex/whoop-remaining-product-gaps`.

This handoff file is coordination material. Do not add it to an app commit.

## What handoff 7 completed — do not reopen

### Protected-v9 app path is complete

Commit `c9c29703` fixed the actual workout-bank discovery priority inversion. One pure owner resolver now drives both service and characteristic discovery:

```text
exact history > explicit diagnostic > protected-v9 pending/proving > workout bank > standard HR
```

The physical attempt then proved the entire app sequence:

```text
protectedV9BringUp selected with bank=1
profile accepted
all four notifications confirmed
sequence preflight clean
sequence_started
responseEventDataSequenceSentV9 = true
90-second proof
fallback_response_event_data_missing_r10_frames
imuFrames = 0
```

Live HR stayed continuous and the workout saved. This is no longer an app routing/state-machine bug. Dense R10 is now `PROTOCOL/REFERENCE_REQUIRED`: the strap firmware did not serve frames for the activation payload/mode. Do not alter more app-side discovery, leases, cooldowns, owners, or command ordering in this pass.

Production motion remains the v24 workout bank plus history-drain offload. Step/motion truth must remain explicit about partial coverage. A future official-WHOOP negotiation capture is a separate user-authorized research project, not a reason to keep modifying production blindly.

### Graph redesign is shipped and physically verified

Commit `0fdee9b3` converged both hypnograms on one pure render model and shared stepped timeline. Commit `5befd206` routed the Sleep fixture. On the installed build I independently verified through iPhone Mirroring:

- Four readable Awake / REM / Light / Deep levels.
- Real event-time clock ticks.
- Rounded stepped runs and transition connectors.
- `Low confidence` and `Dense estimate` cues.
- HR-only/motion-unavailable copy inseparable from the chart.
- No fabricated SWS numeric tile.
- Compact legend and restorative summary.

The graph is materially cleaner. Some width-composited dense runs still appear as short dots, but that is honest, bounded, and disclosed. Do not churn the chart again in this pass.

### Nap/main ownership remains physically correct

- `WED, AUG 12`: only the 6:15 AM–3:27 PM 9h12 main sleep.
- `TUE, AUG 11`: exactly one confirmed Nap at 1:01 AM–3:17 AM (2h16).

Do not reopen this transaction without a new deterministic failure.

## Fresh device facts from this handoff

I used Computer Use with `com.apple.ScreenContinuity` directly. Coordinate taps routed in this session. The exact installed app was live, the strap was connected at 61% battery, and current HR was present.

### Historical HR CP3A is terminal but far too slow

At approximately 06:55 IST:

1. Opened Activity.
2. Navigated directly to `TUE, AUG 11`.
3. Left Heart rate selected and performed no tab toggle or unrelated action.
4. The chart still said `Loading recorded heart rate…` after 12 seconds.
5. After about 42 seconds total it autonomously became the honest terminal state:

```text
Selected day
-- bpm
No heart-rate samples were captured in this window.
```

Therefore the old CP3A liveness concern is closed, but a real latency defect remains. Track it in [#35](https://github.com/adidshaft/atria/issues/35).

### History is advancing, but remains roughly 2h37 behind

During this read-only session the compact history state moved approximately:

```text
3054 saved · through 4:09 AM
→ 3595 saved · through 4:19 AM
```

Wall clock was 06:56 IST. Live HR remained current. This proves productive work, not convergence: the frontier advanced only ten minutes during the observation and was still about 2h37 behind. Checkpoint 2 must measure the rate over a proper interval before claiming the backlog is solved.

## Checkpoint 1 (P0): bound exact historical-HR lookup latency

### Current source path

`Atria/Atria/AtriaActivityMonitor.swift`:

- `AtriaActivityTimelineHost` starts `.task(id: timelineSignalWindowKey)` around lines 2015–2025.
- `refreshTimelineHeartRate` begins around line 2205.
- The historical snapshot deliberately excludes resident sessions and invokes the exact-window reader on a detached utility task.
- `readTimelineHeartRate` calls:

```swift
HistoricalArchive.metricHeartRatePoints(
    start: snapshot.interval.start,
    end: snapshot.interval.end,
    maximumPoints: 100_000
)
```

`Atria/Atria/HistoricalArchive.swift`:

- `metricHeartRatePoints(start:end:maximumPoints:)` begins around line 7077.
- `exactMetricHeartRatePoints` begins around line 7099.
- `recentReadableFileURLs()` around line 7349 includes catalog raw chunks, active segment, readable/base data, and legacy data.
- `exactWindowProjectionFileURLs` around line 7555 excludes a file only when one sealed catalog row, digest/stat identity, and trusted timestamps prove it lies outside the requested interval.
- Unknown, active, legacy, or otherwise untrusted candidates are conservatively scanned.
- The scanner starts every selected source at offset zero with `cutoff: 0`, decodes every mixed-channel JSONL line enough to call `fastHeartRatePoint`, then filters to the requested day.

That is the leading code-backed suspicion for the ~42-second empty lookup. It is not yet a measured root cause. Instrument first.

### Required measurements before choosing architecture

For one exact request ID/window/source fingerprint, record a bounded diagnostic receipt (DEBUG/persisted diagnostic only; no health samples) containing:

```text
request start/end and elapsed milliseconds
catalog generation
candidate file count
trusted-outside-window skipped count
selected file count
selected/scanned bytes
scanned lines
HR candidate lines
in-window points
index/cache hit or miss
terminal result
cancellation/stale-generation result
```

Add `os_signpost` spans around catalog selection, raw scan, parse/filter, projection, and MainActor install. Run the same Aug 11 navigation once in Release on the physical device. Attribute the cost before implementing a large index.

### Required product behavior

- A selected completed day must reach measured data, honest empty, or a named blocker quickly.
- No unbounded `Loading recorded heart rate…` state.
- Real samples, min/max, exact timestamps, source provenance, and capture gaps remain unchanged.
- A result for one source fingerprint/window may never be reused after the underlying exact source identity changes.
- Day changes cancel/retire the old request; stale completions cannot replace the new day.
- No raw-archive scan or large parse runs on MainActor.
- Live per-row writes must not re-key a completed historical request.

### Preferred bounded design

Choose the smallest architecture supported by the measurements. The likely safe shape is:

1. **Versioned verified per-chunk HR lookup metadata/sidecar**, produced off-main when a raw chunk seals or when recovery publishes a source revision.
   - Bind it to exact raw relative path/resource identity, byte count, modification time, catalog generation, and content digest where available.
   - Store only minimal HR lookup data: timestamp/byte-block bounds or canonical HR rows. Do not duplicate unrelated raw channels.
   - An index may exclude a block only when its time/source authority is durably proven. Unknown/corrupt/mismatched metadata falls back safely.
2. **Exact result cache** keyed by closed-open window + source fingerprint + reader version, for instant repeat navigation.
   - This is additive; caching alone is not an acceptable fix for a 42-second first read.
3. **Progressive UI state**:
   - If verified data/index is available, terminalize immediately.
   - If safe background preparation is required, leave `.loading` within 500 ms for a typed state such as `Preparing recorded history…`, then republish the exact same request generation when ready.
   - If preparation cannot proceed, show a terminal named blocker within five seconds. Never call an unproven window empty.

Do not write a timestamp-only shortcut that ignores `capturedAt` corrections or assumes all legacy lines are ordered. Do not trust an unsealed sidecar merely because the filename looks daily. Do not delete/rewrite the raw archive.

### Performance acceptance

On the real installed corpus and the exact Aug 11 navigation:

- Cold lookup with valid index: terminal in **≤3 seconds**.
- Warm exact-window cache: terminal in **≤250 ms**.
- Missing/invalid index: typed preparation or named blocker in **≤5 seconds**, no indefinite spinner.
- No MainActor slice ≥100 ms attributable to this read.
- Repeated navigation does not rescan unchanged raw bytes.
- Before/after receipt reports elapsed time, selected files, scanned bytes/lines, and result equality.

### Required tests

- Large mixed-channel multi-file fixture where only one sealed chunk overlaps; prove outside chunks are never read.
- Unknown/active/legacy file remains conservative and cannot be falsely excluded.
- Verified index and raw fallback return byte-equivalent ordered HR points and identical empty/non-empty truth.
- Corrupt, stale, wrong-generation, truncated, or wrong-digest index fails closed.
- Window/source-keyed result cache invalidates on catalog generation, size/mtime/resource identity, or reader-version change.
- Day A request → day B request → late A result: only B publishes.
- Cancellation yields `.interrupted`/prior visible projection per the existing policy, never a spinner.
- No live history revision re-keys a completed historical day.
- A performance fixture asserts bounded file/byte visits, not wall-clock timing alone.

## Checkpoint 2 (P0): prove history backlog convergence

The user's recurring complaint was accurate: wearing the strap continuously should not leave the historical frontier perpetually hours behind while live HR continues. The domains are separate, but the history drain must eventually outrun new historical production.

Run one **30-minute read-only settled window** on the signed final build. Do not start a workout or force a reconnect.

Capture every 60 seconds:

```text
wall clock
live accepted-HR latest timestamp/count
durable live-journal latest timestamp/count
history frontier timestamp
saved row count
history owner/generation/state
command/ACK counts
sequenceGap fingerprint/attempt/parked state
disconnect/reconnect/CCCD counters
process PID and resource/watchdog/crash evidence
```

Compute:

```text
frontier advance seconds / wall-clock seconds
net lag change
saved rows per minute
accepted-vs-durable HR gaps
```

### Pass criteria

- Live raw/accepted/durable HR remains current with maximum gap <30 seconds.
- One history owner; no reconnect/CCCD storm or process restart.
- For a real backlog, the historical frontier advances faster than wall clock over the settled window and net lag shrinks materially.
- Continue a second bounded window only if the first is distorted by one connection transition.
- Existing `sequenceGap*` keys remain empty while repair is productive; do not synthesize a parked record.
- When lag reaches ≤5 seconds, UI may say `Synced`; before then it must continue naming history-domain sync.

If the frontier rate is ≤1.0× for a settled 30-minute window, diagnose the exact bottleneck (radio page cadence, ACK wait, persistence, scheduling, or MainActor fan-out) from counters before editing. Make one bounded throughput correction only. Do not sacrifice live HR, motion-bank truth, ACK durability, or prefix-only retirement to increase headline speed.

## Checkpoint 3 (P1): wire relative raw skin incrementally and honestly

The pure computation is already shipped:

- `Atria/Atria/AtriaRelativeSkinSignal.swift`
- `Atria/AtriaTests/AtriaRelativeSkinSignalTests.swift`

Raw inputs already exist:

- `HistoricalArchive.SkinTemperatureRawPoint` (`t`, `raw`, `strapIdentifier`).
- Recovered snapshots include `skinTemperatureRawPoints`.

Do not use these existing Celsius-path functions for the relative product:

- `attachRecoveredSkinTemperature...`
- `recoveredSkinTemperatureProjection...`
- `skinTemperatureDeviationCelsius`

They remain behind an unvalidated absolute decoder and are a separate authority.

### Required producer

Create a versioned off-main per-night summary producer:

```text
integrity-gated SkinTemperatureRawPoint rows
  + exact strap/layout/payload-length/raw-offset authority
  + confirmed main-sleep window and confirmed-sleep revision
  + exact archive source fingerprint/completeness receipt
  -> RawSkinSample
  -> AtriaRelativeSkinSignal.nightSummary
  -> persisted AtriaRelativeSkinNightSummary
  -> AtriaRelativeSkinSignal.resolve(current + 7–30 prior qualified nights)
```

Persist only the compact versioned night summaries and their source authority; do not create another raw archive. Key by confirmed sleep ID plus exact authority/algorithm/source revision. A user edit/delete/type change invalidates or rebuilds the affected summary. A stale recovered generation cannot install a night or UI result.

Reuse the recovered execution lease/cooperative checkpoints. Preparation is off-main; MainActor installation is a bounded value swap after exact canonical-session, confirmed-sleep, archive-fingerprint, and execution-authority rechecks.

### Completeness rule

A global gap should not erase an independently proven complete night, but an unproven night must fail closed. A night qualifies only if its exact window has a completeness receipt proving the raw channel is not truncated. Otherwise:

```text
blocker = .incompleteArchive
rawDelta = nil
normalizedIndex = nil
```

While fewer than seven prior matching qualified nights exist:

```text
blocker = .buildingBaseline
baselineNightCount = actual qualified count
```

### UI contract

Keep validated temperature and experimental raw-relative signal visually separate.

Validated card remains:

```text
Skin temperature  --
Decoder not verified
```

Experimental card/section may show:

```text
Relative skin signal
Building personal baseline · 3 of 7 nights
```

or, only after full qualification:

```text
Relative skin signal
Higher / within / lower than your usual raw baseline
+18 raw sensor units · Experimental · uncalibrated
```

Rules:

- No °C/°F or “temperature” numeric value.
- No fever, illness, recovery, readiness, strain, coaching, or cross-user/device claim.
- No HealthKit, widget, Live Activity, report/export, or retroactive reinterpretation.
- No numeric raw delta while `.incompleteArchive`, `.buildingBaseline`, mixed/unknown authority, stale evidence, or insufficient coverage.
- HR-only nights may be lower-confidence; never claim motion-qualified stillness when motion is absent.
- SpO₂ stays blank and `REFERENCE_REQUIRED`.

### Required tests

- Per-minute median → nightly median from real-shaped raw rows.
- Same strap/layout/payload/offset/algorithm nights build baseline; any authority mismatch does not.
- Exactly six prior nights stays `.buildingBaseline`; seven qualifies.
- Gap overlapping current or prior night yields `.incompleteArchive` and no numeric value.
- Independently proven complete nights survive an unrelated gap outside their windows.
- User sleep edit/delete/reclassification invalidates the exact summary and stale worker cannot restore it.
- Relaunch restores identical compact summaries/result.
- No write/read of `skinTemperatureDeviationCelsius`; no degrees/medical/recovery/export call site.
- Background cancellation leaves previous committed result and no partial summary.

## Explicitly out of scope

- **More production R10/IMU activation changes.** App sequence is physically complete; protocol reference is missing.
- **Official WHOOP protocol capture** unless the user separately authorizes/provides the official app/account and capture setup. Never open Passwords or ask Claude to infer credentials.
- **SpO₂ approximation or reverse-engineering.** No simultaneous independent oximeter corpus exists.
- **SWS-HRV wiring.** There are no motion-validated stage nights; never use HR-only estimated stages to select an HR-derived HRV window.
- **Further graph polish.** Handoff 7 is shipped and physically acceptable.
- **Sleep/nap ownership changes.** Physically correct on Aug 11/12.
- TestFlight.

## Focused validation

Use the `AtriaTests` scheme, parallel testing off, one simulator worker. Start with:

```text
AtriaActivitySectionsCacheTests
AtriaHistoricalJSONLRecentScannerTests
AtriaHistoricalArchiveCatalogTests
AtriaHistoricalAggregateReaderMemoryWindowingTests
AtriaSwiftUIPerformanceAuditTests
AtriaRecoveredDataPublicationFenceTests
AtriaRecoveredDataMutationTransactionTests
AtriaRelativeSkinSignalTests
AtriaExperimentalSensorCopyTests
AtriaBLERecoveryCadenceTests                  # only if checkpoint 2 changes code
AtriaBackgroundDrainBacklogTests              # only if checkpoint 2 changes code
```

Add focused suites for any new HR index/store and relative-skin summary store. Prefer behavioral tests over source-string assertions.

Use a guarded temporary symlink to `/Users/amanpandey/projects/atria/evidence` only when a selected test truly needs the gitignored corpus. Hash a null-delimited evidence manifest before/after, verify equality, and remove the exact symlink with a trap.

Then run changed-file Swift parse, `git diff --check`, and a signed physical-device build. Do not weaken data-authority or archive-integrity tests for performance.

## Physical acceptance through Computer Use

Use iPhone Mirroring (`com.apple.ScreenContinuity`) directly. Taps routed in this handoff; retry before using fixture-only claims.

1. Activity → `TUE, AUG 11` → Heart rate, with no tab toggle. Record cold and warm time-to-terminal plus diagnostic receipt.
2. Activity current day HR/Stress: live tail, real gaps, marker band, and rows remain correct.
3. Vitals → Sleep: redesigned chart remains intact; no regression work.
4. Vitals → relative skin section: show the exact blocker/progress or qualified experimental result; validated temperature remains blank.
5. Observe the 30-minute history-convergence window and live-HR continuity.
6. Confirm stable PID and no crash, jetsam, watchdog, reconnect storm, false Bluetooth-off, or CCCD churn.

Do not start a workout, force a BLE reconnect, change system Bluetooth, or operate any enclosure/appliance for this pass.

## Commit, push, and issue hygiene

Prefer two commits:

1. `Bound Activity historical heart-rate window reads`
2. `Publish blocker-first relative skin summaries`

Add a third only if the 30-minute measurement proves and motivates one small drain-throughput correction.

Author and committer: `adidshaft <adidshaft@gmail.com>`. No Claude/Codex/AI trailer. Push only to `origin/codex/whoop-remaining-product-gaps` as a clean fast-forward. No TestFlight.

Update:

- [#35](https://github.com/adidshaft/atria/issues/35): before/after timings, scan stats, design, tests, physical terminal screenshots. Close only when the exact real-day latency criteria pass.
- [#21](https://github.com/adidshaft/atria/issues/21): 30-minute backlog/frontier result and step/motion truth. Do not reopen app-side R10 work; keep protocol/reference capture separate.
- [#31](https://github.com/adidshaft/atria/issues/31): relative-skin producer/result/blocker. Keep absolute skin and SpO₂ validation issue open.
- [#5](https://github.com/adidshaft/atria/issues/5): only the old-day HR latency closure if still useful; do not add more chart churn.
- [#33](https://github.com/adidshaft/atria/issues/33): only if the physical window adds stability/regression evidence.

## Final report

Return:

- Exact commits, clean status, and remote parity.
- Historical-HR before/after cold/warm latency and selected/scanned file/byte/line counts.
- Proof that returned points/empty truth and real gaps are unchanged.
- 30-minute frontier slope, net lag change, HR continuity, and connection/process counters.
- Relative-skin state: qualified value, building baseline count, incomplete archive, or concrete blocker.
- Focused test counts and any untouched pre-existing failure.
- Physical screenshots of old-day HR terminal and relative-skin state.
- Confirmation that app-side R10 logic, SpO₂, stage ratios, user sleep records, dirty main checkout, and evidence corpus were untouched.
