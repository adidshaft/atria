# Atria final goal status — `99809085`

Updated: 2026-08-11 (Asia/Kolkata)

## Authority

- Pushed branch: `codex/whoop-remaining-product-gaps`
- Exact tip: `99809085a83158cd8db62ceea73d0e31bbff507a`
- Remote parity verified with `git ls-remote`.
- Commit chain over the previously accepted base:
  - `ab071eb34d247f4cf44e8cd8912bd478c1df9784`
  - `1991c6242e4b0a06a5c9db2f9b767176bdaeec42` — physiological Activity days
  - `25db23abc6d9731061fb402462fa588cfef81c87` — preempt stalled connected history for live HR
  - `99809085a83158cd8db62ceea73d0e31bbff507a` — cross-calendar wake-day ownership
- Every author and committer is `adidshaft <adidshaft@gmail.com>`; no AI/co-author trailer.
- The exact candidate worktree was clean after removing the temporary external-evidence symlink.
- No TestFlight upload was performed.

## Completed checkpoints

### 1. Saved-device Bluetooth continuity source fix

- Only stale exact connected-raw history may be preempted.
- Ordinary history, workout history, motion-bank work, and diagnostic owners remain exclusive.
- The preemption path revalidates the exact generation, peripheral object, strap ID, callback source, and BLE epoch.
- It finishes the history generation while preserving durable spool/backlog, clears continuation, persists and synchronizes an absolute five-minute-or-longer cooldown, and only then rebuilds canonical HR transport.
- It does not synthesize an ACK or ABORT.
- A background or foreground-to-lock raw slice is bounded to one clean ACK.

### 2. Physiological Activity days

- Historical Activity resolves wake-to-wake instead of midnight-to-midnight.
- A confirmed main sleep belongs exactly once to its final-wake day.
- Resumed sleep shares that wake day.
- Naps and pending detections remain overlap evidence.
- No-sleep dates use the deterministic event-local rollover; unknown history remains an explicit civil fallback.
- Workout Recovery attribution fails closed across a rollover or invalid following sleep.
- Activity now re-derives wake ownership from the factual wake timestamp plus event timezone, so travel or a different caller calendar cannot hide or duplicate a saved sleep.

### 3. Verification

- Exact full serial suite: **4,082 passed, 0 failed, 9 intentional skips (4,091 total)**.
- Focused wake-day/Activity regression gate: **108 passed, 0 failed**.
- Earlier combined focused integration gate: **619 passed, 0 failed**.
- Final independent exact-commit audit: **CLEAR; no P0/P1**.
- Swift parse and `git diff --check`: clean.
- Full-suite result: `/private/tmp/atria-goal-final-full-20260811c.xcresult`
- Focused result: `/private/tmp/atria-goal-final-wakeday-test-20260811b.xcresult`

### 4. Signed physical build

- Fresh detached source: `/private/tmp/atria-final-998.AoausO/source`
- Build: Debug, bundle `com.adidshaft.atria`, version `1.0`, build `5`.
- Build log ends `** BUILD SUCCEEDED **`.
- Signer: `Apple Development: Aman Pandey (9BFSABP27W)`.
- Team ID: `JP4HU7X6G7`.
- `codesign --verify --deep --strict`: pass.
- Binary SHA-256: `15bfbd7d0a4335bb42cb9ad6dba4cfcf6fcca61a167432359265c8245c24e6f5`.
- Source fingerprint: `f7c63c851fe108b14df5cd747c9d519140cbbd8615067e0dcb42bfff014a5526`.
- Build provenance: pass, `source_commit=99809085...`, `source_dirty=false`.
- Evidence root: `/private/tmp/atria-final-998.AoausO/evidence`

### 5. GitHub maintenance

- #33 source/test update: https://github.com/adidshaft/atria/issues/33#issuecomment-5249054667
- #25 wake-to-wake update: https://github.com/adidshaft/atria/issues/25#issuecomment-5249054805
- Both remain open. No issue was closed and no TestFlight claim was made.

## Current blocker

The iPhone is connected and paired but still reports `passcodeRequired: true`. Installation must not proceed while it is locked.

Required user action: unlock the iPhone and leave it on the Home Screen, wired, with the strap nearby/worn. Do not open WHOOP or start a workout.

The old exact `ab071eb3` install is still present. Its preinstall data container is:

`/private/var/mobile/Containers/Data/Application/2B7AAAAE-89BA-485D-A3C5-FDD16C9DDAE9`

The in-place install must preserve that exact data-container path.

## Remaining physical checklist

### A. Install and provenance

- [ ] Recheck unlocked state and absence of another device/build owner.
- [ ] Install the exact signed `.app` in place; never uninstall or wipe.
- [ ] Confirm exactly one Atria app, version/build match, and unchanged data-container path.
- [ ] Bind postinstall metadata to the build identity.
- [ ] Copy `atria-installed-app-provenance.json` into the app Documents directory.
- [ ] Verify bound provenance locally against both the built app and installed metadata.
- [ ] Foreground-launch once without a console tether.
- [ ] Establish one exact new PID/path with live/notifying/fresh 2A37 HR.

### B. Locked ten-minute history/HR gate

- [ ] Pull a live `prelock-t0` checkpoint.
- [ ] Lock once with the Side button.
- [ ] Poll exact PID/path every 15 seconds for 600 seconds.
- [ ] Require raw HR delta == accepted HR delta and at least 300 accepted samples.
- [ ] Require zero new zero/held/dropped samples.
- [ ] Require no new gap count and maximum accepted-HR interval under 30 seconds.
- [ ] Require automatic connected raw history to be genuinely admitted.
- [ ] Preferred: one durable raw page with live restoration and no preemption.
- [ ] If one `preempted_for_live_heart_rate` occurs and HR returns within 45 seconds with persisted cooldown, mark **HOLD**, not seamless PASS.
- [ ] Fail on process turnover, repeated reconnect, gap over 45 seconds, false Bluetooth-off, provenance mismatch, or repeated history attempt inside cooldown.
- [ ] Pull `locked-t10` and preserve unified logs/counters.

### C. Unlocked visual gate

- [ ] Partial Strain such as `>=11.9` shows a continuous electric-blue factual arc, not the grey beaded unavailable ring.
- [ ] Strain detail retains the lower-bound value and does not show target/zone/coaching authority.
- [ ] Vitals tab bar minimizes on a real downward scroll and restores on reverse scroll without a blank frame or content jump.
- [ ] Activity Today contains only the newest main sleep for the current wake day.
- [ ] Activity previous day contains the older main sleep and between-wake workout; no row appears on both days.
- [ ] Activity HR and Stress preserve real gaps without a fabricated diagonal bridge.

Required screenshots:

- `today-strain-ring.png`
- `strain-detail.png`
- `vitals-tab-expanded.png`
- `vitals-tab-minimized.png`
- `vitals-tab-restored.png`
- `activity-today-physiological.png`
- `activity-previous-physiological.png`
- `activity-heart-rate.png`
- `activity-stress.png`

## Claude follow-up — presentation only

Only start this after the exact `99809085` physical gate above is recorded. Work from a fresh detached clean worktree and preserve the 14 user-owned chart edits in the main worktree.

1. Retake the exact Strain screenshot before editing. If numeric partial Strain already shows `>=value` with a blue factual arc, do not re-fix it.
2. If desired, replace the truly unavailable ring with one thin continuous neutral outline—no beads, dashes, fake cap, fake progress, or metric-colored magnitude.
3. Make Strain detail compact and useful: lead with `Today · >=x` plus one factual limitation line; keep partial values out of exact trends and suppress targets, zones, remaining-target arithmetic, and coaching.
4. Reuse `AtriaSleepHypnogramCard(night:)` in Vitals so visible lanes are Awake, REM, Light, and Deep. SWS may fold into Deep for presentation only; never rewrite raw SWS storage or inference.
5. Missing motion remains fail-closed: `Stages unavailable` / `Motion data required`.
6. Do not modify BLE, history preemption, step authority, Recovery/Strain scoring, stage inference, raw stage semantics, or physiological-day ownership.
7. Require focused tests, full serial suite, parse/diff checks, physical screenshots, `adidshaft` authorship, and no TestFlight.

