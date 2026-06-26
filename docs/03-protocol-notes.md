# Protocol Notes (proprietary stream)

Work-in-progress decoding of the WHOOP custom service
(`61080001-…`), based on captures from `61080004` ("stream4").

## Frame format (verified)

```
+---------+-----------+----------+----------+--------------+
| 0xAA    | len (2B)  | opcode   | body...  | checksum(4B) |
| preamble| little-end| (1B)     |          |              |
+---------+-----------+----------+----------+--------------+
            \__________ len counts these __________/
```

- **Preamble:** always `aa`.
- **Length:** 2 bytes, little-endian. **Counts every byte except the 4-byte
  checksum**, i.e. `total = len + 4`. (e.g. `len=0x0014`=20 → 24-byte frame.)
- **Opcode:** the byte right after `len` — the message type (`03`, `57`, `f9`,
  `fa`, `52` seen so far). The next byte is consistently `0x30`.
- **Checksum:** the 4 trailing bytes. **Algorithm unidentified — NOT standard
  CRC-32.** See below.

### Checksums — FULLY CRACKED ✅

The earlier brute force failed only because it never tried the CRC32 range
starting at **offset 4**. The framing is the standard WHOOP layout:

- **CRC8** (byte 3) = CRC-8, poly `0x07`, init `0x00`, over the **2 length bytes**.
- **CRC32** (last 4 bytes, LE) = standard **CRC-32/ISO-HDLC** (`zlib.crc32`) over
  the **payload only** (`bytes[4 : len]`).
- `len` field = `len(payload) + 4` = `total - 4`.

`whoop_codec.py` encodes/decodes and round-trips all captured frames. We can now
**build valid packets the strap accepts.**

### Payload structure (after the frame header)

`payload = [ type(u8) | seq(u8) | cmd(u8) | data... ]`

| PacketType | Hex | Meaning |
|---|---|---|
| COMMAND | `0x23` | host → strap |
| COMMAND_RESPONSE | `0x24` | strap → host |
| REALTIME_DATA | `0x28` | strap → host (HR + RR intervals) |
| HISTORICAL_DATA | `0x2F` | strap → host |
| EVENT | `0x30` | strap → host ← **our captured "status" frames were these** |
| METADATA | `0x31` | strap → host |

Our passive captures all started with `0x30` (EVENT) — the strap only streams
EVENTs until asked for realtime data.

### Historical usability guard

`tools/analyze_historical_usability.py` is the current Gate H decision tool for
stored transfers. It checks three separate facts:

- transport validity: every logged `0x2f` frame must decode through
  `whoop_codec.py`;
- currentness: the historical time range must overlap live realtime frames or a
  pulled on-device `sessions.json`;
- metric safety: historical RR remains barred from HRV/Recovery/Sleep/Workout
  metrics unless the RR layout and an external RR/IBI reference are also
  validated.

Latest physical-iPhone run:
`docs/evidence/gate-h/20260614T-historical-usability-device-verify/`.
History-only `1400,6000,1600` produced `2810` codec-clean `0x2f` frames. The
`whoof` layout had plausible HR/RR agreement and `135` clean old 5-minute
RR-shaped windows, but the range was March 29, 2026 and did not overlap live or
saved local sessions. The correct verdict is `stored_transfer_verified=1`,
`current_session_usable=0`, `metric_usable=0`.

`--history-ack-mode enddata` is a NOOP-backed experiment mode. It ACKs
`HISTORY_END` with `[0x01] + body[10..<18]` and write-with-response instead of
the older `trim + zero` payload. The physical iPhone run in
`docs/evidence/gate-h/20260614T-history-enddata-ack-device-verify/` confirmed
the strap accepts this form (`writeResult ok`, repeated `0x17` ACK responses,
`3160` codec-clean `0x2f` frames), but it still selected old March history.
That rules out ACK padding as the current-history selector blocker.

`./live_device_debug.sh --history-noop-backfill` is the repeatable NOOP-style
stored-session preset. It launches history-only, skips realtime START and the
default `0x22` range request, sends `1400,6000,1600`, uses confirmed writes for
the init/start commands, and uses `enddata` ACKs. Physical-iPhone evidence in
`docs/evidence/gate-h/20260614T-noop-backfill-confirmed-init-device-verify/`
verified the corrected command mode (`historyOnly ... mode=wr`), `3453`
codec-clean `0x2f` frames, and plausible `whoof` layout windows
(`ready_windows=2878`, best 300-second window `raw=371 kept=371 conf=100`).
The range was still old (`2026-03-29T20:54:58Z...21:49:00Z`) with no live or
saved-session overlap, so this path proves transfer mechanics but not a usable
current-session selector.

Current-history recheck, 2026-06-15:
`docs/evidence/gate-h/20260615T-current-history-noop-backfill-recheck/`.
The repeat NOOP-style backfill did not produce new current-history frames. The
pulled archive is still codec-clean (`728` rows, `undecodable_rows=0`) but
`current_session_usable_rows=0`, `metric_usable_rows=0`, and Gate E still
reports `sleep_motion_unvalidated_historical_stale`. Plain NOOP backfill is
therefore exhausted as a current sleep/workout unblocker unless a different
current-history selector or validated live IMU path is discovered.

Single-device recheck after long wear:
`docs/evidence/gate-h/20260615T-single-device-noop-backfill-current-recheck/`.
The pulled archive again contained the same stale March 29 range (`728` decoded
rows, validated gravity, `706` Whoof-layout RR values, zero current-session
overlap). The live transfer attempt produced `historical_2f_frames=0` because
long-wear HR/RR watchdogs repeatedly forced fresh reconnects during the
history-only init sequence (`0x14`, `0x60`, `0x16`). Atria now suppresses
watchdog reconnect actions while `--atria-history-only-probe` is active, so
future history/IMU protocol probes get a clean BLE window instead of being
interrupted by the app's own recovery policy. This removes probe noise only; it
does not make stale historical data metric-usable.

Post-fix physical verification:
`docs/evidence/gate-h/20260615T-history-probe-watchdog-suppressed-device-verify/`.
The fixed build installed and launched on the cabled iPhone. The same
history-only sequence produced clock ACKs, `0x14`/`0x60`/`0x16` command
responses, live `0x2f` rows, and a pulled archive with `50` decoded
Whoof/NOOP-layout rows (`undecodable_rows=0`, validated gravity, corrected range
`2026-03-29T23:17:19Z...23:18:06Z`). The HR-continuity and accepted-HR
watchdogs logged `action=suppressed_history_only_probe` instead of reconnecting.
Gate H remains protocol-ready/metric-fail-closed because the archive is still
old and has zero current-session overlap.

Live IMU/current-motion counter, 2026-06-15:
`docs/evidence/gate-h/20260615T-protocol-imu-counter-device-verify/`. Atria now
persists protocol packet counters and exposes them in `local_status` and Gate H
evidence (`protocol_imu_frames`, `protocol_diagnostic_frames`,
`protocol_event_frames`, `protocol_unknown_frames`). A cabled iPhone full-
protocol run reset the counters, collected for 100 seconds, then a status read
reported `protocol_packets=5`, `protocol_imu_frames=0`,
`protocol_diagnostic_frames=0`, and `protocol_event_frames=3`. This proves the
current subscription plus realtime START path is not receiving live `0x33` IMU
frames; current-motion validation still needs a new trigger/selector, not a
decoder promotion.

Passive live-motion recheck, 2026-06-15:
`docs/evidence/gate-h/20260615T-live-motion-passive-recheck-device-verify/`.
The first `--log-gate-status` launch exited too quickly to be a useful motion
window, so the repeat run held the physical iPhone in full-protocol mode for a
170-second live-workout diagnostic window, then launched a post-window gate
status read. The app received full-protocol traffic (`protocol_packets=2`,
`protocol_event_frames=1`, `protocol_unknown_frames=1`) but still reported
`protocol_imu_frames=0`, `protocol_diagnostic_frames=0`,
`sleep_motion_hint_count=0`, and no `imu_candidate` logs. This does not prove
that deliberate wrist movement cannot trigger live IMU, because no active
movement script was performed during the window; it does rule out passive
foreground full-protocol subscription as a current sleep-motion source. Gate E
therefore remains blocked on a real current-history selector, a validated
live-IMU trigger, or external official-app/sniffer evidence.

Active-motion result-row verification, 2026-06-15:
`docs/evidence/gate-h/20260615T-active-motion-result-row-device-verify/`.
The active-motion preset now emits its own delayed
`ATRIADBG active_motion_imu_check` result row instead of requiring Gate Status
to be interpreted as the only outcome. The physical iPhone run built cleanly,
installed and launched Atria on the cabled device, connected to the strap,
enabled `61080003/04/05/07`, sent realtime START, and received
`cmdResp ... payload=2485030002000000`. The result row reported
`status=no_strap_motion_signal`, `protocol_packets=3`,
`protocol_imu_frames=0`, `protocol_diagnostic_frames=0`,
`sleep_motion_hint_count=0`, and `metric_promotions=0`. This rules out the
unattended single-device still run as a usable current-motion source. It does
not prove a deliberate wrist-motion script or a missing selector cannot expose
IMU; until such evidence appears, sleep/workout motion remains learning.

Latest NOOP clock/backfill verification:
`docs/evidence/gate-h/20260614T032719Z-clock-policy-noop-backfill-override-device-verify/`.
The probe now overrides persisted standard-HR-only mode so explicit history-only
runs can still subscribe to `61080003/04/05/07` and write `61080002`. The
physical iPhone confirmed the full custom path: `cmd_response_count=5`,
clock correlation present (`GET_CLOCK` drift `6s`), `frame_61080005_count=56`,
`frame_61080005_types=0x2f:50,0x31:6`, and `historical_2f_frames=50`.
The pulled archive is codec-clean and persisted, but the selected range is still
old (`2026-03-29T23:07:05Z...23:07:53Z`), with no live/saved-session overlap.
Verdict: `stored_transfer_verified=1`, `gate_h_protocol_exit_ready=1`,
`gate_h_current_session_metric_ready=0`, `ready=0`.

Latest Atria post-rename verification:
`docs/evidence/gate-h/20260614T-atria-historical-backfill-device-verify/` and
`docs/evidence/gate-h/20260614T-atria-gate-h-post-backfill-status/`.
The bundle rename created a fresh app container, so Atria initially reported
`missing_archive`. A full-protocol NOOP backfill then pulled `350` codec-clean
`0x2f` rows into Atria's own local archive, and a short post-status launch
reported Gate H `status=ready` / `gate_h_protocol_exit_ready=1`. The archive is
still old March history with no saved-session overlap, so metric readiness stays
`ready=0`.

### Key commands

- **`TOGGLE_REALTIME_HR` (cmd 0x03)** — payload `[0x23, seq, 0x03, enable]`
  (`0x01` start / `0x00` stop). Triggers continuous `REALTIME_DATA`.
- **`SET_CLOCK` (cmd 0x0A / decimal 10)** — NOOP-backed clock sync uses
  `[unix u32le][subsec u32le]`, plus the legacy 9-byte form on WHOOP 4.
- **`GET_CLOCK` (cmd 0x0B / decimal 11)** — empty payload or `[00]`; response
  establishes the diagnostic strap-clock/wall-clock correlation.
- **`GET_BATTERY_LEVEL` (cmd 0x1A / decimal 26)**.

### Mac probe for RR continuity

Gate B currently needs to distinguish a BLE disconnect from realtime payloads
that keep arriving with `rrnum=0`. Use the Mac probe with the iOS app force-quit:

```bash
.venv/bin/python probe.py --start-only-seconds 180
```

This sends only the validated realtime START command (`0x03 enable=1`) after
subscriptions are active, then prints `WHOOP_PROBE_SUMMARY` counters:
`realtime_frames`, `rr_frames`, `rr_zero_frames`, `rr_values`,
`rr_hr_mismatch_values`, first/last RR timing, and `max_rr_log_gap_s`. A high
`rr_zero_frames` count with steady `realtime_frames` means the strap is connected
but choosing to emit HR-only realtime payloads, matching the iPhone Gate B
timeouts.

Current Gate B conclusion from physical iPhone evidence:

- Standard BLE Heart Rate Measurement `2A37` is the primary live HR/RR source.
  Proprietary `0x28` realtime RR is supplemental diagnostics when fresh `2A37`
  RR is available.
- The validated START command (`0x03 enable=1`) still unlocks realtime frames on
  `61080005`, but Gate B must not depend on proprietary `0x28` RR while `2A37`
  is carrying real R-R intervals.
- Single START and STOP→START restart policies are no longer productive Gate B
  work. The remaining live-capture failures are real RR blackouts in `2A37`
  notifications, not parser offsets or START retry policy.
- New captures seed from already archived real RR and recompute HRV on a timer
  as well as on BLE packets. This prevents missing a valid 300-second boundary
  between notifications, but it does not synthesize intervals during HR-only
  periods.
- Saved RR-ledger export is the active Gate B reference path. The current
  physical-iPhone reference package is real local RR (`raw=347`, `kept=317`,
  `conf=91`, `max_rr_gap_s=2.8`, `rmssd=50.2`) and remains pending external
  RR/IBI comparison within `+/-5 ms`.
- macOS `probe.py` is currently blocked before subscription by CoreBluetooth
  `CBErrorDomain Code=14` / "Peer removed pairing information", even after the
  iOS app is force-quit with `force_quit_ios_app.sh`.
- Do not relax the HRV gap/confidence gates to force a number. If live `2A37`
  RR blacks out, the app must stay `learning` and use the saved RR package or a
  validated historical/stored-session fallback.

Minimum sniffer/protocol evidence if the iPhone probe path does not reproduce:

1. Capture official-app connection setup from scan/connect through realtime RR
   streaming, with the strap free to advertise before capture.
2. Record notifications enabled for `61080003`, `61080004`, `61080005`, and
   `61080007`, plus writes to `61080002`.
3. Extract every host→strap command frame after subscriptions become active,
   including write type, sequence, command id, payload bytes, and timing relative
   to `61080005` notify confirmation.
4. Compare those commands with our current `0x03 enable=1`, STOP→START restart,
   and retry policies.
5. Only add or change app commands after the candidate is reproduced in a
   physical iPhone `ATRIADBG` run that improves `realtime_rr_zero_frames`,
   `max_rr_log_gap_s`, and the on-device HRV readiness reason without weakening
   correction rules.

The iPhone debug runner can now send one explicit extra command after the
validated START:

```bash
./live_device_debug.sh --seconds 120 --probe-command 0301 --probe-command-delay 8
```

`--probe-command` is unframed command+data hex; the app adds `[0x23, seq, ...]`
and the WHOOP frame wrapper. Use it only for documented Gate B protocol probes
that are compared against the baseline summary counters.

### REALTIME_DATA body (the HRV source)

Within `data` (payload offset 3+): byte 5 = **heart_rate**, byte 6 = **rrnum**
(0–4), bytes 7+ = **RR intervals** as `u16le` milliseconds (valid 200–2000 ms).
So in absolute payload offsets: `P[8]`=HR, `P[9]`=rrnum, `P[10+]`=RR intervals.
**RR intervals → HRV (RMSSD).**

Credit: community reverse engineering — `madhursatija/whoof`,
`jogolden/whoomp`, `bWanShiTong/reverse-engineering-whoop`.

## Sample captures

Off-wrist (sparse status frames):
```
aa 2400 fa3017 03 00 4ac8296a 586c14 ... da7e9b7d   (40B)
aa 2c00 5230183f00 4ac8296a 606c1c ... 899ad784     (48B)
```

On-wrist (varied frame types appear, counter advancing `…c8296a` → `…c9296a`):
```
aa 1400 0330 8566 0009c9296a 003b0400 0101 0000 b1317fa1   (24B)
aa 1000 5730 a316 0015c9296a 582c0000 419bc28c             (20B)
aa 3000 f930 a520 001bc9296a d01d2000 0301153f25…          (52B)
```

## Observations / hypotheses

- Multiple distinct **frame lengths** (20/24/40/48/52 B) ⇒ several message types,
  keyed by the opcode byte after the length.
- A 4-byte field (`4ac8296a` / `…c9296a`) is **near-constant** with a low byte that
  rises over time → likely a **timestamp or session id + counter**.
- HR over the *standard* service works without any command, so the proprietary
  streams are probably **raw PPG / accelerometer / events**.
- Continuous high-rate raw data may require sending a **start command** on the TX
  characteristic (`61080002`) — not yet attempted (write path = brick risk).

## Open questions

- [ ] Verify the CRC32 polynomial/seed against captures.
- [ ] Identify each opcode → message type.
- [ ] Find the "start streaming" command (sniff the official app, or research).
- [ ] Decode PPG vs accelerometer fields by correlating with movement.
