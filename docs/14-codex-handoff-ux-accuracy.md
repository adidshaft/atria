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

> **No external reference is available.** There is only one strap and no second
> chest-strap / ECG / lab device. So **drop every "independent RR/IBI reference"
> work item** — it cannot be done and must not be a blocker. All accuracy work
> below is **on-device, single-strap only**. Always run audits with
> `--skip-external-reference`. The terminal honest state for HRV/recovery is
> **"personal baseline"**, not "validated" — treat personal-baseline as the
> finished state for this project, and do not present "validated" as a pending
> to-do to the user (see §3a).

Current accuracy architecture lives in `WhoopBLEManager.record(_:)` and the
RR/HRV path (`HRV.swift`, `Metrics.swift`); see `docs/09-accuracy-and-learning.md`
and `docs/12-validation.md`. Per README Gate A/B, the proprietary realtime stream
is still diagnostic and the custom RR stream "is not reliable enough to be
primary."

On-device, single-strap work items (each needs a real strap + captures, **no
second device**):

1. **Promote the custom RR stream toward primary (Gate A/B) using self-consistency,
   not an external reference.** Over a long wear, capture standard `2A37` HR and
   the proprietary stream together and cross-check the RR stream *against the
   strap's own HR*: derived HR from RR intervals (60000 / mean RR) should track
   the `2A37` average within a tight band; beat counts over a window should
   agree. Quantify drift and only widen RR-source trust if the kept/raw RR
   confidence holds within the existing artifact filters (300–2000 ms, >20%
   beat-to-beat delta). Do **not** relax those filters to make numbers look
   better — that violates "no fake metrics."
2. **Strengthen the on-device RR confidence score.** Replace/augment the simple
   kept-vs-raw percentage with stability checks that need no reference: SDNN/RMSSD
   agreement across adjacent sub-windows, fraction of intervals surviving
   correction, and HR-contact stability (the existing 10 s contact gate). Surface
   this as the personal-baseline confidence — it is the honest ceiling without a
   reference.
3. **Motion-artifact rejection tuning.** Current rule rejects an isolated reading
   >50 bpm off the recent median. Validate against real gym/running captures
   (`gate_e_workout_audit.sh`) — measure false-reject rate before changing the
   threshold. Self-consistency only; no reference.
4. **Reconnect/coverage robustness for workout detection (Gate E).** The blocker
   is sustained-coverage gaps, not the detection math. Improve BLE reconnect
   continuity (watchdog timing in `WhoopBLEManager`) and re-run
   `tools/monitor_long_wear.py --preset overnight` until
   `acceptance_status=pass` / `acceptance_blockers=none`.

Verification harness (note `--skip-external-reference` everywhere):
```sh
./live_device_debug.sh --seconds 45 --log logs/live-device/run.log \
  --log-gate-status --standard-hr-only --long-wear-mode --leave-running
ATRIA_DEVICE_ID=<id> python3 tools/monitor_long_wear.py --preset overnight \
  --label overnight-$(date -u +%Y%m%dT%H%M%SZ)
python3 tools/audit_handoff_status.py --skip-external-reference
```

### 3a. Make "validated" not look like an unfinished task (no-reference reality)

Because validation can never complete on a single strap, the UI must not keep
dangling it as a pending checklist item. Today these present "Validated" as a
goal the user can reach:

- `AtriaOverviewSections.swift` → `AtriaOverviewLaunchChecklist`, the
  `"reference"` item titled **"Metric validation"** with detail "Use Collection
  when you have comparison data." → reframe so **personal baseline = done**. e.g.
  title "Personal baseline", complete when `baselineSamples >= 7`, and drop the
  "comparison data" call-to-action.
- The disconnected/quick-stat `AtriaInlineQuickStat(label: "Validation", ...)` and
  `snapshot.referenceText` → show baseline maturity, not a validation verdict.

Keep the **internal** validated seam intact (the static suite enforces
`test_validate_later_recovery_displays_personal_baseline_before_validation`,
`test_healthkit_hrv_export_uses_validated_sdnn_only`, etc. — HealthKit HRV write
must still gate on validated SDNN). This is a **presentation** change: stop
advertising "validated" as a user goal; the seam stays for correctness. Verify
the static suite stays green after any such edit.

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

## 6. Structure, scroll, duplication, lag (on-device iteration — Codex)

These need a running app + Instruments to do safely; I did the contained,
verifiable parts and scoped the rest precisely.

### Done this session (verifiable without a build)
- Rebuilt onboarding from a single cold "Profile" HRmax screen into a guided
  **3-step flow** (Welcome → Connect your strap → Set your max heart rate) in
  `ContentView.swift` `ProfileOnboardingView`. New steps explain the local/no-cloud
  value prop and the one-time strap connection — previously missing entirely.
- Removed the never-completable **"Metric validation"** row from the Overview
  launch checklist (`AtriaOverviewLaunchChecklist`) — it can't complete without an
  external reference and duplicated the HRV-baseline row. Renamed "Capture path"
  → "Live recording", "Launch checklist" → "Getting set up". Internal validated
  seam untouched (static suite green).

### Overview scroll is too long — 8 stacked cards on a phone
`AtriaOverviewTabContent` (compact width) stacks: Readiness → Getting-set-up →
Guidance/AI coach → Behavior journal → Trends → Live strap → Collection → Backup.
Recommendations (need on-device layout checks):
1. **Cut duplication with the Vitals tab.** Overview "Readiness" tiles
   (Recovery/Strain/HRV/Sleep) repeat the Vitals cards. Keep Readiness as the
   at-a-glance summary on Overview and make the Vitals tab the *detail* view —
   don't show the same four full cards in both. Tapping a Readiness tile should
   deep-link to the matching Vitals card.
2. **Cut duplication with the Collection tab.** The Overview "Collection" card
   duplicates the Collection tab. Demote it to a single compact "View captures →"
   link row, or fold it into the Backup card.
3. **Make secondary cards collapsible / move below the fold deliberately.**
   Behavior journal, Trends, Backup are reference material — consider a segmented
   control ("Today / Trends / Data") inside Overview instead of one long scroll,
   or `DisclosureGroup`s collapsed by default.
   - Note: the `AtriaLoadingPanel(title: "Preparing saved insights"|"Preparing
     trends")` literals are **test-locked** — keep those exact strings if those
     panels survive a refactor.

### Fewer dev-facing options
- The **Collection tab** is the most dev-facing surface (capture/CSV export). The
  RR/HR *reference import* cards are already gated behind `developerModeEnabled`
  (good). Consider renaming the user-visible tab "Collection" → "Data" or
  "Export", and leading with the plain "back up / export my data" action while
  pushing raw capture controls lower.
- Audit every remaining `value:`/`detail:` string in
  `AtriaVitalsCollectionSections.swift` for jargon once you can see it render.

### Lag (needs Instruments — do not guess-edit equatable code)
No always-on animation or high-frequency timer was found driving the main UI
(backdrop is `Equatable`/static; side-effects throttled at 750 ms; diagnostics
deferred). So lag is most likely **view-body churn from live-store @Published
updates** during connected/Vitals high-frequency mode
(`setForegroundHighFrequencyDisplayMode`). Suggested approach:
1. Profile with Instruments (SwiftUI + Time Profiler) on a real device while
   connected and on the Vitals tab (high-frequency path).
2. Look for views that re-evaluate `body` on every HR sample but aren't
   `.equatable()`-gated, or `Equatable ==` implementations that compare changing
   fields (e.g. timestamps) and so never short-circuit.
3. Throttle/coalesce the high-frequency display store the same way side-effects
   are throttled, if the big-number/sparkline path is the hot spot.
The codebase is already heavily `Equatable`-optimized, so the win is finding the
one or two stores that bypass it — not a broad rewrite.

## 5. Suggested commit for this session's work

```
Humanize connection and first-run copy

Replace internal terms (handoff, fast path, armed, live packets) with
plain user-facing language across the disconnected overview, connection
guide sheet, and hero guidance. Copy-only; static checks green.
```
