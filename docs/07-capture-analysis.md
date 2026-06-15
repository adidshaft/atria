# Capture Analysis (2026-06-11)

First labeled captures: `still`, `deep-breath`, `walking`, `jumping`
(CSV exported from the app's Capture feature).

## Heart rate — works, physiologically correct

| Activity | n | min | max | mean | trajectory |
|---|---|---|---|---|---|
| still | 46 | 66 | 88 | 74 | 88 → 66 (recovery) |
| deep-breath | 32 | 69 | 92 | 77 | 71 → 92 |
| walking | 29 | 76 | 84 | 80 | steady ~80 |
| jumping | 29 | 83 | **142** | 106 | 83 → 142 (exertion) |

Clear rest-vs-exertion separation. HR via standard `0x2A37` is reliable app data.

> Note: the standard HR characteristic sends **BPM only** (flags byte `0x00`, no
> RR-interval data), so **HRV is not available from the standard service** — it
> would require the raw PPG from the proprietary channel.

## Proprietary frames — sparse status/identity, NOT a live sensor feed

Only **3 frames in ~3 minutes** of capture. These streams are periodic, not a
continuous sensor feed:

- **`stream7` opcode `08` (98 B)** — protobuf-style **device identity**. Decoded
  strings: firmware **`17.2.2.0`**, platform **`harvard_r10`**, codename
  **`boylston`**. ⚠️ This stream is **not `aa`-framed** — different format from
  `stream4` (looks like protobuf).
- **`stream4` opcodes `FA` / `52`** — the `aa`-framed periodic status packets,
  ~once per 30–50 s.

## Key conclusion

Passive listening yields only HR (standard service) + occasional status. To get
**continuous raw biometrics** (PPG waveform, accelerometer, RR/HRV, SpO2) we must
send a **start-streaming command on the TX characteristic `61080002`**. That is
the next frontier — and the first time we write to the device (handle carefully).

## Approaches to find the start command

1. **Sniff the official app** — log what the WHOOP app writes to `61080002` on
   connect (BLE sniffer / proxy), then replay. Cleanest.
2. **Research** community WHOOP reverse-engineering for the command schema.
3. **Black-box probe** — send framed commands with guessed opcodes on `61080002`,
   watch `61080003` (RX) for responses. Slowest, highest risk.
