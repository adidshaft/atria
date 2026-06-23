# Codex Handoff — Real-time BLE collection validation (worn, daytime, ~2–3h)

Date: 2026-06-23
Goal: Confirm on a physical iPhone, **worn during the day over the next few
hours** (not overnight), that the recent BLE fixes hold — continuous collection,
no reconnect churn, and automatic recovery of any silent link.

You (Codex) have the cabled iPhone. Start cold; everything you need is below.

## What was fixed (validate these)

Key fixes on `main` (HEAD region):
- `3647a1d` — HR-continuity & accepted-HR watchdogs no longer **tear down a still-
  `.connected` link** for brief HR gaps; they re-assert the subscription and keep
  the connection (new action `reassert_keep_connection`). Reserve teardown for a
  dead link or ≥60s gap.
- `68cc562` + `5c17b7d` — **foreground keepalive watchdog**. In long-wear mode the
  full supervisor is paused while the app is foreground; that left a silent-but-
  "connected" link unrecovered when the screen stays on (the "wore it all night,
  collected nothing" bug). The keepalive, armed at cold launch, re-asserts after
  75s of total `2A37` silence and reconnects after a further 75s. It uses its own
  arm time as the silence reference so a **state-restored** connection (no
  `connectedAt`) is still covered.
- `90966e3` — **app-switch lifecycle fix**. iOS can sit in `.inactive` during
  app switching; Atria now keeps BLE in its current mode during that transient,
  checkpoints realtime state, and only moves to unattended mode on true
  `.background`. On foreground return it re-asserts the standard HR notify/read
  path without disconnecting the strap. This prevents transient app switches
  from restarting long-wear supervision or waiting for the next keepalive tick.
- `7edf8fd` — **background app-switch hardening**. `.background` scene changes
  now use a dedicated checkpoint/keep-link path instead of reusing
  `handleUnattendedMode`. The path flushes realtime state, keeps the foreground
  keepalive armed, reasserts the standard HR notify/read path when connected,
  and explicitly avoids `cancelPeripheralConnection`.
- `655c863` — **background supervisor resume**. True `.background`
  transitions now resume the full long-wear supervisor with the current
  rest/max-HR profile after flushing, while transient `.inactive` app-switch
  states remain checkpoint-only. This keeps unattended collection protected by
  the same watchdog/checkpoint path used for normal background wear.
- `2a0491d` — **disconnect continuity fix**. A transient BLE disconnect during
  long-wear now checkpoints the active journal and reconnects without finishing
  or fragmenting the live session. The manual Disconnect button is tracked
  separately so user-requested disconnects stay disconnected instead of
  immediately reconnecting.
- `4ec0757` — **protected long-wear default**. Normal startup now defaults to
  protected long-wear collection with low-radio standard HR and offline sync
  enabled, so users do not have to keep the phone unlocked or discover a hidden
  mode before background-safe collection starts.
- Current worktree after `4ec0757` — **monitor/harness hardening**. The harness
  classifies iOS developer-profile trust launch failures explicitly, and the
  realtime monitor only raises `KEEPALIVE_NOT_ADVANCING` when the keepalive tick
  is flat and the live stream is also stalled. Positive raw/accepted 2A37 data
  remains the primary proof that the link is alive during app switches.

## Device + paths (constants)

```
CoreDevice id (devicectl):   3803F5B6-1666-56D3-A71A-62F131F6CE3B
Xcode dest UDID (xcodebuild): 00008130-000C74820130001C
Bundle id:                   com.adidshaft.atria
Container prefs plist:       Library/Preferences/com.adidshaft.atria.plist
Container sessions:          Documents/sessions.json
Container active journal:    Documents/atria-active-session.json
Container gate snapshot:     Documents/atria-gate-status.txt
```

Build/install/launch harness (env vars, NOT --device flags — the script reads env
before arg parsing):
```sh
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
ATRIA_XCODE_DEVICE_ID=00008130-000C74820130001C \
  ./live_device_debug.sh --seconds 40 --long-wear-mode --leave-running \
  --log logs/live-device/rt-validate.log
```
Important harness note: `--leave-running` performs a non-console `devicectl`
relaunch after the evidence window. On the June 23 physical phone this could
leave an Atria process present but suspended before SwiftUI/keepalive timers
advanced (`whoop.keepalive.ticks` stayed flat and `rawNotif+0`). Do **not** count
that non-console relaunch as proof of the monitor window. For the actual
2–3-hour monitor, either keep an active/console launch alive in one terminal
while running the monitor in another, or manually foreground Atria on the phone
after the harness installs it and confirm `whoop.keepalive.ticks` and
`rawNotifications` advance before starting the clock.
Pull any container file live (no relaunch — relaunch drops the connection):
```sh
xcrun devicectl device copy from --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --domain-type appDataContainer --domain-identifier com.adidshaft.atria \
  --source Library/Preferences/com.adidshaft.atria.plist --destination /tmp/p.plist
```
Read dotted UserDefaults keys (plutil mis-parses dots — use plistlib):
```sh
python3 - <<'PY'
import plistlib; d=plistlib.load(open('/tmp/p.plist','rb'))
for k in ['whoop.link.attempts','whoop.link.disconnects','whoop.link.successes',
          'whoop.watchdog.hrContinuityCount','whoop.watchdog.acceptedHRCount',
          'whoop.sample.rawNotifications','whoop.sample.acceptedSamples',
          'whoop.sample.lastStatus','whoop.link.lastStatus','whoop.watchdog.lastAction']:
    print(k, '=', d.get(k))
PY
```
Pull the full state snapshot without relaunching the app:
```sh
./pull_atria_state.sh \
  --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  --bundle-id com.adidshaft.atria \
  --evidence-dir logs/live-device/state-pulls/$(date -u +%Y%m%dT%H%M%SZ)
```

## Procedure (real-time, ~2–3 hours worn)

1. **Install fresh & confirm worn streaming.** Run the harness command above.
   In `logs/live-device/rt-validate.log` you must see, within the 40s window:
   - `status=connected name=ADIDSHAFT'S WHO`
   - `foreground_keepalive armed=1 silence_timeout_s=75`
   - `standardHR hr=NN ...` and `rr source=0x2A37 ...` with **NN > 0** (real pulse).
   If `hr=0` / `sample.lastStatus=zero_contact`, the strap isn't reading skin —
   tighten it until a real bpm streams before starting the clock.

2. **Run the monitor loop** (copy/paste, leave running). It snapshots every 120s
   and prints deltas + flags:
   Prefer the checked-in wrapper below; it writes JSONL samples and a final
   summary under `logs/live-device/realtime-ble-monitor/<label>/`:
```sh
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  python3 tools/monitor_realtime_ble.py --samples 91 --interval 120 \
  --label rt-daytime-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot
```
   `--pull-state` runs `pull_atria_state.sh` after the monitor completes and
   embeds active-journal/session continuity fields in `summary.json` under
   `state_pull`. This gives the pass/fail audit one artifact for both live BLE
   counters and the "continuous session, not tiny fragments" requirement.
   `--audit-snapshot` writes the verifier's Markdown output to `audit.md` in the
   same run directory and records its status/blockers in `summary.json` under
   `audit_snapshot`, so each physical run carries its own current audit result.
   `summary.json` also records the raw argv `command`, copy-pasteable
   `invocation`, effective `device`, and `bundle` used for the run so evidence
   can be reproduced or challenged later.
   New summaries include `min_accepted_sample_delta`; when present, the audit
   requires it to stay positive for worn clean-stream requirements, so raw BLE
   notification churn cannot masquerade as accepted HR collection.
   For targeted stress runs, add one or more `--event SAMPLE:LABEL` flags to
   annotate the JSONL/summary timeline. The summary also includes
   `event_outcomes`, which reports the next sample's raw-data, disconnect, and
   HR-continuity deltas after each event. Known stress labels also print an
   `ATRIA_REALTIME_BLE_OPERATOR_ACTION` line at the marked sample and are saved
   in `summary.json` under `operator_actions`. Example:
```sh
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  python3 tools/monitor_realtime_ble.py --samples 5 --interval 120 \
  --label rt-brief-contact-loss-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot \
  --event 1:brief_contact_loss_start --event 2:brief_contact_loss_reseat
```
   Use the inline loop only if the repo tool is unavailable:
```sh
python3 - <<'PY'
import subprocess, plistlib, time, os
DEV="3803F5B6-1666-56D3-A71A-62F131F6CE3B"; B="com.adidshaft.atria"
KEYS=['whoop.link.attempts','whoop.link.disconnects','whoop.link.successes',
      'whoop.watchdog.hrContinuityCount','whoop.watchdog.acceptedHRCount',
      'whoop.sample.rawNotifications','whoop.sample.acceptedSamples']
def snap():
    subprocess.run(["xcrun","devicectl","device","copy","from","--device",DEV,
      "--domain-type","appDataContainer","--domain-identifier",B,
      "--source","Library/Preferences/com.adidshaft.atria.plist",
      "--destination","/tmp/rt.plist"],capture_output=True)
    d=plistlib.load(open("/tmp/rt.plist","rb"))
    return {k:(d.get(k,0) or 0) for k in KEYS}, d.get('whoop.sample.lastStatus'), d.get('whoop.watchdog.lastAction')
prev,_,_=snap(); print("baseline",prev)
while True:
    time.sleep(120)
    cur,sstat,act=snap()
    dr=cur['whoop.sample.rawNotifications']-prev['whoop.sample.rawNotifications']
    dd=cur['whoop.link.disconnects']-prev['whoop.link.disconnects']
    dh=cur['whoop.watchdog.hrContinuityCount']-prev['whoop.watchdog.hrContinuityCount']
    flag=""
    if dr<=0: flag+=" !NO_NEW_DATA"
    if dd>=3: flag+=" !DISCONNECT_CHURN"
    if dh>=3: flag+=" !TEARDOWN_CHURN"
    print(f"+120s rawNotif+{dr} accepted+{cur['whoop.sample.acceptedSamples']-prev['whoop.sample.acceptedSamples']} "
          f"disc+{dd} hrCont+{dh} sample={sstat} lastAction={act}{flag or ' OK'}")
    prev=cur
PY
```

The wrapper also prints `keepalive=<action>`, `keepaliveTicks=<n>`, and
`keepaliveTicks+<delta>`. If long-wear keepalive is armed,
`keepaliveTicks+0` repeats, and the same tick has no new raw 2A37 data, the tool
flags `KEEPALIVE_NOT_ADVANCING`: the app is not actively running its live-link
recovery loop while the stream is stalled. Foreground Atria or relaunch with an
active console before using that interval as validation evidence. Flat keepalive
ticks do not fail a tick that is already proving positive raw and accepted HR
progress.

Audit the collected realtime BLE evidence at any point:
```sh
python3 tools/audit_realtime_ble_validation.py --markdown
```
To preserve a local audit snapshot alongside the ignored physical-device logs:
```sh
python3 tools/audit_realtime_ble_validation.py --markdown \
  --out logs/live-device/realtime-ble-monitor/audit-$(date -u +%Y%m%dT%H%M%SZ).md \
  --allow-incomplete
```
This verifier is intentionally conservative. It only passes when all four
requirements are proven from local monitor summaries: the 2+ hour worn
monitor with fresh/active `--pull-state` continuity, brief contact-loss recovery,
sustained-silence/reseat recovery, and app-switch continuity.
Every passing requirement summary must include the embedded `audit_snapshot`
written by `--audit-snapshot`, and the referenced `audit.md` file must be
present locally; app-switch also requires the same OK `--pull-state` durability
snapshot as the other physical runs.
Summaries that explicitly record `worn_expected=false` are rejected for these
requirements; `--not-worn` is useful for diagnostics, but it cannot satisfy this
worn-validation handoff.
For sustained silence, only the expected off-wrist `NO_NEW_DATA` /
`ZERO_CONTACT` flags are tolerated. `KEEPALIVE_NOT_ADVANCING` and any other
unexpected flags still fail the requirement. The verifier also requires bounded
churn, an OK `--pull-state` durability snapshot, and a recovered
`sustained_silence_reseat` event outcome. For both stress requirements, the
verifier requires the monitor-recorded `operator_actions` prompts at the same
sample indices as the start and reseat markers; hand-authored event markers or
prompts attached to the wrong sample do not satisfy the physical-action evidence
contract. The prompt text must match the known monitor action for that stress
label.
When the audit is incomplete, its Markdown output includes the exact next
monitor command plus the required physical operator action for each missing
requirement. For any candidate summary it also prints the key evidence metrics
(`samples`, `duration_s`, raw-notification delta, accepted-sample delta when
available, disconnect delta, and HR-continuity delta), plus the state-pull,
file-durability, active-journal, and embedded-audit snapshot statuses, so a
failed run can be diagnosed without opening `summary.json`. Each requirement
also prints how many local candidate summaries matched before blockers were
applied. Saved audit reports include a generation timestamp and the number of
local monitor summaries inspected.
If an interrupted run leaves a corrupt `summary.json`, the audit reports it
under `Invalid Summaries`, continues evaluating the valid run artifacts, and
blocks the final completion gate until the corrupt run is removed or rerun.

3. **Stress tests during the window** (do each, watch the next monitor tick):
   - **App-switch:** open another app for ~2 min, return to Atria. Expect: link
     stays `connected` (disc delta ~0); data resumes. (Background hands off to the
     full supervisor; foreground re-arms the keepalive.)
   - **Brief contact loss (<75s):** loosen/lift the strap ~30s, reseat. Expect:
     **no** teardown (hrCont delta 0), data resumes on its own.
   - **Sustained silence (>2.5 min):** take the strap off and set it down. Expect:
     `foreground_keepalive` logs `status=silent action=reassert_notify` then
     `action=fresh_scan_reconnect`; on reseating, data resumes within a cycle.

### Remaining Stress Test Commands

Use these short targeted runs before or after the full 2–3h monitor. They do not
replace the long worn window. App-switch has current passing physical evidence
after the disconnect-continuity and protected-default fixes. The contact-loss
and sustained-silence commands create the other missing physical recovery
artifacts.

**App switch:**
1. Start this monitor:
```sh
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  python3 tools/monitor_realtime_ble.py --samples 4 --interval 120 \
  --label rt-app-switch-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot \
  --event 1:app_switch_background --event 2:app_switch_return
```
2. When the monitor prints the sample index 1 operator prompt, foreground
   another app. When it prints the sample index 2 prompt, return to Atria.
3. Pass evidence: summary `status=pass`, positive raw and accepted deltas when
   present, `max_disconnect_delta=0`, `max_hr_continuity_delta=0`, no flags, and
   `audit.md` keeps `app_switch` at `pass`. The verifier rejects app-switch
   summaries without the monitor-recorded switch-away and return prompts, so a
   passive run cannot masquerade as lifecycle evidence.

Current passing app-switch evidence:
`logs/live-device/realtime-ble-monitor/rt-app-switch-20260623T081354Z/summary.json`
ran on physical iPhone with Clock foregrounded between the monitor-recorded
`app_switch_background` and `app_switch_return` prompts. It passed with
`samples=4`, `duration_s=363`, `min_raw_notification_delta=113`,
`min_accepted_sample_delta=113`, `max_disconnect_delta=0`,
`max_hr_continuity_delta=0`, `flags=[]`, `state_pull.status=ok`,
`file_durability_status=saved_sessions_present`,
`active_journal_continuity_status=active`, and
`active_journal_freshness=fresh`.

**Brief contact loss (<75s):**
1. Start this monitor:
```sh
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  python3 tools/monitor_realtime_ble.py --samples 5 --interval 120 \
  --label rt-brief-contact-loss-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot \
  --event 1:brief_contact_loss_start --event 2:brief_contact_loss_reseat
```
2. After sample `index=1` prints, loosen/lift the strap for about 30 seconds,
   then reseat it firmly before sample `index=2`.
3. Pass evidence: summary `status=pass`, `max_disconnect_delta=0`,
   `max_hr_continuity_delta=0`, and `event_outcomes` for
   `brief_contact_loss_reseat` has `status=recovered` with
   `next_raw_notification_delta > 0`. The audit also requires
   `state_pull.status=ok` with saved-session file durability, and the
   `brief_contact_loss_reseat` marker must be at least one sample after
   `brief_contact_loss_start` with at least 30 seconds of planned monitor time
   between the markers. The summary must include same-sample `operator_actions`
   prompt records for both `brief_contact_loss_start` and
   `brief_contact_loss_reseat`, with the expected monitor prompt text.

**Sustained silence and reseat (>2.5 min):**
1. Start this monitor:
```sh
ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B \
  python3 tools/monitor_realtime_ble.py --samples 7 --interval 120 \
  --label rt-sustained-silence-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot \
  --event 1:sustained_silence_start --event 3:sustained_silence_reseat
```
2. After sample `index=1` prints, take the strap off and set it down for at
   least 2.5 minutes. Reseat it firmly after sample `index=3` prints.
3. Pass evidence: summary should show a recovery action in the latest/nearby
   watchdog or keepalive fields (`reassert_notify` or `fresh_scan_reconnect`),
   no churn storm (`max_disconnect_delta < 3`, `max_hr_continuity_delta < 3`),
   and `event_outcomes` for `sustained_silence_reseat` has `status=recovered`
   with `next_raw_notification_delta > 0`. The audit also requires
   `state_pull.status=ok` with saved-session file durability, and the
   `sustained_silence_reseat` marker must be at least two samples after
   `sustained_silence_start` with at least 150 seconds of planned monitor time
   between the markers. The summary must include same-sample `operator_actions`
   prompt records for both `sustained_silence_start` and
   `sustained_silence_reseat`, with the expected monitor prompt text.

## PASS / FAIL

**PASS** over the worn window:
- `rawNotifications` increases on **every** monitor tick while worn (continuous
  collection — no silent stalls).
- `sessions.json` grows a **continuous** session (large `points` count), not a
  pile of tiny `Auto-saved` fragments.
- `hrContinuityCount` and `disconnects` stay ~flat while worn (teardown fix holds).
- Any induced silence is recovered by `foreground_keepalive` (reassert→reconnect),
  and data resumes after reseating — **single** recovery, not a churn storm.

**FAIL signals** (capture the log + prefs and report):
- A monitor tick shows `rawNotif+0` while the strap is worn with a pulse → silent
  stall not recovered (check `foreground_keepalive` lines; confirm it armed).
- A monitor tick shows `KEEPALIVE_NOT_ADVANCING` while long-wear keepalive is
  armed → the app may be suspended or not running the recovery loop; foreground
  Atria or relaunch with active console evidence before restarting validation.
- `disc+` or `hrCont+` climbing several per tick while worn → churn regression.
- `sessions.json` filling with sub-minute `Auto-saved` fragments → link flapping.

## Current evidence (2026-06-23)

Bounded evidence now proves the monitor and live stream are usable, but does not
complete the full 2–3h validation:
- `logs/live-device/counter-flush-smoke.log` passed the first gate on the
  physical iPhone: connected to `ADIDSHAFT'S WHO`, `foreground_keepalive` armed,
  `standardHR` present, and `rr source=0x2A37` present (`standard_2a37_frames=32`,
  `standard_2a37_rr_frames=32`, `standard_2a37_rr_values=35`).
- `logs/live-device/realtime-ble-monitor/rt-bounded-8min-20260623T051817Z/summary.json`
  passed a bounded active run: 16 samples at 30s intervals, every real interval
  had new raw notifications (`min_raw_notification_delta=15`), with
  `max_disconnect_delta=0`, `max_hr_continuity_delta=0`, and no flags.
- A delayed active-journal pull after that bounded run found
  `segment-00000001.json` with 188 samples, RR samples present, and
  `zeroHRSamples=0`, so the bounded run was not producing tiny saved fragments.
- `logs/live-device/realtime-ble-monitor/rt-app-switch-stress-20260623T052919Z/summary.json`
  passed the app-switch stress test: Atria was backgrounded by launching Clock
  for about two minutes, then foregrounded again; all real 30s monitor intervals
  had new raw notifications (`min_raw_notification_delta=21`), with
  `max_disconnect_delta=0`, `max_hr_continuity_delta=0`, and no flags. A
  post-stress active-journal pull found a Long wear segment with 72 samples,
  73 RR samples, and `zeroHRSamples=0`.
- After the user reported immediate disconnect on app switch, `1ade2cd` was
  installed on the physical iPhone and re-tested:
  `logs/live-device/realtime-ble-monitor/rt-inactive-switch-fix-20260623T053744Z/summary.json`
  and
  `logs/live-device/realtime-ble-monitor/rt-inactive-flush-switch-fix-20260623T054209Z/summary.json`
  both kept `max_disconnect_delta=0` and `max_hr_continuity_delta=0` while Clock
  was foregrounded and Atria was returned to foreground. The strap link did not
  disconnect or churn. However, each short app-switch run still had one
  `NO_NEW_DATA` monitor poll followed by a large catch-up delta (`rawNotif+41`
  or `rawNotif+46`), so this is **not** full pass evidence for the strict
  "rawNotifications increases on every monitor tick" criterion. Treat it as
  evidence that app-switch teardown is fixed, with remaining work to prove or
  improve realtime persistence while another app owns the foreground.
- A short experiment adding a held `UIApplication` background assertion across
  `.inactive`/`.background` was built and tested, then intentionally not kept:
  `logs/live-device/realtime-ble-monitor/rt-bg-assertion-switch-20260623T054737Z/summary.json`
  still failed the strict app-switch criterion (`flags=NO_NEW_DATA`,
  `min_raw_notification_delta=0`) even though `keepaliveTicks` advanced from 37
  to 43 and `max_disconnect_delta=0`. The failed experiment suggests the stale
  app-switch ticks are not just lack of general app execution time; iOS appears
  to delay or batch BLE notification delivery/persistence while another app owns
  the foreground, then Atria catches up on return.
- Current `main` was reinstalled after removing that background-assertion
  experiment, then tested at the handoff's actual 120s monitor cadence:
  `logs/live-device/realtime-ble-monitor/rt-app-switch-120s-current-20260623T055149Z/summary.json`
  passed with `samples=4`, `min_raw_notification_delta=96`,
  `max_disconnect_delta=0`, `max_hr_continuity_delta=0`, and no flags. Clock was
  foregrounded between the baseline and first 120s tick, then Atria was returned
  before the tick; the app-switch interval produced `rawNotif+96 accepted+96`.
  Treat this as the current app-switch pass evidence for the documented 120s
  stress-test cadence. The earlier 20s failures remain useful diagnostic
  evidence that sub-120s polling can observe iOS batching while another app is
  foreground.
- After the latest app-switch lifecycle patch, the updated build was installed
  on the physical iPhone and retested with a 20s Clock switch monitor:
  `logs/live-device/realtime-ble-monitor/rt-clock-switch-reassert-20260623T061228Z/summary.json`
  passed with `samples=4`, `min_raw_notification_delta=18`,
  `max_disconnect_delta=0`, `max_hr_continuity_delta=0`, no flags, and
  `state_pull.status=ok` with `active_journal_continuity_status=active`. The
  switched-away windows produced `rawNotif+21` and `rawNotif+18`; the return
  window produced `rawNotif+24`. This is the current short-cadence app-switch
  pass evidence.
- After `7edf8fd`, the updated build was installed on the physical iPhone with
  `./live_device_debug.sh --seconds 45 --long-wear-mode --reset-link-diagnostics
  --log auto --leave-running`. The launch log
  `logs/live-device/20260623T064017Z.log` showed CoreBluetooth state restoration
  to `ADIDSHAFT'S WHO`, `foreground_keepalive armed=1`, `2A37 notifying=1`,
  standard HR frames, `standard_2a37_frames=43`, and low-radio mode ready. A
  non-disruptive state pull immediately after normal end-user relaunch,
  `logs/live-device/state-pulls/app-switch-fix-20260623T064128Z/pull-summary.txt`,
  reported `process_status=running`, saved sessions preserved, and a fresh active
  journal.
- A normal non-console switch to Clock after that build kept Atria running:
  `logs/live-device/state-pulls/app-switch-background-20260623T064205Z/pull-summary.txt`
  reported `process_status=running`, `sessions_count=219`,
  `file_durability_status=saved_sessions_preserved`,
  `live_stream_consistency_status=interrupted_not_file_loss`,
  `active_journal_freshness=fresh`, and an active Long wear segment updated after
  the switch. This is not a replacement for the strict monitor summary because it
  does not prove every 120s tick advanced; it is device evidence that ordinary
  app switching no longer tears down the process or loses saved files.
- A separate console-attached app-switch attempt after `7edf8fd` launched Clock
  while `devicectl --console` owned Atria. That process exited with `signal 9`
  before the evidence deadline, so it is treated as a console-harness artifact,
  not as normal user app-switch evidence. Use non-disruptive container pulls or
  the checked-in monitor summaries as authoritative evidence for this handoff.
- After the background-supervisor resume patch, the fixed Debug build was
  installed on the physical iPhone and relaunched normally. A non-disruptive
  pull at
  `logs/live-device/state-pulls/app-switch-supervisor-20260623T070647Z/pull-summary.txt`
  showed `process_status=running`, `sessions_count=220`,
  `file_durability_status=saved_sessions_preserved`, a fresh reconstructed
  active journal, and `active_journal_peak_hr=81`. This is install/liveness
  evidence only; the long worn monitor and two contact-loss stress artifacts
  remain required.
- Fresh post-`655c863` app-switch evidence:
  `logs/live-device/realtime-ble-monitor/rt-app-switch-20260623T071141Z/summary.json`
  passed with `git_commit=9bafbfa51c585b81aa465f56f1b2b0e3d586d6a2`,
  `samples=4`, `duration_s=363`, `min_raw_notification_delta=118`,
  `min_accepted_sample_delta=118`, `max_disconnect_delta=0`,
  `max_hr_continuity_delta=0`, no flags, and `state_pull.status=ok` with
  `active_journal_continuity_status=active`. Clock was foregrounded between the
  baseline and first 120s monitor tick, then Atria was returned before the tick;
  the switched interval and both follow-up intervals advanced cleanly. The
  monitor exposed a tooling bug after writing `summary.json`: `--audit-snapshot`
  crashed when `tools/monitor_realtime_ble.py` was run as a script because the
  audit import used the package path. That bug is fixed after this evidence run.
- After the user reported that switching apps could still immediately disconnect
  or fragment the collection, `2a0491d` was built, installed on the physical
  iPhone, launched, and checked with a non-disruptive state pull. The pull showed
  `process_status=running`, saved sessions preserved, historical archive
  present, and a fresh active journal. This proves install/liveness only. The
  previous app-switch monitor predates the disconnect-continuity callback fix, so
  the verifier now requires a fresh `rt-app-switch-*` monitor summary whose
  `git_commit` includes `2a0491d`.
- Superseded post-`2a0491d` app-switch evidence:
  `logs/live-device/realtime-ble-monitor/rt-app-switch-20260623T073612Z/summary.json`
  passed with `git_commit=291f7f8a822a15f989f164ad3a3cdb3c856ebf52`,
  `samples=4`, `duration_s=363`, `min_raw_notification_delta=99`,
  `min_accepted_sample_delta=99`, `max_disconnect_delta=0`,
  `max_hr_continuity_delta=0`, no flags, and `state_pull.status=ok` with
  `file_durability_status=saved_sessions_preserved`. Clock was foregrounded
  after the baseline sample for about 105 seconds, then Atria was returned before
  the first 120s tick. The app-switch interval advanced cleanly
  (`rawNotif+99 accepted+99`), and both follow-up intervals also advanced cleanly
  (`rawNotif+127 accepted+127`, `rawNotif+118 accepted+118`). This run is useful
  continuity evidence, but it is no longer the authoritative app-switch pass
  because it predates the explicit operator-prompt requirement.
- Current marked app-switch evidence:
  `logs/live-device/realtime-ble-monitor/rt-app-switch-20260623T081354Z/summary.json`
  passed with `git_commit=4ec07578575784a4ff981a3160b4e72dd92024eb`,
  `samples=4`, `duration_s=363`, `min_raw_notification_delta=113`,
  `min_accepted_sample_delta=113`, `max_disconnect_delta=0`,
  `max_hr_continuity_delta=0`, no flags, and `state_pull.status=ok` with
  `file_durability_status=saved_sessions_present`,
  `active_journal_continuity_status=active`, and
  `active_journal_freshness=fresh`. The monitor recorded same-sample
  `operator_actions` for `app_switch_background` at sample 1 and
  `app_switch_return` at sample 2. Clock was foregrounded during that marked
  away window, and raw/accepted 2A37 samples advanced throughout
  (`rawNotif+126 accepted+126`, `rawNotif+113 accepted+113`,
  `rawNotif+125 accepted+125`) with zero disconnect and HR-continuity churn.
  This is the current authoritative app-switch pass evidence.
- Current continuation readiness:
  `logs/live-device/realtime-ble-monitor/rt-continuation-readiness-20260623T062113Z/summary.json`
  passed with `samples=2`, `min_raw_notification_delta=21`,
  `max_disconnect_delta=0`, `max_hr_continuity_delta=0`, no flags, and
  `state_pull.status=ok`. The active journal was fresh and active
  (`active_journal_samples=584`, `active_journal_rr_values=149`,
  `active_journal_duration_s=560`). This proves the current installed app is
  still live and writing durable state, but it is only readiness evidence, not
  the full 2–3h worn validation.
- Direct non-disruptive state pull:
  `logs/live-device/state-pulls/continuation-cli-20260623T062356Z/pull-summary.txt`
  verified the documented `pull_atria_state.sh --device ... --bundle-id ...`
  command path after the parser fix. It reported `process_status=running`,
  `active_journal_freshness=fresh`,
  `active_journal_continuity_status=active`, `active_journal_samples=710`,
  `active_journal_rr_values=149`, and `active_journal_duration_s=681`. This is
  state-readiness evidence only; it does not replace the long monitor because it
  cannot prove every 120s tick had new raw notifications.
- Latest non-disruptive continuation pull:
  `logs/live-device/state-pulls/goal-continuation-20260623T065651Z/pull-summary.txt`
  reported `process_status=running`, `sessions_status=ok`,
  `sessions_count=219`, `file_durability_status=saved_sessions_present`,
  and a fresh reconstructed Long wear active journal
  (`active_journal_samples=86`, `active_journal_duration_s=81`,
  `active_journal_peak_hr=111`). This is only liveness/durability evidence:
  the active journal was `hr_only` with `active_journal_rr_values=0` and
  `active_journal_continuity_status=hr_only`, so it does not satisfy the worn
  realtime BLE monitor, RR continuity, or stress-test requirements.
- `tools/monitor_realtime_ble.py --pull-state` now captures end-of-run
  `pull_atria_state.sh` evidence into the monitor `summary.json`, including
  active journal continuity, latest saved-session points/RR points, and file
  durability status. Use it for the remaining full-window and stress evidence so
  the handoff proves both live counter continuity and durable session continuity.
  Smoke evidence:
  `logs/live-device/realtime-ble-monitor/rt-pull-state-smoke-20260623T055958Z/summary.json`
  passed the live counter monitor (`min_raw_notification_delta=13`,
  `max_disconnect_delta=0`, `max_hr_continuity_delta=0`) and embedded
  `state_pull.status=ok`. That smoke is tooling proof only; its active journal
  was stale, so it is not long-window pass evidence.
- `tools/monitor_realtime_ble.py --event SAMPLE:LABEL` now records stress
  annotations in both `samples.jsonl` and `summary.json`, and derives
  `event_outcomes` from the next monitor sample (`recovered`,
  `no_new_data_after_event`, or `churn_after_event`). Use it for the remaining
  contact-loss and sustained-silence runs so the physical action is tied to the
  monitor tick that proves recovery.

Still required before marking this handoff complete: the full 2–3h worn monitor,
brief contact-loss recovery, and sustained-silence/reseat recovery.

Current verifier status:
```text
python3 tools/audit_realtime_ble_validation.py --markdown
Status: incomplete
daytime_worn_monitor: missing_evidence
brief_contact_loss: missing_evidence
sustained_silence_reseat: missing_evidence
app_switch: pass
```
The live Markdown output is the authoritative next-step list; it prints the exact
monitor command and operator action for each missing requirement.

## Notes / gotchas
- Device console (`devicectl --console`) is flaky on iOS 27; the **container pulls
  above are the source of truth**, not the console stream.
- UserDefaults persist across reinstall, so counters are cumulative — always work
  in **deltas**, not absolutes.
- Keep `python3 test_handoff_static_checks.py` green for any code change
  (current suite also locks keepalive/app-switch behavior and healthy-stream
  counter flushing).
- Keep `python3 tools/audit_realtime_ble_validation.py --markdown` as the
  completion gate for this document; do not mark the goal complete while it
  reports `incomplete`.
