# Device & BLE Map

## Device identity

| Field | Value |
|---|---|
| Advertised name | `WHOOP…` (device-specific suffix omitted) |
| Bluetooth address | Host- and strap-specific; discover at runtime |
| CoreBluetooth identifier | Per-host; discover at runtime |
| Manufacturer (`0x2A29`) | `WHOOP Inc.` |

> ⚠️ **CoreBluetooth peripheral UUIDs are per-host.** A Mac and iPhone assign
> different identifiers to the same strap, so the app must never hardcode one.
> Gate A uses a fresh advertisement scan and connect path.

## GATT map

### Proprietary WHOOP service — `61080001-8d6d-82b8-614a-1c8cb0f8dcc6`

| Characteristic | Properties | Role |
|---|---|---|
| `61080002-…` | write, write-without-response | **Command / TX** (host → strap). Inner type `0x23`. |
| `61080003-…` | notify | **Command response / RX.** Type `0x24`. A `6A` echo here is an ACK, **not** IMU. |
| `61080004-…` | notify | **Events (stream-4).** Type `0x30`. Event `0x3F` is extended battery, not R10. Mid-link CCCD on this characteristic caused reconnect churn; production all-day HR does not subscribe it. |
| `61080005-…` | notify | **Data (stream-5).** Multiplexed: `0x2F` history, `0x31` metadata, `0x32` console logs, compact IMU **`0x33`**, historical IMU dump `0x34`, heavy R10 `0x2B`. Production history notify is RX + stream-5. Compact IMU recovery needs stream-5 CCCD from **initial discovery** only — mid-link stream-5 off/on disconnects this V4. |
| `61080007-…` | notify | Memfault / diagnostics. Not a motion pipe. |

This is a Nordic-UART-style layout: one write channel, one response channel,
several notify streams. Stream-4 and stream-5 are **not** interchangeable.

Type-43 R10 (`0x2B` after `0x3F`/`6A` in a workout epoch) kills this iPhone’s
BLE link (`CBErrorDomain: 6`). Compact `0x33` is a different, lower-rate stream
that has run for hours without that timeout. Details:
[WHOOP4_PROTOCOL_FINDINGS.md](WHOOP4_PROTOCOL_FINDINGS.md) (2026-09-20 compact IMU).

### Standard services (documented BLE specs — easy wins)

| Service | Characteristic | Use |
|---|---|---|
| Heart Rate `0x180D` | `0x2A37` (notify) | **Live BPM** — the foundation of the app |
| Battery `0x180F` | `0x2A19` (notify, read) | Battery % |
| Device Info `0x180A` | `0x2A29` (read) | Manufacturer = "WHOOP Inc." |

## Behavior notes

- **Battery:** an initial `read` returned a stale `0x64` (100%); the live `notify`
  gives the true value (e.g. 43%). Trust the notify.
- **Idle vs worn:** off-wrist the strap emits only sporadic status frames and
  `0x2A37` reports `0`. **On-wrist**, HR populates (watched it climb 0 → 71 → 84)
  and the proprietary streams become active.
- **Live HR ≠ live IMU.** `0x2A37` can stay accepted while compact `0x33` is
  stale for hours (build 228: HR age ~0.03 s, compact last assembled ~15:22 the
  previous afternoon). Wrist-off / LED-off is not a firmware reboot.
- **Do not send on a live `2A37` link:** `0x3F`, `0x51`, unguarded
  `03/01 + 6A/01 + 14/00` (July: that sequence opened type-43 then timed out),
  `0x9A` (persistent optical). `6A/01` in a workout/lease epoch can still open
  type-43; in all-day `pure_hr_v10` a type-24 `6A` ACK is not compact-on.
