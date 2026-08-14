# Claude handoff — install and physically close `f68c14c9`

This supersedes the Git/source portions of the older `631fa766` handoff. Do
not modify source unless a physical run demonstrates a concrete contradiction.

## Current authoritative state

- Branch: `codex/whoop-remaining-product-gaps`
- Local + origin: `f68c14c9352e40972d38f420279144cba761b467`
- Upstream parity at handoff: `0 0`
- Parent: `631fa766e6f96a68c05eef42f9f9272789465608`
- Author + committer: `adidshaft <adidshaft@gmail.com>`
- Commit scope: exactly three files:
  - `Atria/Atria/AtriaBLEManager.swift`
  - `Atria/AtriaTests/AtriaBLEObservedConnectionIdentityTests.swift`
  - `Atria/AtriaTests/AtriaBLEUnsavedRestoredCandidateTests.swift`
- The 14 user-owned chart diffs and all handoff documents remain
  unstaged/uncommitted. Never stash, reset, overwrite, or stage them.
- GitHub issue #33 remains open. Latest update:
  <https://github.com/adidshaft/atria/issues/33#issuecomment-5243772407>
- No TestFlight upload is authorized or required for this pass.

## Source result already complete

The first-use identity path is now fail-closed:

1. Provisional first-use or restored `didConnect` does not persist or replace
   the saved strap UUID.
2. An unsaved candidate becomes durable only after WHOOP proprietary-service
   evidence, or 2A37 from a candidate already qualified by WHOOP scan identity.
   Generic 180D/2A37 cannot claim ownership.
3. An exact saved UUID retains immediate reconnect behavior.
4. Promotion and observed-success publication revalidate the complete callback
   source at the mutation site: epoch, UUID, object identity, and connected
   state.
5. Cold `central_powered_on` first use scans broad immediately. Saved/manual
   flows retain bounded filtered -> widen -> retry behavior.
6. Only CoreBluetooth's exact `.poweredOff` state maps to the UI's
   “Bluetooth off” status.
7. Success counting is one edge per callback epoch, while both didConnect/GATT
   callback orders still run the idempotent recovery reducers.

Validation already completed:

- affected selectors: 19/19 passed, 0 failures;
- final three files frontend-parse clean;
- `git diff --check` clean;
- two independent adversarial audits: CLEAR, zero P0/P1.

## Current physical blocker

The paired iPhone 15 Pro is presently unreachable:

- CoreDevice: `unavailable`
- `xcdevice`: `available: false`
- no iPhone USB endpoint
- paired + Developer Mode enabled, but unlock state cannot be verified

The currently installed app is the older clean `631fa766` build. Do not claim
`f68c14c9` is installed until the provenance checks below pass.

## Essential physical checklist

### CP0 — reconnect and preflight

1. User reconnects the cable (or restores the same-LAN pairing) and unlocks the
   iPhone. Never access Passwords or attempt a credential workaround.
2. Require the target
   `3803F5B6-1666-56D3-A71A-62F131F6CE3B` to report `available` in CoreDevice.
3. Confirm no competing `xcodebuild`, `xctrace`, `devicectl` mutation,
   `live_device_debug`, `ios-deploy`, or `idevicesyslog` owner.
4. Free enough disposable build space if needed. Do not delete source,
   evidence, user files, or broad directories.

### CP1 — clean build, in-place install, provenance

1. Create a fresh detached clean worktree at exact `f68c14c9`.
2. Build a signed Debug device app using the repository's
   `live_device_debug.sh` provenance path. No debug protocol/mode flags, no
   database wipe, no Bluetooth toggle, no TestFlight.
3. Install in place so app data is preserved.
4. Hard requirements before runtime acceptance:
   - `source_commit=f68c14c9352e40972d38f420279144cba761b467`
   - `source_dirty=false`
   - source/binary/installed provenance verification PASS
   - Apple Development signing for Aman Pandey
   - exactly one Atria main process after the harness exits and the final
     normal no-argument launch is established
   - no official WHOOP process/coexistence owner

Stop on build, signing, install, provenance, or process-identity mismatch.

### CP2 — saved-device HR/status continuity

Observe one unchanged acceptance PID for 5–10 minutes, including one normal
background/lock/foreground cycle. Require:

- connected + notifying + GATT reads true;
- fresh packet age and truthful accessibility/status copy;
- raw and accepted counters both advance by the same positive delta during a
  healthy contact window;
- zero/held/dropped/gap counters do not grow;
- no disconnect/failure/app-cancel/reconnect churn;
- one production restore namespace, no duplicate/reap/0x002b disable;
- no watchdog, jetsam, false “Bluetooth off”, or PID turnover;
- HR resumes after the lifecycle edge without manual radio recovery.

If a connected/notifying surface freezes, wait through the intentional
120-second repair boundary and capture the exact contradiction before changing
state. Do not reinstall or toggle Bluetooth to hide it.

### CP3 — normal strap-motion publication (only if naturally eligible)

Do not force a protocol mode or ad-hoc BLE command. If the app-owned motion bank
has been armed for at least 10 minutes and history ownership is released,
perform exactly one normal foreground “drain-on-glance” checkpoint.

Require the single chain:

1. `terminal_and_live_restored=1`
2. `workout_motion_bank status=glance_checkpoint_due`
3. `workout_motion_bank status=stopped cmd=6900`
4. exactly one `workout_motion_bank_offload ... attempt=1`
5. durable compact checkpoint + terminal ownership release
6. `whoop4_daily_steps ... window=immediately_prior changed=1`

Also require HR continuity from CP2 to remain intact. Stop after the first
qualified terminal publication; do not drain every pending ticket. If the bank
never becomes naturally eligible, record `NOT EXERCISED`, not failure.

### CP4 — first-use physical proof (permission-gated)

This cannot be honestly exercised on the sole preserved install without
changing app data. Use a spare device or ask the user for explicit permission
to wipe only Atria's app data. Do not infer that permission.

Acceptance on a fresh environment:

- cold `central_powered_on` immediately starts the broad WHOOP-specific path;
- a generic heart-rate peripheral cannot become the saved owner;
- the first WHOOP-qualified current-scan candidate owns deterministically;
- saved UUID remains absent through provisional didConnect;
- saved UUID appears only after WHOOP service or qualified 2A37 evidence;
- accepted HR begins and remains dense;
- relaunch reconnects to that exact saved UUID without requiring a scan,
  duplicate namespace, false-off flip, or manual intervention.

Without a spare device or explicit wipe approval, label CP4
`SOURCE/TEST CLEAR — PHYSICALLY NOT EXERCISED`.

### CP5 — bounded visual evidence

On the exact installed build, capture only the useful physical pair:

- Vitals Live HR + Stress: no diagonal bridge across a factual >5-minute gap;
  ambient <=5-minute hiccups may remain a smooth monotone run.
- Today bottom navigation: one scroll-top and one after-scroll screenshot from
  the same PID, proving the native bottom bar minimizes to the single accessory
  action and expands again.
- Sleep stages remain unavailable unless qualified motion-backed stage evidence
  exists. Never fabricate REM/deep. If qualified stages exist, their displayed
  durations must reconcile to the validated segments.

Do not manufacture BLE loss merely to create chart gaps.

## Final reporting

After each physical checkpoint, update issue #33 with exact commit, installed
binary/provenance hashes, PID window, counter deltas, namespace/status facts,
and evidence paths. Keep the issue open unless its TestFlight acceptance text is
explicitly revised or TestFlight is separately authorized and completed.

If CP1–CP3 and CP5 pass but CP4 lacks a permitted environment, report the app as
saved-device accepted and first-use source/test-cleared, with physical first-use
explicitly pending. Do not overclaim full first-use acceptance.
