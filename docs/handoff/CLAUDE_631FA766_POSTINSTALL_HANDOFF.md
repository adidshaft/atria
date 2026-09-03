# Claude handoff — finish the installed `631fa766` acceptance only

## Scope

Do **not** modify source, rebuild, reinstall, change the strap mode, toggle
Bluetooth, wipe app data, or upload to TestFlight. The latest intended build is
already installed in place on the iPhone. Finish only the bounded post-install
runtime/visual checks below once the Mac and iPhone are available again.

## Exact source and Git state

- Branch: `dev`
- Local + origin: `631fa766e6f96a68c05eef42f9f9272789465608`
- Upstream parity at handoff: `0 0`
- Author + committer: `adidshaft <adidshaft@gmail.com>`
- Commit `18181f46` is the corrected NEW-3 ambient-gap change.
- Commit `631fa766` adds the explicit continuity policy:
  - ambient/all-day HR: display-only continuity through exactly 5 minutes;
  - workout HR: strict 2-minute boundary;
  - raw and dense-bucket paths use the same selected policy.
- Focused proof: `AtriaHeartRateTimelineWindowTests` 36/36 and
  `AtriaActivitySectionsCacheTests` 57/57, zero failures; all four edited files
  parse; diff check clean.
- Fresh exact-commit bottom-navigation proof:
  `AtriaLiveTabAccessoryTests` 38/38, zero failures, including native
  `.tabBarMinimizeBehavior(.onScrollDown)`, adaptive accessory behavior, no
  custom drag gesture, and no opaque/empty bottom shelf. Result bundle:
  `/private/tmp/atria-live-tab-final-20260810-2230.xcresult`.
- The 14 pre-existing user chart files remain unstaged and uncommitted. Do not
  stash, reset, overwrite, or stage them.

## Exact installed build

Evidence root:

`/private/tmp/atria-new3-final-device.xxkTCJ`

Clean source worktree:

`/private/tmp/atria-new3-final-device.xxkTCJ/source`

Build/install facts:

- `** BUILD SUCCEEDED **`
- Configuration: Debug
- Signing: `Apple Development: Aman Pandey (9BFSABP27W)`
- In-place install; preserved app data
- Installed bundle path:
  `/private/var/containers/Bundle/Application/2805023D-B5F7-42F9-B9E0-84FBC8001774/Atria.app/Atria`
- Binary SHA-256:
  `d47e7c0b1736c283df9b52caf58ff72559ef584dd801d29ee6ac17aaa21cda26`
- Installed provenance SHA-256:
  `2ba0d18b7288d1f9aabca93ceb4dd0367ce6bda669e6d5003fc2afd25a2647f5`
- Provenance: `source_commit=631fa766...`, `source_dirty=false`, source match
  PASS, no blockers
- Official WHOOP process count: 0

The install harness intentionally ended its console process with SIGINT after
45 seconds and then exited 3 because quiet logging yielded zero `ATRIADBG`
lines. This happened **after** successful build/install/provenance. Codex then
launched the installed app normally without debug arguments.

## Completed physical checks

### Normal process and BLE ingress

First normal acceptance PID: `20545` at the exact installed path above.

Post-install baseline:

- raw `1,080,973`
- accepted `1,080,887`
- zero `86`
- held `0`
- dropped `0`
- raw gaps `469`
- accepted gaps `471`

Same PID after warm-up:

- raw `1,081,170` (`+197`)
- accepted `1,081,084` (`+197`)
- zero/held/dropped/gaps unchanged
- `strap_stream_state=live`
- notifying + GATT reads true
- accessibility: `Strap connected and live heart rate is arriving.`
- provenance still PASS

Before the controlled screenshot-route relaunches, totals later reached raw
`1,081,342` / accepted `1,081,256` (`+172/+172` again), with gaps and artifact
counters still unchanged.

### Physical render

`/private/tmp/atria-new3-final-device.xxkTCJ/screen-t0.png`

This exact-build screenshot proves:

- measured Sleep ring is filled (8h 7m), not dotted;
- live HR is visible (77 bpm);
- the app rendered normally after install;
- the existing minimized/floating bottom navigation remains present.

## Why the final check stopped

Codex used the DEBUG-only `--atria-ui-screen vitals` route to prepare the Vitals
screen. The phone auto-locked before capture, so the direct device screenshot
was correctly black. iPhone Mirroring then reported the Mac was locked. Do not
attempt any credential workaround; the user must unlock the Mac manually.

Codex restored a final normal no-argument launch. The summary pull showed PID
`20561`, provenance/source PASS, connected/notifying/GATT true, and a 54.8-second
surface age labelled `warming`. A later journal audit established that this was
**not** a startup deadlock: PID `20561` had ingested dense 2A37 through 22:06:20
(`6,424 raw == 6,424 accepted`, last BPM 100), with one B restore namespace,
empty pending recovery set, and no false-off evidence. The apparent summary lag
is consistent with the 30-second diagnostic flush, and 54.8 seconds is below
the intentional 120-second repair boundary. Immediately afterward CoreDevice
changed the phone to `unavailable`, so only a bounded live resample remains:
do not reinstall/relaunch; sample the same process at +90 and +150 seconds.
Treat it as a defect only if a connected/notifying/GATT stream stays frozen
beyond 120 seconds without bounded repair or a disconnect callback.

## Only remaining checklist

1. User manually unlocks the Mac and reconnects/unlocks the cabled iPhone. Never
   access Passwords or ask Claude/Codex to bypass the lock.
2. Confirm:
   `xcrun devicectl list devices | rg 3803F5B6-1666-56D3-A71A-62F131F6CE3B`
   reports `available`.
3. Do **not** reinstall. Pull read-only state from the clean worktree:

   ```bash
   ./pull_atria_state.sh \
     --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
     --runtime-only \
     --evidence-dir /private/tmp/atria-new3-final-device.xxkTCJ/resume-final
   ```

4. Require all of the following:
   - exactly one Atria main process at the installed bundle path;
   - provenance/source match PASS for `631fa766...`;
   - raw and accepted both strictly exceed `1,081,342` / `1,081,256` by the
     same delta;
   - zero remains 86; held/dropped remain 0;
   - raw/accepted gaps remain 469/471;
   - link status connected;
   - stream state live, packet age fresh, notifying and GATT reads true;
   - no watchdog/jetsam/false-Bluetooth-off/new competing WHOOP process.
5. With the Mac unlocked and the physical phone locked, reconnect iPhone
   Mirroring. Navigate the **normally launched** app to Vitals > Live:
   - capture HR and Stress screenshots with `devicectl device capture screenshot`;
   - confirm no diagonal bridge across a >5-minute gap;
   - if a factual <=5-minute hiccup is visible, it should remain a smooth
     monotone run;
   - do not manufacture BLE loss merely to create a gap.
   Synthetic boundary proof is already green for exactly 5m vs 5m+1s and 2m
   workout strictness, so absence of a natural short dropout is not a failure.
6. Leave one normal no-argument Atria process running. If a debug route was used,
   relaunch once without arguments and repeat step 4.
7. Add a factual final comment to GitHub issue #33. Keep it open because its
   acceptance text still names TestFlight; no TestFlight upload is authorized.
   Latest forensic update already posted:
   `https://github.com/adidshaft/atria/issues/33#issuecomment-5243316195`.

## Full-goal closure gates (do not overclaim)

The bounded `631fa766` run proves one healthy saved-device window, but it does
not yet close the user's entire connection/transmission goal. After the phone
returns, use the same installed build and close these in order:

1. **Capture the reported contradiction before changing state.** If the UI says
   Bluetooth is off/connecting/reading, capture the exact PID, CoreBluetooth
   manager state, saved UUID, restore namespace, notifying/GATT flags, packet
   age, raw/accepted counters, and the actionable false-off timestamp. A stale
   persisted `connected` label alone is not proof of a live stream.
2. **Saved-device continuity:** one unchanged PID for 5–10 minutes, including
   one background/lock/foreground cycle. Require raw delta > 0, raw == accepted,
   flat gaps/artifacts/reconnect/app-cancel counters, fresh packet age, one
   namespace, no reaping/watchdog, and no false Bluetooth-off diagnosis.
3. **Fresh strap motion in the same window:** `standard_hr_only` is insufficient.
   Use only an already-authorized normal motion-capable/app-owned checkpoint;
   require fresh compact/receipt or protocol IMU counters to advance while HR
   remains uninterrupted. Do not count phone Core Motion as strap motion.
4. **First-use connection:** physical proof requires an isolated fresh app-data
   environment. Do not wipe the sole preserved device install without explicit
   user permission. Until such a run exists, label first-use source/test-covered
   but physically NOT EXERCISED.
5. **Bottom-bar visual pair:** the exact source test is green and historical
   physical expanded/collapsed screenshots exist, but capture a same-PID
   scroll-top/after-scroll pair if iPhone Mirroring is available. Never bypass
   the Mac lock to obtain it.

If a false-off flip or stalled successor reproduces, diagnose and fix that
specific contradiction before repeating acceptance. If no new eligible motion
publication occurs, label motion NOT EXERCISED rather than FAIL.

The disposable 1.6 GB temporary DerivedData directory was removed after the
exact simulator run to recover disk space; all source, installed provenance,
runtime pulls, screenshots, and the xcresult above remain intact. Regenerate
build products only if a real source fix becomes necessary.

## Stop conditions

Stop and report instead of retrying/reinstalling if provenance differs, PID
turns over unexpectedly, raw and accepted deltas diverge, any gap/artifact
counter grows, Bluetooth is falsely reported off, a >5-minute chart gap is
bridged, or workout HR uses the ambient 5-minute policy.
