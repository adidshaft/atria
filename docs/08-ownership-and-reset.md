# Ownership, Factory Reset & "Treat It As My Device"

## Can we factory-reset the strap over BLE?

**Not reliably — and we deliberately don't attempt it.**

- A WHOOP factory reset is a **proprietary command** on the write characteristic
  `61080002`, which we have **not decoded**. The sanctioned path is the official
  WHOOP app (requires a subscription we don't have).
- The only way to "reset" from our code today would be to **blindly write guessed
  commands** to the device — an irreversible, brick-risk action. We won't do that
  without a known-good command.
- Tell: the `stream7` identity frame is bound to user `boylston` (likely a prior
  owner). Only a real reset clears that binding — but it doesn't block our use.

## What "treat it as my device" means in practice

We don't need WHOOP's cloud, account, or a reset to fully own the experience. The
split:

| Reliably reusable (keep) | Discard / replace with our own |
|---|---|
| Heart Rate service `0x2A37` (live BPM) | WHOOP cloud & account |
| Battery `0x2A19`, Device Info `0x180A` | Subscription-gated features |
| BLE connection itself | Proprietary streams needing undecoded commands |

Everything user-facing — profile, zones, **session history, persistence** — is
**local to the app** (Documents JSON + UserDefaults). No WHOOP login anywhere.

## If we ever want a real reset / raw streams

That requires decoding the command channel (`61080002`) — see
[07-capture-analysis.md](07-capture-analysis.md). Approach without the official
app: research known WHOOP protocol work, then careful black-box probing while
watching the RX channel `61080003`. Treated as a separate, deliberate effort.
