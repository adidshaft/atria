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
4. **Remaining drain-keeping hardening** (so it never diverges even off-charger/HR-starved): timer-driven re-arm independent of HR during a backlog; connected-slice teardown fix; charge-resume; flush-debt tracker; verify BGProcessing windows actually fire; retire the non-convergent full drain. (Design doc + task #22.)
5. **Task #20 (backlog):** validated SpO2 on WHOOP 4 (decoder + reference calibration).

## 7b. LOOP — next concrete step to implement (start here)
A `continue implementing` cron loop (`c4bd0c6c`, every 10 min) is running. Do task #22 hardening in **smallest-safe-first** order, each as its own build+test+commit, appending a ✅ line to §6/§7 after each:
1. ✅ **DONE (`6df7f9c4`)** — P2 telemetry: added `lastDurableFlushBoundaryOKAt` success-path timestamp (AtriaBLEManager.swift ~30130, schema AtriaBLESchema.swift). Compile-verified on sim.
2. **← START HERE. Timer-driven re-arm independent of HR** (the real anti-divergence fix): during a backlog (`rangeLossBackfillPending`) + connected + settled + no storm, re-arm the range-loss drain on a bounded timer even when HR ticks are sparse (don't rely on accepted-HR callbacks). Gate + progress-guard like P1 so it never churns; keep constraints §8.
3. Connected-slice teardown fix (don't release a productive drain on live-HR silence during a large backlog); charge-resume on power-state edge; flush-debt tracker. See `docs/drain-keeping-flush-design.md`.
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
