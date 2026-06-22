# Codex Handoff — UX friendliness pass + accuracy follow-ups

Date: 2026-06-22
Author: Claude (non-device session)
Scope: User-facing copy made friendlier (no logic change); device-dependent
accuracy and visual work handed to Codex.

## Hard constraint for this session

This pass was done **without a physical iPhone and without an Xcode build**. So
everything here is restricted to changes that are verifiable by reading source +
the existing Python static-check suite:

```sh
python3 test_handoff_static_checks.py     # 26 tests, must stay green
./test_handoff_local.sh                   # fast local tooling checks
```

Anything that touches BLE, RR/HRV accuracy, layout/rendering, or HealthKit
**must be verified on a real device by Codex** — the Simulator does not count
(see README "Physical-device verified").

---

## 1. What changed in this session (done)

A **copy-only** pass replacing developer jargon in the most-seen first-run and
connection surfaces with plain, user-facing language. No control flow, no metric
math, no BLE behavior changed. Static suite stays green (26/26).

Files touched:

- `WhoopApp/WhoopApp/AtriaOverviewSections.swift`
  — `AtriaDisconnectedOverviewPanel` title/detail/setupDetail strings.
- `WhoopApp/WhoopApp/AtriaHeroConnectionSections.swift`
  — `AtriaConnectionGuideSheet` title/subtitle/steps/automatic items/button
  labels/footer.
- `WhoopApp/WhoopApp/AtriaHomeView.swift`
  — hero `Coach.Guidance` headlines/details for scanning/connecting/poweredOff/
  disconnected/connected fast-path states.

Jargon removed → replaced, examples:

| Before (dev-speak) | After (user-facing) |
|---|---|
| "Finishing the first handoff" | "Connecting to your strap" |
| "Atria already has the first-run path … lightweight connection flow" | "Almost there — Atria is linking up with your strap." |
| "Automatic reconnects are armed after the first successful handoff" | "From now on, Atria reconnects to your strap automatically." |
| "keeps background logging armed on its own" | "keeps logging in the background on its own" |
| "the first live packets can settle cleanly" | "your live data comes back cleanly" |
| "Atria already owns the strap … resumes the live path" | "Atria is already connected to your strap … picking your live data back up" |
| "Live scoring settles in after the first screen becomes interactive" | "Your live scores fill in moments after the screen is ready" |

**Important — two strings are LOCKED by `test_handoff_static_checks.py` and must
stay verbatim** (do not "humanize" them without also updating the test):

- `AtriaOverviewSections.swift`: `"Saved insights prepare after the live connection settles."`
- `AtriaOverviewSections.swift`: `"Saved metrics and backup remain available while the strap reconnects."`
- `AtriaHeroConnectionSections.swift`: `"Saved metrics and backup remain on device while Atria waits for the strap again."`
- Also locked: `"Connection state: \(context.userStatusLabel)"`, plus several
  `AtriaLoadingPanel`/`AtriaInlineQuickStat` literals. Grep the test before
  editing any overview/hero copy.

### Codex: verify this pass on device
Build to a physical iPhone and walk the four connection states (powered-off,
scanning, connecting, connected) confirming the new copy renders without
truncation/overflow at the largest Dynamic Type size. The `ViewThatFits` blocks
should still pick the right layout.

---

## 2. UX follow-ups worth doing (not done — needs render/device)

These are judgment calls I would not make blind because I can't see them render:

1. **"Validation" / "Metric validation" / "Baseline 0/7" labels** in the launch
   checklist and disconnected quick-stats (`AtriaOverviewSections.swift`,
   `AtriaOverviewLaunchChecklist`). Honest, but reads clinical. Consider a plain
   tooltip/"What does this mean?" affordance instead of renaming (renaming risks
   the honesty invariants in the static suite — keep the badge semantics).
2. **First-run onboarding** (`ContentView.swift` `ProfileOnboardingView`, around
   line 750). Line 755 still says "Atria uses HR reserve from learned resting HR
   up to this HRmax." → that's the one remaining dev-ish onboarding sentence.
   Soften to explain *why* (e.g. "This sets how hard your max effort is, so
   strain is scored to you. You can change it anytime in Vitals.").
3. **Empty/`miniMetric` states** in `ContentView.swift` `DailyEvidenceCard`
   ("candidate"/"none" labels). "candidate" is jargon for "we think we saw one,
   not confirmed". Consider "maybe"/"unconfirmed" wording with an info tap.
4. **Connection guide button hierarchy** — `Retry scan now` is `.glassProminent
   .tint(.gray)` next to a blue prominent primary. On device, confirm the gray
   prominent button doesn't read as disabled; a `.glass` (non-prominent)
   secondary may be clearer.

None of the above were changed because they need eyes on the running UI.

---

## 3. Accuracy — "read WHOOP better" (device-only, Codex)

This is the part that genuinely cannot be done off-device. Current accuracy
architecture lives in `WhoopBLEManager.record(_:)` and the RR/HRV path
(`HRV.swift`, `Metrics.swift`); see `docs/09-accuracy-and-learning.md` and
`docs/12-validation.md`. Per README Gate A/B, the proprietary realtime stream is
still diagnostic and the custom RR stream "is not reliable enough to be primary."

Concrete, evidence-gated work items (each needs a real strap + captures):

1. **Promote the custom RR stream toward primary (Gate A/B).** Capture
   simultaneous standard `2A37` HR and the proprietary stream over a long wear,
   compare beat counts/timing, and quantify drift. Only widen RR-source trust if
   the kept/raw RR confidence holds within the existing artifact filters
   (300–2000 ms, >20% delta rejection). Do **not** relax those filters to make
   numbers look better — that violates the "no fake metrics" principle.
2. **Independent RR/IBI reference comparison (Gate B → validated HRV).** This is
   the single gate blocking validated HRV/recovery/HealthKit HRV write. Use a
   chest-strap/ECG reference, run `prepare_reference_rr.py` +
   `reference_validate.sh`, and confirm tolerance. The badge only promotes to
   "Validated" when the reference path passes — wire the result through, don't
   hardcode.
3. **Motion-artifact rejection tuning.** Current rule rejects an isolated reading
   >50 bpm off the recent median. Validate against real gym/running captures
   (`gate_e_workout_audit.sh`) — measure false-reject rate before changing the
   threshold.
4. **Reconnect/coverage robustness for workout detection (Gate E).** The blocker
   is sustained-coverage gaps, not the detection math. Improve BLE reconnect
   continuity (watchdog timing in `WhoopBLEManager`) and re-run
   `tools/monitor_long_wear.py --preset overnight` until
   `acceptance_status=pass` / `acceptance_blockers=none`.

Verification harness for all of the above:
```sh
./live_device_debug.sh --seconds 45 --log logs/live-device/run.log \
  --log-gate-status --standard-hr-only --long-wear-mode --leave-running
ATRIA_DEVICE_ID=<id> python3 tools/monitor_long_wear.py --preset overnight \
  --label overnight-$(date -u +%Y%m%dT%H%M%SZ)
python3 tools/audit_handoff_status.py --skip-external-reference
```

---

## 4. Guardrails Codex must not trip

- Keep `python3 test_handoff_static_checks.py` green (it locks honesty copy,
  `standard_hr_only` write-blocking, HealthKit HRV→validated-SDNN gating,
  local-first no-network invariant, AI-coach offline default, monetization seam
  un-gated).
- No network/cloud clients in the app core (test enforces it).
- HRV/recovery stay "personal baseline / unverified" until a real reference
  validates — never auto-promote.
- All BLE-affecting changes require a physical-iPhone run; Simulator is not
  acceptance.

---

## 5. Suggested commit for this session's work

```
Humanize connection and first-run copy

Replace internal terms (handoff, fast path, armed, live packets) with
plain user-facing language across the disconnected overview, connection
guide sheet, and hero guidance. Copy-only; static checks green.
```
