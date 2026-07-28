# WHOOP 4.0 Protocol and Behaviour Notebook

This is Atria's living, append-only notebook for WHOOP 4.0 ("Harvard") protocol work. It records the wire protocol, physical strap behaviour, failed approaches, and the evidence behind conclusions. New experiments must be appended to the experiment log even when they fail.

Last updated: 2026-07-28 (Asia/Kolkata)

## Evidence labels

- **PHYSICAL** — observed on the current WHOOP 4.0, physical iPhone, and Atria build. This is the highest-confidence evidence for this product.
- **REFERENCE** — corroborated by primary implementation/reference code, currently `ryanbr/noop` and its `WhoopProtocol` package, but not necessarily reproduced on this exact strap.
- **CODE** — verified in Atria source or tests; it does not count as a physical product pass.
- **HYPOTHESIS** — plausible interpretation that still needs a controlled physical test.

No inference, archived row, unit test, or code structure is promoted to a physical pass.

## 2026-07-28 — exact-window sleep respiration survives confirmation

**PHYSICAL INPUT + CODE**

- The July 28 device pull contains dense standard-2A37 RR evidence across the
  00:45–04:23 sleep review window. The live qualified RR snapshot independently
  produced a plausible 10.5 breaths/minute estimate, but the review and
  `UserConfirmedSleep` projection paths discarded respiration by writing
  `nil`.
- Sleep-window respiration is now estimated only inside the candidate or
  confirmed boundaries. It never joins RR across connection-bounded sessions
  or across a greater-than-three-second RR gap; independently continuous runs
  contribute bounded RSA estimates whose median becomes the nightly scalar.
- The optional value is migration-safe and persists through review,
  confirmation, adjustment, session compaction, physiological-day projection,
  and `SleepHistorySnapshot`. Legacy confirmed-sleep rows decode with no
  respiration instead of inventing one.
- The focused respiratory tests and the complete sleep-audit regression suite
  pass (38/38). This remains **CODE**, not a physical output pass, until the
  current review is settled and the value is observed after an in-place install
  and relaunch.
- **Evidence:** `evidence/2026-07-28-current-metric-audit/full/` and
  `Test-AtriaTests-2026.07.28_11-59-23-+0530.xcresult`.

## 2026-07-28 — resumed morning sleep remains a separate segment

**PHYSICAL INPUT + CODE**

- The physical July 28 stream contains a qualified 00:45–04:23 main-sleep
  review, tiny ambiguous 05:58 and 06:17 fragments, and a separate dense
  08:33–10:42 low-HR/qualified-RR segment. The earlier pipeline clustered the
  latter three records, then rejected the cluster because its 114-minute
  internal gap exceeded the safety ceiling.
- A substantial later-morning segment may now become a
  `resumed_sleep_candidate` only when a review-worthy main sleep exists in the
  same physiological morning, the separation is at least 90 minutes, the
  segment ends before noon, HR and qualified RR are dense, robust HR gates are
  low, and workout evidence is absent. It is review-only and cannot
  auto-confirm.
- The primary main-sleep review is always settled first. A resumed candidate is
  queued separately afterward. Confirmation persists a distinct
  `resumed_sleep` record; it cannot extend, replace, or delete the main record.
  Cycle presentation sums only the observed segment durations, so the
  04:23–08:33 awake gap receives zero sleep credit.
- The sequential Audit + ReviewCache suite passes 75/75, including the actual
  durable confirmation path and negative no-prior-main/active-tail controls.
  Physical UI verification remains pending an in-place install and settlement
  of the current main review.
- **Evidence:** `evidence/2026-07-28-current-metric-audit/full/` and
  `Test-AtriaTests-2026.07.28_12-16-14-+0530.xcresult`.

### Physical correction after settling the main sleep

- **PHYSICAL failure:** confirming 00:45–04:23 correctly wrote both the
  confirmed main sleep and its durable settled/dismissed detector window, but
  that main-window dismissal also prevented the separate 08:33–10:42 segment
  from reaching the review card.
- **CODE correction:** a confirmed overlap may unlock only a same-cycle
  `resumed_sleep_candidate` even when the main detector window is settled. The
  resumed candidate still passes its own `isUnsettled` check, so dismissing the
  resumed window remains final and no older ordinary sleep candidate can leak
  through.
- **TEST evidence:** the exact confirmed-plus-dismissed physical main now
  queues the 08:33–10:42 tail, while a separately dismissed tail returns no
  review. The sequential Audit + ReviewCache suite passes 75/75 in
  `Test-AtriaTests-2026.07.28_12-34-32-+0530.xcresult`.
- **PHYSICAL acceptance:** signed Release commit `e15ecce2` was installed in
  place with data and pairing preserved. Atria retained the main sleep as
  3h38m and displayed a distinct “Possible sleep” card for 08:33–10:42 (2h09m).
  The 04:23–08:33 awake interval was not added to sleep duration.
- **Evidence:**
  `evidence/2026-07-28-resumed-sleep-physical/resumed-sleep-card.png` and
  `evidence/2026-07-28-resumed-sleep-physical/fixed-live-state/`.

## 2026-07-27 — sleep respiratory provenance boundary

**CODE + PHYSICAL PERSISTENCE**

- Qualified RR provenance and nighttime clock position are not sufficient to
  call a respiratory value a “sleep average.” The current device had repeated
  contaminated rollups on July 26 and 27 even though both authoritative daily
  metrics had no sleep duration, interval, source, or respiratory value.
- `sleepRespiratoryRate` now requires explicit sleep-research or detected-sleep
  evidence; wall-clock time alone is rejected.
- A session-derived respiratory fallback can enter a daily rollup only when
  the saved daily metric has a positive sleep duration, a valid start/end
  interval, and a nonempty sleep source. A respiratory value already persisted
  by the qualified sleep pipeline is preserved.
- After installing the fix, both affected physical-device rollups contain
  `respiratoryRate: null` and no respiratory baseline. Confirmed-sleep and
  sleep-research fixtures continue to pass.
- **Evidence:** `evidence/2026-07-27-respiratory-truth/acceptance.md`

## 2026-07-27 — restored gyro-step evidence identity

**CODE**

- Active-session journals intentionally encode the research gyro step field as
  optional: `nil` means the legacy journal never observed validated gyro
  cadence, while `0` can mean a validated observation containing zero steps.
- Restore preparation previously collapsed both states to integer zero and
  later tested that nonoptional integer as if it could still be `nil`. The
  restored UI therefore always published `r10_live_validated`, including for
  legacy journals with no gyro evidence.
- `ResearchAggregates` now carries a separate
  `hasGyroCadenceResearchEvidence` bit derived from the persisted optional
  field. Restore seeds still use the safe numeric zero, but publication remains
  `research_unvalidated` unless the journal genuinely contained gyro evidence.
- This affects evidence labeling only; it does not introduce phone-motion
  fallback or promote research counts into authoritative user-facing steps.

## Device and test context

- Strap generation: WHOOP Strap 4.0 / Harvard.
- Client: physical iPhone over CoreBluetooth.
- Atria framing implementation: `Atria/Atria/FrameParser.swift`.
- Atria command identifiers: `Atria/Atria/AtriaBLESchema.swift`.
- Current acceptance order: locked reconnect, exact historical recovery, manual workout reliability, strap-only steps/motion, then automatic detection/strain.

## Current physical acceptance ledger

This table is the authoritative current status. Earlier failed experiments
remain in the append-only log below, but do not override a later physical pass.

| Gate | Current result | Authoritative evidence |
|---|---|---|
| 1 — locked reconnect | **PASS — sealed** | `evidence/2026-07-26-gate-1-accepted.md` |
| 2 — exact historical recovery | **PASS — sealed** | `evidence/2026-07-28-gate2-generation-fix/terminal-physical/acceptance.md` |
| 3 — manual workout reliability | **PASS — sealed** | `evidence/2026-07-28-gate3-manual-workout/acceptance.md` |
| 4 — strap-only steps and motion | **PASS — sealed** | `evidence/2026-07-27-gate4-final-110-step/ACCEPTANCE.md` |
| 5 — automatic detection and strain | **PASS — sealed** | `evidence/2026-07-27-gate5-physical-positive/acceptance.md` |

Gate 2 chronology matters: the first 162-second controlled outage remained at
0/163 target seconds and correctly failed. The later controlled gap advanced
the strap through the requested interval, durably covered 114/115 expected
seconds (99%; every whole-second position present), survived two real
transport drops, and therefore superseded that earlier failure. Gate 2 is not
being inferred from archived rows or code structure.

## Harvard frame format

**REFERENCE + CODE**

WHOOP 4.0 uses this envelope:

```text
AA | length:u16 little-endian | CRC8(length bytes) | inner payload | CRC32(inner payload):u32 little-endian
```

- `length` is `inner payload byte count + 4`, where the four bytes are the trailing CRC32.
- CRC8 uses polynomial `0x07`, initial value `0x00`, over the two length bytes.
- A command inner payload is:

```text
23 | sequence:u8 | command:u8 | command payload...
```

- `0x23` is the command packet type.
- The sequence byte changes per command.
- CRC32 covers only the inner payload.

Atria's `encodeFrame(_:)` implements this exact layout.

## Relevant commands

| Hex | Decimal | Meaning | Payload used | Confidence and notes |
|---|---:|---|---|---|
| `0x03` | 3 | Toggle realtime HR | `01` on, `00` off | **REFERENCE + PHYSICAL.** Standard live-HR arming. Combining it with `0x3F/01` did not keep the high-bandwidth motion stream alive on this link. |
| `0x0A` | 10 | Set strap clock | firmware-dependent timestamp body | **REFERENCE + PHYSICAL history work.** Mutating; never use casually. |
| `0x0B` | 11 | Get strap clock | read request | **REFERENCE + PHYSICAL history work.** |
| `0x14` | 20 | Abort historical transmission | command-specific | **REFERENCE + PHYSICAL history work.** Stops an active history serve. |
| `0x16` | 22 | Send historical data | cursor/range body | **REFERENCE + PHYSICAL history work.** Requests the strap's banked records. |
| `0x17` | 23 | Historical data result/ack | result/cursor body | **REFERENCE + PHYSICAL history work.** History transaction acknowledgement. |
| `0x1A` | 26 | Get battery level | read request | **REFERENCE + PHYSICAL.** |
| `0x22` | 34 | Get data range | read request | **REFERENCE + PHYSICAL history work.** Reads available history bounds. |
| `0x3F` | 63 | Send R10/R11 realtime | `01` on, `00` off | **REFERENCE + PHYSICAL.** Controls the heavy type-43 realtime stream. `STOP_RAW_DATA` does not stop this stream. |
| `0x51` | 81 | Start raw data | `duration_ms:u32 LE` | **REFERENCE.** Original WHOOP 4 app/decompile research identifies this as a timed capture. The newer NOOP wrapper's `[01]` body is an outdated stub and is now retired in Atria. |
| `0x52` | 82 | Stop raw data | `01` | **REFERENCE + PHYSICAL TRANSMISSION; behavior not independently isolated.** Atria physically sent it during bounded-lease teardown. It did not stop `0x3F`; `0x3F/00` remains the verified master switch for that stream. |
| `0x6A` | 106 | Toggle IMU mode | `01` on, `00` off | **REFERENCE + PHYSICAL.** `0x6A/01` physically opens type-43 delivery. `0x6A/00` alone is not a proven master stop; it must not be treated as a successful production transport. |

## Streams and records

### Live HR

**PHYSICAL**

The lightweight standard Heart Rate Service characteristic (`0x2A37`) can continue delivering accepted HR without a sustained type-43 raw-motion stream. Gate 1 proved automatic locked reconnect across three real out-of-range/return cycles.

### Type 43 / R10-R11 realtime

**REFERENCE + PHYSICAL**

`0x3F/01` enables a high-bandwidth raw stream. On the current iPhone/strap link, Atria received either a short burst or one 1,920-byte R10 frame and CoreBluetooth then reported timeout error 6 roughly 6–7 seconds later. This behavior occurred while stationary too, so walking itself is not the cause.

### Type 47 historical

**PHYSICAL + REFERENCE**

- WHOOP 4.0 history has firmware-dependent layouts; v24 and v25 must not be conflated.
- The current strap has yielded v25, 84-byte motion-oriented rows.
- Atria currently reads the v25 gravity tail at byte offsets 69, 71, and 73.
- The observed v25 motion arrives as sparse bursts (approximately 38 seconds around every 20 minutes in the inspected archive), not continuous workout-rate motion.
- Therefore these rows help sleep/activity context but are not presently sufficient to claim exact workout steps.

## WHOOP 4.0 step capability

**REFERENCE + PHYSICAL CONSTRAINT**

The inspected NOOP implementation and documentation state that WHOOP 4.0 does not expose a native cumulative step counter. NOOP estimates WHOOP 4 steps from banked strap motion and calibrates that estimate against an external step source.

Atria's acceptance constraint is stricter:

- WHOOP/R10 strap motion only.
- No `CMPedometer`, phone fallback, imported phone count, or fabricated/estimated display.
- Accuracy must be measured against manually counted controlled walks.

Consequently, Gate 4 requires a stable strap raw-motion capture plus a physically calibrated detector. Sparse v25 history alone is not a substitute.

## Experiment log

### 2026-07-26 — `0x3F/01` plus `0x6A/01`

- **Setup:** Manually counted 136-step/90-second walk.
- **Expected:** Continuous strap motion for the workout while HR and connection remain healthy.
- **Observed:** About 11 seconds of useful motion, 15 preliminary steps, then link timeout.
- **Result:** **FAIL.**
- **Conclusion:** This pairing is not a stable production motion lease on the current iPhone/strap.

### 2026-07-26 — `0x3F/01` only

- **Setup:** Manually counted 113-step walk, with history-preemption retry fixed.
- **Expected:** Sustained R10 stream.
- **Observed:** UI remained “Motion syncing”; HR coverage was 95% and workout saved, but sustained raw motion was absent.
- **Result:** **FAIL.**
- **Evidence:** `evidence/2026-07-26-gate4-strap-steps/r10-only-113-step-failed-rerun/acceptance.md`

### 2026-07-26 — `0x3F/01` plus `0x03/01`

- **Setup:** Manually counted 136-step/90-second walk, then stationary reproduction.
- **Expected:** NOOP-style live arming would sustain type-43 frames.
- **Observed:** One 1,920-byte R10 frame, then CoreBluetooth timeout error 6 about six seconds later. Stationary reproduction behaved the same. Live HR recovered.
- **Result:** **FAIL.**
- **Conclusion:** Missing realtime-HR arming was not the cause; the high-bandwidth link itself is marginal/unstable in this state.
- **Evidence:** `evidence/2026-07-26-gate4-strap-steps/reconnect-retry-136-step-failed-rerun/acceptance.md`
- **Raw example:** `evidence/2026-07-26-gate4-strap-steps/reconnect-retry-136-step-failed-rerun/full-pull/Documents/atria-step-calibration/strap-imu-20260726-1785077127411-30afec9a.csv`

### 2026-07-26 — bounded raw pair `0x51/01` plus `0x6A/01`

- **Source:** NOOP's bounded `captureRawAccel` path sends `START_RAW_DATA`, then `TOGGLE_IMU_MODE`, and sends `STOP_RAW_DATA` when the window ends.
- **Atria change:** Workout motion activation now uses the same bounded pair and sends `0x52/01` on lease release.
- **Code verification:** Focused cadence/sequence tests pass.
- **Physical setup:** 43-second stationary Walking workout on the physical iPhone/strap.
- **Observed:** Direct lease activation occurred first. The protected per-link activation was recorded at Unix `1785078401.247878`; one R10 receive instant followed at `1785078403.241202`, with two IMU/R10 protocol frames total. The link disconnected at `1785078411.365226` with `CBErrorDomain:6`. Atria recovered HR and saved the workout, but the UI remained `Motion syncing` and did not claim steps.
- **Physical result:** **FAIL.**
- **Conclusion:** `0x3F` is not the sole cause. Both the realtime-raw and bounded-raw command families can start valid R10 delivery and then provoke the same quick timeout on the current Atria/iPhone transport.
- **Evidence:** `evidence/2026-07-26-gate4-strap-steps/bounded-raw-stationary-soak/acceptance.md`

### 2026-07-26 — implementation comparison after bounded-raw failure

- **REFERENCE:** NOOP sends WHOOP 4 commands to characteristic `61080002…` using CoreBluetooth `.withoutResponse`; Atria does the same.
- **REFERENCE:** NOOP runs its `CBCentralManager` delegate on `.main`.
- **CODE:** Atria runs CoreBluetooth on a private serial queue with `.utility` QoS and moves publication to the main actor. R10 decoding and step detection are already offloaded to a separate serial utility queue.
- **HYPOTHESIS:** Delegate scheduling/connection ownership remains a meaningful difference, but it is not yet proven to cause the controller-level `CBErrorDomain:6`. A controlled transport-only build is required before changing production ownership or reopening Gate 1.
- **CODE:** Atria still contains older leased recovery paths that can issue `0x3F/01 + 0x6A/01`. They must be prevented from overlapping a bounded `0x51 + 0x6A` workout experiment; otherwise command-family attribution is not clean.
- **Next controlled experiment:** enforce one motion-command owner per connection, persist every transmitted opcode and timestamp, disable all older R10 repair writes during an active bounded workout lease, and rerun the stationary soak before another counted walk.

**Superseded:** the controlled main-queue transport comparison was subsequently
completed and failed identically, ruling delegate-queue choice out. Do not
reopen Gate 1 from this historical hypothesis; use the later physical Gate-1
acceptance and command-owner findings below.

### 2026-07-26 — original protocol trace corrects `START_RAW_DATA`

- **REFERENCE:** `johnmiddleton12/my-whoop`'s protocol-completeness matrix states that command `0x51` takes a timed `<u32 milliseconds little-endian>` body and explicitly calls the older one-byte body wrong.
- **REFERENCE:** The production GEN_4 ordering enables `TOGGLE_IMU_MODE` before beginning raw capture.
- **Finding:** The failed Atria experiments sent `51 01` followed by `6A 01`, copied from a newer NOOP convenience wrapper. That was neither the correct payload shape nor the correct order.
- **CODE change:** Atria now sends `6A 01`, then `51` plus a six-hour `u32 LE` duration (`00 97 49 01`), and still sends `52 01` at workout release.
- **CODE change:** The older `3F + 6A` short-burst retry is suppressed while a bounded workout motion owner exists.
- **Physical result:** **FAIL.** In a 39-second stationary workout, the corrected sequence still dropped HR, reconnected, produced two R10 frames at one receive instant, and hit `CBErrorDomain:6` about eight seconds later. HR recovered and no steps were fabricated.
- **Evidence:** `evidence/2026-07-26-gate4-strap-steps/correct-timed-raw-stationary-soak/acceptance.md`
- **Next experiment:** Isolate `0x6A/01` and `0x51/duration` into separate physical tests. Do not infer which opcode causes the controller timeout from another paired run.

### 2026-07-26 — `0x6A/01` isolated

- **Setup:** Debug-isolated stationary workout sent only `TOGGLE_IMU_MODE 6A/01`; `START_RAW_DATA` and the legacy `3F + 6A` retry were suppressed.
- **Observed:** Two valid R10 receive instants spanning about four seconds, then `CBErrorDomain:6` about five seconds after the last frame. HR recovered.
- **Result:** **FAIL.**
- **Conclusion:** Sustained IMU mode alone reproduces the transport timeout. `0x51` is not necessary.
- **Additional finding:** Workout teardown sent `STOP_RAW_DATA 52/01` but did not send `TOGGLE_IMU_MODE 6A/00`. Because `0x6A` is independently capable of opening the failing stream, teardown was incomplete.
- **Evidence:** `evidence/2026-07-26-gate4-strap-steps/imu-only-stationary-probe/acceptance.md`
- **Next experiment:** Pulse `6A/01`, collect the initial valid frames, send `6A/00` before the measured timeout, and verify the BLE/HR link survives. If it does, measure the maximum safe duty cycle before attempting step accuracy.

### 2026-07-26 — three-second IMU pulse with `0x6A/00`

- **Setup:** `6A/01`, wait three seconds, then `6A/00`; no `0x51`, no workout legacy retry.
- **Observed:** Two R10 frames/one receive instant, then `CBErrorDomain:6`; HR recovered.
- **Result:** **FAIL.**
- **Interpretation:** `0x6A` selects IMU mode, but it is not independently proven to stop the underlying type-43 flood. The verified master switch is `0x3F/00`.
- **Evidence:** `evidence/2026-07-26-gate4-strap-steps/imu-three-second-pulse/acceptance.md`
- **Next experiment:** End each pulse with `6A/00` followed by `3F/00`, persist both transmit timestamps, and require the connection to survive beyond the prior timeout window.

### 2026-07-26 — three-second IMU pulse with `0x6A/00` and `0x3F/00`

- **Setup:** Stationary workout; send `6A/01`, wait three seconds, send
  `6A/00`, wait 120 milliseconds, then send the verified master flood stop
  `3F/00`. Do not send `51`.
- **Observed command timing:** First R10 frame at Unix
  `1785079399.764635`; `6A/00` sent at `1785079399.780971`; `3F/00` sent at
  `1785079399.907011`.
- **Observed link behavior:** CoreBluetooth disconnected at
  `1785079408.885593` with `CBErrorDomain:6`, about 8.98 seconds after the
  master stop. Live HR recovered by `1785079411.020755`.
- **Result:** **FAIL.**
- **PHYSICAL conclusion:** Once `6A/01` opened type-43 delivery on this
  connection epoch, neither the immediate IMU-off write nor the verified
  master flood-stop write prevented the controller timeout.
- **Confound:** The persisted battery level crossed from 26% to 25% during
  the run. The same transport sequence must be repeated above the
  high-frequency-motion battery floor before attributing the failure solely
  to command semantics or the iOS transport.
- **Evidence:**
  `evidence/2026-07-26-gate4-strap-steps/imu-pulse-with-flood-stop/acceptance.md`

### Low-battery motion contract

**CODE + PHYSICAL REQUIREMENT**

- The physical 25% run proves that a stale pre-command eligibility decision
  can become unsafe when the battery crosses the warning boundary during
  asynchronous profile setup.
- High-bandwidth motion eligibility must therefore be checked again at the
  exact command boundary, not only when the lease or discovery begins.
- At low battery Atria must preserve HR and the durable workout first. It may
  use a physically proven lower-duty or banked strap-motion path, but it must
  never fabricate steps or silently present sparse motion as complete.
- Charging above the threshold is a control experiment, not the intended
  product workaround.

### 2026-07-26 — post-gym passive R10 behavior

- **Physical workout:** The saved manual workout spans 3,255.86 seconds and
  contains 3,295 accepted 2A37 HR samples, zero accepted-HR gaps, zero zero-HR
  rows, and zero artifact drops. Manual workout integrity remained intact.
- **Motion during workout:** Only two frames over 21.94 seconds and three
  frames over 18.02 seconds were archived in two isolated live bursts. This is
  not continuous step authority and the workout correctly retained zero
  published segment steps.
- **Fresh passive connection after workout:** With no motion activation
  recorded for that connection epoch, the strap immediately resumed R10 and
  delivered 69 CRC-valid frames across 68.43 seconds. Device timestamps were
  current and advanced by 66 seconds, ruling out historical replay.
- **Link result:** The passive connection lasted 74.93 seconds, then ended with
  `CBErrorDomain:6`; the final R10 frame preceded the disconnect by 5.59
  seconds.
- **PHYSICAL conclusion:** The activating write is not required on every
  connection. Motion mode persists on the strap and can resume passively on a
  fresh epoch. However, continuous type-43 traffic itself remains correlated
  with controller timeout, even on a connection that sent no activation.
- **Low-battery defect:** A persisted seven-day calibration lease was still
  active and overrode battery protection. Calibration transport authority is
  now bounded to 30 minutes, retained evidence remains seven days, and
  calibration no longer bypasses the low-battery HR-protection gate.
- **Legacy-state migration:** On launch, any stored calibration deadline that
  exceeds the requested 30-minute attended window is deleted rather than
  clamped or inherited. This removes the old seven-day radio authority while
  preserving the separately retained raw evidence files.
- **Evidence:** `evidence/2026-07-26-post-gym-workout/full-pull/`

### 2026-07-26 — deterministic idle-link churn and peripheral lifetime

**PHYSICAL BASELINE + CODE FIX; GATE-1 OUTCOME PASSED, ISOLATED 722 PROOF PENDING**

- A 150-second pre-fix device capture contained six
  `API MISUSE: Forcing disconnection of unused peripheral` events. Each maps
  one-for-one to a Bluetooth reason-722 teardown about 1.4 seconds after a
  healthy 30 ms connection.
- The reconnect fast lane called `central.connect` on the callback peripheral
  without first giving that exact `CBPeripheral` object a durable strong
  owner. CoreBluetooth does not retain it for the app; a later MainActor
  reassignment could therefore deallocate the live object and force the link
  down without traversing any instrumented `cancelPeripheralConnection` site.
- `AtriaBLEConnectedPeripheralRetainer` now retains by object identity, not
  strap UUID. UUID-keyed retention is unsafe because CoreBluetooth may vend
  more than one object instance for the same physical strap.
- The same baseline also shows the strap requesting a 250–1000 ms interval
  with a four-second supervision timeout after reconnect. The request was
  accepted by iOS, followed roughly 13–16 seconds later by reason-708
  supervision timeout. This is a separate population from the app-owned 722
  teardown.
- The earlier “30% packet failure” conclusion was a counting error: the four
  `No-Sync / Packet Type: None` slots were empty post-disconnect buffer slots,
  not in-link losses. In-link samples were normally 26 consecutive `Good`
  receptions with SNR 33–40 dB and RSSI around −66 dBm up to the drop.
- **Outcome:** the later combined reconnect build physically passed three
  locked out-of-range → return cycles (Gate 1). That proves end-to-end locked
  recovery on a build containing this retention fix. It does not, by itself,
  isolate this change as the sole cause: no saved post-fix bluetoothd capture
  proves a zero reason-722 population. The strap-requested slow-interval 708
  population remains separate and must not be hidden by aggregate disconnect
  counts.
- **Evidence:** `evidence/2026-07-26-baseline/`
- **Post-fix scorer:** `tools/analyze_link_lifetime.py`

### Official GEN4 compact-motion candidate

**REFERENCE; NOT YET PHYSICALLY QUALIFIED**

- The inspected original app-reversal notes distinguish WHOOP Labs raw capture
  from normal GEN4 operation.
- `START_RAW_DATA 0x51` is used by the opt-in Labs/DWL raw-capture path, not
  normal continuous GEN4 collection.
- The observed normal GEN4 realtime sequence is:
  `TOGGLE_REALTIME_HR 03/01` → `TOGGLE_IMU_MODE 6A/01` →
  `ABORT_HISTORICAL_TRANSMITS 14/00`.
- The observed transient full live-sensor view additionally pairs
  `TOGGLE_IMU_MODE 6A` with `TOGGLE_OPTICAL_MODE 6C`; that higher-airtime
  profile is not the first candidate for steps.
- Atria has tested `6A` alone and several `3F`/`51` combinations, but it has
  **not** tested the complete compact-HR/IMU/history-abort sequence above.
- **Next controlled test:** diagnostic-only exact sequence, adequate battery,
  stationary phone and strap, no history owner, no `3F`, no `51`, and require
  at least 90 seconds of current-timestamp motion with live HR and no BLE
  disconnect before any counted walk.

#### First stationary execution — invalidated by app-owned repair

**PHYSICAL; COMMAND DELIVERY PROVEN, CANDIDATE RESULT UNPROVEN**

- The debug lease armed at Unix `1785087327.809`. CoreBluetooth received the
  exact three writes at 23:05:34.056, 23:05:34.178, and 23:05:34.305.
- Atria's guided-calibration stale-stream repair independently called
  `cancelPeripheralConnection` at 23:05:34.853, only 0.55 seconds after the
  final command. The persisted cancellation reason is
  `step_calibration_stale_r10_rebuild`.
- The following pure-HR connection recovered and delivered 50 accepted HR
  samples. It later underwent the already-known strap-requested slow interval
  and reason-708 timeout; that second link never replayed the compact sequence.
- **Conclusion:** this is a binary Gate 4 failure because no 90-second motion
  interval was produced, but it is not evidence that `03/01,6A/01,14/00`
  destabilizes the strap. The app terminated the tested epoch itself.
- The UI-free stationary probe now suppresses only that four-second repair.
  Normal guided calibration keeps it. The identical physical test must be
  rerun before changing commands or asking for a counted walk.
- **Evidence:** `evidence/2026-07-26-gate4-official-compact-stationary/`

### CoreBluetooth delegate-queue difference

**CODE + REFERENCE; CAUSAL ROLE UNPROVEN**

- The inspected reference iOS client constructs `CBCentralManager` with
  `queue: .main`.
- Atria production uses a private serial `.utility` queue and moves decoding
  work away from UI publication.
- Atria has proven that the private queue can reassemble and persist 69
  consecutive 1,920-byte R10 frames, so it is not generically incapable of
  receiving the stream. It has not proven whether iOS scheduling/QoS
  contributes to the later controller timeout.
- A debug-only `--atria-gate4-main-ble-queue` parity switch is available for a
  second controlled run if the exact official sequence fails on Atria's
  production queue. Normal launches and sealed Gate 1 behavior are unchanged.

#### Completed compact-motion and lifetime controls

**PHYSICAL; ALL FAILED**

- Production delegate queue, exact `03/01 → 6A/01 → 14/00`: current R10
  arrived for about three seconds, then `CBErrorDomain:6` and pure-HR fallback.
  No app-owned cancel occurred in the tested epoch.
- Main delegate queue, identical commands: one current R10 frame, then the same
  controller timeout. Delegate scheduling is therefore ruled out.
- NOOP realtime keeper parity, `3F/01 → 03/01` every two seconds: five command
  cycles and one current R10 receive instant, then `CBErrorDomain:6`.
- Command-free passive reconnect after that timeout: the strap reconnected but
  delivered no additional current R10; the next link also timed out. Total
  motion coverage remained far below 90%.
- **Conclusion:** neither compact command ordering, main-queue delegation,
  two-second command keepalive, nor command-free continuation sustains WHOOP 4
  motion on this iPhone/strap. These are failed physical controls, not product
  progress.
- **Evidence:**
  `evidence/2026-07-26-gate4-official-compact-stationary/run-2/`

### Current upstream boundary and next protocol lead

- Current NOOP source explicitly describes WHOOP 4 strap-derived steps as
  deferred; its displayed WHOOP 4 steps come from imported phone health data.
  This does not define Atria's product boundary, but it independently confirms
  there is no known native cumulative-step field in the public implementation.
- NOOP's v25 type-47 decoder exposes a timestamp and one gravity vector, and
  Atria's physical archive shows that stream sparsely. It cannot by itself
  support counted-walk accuracy.
- The remaining protocol-specific lead is command `0x69`
  (`TOGGLE_IMU_MODE_HISTORICAL`): determine whether the official lifecycle uses
  it to bank dense strap motion for later offload, without the unstable
  realtime type-43 flood. Payload and teardown must be established from
  reference code or a read-safe physical probe before product use.

### Historical IMU banking (`0x69`) — stationary transport proof

**PHYSICAL; DENSE BANKED MOTION TRANSPORT PASSED, STEP ACCURACY PENDING**

- Atria sent `69/01` at Unix `1785088867.749055`, kept the strap connected for
  90 seconds without opening realtime raw motion, then sent `69/00` at
  `1785088958.15509`.
- The first normal history request began at an older strap cursor. The exact
  eight-byte time selector was then tested independently: its write was
  confirmed, but the strap returned zero rows for 75 seconds. Atria issued
  `14/00` and retained the failed result. This firmware therefore does not
  provide a usable exact-time selector through that command shape.
- Because this strap was explicitly designated sacrificial, Atria traversed
  the older cursor page-by-page using only CRC-valid page tokens. No ACK was
  fabricated. Two concrete transport races were exposed and fixed:
  a next page-end arriving before the preceding ACK callback, and replay of an
  already-acknowledged page-end after reconnect. The fixes defer exactly one
  new token and ignore only byte-identical acknowledged-token replay.
- The eventual sequential drain recovered **97 raw 96-byte type-47 records**
  in the exact inclusive interval `1785088867...1785088959`.
  All **93/93 seconds** occurred at least once; four seconds had two records.
  Missing seconds: **0**. Temporal coverage: **100%**.
- This passes the banked-motion transport subtest and disproves the earlier
  assumption that type-47 must remain sparse. It does **not** yet pass strap
  step accuracy: the interval was not a controlled counted walk.
- **Evidence:** `evidence/2026-07-26-gate4-historical-imu/`
- **Next binary test:** repeat the same bounded `69/01 → 69/00` lifecycle
  during a counted 90-second walk, drain from the now-advanced cursor, then
  derive and score cadence only from the recovered strap vectors.

#### v24 bytes 88...89 — cumulative motion-tick counter

**PHYSICALLY CONFIRMED AS MOTION, DISPROVEN AS A 1:1 STEP COUNTER**

- The dense v24 rows contain a little-endian `UInt16` at offsets 88...89.
- It remained exactly `23051` through the stationary 93-second `0x69` window.
- The initial raw-clock comparison appeared to match a 132-step walk. Repeating
  the comparison with each row's persisted clock correction removed that
  coincidence: the same 90-second wall-clock window advanced by **146 ticks**
  for 132 counted steps.
- Two more preserved 90-second walks advanced by approximately **150 ticks**
  for 136 counted steps and **154 ticks** for 113 counted steps when aligned to
  the workout end. Their exact user start instants were not durably marked, so
  these are diagnostic correlations rather than acceptance measurements.
- Increments during walking are batches of 1–4 ticks per historical second.
  This is useful strap-owned motion evidence, but the physical ratios prove
  that raw ticks must never be displayed as steps.
- Atria decodes and durably retains the value as `motionTickCounter88`.
  The experimental path that could have promoted its delta as exact steps was
  removed. No CoreMotion or phone-derived fallback is used.
- `AtriaWhoop4MotionTickStepModel` now enforces the publication gate in code:
  a controlled exact-boundary walk plus a zero-tick rest window may fit a
  per-strap scale, but the fit remains unusable until a distinct held-out walk
  and rest window pass at no more than 5% walk error and zero rest steps.
- The independent held-out test below now satisfies that publication gate.

#### Pre-armed counted-walk training point

**PHYSICAL; TRAINING AND INDEPENDENT HOLDOUT PASSED**

- An immediate-on 134-step capture was rejected: its protected interval did not
  include the full wall-clock tail under the then-assumed strap clock offset,
  and the counter stayed flat through a material early interval. It is not used
  to fit or validate the model.
- A second run enabled `69/01` 102 seconds before the saved workout boundary.
  The phone remained stationary. The user counted **132 steps** over a saved
  **91.14-second** Walking workout.
- A correlated, read-only `GET_CLOCK 0B/00` response reported device Unix
  `1785092647` at wall Unix `1785092646`: wall minus device = **-1 second**.
  No clock write, history command, ACK, trim, or mode change was reachable from
  this clock probe.
- At exact corrected workout boundaries, bytes 88...89 advanced from `23392`
  to `23547`: **155 motion ticks**. The preceding exact 60-second rest window
  advanced by **0**, so it contributes zero false steps.
- This fits a WHOOP 4 v24 scale of `1.174242` ticks/step.
- In the distinct held-out **92.02-second** Walking workout, bytes 88...89
  advanced from `23555` to `23715`: **160 motion ticks**. The training-only
  scale predicted **136 steps**, exactly matching the user's independently
  counted **136** (0.0% error). The preceding 60-second rest again advanced by
  0 ticks and published 0 steps.
- Production now opens the low-bandwidth `69/01` bank at a manual workout
  boundary, closes it with `69/00` at workout end, requests history
  asynchronously, re-decodes the retained raw payload, and enriches the saved
  workout only after clock-corrected endpoints and the validation receipt pass.
  Start/End never wait for that offload.
- The run also exposed and fixed two diagnostic/recovery startup defects:
  launch authority was parsed after a restoration-only early return, and
  read-only clock responses were incorrectly placed behind production drain
  generation authority.
- **Evidence:** `evidence/2026-07-27-gate4-prearmed-walk/`

#### 2026-07-27 — product integration exposes mandatory pre-arm

**PHYSICAL; BOUNDARY-ARM FAILED, CONTINUOUS PRE-ARM IMPLEMENTED; FINAL RERUN PENDING**

- A production Walking workout opened `69/01` at its Start boundary and later
  recovered 131 clock-corrected v24 rows spanning the saved interval.
- The v24 motion counter remained exactly `24050` through the interval,
  including the user's brief walking period. The saved workout correctly
  published no steps. A transmitted `69/01` receipt is therefore not evidence
  that motion accumulation is already ready.
- This repeats the previously rejected immediate-on capture and contrasts with
  both accepted counted walks, whose bank was armed well before their exact
  workout boundaries. The 132-step training run had a 102-second lead.
- Production now requests the low-bandwidth historical-motion bank after fresh
  accepted HR, before a workout exists. Manual Start reuses the prepared bank;
  End remains responsive, sends `69/00`, and offloads asynchronously. The
  protected-HR characteristic router permits TX discovery for this bank without
  enabling proprietary notification profiles.
- The first continuous-prearm receipt was persisted at Unix
  `1785094933.149608`. A later excluded no-walk run stopped and drained the
  bank; it re-armed at `1785095166.581136` while preserving live HR.
- Gate 4 requires ordinary walking with no workout as well as labeled workout
  windows. The production path therefore keeps `69/01` prepared from accepted
  HR even when no workout exists. A bounded hourly checkpoint sends `69/00`,
  closes the durable coverage interval, and starts the existing asynchronous
  history drain. A five-second re-arm fence prevents the next one-Hz HR packet
  from reopening the bank before the history owner takes the transport.
- Daily v24 reduction is isolated to the currently verified peripheral UUID.
  It rejects same-timestamp counter conflicts, impossible flash progression,
  implausible tick rates, and intervals long enough to conceal a complete
  UInt16 tick revolution. It sums admitted sequential transitions rather than
  subtracting two distant endpoints.
- The current subtotal is retained while unrelated history projections rebuild,
  and its freshness ends at the last physically decoded row rather than at the
  wall-clock time at which the projection happened.
- A verified cumulative daily subtotal is now written to a bounded,
  fsync-backed receipt store before it becomes eligible to outlive raw archive
  retention. Receipts are keyed by canonical strap UUID plus physiological-day
  boundary, carry the motion-model version, and only advance monotonically in
  coverage, capture time, ticks, and steps. A weaker or older replay cannot
  replace a stronger receipt; another strap cannot read it.
- These daily-path changes are implemented and covered by focused unit tests,
  but are **not yet physical Gate-4 acceptance evidence**.
- Gate 4 remains open. Required physical closure now includes: a held-out
  counted manual walk, a stationary zero-step control, and ordinary unannounced
  walking published into the day total without starting a workout.

#### 2026-07-27 — unannounced 150-step holdout disproves a fixed tick scale

**PHYSICAL; CAPTURE PASSED, ACCURACY FAILED**

- With no workout active and the iPhone stationary, the user independently
  counted 150 steps. The continuously armed `69/01` bank covered the complete
  burst and was recovered from the same strap after a thermal deferral.
- The exact v24 boundary advanced from `24273` to `24464`: **191 motion
  ticks**. The previously accepted fixed scale (`155 / 132` ticks per step)
  predicts **163 steps**, which is **8.67% high** and outside the required
  ±5% range (`143...158`).
- The counter remained exactly `24464` for the following 185 seconds. This
  supports its use as a strong motion/stillness gate, but does not convert it
  into a cadence-independent step counter.
- Therefore the earlier two-walk fixed-scale result is superseded for product
  acceptance. It remains useful calibration evidence, but Gate 4 is open and
  v1 must not be called reliable for ordinary daily walking.
- Independent source audit agrees with the physical result: NOOP explicitly
  treats WHOOP 4 steps as a calibrated motion **estimate**, states that the 4.0
  does not transmit a BLE step count, and uses phone-counted days for its
  personal fit. Atria cannot reuse that calibration source because Gate 4
  forbids phone pedometer input.
- **Evidence:** `evidence/2026-07-27-gate4-unannounced-150/`.

#### Gravity-cadence replacement after the fixed-scale failure

**IMPLEMENTED AND RETROSPECTIVELY CONSISTENT; FRESH PHYSICAL HOLDOUT PENDING**

- The v24 gravity vector at offsets `36/40/44` is available at approximately
  1.04 Hz while `0x69` is armed. Offsets `52...63` duplicate that vector and
  provide no independent cadence channel.
- Atria now uses bytes `88...89` only as the motion/stillness gate. For a
  sustained, densely covered motion burst it estimates cadence from the
  dominant aliased frequency of consecutive gravity-vector differences. It
  uses no phone motion, pedometer, GPS, distance, or HR-derived step estimate.
- Retrospective results on the exact captured windows are: 135 for 132 counted
  steps, 136 for 136 counted steps, and 145 for the unannounced 150-step walk.
  All are within 5%, including the walk that disproved the fixed scale.
- Counter-active bursts shorter than 30 seconds, sparse samples, discontinuous
  samples, and weak/ambiguous spectra are not silently converted into steps.
  Daily publication keeps qualified sustained walks as a lower bound and marks
  unresolved motion as partial coverage.
- These three walks influenced model selection and are not a fresh holdout.
  Gate 4 therefore remains open until the frozen build passes one new counted
  walk and a separately instructed zero-step arm-motion control.

#### 2026-07-27 — ensemble v3 and single-offset clock alignment

**CODE + RETROSPECTIVE PHYSICAL REPLAY; INDEPENDENT ACCEPTANCE PENDING**

- A new saved Walking workout covered 93.56 wall-clock seconds. The user
  independently counted **129 steps**. The retained v24 sequence contains
  **98 rows**, spans **93.25 raw seconds**, and covers **99.66%** of the saved
  boundary.
- Cadence-only v2 produced 137 steps (**6.20% high**). The frozen v3 result
  combines two independent strap-only measurements: two-thirds aliased gravity
  cadence plus one-third gravity-vector motion volume. It produces **129
  steps** for this capture.
- The same frozen v3 scorer produces **148 steps** for the earlier unannounced
  150-step walk (**1.33% low**). No phone motion, phone pedometer, GPS, distance,
  or imported step total is used.
- A history-drain defect was found during this replay: one physical sequence
  crossed pages whose stored `clockDriftSeconds` changed from `+16` to `+4`.
  Applying page-local corrections spliced the wrong physical seconds together
  and produced 145/129. Raw device time remained monotonic.
- Workout and daily decoding now evaluate only whole-window clock offsets
  actually observed in the retained rows (plus zero for a synchronised strap).
  A single offset governs the complete candidate; the candidate with the
  strongest strap-owned motion evidence is selected. For the 129-step capture
  this selects offset `0`; for the prior 150-step capture it selects `+14`.
- This correction and the v3 blend were selected after inspecting the
  129-step result. Therefore that replay proves the demonstrated failure is
  fixed, but it is **not** an untouched holdout and does not seal Gate 4.
- Stronger daily replays may now correct an earlier false-positive step subtotal
  downward. Coverage, capture time, and raw motion ticks must still advance;
  weaker or older evidence cannot replace a durable receipt.
- Focused Swift tests pass for the model, one-offset alignment, multi-gap
  reduction, daily receipt correction, and presentation. Simulator build
  succeeds.
- **Evidence:** `evidence/2026-07-27-gate4-fresh-129/`.

#### 2026-07-27 — v4 clock-provenance correction

**CODE CORRECTION; PHYSICAL ACCEPTANCE PENDING**

- The v3 whole-window selector still chose between otherwise valid offsets by
  motion-tick volume. That made time alignment depend on the activity being
  measured and could shift a workout toward adjacent motion.
- v4 selects the offset only from the number of retained rows carrying that
  clock-reference drift, then boundary fit. Equally supported, equally aligned
  but physically distinct windows fail closed; motion is scored only after one
  clock mapping wins.
- Existing v3 receipts are invalidated by the algorithm-version change.
- A stronger-coverage daily replay may replace an earlier result even when the
  corrected interval has fewer ticks or fewer steps.
- The retained 150-step capture has 292 rows supporting offset `+14` and 67
  supporting `+11`; clock provenance therefore selects `+14` independently of
  motion and preserves the 148-step retrospective result.

#### 2026-07-27 — untouched v4 physical holdout

**PHYSICAL ACCEPTANCE PASS**

- The v4 binary was frozen, audited, tested, and installed before the user was
  instructed to walk or disclosed the counted total.
- The saved Walking workout covered wall time `1785101104.293357` through
  `1785101198.958469`. The user independently counted **129 steps**.
- Candidate-local clock provenance selected offset `+12`. The retained v24
  sequence supplied 99 rows over 94.208 seconds and covered **99.517%** of the
  saved boundary.
- The strap-only result was **127 steps**, an absolute error of 2 and relative
  error of **1.5504%**. No phone pedometer, phone motion, GPS, distance, or
  imported step total was used.
- The workout remained saved with 85.787 seconds of accepted live HR coverage,
  98 bpm average HR, and 0.0678 internal workout strain.
- **Evidence:** `evidence/2026-07-27-gate4-untouched-129/`.
- Gate 4 is not sealed until a separately instructed stationary arm-motion
  control proves that wrist motion without walking does not publish steps.

#### 2026-07-27 — planted-feet rhythmic-arm control disproves v4

**PHYSICAL FAILURE; V4 INVALIDATED**

- The user kept both feet planted and rhythmically swung only the
  WHOOP-wearing arm through the complete saved workout
  `1785102086-1785102206-live_workout_window`.
- The v4 strap-only scorer accepted the motion as 166 walking steps despite
  the physical ground truth being zero. The saved workout and HR stream
  remained intact; the failure is specifically locomotion classification.
- The tempting whole-window gravity-axis variance is not a safe discriminator:
  pose and inactive workout edges materially change it. Raw byte 80 bit 4 is
  also not a gait flag; it is absent in three prior counted walks.
- **Evidence:**
  `evidence/2026-07-27-gate4-arm-control-failure/`.
- Gate 4 remains open. No v4 result may be called reliable after this control.

#### WHOOP 4 v24 gait/non-gait findings and v5 freeze

**IMPLEMENTED; FRESH PHYSICAL CONTROL PENDING**

- Classification is computed only over the counter-active burst, while step
  quantity remains computed over the exact clock-proven workout boundary.
- Four real counted walks and the planted-feet arm control expose a stable
  strap-only separation in the gravity-difference spectrum:

| Capture | Tick rate/s | 0.35–0.50 Hz power share | Normalized spectral entropy | Lag-2 vector autocorrelation |
|---|---:|---:|---:|---:|
| Walk 129 | 1.760 | 0.544 | 0.810 | 0.017 |
| Unannounced walk 150 | 1.947 | 0.230 | 0.965 | -0.095 |
| Training walk 132 | 1.853 | 0.360 | 0.904 | -0.185 |
| Held-out walk 136 | 1.870 | 0.274 | 0.954 | -0.020 |
| Planted-feet arm motion | 1.392 | 0.777 | 0.707 | 0.527 |

- Frozen v5 requires all of: tick rate at least `1.55/s`, band-power share at
  most `0.65`, normalized entropy at least `0.75`, and lag-2 autocorrelation at
  most `0.20`. Sparse, discontinuous, split, or non-gait motion fails closed.
- This gate uses only WHOOP 4 v24 counter and gravity fields. It does not use
  phone motion, CMPedometer, GPS, distance, HR, or user-entered steps.
- Inner v24 float bytes `32...35` also separate the four walks from arm/rest
  controls when interpreted as an unknown motion scalar. Its semantics are
  not proven and overlap other community heuristic mappings, so it is recorded
  as a protocol lead rather than promoted into product logic.
- Because the v5 thresholds were selected after inspecting the failed arm
  control, the same planted-feet control must now be repeated untouched, then
  a fresh slow counted walk must pass before Gate 4 can be sealed.

#### 2026-07-27 — fresh arm control disproves v5; v6 impact/orientation gate

**V5 PHYSICAL FAILURE; V6 IMPLEMENTED; FRESH ACCEPTANCE PENDING**

- A new planted-feet control ran from `1785103194.596314` through
  `1785103299.565563`. Only the strap-wearing arm moved. V5 classified it as
  **200 steps**, despite physical ground truth of zero.
- Its gravity spectrum passed every v5 gate: tick rate `1.637/s`, alias-band
  share `0.489`, normalized entropy `0.934`, and lag-2 vector autocorrelation
  `0.062`. Gravity periodicity alone is therefore not a sufficient locomotion
  discriminator.
- The user's immediate post-workout toilet/out-of-range trip interrupted the
  first archive drain. The complete interval was subsequently recovered using
  a bounded 30-second bank checkpoint. This changed evidence availability, not
  the physical result.
- v24 bytes `32...35`, decoded conservatively as an unknown finite float, add
  an independent impact-to-orientation discriminator. Mean scalar divided by
  mean gravity-vector delta was `0.756`, `0.863`, `0.715`, and `0.701` in four
  counted walks, versus `0.327` and `0.559` in the two planted-feet controls.
- Frozen v6 retains every v5 gate and additionally requires scalar mean
  `>= 0.07` and scalar/gravity-delta ratio `>= 0.65`. The field's physical
  semantics remain unconfirmed; neither documentation nor product output calls
  it acceleration.
- Retrospective replay accepts all four known walks and rejects both known arm
  controls. Because the new thresholds were selected after the second control,
  v6 still requires a fresh untouched planted-feet control followed by a fresh
  slow counted walk within 5% before Gate 4 can be sealed.
- **Evidence:** `evidence/2026-07-27-gate4-v5-arm-control-failure/`.

#### 2026-07-27 — untouched v6 planted-feet control

**PHYSICAL ACCEPTANCE PASS**

- The v6 binary was frozen, tested, and installed before this control began.
- Through saved workout `1785104226-1785104332-live_workout_window`, the user
  kept both feet planted and moved only the strap-wearing arm.
- The exact strap-history interval failed closed as non-gait. It published no
  walking steps. Its scalar/gravity-delta ratio was `0.507`, below v6's frozen
  `0.65` floor; lag-2 vector autocorrelation was also `0.226`, above the
  frozen `0.20` ceiling.
- The workout remained intact with 104.772 seconds of accepted HR, 99% stream
  coverage, 91 bpm average HR, and 0.0584 internal strain.
- The exact interval was recovered asynchronously from banked strap history.
  No phone motion, CMPedometer, GPS, distance, HR, or user-entered count was
  used by the classifier.
- **Evidence:** `evidence/2026-07-27-gate4-v6-arm-control-pass/`.
- V6 now requires one fresh slow counted-walk holdout within 5% before Gate 4
  can be sealed.

#### 2026-07-27 — slow-walk holdout disproves v6; v7 dominant burst

**V6 PHYSICAL FAILURE; V7 IMPLEMENTED; FRESH ACCEPTANCE PENDING**

- On frozen v6, the user stopped a slow Walking workout at 90 seconds after
  its active screen appeared and independently counted **106 steps**.
- The exact strap window contained a tiny 14-tick setup-motion cluster, then
  20.188 seconds before a sustained 125-tick gait cluster. V6 rejected the
  complete workout as multiple bursts, so it produced no count.
- The sustained cluster independently passed every frozen gait feature:
  tick rate `1.806/s`, alias-band share `0.593`, entropy `0.847`, lag-2
  autocorrelation `0.167`, scalar mean `0.0945`, and impact/orientation ratio
  `1.002`.
- V7 permits setup/ending noise only when one unique cluster owns at least 80%
  of all motion ticks. It scores that cluster with at most ten seconds of
  counter-derived pre/post roll. Balanced stop/start efforts still fail closed.
- Retrospective v7 produces **104 steps**, 2 low and **1.887% error**. The
  stationary v6 arm control remains rejected.
- Because v7 was selected after this holdout, this is a demonstrated-failure
  repair, not independent physical acceptance. The same slow counted-walk test
  must be repeated on a frozen v7 build.
- **Evidence:** `evidence/2026-07-27-gate4-v6-slow-walk-failure/`.

#### 2026-07-27 — high-impact holdout disproves v7; v8 amplitude rejection

**V7 PHYSICAL FAILURE; V8 IMPLEMENTED; FRESH ACCEPTANCE PENDING**

- On frozen v7, the user manually stopped a 90-second slow Walking workout
  and independently counted **108 steps**.
- The exact raw interval had 99.732% boundary coverage. V7 produced **171
  steps** (58.33% high): its gravity motion volume was 25.545 and alone implied
  248 steps. Wrist amplitude is therefore unsafe for step quantity even after
  locomotion itself has been qualified.
- The v24 unknown-motion scalar mean was `0.1667`, materially above all four
  earlier counted walks (`0.085...0.109`). In this high-impact regime, the
  true lower gait alias remains present while the ordinary high alias band is
  dominated by wrist motion.
- Frozen v8 defines high impact at scalar mean `>= 0.13`, searches
  `0.08...0.20 Hz` for the lower gait alias, and uses cadence only. It never
  rewards gravity amplitude in this branch. All prior gait/non-gait gates
  remain mandatory.
- Retrospective v8 produces **112 steps**, 4 high and **3.704% error**. It also
  preserves 104/106, 127/129, and 148/150 while rejecting the untouched
  planted-feet arm control.
- Because v8 was selected after this holdout, another frozen-build physical
  walk is required before Gate 4 can be sealed.
- **Evidence:** `evidence/2026-07-27-gate4-v7-high-impact-failure/`.

#### 2026-07-27 — moderate-impact holdout disproves v8; v9 alias arbitration

**V8 PHYSICAL FAILURE; V9 IMPLEMENTED; FRESH ACCEPTANCE PENDING**

- On frozen v8, saved Walking workout
  `1785106515-1785106607-live_workout_window` retained 90% accepted live-HR
  coverage. The user began walking about five seconds after Start, manually
  stopped at 1:30, and independently counted **100 steps**.
- The exact asynchronous strap-history interval had 97 v24 rows and 99.8707%
  boundary coverage. No phone motion, pedometer, GPS, distance, HR, or
  user-entered count was used by the scorer.
- V8 produced **151 steps**, 51% high. Its scalar mean (`0.11965`) sat below
  the `0.13` high-impact threshold, so it selected the ordinary `0.47678 Hz`
  alias: 140 cadence steps. Gravity amplitude independently implied 172 and
  inflated the final ensemble.
- The same strap signal contains a `0.13003 Hz` lower alias whose power is
  **1.5176x** the ordinary peak. In preserved earlier walks this ratio is at
  most 1.081; the planted-feet control still fails the locomotion gates.
- V9 selects the lower alias at a frozen ratio of `>= 1.25`. In this
  moderate-impact branch, cadence remains two-thirds of the estimate and the
  physically validated cumulative strap counter supplies one-third; amplitude
  is excluded. Retrospective v9 returns **103 steps** (3% error).
- A separate protocol finding remains diagnostic: after at least five seconds
  of an unchanged counter, the first transition is consistently a large
  `+11...+13` activation/batch transition. Across the cumulative capture,
  61/61 resumed bursts followed this pattern. The counter is therefore a
  motion coordinate, not a literal footfall counter; v9 does not publish it
  one-for-one.
- The five then-preserved walking windows replayed within 5% under v9. Later
  recovery of W110 plus replay of the original W132/W136 drains disproved the
  broader v9 claim; see the appended v10 correction below.
- The all-day no-workout path is not sealed by this result. Its historical
  burst splitter begins at the delayed counter transition and would truncate
  the first ~20 seconds of this walk. A separate no-workout counted walk must
  validate continuous live R10 capture and durable daily publication.
- **Evidence:** `evidence/2026-07-27-gate4-v8-low-alias-failure/`.

#### 2026-07-27 — untouched v9 holdout exposes motion-owner gap

**PHYSICAL ACQUISITION FAILURE; V9 ACCURACY NOT EVALUATED**

- On the untouched v9 binary, the user manually stopped Walking workout
  `1785107793-1785107885-live_workout_window` at 1:30 and independently
  counted **110 steps**.
- The workout remained durably saved with 85 accepted HR samples and 87%
  stream coverage. Atria did not fabricate or publish a step result.
- The frozen post-test archive contained no v24 rows for the physical
  interval. Its last qualified wall timestamp was `1785107768.416992`, 24.195
  seconds before workout start. Runtime independently persisted
  `r10_range_unrecovered:1785107793-1785107885`.
- Protected R10 correctly remained suppressed under the proven pure-HR owner.
  The historical-motion bank armed only at `1785107967.181886`, about 82
  seconds after workout end, while an all-day prearm request remained pending.
- Code audit isolated one exact transition: TX-only discovery preserves the
  pending bank prearm, but TX discovery completion ignores it unless a manual
  workout owner is already present. Fixing that linkage can use the safe
  `0x69` bank without clearing R10 suppression or subscribing proprietary
  motion streams.
- This result does not disprove v9's estimator. It proves the app did not
  acquire the input required to evaluate it, so Gate 4 remains open and the
  identical physical test must be rerun after the ownership correction.
- **Evidence:** `evidence/2026-07-27-gate4-v9-motion-ownership-failure/`.

#### 2026-07-27 — repaired acquisition disproves v9 gait gate

**MOTION ACQUISITION PASS; V9 CLASSIFIER PHYSICAL FAILURE**

- The narrow all-day prearm/TX-discovery repair was installed without
  changing the proven pure-HR owner or protected-R10 suppression.
- Walking workout `1785108503-1785108594-live_workout_window` retained 99%
  accepted-HR coverage. The user manually stopped at 1:30, independently
  counted **109 steps**, and remained nearby through offload.
- Unlike the preceding failed holdout, the bank closed, asynchronous history
  offload reached a terminal state, the exact 96-row v24 interval became
  durable, and the bank re-armed afterward. This physically passes acquisition
  for the bounded workout.
- V9 returned no count. During continuous walking, the firmware counter paused
  for 10.574 seconds. V9 split at ten seconds into 37-tick and 91-tick
  clusters; their 28.91%/71.09% shares left no 80%-dominant cluster.
- The whole verified walking interval also has scalar/orientation ratio
  `0.48034`, below v9's `0.65` gait threshold. That feature is now disproven
  as a mandatory locomotion condition.
- No phone motion, pedometer, GPS, distance, HR-derived step estimate, or
  user-entered count was provided to the estimator.
- **Evidence:** `evidence/2026-07-27-gate4-v9-gait-gate-failure/`.

#### 2026-07-27 — recovered W110 and full-corpus v10 correction

**RETROSPECTIVE MODEL PASS; FRESH PHYSICAL ACCEPTANCE REQUIRED**

- The earlier 110-step acquisition-failure interval was subsequently recovered
  with 97 rows, 99.891% boundary coverage, consecutive flash counters, and no
  sample gap above 0.962 seconds. Acquisition was not the remaining problem.
- W110 disproved four v9 classifier gates simultaneously: ordinary-band share
  was `0.77176`, lag-two autocorrelation `0.31273`, scalar mean `0.06604`, and
  scalar/gravity ratio `0.64144`. The old thresholds would reject genuine
  walking.
- Across ten counted walks and three planted-feet rhythmic-arm controls, the
  current-window firmware-counter transition mean separates locomotion:
  walks are `1.639...1.818`; controls are `1.338...1.539`.
- Gravity-delta magnitude MAD independently separates this corpus: walks are
  `0.0282...0.0576`; controls are `0.0663...0.1038`.
- V10 therefore requires at least 55 regular positive transitions, mean
  `>=1.60`, and gravity-delta MAD `<=0.060`. It treats `+11...+13` as the
  observed resume/batch token and bridges such a token across at most twelve
  seconds. Scalar amplitude, ordinary-band concentration, lag-two
  autocorrelation, and scalar/gravity ratio are no longer mandatory gait
  gates.
- W110's over-concentrated ordinary band is treated as an alias-selection
  signal only after the independent locomotion gate passes. Its lower cadence
  yields **107/110** (2.73% error), instead of v9's false negative or the
  ordinary branch's 134/110 overcount.
- The complete retrospective results are: 133/132, 136/136, 148/150, 129/129,
  127/129, 106/106, 112/108, 103/100, 107/110, and 109/109. Maximum error is
  3.704%. All three planted-feet controls reject.
- Duplicate payload clock provenance is now immutable: the earliest durable
  observation owns a payload; a later replay cannot rewrite its offset or
  inflate offset support; equal-earliest conflicting clock tuples fail closed.
- This rule was selected retrospectively. Gate 4 remains open until the same
  frozen installed binary passes a fresh untouched counted walk and a fresh
  untouched planted-feet control.
- **Evidence:** `evidence/2026-07-27-gate4-v10-retrospective/`.

#### 2026-07-27 — fresh slow walk disproves V10 alias selection; V11 arbitration

**V10 PHYSICAL FAILURE; V11 IMPLEMENTED; FRESH ACCEPTANCE REQUIRED**

- The frozen V10 binary captured a user-counted **109-step** slow walk over the
  exact wall interval `1785111646.3601...1785111736.3601`.
- Acquisition passed: the asynchronous WHOOP motion-bank offload durably
  produced 95 qualified v24 rows with 100% boundary coverage.
- V10 selected the ordinary cadence alias and returned **125 steps**, 16 high
  and **14.679% error**. Gate 4 therefore remained open.
- The same signal contains a lower alias yielding 109 cadence steps. V11 does
  not lower the spectral threshold or choose whichever alias is merely closest
  to the firmware counter; both approaches break preserved walks.
- V11 adds an independent cross-signal inflation check after gait has already
  qualified. When the ordinary cadence/motion-volume ensemble is at least
  `1.20x` the validated WHOOP-v24 counter projection, the lower alias is used
  with the existing cadence/counter correction. The counter arbitrates the
  alias only and is never published one-for-one.
- The 11-walk/3-control replay changes only this new failure: it returns
  **107/109** (1.835% error), preserves every prior walk within 5%, and all
  three planted-feet controls still reject. One-row boundary perturbations
  preserve separation from the closest prior ordinary-alias case.
- V11 is retrospective and must pass another untouched slow walk followed by
  an untouched planted-feet rhythmic-arm control from the frozen installed
  build.
- **Evidence:**
  `evidence/2026-07-27-gate4-v10-fresh-slow-walk-109/`.

#### 2026-07-27 — fresh V11 walk exposes a second slow-cadence subharmonic

**V11 PHYSICAL FAILURE; V12 IMPLEMENTED; FRESH ACCEPTANCE REQUIRED**

- On the frozen V11 Release build, the user walked from workout timer `00:01`
  through `01:31` and independently counted **115 steps**. The manual workout
  remained saved with 94% accepted-HR coverage.
- Asynchronous strap history durably supplied 95 qualified v24 rows for the
  exact wall interval `1785112541.363978...1785112631.363978`, with 100%
  boundary coverage. Live HR continued during the offload.
- V11 selected the ordinary `0.35413 Hz` alias and returned **132 steps**,
  17 high and **14.783% error**.
- The same interval has a lower `0.17706 Hz` alias, lower/ordinary peak-power
  ratio `0.68772`, and firmware motion-coordinate rate `1.99838/s`. Across the
  twelve-walk physical corpus, the nearest ordinary-alias case below a 1.0
  peak-power ratio has a `1.853/s` tick rate. All three planted-feet controls
  fail the independent locomotion classifier.
- V12 treats a `0.40...<1.0` lower/ordinary peak ratio combined with a
  `>=1.90/s` gait-qualified tick rate as a high-rate subharmonic. This is alias
  selection only; it does not publish the counter as steps.
- When the lower alias is selected, the counter replaces cadence only when its
  projection is at least `1.20x` cadence. Otherwise V12 retains the existing
  two-thirds cadence, one-third counter blend. This produces **115/115** on the
  failed interval.
- The twelve preserved walks replay within 5% and the three preserved arm-only
  controls reject. One-row boundary perturbations keep the repaired 115-step
  walk within 2.61%. A new frozen-V12 walk and planted-feet control remain
  mandatory.
- **Evidence:**
  `evidence/2026-07-27-gate4-v11-fresh-slow-walk-115/`.

#### 2026-07-27 — frozen V12 rejects a fresh planted-feet arm-only control

**FRESH V12 NEGATIVE CONTROL PASS; COUNTED WALK STILL REQUIRED**

- The user kept both feet planted and swung only the strapped arm for a
  90-second Walking workout. The workout saved with 90 accepted HR samples.
- The asynchronous motion-bank offload reached the terminal
  `Recovery partial · 341 saved` state while live HR remained available.
- The exact-window WHOOP v24 signal was intentionally energetic
  (`1.9275/s` firmware motion-coordinate rate) but failed the independent gait
  classifier: lag-two autocorrelation was `-0.11256`, spectral entropy was
  `0.89937`, and gravity-delta MAD was `0.10675`.
- V12 therefore returned unavailable rather than fabricating steps. This is
  the required fresh planted-feet negative-control pass.
- Gate 4 remains open because the earlier V12 acquisition run was discarded
  and no fresh user-counted V12 walk has yet passed the accuracy and coverage
  thresholds.
- **Evidence:**
  `evidence/2026-07-27-gate4-v12-fresh-arm-control/`.

#### 2026-07-27 — counted V12 walk exposes a connection-epoch bank bug

**PHYSICAL ACQUISITION FAILURE; ESTIMATOR NOT SCORED**

- The user walked **103 counted steps** from workout timer `00:01` through
  `01:32`. The workout itself saved with 91 accepted HR samples and 98%
  stream coverage.
- The post-workout archive added 40 durable rows, but the newest corrected v24
  timestamp was `1785114634`; movement began at `1785114744.454893`. The exact
  interval therefore had zero coverage and no step estimate was admitted.
- Preferences bind the failure to the retired realtime-R10 cutover:
  `v8WorkoutInProcessCutoverLease=1785114743.454893`, followed by a new
  connection epoch at `1785114747.862753`.
- The bank's in-memory armed bit survived that physical disconnect. Fresh TX
  discovery consequently treated the replacement link as already armed and
  did not send `69/01`.
- The repair makes banked v24 the sole production Gate-4 motion owner:
  manual-workout Start and accepted-HR callbacks no longer initiate the R10
  cutover; armed state is scoped to one connection epoch; a reconnect preserves
  desired/prearm intent but must send one new `69/01`.
- A closed workout now creates a durable ticket containing strap ID, exact
  start/end, arm epoch and attempt state. History completion verifies
  clock-corrected v24 transport coverage off-main and clears the ticket only at
  **≥90%**; process replacement or partial pages retain and retry it.
- **Evidence:**
  `evidence/2026-07-27-gate4-v12-fresh-walk-103/`.

#### 2026-07-27 — post-workout offload must prove v24 coverage and restore live ownership

**110-STEP RUN SAVED; OFFLOAD REGRESSION ISOLATED**

- The final slow walk saved intact for `1785118046.970...1785118139.393`
  with 92 HR samples, 95% stream coverage, 89 average HR and 99 peak HR.
- The first offload verifier incorrectly cleared the durable ticket even
  though the exact analyzer found zero qualified v24 rows. Generic historical
  transport density is not motion-bank proof; only clock-corrected,
  gravity-validated v24 rows for the same strap and exact interval qualify.
- After the bounded offload, CoreBluetooth still reported a connected link
  while the displayed HR remained fixed. Relaunching immediately restored
  changing HR, isolating the regression to history-to-live ownership release.
- Every connected history exit now waits for an accepted HR sample newer than
  the exit request. It reasserts 2A37 after five seconds and performs at most
  one known-strap reconnect after ten seconds. An incomplete drain remains
  incomplete even if live restoration succeeds.
- A one-time migration reconstructs a ticket cleared by the retired verifier
  only when the durable unresolved R10 range is contained by a closed `0x69`
  bank for the same strap. On the physical phone this restored
  `1785118047...1785118139`, and history rows began increasing while live HR
  continued changing.
- The complete segmented archive subsequently proved **97 qualified v24 rows**
  over the 92.42-second workout window, with **99.85% exact coverage**. The
  ticket therefore cleared legitimately on the repaired verifier.
- Frozen V12 scored the user's 110 steps as 135. V13 recognizes the recovered
  low-amplitude/high-rate gait regime from strap-only tick rate, gravity MAD,
  spectral band share and firmware scalar, selects the 113-step lower cadence,
  and finishes at **2.73% error**. The preserved 150-step ordinary-alias walk
  remains 148 (1.33% error); planted-feet controls remain rejected.
- An unresolved ticket may retry only after verified live restoration.
  Otherwise it remains durable until the next genuinely accepted HR callback;
  history cannot repeatedly seize a connected-but-silent link.
- **Evidence:** `/tmp/atria-g4-poll.h4X4sl/`,
  `/tmp/atria-post-fix-state/`.

#### 2026-07-27 — V13 Swift parity and durable publication repair

**EXISTING 110-STEP WALK NOW PERSISTS AS 113**

- The Python V13 parity tool selected 113, while the production Swift model
  initially persisted 135 from the same 97 rows and exact endpoints.
- A direct Swift replay exposed the mismatch: the soft-gait discriminator used
  `motionTicks / fullWorkoutDuration` (1.647 Hz), while its gravity, scalar and
  spectral features describe the counter-active gait interval. The latter rate
  is 2.053 Hz. V13 now carries that independently qualified active tick rate
  through `GaitQualification`.
- The preserved 150-step ordinary-alias calibration remains below the 2.00-Hz
  active-rate boundary at 1.947 Hz; this correction does not select from the
  user's entered count.
- Step publication is now a dedicated newest-unresolved-walk queue. It no
  longer waits behind lifetime HR rehydration or a batch of 32 legacy walks.
- Release binary SHA-256
  `a6ec65d605ddcd8ab9e28b36e7a417da8ec0eeb8fab3623ce3aa8370f7d4f5ef`
  persisted workout `1785118047-1785118139-live_workout_window` as **113
  estimated strap steps** within four seconds of launch. The saved workout
  retained 92 HR samples and 95% HR coverage.
- The Start Activity sheet opened normally after the repair; no new workout
  was started during that responsiveness check.
- **Evidence:** `/tmp/atria-verify/gate4-v13-1.json`,
  `/tmp/atria-verify/current-active.jsonl`.

#### 2026-07-27 — current-binary counted walk and save-flow acceptance

**GATE 4 PHYSICALLY PASSED**

- On the current Release binary, the user walked exactly 90 seconds and
  independently counted **110 steps**.
- The exact workout remained durable as
  `1785124908-1785125000-live_workout_window`, with 92 accepted HR samples,
  95% stream coverage, 120 average HR and 136 peak HR.
- The exact WHOOP v24 bank interval covered 88.199 of 92.494 seconds
  (**95.4%**). The current strap-only model persisted **112 steps**, an
  absolute error of 2 steps or **1.82%**. No phone-pedometer fallback was used.
- A stale oldest-first offload selector had allowed retried legacy tickets to
  delay the just-finished workout. New unattempted tickets now run
  newest-first; after every ticket has one attempt, retries remain
  oldest-first.
- The user's first Done tap then exposed a separate save-flow freeze. A debugger
  sample showed three archive-wide readers competing after save: history
  snapshot projection, lifetime recovered-HR projection and compaction. All
  archive-wide projection/recovery/maintenance work now shares one serial
  queue; narrow current-workout evidence stays independently prioritized.
- The repaired installed binary passed a physical stationary control: Start
  presented immediately, the timer advanced, End produced the receipt on its
  first tap, and Done dismissed it on its first tap in approximately 0.6
  seconds. The 112-step workout remained present after the final install and
  relaunch.
- Release binary SHA-256:
  `de3d5626345f04d4457cfdae70ade7c12a8aa810e6caa725c611b0432bafc406`.
- **Evidence:**
  `evidence/2026-07-27-gate4-final-110-step/`.

## Current binary status

| Gate 4 subtest | Expected | Observed | Result |
|---|---|---|---|
| Workout integrity during failed motion probes | Workout remains saved; sparse motion is not presented as complete | Workouts saved with 95–99% HR; steps not fabricated | **PASS** |
| `0x3F` high-bandwidth motion lease | Continuous motion through workout | Short burst/one frame then timeout | **FAIL** |
| Bounded `0x51 + 0x6A`, stopped by `0x52` | ≥30-second stable stationary capture, then accurate controlled walk | Two frames, then `CBErrorDomain:6`; HR recovered, workout saved, no steps claimed | **FAIL** |
| `0x69` banked-motion transport | Every second of a bounded stationary window recovered from strap history | 97 type-47 rows, 93/93 unique seconds, 0 missing | **PASS** |
| `0x69` counted-walk accuracy | Strap-only count within 5%; zero rest false steps | Current physical truth 110; current release durably saved 112 (1.82% error); fresh planted-feet arm control rejected | **PASS** |

## Gate 5 — automatic detection and strain

#### Production positive-detection contract

**PHYSICAL PASS — sealed**

- A detector-ready workout requires at least **10 minutes of accepted HR**,
  at least **75% stream coverage**, no contact-compromise or RR-disagreement
  rejection, and sustained HR at the profile's 50%-reserve threshold.
- The sustained-HR requirement is the larger of 35% of observed time or five
  minutes (capped at twenty minutes), including one continuous bout of the
  larger of 20% of observed time or three minutes (capped at eight minutes).
- A lower-confidence review candidate that does not clear the detector-ready
  bar ordinarily requires at least **15 minutes observed** and 40% coverage,
  with a sustained, contact-qualified distribution. The deliberately narrow
  gapped-effort fallback starts at twelve observed minutes and applies only
  when its stronger distribution checks pass.
- A candidate is not eligible for presentation until the production
  **10-minute post-end settle delay** has elapsed. Already-confirmed or
  dismissed overlapping windows are suppressed.
- The saved unconfirmed candidate is rebuilt into an in-memory cache; it is not
  itself written as a durable candidate JSON record. The detections ring is
  not proof of an unconfirmed candidate because current `workoutDetected`
  entries are appended when a workout is confirmed. Physical acceptance
  therefore requires both (a) the visible Activity detected/Review surface
  after settling and (b) a pulled sensor window with no overlapping confirmed
  or dismissed workout.
- Before the repaired-build migration, `personalBaseline.restingHR` was absent
  and the detector honestly fell back to 60 bpm. The migration initially
  rehydrated a 60.991 bpm EMA and settled to 59.371 bpm as deferred canonical
  session reconciliation completed, while retaining four real samples. The
  exact 50%-reserve threshold must therefore be frozen from the start snapshot
  of each physical test, not copied from an earlier UI observation.
- The accepted physical positive was a 12m25s genuinely brisk walk without a
  manually started workout. Its accepted strap-HR evidence independently
  cleared the production duration, coverage, sustained-HR and continuous-bout
  gates; the app then exposed the bounded review after settling.

#### 2026-07-27 — preserved-data preflight

**STRAIN PASS; CONSERVATIVE DETECTOR NEGATIVES PASS; NEW UNCONFIRMED PHYSICAL
POSITIVE STILL REQUIRED**

- The focused automatic-detection and motion-gate suites passed **27/27**.
  They cover spike, stale-sample, duplicate-timestamp, fragmented-bout,
  reconnect-blip, poor-contact, RR-disagreement and automotive negatives,
  plus sustained qualified strap-HR positives.
- Exact current-binary replay of the physical store found 57 retained sessions.
  It emitted 34 low-confidence diagnostic rest rows and **zero** workout or
  activity candidates from the current quiet/test period. The candidate cache
  also emitted zero duplicates for already-confirmed workout windows.
- This does not prove the positive physical gate: every preserved gym window
  is already confirmed, and the production overlap fence correctly suppresses
  a detector candidate for an effort that is already saved.
- The strain confirmation ledger contains 40 exact raw-TRIMP audits. Reapplying
  the production `21 × (1 − exp(−TRIMP/150))` curve reproduced all 40 stored
  scores with maximum numeric error **0**.
- The current 90-second walk is **0.15 strain** at 95% HR coverage. The
  preserved 74-minute hard strength workout is **7.53 strain** from 3,820
  observed HR seconds at 86% coverage, matching the user's expected 7–9 band.
- Sparse evidence remains disclosed: workout activity rows mark coverage below
  75% as partial and cumulative day strain uses a lower-bound presentation.
- **Evidence:** `evidence/2026-07-27-gate5-preflight/`.

#### 2026-07-27 — metric-truth presentation hardening

- Sleep performance can no longer borrow the newest unrelated historical
  rollup and present it as the current night's exact percentage.
- Recovery carried from the prior sleep remains visible but is now labelled
  `Previous sleep score · awaiting today’s sleep`; the Day detail no longer
  assigns an unlabeled current Good/Typical/Low grade to that older score.
- Partial cumulative strain retains its measured `≥ N.N` lower bound, but
  cannot receive a complete ring fill, target progress, or zone.
- Workout HR coverage now uses one qualification boundary everywhere:
  **75%**. Coverage below it remains visible as incomplete and cannot publish
  precise derived strain, average/peak HR, energy, zones, or complete share
  metrics.
- Raw saved-session details now apply the same continuity-aware coverage gate,
  so two distant samples cannot paint an exact average, peak, strain, or zone
  breakdown across an otherwise empty hour.
- The reported quiet-awake false-sleep fixture remains diagnostic-only. Its
  initial audit failure was a stale structural test boundary, not a behavioral
  detector regression; the repaired focused run passed 37/37.
- **Evidence:** `evidence/2026-07-27-gate5-metric-truth/`.

#### 2026-07-27 — retained confirmed sleep must survive raw-session retirement

- **PHYSICAL state:** the phone retains twelve confirmed sleep records with
  real resting-HR values, including multiple physiological main sleeps, while
  `personalBaseline` contained zero samples and no resting HR.
- **Root cause:** raw-session retention had retired the older sleep sessions.
  Baseline reconstruction consulted only surviving raw sessions, so it could
  not bootstrap from the still-canonical confirmed sleeps and remained stuck
  on the 60 bpm fallback.
- **CODE repair:** if ordinary raw-session reconstruction yields zero resting
  samples, confirmed physiological main sleeps seed resting HR from their
  persisted canonical RHR, oldest first. Naps and implausible RHR values are
  excluded; no confirmed-sleep scalar is promoted into HRV.
- **Verification:** 14/14 HRV/baseline qualification tests, 5/5 baseline
  evidence tests, and 5/5 focused recovery-confidence tests pass. This remains
  code evidence for the rule itself.
- **PHYSICAL migration:** signed Release executable
  `161039b6914258ce024367eb4fa9b0d59327cc226fae5ffaf7c807fbeec4caf3`
  was installed in place. The confirmed-workout file retained the identical
  SHA-256 before and after installation. On the first repaired launch,
  `personalBaseline` advanced from zero samples/no RHR to four real samples
  and a 60.991 bpm EMA, then settled to 59.371 bpm with the same four-sample
  count after deferred canonical reconciliation; HRV remained absent rather
  than being fabricated.
- **PHYSICAL live state:** after migration, the link reported connected,
  sample diagnostics reported accepted/sample, and the checkpoint count
  advanced from 4,032 to 4,126 and then to 4,205 without foreground
  interaction.

#### 2026-07-27 — automatic history ownership can create its own live gap

- **PHYSICAL observation:** during the declared 15:24–15:40 no-manual-workout
  walk, the nearby phone was checked a few times and other apps were used
  normally, with no force quit, Bluetooth change, or re-pair. Atria initiated
  `explicit_history_fresh_owner_cutover` at 15:29:51
  while accepted strap HR was fresh. The resulting reconstruction contains one
  229.171-second live hole; the history background lease later reconciled as
  `orphaned_process_terminated`. The same automatic cutover repeated at
  15:49:39 during the post-walk settle while phone and strap were nearby. The
  user-visible `Disconnected`/`Reading` state matched this persisted event.
- **Protocol implication:** standard HR and the history transaction share a
  transport owner in the current implementation. A fresh live stream is proof
  that realtime must retain that owner; it is not proof that a background
  history cutover is safe.
- **CODE correction:** an automatic connected-history handoff is eligible only
  after accepted HR is already older than the live-freshness window. Explicit
  user recovery remains available, and the exact missing interval stays in the
  durable ledger while fresh capture continues.
- **Acceptance status:** code/test evidence is not a physical pass. Repeat the
  same stationary-phone physical run and prove no app-initiated cutover or
  capture hole before sealing this correction.
- **Evidence:** `evidence/2026-07-27-gate5-physical-positive/acceptance.md` and
  `/tmp/atria-gate5-walk-post.3tulmU/preferences.plist`.

#### 2026-07-27 — fresh-HR history-preemption guard physically verified

- Signed Release executable:
  `e8e5131b368ac3737df7e9fc72cceb23e7c17577c75e41530a800273ab1c7727`.
- The prior build's already-active history transaction was allowed to terminate
  on launch; live 2A37 then resumed.
- With the old exact gap still pending, accepted samples advanced from 996 to
  1,063 over 64.35 seconds. No new greater-than-15-second gap appeared, the
  history-attempt counter remained 1,079, and `lastAppCancelAt` remained frozen
  at the old 15:49:39 cutover.
- **Result:** physical pass for the narrow invariant that background history
  cannot preempt a healthy fresh-HR owner. This is not a Gate-5 positive
  auto-detection pass.
- **Evidence:** `/tmp/atria-history-guard-soak1.1785147893`,
  `/tmp/atria-history-guard-soak2.1785147955`, and
  `evidence/2026-07-27-gate5-physical-positive/acceptance.md`.

#### 2026-07-27 — natural phone use exposed app-created history preemption

- Picking up the phone, checking Atria, or briefly using another app did not
  itself explain the 229.171-second live hole. There was no force quit,
  Bluetooth toggle, or re-pair.
- The persisted `explicit_history_fresh_owner_cutover` at 15:29:51 matches the
  visible `Disconnected`/`Reading` state. The app intentionally yielded a
  healthy live owner to history work.
- Therefore ordinary foreground/background use must be included in future
  continuity acceptance. It is not valid to require a stationary untouched
  phone for normal strap recording.

#### 2026-07-27 — precise easy-walk strain result

- Physical truth: 15:24–15:40 IST; 724 accepted samples; average 109.15 bpm;
  peak 130 bpm; 729.611 qualified seconds.
- With resting HR 59, maximum HR 190, male coefficient 1.92, and the production
  15-second evidence boundary, TRIMP is 6.317 and displayed strain is 0.866.
- The 229.171-second missing interval contributes no load. A 3–4 workout strain
  for this evidence would be an overstatement.
- Detector, strain-gap, and strain-consistency focused suites all passed. The
  walk remains a physical negative control; it does not satisfy the sustained
  elevated-HR positive required to close Gate 5.

#### 2026-07-27 — automatic-workout delivery must include live journal evidence

- A detector pass is insufficient if a cold cache miss is treated as final,
  the cache omits the fsynced active journal, or an unsettled newer effort
  masks an older settled effort.
- Workout-review caching now merges the freshest durable active journal with
  canonical sessions and invalidates on canonical/live workout revisions.
- Dashboard cache publication retries notification delivery using the same
  candidate-ID reservation and deduplication rules as launch delivery.
- Candidate selection prefers the strongest fresh settled effort when the
  global strongest candidate is still unsettled.
- Focused automated acceptance: 42/42 tests passed across notification
  deep-link, workout-review cache, and detected-activity review suites.
- Signed Release executable prepared for physical acceptance:
  `3cd4c7176acaad192944ab1e96a936b67638980ec9a3edf9e0cc1dacbf3b9df8`.
- **Acceptance status:** delivery code is hardened, but Gate 5 remains open
  until this exact candidate produces and preserves a physical sustained-HR
  automatic-workout review.

#### 2026-07-27 — hardened Gate-5 candidate installed without data loss

- The signed `3cd4c717...b3b9df8` Release was installed without uninstalling,
  forgetting Bluetooth, or re-pairing.
- iOS rotated the private data-container identifier but retained the app-group
  container. Record comparison proved all 98 workouts, daily metrics, and 63
  completed sessions remained intact; only the live session and current-day
  rollup advanced normally.
- During the post-install passive soak, accepted samples advanced
  41,427→41,528 while disconnects, accepted-gap count, and history-attempt
  count were unchanged.
- This is a physical preflight pass, not the Gate-5 positive. A sustained
  elevated-HR effort without a manually started workout is still required.

#### 2026-07-27 — physical positive exposed coarse detector boundaries

- Physical truth: no manual workout; 16:28:23–16:40:48 IST; 736 accepted
  samples; average 126.55 bpm; peak 159 bpm; 337.495 seconds at/above the
  production 125-bpm HRR50 threshold; longest continuous elevated bout
  231.739 seconds; no accepted gap over 15 seconds.
- The signal therefore cleared the short-window detector requirement, but the
  installed app offered 15:38–16:52 (1h14m, 102 bpm average). This is a
  boundary failure, not a sensor-capture failure.
- Root cause: minimum ten-minute windows were anchored every five minutes.
  The real effort began between anchors, leaving no bounded ready window; the
  overlapping all-day journal remained review-worthy at low confidence and
  won overlap collapse.
- **CODE correction:** search ten-minute windows at one-minute start
  resolution while keeping all longer windows on the five-minute cadence.
  Ready-first ranking can then select the bounded physiological effort without
  weakening or deleting low-confidence Strength review behavior.
- The preserved real journal now passes a regression requiring a bounded,
  medium-confidence review overlapping the declared physical interval.
  On-device reprojection remains required before Gate 5 can pass.
- Two `explicit_history_fresh_owner_cutover` events also occurred during this
  run. They produced only approximately 4.7-second micro-gaps and no accepted
  gap over 15 seconds, but prove the earlier short preemption soak did not
  cover natural-use duration.
- **Evidence:** `evidence/2026-07-27-gate5-physical-positive/final-run`.

#### 2026-07-27 — bounded physical activity projection passed on device

- The repaired signed Release reprojected the same saved physical walk without
  asking the user to repeat it.
- The Activity surface now shows one conservative review at 16:36–16:48,
  11 minutes, 130 bpm average, instead of the incorrect 74-minute journal.
- It remains an unnamed “Activity detected” candidate until user confirmation;
  strap HR alone does not invent an activity type.
- The displayed rounded interval contains 723 real strap samples with 719.15
  qualified seconds and no gap over the 15-second load boundary. Production
  Banister TRIMP is 14.541 and workout strain is 1.94. No gap time or estimated
  load is added.
- Focused detector acceptance passed 20/20, including the preserved physical
  journal and the unchanged low-confidence Strength review.
- Install/launch preserved all 98 confirmed workouts and 64 sessions. Accepted
  samples advanced 44,291→44,427 while disconnects (344), accepted gaps (42),
  and history attempts (1,081) remained unchanged.
- **Result:** Gate 5 automatic detection + qualified strain physical pass.
- **Evidence:** `evidence/2026-07-27-gate5-physical-positive/final-run/boundary-fix-on-device-review.jpeg`
  and the adjacent `boundary-fix-preinstall` / `boundary-fix-postinstall`
  runtime pulls.

#### 2026-07-27 — all-day steps must not be a hidden opt-in

- Gate 4 proved WHOOP-only step measurement during explicit workouts, but the
  production install had no `atria.allDayMotion.enabled` preference. The
  previous missing-key default was false, so ordinary walking could never
  refresh the strap step ledger even while live HR was healthy.
- Missing preferences now default to enabled, including existing installs
  created before the setting existed. An explicit false remains a durable user
  opt-out.
- This reuses the existing lowest-priority governor: it yields to explicit
  workouts, calibration, and historical replay, and suspends below the proven
  battery boundary with resume hysteresis.
- Focused safety and presentation acceptance passed 16/16. The signed Release
  was installed in place; 98 workouts, 64 sessions, and daily metrics were
  preserved, accepted HR advanced, and the stream returned to `live`.
- The governor armed the WHOOP historical motion bank without a manual
  workout. A physical ordinary-walking step increment remains intentionally
  unclaimed because the user was stationary after installation; natural
  movement can supply that proof without another formal walk.
- **Evidence:** `evidence/2026-07-27-all-day-motion-default`.

#### 2026-07-27 — preserved natural walks prove all-day accumulation

- A later non-disruptive pull found the app's durable physiological-day v24
  receipt, which the earlier evidence script had not copied.
- From 15:04 IST through 16:29:47, the all-day bank decoded 5,313 WHOOP v24
  rows and published **1,094 strap-only steps** over 4,453 known seconds.
  Missing time remains explicit: 897 seconds, or 83.2% covered.
- This interval includes natural walking performed without a manually started
  workout. It physically proves that all-day accumulation is active and
  durable. It does not prove all-day numeric accuracy because the wearer did
  not count every step in this mixed interval; the separate Gate-4 counted
  walk remains the physical accuracy evidence for the same frozen v13 model.
- The evidence pull now includes
  `whoop4-motion-tick-days-v1.json` so future all-day claims cannot be inferred
  from preferences alone.
- **Evidence:** `evidence/2026-07-27-all-day-motion-existing-walk/current/`.

#### 2026-07-27 — fragmented morning sleep must not be hidden by an awake prelude

- **PHYSICAL observation:** the wearer reported roughly three to four hours of
  morning sleep on July 26, but the installed app showed no sleep review. Four
  retained strap-HR sessions from 07:22:02–11:32:04 IST contain 4h10m of
  reviewable evidence. Two earlier, physiologically distinct short sessions
  caused the former two-hour cluster rule to absorb a long awake prelude and
  reject the whole aggregate as sparse.
- **CODE correction:** a cluster may split at a gap over 90 minutes when the
  trailing block contains at least three hours of dense sleep evidence, no
  internal gap over 20 minutes, and the prelude is either short or at least
  eight bpm higher than the trailing block. Substantial biphasic sleep remains
  combined; the correction does not auto-confirm or manufacture recovery.
- **Regression coverage:** the exact pulled July 26 sessions now produce one
  review-only 07:22–11:32 candidate. The full sleep-audit suite passed 34/34,
  including quiet-awake false positives, substantial biphasic sleep, excessive
  inter-session gaps, and excessive accepted-HR gaps.
- **PHYSICAL delivery:** signed Release executable
  `f0c46a78ba4848a6920f7df62afebd64a2c2cea5f6d15c0fe6b8b104ef3d1712`
  was installed in place. All 98 confirmed workouts and 64 sessions were
  preserved; the confirmed-workout file remained byte-identical. Accepted HR
  advanced 46,837→46,936, accepted-gap count stayed 42, and history-attempt
  count stayed 1,082.
- **ON-DEVICE result:** Home visibly presents `Possible sleep`,
  `7:22 AM – 11:32 AM`, `4h 10m`, with Confirm, Adjust and Dismiss. It remains
  review-only until the wearer acts, so Recovery is not silently rewritten.
- **Evidence:** `evidence/2026-07-27-sleep-prelude-recovery/`.

#### 2026-07-27 — metric truth and native tab-bar audit

- Recovery is intentionally visible from day one, but its evidence state is
  explicit. The current day has no qualified HRV and the recovered sleep is
  still pending review, so the displayed 56% is `Limited confidence`, not a
  high-confidence recovery claim.
- VO₂ max is not currently 49.3 or any other premature number. The physical
  profile has seven accepted resting samples across only 2 of the required 14
  distinct days, so production correctly displays `Learning` as `2/14 RHR`.
  Once admitted, the value remains labelled a rough HR-ratio estimate rather
  than laboratory VO₂.
- HRV, respiratory rate, recovered-interval sleep stages, and temperature
  fail closed when their own qualification evidence is absent. The UI does
  not substitute an inferred number.
- The opaque legacy tab-bar background was removed. A signed Release install
  physically shows the native Liquid Glass control floating without the
  former full-width black shelf.
- Install/launch preserved 98 workouts and 64 sessions, while accepted strap
  samples advanced 48,434→48,474. Focused metric and presentation acceptance
  passed 48/48.
- **Evidence:** `evidence/2026-07-27-liquid-tabbar-metric-audit/`.

#### 2026-07-27 — correction: fallback recovery is immutable across deferred refreshes

- The earlier 56% observation was not a settled recovery authority. The
  persisted July 27 fallback is **46%**, explicitly `unverified`, with sleep and
  qualified HRV excluded and only a conservative RHR contribution.
- Two separate launch races were found physically. First, widget publication
  waited forever behind a superseded history callback and retained an older
  score. Second, after the 46% row loaded, a later history refresh could remint
  it from live RHR and drift Home/Vitals/widget to 41%.
- A structurally valid no-sleep/initial-wear Recovery v2 row now releases the
  widget fence without waiting for unrelated history work, and ordinary
  refreshes preserve that recovery while still advancing cumulative strain.
- **PHYSICAL result:** after the final signed Release launch and asynchronous
  soak, Home, Vitals and the widget payload all remained at **46%**. Strain
  converged at 11.4 across Home/widget. The phone retained 98 confirmed
  workouts and 65 sessions.
- VO2 remains fail-closed at `Learning`: the profile has only 2 distinct
  accepted RHR days toward the 14-day minimum. No premature VO2 number is
  emitted.
- The bottom-bar black shelf was a second, redundant 148-point clear safe-area
  inset—not the native Liquid Glass material itself. Removing that inset lets
  content continue beneath the native glass capsule while existing scroll
  clearance keeps the final card reachable.
- Focused recovery-freeze, launch-settlement and tab-bar regressions passed.
  Installed executable SHA-256:
  `2364c29f60697253b66e67cdc711b3976b12269f8a0378cc3c191345b07de9ea`.
- **Evidence:** `evidence/2026-07-27-recovery-authority/acceptance.md` and
  `evidence/2026-07-27-recovery-authority/final-soak-pass/`.

#### 2026-07-27 — correction: the all-day `0x69` lease is not realtime-R10 authority

- **PHYSICAL observation:** the installed state was deterministically stranded
  at owner `protected_redp_v9`, state `protected_launch_pending`,
  `sequenceSentV9=false`, `stableTransport=false`, and passive status
  `subscribed_no_crc_valid_frames`. The all-day bank was armed 0.11 seconds
  after the persisted motion owner began.
- **CODE diagnosis:** launch treated the shared
  `atria.workoutMotion.ownerStartedAt` value as explicit permission to
  requalify realtime R10. The same all-day bank ownership then bypassed the
  v9 profile handler, so the pending state could neither prove nor recover.
- Gate 4 did not depend on realtime R10. Its accepted step source was the
  asynchronous historical v24 motion bank armed with `0x69`; the separate
  counted-walk acceptance remains 112 measured versus 110 truth.
- **CODE correction:** an all-day bank lease no longer authorizes realtime-R10
  requalification. Only durable active workout intent or the explicit debug
  drill can do so. A stranded launch requalification with no active request
  now returns to the command-free pure-HR v10 owner while preserving the
  independent all-day bank lease.
- The correction sends no BLE command, does not cancel or reconnect the
  peripheral, and does not claim realtime R10. Focused launch-recovery tests
  passed 3/3 at
  `/tmp/atria-all-day-bank-fix/Logs/Test/Test-AtriaTests-2026.07.27_20-40-40-+0530.xcresult`.
- Physical delivery and soak remain required before this correction can be
  called accepted on the strap.

#### 2026-07-27 — exact-source metric-truth candidate prepared, not yet physically accepted

- **CODE correction:** a missing or legacy HRmax source now defaults to
  age-estimated. The former implicit `measured 190` provenance could
  incorrectly raise strain confidence and prematurely unlock the HR-ratio VO₂
  estimate.
- **CODE correction:** current Vitals Recovery, RHR and HRV now use the same
  wake-to-wake Hero authority as Home and the widget. Civil-day rollups remain
  available only for explicitly dated history/trends.
- **CODE correction:** Today sharing resolves current-cycle sleep exactly once.
  A retained prior night cannot leak into the exported duration, score, fill or
  detail after the no-sleep rollover boundary.
- **CODE correction:** if any contributing workout has incomplete HR coverage,
  day strain is presented as a lower bound. One dense workout cannot prove load
  missing from a separate sparse workout.
- **CODE correction:** the Lock Screen workout metric helper gives emphasized
  three-digit heart rate higher layout priority so pulse cannot wrap behind
  secondary metrics.
- **TEST observation:** the four truth fixes passed together 91/91. The complete
  rebuilt simulator suite then passed 2,716/2,716 at
  `/tmp/atria-final-full-green-rerun.xcresult`.
- **BUILD observation:** the signed Release executable is
  `6993fdcdaac222fd8ab6169f329e4993e28949fb59949993d649f5cdc24bea65`.
  Its source fingerprint is
  `a2612556d819094213b51dd6c96788913820e8efd474294243be0f6149ced8da`;
  the dirty-source fingerprint is
  `6ef9c90665d95c85eb730d73386d13b843ab6ab0c3e5a136eb4d4c2c742db8b7`.
- **Acceptance status:** this is software/build evidence only. It does not
  transfer the prior physical Gate 1–5 passes to this binary. In-place install,
  preservation checks, passive live/history/motion soak, the gym workout
  receipt, and the counted all-day step delta remain required.
- **Evidence:** `evidence/2026-07-27-dashboard-truth-integration/acceptance.md`
  and `evidence/2026-07-27-final-product-candidate/app-build-identity.json`.

#### 2026-07-27 — post-gym workout exposes terminal-publication starvation

- **PHYSICAL observation:** the Strength workout is durably saved from
  21:30:32–22:26:10 IST (55m38s), with 2,563 accepted HR samples, 120 bpm
  average, 158 bpm peak, 78% coverage, and computed strain 4.246.
- **PHYSICAL observation:** one continuous 11m52s interval inside that workout
  (21:48:07–21:59:59 IST) remains absent. Its exact ledger row is
  `2DC38C20-BB0C-444D-A132-961B8EA75CD5`, reason
  `explicit_workout_process_restore_gap`; no raw-v2 historical row overlaps
  the interval.
- **UI defect:** the prior 75% threshold rendered the gapped workout as a
  complete `Strain 4.2`. A continuous material `stream_gaps` diagnosis now
  remains Partial above that threshold and presents observed strain/energy as
  lower bounds instead of exact values.
- **RECOVERY defect:** the runtime remained
  `deferred_terminal_materialization` behind an older completed full-drain
  authority. Admission-ledger preparation resumed pending sync but did not
  resume the terminal publication that needed the same ledger. Requests
  arriving during that publication could also remain pending after the lane
  was released.
- **CODE correction (not yet physical proof):** opening the durable admission
  ledger now resumes terminal publication; terminal completion re-arms one
  retained range-loss request; automatic and normal manual repair both select
  the newest exact gap while retaining older gaps for later archival sweep.
- **Evidence:**
  `evidence/2026-07-27-post-gym-final-candidate/preinstall-full/`,
  `evidence/2026-07-27-post-gym-final-candidate/postinstall-soak-runtime/`,
  and `/tmp/atria-postgym-focused-v2.xcresult`.

#### 2026-07-27 — completed admission retention can deadlock terminal publication

- **PHYSICAL evidence diagnosis:** full-drain attempt
  `7a90876a-8ab8-4d9a-9e9e-374a2dc48d8e` durably receipted 18,805 frames
  and reached `HISTORY_COMPLETE`, but its later admission database retained
  only 18,615 attempt-owned frames. Exact receipt enumeration therefore
  correctly failed closed and left publication at `rawSealed`.
- **PHYSICAL archive observation:** immutable raw chunk
  `faddb341-44bd-4950-b7bb-9c1fe108d042` still has an exact matching
  generation/hash/size/row seal. Its target interval contains 134 usable rows,
  covers 129/129 seconds, and every row proves an observation timestamp inside
  that exact command-to-`HISTORY_COMPLETE` window.
- **CODE correction (not yet physical acceptance):** retention now protects
  any completed attempt owned by an unresolved terminal authority. Existing
  affected installs may use the matching immutable seal as a recovery
  authority only with exact seal identity and exact-attempt observation
  bounds. Missing or ambiguous observation evidence remains rejected.
- **CODE correction:** WHOOP `subsec11` coverage timestamps consistently use
  the protocol's 32,768 Hz tick base, not milliseconds.
- **PHYSICAL acceptance:** the corrected installed Release used the immutable
  exact-attempt fallback, admitted 919 metric rows, and advanced the target gap
  to `coverageProven`: 129/129 buckets, 100% density, 1-second maximum gap and
  1-second p95 gap. This physically clears the Gate 2 exact-coverage threshold.
- **PHYSICAL follow-up failure:** consumer publication then failed because the
  retention transaction compared its ISO-8601 whole-second decode to the
  pre-serialization subsecond object. Canonical verification now compares the
  complete persisted representation while retaining exact digest/byte/row
  checks. The subsecond regression and related projection suites pass.
- **CODE hardening:** the same persistence boundary is now enforced for the
  terminal completion record, aggregate snapshot reread, idempotent restart,
  and requested-range containment. A subsecond completion-store-to-inspection
  proof test passes, preventing another restart-only failure after aggregate
  publication.
- Final consumer-store settlement remains pending an unlocked launch; iOS
  rejected the hardened Release relaunch while the phone was locked. The
  hardened binary is installed; coverage proof is already durable and will not
  be repeated or downgraded.
- **Evidence:**
  `evidence/2026-07-27-post-gym-final-candidate/terminal-retention-repair.md`.

#### 2026-07-28 — correction: a full-scan source can extend beyond its history cursor

- **PHYSICAL observation:** after the unlocked relaunch, the exact authority
  remained `coverageProven` at 129/129 buckets and terminal completion
  publication successfully wrote generation 1. The next full-scan attestation
  failed `invalidRecord`; no full-scan completion directory was created.
- **PHYSICAL evidence:** the matched strap cursor watermark is
  `1785089991`, terminal receipt is `1785090195.06456`, and the immutable
  source ends at `1785090206.322`. The sealed source therefore contains a
  short concurrently observed/clock-corrected live tail after both the
  historical cursor and local terminal receipt. Its exact content hash,
  catalog generation and aggregate snapshot remain valid.
- **CODE diagnosis:** `AtriaHistoricalFullScanCompletionStore` incorrectly
  required the historical cursor to be at or after the aggregate's final raw
  timestamp. Those are separate evidence domains: the cursor bounds
  historical no-more-data authority; source bounds authenticate the exact
  hash-bound aggregate and may include live rows.
- **CODE correction (not yet physical acceptance):** source ordering,
  cursor/terminal ordering, hashes and snapshot identities remain fail-closed,
  but a live tail no longer widens or invalidates historical cursor authority.
  Fractional input is validated before whole-second ISO-8601 persistence and
  then compared using its canonical persisted representation, preventing both
  invalid same-second ties and restart-only reread failures.
- **TEST evidence:** exact physical fractional timestamps now persist, reread
  and retry idempotently. A live tail beyond the requested dependency still
  publishes five consumers only when the cursor covers that dependency; the
  same tail with a cursor 60 seconds short publishes none. Focused store and
  consumer coordinator suites pass.
- **Physical settlement remains required:** install the corrected build,
  resume the existing generation without another strap drain, and prove the
  authority advances through completion/projection/consumer commit to
  resolved while preserving the 129/129 coverage proof.
- **Evidence:**
  `evidence/2026-07-28-terminal-retention-device/unlocked-final-state/`,
  `evidence/2026-07-28-terminal-retention-device/unlocked-publication-artifacts/`,
  and
  `/tmp/atria-gate2-invariant-derived/Logs/Test/Test-AtriaTests-2026.07.28_00-59-35-+0530.xcresult`.

#### 2026-07-28 — correction: verified catalog enrichment requires a later completion generation

- **PHYSICAL observation:** after accepting the live-tail invariant, terminal
  publication resumed but deferred with `generationConflict`. The durable
  completion remained generation 1 and no full-scan completion or consumer
  receipt was published. Exact gap coverage remained 129/129 and the raw seal
  remained intact.
- **PHYSICAL evidence:** the generation-1 completion attests catalog
  generation 249. The current catalog is generation 251. Both catalogs contain
  the same 21 immutable chunk identities; generation 251 only enriches two
  older chunks with verified row count, first/last timestamp, size and SHA-256
  metadata. Its canonical catalog hash therefore legitimately differs from
  the already-durable generation-1 record.
- **CODE diagnosis:** terminal retry selected generation 1 solely from the
  transport identity (batch, durable sequence and requested/completed
  timestamps). The completion store correctly rejected that generation when
  presented with the later catalog and aggregate attestation.
- **CODE correction (not yet physical acceptance):** a retry now reuses its
  prior completion generation only when transport identity, catalog
  generation, canonical catalog hash and canonical aggregate snapshot hash
  all match. Verified metadata enrichment advances to the next generation;
  exact retries remain idempotent and generation exhaustion remains
  fail-closed.
- **TEST evidence:** the focused publication/invariant suites pass 28/28. The
  wider history archive, authority, completion, projection, retention and
  verified-reader matrix passes 114/114 with zero failures or skips.
- **Physical settlement remains required:** install in place, resume the same
  durable attempt, and prove generation 2 advances the exact authority without
  another strap drain or loss of the 129/129 coverage proof.
- **Evidence:**
  `evidence/2026-07-28-terminal-retention-device/post-live-tail-fix/`,
  `/tmp/atria-gate2-invariant-derived/Logs/Test/Test-AtriaTests-2026.07.28_01-09-44-+0530.xcresult`,
  and
  `/tmp/atria-gate2-invariant-derived/Logs/Test/Test-AtriaTests-2026.07.28_01-11-03-+0530.xcresult`.

#### 2026-07-28 — correction: archive compaction can starve exact-gap publication

- **PHYSICAL acceptance:** the catalog-enrichment correction published
  terminal completion generation 2 and full-scan completion generation 2
  without another strap drain. Exact coverage remains 129/129 seconds (100%),
  with a one-second maximum and p95 gap.
- **PHYSICAL follow-up failure:** the exact authority remained
  `coverageProven`; no consumer receipt crossed the recovered-data publication
  fence. This is not a Gate 2 pass even though raw coverage and both terminal
  completion records are durable.
- **PHYSICAL storage observation:** the device contained 579 abandoned
  aggregate transaction temporary files totalling 891,648,514 bytes. Repeated
  files were complete shadow copies derived from the same 134 MB legacy raw
  source.
- **CODE diagnosis:** deferred session loading could enqueue archive compaction
  on the same serial projection queue before BLE resumed exact-gap
  publication. The large shadow build then held that lane beyond the finite
  recovered-data lease, leaving the authority parked at `coverageProven`.
  Ordinary semantic or verification errors also left their complete temporary
  aggregate behind.
- **CODE correction (not yet physical acceptance):** an unresolved exact
  authority now owns the shared projection lane through consumer settlement,
  so compaction defers instead of racing it. Retention transactions remove
  their own temporary files on ordinary thrown errors, and generated-artifact
  GC removes only recognized aggregate/manifest temporaries older than one
  hour. Committed and unknown files remain untouched.
- **TEST evidence:** the wider completion, projection, retention, verified
  reader, transaction and generated-artifact matrix passes 149/149 with zero
  failures or skips.
- **Physical settlement remains required:** install in place, resume the
  already-proven authority, and verify it advances to
  `gapResolvedConsumersPending` or `resolved` while preserving generation 2
  and the 129/129 coverage proof.
- **Evidence:**
  `evidence/2026-07-28-gate2-generation-fix/` and
  `/tmp/atria-gate2-invariant-derived/Logs/Test/Test-AtriaTests-2026.07.28_01-29-40-+0530.xcresult`.

#### 2026-07-28 — correction: ordinary history cards can still take the recovery lane first

- **PHYSICAL observation:** the compaction-priority build released
  `historicalConsumerMaterializationInFlight` instead of remaining stuck, but
  the authority still remained `coverageProven`. The physical candidate
  therefore did not pass Gate 2.
- **DEBUGGER evidence:** during the next exact-publication retry, the shared
  `com.atria.history-snapshot-projection` queue was executing an ordinary
  `refreshHistorySnapshotCache` with no completion requirement. Its stack was
  decoding a canonical aggregate page for launch/dashboard history while the
  required recovery publication waited behind it.
- **CODE diagnosis:** deferring archive compaction removed one priority
  inversion but did not stop ordinary history-card projection from entering
  the same lane first.
- **CODE correction (not yet physical acceptance):** every ordinary history
  snapshot now defers while exact recovery owns priority. The recovered-data
  publication step is explicitly identified and is the only history snapshot
  allowed to bypass that gate.
- **TEST evidence:** focused authority, retention transaction and generated
  artifact suites pass 55/55 with zero failures or skips, including the
  recovered-only bypass policy.
- **Physical settlement remains required:** install the corrected build and
  prove the existing authority advances from `coverageProven` without another
  strap drain.
- **Evidence:**
  `evidence/2026-07-28-gate2-generation-fix/physical-lldb-priority-inversion.md`,
  `/tmp/atria-gate2-probe.uvvtZa/`, and
  `/tmp/atria-gate2-invariant-derived/Logs/Test/Test-AtriaTests-2026.07.28_01-44-24-+0530.xcresult`.

#### 2026-07-28 — correction: confirmed-workout recovery reread the archive per workout

- **PHYSICAL observation:** with ordinary dashboard work excluded, the required
  recovered-data pipeline advanced through archive/status projection and then
  timed out its `confirmedWorkouts` component after the full 150-second lease.
  The transaction rolled back and the exact authority correctly remained
  `coverageProven`.
- **PHYSICAL diagnostics:** the recovered projection parsed 304,605,735 bytes,
  83,778 archive rows and emitted 81,107 verified HR points. LLDB then showed
  `scheduleConfirmedWorkoutArchiveRehydration` scanning the archive again for
  one workout window. The persisted store has 100 confirmed workouts, many
  intentionally eligible for incomplete-coverage repair.
- **CODE diagnosis:** the component performed one complete immutable-archive
  scan per eligible workout, an O(workouts × archive) path. Increasing the
  lease would only hide the multiplicative work.
- **CODE correction (not yet physical acceptance):** recovery now performs one
  bounded, fail-closed scan over the union of eligible workout windows, then
  slices that verified point set by each exact workout interval. A global
  1,500,000-point ceiling withholds all HR replacements on overflow; it never
  publishes a partial prefix.
- **TEST evidence:** authority and workout durability suites pass 97/97 with
  zero failures or skips, including union-window ordering and empty-input
  behavior.
- **Physical settlement remains required:** install the optimized candidate
  and rerun the same existing authority to terminal settlement.
- **Evidence:**
  `/tmp/atria-gate2-invariant-derived/Logs/Test/Test-AtriaTests-2026.07.28_01-59-57-+0530.xcresult`.

#### 2026-07-28 — correction: walking-step scans blocked exact HR publication

- **PHYSICAL observation:** the one-pass HR candidate applied the exact
  generation-2 projection, but `confirmedWorkouts` still exhausted its
  150-second lease and rolled the recovered-data transaction back.
- **PHYSICAL diagnostics:** after the single HR scan, the same component read
  56,339,685 bytes of motion history repeatedly for incomplete walking rows.
  It decoded some step windows, but this independent Gate 4 enrichment kept
  Gate 2 from publishing already-proven exact HR recovery.
- **CODE diagnosis:** the broad confirmed-workout rehydration path mixed two
  authorities: recovered HR/load and strap-motion steps. A separate bounded
  step publisher already exists, so the duplicate motion work was both
  unnecessary and capable of starving exact-gap settlement.
- **CODE correction (not yet physical acceptance):** the recovered-data
  workout fence now repairs only HR/load evidence. Walking steps remain on the
  independent one-workout-at-a-time WHOOP/R10 motion lane and cannot extend or
  fail Gate 2.
- **TEST evidence:** the workout durability and recovered-data coordinator
  suites pass, including a regression proving a complete-HR walking workout
  with pending step evidence is not admitted to the Gate 2 rehydration lane.
- **Physical settlement remains required:** install in place and rerun the
  same durable generation-2 authority to a terminal consumer publication.
- **Evidence:**
  `evidence/2026-07-28-gate2-generation-fix/union-scan-physical-console.log`
  and `/tmp/atria-gate2-lane-tests.log`.

#### 2026-07-28 — Gate 2 physical acceptance: exact recovery published

- **PHYSICAL pass:** after separating the motion lane, the existing exact
  generation-2 recovery completed every recovered-data component and logged
  `recovered_derived status=published`. The durable authority advanced from
  `coverageProven` to `gapResolvedConsumersPending`; no new strap drain was
  required.
- **Exact interval proof:** gap
  `37b98471-a122-48d7-8365-4403cd74bc8d` retained 129/129 observed one-second
  buckets, 100% density, one-second maximum gap and one-second p95 gap.
- **Durability/publication proof:** source chunk
  `faddb341-44bd-4950-b7bb-9c1fe108d042` remains sealed at 1,829 rows and
  2,395,673 bytes with SHA-256
  `079c11611d1fe6f3d61239498a6a9eec482833ee453f0c316ab4a5e7d72bfc13`;
  completion generation 2/catalog generation 253 remains published.
- **Lane behavior:** confirmed-workout HR/load repaired 43 rows, then sleep,
  history/daily rollups, HR zones, behavior insights and training load all
  crossed the same transaction fence. Step enrichment remained independent
  and did not extend the Gate 2 lease.
- **Evidence:**
  `evidence/2026-07-28-gate2-generation-fix/terminal-physical/` and
  `evidence/2026-07-28-gate2-generation-fix/hr-motion-lane-physical-console.log`.

#### 2026-07-28 — Gate 3 physical acceptance: manual workout durability

- **PHYSICAL pass:** a stationary-phone Strength workout acknowledged Start
  in about one second, kept publishing live strap HR, acknowledged End in
  0.60 seconds, produced its saved receipt, and dismissed Done in 0.61
  seconds.
- **Durable result:** canonical workout
  `1785188099-1785188212-live_workout_window` contains 119 HR samples over
  112.72 of 113.38 seconds (99% coverage), average 79 BPM and peak 85 BPM.
  The pending workout intent was removed only after canonical persistence.
- **Honest sparse presentation:** the prior gym Strength workout with 78% HR
  coverage is visibly labelled `78% HR · Partial` in Activity history.
- **Prior premature-end finding:** no automatic 55-minute workout timeout
  exists in the installed lifecycle policy, and the fresh physical run did
  not reproduce a phantom end. A future recurrence requires capture of the
  originating in-app or Live Activity End command; it is not accepted as an
  automatic lifecycle behavior.
- **Evidence:**
  `evidence/2026-07-28-gate3-manual-workout/`.

#### 2026-07-28 — durable all-day step receipt was hidden during projection lag

- **PHYSICAL observation:** the current physiological-cycle v24 receipt
  durably contained 1,102 strap-only steps with 7,773 known seconds and
  27,496 missing seconds (about 22% verified coverage), while the app-group
  widget snapshot omitted steps entirely.
- **CODE diagnosis:** Home and the widget read only the asynchronously rebuilt
  `HistorySnapshot`. The stronger receipt already fsynced by
  `AtriaWhoop4MotionTickDailyStore` was not a direct presentation authority, so
  an ordinary snapshot delay could temporarily turn verified evidence into
  “unavailable.”
- **CODE correction:** the daily
  receipt store is now a shared cached authority. Home and widget merge the
  exact current wake-boundary receipt with the projected days, retain exact
  canonical conflicts fail-closed, and select only the strongest partial
  coverage. A partial subtotal remains a lower bound (`≥1,102 · Partial
  archive · 22% covered`); no phone-pedometer value or extrapolation is used.
  Saving a stronger receipt triggers both Home refresh and widget publication.
- **PHYSICAL pass:** after the in-place Release installation, the app-group
  payload published 1,102 steps from `verifiedCanonical`, completeness
  `partial`, and coverage `0.2203918455`. The confirmed-workout and daily-metric
  stores remained byte-identical, and live HR continued.
- **TEST evidence:** durable-receipt merge, stronger-coverage ordering,
  exact-over-partial precedence, and lower-bound presentation all pass in
  `Test-AtriaTests-2026.07.28_03-21-00-+0530.xcresult`.
- **Evidence:**
  `evidence/2026-07-28-terminal-retention-device/unlocked-final-state/`
  and
  `evidence/2026-07-28-metric-truth-fix/`.

#### 2026-07-28 — current-cycle strain lost its partial qualifier after midnight

- **PHYSICAL observation:** the widget accumulated wake-to-wake strain across
  midnight, but tested incompleteness only against workouts whose start was on
  the new civil day. The contributing 78%-coverage gym Strength workout could
  therefore remain in the numeric strain while its `Partial` warning vanished.
- **CODE correction:** current
  Home, Today and widget strain now qualify every workout overlapping the exact
  physiological cycle. Civil-day history continues to use the existing
  civil-day helper.
- **PHYSICAL pass:** on the installed Release, Home displayed the current-cycle
  score as `≥ 16.3` with `Partial · sparse HR` while live strap HR remained
  present. The contributing pre-midnight 78%-coverage workout therefore cannot
  lose its uncertainty disclosure after midnight.
- **TEST evidence:** the prior-day sparse-workout/current-cycle regression and
  adjacent Today, widget, strain, and physiological-day suites pass, including
  the combined `Test-AtriaTests-2026.07.28_03-21-00-+0530.xcresult`.
- **Evidence:** `evidence/2026-07-28-metric-truth-fix/`.

#### 2026-07-28 — confirmed-sleep HRV must span reconnect-bounded sessions

- **CODE finding:** the exact confirmed-sleep calculation summed qualified
  five-minute HRV window counts across all overlapping sessions, but derived
  RMSSD only from sessions that individually contained at least three
  windows. A sleep split into reconnect-bounded chunks could therefore report
  three or more qualified windows while publishing no HRV.
- **CODE correction:** every five-minute window still qualifies independently
  inside one session with the existing RR provenance, beat-density,
  continuity, and artifact gates. Only those already-qualified ln(RMSSD)
  scalars are combined across sessions; raw RR intervals are never joined
  across a reconnect boundary. Three or more qualified windows in the exact
  confirmed-sleep interval now publish `exp(median(lnRMSSD))`.
- **Fail-closed behavior:** legacy or source-ambiguous RR remains excluded.
  Reference validation is not required for local HRV, but still controls the
  higher-confidence tier.
- **Physical-data clarification:** the latest July 26 confirmed sleep had
  already been requalified to HRV 50 from eight windows, and its saved
  recovery uses HRV. The current July 28 `HRV unavailable` state has no
  current-cycle confirmed sleep and is therefore correct; stale sleep HRV is
  not carried forward.
- **TEST evidence:** the split-session publication regression and ambiguous-RR
  rejection pass in
  `Test-AtriaTests-2026.07.28_03-37-47-+0530.xcresult`.

#### 2026-07-28 — all-day bank owner blocked its own hourly close

- **PHYSICAL fail:** the production all-day `69/01` bank remained armed from
  03:06:57 through 04:09 IST while accepted live HR continued. The scheduled
  hourly checkpoint never updated `lastDailyCheckpointAt`, never re-armed, and
  the durable v24 receipt remained byte-identical at 1,102 strap-only steps.
- **Exact evidence:** `atria.workoutMotion.ownerStartedAt` was present from
  03:06:52. This is expected: the all-day governor uses the shared motion lease
  while its bank accumulates. There was no pending workout-intent file and no
  manual workout in progress.
- **CODE diagnosis:** `checkpointDailyHistoricalMotionBankIfNeeded` required
  the shared owner lease to be absent. That condition cannot become true during
  healthy all-day capture, so the intended one-hour close/offload could remain
  blocked forever.
- **CODE correction:** the shared owner stamp is no longer interpreted as a
  manual-workout blocker. Eligibility now defers only for an active persisted
  manual workout, a live calibration hold, a history transport owner, an
  unarmed bank, or the existing battery safety condition. The same separation
  applies to the subsequent async exact-window offload, which still requires a
  current accepted-HR connection and a durable pending ticket. This does not
  alter command bytes, history durability, or the accepted-HR path.
- **TEST evidence:** 431/431 BLE, bank, motion projection, daily receipt,
  strap-step ledger, and step-model tests pass in
  `Test-AtriaTests-2026.07.28_04-16-50-+0530.xcresult`.
- **PHYSICAL pass:** the installed Release closed the production bank, re-armed
  the next bank, preserved its exact pending offload, and extended the existing
  same-day durable receipt in place. The receipt advanced from 16,324 to 20,069
  decoded WHOOP rows, 3,032 to 3,997 motion ticks, and 1,102 to 1,169
  strap-only steps. `capturedThrough` advanced from 806842786.814209 to
  806846482.9997559. This is a durable file diff from the app container, not a
  UI projection or an archive-row count.
- **Acceptance status:** PASS for the production one-hour arm → close → exact
  offload → durable receipt boundary. Counted all-day numeric accuracy remains
  a separate acceptance question.
- **Evidence:**
  `evidence/2026-07-28-all-day-step-checkpoint/03-35/`,
  `evidence/2026-07-28-all-day-step-checkpoint/04-07/`, and
  `evidence/2026-07-28-all-day-step-checkpoint/04-09/`, compared with
  `evidence/2026-07-28-all-day-step-checkpoint/expiration-fix-background-mature/receipt.json`.

#### 2026-07-28 — background lease expiration could strand history ownership

- **PHYSICAL observation:** after the corrected all-day bank closed at
  04:21:00 IST, the exact durable offload ticket was created, real history rows
  reached the canonical archive, and the next bank re-armed. The phone then
  remained locked. From 04:23:17 onward the generation stayed frozen at
  `history_first_frame_received`; its background lease remained persisted as
  `active`, live-state freshness stopped advancing, and the durable step
  receipt remained byte-identical.
- **CODE diagnosis:** the UIKit background-task expiration closure returned
  immediately after enqueueing a new `Task { @MainActor ... }`. iOS is allowed
  to suspend the process as soon as the expiration handler returns, so the
  queued cleanup could never execute. The stranded generation consequently
  retained the proprietary history transport without reaching a terminal or
  restoring live HR.
- **CODE correction:** expiration now crosses to the MainActor synchronously
  before returning. It ends the finite UIKit lease, retains every durable row
  and offload ticket, and resets only the connected history transport without
  ACK, abort, cursor advancement, or gap clearance. Normal disconnect handling
  remains the sole generation finalizer and standing reconnect restores live
  collection.
- **TEST evidence:** 424/424 BLE recovery, historical policy, drain reducer,
  motion-bank ledger, and durable step-receipt tests pass in
  `Test-AtriaTests-2026.07.28_04-30-56-+0530.xcresult`.
- **PHYSICAL observation after installation:** while the app was backgrounded,
  the same durable receipt did advance (20,069 decoded rows, 3,997 ticks,
  1,169 steps). The background execution lease had not expired in the captured
  snapshot, however, so that advancement proves the offload durability path
  but does not physically exercise the repaired expiration callback.
- **Acceptance status:** code regression PASS; durable-prefix preservation and
  receipt advancement PASS; physical expiration-callback/reconnect acceptance
  remains pending until iOS actually invokes that boundary.
- **Evidence:**
  `evidence/2026-07-28-all-day-step-checkpoint/fixed-install-baseline/` through
  `evidence/2026-07-28-all-day-step-checkpoint/continuation-current/`, plus
  `evidence/2026-07-28-all-day-step-checkpoint/expiration-fix-background-30s/`
  and
  `evidence/2026-07-28-all-day-step-checkpoint/expiration-fix-background-mature/`.

#### 2026-07-28 — connected history progress could starve live heart rate

- **PHYSICAL failure:** the current-device UI claimed `Live 60 bpm` while the
  persisted raw-HR and stream timestamps were already more than three minutes
  old. The peripheral remained connected and a productive history generation
  had materialized 3,669 rows, but standard 2A37 delivery had stopped. History
  progress therefore concealed a stale live stream rather than proving that
  both transports remained healthy.
- **CODE diagnosis:** `connectedChunkedBackfill` was only an admission label.
  Once admitted, a connected production history generation had no slice
  boundary while rows continued to arrive; the 30-minute idle watchdog
  correctly did not fire, and live-HR keepalive/reconnect paths correctly
  deferred to the history transport owner. A productive archive drain could
  consequently monopolize the connection.
- **PHYSICAL correction to the first implementation:** an admission-time
  `connected` classifier missed fresh-owner transactions because the deliberate
  cutover temporarily disconnects before history starts. After arming on the
  first real stream-5 row, a locked run proved a second constraint: iOS
  suspended the process roughly seven seconds into the history owner despite
  the finite background lease, so a 45-second Swift timer was not a valid
  locked-phone safety boundary.
- **CODE correction:** every production history serve now arms from its first
  real row. Foreground history retains a 45-second/15-second-silence bound.
  Background history uses a five-second/three-second-silence slice and evaluates
  synchronously on every served frame, so the callback that durably enqueues
  the row can also relinquish the radio before iOS suspends timers. Atria then
  records the release, retains the exact request and every fsynced ingress
  prefix, adds a five-minute live-first cooldown, and disconnects only the BLE
  transport so standing reconnect can restore live HR. It sends no ACK or
  abort, advances no cursor, and resolves no gap. Attended Gate 2 and selector
  research drains retain their explicit full-drain behavior.
- **TEST evidence:** 428/428 BLE cadence, historical policy, motion-bank
  ledger, daily receipt, strap-step ledger, and strap-step model tests pass in
  `Test-AtriaTests-2026.07.28_06-46-45-+0530.xcresult`.
- **Acceptance status:** foreground callback-bound release and automatic live
  restoration physically PASS. The installed build persisted
  `released_for_live_heart_rate`, entered its five-minute live-first cooldown,
  and accepted 45 additional HR samples in 27 seconds without resolving the
  pending history ticket. Locked/background acceptance exposed the separate
  pre-first-frame thermal admission failure documented below and therefore
  remains open.
- **Evidence:**
  `evidence/2026-07-28-current-metric-audit/runtime/` and
  `evidence/2026-07-28-current-metric-audit/live-stall-check/`, plus
  `evidence/2026-07-28-connected-slice-physical/callback-final-baseline/`
  and
  `evidence/2026-07-28-connected-slice-physical/callback-final-live-soak/`.

#### 2026-07-28 — locked post-workout history could bypass thermal admission

- **PHYSICAL failure:** after the foreground slice release and its five-minute
  live-first cooldown, the phone remained locked while iOS reported serious
  thermal pressure. A pending post-workout motion-bank request nevertheless
  advanced its attempt counter and acquired the background history lease. The
  process suspended before receiving its first stream-5 row; accepted HR and
  the active journal then stopped advancing, and neither the frame-driven slice
  release nor its first-frame Swift watchdog could execute.
- **CODE diagnosis:** `explicitPostWorkoutBankRequest` was included in
  `explicitHistoricalRequest`, and that aggregate was passed to the thermal
  helper as if it were an attended user/research command. The offload caller
  also called `markOffloadAttempt` before knowing whether history admission had
  succeeded.
- **CODE correction:** only an attended explicit user or research request may
  bypass serious/critical thermal deferral. A post-workout bank ticket now
  remains durable and leaves the live radio untouched until pressure recovers.
  Its attempt counter advances only after
  `requestOfflineHistoricalSyncIfNeeded` returns true.
- **PHYSICAL correction:** the signed Release build was installed in place
  without uninstalling, clearing data, or changing pairing. Low Power Mode
  deliberately selected governor mode `serious` while the phone was locked.
  Across the retry interval, history remained
  `deferred_thermal_pressure`, the attempt count remained exactly 1,100, the
  prior background lease stayed terminal, and accepted HR plus the active
  journal continued advancing. The pending recovery was retained rather than
  consumed.
- **Acceptance status:** locked thermal admission and live-radio preservation
  physically PASS; focused reliability regression 429/429 PASS in
  `Test-AtriaTests-2026.07.28_09-22-37-+0530.xcresult`.
- **Evidence:**
  `evidence/2026-07-28-connected-slice-physical/locked-cooldown-expiry/`,
  `evidence/2026-07-28-connected-slice-physical/locked-post-cooldown-45s/`,
  and
  `evidence/2026-07-28-connected-slice-physical/locked-history-first-frame/`,
  followed by the corrected-build proof in
  `evidence/2026-07-28-thermal-admission-fix/low-power-locked-baseline/`
  and
  `evidence/2026-07-28-thermal-admission-fix/low-power-locked-soak/`.

## Notebook maintenance rules

1. Append every physical command experiment, including failures and no-response cases.
2. Record exact command bytes, ordering, delays, connection state, phone lock state, and strap behavior.
3. Link the durable evidence directory or capture file.
4. Keep observation separate from interpretation.
5. Never overwrite an earlier conclusion silently; append a correction with the evidence that changed it.
6. Never call a protocol behavior reliable until the relevant physical acceptance test passes.
