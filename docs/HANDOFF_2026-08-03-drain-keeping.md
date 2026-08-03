# Atria — Session Handoff (2026-08-03, ~5 AM IST)

Read this top-to-bottom and you are exactly where the previous session left off. No prior context needed.

---

## 0. The product, in one line
**Atria** is an iOS companion app for the **WHOOP 4** strap. WHOOP 4 does **not** broadcast a step count or most metrics live — Atria computes steps / sleep / recovery from the strap's **onboard-banked motion + HR**, which it **drains over Bluetooth** and materializes into insights. So: **if the drain doesn't keep up, every metric goes stale / shows `--`.** Reliable draining is the whole ballgame.

- **Work in this worktree:** `cd /Users/amanpandey/projects/atria/.claude/worktrees/atria-background-continuity-88ce90` (this IS the working dir; the handoff lives at `docs/HANDOFF_2026-08-03-drain-keeping.md` here).
- **Branch:** `claude/atria-background-continuity-88ce90` — **clean at `dafe3fca`** (drain-keeping P0a/P1/P1b/P2/P0b + P2-telemetry all committed; `git log --oneline` to see them).
- Physical device (Aman's iPhone): `3803F5B6-1666-56D3-A71A-62F131F6CE3B` (devicectl over Wi-Fi/USB)
- Strap peripheral: `C125C62E-C432-53E7-BD19-9761251B2C3E`
- Build sim (iOS 27): `85C288CE-EA97-4A98-B650-44BCF49F2CA5` ("Atria RC Clean")
- Signing team: `JP4HU7X6G7`

---

## 1. The goal we were chasing
**"Today's strap steps show `--` until the next day."** The user wants today's steps to fill within **15–60 min**, and more broadly: the app should **continuously, asynchronously catch up** from the strap in the background (phone locked / person asleep) so metrics are **always up to date**.

## 2. What we learned (root cause — this is the important part)
The `--` is **NOT** a step-detection bug, **NOT** battery, **NOT** the clock, **NOT** the memory balloon (that's separately fixed). It's a **drain problem**:

- The strap history transport is a **ring buffer** (`getDataRange` 0x22 → `capacity=131072`, `write_cursor`, `read_cursor`, `pending_records`). It streams **forward-from-cursor, oldest-first, ~real-time, NO seek**. ACK advances `read_cursor`.
- A **time-windowed seek is PROVEN DEAD** on WHOOP 4 (tested on-device): the strap accepts a `[startUnix,endUnix]` serve (0x16) but returns **zero** records (`history_started=false`). `productionHistoricalExactRangeTransportEnabledAndProven=false`. **Do not chase recent-first seek.**
- The old **full-drain-from-oldest is non-convergent** (never re-enable `productionHistoricalFullDrainGapRecoveryEnabled`).
- **Convergence math (the crux):** while draining, new data arrives at 1×, so a backlog only closes at **(rate − 1)** per wall-hour. At the healthy **~1.8×** we observed, a **27 h backlog ≈ 34 h to fully catch up**. Anything **<1× diverges** (loses ground).
- **Why the rate collapses:** the drain re-arm is partly **HR-driven**; when the user is still/asleep HR ticks are sparse → re-arm starves → sub-1× → diverges. Also **iOS throttles a backgrounded app** the longer it runs, and there were layered deferral gates (below).
- **Foreground DEFERS history by design** (`deferred_interactive_live_priority`) to protect the live HR stream. **Background is where it drains.** (Counterintuitive but confirmed — keep the app backgrounded + strap worn for draining.)

## 3. What we shipped (all committed, tests green, on `858a9f50`)
The drain has a cascade of gates that deferred background catch-up. We removed the ones that were bugs, guarded:

| Commit | What |
|---|---|
| `8203aad2` | **P0a** — a parked terminal-coverage authority (`.gapResolvedConsumersPending`) made `requestOfflineHistoricalSyncIfNeeded` return false for all catch-up until the app was foregrounded. New disposition `resumeLocalPublicationAndContinueRawDrain` lets the RAW drain advance `read_cursor` in background, decoupled from the (foreground-gated) materialization. **+ P1**: `rangeLossBackfillRetryDelay` chains slices at 8s when the last slice made durable progress (progress-gated → no churn). |
| `f5b65a52` | **P1b** — `shouldAllowConnectedRangeLossCatchUp`: guarded connected catch-up (settled R10 owner, no recent disconnect storm). |
| `2d339ac7` | **P2** — `isFlushMaintenanceWindow`: bypass the connected-link guards (`connected_slice_cooldown`, `connected_live_link`, `live_link`) when a backlog is pending on a settled/storm-free link. |
| `8c47b1f8` | **docs/drain-keeping-flush-design.md** — the ideal freshness-driven flushing design (read it; it's the north star). |
| `858a9f50` | **P0b** — `BGProcessingTask` was scheduled `earliestBeginDate = +2h`; during a backlog make it eligible in ~60s so iOS grants frequent processing windows. Its handler already runs the range-loss drain to completion. |

On-device verified: P0a/P1/P1b work — undisturbed & backgrounded, the drain converges at **~1.8×** with **`earlyDisconnects=0`** (no link damage).

## 4. Dead-ends (do NOT repeat these)
- **Foreground "speed-run"** (relaxing guards + materialization + cadence throttle to drain fast in foreground): whack-a-mole — each fix revealed another foreground-only gate (`deferred_terminal_materialization` → `throttled` → `deferred_archive_warm` → `deferred_interactive_live_priority`). **Foreground fundamentally defers history.** All those edits were **reverted** (repo is clean).
- **Repeated `--terminate-existing` relaunches** drop the strap link, reset iOS's background budget, and re-trigger archive warm-up — they **cost progress** (drove the rate to ~0.1×). Leave the app alone to settle.
- **Don't reinstall while the phone is locked** — it kills the running app and devicectl can't relaunch (RequestDenied) until unlocked.
- **`battery.at` is the battery-read timestamp, NOT HR freshness.** Use `rearm ...fresh=1` for live-HR presence.

## 5. THE BIG MOVE — strap wipe (done, worked)
User decision: don't wait 34 h for a backlog of mostly-sleep data — **wipe the strap and start fresh**, rely on continuous flush going forward. Mechanism = **`AtriaWhoop4SacrificialHistoryTrimPolicy`**: preflight `getDataRange(0x22)` → **`forceTrim(0x19, payload FE×8+00)`** → postflight verify `readCursor==writeCursor`. It advances the strap's read cursor to *now*, discarding the backlog.

**Executed on-device Aug 3 and verified:** `pending_records 9859 → 1`, `trim_finished: "verified_backlog_collapse"`. On relaunch, `rangeLossBackfillPending` cleared. **The strap is now WIPED, caught up to real-time, and continuously flushing.**

⚠️ **The trim is `#if DEBUG`-only.** To run it we built a **Debug** build (its widget failed App-Groups signing → fixed with `CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=JP4HU7X6G7 PROVISIONING_PROFILE_SPECIFIER="" -allowProvisioningUpdates`). **That Debug build is what is CURRENTLY INSTALLED on the phone** (functional + caught-up, just unoptimized).

## 6. CURRENT STATE (right now)
- Strap: **wiped, caught up, worn, ~70% battery.**
- Phone: **optimized Release build (`858a9f50`) installed** (Aug-3 05:20, replaced the temporary Debug build; trim is DEBUG-gated again), app launched, `rangeLossBackfillPending` cleared, materializing then steady.
- Continuous flush (P0a/P1/P1b/P2/P0b) running → stays current going forward (no backlog to accumulate; keeps pace with ~1× new data easily).
- Repo clean at `858a9f50`. No background tasks needed (the overnight watchers were stopped; a `walk-watcher2` may still be running harmlessly — read-only).
- The 4:30 AM walk validation was **sacrificed** by the wipe (user is fine redoing a walk anytime).

## 7. NEXT STEPS (in priority order)
1. ✅ **DONE (Aug-3 05:20)** — optimized Release build (`858a9f50`) built + installed + launched on the phone, replacing the temporary Debug build. Daily performance restored; trim DEBUG-gated again.
2. **Validate the step engine** (task #21 close-out): user does a known-count walk (they cited **265 steps** as reference; ~2% expected error). On the now-caught-up strap it should surface within the flush window. Compare engine vs actual.
3. **Build task #23 — wipe feature (two entry points, same productionized trim):**
   - **(a) Onboarding wipe-vs-sync choice.** First-run, when a connected strap already has banked data, show a one-line two-option choice: **"Start fresh · clears the strap, ready in seconds (Recommended)"** vs **"Bring my history · syncs ~Xh in the background"** (ETA computed from `pending_records`).
   - **(b) Manual wipe from Settings.** A permanent **"Wipe strap / Start fresh"** action in the app's Settings so the user can wipe on demand any time (not just onboarding) — same trim, with a clear confirm dialog ("This clears unsynced data on the strap. Continue?"). This is what we did by hand tonight; make it a real in-app button.
   - **Shared:** **productionize the trim out of `#if DEBUG`** into a code path where the user's explicit tap (onboarding "Start fresh" OR the Settings confirm) IS the sacrificial-loss confirmation (no launch flags); keep all safety (preflight → forceTrim 0x19 → postflight verify `readCursor==writeCursor`, one-shot, fail-closed). See memory `atria-onboarding-strap-wipe-choice` + `docs/drain-keeping-flush-design.md`.
4. **Remaining drain-keeping hardening** — ✅ timer-driven re-arm (P3), ✅ connected-slice teardown fix (P4), ✅ charge-resume (P5), ✅ flush-debt tracker (P6), ✅ retire the non-convergent full drain (design #6 — sealed via `exactRangeTransportAuthorityAvailable`, `5036374c`) all DONE (committed, sim-green, see §7b). **Left (validation only, no code):** verify BGProcessing windows actually fire on-device; confirm P3.1 `lastMaintenanceReArmAt` populates under a background/HR-sparse soak. (Design doc + task #22.)
5. **Task #20 (backlog):** validated SpO2 on WHOOP 4 (decoder + reference calibration).

## 7b. LOOP — task #22 hardening (P3–P6 DONE; committed, sim-green, install pending)
A `continue implementing` cron loop (`c4bd0c6c`, every 10 min) was running. Task #22 hardening done in **smallest-safe-first** order, each its own build+test+commit. All four are pure-helper + wiring + unit test, 428 tests green across `AtriaBLERecoveryCadenceTests` + `AtriaBLEHistoricalRecoveryPolicyStructureTests`:
1. ✅ **DONE (`6df7f9c4`)** — P2 telemetry: `lastDurableFlushBoundaryOKAt` success-path timestamp.
2. ✅ **DONE (`e83661bb`) — P3 timer-driven re-arm independent of HR** (the anti-divergence fix). Bounded 60 s maintenance ticker re-arms the range-loss drain when the normal (accepted-HR-driven) loop has been silent past a 120 s floor. Pure helper `shouldReArmRangeLossBackfillOnMaintenanceTick`; anti-churn = the floor (any real re-arm refreshes `lastRangeLossBackfillReArmAt`); eligibility reuses P1b+P2 (`isFlushMaintenanceWindow` || `shouldAllowConnectedRangeLossCatchUp`). Telemetry: `lastMaintenanceReArmAt.v1`. Never sends BLE directly (re-enters `scheduleRangeLossBackfillIfNeeded`).
3. ✅ **DONE (`adb64982`) — P4 connected-slice teardown fix.** `shouldReleaseConnectedHistorySlice` gains `productiveBacklogHold`: suppress the live-HR-silence teardown while the slice is productive (recent durable row progress on the same uptime clock the GATT idle-timeout trusts) AND in the P2 maintenance window. Stalled slices still release; the idle-timeout watchdog still drops a wedged link. Foreground unchanged.
4. ✅ **DONE (`97f0c786`) — P5 charge-resume.** On the phone's charging rising edge (`UIDevice.batteryState` unplugged→charging/full) with a backlog pending, re-arm + bring up the P3 ticker. Pure helpers `shouldResumeDrainOnPhoneChargeEdge` / `phoneStateIsCharging`. Rising-edge only.
5. ✅ **DONE (`e500ee2a`) — P6 flush-debt tracker.** Every observed 0x22 getDataRange records `pending_records` as first-class debt (`flushDebtPendingRecords/ObservedAt/Level.v1`). `flushDebtLevel` classifies caught_up(≤~2 min)/low/high(≥~1 h @ ~1 Hz). First escalation: HIGH debt shortens the P3 re-arm floor (→ tick interval) so a deep backlog closes faster; stale debt (>15 min) ignored. Existing deferral guards left intact (adds a priority on top, doesn't rip them out).

6. ✅ **DONE (`060eb4fb`) — P3.1 fix (the soak caught P3 inert).** A 45-min on-device soak (frontier 84→42 min behind ≈1.56×, `lastMaintenanceReArmAt=None`) exposed that shipped P3 never engaged the connected WHOOP 4 path: (a) its ticker START sat AFTER `scheduleRangeLossBackfillIfNeeded`'s `gap_retained_transaction_unverified` early-return (always taken on connected WHOOP 4 — raw verified, transaction-recovery unverified because full-drain OFF), and (b) its tick re-armed via that same suppressed lane; the forced-handoff lane also needs `verifiedMetricRecovery` (false for WHOOP 4). **The lane that actually drains connected WHOOP 4** = `requestOfflineHistoricalSyncIfNeeded` + P1b/P2 admission — what the BGProcessing handler calls (`requestOfflineHistoricalSyncAwaitingCompletion` → force:false/handoff:false for WHOOP 4). Fix: start the ticker BEFORE the suppress return (+ on `markRangeLossBackfillRequired`); tick now calls `requestOfflineHistoricalSyncIfNeeded(force:false, handoff:false)` gated to background (`!foregroundInteractiveMode`). Storm gate + `!syncInProgress` + floor bound churn. **P7 (daytime trickle) is SUBSUMED** by this — the corrected P3 re-arms the connected drain every 60–120 s while backgrounded (daytime-in-pocket included); no foreground trickle (that's the reverted dead-end).

**KEY SOAK LEARNINGS (Aug-3):** (1) the strap is only ~3 min behind (`flushDebtPendingRecords=193`); the user-visible staleness is the phone-side drain **stalling in bursts** (frontier froze 13:26→14:09), not raw rate. (2) `capturedThrough` (step decode frontier) advances in the BACKGROUND raw path (motion-tick compact store synchronized at each drain checkpoint, AtriaBLEManager ~29995) — NOT foreground-gated — so closing the drain stalls is what fixes step freshness. (3) BOTH the `scheduleRangeLossBackfillIfNeeded` lane (suppress) and the forced-handoff lane are gated off for connected WHOOP 4; the ONLY connected-drain entry is `requestOfflineHistoricalSyncIfNeeded` + P1b/P2. Anyone touching drain-keeping must target THAT lane.

**Remaining task #22:** verify BGProcessing windows actually fire on-device (P0b/P5); confirm P3.1 `lastMaintenanceReArmAt` populates under a background/HR-sparse soak. (Design doc #6 — retire the non-convergent full-drain — is DONE: sealed in `5036374c` so no flag flip can re-arm the seekless replay; only validation remains.)

**⚠️ NOT INSTALLED YET.** Device still runs `858a9f50` (P0a/P1/P1b/P2/P0b). User chose "finish P5/P6, then install once" → build+install a single Release with P3–P6 and validate. On-device pull (Aug-3 ~12:56): frontier ≈ **1.4 h behind** (steps captured through 11:32), `rangeLossBackfillPending=True` (interior gaps), owner `fallback_active`, `earlyDisconnects=0`, battery 84%. `lastMaintenanceReArmAt=None` confirms P3 not deployed.

Build cmd (sim test): `xcodebuild test -project Atria/Atria.xcodeproj -scheme AtriaTests -destination 'platform=iOS Simulator,id=85C288CE-EA97-4A98-B650-44BCF49F2CA5' -only-testing:AtriaTests/AtriaBLERecoveryCadenceTests`. Release for device: `-scheme Atria -configuration Release -destination 'platform=iOS,id=3803F5B6-1666-56D3-A71A-62F131F6CE3B' -allowProvisioningUpdates`.

## 8. Hard constraints (never violate)
- Never re-enable the non-convergent full drain (`productionHistoricalFullDrainGapRecoveryEnabled` / `automaticFullDrainRecoveryEnabled`).
- No history seek (`[start,end]` serve returns nothing on WHOOP 4).
- Never change persisted completion **digest bytes** (SHA-256 parity is load-bearing).
- **Announce each device action; keep the user in the loop; device pulls are dev-only diagnostics.** Don't run silent parallel device tasks.

## 9. Verification cheatsheet
- Pull prefs: `xcrun devicectl device copy from --device <DEV> --domain-type appDataContainer --domain-identifier com.adidshaft.atria --user mobile --source "Library/Preferences/com.adidshaft.atria.plist" --destination p.plist` → `plutil -convert xml1`.
- Drain frontier = max `unix7` in `Documents/atria-historical/segments/raw-v2/*.jsonl` (Apple/CF epoch NOT used here — these are unix).
- Step store: `Library/Application Support/Atria/verified-step-evidence-v1/whoop4-motion-tick-days-v1.json` (per-window steps; Apple-epoch fields).
- Key prefs: `offlineSync.lastStatus`, `offlineSync.persistedDrainRearmDiagnostic` (`link/fresh/workout/sync/materializing/authority/defer`), `offlineSync.rangeLossBackfillPending`, `protectedR10.earlyDisconnects` (storm), `protectedR10.cleanOwnerState`, `battery.level`.
- Debug logs: launch with `--atria-enable-debug-logs`; `--console` on devicectl often does NOT stream on this transport — prefer the app's own capture files under `Documents/atria-*`.

## 10. Relevant memories
`atria-today-steps-drain-backlog`, `atria-drain-keeping-hardening-plan`, `atria-onboarding-strap-wipe-choice`, `atria-fulldrain-nonconvergent`, `atria-background-continuity-root-cause`, `atria-3gb-memory-balloon-real-cause`, `atria-keep-user-in-loop`, `atria-verification-protocols`.
