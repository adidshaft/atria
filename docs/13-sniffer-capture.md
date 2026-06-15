# Gate B — BLE sniffer capture plan (official WHOOP app)

Goal: capture the official WHOOP app driving **this** strap, so we learn the two
things our app doesn't know: the command sequence that makes RR continuous, and/or
the historical-transfer request that yields `0x2f` data frames.

Analyzer is ready: `tools/analyze_sniffer.py` (decodes the trace with `whoop_codec`).

---

## STEP 0 — Feasibility gate (do this FIRST, before buying/setting up anything)

The sniffer only works if the **official WHOOP app can actually connect to and
stream from this strap.** This strap is bound to a prior owner (`boylston`), and
the WHOOP app requires an account.

**Check:** install the official WHOOP app, sign in / create an account, and try to
add this strap. Watch live HR appear in the official app.
- ✅ If the official app shows live data from this strap → proceed to STEP 1.
- ❌ If it can't claim/connect the strap (owned by another account, needs
  subscription) → **the sniffer route is infeasible**; there is nothing to capture.
  Fall back to "defer HRV, build elsewhere" and revisit if ownership is resolved.

Do not skip Step 0 — it determines whether the rest is possible.

---

## STEP 1 — Hardware & software

- **Sniffer:** Nordic **nRF52840 Dongle** (~$10) flashed with the **nRF Sniffer for
  Bluetooth LE** firmware (Nordic's free tool). (A Bluefruit LE Sniffer also works.)
- **Wireshark** (includes `tshark`) + the nRF Sniffer Wireshark plugin (Nordic's
  installer adds the capture interface).
- macOS: `brew install --cask wireshark` then install the nRF Sniffer plugin per
  Nordic's guide.

## STEP 2 — Capture

1. Open Wireshark, select the **nRF Sniffer** interface.
2. In the sniffer toolbar, set it to **follow the WHOOP device** (pick it by name/
   address `E0:29:C0:AC:D2:75` so you capture its connection, not all traffic).
3. Start capture.
4. In the **official WHOOP app**: disconnect/reconnect the strap so you capture a
   **fresh connection from scratch** (the init handshake is the prize).
5. Capture these windows (keep the strap on, still, snug — same fit discipline):
   - **0–60 s after connect:** the full connection setup + every command write.
   - **2–5 min steady state:** to measure the official app's RR-frame rate.
   - If the app has a "reprocess / sync / view HRV" action, trigger it to force a
     **historical sync** and capture the `0x06`-family request + any `0x2f` frames.
6. Stop capture; **File → Save As** `whoop_official.pcapng`.

## STEP 3 — Export the ATT layer and analyze

```bash
tshark -r whoop_official.pcapng -Y btatt -T json \
  -e frame.time_relative -e btatt.opcode -e btatt.handle -e btatt.value > att.json

./tools/analyze_sniffer.py att.json
```

Drop both `whoop_official.pcapng` and `att.json` into
`docs/evidence/gate-b/sniffer/<timestamp>/` and commit (capture is the evidence).

## STEP 4 — What we're looking for (decision)

The analyzer prints **every command the official app wrote** and the **RR-bearing
fraction**. Two possible wins:

1. **Continuous-RR trigger:** if the official app's RR fraction is high (~≥90%),
   diff its write sequence against ours (we send only `aa0800a82300030199bce9cf`).
   The extra/different writes before sustained RR are the missing step → replicate
   them in `WhoopBLEManager.armRealtime`.
2. **Historical transfer:** if `0x2f` frames appear, capture the exact `0x06`-family
   request bytes that preceded them → replicate to pull stored RR (clean 5-min
   windows without live continuity).

## STEP 5 — Then close Gate B

Replicate the discovered sequence on the cabled iPhone, capture a clean ≥5-min RR
window, and compare RMSSD within **±5 ms** of a reference (e.g. a Polar H10). Only
then mark Gate B done. Until then HRV stays **learning** — no fabrication.
