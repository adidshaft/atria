# Roadmap

## Done ✅
- **Protocol fully cracked** (CRC8+CRC32 framing, START_REALTIME) — HRV/RR validated on macOS.
- **Recovery (%)** ring + **Strain (0–21)** gauge + **daily Strain-Coach guidance** (push vs rest).
- BLE discovery, GATT enumeration, frame framing decoded.
- Live HR + battery captured on macOS.
- Native iOS app: live HR, sparkline, battery, manufacturer, frame log.
- Connect even while the official WHOOP app holds the strap.

## Next 🔜
- [x] **Accuracy** — skin-contact detection, motion-artifact rejection, median display smoothing.
- [x] **Feedback** — baseline-vs-now comparison, per-session time-in-zone.
- [x] **Continuous learning** — adaptive resting-HR baseline (EMA) trained on every session.
- [x] **Resting-HR trend chart** — per-session resting over time with baseline overlay (History).
- [x] **Auto-save on disconnect** — sessions with ≥10 samples persist automatically
      (labeled "Auto-saved" if untagged), so runs are never lost.
- [x] **Background BLE** — `UIBackgroundModes: bluetooth-central` so HR keeps
      logging while the app is backgrounded.
- [x] **Frame format verified** — `len = total − 4`; parser corrected.
- [ ] **Identify the checksum** — NOT standard CRC-32 (ruled out); try seeded/
      custom variants once we have more captures.
- [x] **Capture & CSV export** — labeled in-app recording of frames + HR.
- [ ] **Classify opcodes** — map each frame type (first payload byte) to meaning,
      using labeled captures.
- [x] **HR insights** — session resting/avg/peak, 5-zone model, live Swift Charts
      line chart, adjustable Max HR.
- [x] **Persist sessions** — finish & save HR sessions to local JSON; History
      screen with per-session chart + stats; swipe to delete. Max HR persists.
      Fully standalone — no WHOOP account/cloud (see 08-ownership-and-reset.md).
- [ ] **Decode stream4 payloads** — correlate fields with movement/stillness to
      separate PPG vs accelerometer vs events.

## Later 🧭
- [x] **Command channel cracked** — send TOGGLE_REALTIME_HR, parse REALTIME_DATA.
- [x] **HRV (RMSSD)** from RR intervals over the realtime channel.
- [ ] **Find the "start streaming" command** for high-rate raw data — sniff what
      the official app writes to `61080002`, or research community work. (Write path
      = careful, brick risk.)
- [ ] **Strap-worn / off-wrist detection** from the proprietary stream.
- [ ] **Background BLE** so the app keeps logging when not foregrounded.

## Ideas / stretch
- [ ] Recovery/strain-style metrics computed locally from HR/HRV.
- [ ] Standalone use without the official app at all.
