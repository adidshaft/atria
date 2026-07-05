# docs/26 — Product-Quality Pass (perf, connection honesty, Vitals unification, scroll traps, workout false-positives)

Date: 2026-07-06. Follows docs/24 (product audit) and docs/25 (remaining-work
specs). Triggered by an owner report that the live app "lags badly, shows little
useful info, auto-detection unreliable, auto-connect poor, opening screen looks
broken, some screens don't scroll, UI feels flaky."

Method: a read-only root-cause audit fanned out across five subsystems (perf,
BLE, workout-detection, scroll/IA, metric coverage), then targeted fixes. Key
framing insight — **the simulator renders every screen cleanly**, so the reported
brokenness is on-device / logic / perf, not sim rendering. Fixes are in code.

Gates (all green): `python3 test_handoff_static_checks.py` → OK (128);
`xcodebuild -scheme Atria … build` → BUILD SUCCEEDED; full unit suite on sim
`45242AD1…` → TEST SUCCEEDED; sim fixture screenshots for the visible changes.

## Shipped

### 1. Performance — the scroll "hang"/lag root cause (AtriaTodayScreen.swift)
- **Synchronous disk I/O in `body`**: `weeklyPlan` called `WeeklyPlanStore().currentPlan`
  (disk read + generate + atomic write on a cache miss) from a computed property
  read every `body` eval — i.e. on every quantized scroll step and every ~750ms
  live tick. Invisible in the sim (no saved plan file, no scroll-under-load);
  brutal on a device with a real rollup file. Now memoized behind
  `store.dailyRollupHistoryRevision` (runs at most once per rollup change).
- **`coachPayload`** (sorts + ISO/weekday-formats the last-7 rollups) memoized
  the same way. (`weeklyReport` was already lazy inside its `.sheet` closure.)
- **Hero scroll-shrink isolation**: `heroShrinkProgress` @State + the
  `.onScrollGeometryChange` observation moved out of the giant `AtriaTodayScreen`
  body into the small `AtriaTodayHeroShrink` child that owns them. Previously
  every quantized scroll write re-evaluated the entire Today body (ring, glance
  grid, plan/coach cards). Completes the isolation commit 28797998 started.

### 2. Vitals ↔ Today data unification (AtriaHealthScreen.swift)
The Health Monitor rows read ONLY persisted daily rollups, while Today renders
the live hero estimate; today's rollup row is intentionally unpersisted until a
settled morning reading (frozen-chart invariant). Result: Today showed 72% / 8h
while Vitals showed "Building" / "--". Fix: Recovery / RHR / HRV / Sleep rows now
fall back **read-only** to the same live hero snapshot (and latest sleep night)
when today's rollup isn't persisted, honestly labeled "today · estimate". Nothing
is persisted, so the frozen-chart invariant is untouched. Verified: RHR "--"→"60 bpm",
HRV "--"→"Learning".

### 3. Connection-state honesty (AtriaHomeView.swift `AtriaTopStatusChip`)
- **False green "Live" after a real disconnect**: the `.connected` upgrade rode
  on `hasPulseSignal`, true for up to 180s off a stale value. Now, when the
  radio `status` is `.disconnected`, the chip only stays "Live" while the pulse
  is genuinely fresh (`hasFreshPulseSignal`, a reading within ~15s via
  `CoreLiveState.lastReadingAt`). Still heals the legitimate state-restoration
  case. NEEDS on-device confirmation of the resolve timing.
- **"Disconnected" recolored** blue → neutral gray (idle, never-connected) /
  yellow (actively reconnecting), restoring the red/yellow/green severity
  language. Verified in sim.

### 4. Scroll traps (5 sheets wrapped in ScrollView)
Set-logger sheet (fixed 390pt, "Save set" clipped off-screen — now
`[.height(390), .large]` + ScrollView), workout target-picker, metric
target-editor, metric zone/info sheet, experimental-sensors info sheet.

### 5. Workout false-positive reduction (Sessions.swift)
`bestReviewWorthyCandidate`'s `moderateStrengthReviewCandidate` branch returned
review-worthy on HR thresholds alone — no contact-qualified-evidence gate,
unlike its sibling `nearMiss` branch — so ordinary daily HR elevation (stairs, a
stressful meeting) could surface a "review this workout?" prompt. Now requires
`bestContactQualifiedLongestBout > 0`, matching the nearMiss gate.

### 6. IA + diagnostics
- `onOpenCollection` set `selectedTab = .collection`, a tag the TabView doesn't
  contain (blank tab) → now opens the strap `fullScreenCover` like the deep-link
  handler and topChrome.
- Added `ATRIADBG ble_link … powered_on_precheck` branch logging
  (`no_saved_uuid` / `retrieve_empty` / `already_connected`) so
  "auto-connect not working" is diagnosable from the connection timeline.

## Still missing / needs data or on-device verification
- **RR-gated auto-COUNT** (workout finding #1/#2): only auto-count a workout
  (rollup.workouts + orange "Auto" chip) when contact-qualified-RR-backed, else
  route stream-only-`ready` sessions to user review. Higher value but changes
  the accuracy engine's classifications — needs real on-device false-positive
  data to tune and full-suite/test migration; do NOT change blind.
- **OS-level auto-reconnect** (`CBConnectPeripheralOptionEnableAutoReconnect` on
  saved-strap connects): strengthens reconnect but changes OS behavior — must be
  verified on-device against the paced-watchdog constraint before shipping.
- **Metric trends expansion**: extend the primary Trends chart to
  recovery/sleep/respiratory; a first-class sleep-target/suggested-bedtime card;
  persisted daily summaries for Stress / VO2 / HR-zones (+ their trend sheets);
  multi-night sleep-stage trend. Several need weeks of accumulated daily
  summaries before a trend can honestly render.
- **Sensor-limited**: SpO2 is permanently unavailable on this strap; steps stay
  honest-dead (IMU never decoded). These keep their "not available" states.

## Standing notes
- Three static-check pins migrated in lockstep (displayStatus case split,
  disconnected tint, set-logger detent) with dated comments.
- The dual Today layout systems (docs/25 C1) remain unconsolidated — still
  change BOTH `AtriaTodayMetric` CSVs and `AtriaHomeLayoutConfig.glanceMetrics`.
