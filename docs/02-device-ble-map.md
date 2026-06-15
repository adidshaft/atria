# Device & BLE Map

## Device identity

| Field | Value |
|---|---|
| Name | `ADIDSHAFT'S WHO…` (truncated WHOOP) |
| Bluetooth MAC (macOS `system_profiler`) | `E0:29:C0:AC:D2:75` |
| CoreBluetooth UUID (this Mac) | `837560C0-5B6C-C520-95EF-B1E713358D33` |
| Manufacturer (`0x2A29`) | `WHOOP Inc.` |

> ⚠️ **CoreBluetooth peripheral UUIDs are per-host.** The `837560C0…` UUID is what
> *this Mac* assigns; the iPhone assigns a different one. So the iOS app cannot
> hardcode that UUID. Gate A uses a fresh advertisement scan and connect path.

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
