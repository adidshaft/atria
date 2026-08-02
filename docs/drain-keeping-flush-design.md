# Drain-Keeping / History Flush — Design

_Status: in progress (2026-08-02). Author: continuity work on `claude/atria-background-continuity-88ce90`._

## Why this exists

Almost everything Atria "synthesizes" — steps, naps, activity, daily summaries,
recovery — is computed from strap motion/HR **after it drains off the strap**.
When the drain stalls or crawls, recent data never reaches the phone, so those
surfaces silently lag or show `--`. Timely, consistent flushing is therefore a
prerequisite for up-to-date metrics, not a nice-to-have.

North star: **bound metric latency** — recent data ≤ ~15 min behind during the
day, fully caught up by morning — instead of "flush when we happen to get a
lucky moment."

## Hard constraints (design around these; do not fight them blindly)

1. **Single command pipe / shared radio.** WHOOP 4 runs live HR and history over
   one proprietary pipe; they contend. Opening the history profile on a live
   link has physically dropped the link in the `pure_hr_v10` R10 fallback.
2. **Ring-buffer, forward-from-cursor FIFO.** `GET_DATA_RANGE (0x22)` returns
   `capacity` / `write_cursor` / `read_cursor` / `pending_records`. The serve
   (`0x16 [0x00]`) streams sequentially from `read_cursor`; ACK advances it. The
   `read_cursor` is the convergence anchor.
3. **No seek.** A time-windowed serve (`0x16 [startUnix,endUnix]`) is accepted by
   the strap but streams **zero** records (proven on-device Aug 2:
   `history_started=false frames=0`). `productionHistoricalExactRangeTransportEnabledAndProven = false`.
   Recent-first-by-timestamp is not available.
4. **Full-drain-from-oldest is non-convergent** (replays oldest flash record at
   ~1x, no seek). Stays OFF (`productionHistoricalFullDrainGapRecoveryEnabled`).
5. **iOS background limits.** A backgrounded app gets bursts (CoreBluetooth
   state-restoration wakes; `beginBackgroundTask` ~seconds–minutes;
   `BGProcessingTask` = longer, low-priority, granted while charging/idle).
6. **Materialization is CPU-heavy** and foreground-gated (the `cpu_resource_fatal`
   history-queue projections). It must not block the cheap raw drain.

## The core reframe

"Flush only while disconnected" is a **fragility workaround** for #1, not a
principle. On a healthy link, connected flushing works. The policy should be
driven by **flush debt + link health + who's watching**, not by luck.

## Design: freshness-driven, tiered, budgeted flushing

### 1. Flush-debt tracker (the missing brain)
Make `pending_records` + time-behind a first-class, persisted signal. Every
flush decision keys off debt, not scattered gates. Low debt → gentle; high debt
→ escalate. Replaces ~5 independent deferral guards with one explicit priority.

### 2. Three flush modes, chosen by context
- **Live-guarded trickle** (awake, worn, foreground/active): small bounded
  slices interleaved with live HR so the stream is never starved. Steady-state
  ~15 min latency. (≈ task #17 daytime drain admission.)
- **Maintenance-window flush** (idle + backgrounded/locked — the "asleep on the
  charger" window): relax the connected-link guards and flush hard (chained
  slices, no live-HR-silence teardown). Clears backlog nightly. **Shipped as P2**
  (`isFlushMaintenanceWindow`).
- **Reconnect burst** (existing): keep as a supplement, not the primary path.

### 3. Right iOS primitive for overnight
Replace the single short `beginBackgroundTask` (dies → `orphaned_process_terminated`)
with **`BGProcessingTaskRequest`, `requiresExternalPower = true`** — iOS grants
these long, low-priority windows while charging overnight. Pair with CoreBluetooth
state-restoration wakes. _(Not yet implemented — needs the Info.plist
`BGTaskSchedulerPermittedIdentifiers` entitlement + register/schedule/handle
lifecycle + on-device validation that iOS actually grants the window.)_

### 4. Link-health-adaptive admission (kills the disconnect crutch)
Replace "defer if connected" with "allow connected flush **if link is healthy**"
— gauged by recent early-disconnect rate / R10 state. Healthy → flush connected.
Flaky → fall back to reconnect-burst. Evidence-driven. _(P1b + P2 encode the
storm-gate; a fuller RSSI/rate signal is future work.)_

### 5. Decouple raw drain from synthesis
Raw flush (advancing `read_cursor`) must always make durable progress; the heavy
synthesis/materialization is a separate scheduled job (its own `BGProcessingTask`,
chunked, charge-gated). **P0a started this** (raw drain no longer blocked by a
parked terminal materialization authority).

### 6. Convergence guarantee
Every slice ACKs → advances `read_cursor` → permanent progress. Never restart
from oldest. Make the chunked range-loss drain THE drain; retire the old
full-drain path entirely.

## A good day under this design
- **Daytime:** trickle flush → steps/naps ~15 min fresh.
- **Evening on charger:** maintenance flush clears the day.
- **Overnight sleep + charging:** `BGProcessingTask` deep flush + synthesis →
  wake to fully up-to-date metrics.
- **Any disconnect:** burst tops it off.
- **Missed a window:** debt tracker escalates automatically.

## Shipped vs remaining (as of 2026-08-02)
- ✅ **P0a** (`8203aad2`) — parked terminal-consumer authority no longer blocks
  the raw range-loss catch-up lane (`terminalHistoryRequestDisposition` →
  `resumeLocalPublicationAndContinueRawDrain`). On-device verified; frontier
  advances; `earlyDisconnects=0`.
- ✅ **P1** (`8203aad2`) — `rangeLossBackfillRetryDelay` chains slices at 8s when
  the previous slice made durable progress (progress-gated → no churn).
- ✅ **P1b** (`f5b65a52`) — `shouldAllowConnectedRangeLossCatchUp`: guarded
  connected catch-up (settled owner, no storm). On-device: bypasses clean-owner
  deferral, no storm.
- ✅ **P2** (`2d339ac7`) — `isFlushMaintenanceWindow`: when backgrounded + backlog
  + settled + no storm, bypasses the three connected-link guards
  (`connected_slice_cooldown`, `connected_live_link`, `live_link`). Tested +
  compiled; **on-device validation pending**.
- 🔨 **BGProcessingTask overnight window** (#3) — highest-value remaining.
- 🔨 **Flush-debt tracker** (#1) and **link-health admission** (#4) — make it
  self-regulating.
- 🔨 **Retire non-convergent full-drain** (#6).

## Open risk / decision
Fast **connected** catch-up is entangled with **R10 qualification**: while the
strap sits in `pure_hr_v10 / fallbackActive`, connected history is what the guards
protect against. Two paths: (a) fix R10 qualification (hard, separate saga) so
connected history is first-class, or (b) route around it via the maintenance
window (P2) + link-health admission, accepting bounded link churn when nobody is
watching live HR. Current direction is (b). All changes keep full-drain OFF, add
no seek, and never alter persisted digest bytes.

Related memory: `atria-drain-keeping-hardening-plan`, `atria-today-steps-drain-backlog`,
`atria-fulldrain-nonconvergent`, `atria-background-continuity-root-cause`.
