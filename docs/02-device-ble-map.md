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
| `61080002-…` | write, write-without-response | **Command / TX** (host → strap) |
| `61080003-…` | notify | **Response / RX** (strap → host) |
| `61080004-…` | notify | data stream (active when worn) |
| `61080005-…` | notify | data stream |
| `61080007-…` | notify | data stream |

This is a Nordic-UART-style layout: one write channel, one response channel,
several notify data streams.

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
