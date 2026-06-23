# Codex Handoff — Real-time BLE collection validation (worn, daytime, ~2–3h)

Date: 2026-06-23
Goal: Confirm on a physical iPhone, **worn during the day over the next few
hours** (not overnight), that the recent BLE fixes hold — continuous collection,
no reconnect churn, and automatic recovery of any silent link.

You (Codex) have the cabled iPhone. Start cold; everything you need is below.

## What was fixed (validate these)

Three commits on `main` (HEAD region):
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
- `1ade2cd` — **app-switch lifecycle fix**. iOS can sit in `.inactive` before
  fully backgrounding during app switching; Atria now moves BLE long-wear
  supervision to unattended mode immediately on `.inactive` and flushes realtime
  sample diagnostics plus the active journal on lifecycle exits. This prevents
  the strap link from depending on foreground-only timers when the user switches
  away without closing the app.

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
  --label rt-daytime-$(date -u +%Y%m%dT%H%M%SZ)
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

The wrapper also prints `keepalive=<action>` and `keepaliveTicks=<n>`. If
`keepaliveTicks` stays flat across monitor ticks, the app is not actively running
its live-link recovery loop; foreground Atria or relaunch with an active console
before using that interval as validation evidence.

3. **Stress tests during the window** (do each, watch the next monitor tick):
   - **App-switch:** open another app for ~2 min, return to Atria. Expect: link
     stays `connected` (disc delta ~0); data resumes. (Background hands off to the
     full supervisor; foreground re-arms the keepalive.)
   - **Brief contact loss (<75s):** loosen/lift the strap ~30s, reseat. Expect:
     **no** teardown (hrCont delta 0), data resumes on its own.
   - **Sustained silence (>2.5 min):** take the strap off and set it down. Expect:
     `foreground_keepalive` logs `status=silent action=reassert_notify` then
     `action=fresh_scan_reconnect`; on reseating, data resumes within a cycle.

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

Still required before marking this handoff complete: the full 2–3h worn monitor
and the remaining stress tests above (strict app-switch with no `NO_NEW_DATA`,
brief contact loss, sustained silence/reseat) with passing evidence.

## Notes / gotchas
- Device console (`devicectl --console`) is flaky on iOS 27; the **container pulls
  above are the source of truth**, not the console stream.
- UserDefaults persist across reinstall, so counters are cumulative — always work
  in **deltas**, not absolutes.
- Keep `python3 test_handoff_static_checks.py` green for any code change
  (current suite also locks keepalive/app-switch behavior and healthy-stream
  counter flushing).
